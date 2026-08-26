/**
 * VisualizerCore：音乐可视化合成数据源（纯函数，无 UI 依赖，LocalUnit 可测）。
 *
 * 平台无音频频谱 API（API 24 已查证），此处以曲目 id 为随机种子，
 * 用多频正弦叠加合成"频谱能量"，配合节拍包络驱动 MilkDrop 风格动效；
 * 同一输入恒定输出，保证暂停/切歌回放时视觉连续。
 */

/** preset 轮换周期：每个图形风格展示时长 */
export const PRESET_SPAN_MS = 18000;

/** 可视化 preset 数量（水平波形带 / 径向花环 / 放射线爆） */
export const PRESET_COUNT = 3;

export interface PresetSpan {
  index: number;
  startMs: number;
}

/** FNV-1a 32 位哈希，把曲目 id 折成无符号整数种子 */
export function seedFromId(id: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < id.length; i++) {
    h = Math.imul(h ^ id.charCodeAt(i), 0x01000193) >>> 0;
  }
  return h;
}

/** 整数 → [0,1) 的确定性小数（异或折叠后取高位）；可视化组件也用于球团参数散列 */
export function hash01(n: number): number {
  // 整数 → [0,1) 的确定性小数（异或折叠后取高位）
  let h = Math.imul(n ^ (n >>> 16), 0x45d9f3b) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x45d9f3b) >>> 0;
  return (h >>> 8) / 0x1000000;
}

/**
 * 合成频谱：count 根柱的瞬时能量，每项 ∈ (0,1]。
 * p 低端是低频（柱高、缓变），高端是高频（柱矮、快闪）；
 * seed 扰动各柱相位/幅度，使每首歌画面不同但恒定。
 */
export function synthSpectrum(seed: number, tMs: number, count: number): number[] {
  const out: number[] = new Array(count);
  for (let i = 0; i < count; i++) {
    const p = count > 1 ? i / (count - 1) : 0;
    const base = 0.34 + 0.38 * (1 - p);
    const w1 = 0.0021 + 0.0035 * p;
    const w2 = 0.0009 + 0.0022 * p;
    const ph1 = hash01(seed + i * 7 + 1) * Math.PI * 2;
    const ph2 = hash01(seed + i * 13 + 5) * Math.PI * 2;
    const amp1 = 0.30 + 0.22 * hash01(seed + i * 29 + 11);
    const amp2 = 0.14 + 0.16 * hash01(seed + i * 41 + 17);
    const v = base + amp1 * Math.sin(tMs * w1 + ph1) + amp2 * Math.sin(tMs * w2 + ph2);
    out[i] = Math.min(1, Math.max(0.04, v));
  }
  return out;
}

/**
 * 节拍包络：exp 衰减脉冲，值域 [0.25, 1]。
 * bpm 为每分钟节拍数；phase ∈ [0,1) 平移节拍相位（用曲目种子错开）。
 */
export function beatEnvelope(tMs: number, bpm: number, phase: number): number {
  const periodMs = 60000 / Math.max(40, Math.min(220, bpm));
  let x = (tMs / periodMs) % 1;
  if (x < 0) {
    x += 1;
  }
  x = (x + phase) % 1;
  return 0.25 + 0.75 * Math.exp(-4 * x);
}

/** 由种子取 BPM：90–150 区间整数，慢歌快歌画面节奏不同 */
export function bpmFromSeed(seed: number): number {
  return 90 + Math.floor(hash01(seed + 0x5f3a) * 61);
}

/** 当前时刻落在哪个 preset（含该 preset 的起始时刻），seed 决定轮换起点 */
export function presetAt(tMs: number, seed: number): PresetSpan {
  const offset = Math.floor(hash01(seed + 0x9e37) * PRESET_COUNT) * PRESET_SPAN_MS;
  const idx = Math.floor(Math.max(0, tMs - offset) / PRESET_SPAN_MS);
  return { index: idx % PRESET_COUNT, startMs: offset + idx * PRESET_SPAN_MS } as PresetSpan;
}

function hue2rgb(p: number, q: number, t: number): number {
  let tt = t;
  if (tt < 0) {
    tt += 1;
  }
  if (tt > 1) {
    tt -= 1;
  }
  if (tt < 1 / 6) {
    return p + (q - p) * 6 * tt;
  }
  if (tt < 1 / 2) {
    return q;
  }
  if (tt < 2 / 3) {
    return p + (q - p) * (2 / 3 - tt) * 6;
  }
  return p;
}

/** HSL → RGB（h∈[0,360) s,l∈[0,1]），返回 [r,g,b]，每项 ∈ [0,255] */
export function hslToRgb(h: number, s: number, l: number): number[] {
  const hh = ((h % 360) + 360) % 360 / 360;
  if (s === 0) {
    const v = Math.round(l * 255);
    return [v, v, v];
  }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return [
    Math.round(hue2rgb(p, q, hh + 1 / 3) * 255),
    Math.round(hue2rgb(p, q, hh) * 255),
    Math.round(hue2rgb(p, q, hh - 1 / 3) * 255)
  ];
}

/** 生成 Canvas fillStyle 的 rgb() 字符串 */
export function rgbStyle(rgb: number[]): string {
  return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
}
