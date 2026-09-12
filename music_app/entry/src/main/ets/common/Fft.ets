/**
 * 最小 radix-2 迭代 FFT：输入实信号窗，输出半谱幅度（归一化 0..~1，
 * 满幅正弦主 bin ≈ 1）。麦克风律动（MicSpectrum）与潜在的其他频域
 * 特性共用；纯函数、LocalUnit 可测（正弦输入峰值 bin 位置锁定）。
 */

/** 布尔恒等：n 是否 2 的幂 */
export function isPowerOfTwo(n: number): boolean {
  return n > 0 && (n & (n - 1)) === 0;
}

/**
 * 实信号 FFT 幅度谱。输入长度须为 2 的幂（调用方保证），输出长度 n/2。
 * 幅度按 2/n 归一：满幅单频正弦（频率对齐 bin）的主峰 ≈ 1。
 */
export function fftMagnitudes(input: Float32Array): Float32Array {
  const n = input.length;
  const re = new Float32Array(n);
  const im = new Float32Array(n);
  // 位反转重排
  const bits = Math.round(Math.log2(n));
  for (let i = 0; i < n; i++) {
    let r = 0;
    let x = i;
    for (let b = 0; b < bits; b++) {
      r = (r << 1) | (x & 1);
      x >>= 1;
    }
    re[r] = input[i];
  }
  // 蝶形
  for (let len = 2; len <= n; len <<= 1) {
    const half = len >> 1;
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let j = 0; j < half; j++) {
        const a = i + j;
        const b = a + half;
        const vr = re[b] * cr - im[b] * ci;
        const vi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - vr;
        im[b] = im[a] - vi;
        re[a] += vr;
        im[a] += vi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  const half = n >> 1;
  const out = new Float32Array(half);
  for (let i = 0; i < half; i++) {
    out[i] = Math.hypot(re[i], im[i]) * 2 / n;
  }
  return out;
}
