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
      await this.session.activate();
      hilog.info(DOMAIN, TAG, 'AVSession activated');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'create AVSession failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 通知媒体中心当前曲目元数据；本地曲目带封面（mediaImage 支持
   * 本地路径，锁屏/通知栏展示专辑封面），在线曲目无封面文件则省略 */
  async updateMetadata(song: SongRecord): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      const metadata: avSession.AVMetadata = {
        assetId: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album !== '' ? song.album : undefined,
        duration: song.duration > 0 ? song.duration : undefined,
        mediaImage: song.coverPath !== '' ? song.coverPath : undefined
      };
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

  /** 开始播放时申请音频后台长驻任务 */
  async startBackground(): Promise<void> {
    if (this.runningInBackground || !this.context) {
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
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 停止播放时结束长驻任务 */
  async stopBackground(): Promise<void> {
    if (!this.runningInBackground || !this.context) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.runningInBackground = false;
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
}
