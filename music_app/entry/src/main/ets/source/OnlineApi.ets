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

/** 源能力摘要：网易云源是否可用/已登录（不可用时 hint 无意义） */
export interface OnlineProviderState {
  neteaseEnabled: boolean;
  neteaseLoggedIn: boolean;
}

/** music_server GET /api/songs 响应体 */
export interface OnlineSongsResponse {
  songs: OnlineSongItem[];
  total?: number;
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

/**
 * 解析源列表响应为源能力摘要：netease 源存在即 enabled，其 loggedIn 缺省
 * 视为 false。非法响应（空串/非 JSON/缺 providers）返回 null，调用方按
 * 「未知状态、不展示提示」处理。
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
  const state: OnlineProviderState = { neteaseEnabled: false, neteaseLoggedIn: false };
  for (const item of parsed.providers) {
    if (item && item.id === 'netease') {
      state.neteaseEnabled = true;
      state.neteaseLoggedIn = item.loggedIn === true;
    }
  }
  return state;
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
