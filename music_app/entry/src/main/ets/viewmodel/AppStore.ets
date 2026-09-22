import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import display from '@ohos.display';
import { MusicLibrary } from '../library/MusicLibrary';
import { PlayerController } from '../player/PlayerController';
import { OnlineSource } from '../source/MusicSource';
import { OnlineSongStore } from '../source/OnlineSongStore';
import { effectiveBaseUrl, isOnlineId } from '../source/OnlineApi';
import { SongRecord } from '../model/Song';
import { UserData } from './UserData';
import { writeFormState, FormPlaybackState, readFormIds, CARD_ACTION_EVENT, toCardPayload } from '../common/FormStateFile';
import { MicSpectrum } from '../common/MicSpectrum';

const TAG = 'AppStore';
const DOMAIN = 0x0004;

/** 颜色数值(0xAARRGGBB)转 setWindowBackgroundColor 接受的 #AARRGGBB 字符串 */
function toArgb(color: number): string {
  return `#${(color >>> 0).toString(16).padStart(8, '0')}`;
}

const PREF_NAME = 'music_player_settings';
const KEY_ONLINE_BASE_URL = 'online_base_url';
const KEY_MIC_LIVE = 'mic_live';
/** 卡片进度推送间隔：推送节流窗口 = 播放中自驱定时器周期（1s，用户决策：
 * 真机验证 TextTimer 卡片本地走秒不生效，回到主进程每秒推送驱动重绘；
 * 音频长时任务保活下后台 setInterval 可靠） */
const FORM_PROGRESS_PUSH_MS = 1000;

/**
 * 应用全局状态：组装音乐库、用户数据、播放内核与在线源配置。
 * 以单例导出，页面直接引用。
 */
@ObservedV2
export class AppStore {
  readonly library: MusicLibrary = new MusicLibrary();
  readonly userData: UserData = new UserData();
  /** 在线歌曲元数据注册表：收藏/播过的在线歌持久化（声明须先于 player，
   * constructor 构造播放内核时注入） */
  readonly onlineStore: OnlineSongStore = new OnlineSongStore();
  readonly player: PlayerController;
  readonly onlineSource: OnlineSource = new OnlineSource();
  /** 主 Ability 上下文（页面取 window 设置系统栏样式用） */
  abilityContext: common.UIAbilityContext | null = null;
  /** 播放页舞台沉浸标记：true 期间窗口 chrome 恒定深色舞台态——舞台底色
   * 恒深，系统切换深浅模式（AppAbilityStage 重应用 chrome）时不得把系统栏
   * 字色自适应成深字压在深舞台上（会不可见） */
  stageImmersion: boolean = false;
  /** 全局恒定全屏布局下的状态栏/导航条避让高度（vp），页面加载完成后读入 */
  @Trace safeTopVp: number = 0;
  @Trace safeBottomVp: number = 0;
  /** 网易云源是否已登录（未登录时付费曲仅试听：试听曲不进缓存、播放页标注试听） */
  @Trace neteaseLoggedIn: boolean = false;
  /** 服务端版本号缓存（/health 成功时更新，内存级）：设置页弱网重进时
   * 直接展示上次结果，不再停留「获取中…」 */
  serverVersionCache: string = '';
  /** 麦克风律动开关（设置页控制；start 失败/权限被拒自动回退 false） */
  @Trace micOn: boolean = false;
  /** 麦克风频谱采集单例（VisualizerView 舞台激活时启停，见 MicSpectrum） */
  readonly mic: MicSpectrum = new MicSpectrum();
  private pref: preferences.Preferences | null = null;
  /** 在线源地址已变更待生效（首页 onPageShow 消费后重拉在线列表） */
  private onlineConfigDirty: boolean = false;
  /** providers 摘要缓存时间戳（0 = 从未取过）与 TTL：登录态低频变化，
   * 进在线页不必每次都等一个 RTT */
  private providersFetchedAt: number = 0;
  private static readonly PROVIDERS_TTL_MS: number = 30000;
  /** 在途 providers 请求（同刻并发去重，避免重复打上游） */
  private providersInflight: Promise<void> | null = null;
  /** 最近一次进度锚点（timeUpdate 或状态事件）的墙钟时刻：后台 timeUpdate
   * 停报时按墙钟插值补齐快照位置用，不产生任何周期性工作 */
  private formTickBaseAt: number = 0;
  /** 上次卡片推送时间（播放中秒推节流窗口） */
  private lastFormPushAt: number = 0;
  /** 播放中卡片进度自驱定时器 id（-1 = 未启动） */
  private formTickerId: number = -1;
  /** 卡片控制指令订阅者（FormAbility 转发的 message 型按钮事件） */
  private cardSubscriber: commonEventManager.CommonEventSubscriber | null = null;

  constructor() {
    // 字段按声明顺序初始化，userData/onlineStore 先于 player 构造
    this.player = new PlayerController(this.library, this.userData, this.onlineStore);
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.abilityContext = context;
    this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    this.onlineSource.configuredUrl = this.pref.getSync(KEY_ONLINE_BASE_URL, '') as string;
    // 在线列表缓存目录：注入即恢复持久化的默认视图（杀进程重开秒开在线页）
    this.onlineSource.setCacheDir(context.filesDir);
    // 在线歌曲注册表：恢复收藏/播过的在线歌元数据——须先于 player.init，
    // 续播恢复（restoreLastSession）经 findSong 兜底查本表
    this.onlineStore.init(context.filesDir, this.onlineSource.baseUrl);
    this.micOn = this.pref.getSync(KEY_MIC_LIVE, false) as boolean;
    this.userData.init(this.pref);
    this.library.init(context);
    // VIP 未登录试听片段不得进整曲缓存：登录后同一 key 会返回完整音频，
    // 试听字节将污染缓存。闭包实时读取登录态，登录变化即时生效
    this.player.isOnlineCacheable = (song) => !(song.vip === true && !this.neteaseLoggedIn);
    await this.player.init(context, this.pref);
    // 桌面卡片状态同步：状态变化（播控/切歌/seek）即时推送 + 播放中每秒
    // 自驱推送一次（含 anchorAt 墙钟锚点，推送到达延迟时卡片显示仍准）。
    // 真机踩坑：TextTimer 在卡片上不会走秒（onTimer 不触发），卡片无法
    // 自驱重绘，只能靠主进程推送驱动；timeUpdate 后台停报，秒推由
    // 自驱定时器承担（音频长时任务保活），timeUpdate 仅刷新插值锚点
    this.player.addStateListener((reason: string) => this.syncFormState());
    this.player.progressListener = () => {
      this.formTickBaseAt = Date.now();
    };
    // 收藏的在线歌恢复钉住并补下载（上次未下完的整曲续传，不随切歌中止）
    this.syncOnlinePins();
    this.syncFormState();
    this.subscribeCardActions();
  }

  /**
   * 统一收藏入口（PlayerPage ♥ 按钮）：UserData 记账 + 在线歌注册表同步
   * ——收藏即注册元数据（重启后喜欢列表可见可播）并钉住缓存、主动整曲
   * 下载；取消收藏解除钉住（已下音频回归普通 LRU）。本地曲目仅记账。
   */
  toggleFavorite(song: SongRecord): boolean {
    const fav = this.userData.toggleFavorite(song.id);
    if (isOnlineId(song.id)) {
      if (fav) {
        this.onlineStore.upsert(song);
      }
      // 注册表只留收藏 ∪ 最近引用的在线歌（孤儿条目删除）
      const keep = new Set<string>();
      for (const id of this.userData.favoriteIds.concat(this.userData.recentIds)) {
        if (isOnlineId(id)) {
          keep.add(id);
        }
      }
      this.onlineStore.retain(keep);
      this.syncOnlinePins();
    }
    return fav;
  }

  /** 收藏的在线歌（经注册表取元数据）→ 播放内核钉住缓存并补下载 */
  private syncOnlinePins(): void {
    const songs: SongRecord[] = [];
    for (const id of this.userData.favoriteIds) {
      const song = this.onlineStore.get(id);
      if (song !== null) {
        songs.push(song);
      }
    }
    this.player.syncOnlinePins(songs);
  }

  /**
   * 订阅卡片控制指令（FormAbility 把 message 型按钮点击以公共事件转发
   * 过来）：主进程存活即可后台响应播放控制，不拉起前台界面。
   */
  private subscribeCardActions(): void {
    const ctx = this.abilityContext;
    if (ctx === null) {
      return; // 无 context 无法限定发布方（init 时序保证此处已注入）
    }
    const subscriber = commonEventManager.createSubscriberSync({
      events: [CARD_ACTION_EVENT],
      // 只收本应用的卡片指令，屏蔽第三方伪造的公共事件
      publisherBundleName: ctx.applicationInfo.name
    });
    commonEventManager.subscribe(subscriber, (err, data) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'card action subscribe failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.dispatchCardAction(String(data.data));
    });
    this.cardSubscriber = subscriber;
    hilog.info(DOMAIN, TAG, 'card action subscriber registered');
  }

  /** 卡片播放控制指令唯一分派（call 指令与公共事件两条链路共用） */
  dispatchCardAction(method: string): void {
    if (method === 'toggle') {
      this.player.togglePlay();
    } else if (method === 'next') {
      this.player.next();
    } else if (method === 'previous') {
      this.player.previous();
    }
  }

  /** 应用销毁时退订卡片指令事件并撤秒推定时器（EntryAbility.onDestroy 调用） */
  disposeCardBridge(): void {
    this.stopFormTicker();
    if (this.cardSubscriber !== null) {
      commonEventManager.unsubscribe(this.cardSubscriber, (err) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'card unsubscribe failed: %{public}s', JSON.stringify(err));
        }
      });
      this.cardSubscriber = null;
    }
  }

  private stopFormTicker(): void {
    if (this.formTickerId >= 0) {
      clearInterval(this.formTickerId);
      this.formTickerId = -1;
    }
  }

  /**
   * 麦克风律动开关（设置页调用）：开启时请求 MICROPHONE 权限并启动采集，
   * 权限被拒/无麦克风（模拟器）自动回退 false 返回 false；关闭时停止采集。
   */
  async setMicLive(on: boolean): Promise<boolean> {
    const ctx = this.abilityContext;
    if (ctx === null) {
      return false;
    }
    if (on) {
      try {
        // Stage 模型权限请求入口是 AtManager（UIAbilityContext 上的同名方法
        // 是 FA 模型遗留，本 SDK 不可用）
        const atManager = abilityAccessCtrl.createAtManager();
        const result = await atManager.requestPermissionsFromUser(ctx,
          ['ohos.permission.MICROPHONE']);
        if (result.authResults.length === 0 || result.authResults[0] !== 0) {
          this.persistMicLive(false);
          return false;
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'request mic permission failed: %{public}s', JSON.stringify(err));
        this.persistMicLive(false);
        return false;
      }
      const started = await this.mic.start();
      if (!started) {
        this.persistMicLive(false);
        return false;
      }
      this.persistMicLive(true);
      this.player.notifyPrefs();
      return true;
    }
    await this.mic.stop();
    this.persistMicLive(false);
    this.player.notifyPrefs();
    return true;
  }

  private persistMicLive(on: boolean): void {
    this.micOn = on;
    if (this.pref !== null) {
      this.pref.putSync(KEY_MIC_LIVE, on);
      this.pref.flush().catch(() => {});
    }
  }

  /**
   * 桌面卡片状态同步（主进程 → FormExtension 进程）。推送由两类事件驱动：
   * 状态变化（播控/切歌/seek/失败停止等）即时推送；播放中自驱定时器每秒
   * 触发 'progress' 推送并按 FORM_PROGRESS_PUSH_MS 节流（真机验证 TextTimer
   * 在卡片上不走秒，卡片重绘只能靠推送驱动；音频长时任务保活下后台
   * setInterval 可靠）。快照位置按墙钟自锚点插值——锚点由 timeUpdate/
   * 状态事件刷新，真机后台 timeUpdate 停报时插值仍能给出准确位置；暂停/
   * 切歌即重锚，位置夹在时长内。payload 带 anchorAt（采样时刻），推送
   * 到达有延迟时卡片显示仍准。推送失败静默（桌面服务不可用不影响播放）。
   */
  private syncFormState(reason: string = 'state'): void {
    const ctx = this.abilityContext;
    if (ctx === null) {
      return;
    }
    // 墙钟外推：真机后台 timeUpdate 停报时 currentTime 冻结，按上次采样
    // 锚点补齐增量卡片进度才走准；算完即把本次采样设为新锚点（暂停/切歌
    // 事件走不到外推分支、顺带重锚，不会把暂停期墙钟差计入）
    const sampledAt = Date.now();
    let position = this.player.currentTime;
    if (this.player.isPlaying && this.formTickBaseAt > 0) {
      position += Math.max(0, sampledAt - this.formTickBaseAt);
    }
    this.formTickBaseAt = sampledAt;
    const song = this.player.currentSong;
    const duration = this.player.duration;
    if (duration > 0 && position > duration) {
      position = duration;
    }
    const state: FormPlaybackState = {
      title: song !== null ? song.title : '',
      artist: song !== null ? song.artist : '',
      coverPath: song !== null ? song.coverPath : '',
      playing: this.player.isPlaying,
      positionMs: Math.floor(position),
      durationMs: Math.floor(duration),
      progress: duration > 0 ? Math.min(1, position / duration) : 0,
      anchorAt: Date.now()
    };
    const now = Date.now();
    if (reason === 'progress' && now - this.lastFormPushAt < FORM_PROGRESS_PUSH_MS) {
      return;
    }
    this.lastFormPushAt = now;
    writeFormState(ctx.filesDir, state);
    // 卡片实例 id 由 FormAbility.onAddForm 登记（跨进程文件共享）
    const formIds = readFormIds(ctx.filesDir);
    for (const formId of formIds) {
      formProvider.updateForm(formId, formBindingData.createFormBindingData(toCardPayload(state)))
        .catch(() => {
          // 卡片可能刚被移除，忽略单实例失败
        });
    }
    // 推送节奏诊断日志降 debug：生产路径不再每秒刷 info（排查卡片时
    // hilog -L debug | grep formPush 仍可用）
    hilog.debug(DOMAIN, TAG, 'formPush pos=%{public}d playing=%{public}s reason=%{public}s',
      Math.floor(position), String(this.player.isPlaying), reason);
    // 定时器随播放态启停：暂停/停止即撤
    if (this.player.isPlaying) {
      if (this.formTickerId < 0) {
        this.formTickerId = setInterval(() => this.syncFormState('progress'), FORM_PROGRESS_PUSH_MS);
      }
    } else {
      this.stopFormTicker();
    }
  }

  /**
   * 重读状态栏/导航条避让高度：启动后页面加载完成、以及系统配置变更
   * （旋转/折叠展开，AppAbilityStage 回调）时调用——避让值不随窗口
   * 自动刷新，过期会造成布局错位。
   */
  readSafeArea(): void {
    const ctx = this.abilityContext;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win) => {
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const density = display.getDefaultDisplaySync().densityPixels;
      this.safeTopVp = sys.topRect.height / density;
      this.safeBottomVp = nav.bottomRect.height / density;
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'read safe area failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 刷新在线源能力摘要（网易云登录态）；失败静默保留旧值（标注非关键路径）。
   * TTL 缓存 + 在途去重：登录态低频变化，进在线页不必每次都等一个 RTT；
   * force=true 绕过缓存（设置页保存地址后主动刷新） */
  async refreshOnlineProviders(force: boolean = false): Promise<void> {
    if (!force && Date.now() - this.providersFetchedAt < AppStore.PROVIDERS_TTL_MS) {
      return;
    }
    if (this.providersInflight !== null) {
      return this.providersInflight;
    }
    const task = (async (): Promise<void> => {
      try {
        const state = await this.onlineSource.fetchProviders();
        this.neteaseLoggedIn = state.neteaseLoggedIn;
        this.providersFetchedAt = Date.now();
      } catch (err) {
        hilog.info(DOMAIN, TAG, 'fetch providers failed: %{public}s', JSON.stringify(err));
      } finally {
        this.providersInflight = null;
      }
    })();
    this.providersInflight = task;
    return task;
  }

  /**
   * 窗口兜底色与系统栏字色的唯一出口：播放页舞台沉浸期间恒定深色舞台态，
   * 其余时候按当前系统模式的资源值自适应。启动（EntryAbility）、系统配置
   * 变更（AppAbilityStage）与播放页进出（PlayerPage 经 stageImmersion 标记）
   * 都经本方法应用。
   */
  applyWindowChrome(): void {
    if (this.stageImmersion) {
      this.applyStageChrome();
      return;
    }
    const ctx = this.abilityContext;
    if (ctx === null) {
      return;
    }
    const bg = ctx.resourceManager.getColorSync($r('app.color.page_bg').id);
    const ink = ctx.resourceManager.getColorSync($r('app.color.ink').id);
    window.getLastWindow(ctx).then((win) => {
      win.setWindowBackgroundColor(toArgb(bg));
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: toArgb(ink),
        navigationBarContentColor: toArgb(ink)
      });
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'apply window chrome failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 播放页舞台沉浸态 chrome：舞台恒定深底，兜底色与系统栏字色固定深底浅字 */
  private applyStageChrome(): void {
    const ctx = this.abilityContext;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win) => {
      win.setWindowBackgroundColor('#0C0B0A');
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#EFEBDE',
        navigationBarContentColor: '#EFEBDE'
      });
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'apply stage chrome failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 保存在线源地址：存用户原始输入（trim），留空回落默认线上服务；值未变化不落盘 */
  saveOnlineBaseUrl(url: string): void {
    const trimmed = url.trim();
    if (trimmed === this.onlineSource.configuredUrl) {
      return;
    }
    this.onlineSource.configuredUrl = trimmed;
    this.onlineConfigDirty = true;
    // 地址变更即 providers 缓存失效：换服务端后登录态可能不同
    this.providersFetchedAt = 0;
    // 注册表条目流地址按新生效地址重拼（服务端 id 稳定，收藏/续播直达新服）
    this.onlineStore.setBaseUrl(effectiveBaseUrl(trimmed));
    if (this.pref) {
      try {
        this.pref.putSync(KEY_ONLINE_BASE_URL, trimmed);
        this.pref.flush().catch((err: Object) => {
          hilog.warn(DOMAIN, TAG, 'flush online base url failed: %{public}s', JSON.stringify(err));
        });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'save online base url failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  /** 查询并清除「地址已变更」标志：返回 true 表示调用方应重拉在线列表 */
  consumeOnlineConfigDirty(): boolean {
    const dirty = this.onlineConfigDirty;
    this.onlineConfigDirty = false;
    return dirty;
  }

  /**
   * 清空曲库：先停播放（释放当前 fd），再删文件与索引、清用户数据。
   * 收藏/最近随之清空，在线注册表条目成孤儿一并清掉、缓存钉住解除
   * （已下音频回归普通 LRU，不删文件）。
   */
  /** 曲库已被清空（设置页危险操作）：页面在导航返回时消费此标志，把
   * 最近冻结快照等派生态失效——跨页通知走标志而非事件，与在线配置变更
   * 同一套模式 */
  private libraryCleared = false;

  consumeLibraryCleared(): boolean {
    const cleared = this.libraryCleared;
    this.libraryCleared = false;
    return cleared;
  }

  clearLibrary(): void {
    this.libraryCleared = true;
    this.player.stopPlayback();
    this.player.clearPlayNextQueue();
    this.library.clearAll();
    this.userData.clearAll();
    this.onlineStore.retain(new Set<string>());
    this.player.syncOnlinePins([]);
    this.player.refreshSongs();
  }

  /** 退出前台前同步持久化播放会话 */
  persistAll(): void {
    try {
      this.player.persistState();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persistAll failed: %{public}s', JSON.stringify(err));
    }
  }
}

/** 全局单例 */
export const appStore: AppStore = new AppStore();
