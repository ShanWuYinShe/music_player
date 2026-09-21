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
  /** 在线歌曲注册表条目：喜欢/最近列表的在线歌补位来源（全部 Tab 不混入） */
  onlineSongs?: SongRecord[];
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

/** id → 曲目：先查本地曲库，再查在线注册表补位（喜欢/最近跨源融合） */
function findSongById(songs: SongRecord[], onlineSongs: SongRecord[], id: string): SongRecord | null {
  const local = findById(songs, id);
  if (local !== null) {
    return local;
  }
  return findById(onlineSongs, id);
}

/**
 * 按分类取基础集合：
 * - 全部：曲库原顺序
 * - 喜欢：按收藏时间倒序（最新收藏在前）
 * - 最近：按播放时间倒序
 * 喜欢/最近的在线歌从 onlineSongs 补位（id 不在本地曲库时），与本地歌混排。
 */
function baseSongs(songs: SongRecord[], opts: FilterOptions): SongRecord[] {
  const result: SongRecord[] = [];
  const onlineSongs = opts.onlineSongs ?? [];
  if (opts.tab === LibraryTab.FAVORITES) {
    for (let i = opts.favoriteIds.length - 1; i >= 0; i--) {
      const song = findSongById(songs, onlineSongs, opts.favoriteIds[i]);
      if (song) {
        result.push(song);
      }
    }
    return result;
  }
  if (opts.tab === LibraryTab.RECENT) {
    for (const id of opts.recentIds) {
      const song = findSongById(songs, onlineSongs, id);
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

/** 高亮分段：命中片段与普通片段 */
export interface TextSegment {
  text: string;
  hit: boolean;
}

/**
 * 按关键词把文本切分为命中/未命中分段（大小写不敏感），搜索结果
 * 高亮渲染用。关键词为空返回整段未命中。
 */
export function splitHighlight(text: string, keyword: string): TextSegment[] {
  const q = keyword.trim().toLowerCase();
  if (q === '') {
    return [{ text: text, hit: false }];
  }
  const segments: TextSegment[] = [];
  const lower = text.toLowerCase();
  let cursor = 0;
  while (cursor <= text.length) {
    const hit = lower.indexOf(q, cursor);
    if (hit < 0) {
      segments.push({ text: text.substring(cursor), hit: false });
      break;
    }
    if (hit > cursor) {
      segments.push({ text: text.substring(cursor, hit), hit: false });
    }
    segments.push({ text: text.substring(hit, hit + q.length), hit: true });
    cursor = hit + q.length;
  }
  return segments;
}
