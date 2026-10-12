/**
 * 在线缓存的对账/淘汰决策（纯函数，零 @ohos 依赖，LocalUnit 可直测）。
 *
 * 从 OnlineCache.reconcile / evictIfNeeded / migrateLegacyNames 抽出「删什么、
 * 留什么」的判定，IO（列目录/删文件/改名）留在调用方。
 *
 * 为什么值得单测：这三处决定**已下载音频的生死**——判错一度意味着
 *   - 把仍在索引里的缓存当孤儿删掉（用户已下整曲丢失、复播要重下）；
 *   - 把索引条目误留（指向不存在的文件，复播打开 fd 失败）；
 *   - 淘汰时误伤钉住（收藏）条目。
 * 而它们此前零测试覆盖，正确性完全依赖集合运算的顺序细节。
 */

import { evictOrder, CacheEntryLike } from '../source/OnlineApi';

/** 旧命名迁移计划中的一次操作 */
export interface RenameOp {
  /** 索引 key（仅用于日志） */
  key: string;
  /** 迁移前文件名（如 online_ne_1.audio） */
  from: string;
  /** 迁移后文件名（当前命名，含 hash 后缀） */
  to: string;
  /** true = 新名已在盘上，旧名直接删除；false = 执行改名 */
  deleteOld: boolean;
}

/**
 * 旧命名迁移计划：短 hash 引入前缓存名是 `${safe}.audio`（无 hash 后缀）。
 * 若不迁移，升级后旧缓存对不上索引、会被当孤儿清掉。
 *
 * 逐条按序模拟（与实现同构）：一条改名会改变后续判定所见的文件集合——
 * 因此内部维护 diskNames 的工作副本并即时应用效果。纯函数、无 IO。
 */
export function planLegacyRenames(indexKeys: string[], diskNames: Set<string>,
  currentNameOf: (key: string) => string): RenameOp[] {
  const working = new Set<string>(diskNames);
  const ops: RenameOp[] = [];
  for (const key of indexKeys) {
    const safe = key.replace(/[^a-zA-Z0-9_-]/g, '_');
    if (safe === key) {
      continue; // 干净 id：命名从未变过，无需迁移
    }
    const legacy = `${safe}.audio`;
    if (!working.has(legacy)) {
      continue; // 无旧名文件
    }
    const current = currentNameOf(key);
    const deleteOld = working.has(current);
    ops.push({ key: key, from: legacy, to: current, deleteOld: deleteOld });
    if (!deleteOld) {
      working.add(current);
    }
    working.delete(legacy);
  }
  return ops;
}

/**
 * 孤儿文件计划：在盘上、但既不被索引引用、也不是索引文件本身的文件名。
 * referencedNames 为索引各条目对应的当前文件名集合（调用方由 key 派生）。
 */
export function planOrphans(diskNames: Set<string>, referencedNames: Set<string>,
  indexFileName: string): string[] {
  const orphans: string[] = [];
  for (const name of diskNames) {
    if (name === indexFileName) {
      continue; // 索引文件自身不是孤儿
    }
    if (referencedNames.has(name)) {
      continue;
    }
    orphans.push(name);
  }
  return orphans;
}

/**
 * 过期索引计划：索引里存在、但对应文件已不在盘上的 key（应丢弃）。
 * existsOf 由调用方注入文件存在性探测。
 */
export function planMissingKeys(indexKeys: string[],
  existsOf: (key: string) => boolean): string[] {
  const missing: string[] = [];
  for (const key of indexKeys) {
    if (!existsOf(key)) {
      missing.push(key);
    }
  }
  return missing;
}

/**
 * 淘汰计划：按 evictOrder 序（非钉住最旧在前、钉住垫后、在途跳过）累计，
 * 直到总量降到上限内为止，返回「是否超限 + 应删除的 key」。
 *
 * 未超限返回空数组（调用方据此零 IO 早退）。总量按 entry.size 求和；
 * 在途条目被 evictOrder 排除，故不计入被删候选。
 */
export interface EvictionPlan {
  /** 是否超限。false 时 evict 必为空，调用方据此零 IO 早退（与原实现一致） */
  overLimit: boolean;
  /** 应删除的 key，按淘汰优先序（非钉住最旧在前、钉住垫后、在途跳过） */
  evict: string[];
}

export function planEviction<T extends CacheEntryLike>(entries: Map<string, T>,
  pinned: Set<string>, skip: Set<string>, maxBytes: number): EvictionPlan {
  let total = 0;
  for (const entry of entries.values()) {
    total += entry.size;
  }
  if (total <= maxBytes) {
    return { overLimit: false, evict: [] };
  }
  const plan: string[] = [];
  for (const key of evictOrder(entries, pinned, skip)) {
    if (total <= maxBytes) {
      break;
    }
    const entry = entries.get(key);
    if (entry === undefined) {
      continue;
    }
    plan.push(key);
    total -= entry.size;
  }
  return { overLimit: true, evict: plan };
}
