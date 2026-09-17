import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongRecord } from '../model/Song';

const TAG = 'SessionController';
const DOMAIN = 0x0002;

/**
 * 媒体会话与后台播放控制：
 * - AVSession 负责通知栏/锁屏媒体控制与元数据展示
 * - continuousTask(AUDIO_PLAYBACK) 保证退到后台后继续播放
 */
export class SessionController {
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private runningInBackground: boolean = false;

  /**
   * 创建会话并注册媒体控制命令回调（API 24 起命令需逐个注册）
   */
  async init(context: common.UIAbilityContext, handlers: SessionHandlers): Promise<void> {
    this.context = context;
    try {
      this.session = await avSession.createAVSession(context, 'musicPlayerSession', 'audio');
      this.session.on('play', () => handlers.onPlay());
      this.session.on('pause', () => handlers.onPause());
      this.session.on('stop', () => handlers.onStop());
      this.session.on('playNext', () => handlers.onNext());
      this.session.on('playPrevious', () => handlers.onPrevious());
      this.session.on('seek', (time: number) => handlers.onSeek(time));
      // 耳机长按快进/快退手势（无线耳机的 AVRCP 长按映射为此命令），
      // 不注册则按键被系统丢弃
      this.session.on('fastForward', (time?: number) => handlers.onFastForward(time));
      this.session.on('rewind', (time?: number) => handlers.onRewind(time));
      await this.session.activate();
      hilog.info(DOMAIN, TAG, 'AVSession activated');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'create AVSession failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 通知媒体中心当前曲目元数据；本地曲目带封面（mediaImage 支持
   * 本地路径，锁屏/通知栏展示专辑封面），在线曲目无封面文件则省略。
   * 可选字段必须整键省略：系统参数解析按「键存在即校验类型」处理，
   * 键存在但值为 undefined 时整条元数据被拒（真机 API 24 返回 401，
   * 元数据丢失会导致实况窗不显示、耳机按键路由到其他应用） */
  async updateMetadata(song: SongRecord): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      const metadata: avSession.AVMetadata = {
        assetId: song.id,
        title: song.title,
        artist: song.artist
      };
      if (song.album !== '') {
        metadata.album = song.album;
      }
      if (song.duration > 0) {
        metadata.duration = song.duration;
      }
      if (song.coverPath !== '') {
        metadata.mediaImage = song.coverPath;
      }
      await this.session.setAVMetadata(metadata);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVMetadata failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 通知媒体中心播放状态 */
  async updatePlaybackState(playing: boolean, positionMs: number, speed: number): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      const state: avSession.AVPlaybackState = {
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: speed,
        position: {
          elapsedTime: positionMs,
          updateTime: new Date().getTime()
        }
        // 不上报 bufferedTime：平台拿不到真实缓冲位置，误报当前进度会
        // 让锁屏缓冲显示失真
      };
      await this.session.setAVPlaybackState(state);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 开始播放时申请音频后台长驻任务。系统在焦点打断等场景会自行取消
   * 长驻任务（官方要求重启播放时重新申请），内存标志可能与实际不符，
   * 因此每次播放都实际申请：申请成功置标志，失败清标志以便下次重试 */
  async startBackground(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(agentInfo);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.runningInBackground = true;
      hilog.info(DOMAIN, TAG, 'background audio task started');
    } catch (err) {
      this.runningInBackground = false;
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 停止播放时结束长驻任务；无论成功与否标志都归位，避免陈旧标志
   * 挡住后续申请 */
  async stopBackground(): Promise<void> {
    if (!this.runningInBackground || !this.context) {
      return;
    }
    this.runningInBackground = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      hilog.info(DOMAIN, TAG, 'background audio task stopped');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 应用退出时销毁会话 */
  async destroy(): Promise<void> {
    await this.stopBackground();
    if (this.session) {
      try {
        await this.session.destroy();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'destroy session failed: %{public}s', JSON.stringify(err));
      }
      this.session = null;
    }
  }
}

/**
 * 媒体控制命令回调集合（由 PlayerController 提供）
 */
export interface SessionHandlers {
  onPlay(): void;
  onPause(): void;
  onStop(): void;
  onNext(): void;
  onPrevious(): void;
  onSeek(positionMs: number): void;
  /** 耳机/播控快进；time 为控制器给定的秒数，缺省或非法时由实现方兜底 */
  onFastForward(time?: number): void;
  /** 耳机/播控快退；time 语义同上 */
  onRewind(time?: number): void;
}
