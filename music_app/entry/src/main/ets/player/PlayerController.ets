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
import { OnlineCache } from './OnlineCache';
import { OnlineSongStore } from '../source/OnlineSongStore';

const TAG = 'PlayerController';
const DOMAIN = 0x0003;

const KEY_LAST_SONG = 'last_song_id';
const KEY_LAST_POS = 'last_position_ms';
const KEY_PLAY_MODE = 'play_mode';

/** 连续播放失败熔断阈值：达到后停止自动跳过（防全队列不可播时死循环） */
const ERROR_STREAK_LIMIT = 3;

/** 判定 fileName 是否为网络流地址（http/https，在线曲目由 OnlineSource 生成） */
function isNetworkUrl(fileName: string): boolean {
  return fileName.startsWith('http://') || fileName.startsWith('https://');
}

/** 封面预览（路径+种子+歌名）：播放页纸带拖动时展示隔壁封面用，
 * 无封面时占位显示歌名首字。注意 V2 规则——对象字面量必须对应
 * interface，构造一律走 coverRefOf */
export interface CoverRef {
  path: string;
  seed: string;
  /** 歌名（占位首字来源） */
  title: string;
}

/** 构造 CoverRef（song 为 null 即无预览） */
function coverRefOf(song: SongRecord | null): CoverRef | null {
  if (song === null) {
    return null;
  }
  return { path: song.coverPath, seed: song.id, title: song.title };
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
  /** 在线音频整曲缓存：复播走本地 fd，不重复耗流量（init 时传入 context） */
  private onlineCache: OnlineCache = new OnlineCache();
  /** 在线歌曲元数据注册表（AppStore 注入）：播放查找兜底 + 播过/收藏的
   * 在线歌 upsert（重启后喜欢/最近列表补位、续播恢复都靠它） */
  private onlineStore: OnlineSongStore;
  /** 在线曲目是否允许进缓存：VIP 未登录试听片段不得缓存（登录后试听字节
   * 会污染完整音频），由 AppStore 按网易云登录态注入，默认全允许 */
  isOnlineCacheable: (song: SongRecord) => boolean = () => true;
  /** 当前队列 id → SongRecord 索引（本地曲库或在线列表），playSong/currentSong 查找用 */
  private songIndex: Map<string, SongRecord> = new Map();
  /** 播放失败提示回调（页面注入 promptAction），null 时静默 */
  onPlaybackError: ((message: string) => void) | null = null;
  /** 播放进度秒针回调（AVPlayer timeUpdate 透传）：AppStore 注册用于
   * 桌面卡片进度节流推送；UI 不走此通道（页面经 displaySync 拉取） */
  progressListener: ((positionMs: number) => void) | null = null;
  /** 播放状态变化订阅（切歌/启停）：真机上经 @ObservedV2/@Computed 的 UI
   * 依赖对本实例不触发（仅 Text 内容插值存活，已实测），页面靠订阅维护
   * @Local 镜像驱动渲染；reason 语义：'song'=队列/曲目变化（需重建列表），
   * 'playing'=启停变化（需重建列表当前行），'prefs'=偏好变化（音量/模式/
   * 定时器，无需重建列表），'state'=其他 */
  private stateListeners: Set<(reason: string) => void> = new Set();

  addStateListener(fn: (reason: string) => void): void {
    this.stateListeners.add(fn);
  }

  removeStateListener(fn: (reason: string) => void): void {
    this.stateListeners.delete(fn);
  }

  private notifyState(reason: string = 'state'): void {
    for (const fn of this.stateListeners) {
      fn(reason);
    }
  }

  /** 偏好变化广播（AppStore 设置项变更时调用，如麦克风律动开关）：
   * 走现有状态订阅管道刷新各页面的 @Local 镜像 */
  notifyPrefs(): void {
    this.notifyState('prefs');
  }
  /** 连续播放失败计数：任一曲 prepared 成功即清零 */
  private errorStreak: number = 0;
  /** 已处理播放失败的代际号：error 事件与 stateChange(error) 双入口去重 */
  private failureGen: number = -1;

  constructor(library: MusicLibrary, userData: UserData, onlineStore: OnlineSongStore) {
    this.library = library;
    this.userData = userData;
    this.onlineStore = onlineStore;
  }

  /**
   * 同步收藏钉住与补下载（AppStore 在启动恢复、收藏切换、清空曲库后调用）：
   * favoriteSongs 为当前仍收藏的在线曲目（元数据来自注册表）——整表替换
   * 缓存 pin 集合；未缓存且允许缓存（VIP 未登录试听除外）的排队整曲下载。
   */
  syncOnlinePins(favoriteSongs: SongRecord[]): void {
    const pinned = new Set<string>();
    for (const song of favoriteSongs) {
      pinned.add(song.id);
      if (!this.onlineCache.has(song.id) && this.isOnlineCacheable(song)) {
        // 收藏下载不随切歌中止（与播放伴随下载不同）
        this.onlineCache.prefetch(song.id, song.fileName, () => true);
      }
    }
    this.onlineCache.setPinned(pinned);
  }

  /** 应用启动时初始化（UIAbility onCreate 调用） */
  async init(context: common.UIAbilityContext, pref: preferences.Preferences | null): Promise<void> {
    this.context = context;
    this.pref = pref;
    this.onlineCache.init(context);
    this.refreshSongs();
    this.restorePlayMode();
    this.restoreLastSession();
    await this.session.init(context, this.buildHandlers());
  }

  /** 应用退出时释放资源并持久化会话状态 */
  async destroy(): Promise<void> {
    this.generation++;
    this.cancelSleepTimer();
    this.onlineCache.flush(); // 落盘节流攒下的 lastAccess 刷盘（后台/退出钩子）
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

  /** 队列查找（含当前播放但不在列表的条目），找不到返回 null；UI 队列展示用 */
  getSong(id: string): SongRecord | null {
    return this.findSong(id);
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

  /** 从插播队列移除单曲（队列面板行长按入口；id 不在队列时无操作） */
  removePlayNext(id: string): void {
    this.playNextQueue = this.playNextQueue.filter((item) => item !== id);
  }

  /** 点击列表项播放指定曲目（手动动作：清熔断计数，重新开始计数） */
  playSong(id: string): void {
    this.errorStreak = 0;
    this.playSongInternal(id);
  }

  /** 切歌实装：自动链路（失败跳过/播完连播/插播）走此入口，不碰熔断计数，
   * 否则自动跳过每次清零会导致连续失败永远达不到熔断阈值 */
  private playSongInternal(id: string): void {
    const song = this.findSong(id);
    if (!song) {
      hilog.warn(DOMAIN, TAG, 'playSong: song not found %{public}s', id);
      return;
    }
    this.currentSongId = id;
    // 新曲从 0 起显示：加载期（prepared 前）currentTime 若残留上一首位置，
    // 会以新曲标题短暂显示旧进度并被卡片插值放大
    this.currentTime = 0;
    this.notifyState('song');
    this.pendingSeekMs = 0;
    this.userData.addRecent(id);
    if (isNetworkUrl(song.fileName)) {
      // 播过的在线歌注册元数据：重启后最近播放列表补位、续播可恢复
      this.onlineStore.upsert(song);
    }
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

  /** 下一首（手动操作，单曲循环模式下同样切歌）；优先消费插播队列。
   * 迷你条/播放页/锁屏调的都是此入口，语义即手动，清熔断计数 */
  next(): void {
    this.errorStreak = 0;
    this.autoNext();
  }

  /** 内部自动前进（失败跳过/播完连播）：原 next 逻辑，不碰熔断计数 */
  private autoNext(): void {
    if (this.songs.length === 0) {
      return;
    }
    const queuedId = this.shiftQueuedExisting();
    if (queuedId !== '') {
      this.playSongInternal(queuedId);
      return;
    }
    const index = this.currentIndex();
    if (index < 0) {
      this.playSongInternal(this.songs[0].id);
      return;
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      this.playSongInternal(this.songs[this.randomIndex(index)].id);
      return;
    }
    const nextIndex = (index + 1) % this.songs.length;
    this.playSongInternal(this.songs[nextIndex].id);
  }

  /** 上一首（手动操作，清熔断计数） */
  previous(): void {
    this.errorStreak = 0;
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

  /** 相邻封面预览（播放页 pager 用）：只做"展示用"的尽力预判——插播头/
   * 顺序/单曲可确定；随机模式掷骰在切歌瞬间，预判必错直接给 null（子组件
   * 无预览退化为淡入）；上一首不含 5 秒回曲首规则（那是释放后的对账事，
   * 子组件拿返回值 'same' 回弹）。纯读状态，无副作用 */
  peekNextCover(): CoverRef | null {
    if (this.songs.length === 0) {
      return null;
    }
    // 插播队列：跳过已失效 id，取首个仍存在的（与 shiftQueuedExisting 同语义）
    for (const id of this.playNextQueue) {
      const queued = this.findSong(id);
      if (queued) {
        return coverRefOf(queued);
      }
    }
    const index = this.currentIndex();
    if (index < 0) {
      return coverRefOf(this.songs[0]);
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      return null;
    }
    return coverRefOf(this.songs[(index + 1) % this.songs.length]);
  }

  /** 上一首预览（previous 不消费插播队列，纯按索引；随机给 null）。
   * 含 5 秒回曲首规则：播放超 5 秒右滑只回曲首不换轨，此时无预览
   * （与 previous() 语义对齐，释放后 'same' 回弹才不显得 preview 在骗人） */
  peekPrevCover(): CoverRef | null {
    if (this.songs.length === 0) {
      return null;
    }
    const index = this.currentIndex();
    if (index < 0) {
      return coverRefOf(this.songs[0]);
    }
    if (this.playMode === PlayMode.SHUFFLE) {
      return null;
    }
    if (this.currentTime > 5000) {
      return null;
    }
    return coverRefOf(this.songs[(index - 1 + this.songs.length) % this.songs.length]);
  }

  /** 循环切换播放模式并持久化（播放页依赖此 notify 刷新模式图标） */
  cyclePlayMode(): void {
    this.playMode = nextPlayMode(this.playMode);
    this.persistState();
    this.notifyState('prefs');
  }

  /** 进度拖拽（毫秒）；拖完即持久化断点，拖动后直接杀进程也不丢进度。
   * seek 是进度不连续跳变，必须即时广播：卡片/锁屏都靠锚点外推，
   * 不推会从旧锚点继续推算出错误进度（仅在点击与拖动结束时触发） */
  seek(positionMs: number): void {
    if (this.player && this.isPrepared) {
      try {
        this.player.seek(positionMs);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', JSON.stringify(err));
      }
      this.currentTime = positionMs;
      this.session.updatePlaybackState(this.isPlaying, positionMs, 1.0);
      this.notifyState('seek');
      this.persistState();
    }
  }

  /** 相对跳转（秒）：耳机长按快进/快退入口；秒数缺省或非法兜底 15 秒，
   * 终点夹取在 [0, duration] 内（seek 自身对未 prepared 无操作） */
  seekBy(offsetSec?: number): void {
    const offset = offsetSec !== undefined && offsetSec > 0 ? offsetSec : 15;
    const limit = this.duration > 0 ? this.duration : 0;
    const target = Math.min(Math.max(this.currentTime + offset * 1000, 0), limit);
    this.seek(Math.floor(target));
  }

  /** 设置音量（0~1），对后续曲目同样生效（播放页依赖此 notify 刷新音量条） */
  setVolume(value: number): void {
    const clamped = Math.min(1, Math.max(0, value));
    this.volume = clamped;
    this.applyVolume();
    this.notifyState('prefs');
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

  /** 启动定时关闭（分钟）：每秒 tick 只自增 @Trace 不 notify——倒计时 Text
   * 直读本字段走内容插值（真机存活的唯一路径，播放页属性态走镜像），
   * 每秒 notify 会放大成全部订阅方重建；启停两处末尾 notify 供镜像对齐 */
  startSleepTimer(minutes: number): void {
    this.cancelSleepTimer();
    this.sleepRemainSec = Math.max(1, Math.round(minutes * 60));
    this.notifyState('prefs');
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
    this.notifyState('prefs');
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
    // 状态全部落定后统一广播：中途广播会把"无曲目但 playing=true"的
    // 中间态推给卡片，且此后再无通知，卡片残留不一致显示
    this.notifyState('song');
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
      // flush 异步落盘：失败捕获记日志，避免 unhandled rejection（与
      // AppStore.saveOnlineBaseUrl / UserData.persist 同模式）
      this.pref.flush().catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'persist state flush failed: %{public}s', JSON.stringify(err));
      });
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
    this.notifyState();
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

  /** 队列查找：当前队列索引优先，本地曲库兜底（启动恢复等场景），
   * 在线注册表末位兜底（收藏/最近里的在线歌不在前两者时的点播与续播恢复） */
  private findSong(id: string): SongRecord | null {
    if (id === '') {
      return null;
    }
    return this.songIndex.get(id) ?? this.library.getSongById(id) ?? this.onlineStore.get(id);
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
        // 在线曲目：命中整曲缓存即走本地 fd（复播秒开、不重复耗流量），
        // fd 生命周期与本地文件一致（release 时关闭）；未命中播 http 流，
        // 同时后台整曲下载落盘供下次命中。首播体验无退化
        const cachedPath = this.isOnlineCacheable(song) ? this.onlineCache.lookup(song.id) : '';
        if (cachedPath !== '') {
          const file = fs.openSync(cachedPath, fs.OpenMode.READ_ONLY);
          this.currentFd = file.fd;
          player.url = `fd://${file.fd}`;
        } else {
          player.url = song.fileName;
          if (this.isOnlineCacheable(song)) {
            const streamUrl = song.fileName;
            const cacheKey = song.id;
            const cacheGen = gen;
            this.onlineCache.prefetch(cacheKey, streamUrl, () => cacheGen === this.generation);
          }
        }
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
      // openSync 成功后 url 赋值/元数据更新抛错会留下已打开的 fd：此处回收，
      // 代际号过期（已有新切歌接管 currentFd）时不得关闭新曲的 fd
      if (gen === this.generation && this.currentFd >= 0) {
        try {
          fs.closeSync(this.currentFd);
        } catch (closeErr) {
          hilog.warn(DOMAIN, TAG, 'close leaked fd: %{public}s', JSON.stringify(closeErr));
        }
        this.currentFd = -1;
      }
      this.isPlaying = false;
      this.handlePlaybackFailure(gen, song, '加载失败');
    }
  }

  /**
   * 播放失败统一处理：提示 + 自动跳下一首（在线曲目 404 无版权/网络中断/
   * 本地文件损坏等场景此前完全无反馈）。同一代际只处理一次（error 事件与
   * stateChange(error) 双入口）；连续失败达到熔断阈值后停止，防止全队列
   * 不可播时无限循环切歌。
   */
  private handlePlaybackFailure(gen: number, song: SongRecord, reason: string): void {
    if (gen !== this.generation || gen === this.failureGen) {
      return;
    }
    this.failureGen = gen;
    this.errorStreak += 1;
    this.isPlaying = false;
    // 会话侧同步暂停态：失败可能发生在 playing 之后（如播放中网络中断），
    // 漏推会让实况窗/锁屏停留"播放中"却无声
    this.session.updatePlaybackState(false, this.currentTime, 1.0);
    // 停播必须广播：熔断分支不再经过切歌通知，漏推会让卡片停留
    // "播放中"图标与冻结进度（自动跳过分支由后续切歌通知覆盖，此通知冗余无害）
    this.notifyState('playing');
    if (this.errorStreak >= ERROR_STREAK_LIMIT) {
      this.onPlaybackError?.(`「${song.title}」${reason}，已连续 ${this.errorStreak} 首无法播放，停止尝试`);
      hilog.warn(DOMAIN, TAG, 'error streak limit reached, stop auto-skip');
      return; // 保留现场：用户可手动重试或切歌
    }
    this.onPlaybackError?.(`「${song.title}」${reason}，已跳过`);
    this.autoNext();
  }

  private registerPlayerEvents(player: media.AVPlayer, gen: number, song: SongRecord): void {
    player.on('stateChange', (state: string) => {
      if (gen !== this.generation) {
        return;
      }
      this.onPlayerState(state, player, song, gen);
    });
    player.on('timeUpdate', (time: number) => {
      if (gen !== this.generation) {
        return;
      }
      this.currentTime = time;
      if (this.progressListener !== null) {
        this.progressListener(time);
      }
    });
    player.on('error', (err) => {
      hilog.error(DOMAIN, TAG, 'AVPlayer error: %{public}s', JSON.stringify(err));
      // 具体跳过/熔断逻辑统一走 stateChange(error)；此处仅兜底（个别错误
      // 只回调 error 不迁移状态时也能反馈），代际去重防双触发。
      this.handlePlaybackFailure(gen, song, '播放失败');
    });
  }

  /** AVPlayer 状态机推进（异步事件驱动） */
  private onPlayerState(state: string, player: media.AVPlayer, song: SongRecord, gen: number): void {
    hilog.info(DOMAIN, TAG, 'state -> %{public}s', state);
    if (state === 'initialized') {
      player.prepare().catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'prepare failed: %{public}s', JSON.stringify(err));
        // prepare 异步失败同样走统一失败处理（代际去重防与 error 事件双触发）
        this.handlePlaybackFailure(gen, song, '加载失败');
      });
    } else if (state === 'prepared') {
      this.isPrepared = true;
      this.errorStreak = 0; // 任一曲加载成功即解除熔断计数
      if (player.duration > 0 && player.duration !== song.duration) {
        // 仅在「首次获得时长」（原值为 0）时才整体替换数组并广播刷新：
        // @Trace 数组元素字段变化不触发 UI（已踩坑），整刷会让大曲库下
        // 每次切歌都全量重建列表；时长已知（非 0）的曲目直接跳过。
        const firstDuration = song.duration <= 0;
        this.duration = player.duration;
        if (isNetworkUrl(song.fileName)) {
          // 在线曲目不落本地库，直接改对象字段并整体替换数组引用刷新列表
          song.duration = player.duration;
          this.songs = this.songs.slice();
        } else {
          this.library.updateDuration(song.id, player.duration);
          // 保序刷新：队列可能是最近/喜欢快照或在线列表，直接换成曲库会
          // 让切歌走到别的顺序（真机报障：最近签左滑右滑乱跳）。队列与曲库
          // 共享 SongRecord 引用，updateDuration 已就地更新，只需替换数组
          // 引用触发 @Trace（元素字段本身非 @Trace）；防御性再直写一次。
          song.duration = player.duration;
          this.songs = this.songs.slice();
        }
        if (firstDuration) {
          this.rebuildIndex(this.songs);
          // 时长属 SongRecord 普通字段，列表 '--:--' → 时长的刷新须广播：
          // 在线列表展示已与队列解耦（Index.onlineSongs 直持对象引用），
          // 数组替换不再触发其重算，订阅方收到 'song' 后 reload 兜底
          this.notifyState('song');
        }
      } else if (player.duration > 0) {
        this.duration = player.duration;
      }
      // 时长回填后刷新媒体中心元数据（锁屏标题/封面/时长保持准确）
      this.session.updateMetadata(song);
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
        // prepared 成功后 play 异步失败同样走统一失败处理（熔断计数保留：
        // prepared 已清零，此处失败从 0 起计）
        this.handlePlaybackFailure(gen, song, '播放失败');
      });
    } else if (state === 'playing') {
      this.isPlaying = true;
      this.notifyState('playing');
      this.session.updatePlaybackState(true, this.currentTime, 1.0);
      this.session.startBackground();
    } else if (state === 'paused') {
      this.isPlaying = false;
      this.notifyState('playing');
      this.session.updatePlaybackState(false, this.currentTime, 1.0);
    } else if (state === 'completed') {
      this.onCompleted();
    } else if (state === 'error') {
      // 在线无版权/网络中断/本地文件损坏：统一走提示+跳过（代际去重）
      this.handlePlaybackFailure(gen, song, '无法播放');
    }
  }

  /** 一曲播完，按播放模式决定后续行为 */
  private onCompleted(): void {
    if (this.playMode === PlayMode.SINGLE) {
      // 单曲循环不再吞插播：有插播先消费插播，否则回到曲首重播
      const queuedId = this.shiftQueuedExisting();
      if (queuedId !== '') {
        this.playSongInternal(queuedId);
        return;
      }
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
      // 此路径不经 stateChange/切歌通知，漏广播会让卡片停留播放中+冻结进度
      this.notifyState('playing');
      return;
    }
    this.autoNext();
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

  onFastForward(time?: number): void {
    this.controller.seekBy(time);
  }

  onRewind(time?: number): void {
    this.controller.seekBy(time === undefined ? undefined : -time);
  }
}
