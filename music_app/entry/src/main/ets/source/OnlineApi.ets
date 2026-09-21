import { SongRecord } from '../model/Song';

/**
 * 在线源纯逻辑：Base URL 规范化、API 地址拼接与响应解析。
 * 零 @ohos 依赖（LocalUnit 单测可直接 import）；网络请求在 MusicSource 的
 * OnlineSource 中实现。
 */

/** 在线曲目 id 前缀，避免与本地曲库 id（文件名+大小摘要）冲突 */
export const ONLINE_ID_PREFIX = 'online:';

/**
 * 默认在线服务地址：线上 nginx 的 /api/music/ 前缀（与 media_center 客户端
 * 默认 https://yinghuoren.com/api/media 同域同 nginx）。用户未配置时使用。
 */
export const DEFAULT_ONLINE_BASE_URL = 'https://yinghuoren.com/api/music';

/** music_server GET /api/songs 响应中的单曲条目（album/source 服务端可省略） */
export interface OnlineSongItem {
  id: string;
  title: string;
  artist?: string;
  album?: string;
  durationMs?: number;
  format?: string;
  sizeBytes?: number;
  /** 来源标识：省略=服务器本地曲库，netease=网络源 */
  source?: string;
  /** 网易云付费曲目（服务端未登录时仅试听片段） */
  vip?: boolean;
}

/** music_server GET /api/providers 响应中的源条目（loggedIn 服务端可省略） */
export interface OnlineProviderItem {
  id: string;
  name?: string;
  type?: string;
  /** 网易云源是否已配置账号 cookie（解锁完整音频） */
  loggedIn?: boolean;
}

/** music_server GET /api/providers 响应体 */
export interface OnlineProvidersResponse {
  providers?: OnlineProviderItem[];
}

/** 源能力摘要：网易云源是否已登录（决定付费曲是否仅试听） */
export interface OnlineProviderState {
  neteaseLoggedIn: boolean;
}

/** music_server GET /api/songs 响应体 */
export interface OnlineSongsResponse {
  songs: OnlineSongItem[];
  total?: number;
}

/** 在线列表持久化缓存条目（默认视图，空查询）：baseUrl 用于换服失效 */
export interface OnlineCacheEntry {
  baseUrl: string;
  /** 采样时刻（墙钟 ms），TTL 判定与卡片锚点同思路 */
  savedAt: number;
  songs: SongRecord[];
}

/** 缓存文件结构版本：字段/语义变化时递增使旧文件失效 */
const ONLINE_CACHE_VERSION = 1;

/** 缓存文件持久化结构（条目 + 版本号；version 缺失即旧文件，拒绝） */
interface OnlineCacheFile extends OnlineCacheEntry {
  version?: number;
}

/** TTL 判定（纯函数）：clock 回拨（now < savedAt）视为不新鲜 */
export function isCacheFresh(savedAt: number, now: number, ttlMs: number): boolean {
  return savedAt > 0 && now >= savedAt && now - savedAt < ttlMs;
}

/** 缓存条目 → 持久化 JSON 串（纯函数） */
export function serializeOnlineCache(entry: OnlineCacheEntry): string {
  return JSON.stringify({
    version: ONLINE_CACHE_VERSION,
    baseUrl: entry.baseUrl,
    savedAt: entry.savedAt,
    songs: entry.songs
  });
}

/**
 * 持久化 JSON 串 → 缓存条目（纯函数）。损坏 / 版本不符 / baseUrl 与当前
 * 生效地址不一致 / 结构非法（含空列表——空库不值得缓存，展示占位本就不
 * 需要数据）返回 null，调用方按无缓存处理。
 */
export function parseOnlineCache(body: string, baseUrl: string): OnlineCacheEntry | null {
  if (body.trim() === '') {
    return null;
  }
  let parsed: OnlineCacheFile | null;
  try {
    parsed = JSON.parse(body) as OnlineCacheFile;
  } catch (err) {
    return null;
  }
  if (!parsed || parsed.version !== ONLINE_CACHE_VERSION || parsed.baseUrl !== baseUrl) {
    return null;
  }
  if (typeof parsed.savedAt !== 'number' || !(parsed.savedAt > 0) || !Array.isArray(parsed.songs)) {
    return null;
  }
  if (parsed.songs.length === 0) {
    return null;
  }
  const songs: SongRecord[] = [];
  for (const song of parsed.songs) {
    if (song && typeof song.id === 'string' && typeof song.title === 'string' &&
      typeof song.fileName === 'string' && song.fileName !== '') {
      songs.push(song);
    }
  }
  if (songs.length === 0) {
    return null;
  }
  return { baseUrl: parsed.baseUrl, savedAt: parsed.savedAt, songs: songs };
}

/** 规范化 Base URL：去首尾空白与尾部斜杠；空串原样返回 */
export function normalizeBaseUrl(url: string): string {
  const trimmed = url.trim();
  if (trimmed === '') {
    return '';
  }
  return trimmed.replace(/\/+$/, '');
}

/** 生效地址：用户配置值非空用它，否则回落默认服务地址（永不为空） */
export function effectiveBaseUrl(configured: string): string {
  return normalizeBaseUrl(configured) || DEFAULT_ONLINE_BASE_URL;
}

/** 曲目列表接口完整地址：${base}/songs，query 非空时带上服务端搜索参数 */
export function songsUrl(baseUrl: string, query: string = ''): string {
  const base = normalizeBaseUrl(baseUrl);
  const q = query.trim();
  return q === '' ? `${base}/songs` : `${base}/songs?q=${encodeURIComponent(q)}`;
}

/** 源列表接口完整地址：${base}/providers */
export function providersUrl(baseUrl: string): string {
  return `${normalizeBaseUrl(baseUrl)}/providers`;
}

/** 健康端点完整地址：${base}/health（服务端 /api/health 别名，携带版本号） */
export function healthUrl(baseUrl: string): string {
  return `${normalizeBaseUrl(baseUrl)}/health`;
}

export interface OnlineHealthInfo {
  version: string;
}

/**
 * 解析健康响应为版本信息。非法响应（空串/非 JSON/缺 version）返回 null，
 * 调用方按「无法获取」展示。
 */
export function parseOnlineHealth(body: string): OnlineHealthInfo | null {
  if (body.trim() === '') {
    return null;
  }
  let parsed: OnlineHealthInfo;
  try {
    parsed = JSON.parse(body) as OnlineHealthInfo;
  } catch (err) {
    return null;
  }
  if (!parsed || typeof parsed.version !== 'string' || parsed.version === '') {
    return null;
  }
  return { version: parsed.version };
}

/**
 * 解析源列表响应为源能力摘要：取 netease 源的 loggedIn（缺省视为
 * false）。非法响应（空串/非 JSON/缺 providers）返回 null，调用方按
 * 「未知状态」处理。
 */
export function parseOnlineProviders(body: string): OnlineProviderState | null {
  if (body.trim() === '') {
    return null;
  }
  let parsed: OnlineProvidersResponse;
  try {
    parsed = JSON.parse(body) as OnlineProvidersResponse;
  } catch (err) {
    return null;
  }
  if (!parsed || !Array.isArray(parsed.providers)) {
    return null;
  }
  const state: OnlineProviderState = { neteaseLoggedIn: false };
  for (const item of parsed.providers) {
    if (item && item.id === 'netease') {
      state.neteaseLoggedIn = item.loggedIn === true;
    }
  }
  return state;
}

/** 判定歌曲 id 是否属于在线源（online: 前缀） */
export function isOnlineId(id: string): boolean {
  return id.startsWith(ONLINE_ID_PREFIX);
}

/** 在线歌曲 id → 服务端裸 id（去掉 online: 前缀）；非在线 id 返回空串 */
export function onlineItemId(id: string): string {
  return isOnlineId(id) ? id.substring(ONLINE_ID_PREFIX.length) : '';
}

/** 按生效服务地址重拼流媒体地址（注册表条目换服后播放仍指向新服务端） */
export function rebuildStreamUrl(baseUrl: string, itemId: string): string {
  return `${normalizeBaseUrl(baseUrl)}/stream/${itemId}`;
}

/** 在线歌曲注册表文件结构版本：字段/语义变化时递增使旧文件失效 */
const ONLINE_SONG_STORE_VERSION = 1;

/** 注册表持久化结构（version 于序列化时写入；缺失即旧文件，解析拒绝） */
interface OnlineSongStoreFile {
  version?: number;
  baseUrl?: string;
  songs?: SongRecord[];
}

/** 注册表 → 持久化 JSON 串（纯函数）：baseUrl 为注册时刻生效地址 */
export function serializeOnlineSongStore(baseUrl: string, songs: SongRecord[]): string {
  return JSON.stringify({
    version: ONLINE_SONG_STORE_VERSION,
    baseUrl: baseUrl,
    songs: songs
  });
}

/**
 * 持久化 JSON 串 → 注册表歌曲列表（纯函数）。损坏 / 版本不符 / 缺 baseUrl
 * 返回 null（调用方按空注册表处理）。条目校验：id 必须带 online: 前缀、
 * title 与 fileName 为非空字符串；注册时 baseUrl 与当前生效地址不一致时
 * fileName 重拼为当前地址（服务端 id 稳定，换服自动适配）。
 */
export function parseOnlineSongStore(body: string, currentBaseUrl: string): SongRecord[] | null {
  if (body.trim() === '') {
    return null;
  }
  let parsed: OnlineSongStoreFile;
  try {
    parsed = JSON.parse(body) as OnlineSongStoreFile;
  } catch (err) {
    return null;
  }
  if (!parsed || parsed.version !== ONLINE_SONG_STORE_VERSION || typeof parsed.baseUrl !== 'string'
    || !Array.isArray(parsed.songs)) {
    return null;
  }
  const baseUrlChanged = parsed.baseUrl !== normalizeBaseUrl(currentBaseUrl);
  const songs: SongRecord[] = [];
  for (const song of parsed.songs) {
    if (!song || !isOnlineId(song.id) || typeof song.title !== 'string' || song.title === ''
      || typeof song.fileName !== 'string' || song.fileName === '') {
      continue;
    }
    const record: SongRecord = {
      id: song.id,
      title: song.title,
      artist: typeof song.artist === 'string' ? song.artist : '',
      album: typeof song.album === 'string' ? song.album : '',
      duration: typeof song.duration === 'number' && song.duration > 0 ? song.duration : 0,
      fileName: baseUrlChanged ? rebuildStreamUrl(currentBaseUrl, onlineItemId(song.id)) : song.fileName,
      coverPath: ''
    };
    if (typeof song.format === 'string' && song.format !== '') {
      record.format = song.format.toUpperCase();
    }
    if (song.vip === true) {
      record.vip = true;
    }
    songs.push(record);
  }
  return songs;
}

/** 整曲缓存索引条目形态（淘汰排序纯函数入参） */
export interface CacheEntryLike {
  size: number;
  lastAccess: number;
}

/**
 * 缓存淘汰候选序（纯函数）：非钉住条目按末次访问从旧到新排在前面，
 * 钉住（收藏）条目垫后——仅当非钉存总量自身超限时才会轮到它们；
 * skip（在途下载）完全不参与。返回按淘汰优先序排列的 key。
 */
export function evictOrder<T extends CacheEntryLike>(entries: Map<string, T>, pinned: Set<string>,
  skip: Set<string>): string[] {
  const normal: string[] = [];
  const pinnedKeys: string[] = [];
  for (const key of entries.keys()) {
    if (skip.has(key)) {
      continue;
    }
    if (pinned.has(key)) {
      pinnedKeys.push(key);
    } else {
      normal.push(key);
    }
  }
  const byAccess = (a: string, b: string): number => {
    const ea = entries.get(a);
    const eb = entries.get(b);
    return (ea ? ea.lastAccess : 0) - (eb ? eb.lastAccess : 0);
  };
  normal.sort(byAccess);
  pinnedKeys.sort(byAccess);
  return normal.concat(pinnedKeys);
}

/**
 * 解析曲目列表响应为 SongRecord 列表：
 * - id 加 online: 前缀隔离本地曲库 id 空间
 * - fileName 存流媒体绝对地址（PlayerController 按 http 前缀走网络播放分支）
 * - durationMs 网络源带真实时长；本地曲库恒为 0，prepared 后由客户端回填
 * 非法响应（空串/非 JSON/缺 songs）返回空数组，不抛异常。
 */
export function parseOnlineSongs(baseUrl: string, body: string): SongRecord[] {
  const base = normalizeBaseUrl(baseUrl);
  if (base === '' || body.trim() === '') {
    return [];
  }
  let parsed: OnlineSongsResponse;
  try {
    parsed = JSON.parse(body) as OnlineSongsResponse;
  } catch (err) {
    return [];
  }
  if (!parsed || !Array.isArray(parsed.songs)) {
    return [];
  }
  const result: SongRecord[] = [];
  for (const item of parsed.songs) {
    if (!item || typeof item.id !== 'string' || item.id === '') {
      continue;
    }
    const record: SongRecord = {
      id: `${ONLINE_ID_PREFIX}${item.id}`,
      title: typeof item.title === 'string' ? item.title : item.id,
      artist: item.artist ?? '',
      album: item.album ?? '',
      duration: item.durationMs && item.durationMs > 0 ? item.durationMs : 0,
      fileName: `${base}/stream/${item.id}`,
      coverPath: ''
    };
    if (typeof item.format === 'string' && item.format !== '') {
      record.format = item.format.toUpperCase();
    }
    if (item.vip === true) {
      record.vip = true;
    }
    result.push(record);
  }
  return result;
}
