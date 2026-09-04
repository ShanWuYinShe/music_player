import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SortMode } from '../common/LibraryFilter';

const TAG = 'UserData';
const DOMAIN = 0x0004;

const KEY_FAVORITE_IDS = 'favorite_ids';
const KEY_RECENT_IDS = 'recent_ids';
const KEY_SORT_MODE = 'library_sort_mode';

/** 最近播放记录条数上限 */
export const RECENT_LIMIT = 200;

/**
 * 用户行为数据：喜欢的歌曲、最近播放、曲库排序偏好。
 * 持久化于 preferences；@Trace 字段直接驱动 UI 刷新。
 */
@ObservedV2
export class UserData {
  /** 喜欢的歌曲 id（新收藏插最前） */
  @Trace favoriteIds: string[] = [];
  /** 最近播放的歌曲 id（最新播放在前） */
  @Trace recentIds: string[] = [];
  /** 曲库排序方式（重启恢复） */
  @Trace sortMode: SortMode = SortMode.DEFAULT;

  private pref: preferences.Preferences | null = null;

  init(pref: preferences.Preferences): void {
    this.pref = pref;
    this.favoriteIds = this.readStringArray(KEY_FAVORITE_IDS);
    this.recentIds = this.readStringArray(KEY_RECENT_IDS);
    const sort = this.pref.getSync(KEY_SORT_MODE, SortMode.DEFAULT) as number;
    if (sort === SortMode.TITLE || sort === SortMode.ARTIST || sort === SortMode.DURATION
      || sort === SortMode.DEFAULT) {
      this.sortMode = sort as SortMode;
    }
  }

  /** 更新曲库排序并持久化（重启恢复） */
  setSortMode(mode: SortMode): void {
    this.sortMode = mode;
    if (!this.pref) {
      return;
    }
    try {
      this.pref.putSync(KEY_SORT_MODE, mode);
      this.pref.flush().catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'flush sort mode failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persist sort mode failed: %{public}s', JSON.stringify(err));
    }
  }

  isFavorite(id: string): boolean {
    return this.favoriteIds.indexOf(id) >= 0;
  }

  /** 切换收藏状态，返回切换后是否已收藏 */
  toggleFavorite(id: string): boolean {
    const nowFavorite = !this.isFavorite(id);
    if (nowFavorite) {
      this.favoriteIds = [id].concat(this.favoriteIds);
    } else {
      this.favoriteIds = this.favoriteIds.filter((item) => item !== id);
    }
    this.persist(KEY_FAVORITE_IDS, this.favoriteIds);
    return nowFavorite;
  }

  /** 记录一次播放（去重置顶，超限截断） */
  addRecent(id: string): void {
    const rest = this.recentIds.filter((item) => item !== id);
    this.recentIds = [id].concat(rest).slice(0, RECENT_LIMIT);
    this.persist(KEY_RECENT_IDS, this.recentIds);
  }

  /** 歌曲被删除时清理引用 */
  removeSongRefs(id: string): void {
    if (this.favoriteIds.indexOf(id) >= 0) {
      this.favoriteIds = this.favoriteIds.filter((item) => item !== id);
      this.persist(KEY_FAVORITE_IDS, this.favoriteIds);
    }
    if (this.recentIds.indexOf(id) >= 0) {
      this.recentIds = this.recentIds.filter((item) => item !== id);
      this.persist(KEY_RECENT_IDS, this.recentIds);
    }
  }

  /** 清空全部（配合清空曲库） */
  clearAll(): void {
    this.favoriteIds = [];
    this.recentIds = [];
    this.persist(KEY_FAVORITE_IDS, []);
    this.persist(KEY_RECENT_IDS, []);
  }

  private persist(key: string, value: string[]): void {
    if (!this.pref) {
      return;
    }
    try {
      this.pref.putSync(key, value);
      // flush 是异步落盘：失败需捕获记日志，避免 unhandled rejection
      this.pref.flush().catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'flush %{public}s failed: %{public}s', key, JSON.stringify(err));
      });
    } catch (err) {
      // 持久化失败不影响功能，仅丢偏好数据
      hilog.warn(DOMAIN, TAG, 'persist %{public}s failed: %{public}s', key, JSON.stringify(err));
    }
  }

  private readStringArray(key: string): string[] {
    if (!this.pref) {
      return [];
    }
    try {
      const value = this.pref.getSync(key, [] as string[]);
      return value as string[];
    } catch (err) {
      return [];
    }
  }
}
