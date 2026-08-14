import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MusicLibrary } from '../library/MusicLibrary';
import { PlayerController } from '../player/PlayerController';
import { OnlineSource } from '../source/MusicSource';

const PREF_NAME = 'music_player_settings';
const KEY_ONLINE_BASE_URL = 'online_base_url';

/**
 * 应用全局状态：组装音乐库、播放内核与在线源配置。
 * 以单例导出，页面直接引用。
 */
export class AppStore {
  readonly library: MusicLibrary = new MusicLibrary();
  readonly player: PlayerController;
  readonly onlineSource: OnlineSource = new OnlineSource();
  private pref: preferences.Preferences | null = null;

  constructor() {
    this.player = new PlayerController(this.library);
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
    this.onlineSource.baseUrl = this.pref.getSync(KEY_ONLINE_BASE_URL, '') as string;
    this.library.init(context);
    await this.player.init(context);
  }

  /** 保存在线源 Base URL（本期仅持久化，供后续接入使用） */
  saveOnlineBaseUrl(url: string): void {
    this.onlineSource.baseUrl = url;
    if (this.pref) {
      this.pref.putSync(KEY_ONLINE_BASE_URL, url);
      this.pref.flush();
    }
  }
}

/** 全局单例 */
export const appStore: AppStore = new AppStore();
