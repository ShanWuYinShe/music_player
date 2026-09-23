/**
 * 迷你条手势轨迹分类（纯函数，可 LocalUnit 单测）：
 * 把一次触摸的轨迹点（[x,y]，相对起点的累计偏移）分类为「切一级签」或
 * 「切歌」动作，组件只负责采样与派发。
 *
 * 双事件语义（2026-09 用户决策）：
 * - 平直横滑 = 切歌（左滑下一首 / 右滑上一首，与播放页纸带同向）；
 * - 折返画 `>` / `<` = 顶部一级签切换（四签循环）。
 * 早认（earlyClassifyStroke，笔画中顶点一出现即调）只认折返——平直横滑
 * 是折返的前半段，早认开枪必误杀切歌；抬手兜底（classifyStrokeEnd）补
 * 慢笔画 / 漂移大的情况。
 */

export interface StrokeAction {
  kind: 'tab' | 'track';
  /** tab: +1 下一个签 / -1 上一个签；track: -1 下一首 / +1 上一首 */
  dir: number;
}

/** 折返早认阈值：走出 45vp 后折回 25vp 即认；纵向漂移 <50vp 才认（大对角
 * 下滑走抬手兜底通道，不在这里抢） */
const EARLY_OUT_VP = 45;
const EARLY_BACK_VP = 25;
const EARLY_MAX_DRIFT_VP = 50;

/** 抬手兜底阈值：横向跨度 ≥70vp + 折回量 ≥30vp + 纵向推进 ≥15vp 认折返
 * （压平的 `</>` 也认）；平直横滑按净移（纵向 <40vp、横向 ≥40vp） */
const END_SPAN_VP = 70;
const END_BACK_VP = 30;
const END_MIN_DRIFT_VP = 15;
const TRACK_MAX_DRIFT_VP = 40;
const TRACK_MIN_TRAVEL_VP = 40;

/** 折返早认：`>`（右顶点：向右走出 EARLY_OUT_VP 后折回 EARLY_BACK_VP）=
 * 下一个签，`<`（左顶点）= 上一个签；不构成折返返回 null */
export function earlyClassifyStroke(pts: number[][]): StrokeAction | null {
  if (pts.length < 2) {
    return null;
  }
  const first = pts[0];
  const cur = pts[pts.length - 1];
  const ex = cur[0] - first[0];
  const ey = cur[1] - first[1];
  let minX = 0;
  let maxX = 0;
  for (const p of pts) {
    const rx = p[0] - first[0];
    minX = Math.min(minX, rx);
    maxX = Math.max(maxX, rx);
  }
  if (Math.abs(ey) < EARLY_MAX_DRIFT_VP) {
    if (maxX >= EARLY_OUT_VP && maxX - ex >= EARLY_BACK_VP) {
      return { kind: 'tab', dir: 1 };
    }
    if (-minX >= EARLY_OUT_VP && ex - minX >= EARLY_BACK_VP) {
      return { kind: 'tab', dir: -1 };
    }
  }
  return null;
}

/** 抬手兜底分类：折返 → 切签；平直横滑 → 切歌；其余返回 null（忽略） */
export function classifyStrokeEnd(pts: number[][]): StrokeAction | null {
  if (pts.length < 2) {
    return null;
  }
  const first = pts[0];
  const lastPt = pts[pts.length - 1];
  const dxNet = lastPt[0] - first[0];
  const dyNet = lastPt[1] - first[1];
  let minX = 0;
  let maxX = 0;
  for (const p of pts) {
    const rx = p[0] - first[0];
    minX = Math.min(minX, rx);
    maxX = Math.max(maxX, rx);
  }
  const xSpan = maxX - minX;
  const ady = Math.abs(dyNet);
  const adx = Math.abs(dxNet);
  if (xSpan >= END_SPAN_VP && xSpan - adx >= END_BACK_VP && ady >= END_MIN_DRIFT_VP) {
    // 折返侧定方向：向左折返（顶点在左）= 上一个签，向右折返 = 下一个签
    const apexLeft = -minX > maxX - dxNet;
    return { kind: 'tab', dir: apexLeft ? -1 : 1 };
  }
  if (ady < TRACK_MAX_DRIFT_VP && adx >= TRACK_MIN_TRAVEL_VP) {
    return { kind: 'track', dir: dxNet < 0 ? -1 : 1 };
  }
  return null;
}
