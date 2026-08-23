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

/** music_server GET /api/songs 响应中的单曲条目（album 服务端可省略） */
export interface OnlineSongItem {
  id: string;
  title: string;
  artist?: string;
  album?: string;
  durationMs?: number;
  format?: string;
  sizeBytes?: number;
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

/** 曲目列表接口完整地址：${base}/songs（base 需含到 /api[/music] 前缀） */
export function songsUrl(baseUrl: string): string {
  return `${normalizeBaseUrl(baseUrl)}/songs`;
}

/**
 * 解析曲目列表响应为 SongRecord 列表：
 * - id 加 online: 前缀隔离本地曲库 id 空间
 * - fileName 存流媒体绝对地址（PlayerController 按 http 前缀走网络播放分支）
 * - durationMs 服务端恒为 0（不做音频头解析），prepared 后由客户端回填
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
    result.push({
      id: `${ONLINE_ID_PREFIX}${item.id}`,
      title: typeof item.title === 'string' ? item.title : item.id,
      artist: item.artist ?? '',
      album: item.album ?? '',
      duration: item.durationMs && item.durationMs > 0 ? item.durationMs : 0,
      fileName: `${base}/stream/${item.id}`,
      coverPath: ''
    });
  }
  return result;
}
