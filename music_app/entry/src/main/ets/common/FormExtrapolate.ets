/**
 * 桌面卡片进度外推（纯函数，零 @ohos 依赖，LocalUnit 可直测）。
 *
 * 从 AppStore.syncFormState 与 MusicCardWide.dispMs 两端共用同一套推算规则
 * 抽出——两端算法必须逐字一致，否则同一时刻主进程与卡片会显示不同进度
 * （用户看到的典型症状：卡片进度条与锁屏/播放页对不上）。
 *
 * 模型（两级外推，实测不重复计数）：
 *   主进程：pos = currentTime@T + (T - anchorPrev)，anchorAt = T
 *   卡片：  disp = pos + (now - T)
 *   合成后 = currentTime@T + (now - anchorPrev)，即「当前播放位置 + 自上次
 *   锚点以来的真实经过时间」，正确无重复。
 *
 * 关键守卫：锚点新鲜度门槛（freshnessWindowMs）。真机后台 timeUpdate 停报
 * 时 currentTime 冻结，靠墙钟补齐；但长时间暂停后恢复、冷启动首推等场景下
 * 两次采样之间隔着非播放期，墙钟差不是播放增量——必须放弃外推，否则卡片
 * 会一次性跳过整段暂停时长。
 */

/**
 * 主进程侧：由上次锚点外推出当前播放位置。
 * @param currentTime AVPlayer 上报的位置（后台可能冻结）
 * @param anchorPrevMs 上次采样时刻（0 = 从未采样，放弃外推）
 * @param nowMs 本次采样时刻
 * @param freshnessWindowMs 锚点新鲜度窗口：delta 超出即认为隔着非播放期
 * @returns 外推后的位置（毫秒，未夹取）
 */
export function extrapolatePosition(currentTime: number, anchorPrevMs: number,
  nowMs: number, freshnessWindowMs: number): number {
  if (anchorPrevMs <= 0) {
    return currentTime;
  }
  const delta = nowMs - anchorPrevMs;
  // delta > 0：墙钟回拨时不外推(宁停不进);delta 超窗口：非播放期，不外推
  if (delta <= 0 || delta > freshnessWindowMs) {
    return currentTime;
  }
  return currentTime + delta;
}

/**
 * 卡片侧：由主进程推送的快照外推出显示位置（推送到达有延迟时补齐）。
 * @param pushedPosMs 主进程推送的位置（已含主进程侧外推量）
 * @param anchorAtMs 快照采样时刻（push 时写入；<=0 视为无快照）
 * @param nowMs 当前时刻
 * @param durationMs 曲目总时长（>0 才夹取）
 * @returns 显示位置（毫秒，夹在 [0, duration] 内）
 */
export function extrapolateDisplayPosition(pushedPosMs: number, anchorAtMs: number,
  nowMs: number, durationMs: number): number {
  if (anchorAtMs <= 0) {
    return pushedPosMs;
  }
  // Math.max(0, ...)：锚点晚于当前时刻(时钟偏差/推送乱序)不加成负增量
  let pos = pushedPosMs + Math.max(0, nowMs - anchorAtMs);
  if (durationMs > 0 && pos > durationMs) {
    pos = durationMs;
  }
  return pos;
}
