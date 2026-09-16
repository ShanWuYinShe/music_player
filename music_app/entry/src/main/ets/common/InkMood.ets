/**
 * 时辰晨昏：浅墨的色温随时辰呼吸——晨青白、昼无色、昏赭黄、夜黛蓝。
 * 返回极低透明度的罩色（叠在墨晕宣纸上，约一成浓度，隐约可感而不抢内容）；
 * 深浅两种色板下同样适用（深色板上即为夜雾的冷暖微调）。
 */
export function dayPhaseOverlay(): ResourceColor {
  const h = new Date().getHours();
  if (h >= 5 && h < 10) {
    return 'rgba(205, 222, 216, 0.13)'; // 晨 · 青白
  }
  if (h >= 10 && h < 17) {
    return 'rgba(0, 0, 0, 0)'; // 昼 · 无色
  }
  if (h >= 17 && h < 21) {
    return 'rgba(214, 178, 138, 0.12)'; // 昏 · 赭
  }
  return 'rgba(148, 158, 186, 0.12)'; // 夜 · 黛蓝
}
