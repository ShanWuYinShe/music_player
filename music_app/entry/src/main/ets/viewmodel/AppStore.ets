import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicLibrary } from '../library/MusicLibrary';
import { PlayerController } from '../player/PlayerController';
import { OnlineSource } from '../source/MusicSource';
import { UserData } from './UserData';

const TAG = 'AppStore';
const DOMAIN = 0x0004;

/** 颜色数值(0xAARRGGBB)转 setWindowBackgroundColor 接受的 #AARRGGBB 字符串 */
function toArgb(color: number): string {
  return `#${(color >>> 0).toString(16).padStart(8, '0')}`;
}

const PREF_NAME = 'music_player_settings';
const KEY_ONLINE_BASE_URL = 'online_base_url';

/**
 * 应用全局状态：组装音乐库、用户数据、播放内核与在线源配置。
 * 以单例导出，页面直接引用。
 */
@ObservedV2
export class AppStore {
  readonly library: MusicLibrary = new MusicLibrary();
  readonly userData: UserData = new UserData();
  readonly player: PlayerController;
  readonly onlineSource: OnlineSource = new OnlineSource();
  /** 主 Ability 上下文（页面取 window 设置系统栏样式用） */
  abilityContext: common.UIAbilityContext | null = null;
  /** 全局恒定全屏布局下的状态栏/导航条避让高度（vp），页面加载完成后读入 */
  @Trace safeTopVp: number = 0;
  @Trace safeBottomVp: number = 0;
  /** 在线源能力：网易云源是否启用/已登录（未登录时付费曲仅试听，在线页提示用） */
  @Trace neteaseEnabled: boolean = false;
  @Trace neteaseLoggedIn: boolean = false;
  private pref: preferences.Preferences | null = null;
  /** 在线源地址已变更待生效（首页 onPageShow 消费后重拉在线列表） */
  private onlineConfigDirty: boolean = false;

  constructor() {
    // 字段按声明顺序初始化，userData 先于 player 构造
    this.player = new PlayerController(this.library, this.userData);
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.abilityContext = context;
    this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    this.onlineSource.configuredUrl = this.pref.getSync(KEY_ONLINE_BASE_URL, '') as string;
    this.userData.init(this.pref);
    this.library.init(context);
    await this.player.init(context, this.pref);
  }

  /** 刷新在线源能力摘要（网易云登录态）；失败静默保留旧值（提示非关键路径） */
  async refreshOnlineProviders(): Promise<void> {
    try {
      const state = await this.onlineSource.fetchProviders();
      this.neteaseEnabled = state.neteaseEnabled;
      this.neteaseLoggedIn = state.neteaseLoggedIn;
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'fetch providers failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 窗口兜底色与系统栏字色随系统深浅模式自适应：按当前模式的资源值解析后应用。
   * 启动（EntryAbility.onWindowStageCreate）与系统配置变更（AppAbilityStage）
   * 时调用；播放页进入时覆盖为深色舞台沉浸态，退出时经本方法恢复自适应。
   */
  applyWindowChrome(): void {
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

  /** 保存在线源地址：存用户原始输入（trim），留空回落默认线上服务；值未变化不落盘 */
  saveOnlineBaseUrl(url: string): void {
    const trimmed = url.trim();
    if (trimmed === this.onlineSource.configuredUrl) {
      return;
    }
    this.onlineSource.configuredUrl = trimmed;
    this.onlineConfigDirty = true;
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
   */
  clearLibrary(): void {
    this.player.stopPlayback();
    this.player.clearPlayNextQueue();
    this.library.clearAll();
    this.userData.clearAll();
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
