import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongRecord } from '../model/Song';
import { PlayMode, nextPlayMode } from '../model/PlayMode';
import { MusicLibrary } from '../library/MusicLibrary';
import { UserData } from '../viewmodel/UserData';
import { SessionController, SessionHandlers } from './SessionController';

const TAG = 'PlayerController';
const DOMAIN = 0x0003;

const KEY_LAST_SONG = 'last_song_id';
const KEY_LAST_POS = 'last_position_ms';
const KEY_PLAY_MODE = 'play_mode';

/** 判定 fileName 是否为网络流地址（http/https，在线曲目由 OnlineSource 生成） */
function isNetworkUrl(fileName: string): boolean {
  return fileName.startsWith('http://') || fileName.startsWith('https://');
}

/**
 * 播放内核与 UI 状态中心：
 * 封装 AVPlayer 状态机、播放队列与播放模式，@Trace 字段直接驱动界面刷新。
 * 附加能力：下一首插播队列、音量、定时关闭、退出续播。
 */
@ObservedV2
export class PlayerController {
  /** 曲目列表 */
  @Trace songs: SongRecord[] = [];
  /** 当前播放曲目 id，空表示未播放（含「恢复上次会话」的未加载态） */
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
  /** 音量 0~1 */
  @Trace volume: number = 1;
  /** 定时关闭剩余秒数，-1 表示未启用 */
  @Trace sleepRemainSec: number = -1;

  private library: MusicLibrary;
  private userData: UserData;
  private session: SessionController = new SessionController();
  private player: media.AVPlayer | null = null;
  /** 当前曲目占用的文件描述符，release 时关闭 */
  private currentFd: number = -1;
  private context: common.UIAbilityContext | null = null;
  /** 切歌代际号：递增后旧实例的异步回调全部作废 */
  private generation: number = 0;
  /** 「下一首播放」插播队列：任何前进切歌优先消费 */
  @Trace playNextQueue: string[] = [];
  /** 续播位置：prepared 后先 seek 再播，消费后清零 */
  private pendingSeekMs: number = 0;
  private pref: preferences.Preferences | null = null;
  private sleepTimerId: number = -1;
  /** 当前队列 id → SongRecord 索引（本地曲库或在线列表），playSong/currentSong 查找用 */
  private songIndex: Map<string, SongRecord> = new Map();

  constructor(library: MusicLibrary, userData: UserData) {
    this.library = library;
    this.userData = userData;
  }

  /** 应用启动时初始化（UIAbility onCreate 调用） */
  async init(context: common.UIAbilityContext, pref: preferences.Preferences | null): Promise<void> {
    this.context = context;
    this.pref = pref;
    this.refreshSongs();
    this.restorePlayMode();
    this.restoreLastSession();
    await this.session.init(context, this.buildHandlers());
  }

  /** 应用退出时释放资源并持久化会话状态 */
  async destroy(): Promise<void> {
    this.generation++;
    this.cancelSleepTimer();
    this.persistState();
    await this.releasePlayer();
    await this.session.destroy();
  }

  /** 导入/删除歌曲后刷新队列（本地曲库队列） */
  refreshSongs(): void {
    this.songs = this.library.getAllSongs();
    this.rebuildIndex(this.songs);
  }

  /** 切换为在线曲目队列（在线列表拉取成功后调用） */
  setOnlineQueue(list: SongRecord[]): void {
    this.songs = list.slice();
    this.rebuildIndex(this.songs);
  }

  get currentSong(): SongRecord | null {
    return this.findSong(this.currentSongId);
  }

  /** 插播队列长度（UI 展示用） */
  get playNextCount(): number {
    return this.playNextQueue.length;
  }

  /** 插播队列快照 */
  playNextIds(): string[] {
    return this.playNextQueue.slice();
  }

  /**
   * 加入「下一首播放」队列；已在队列或正在播放时不重复加入。
   * @returns 加入后的队列长度
   */
  queueNext(id: string): number {
    if (id === this.currentSongId || this.playNextQueue.indexOf(id) >= 0) {
      return this.playNextQueue.length;
    }
    this.playNextQueue.push(id);
    return this.playNextQueue.length;
  }

  clearPlayNextQueue(): void {
    this.playNextQueue = [];
  }

  /** 点击列表项播放指定曲目 */
  playSong(id: string): void {
    const song = this.findSong(id);
    if (!song) {
      return;
    }
    this.currentSongId = id;
    this.pendingSeekMs = 0;
    this.userData.addRecent(id);
    this.loadAndPlay(song);
  }

  /** 播放/暂停切换；未加载时优先恢复当前曲（续播），否则从第一首开始 */
  togglePlay(): void {
    if (!this.player) {
      const target = this.currentSongId !== '' ? this.findSong(this.currentSongId) : null;
      if (target) {
        // 续播：pendingSeekMs 已在恢复时记录
        this.loadAndPlay(target);
      } else if (this.songs.length > 0) {
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

  /** 下一首（手动操作，单曲循环模式下同样切歌）；优先消费插播队列 */
  next(): void {
    if (this.songs.length === 0) {
      return;
    }
    const queuedId = this.shiftQueuedExisting();
    if (queuedId !== '') {
      this.playSong(queuedId);
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
    if (this.currentTime > 5000) {
      // 播放超 5 秒时上一首回到曲首（符合常见交互习惯）
      this.seek(0);
      return;
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      this.playSong(this.songs[this.randomIndex(index)].id);
      return;
    }
    const prevIndex = (index - 1 + this.songs.length) % this.songs.length;
    this.playSong(this.songs[prevIndex].id);
  }

  /** 循环切换播放模式并持久化 */
  cyclePlayMode(): void {
    this.playMode = nextPlayMode(this.playMode);
    this.persistState();
  }

  /** 进度拖拽（毫秒） */
  seek(positionMs: number): void {
    if (this.player && this.isPrepared) {
      try {
        this.player.seek(positionMs);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', JSON.stringify(err));
      }
      this.currentTime = positionMs;
    }
  }

  /** 设置音量（0~1），对后续曲目同样生效 */
  setVolume(value: number): void {
    const clamped = Math.min(1, Math.max(0, value));
    this.volume = clamped;
    this.applyVolume();
  }

  private applyVolume(): void {
    if (!this.player) {
      return;
    }
    try {
      // setVolume 仅在 prepared/playing/paused/completed 态可调用，其余态由 prepared 时统一应用
      this.player.setVolume(this.volume);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set volume failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 启动定时关闭（分钟） */
  startSleepTimer(minutes: number): void {
    this.cancelSleepTimer();
    this.sleepRemainSec = Math.max(1, Math.round(minutes * 60));
    this.sleepTimerId = setInterval(() => {
      this.sleepRemainSec -= 1;
      if (this.sleepRemainSec <= 0) {
        this.cancelSleepTimer();
        this.pause(); // 到点柔和暂停而非销毁现场
      }
    }, 1000);
  }

  cancelSleepTimer(): void {
    if (this.sleepTimerId >= 0) {
      clearInterval(this.sleepTimerId);
      this.sleepTimerId = -1;
    }
    this.sleepRemainSec = -1;
  }

  /** 删除歌曲：若删除的是当前曲则停止播放，并清理用户数据引用与插播队列（仅本地曲目） */
  removeSong(id: string): void {
    const song = this.findSong(id);
    if (!song || isNetworkUrl(song.fileName)) {
      return; // 在线曲目由服务端曲库管理，本地无删除语义
    }
    const isCurrent = id === this.currentSongId;
    this.playNextQueue = this.playNextQueue.filter((item) => item !== id);
    this.userData.removeSongRefs(id);
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
      // isPlaying / AVSession / 后台任务同步由 stateChange(playing) 事件统一处理
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'play failed: %{public}s', JSON.stringify(err));
    }
  }

  async pause(): Promise<void> {
    if (!this.player || !this.isPlaying) {
      return;
    }
    try {
      await this.player.pause();
      this.persistState(); // 记录断点，供下次续播
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
    this.pendingSeekMs = 0;
    this.session.updatePlaybackState(false, 0, 1.0);
    this.session.stopBackground();
    this.persistState();
  }

  /** 持久化当前会话（当前曲/进度/模式），供下次启动续播 */
  persistState(): void {
    if (!this.pref) {
      return;
    }
    try {
      this.pref.putSync(KEY_LAST_SONG, this.currentSongId);
      this.pref.putSync(KEY_LAST_POS, Math.floor(this.currentTime));
      this.pref.putSync(KEY_PLAY_MODE, this.playMode);
      this.pref.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persist state failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 恢复播放模式偏好 */
  private restorePlayMode(): void {
    if (!this.pref) {
      return;
    }
    const raw = this.pref.getSync(KEY_PLAY_MODE, 0) as number;
    if (raw === PlayMode.SINGLE || raw === PlayMode.SHUFFLE || raw === PlayMode.SEQUENCE) {
      this.playMode = raw as PlayMode;
    }
  }

  /** 恢复上次退出时的曲目与进度（仅展示，首次点播放时真正加载） */
  private restoreLastSession(): void {
    if (!this.pref || this.currentSongId !== '') {
      return;
    }
    const songId = this.pref.getSync(KEY_LAST_SONG, '') as string;
    if (songId === '') {
      return;
    }
    const song = this.findSong(songId);
    if (!song) {
      return;
    }
    const pos = this.pref.getSync(KEY_LAST_POS, 0) as number;
    this.currentSongId = songId;
    this.duration = song.duration;
    this.currentTime = pos > 0 && pos < song.duration ? pos : 0;
    this.pendingSeekMs = this.currentTime;
  }

  /** 弹出插播队列中仍存在的曲目 id */
  private shiftQueuedExisting(): string {
    while (this.playNextQueue.length > 0) {
      const id = this.playNextQueue.shift() as string;
      if (this.findSong(id)) {
        return id;
      }
    }
    return '';
  }

  /** 重建队列索引；正在播放的曲目不在新队列时保留其条目，切源不打断播放 */
  private rebuildIndex(songs: SongRecord[]): void {
    const index = new Map<string, SongRecord>();
    for (const song of songs) {
      index.set(song.id, song);
    }
    const current = this.songIndex.get(this.currentSongId);
    if (current && current.id !== '' && !index.has(current.id)) {
      index.set(current.id, current);
    }
    this.songIndex = index;
  }

  /** 队列查找：当前队列索引优先，本地曲库兜底（启动恢复等场景） */
  private findSong(id: string): SongRecord | null {
    if (id === '') {
      return null;
    }
    return this.songIndex.get(id) ?? this.library.getSongById(id);
  }

  /** 加载曲目并自动播放：重建 AVPlayer 实例，状态推进全部由 stateChange 事件驱动 */
  private async loadAndPlay(song: SongRecord): Promise<void> {
    const gen = ++this.generation;
    this.isPlaying = false;
    this.isPrepared = false;
    this.currentTime = this.pendingSeekMs;
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
      if (isNetworkUrl(song.fileName)) {
        // 在线流媒体：url 属性原生支持 http(s) 网络协议，Range 分段由内核处理
        player.url = song.fileName;
      } else {
        // 本地文件必须走文件描述符（url 仅支持网络协议与 fd:// 协议）；
        // 赋值后状态迁移(initialized)为异步事件，prepare 须在 stateChange 回调中触发
        const file = fs.openSync(this.library.songPath(song), fs.OpenMode.READ_ONLY);
        this.currentFd = file.fd;
        player.url = `fd://${file.fd}`;
      }
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
      this.onPlayerState(state, player, song);
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

  /** AVPlayer 状态机推进（异步事件驱动） */
  private onPlayerState(state: string, player: media.AVPlayer, song: SongRecord): void {
    hilog.info(DOMAIN, TAG, 'state -> %{public}s', state);
    if (state === 'initialized') {
      player.prepare().catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'prepare failed: %{public}s', JSON.stringify(err));
      });
    } else if (state === 'prepared') {
      this.isPrepared = true;
      if (player.duration > 0) {
        this.duration = player.duration;
        if (isNetworkUrl(song.fileName)) {
          // 在线曲目不落本地库，直接改对象字段并整体替换数组引用刷新列表
          song.duration = player.duration;
          this.songs = this.songs.slice();
        } else {
          this.library.updateDuration(song.id, player.duration);
          // 数组元素字段非 @Trace，需整体替换引用以刷新列表时长显示
          this.songs = this.library.getAllSongs().slice();
        }
        this.rebuildIndex(this.songs);
        // 时长回填后再刷新一次媒体中心元数据（锁屏进度更准确）
        this.session.updateMetadata(song);
      }
      this.applyVolume();
      // 续播：先跳到断点再开播
      if (this.pendingSeekMs > 0 && (player.duration <= 0 || this.pendingSeekMs < player.duration)) {
        try {
          player.seek(this.pendingSeekMs);
          this.currentTime = this.pendingSeekMs;
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'resume seek failed: %{public}s', JSON.stringify(err));
        }
      }
      this.pendingSeekMs = 0;
      player.play().catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'play failed: %{public}s', JSON.stringify(err));
      });
    } else if (state === 'playing') {
      this.isPlaying = true;
      this.session.updatePlaybackState(true, this.currentTime, 1.0);
      this.session.startBackground();
    } else if (state === 'paused') {
      this.isPlaying = false;
      this.session.updatePlaybackState(false, this.currentTime, 1.0);
    } else if (state === 'completed') {
      this.onCompleted();
    } else if (state === 'error') {
      this.isPlaying = false;
    }
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
    if (index >= 0 && index === this.songs.length - 1 && this.playMode === PlayMode.SEQUENCE
      && this.playNextQueue.length === 0) {
      // 顺序播放到列表末尾且无插播：停止
      this.isPlaying = false;
      this.currentTime = 0;
      this.session.updatePlaybackState(false, 0, 1.0);
      this.session.stopBackground();
      this.persistState();
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
    if (this.currentFd >= 0) {
      try {
        fs.closeSync(this.currentFd);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'close fd: %{public}s', JSON.stringify(err));
      }
      this.currentFd = -1;
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
