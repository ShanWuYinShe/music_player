import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongRecord } from '../model/Song';
import { PlayMode, nextPlayMode } from '../model/PlayMode';
import { MusicLibrary } from '../library/MusicLibrary';
import { SessionController, SessionHandlers } from './SessionController';

const TAG = 'PlayerController';
const DOMAIN = 0x0003;

/**
 * 播放内核与 UI 状态中心：
 * 封装 AVPlayer 状态机、播放队列与播放模式，@Trace 字段直接驱动界面刷新。
 */
@ObservedV2
export class PlayerController {
  /** 曲目列表 */
  @Trace songs: SongRecord[] = [];
  /** 当前播放曲目 id，空表示未播放 */
  @Trace currentSongId: string = '';
  /** 是否正在播放 */
  @Trace isPlaying: boolean = false;
  /** 当前曲是否已加载完成（可 seek） */
  @Trace isPrepared: boolean = false;
  /** 当前播放位置（毫秒） */
  @Trace currentTime: number = 0;
  /** 当前曲总时长（毫秒） */
  @Trace duration: number = 0;
  /** 播放模式 */
  @Trace playMode: PlayMode = PlayMode.SEQUENCE;

  private library: MusicLibrary;
  private session: SessionController = new SessionController();
  private player: media.AVPlayer | null = null;
  private context: common.UIAbilityContext | null = null;
  /** 切歌代际号：递增后旧实例的异步回调全部作废 */
  private generation: number = 0;

  constructor(library: MusicLibrary) {
    this.library = library;
  }

  /** 应用启动时初始化（UIAbility onCreate 调用） */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.refreshSongs();
    await this.session.init(context, this.buildHandlers());
  }

  /** 应用退出时释放资源 */
  async destroy(): Promise<void> {
    this.generation++;
    await this.releasePlayer();
    await this.session.destroy();
  }

  /** 导入/删除歌曲后刷新队列 */
  refreshSongs(): void {
    this.songs = this.library.getAllSongs();
  }

  get currentSong(): SongRecord | null {
    return this.library.getSongById(this.currentSongId);
  }

  /** 点击列表项播放指定曲目 */
  playSong(id: string): void {
    const song = this.library.getSongById(id);
    if (!song) {
      return;
    }
    this.currentSongId = id;
    this.loadAndPlay(song);
  }

  /** 播放/暂停切换 */
  togglePlay(): void {
    if (!this.player) {
      // 尚未加载任何曲目时，播放列表第一首
      if (this.songs.length > 0) {
        this.playSong(this.songs[0].id);
      }
      return;
    }
    if (this.isPlaying) {
      this.pause();
    } else {
      this.play();
    }
  }

  /** 下一首（手动操作，单曲循环模式下同样切歌） */
  next(): void {
    if (this.songs.length === 0) {
      return;
    }
    const index = this.currentIndex();
    if (index < 0) {
      this.playSong(this.songs[0].id);
      return;
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      this.playSong(this.songs[this.randomIndex(index)].id);
      return;
    }
    const nextIndex = (index + 1) % this.songs.length;
    this.playSong(this.songs[nextIndex].id);
  }

  /** 上一首 */
  previous(): void {
    if (this.songs.length === 0) {
      return;
    }
    const index = this.currentIndex();
    if (index < 0) {
      this.playSong(this.songs[0].id);
      return;
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      this.playSong(this.songs[this.randomIndex(index)].id);
      return;
    }
    const prevIndex = (index - 1 + this.songs.length) % this.songs.length;
    this.playSong(this.songs[prevIndex].id);
  }

  /** 循环切换播放模式 */
  cyclePlayMode(): void {
    this.playMode = nextPlayMode(this.playMode);
  }

  /** 进度拖拽（毫秒） */
  seek(positionMs: number): void {
    if (this.player && this.isPrepared) {
      this.player.seek(positionMs);
      this.currentTime = positionMs;
    }
  }

  /** 删除歌曲：若删除的是当前曲则停止播放 */
  removeSong(id: string): void {
    const isCurrent = id === this.currentSongId;
    this.library.removeSong(id);
    this.refreshSongs();
    if (isCurrent) {
      this.stopPlayback();
    }
  }

  async play(): Promise<void> {
    if (!this.player) {
      return;
    }
    try {
      await this.player.play();
      this.isPlaying = true;
      await this.session.updatePlaybackState(true, this.currentTime, 1.0);
      await this.session.startBackground();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'play failed: %{public}s', JSON.stringify(err));
    }
  }

  async pause(): Promise<void> {
    if (!this.player) {
      return;
    }
    try {
      await this.player.pause();
      this.isPlaying = false;
      await this.session.updatePlaybackState(false, this.currentTime, 1.0);
      // 暂停仅退出播放态：保留长驻任务，避免频繁起停；完全停止时再结束
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'pause failed: %{public}s', JSON.stringify(err));
    }
  }

  stopPlayback(): void {
    this.generation++;
    this.releasePlayer();
    this.currentSongId = '';
    this.isPlaying = false;
    this.isPrepared = false;
    this.currentTime = 0;
    this.duration = 0;
    this.session.updatePlaybackState(false, 0, 1.0);
    this.session.stopBackground();
  }

  /** 加载曲目并自动播放：重建 AVPlayer 实例，简单可靠 */
  private async loadAndPlay(song: SongRecord): Promise<void> {
    const gen = ++this.generation;
    this.isPlaying = false;
    this.isPrepared = false;
    this.currentTime = 0;
    this.duration = song.duration;
    await this.releasePlayer();
    if (gen !== this.generation) {
      return;
    }
    try {
      const player = await media.createAVPlayer();
      if (gen !== this.generation) {
        player.release();
        return;
      }
      this.player = player;
      this.registerPlayerEvents(player, gen, song);
      player.url = `file://${this.library.songPath(song)}`;
      await player.prepare();
      await this.play();
      await this.session.updateMetadata(song);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load song failed: %{public}s', JSON.stringify(err));
      this.isPlaying = false;
    }
  }

  private registerPlayerEvents(player: media.AVPlayer, gen: number, song: SongRecord): void {
    player.on('stateChange', (state: string) => {
      if (gen !== this.generation) {
        return;
      }
      if (state === 'prepared') {
        this.isPrepared = true;
        if (player.duration > 0) {
          this.duration = player.duration;
          this.library.updateDuration(song.id, player.duration);
        }
      } else if (state === 'completed') {
        this.onCompleted();
      } else if (state === 'error') {
        this.isPlaying = false;
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (gen !== this.generation) {
        return;
      }
      this.currentTime = time;
    });
    player.on('error', (err) => {
      hilog.error(DOMAIN, TAG, 'AVPlayer error: %{public}s', JSON.stringify(err));
    });
  }

  /** 一曲播完，按播放模式决定后续行为 */
  private onCompleted(): void {
    if (this.playMode === PlayMode.SINGLE) {
      this.currentTime = 0;
      if (this.player) {
        this.player.seek(0);
        this.play();
      }
      return;
    }
    const index = this.currentIndex();
    if (index >= 0 && index === this.songs.length - 1 && this.playMode === PlayMode.SEQUENCE) {
      // 顺序播放到列表末尾：停止
      this.isPlaying = false;
      this.currentTime = 0;
      this.session.updatePlaybackState(false, 0, 1.0);
      this.session.stopBackground();
      return;
    }
    this.next();
  }

  private currentIndex(): number {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === this.currentSongId) {
        return i;
      }
    }
    return -1;
  }

  private randomIndex(exclude: number): number {
    if (this.songs.length <= 1) {
      return 0;
    }
    let index = exclude;
    while (index === exclude) {
      index = Math.floor(Math.random() * this.songs.length);
    }
    return index;
  }

  private async releasePlayer(): Promise<void> {
    const player = this.player;
    this.player = null;
    if (player) {
      try {
        await player.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'release player: %{public}s', JSON.stringify(err));
      }
    }
  }

  /** 通知栏/锁屏命令回调 → 播放操作 */
  private buildHandlers(): SessionHandlers {
    return new PlayerCommandHandlers(this);
  }
}

/**
 * 媒体控制命令处理器（通知栏/锁屏 → 播放内核）
 */
class PlayerCommandHandlers implements SessionHandlers {
  private controller: PlayerController;

  constructor(controller: PlayerController) {
    this.controller = controller;
  }

  onPlay(): void {
    if (this.controller.currentSongId === '') {
      if (this.controller.songs.length > 0) {
        this.controller.playSong(this.controller.songs[0].id);
      }
    } else if (!this.controller.isPlaying) {
      this.controller.play();
    }
  }

  onPause(): void {
    if (this.controller.isPlaying) {
      this.controller.pause();
    }
  }

  onStop(): void {
    this.controller.stopPlayback();
  }

  onNext(): void {
    this.controller.next();
  }

  onPrevious(): void {
    this.controller.previous();
  }

  onSeek(positionMs: number): void {
    this.controller.seek(positionMs);
  }
}
