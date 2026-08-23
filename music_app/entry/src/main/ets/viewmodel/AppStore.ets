import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicLibrary } from '../library/MusicLibrary';
import { PlayerController } from '../player/PlayerController';
import { OnlineSource } from '../source/MusicSource';
import { UserData } from './UserData';

const TAG = 'AppStore';
const DOMAIN = 0x0004;

const PREF_NAME = 'music_player_settings';
const KEY_ONLINE_BASE_URL = 'online_base_url';

/**
 * 应用全局状态：组装音乐库、用户数据、播放内核与在线源配置。
 * 以单例导出，页面直接引用。
 */
export class AppStore {
  readonly library: MusicLibrary = new MusicLibrary();
  readonly userData: UserData = new UserData();
  readonly player: PlayerController;
  readonly onlineSource: OnlineSource = new OnlineSource();
  private pref: preferences.Preferences | null = null;

  constructor() {
    // 字段按声明顺序初始化，userData 先于 player 构造
    this.player = new PlayerController(this.library, this.userData);
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    this.onlineSource.configuredUrl = this.pref.getSync(KEY_ONLINE_BASE_URL, '') as string;
    this.userData.init(this.pref);
    this.library.init(context);
    await this.player.init(context, this.pref);
  }

  /** 保存在线源地址：存用户原始输入（trim），留空回落默认线上服务 */
  saveOnlineBaseUrl(url: string): void {
    this.onlineSource.configuredUrl = url.trim();
    if (this.pref) {
      this.pref.putSync(KEY_ONLINE_BASE_URL, this.onlineSource.configuredUrl);
      this.pref.flush();
    }
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
