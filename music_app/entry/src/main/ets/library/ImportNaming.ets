/**
 * 导入文件命名派生（纯函数，零 @ohos 依赖，LocalUnit 可直测）。
 *
 * 从 MusicLibrary 的 normalizedFileName / uniqueName 抽出：这两个函数决定
 * 「导入音频在沙盒内的落盘文件名」，而**文件名是曲目 id 的组成部分**
 * （`${fileName}_${size}`）——命名规则若变，存量曲库索引的 id 全部失配，
 * 表现为收藏/最近播放丢引用。此前是 private 方法、零测试覆盖。
 *
 * 设计：纯函数只负责「给定冲突集，算出第几个候选名」，文件系统探测
 * （accessSync）留在调用方，避免把 IO 混进可测逻辑。
 */

/** 沙盒文件名非法字符（Windows/macOS 均不宜出现的路径与保留字符） */
const ILLEGAL_NAME_CHARS = /[\/\\:*?"<>|]/g;

/**
 * 规范化显示名为沙盒文件名基础形态：
 * ① 非法字符替换为 `_`；
 * ② 不含任何 `.` 时补上兜底扩展名（picker 可能给出无扩展名的 URI）。
 */
export function normalizeImportName(displayName: string, fallbackExt: string): string {
  let base = displayName.replace(ILLEGAL_NAME_CHARS, '_');
  if (!base.includes('.')) {
    return `${base}.${fallbackExt}`;
  }
  return base;
}

/**
 * 在规范化文件名基础上生成沙盒内不冲突的文件名。
 * taken 为已占用的文件名集合（调用方查目录得到）——纯函数不碰文件系统。
 * 冲突时在扩展名前追加 `_N`（N 从 1 递增）：`a.mp3` → `a_1.mp3` → `a_2.mp3`。
 * 无冲突原样返回（保证已缓存/已导入文件的命名稳定）。
 */
export function uniqueImportName(base: string, taken: Set<string>): string {
  if (!taken.has(base)) {
    return base;
  }
  const dotIdx = base.lastIndexOf('.');
  // 无扩展名:直接在末尾追加,不按插入点切分
  const stem = dotIdx > 0 ? base.substring(0, dotIdx) : base;
  const ext = dotIdx > 0 ? base.substring(dotIdx) : '';
  let counter = 1;
  let candidate = `${stem}_${counter}${ext}`;
  while (taken.has(candidate)) {
    counter++;
    candidate = `${stem}_${counter}${ext}`;
  }
  return candidate;
}

/**
 * 曲目 id：文件名 + 大小摘要。同名不同内容靠大小区分；同内容重复导入时
 * 两条记录的 id 相同，导入链路据此判重（拷贝前后各查一次）。
 */
export function songIdFor(fileName: string, size: number): string {
  return `${fileName}_${size}`;
}
