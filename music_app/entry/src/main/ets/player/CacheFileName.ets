/**
 * 在线音频缓存的文件名派生（纯函数，零 @ohos 依赖，LocalUnit 可直测）。
 *
 * 从 OnlineCache.filePath 抽出：该函数决定「缓存文件 ↔ 索引 key」的映射，
 * 映射错一度意味着缓存 miss 重下（流量）或孤儿文件被对账清掉（已下音频
 * 丢失），且含 hash 兜底的碰撞规避逻辑——此前零测试覆盖。
 *
 * 命名规则：
 *   - 干净 id（仅 [a-zA-Z0-9_-]）：`${safe}.audio`，已缓存文件零迁移；
 *   - 含其他字符（如 `online:` 前缀的冒号）：转义为 `_` 后追加 31 位
 *     hash 短串兜底——转义会折叠（不同 id 可能折出同名），hash 保证
 *     不互相覆盖。
 */

/** 缓存音频文件后缀 */
export const CACHE_FILE_SUFFIX = '.audio';

/** 缓存索引文件名 */
export const CACHE_INDEX_FILE = 'index.json';

/**
 * songId → 缓存目录内的文件名（不含目录部分）。
 * hash 用 djb2 变体（与 OnlineCache 原实现一致：`hash * 33 ^ c`），
 * 结果与 0x7fffffff 相与保证非负，toString(36) 得短串。
 */
export function cacheFileName(songId: string): string {
  const safe = songId.replace(/[^a-zA-Z0-9_-]/g, '_');
  if (safe === songId) {
    return `${safe}${CACHE_FILE_SUFFIX}`;
  }
  let hash = 5381;
  for (let i = 0; i < songId.length; i++) {
    hash = ((hash * 33) ^ songId.charCodeAt(i)) & 0x7fffffff;
  }
  return `${safe}.${hash.toString(36)}${CACHE_FILE_SUFFIX}`;
}
