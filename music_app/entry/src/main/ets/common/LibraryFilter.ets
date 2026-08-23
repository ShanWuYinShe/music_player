import { SongRecord } from '../model/Song';

/**
 * 曲库页分类 Tab
 */
export enum LibraryTab {
  ALL = 0,
  FAVORITES = 1,
  RECENT = 2
}

/**
 * 排序方式：导入顺序 / 歌名 / 歌手 / 时长
 */
export enum SortMode {
  DEFAULT = 0,
  TITLE = 1,
  ARTIST = 2,
  DURATION = 3
}

/** 筛选排序入参 */
export interface FilterOptions {
  query: string;
  tab: LibraryTab;
  sort: SortMode;
  favoriteIds: string[];
  recentIds: string[];
}

/**
 * 排序方式显示名（用于排序按钮与菜单）
 */
export function sortLabel(mode: SortMode): string {
  if (mode === SortMode.TITLE) {
    return '按歌名';
  }
  if (mode === SortMode.ARTIST) {
    return '按歌手';
  }
  if (mode === SortMode.DURATION) {
    return '按时长';
  }
  return '默认排序';
}

function findById(songs: SongRecord[], id: string): SongRecord | null {
  for (const song of songs) {
    if (song.id === id) {
      return song;
    }
  }
  return null;
}

/**
 * 按分类取基础集合：
 * - 全部：曲库原顺序
 * - 喜欢：按收藏时间倒序（最新收藏在前）
 * - 最近：按播放时间倒序
 */
function baseSongs(songs: SongRecord[], opts: FilterOptions): SongRecord[] {
  const result: SongRecord[] = [];
  if (opts.tab === LibraryTab.FAVORITES) {
    for (let i = opts.favoriteIds.length - 1; i >= 0; i--) {
      const song = findById(songs, opts.favoriteIds[i]);
      if (song) {
        result.push(song);
      }
    }
    return result;
  }
  if (opts.tab === LibraryTab.RECENT) {
    for (const id of opts.recentIds) {
      const song = findById(songs, id);
      if (song) {
        result.push(song);
      }
    }
    return result;
  }
  return songs.slice();
}

/**
 * 曲库筛选 + 排序（纯函数，供页面与单元测试共用）
 */
export function filterAndSort(songs: SongRecord[], opts: FilterOptions): SongRecord[] {
  let result = baseSongs(songs, opts);
  const query = opts.query.trim().toLowerCase();
  if (query !== '') {
    result = result.filter((song) =>
      song.title.toLowerCase().includes(query) ||
      song.artist.toLowerCase().includes(query) ||
      song.album.toLowerCase().includes(query));
  }
  if (opts.sort === SortMode.TITLE) {
    result.sort((a, b) => a.title.localeCompare(b.title));
  } else if (opts.sort === SortMode.ARTIST) {
    result.sort((a, b) => {
      const byArtist = a.artist.localeCompare(b.artist);
      return byArtist !== 0 ? byArtist : a.title.localeCompare(b.title);
    });
  } else if (opts.sort === SortMode.DURATION) {
    // 时长未知(0)的排最后，其余从长到短
    result.sort((a, b) => {
      if (a.duration <= 0 && b.duration <= 0) {
        return 0;
      }
      if (a.duration <= 0) {
        return 1;
      }
      if (b.duration <= 0) {
        return -1;
      }
      return b.duration - a.duration;
    });
  }
  return result;
}
