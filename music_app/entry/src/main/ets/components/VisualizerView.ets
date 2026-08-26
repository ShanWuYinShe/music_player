/**
 * VisualizerView：MilkDrop 风格音乐可视化（@ComponentV2）。
 *
 * 平台无频谱 API，频段能量由 VisualizerCore 合成（种子 = 曲目 id）。
 * 渲染采用双离屏画布 ping-pong 反馈：每帧把上一帧 ImageBitmap 以节拍脉冲
 * 驱动的缩放/微旋转 + 正弦切片偏移重绘为基底（拖尾如液体波动流淌），
 * 再叠加液态光团（metaball）与氛围底光（'lighter' 叠加发光融合），
 * 呈水滴般圆润变幻的流动画面。
 *
 * 变体：full = 播放页全屏沉浸背景；mini = 迷你条底部单色金光带。
 * 帧驱动 displaySync 限 24fps，暂停后跑约 0.9s 收敛动画即停。
 */

import displaySync from '@ohos.graphics.displaySync';
import { PlayerController } from '../player/PlayerController';
import {
  seedFromId, synthSpectrum, beatEnvelope, bpmFromSeed, hash01, hslToRgb, rgbStyle
} from '../common/VisualizerCore';

/** 离屏画布最长边上限：全屏模式下降采样，反馈拖尾本身柔和，拉伸显示无损观感 */
const OFFSCREEN_MAX_DIM = 420;
/** 暂停后收敛动画时长（ms），之后停帧保留静帧 */
const FADE_MS = 900;
/** 绘帧最小间隔：24fps 对拖尾流动观感无感知差异，控制 CPU 总耗 */
const FRAME_MIN_INTERVAL = 42;

@ComponentV2
export struct VisualizerView {
  @Param @Require player: PlayerController;
  /** 'full' 播放页全屏；'mini' 迷你条内嵌 */
  @Param variant: string = 'full';

  private displayCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private offA: OffscreenCanvasRenderingContext2D | null = null;
  private offB: OffscreenCanvasRenderingContext2D | null = null;
  private prevBitmap: ImageBitmap | null = null;
  /** 上屏位图环形缓冲：显示合成是异步的，立即 close 会被 GPU 采样到脏数据（真机花屏），延迟数帧释放 */
  private recycle: ImageBitmap[] = [];
  private ds: displaySync.DisplaySync | null = null;

  private offW = 0;
  private offH = 0;
  private flip = false;
  private running = false;
  private disposed = false;
  private ready = false;

  private lastSongId = '';
  private seed = 0;
  private beatPhase = 0;
  /** 有效播放时钟：暂停期间不走，保证画面冻结在暂停时刻 */
  private playClock = 0;
  private lastNow = 0;
  private fadeDeadline = 0;
  /** 反馈层累积旋转角（恒定慢速） */
  private feedbackSpin = 0;

  aboutToAppear(): void {
    this.ds = displaySync.create();
    const range: ExpectedFrameRateRange = { min: 0, max: 30, expected: 30 };
    this.ds.setExpectedFrameRateRange(range);
    this.ds.on('frame', () => this.frame());
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopLoop();
    if (this.prevBitmap !== null) {
      this.prevBitmap.close();
      this.prevBitmap = null;
    }
    for (const b of this.recycle) {
      b.close();
    }
    this.recycle = [];
  }

  @Monitor('player.isPlaying', 'player.currentSongId')
  onPlayerStateChange(): void {
    this.syncState();
  }

  private syncState(): void {
    if (this.disposed) {
      return;
    }
    const id = this.player.currentSongId;
    if (id !== this.lastSongId) {
      this.lastSongId = id;
      this.seed = seedFromId(id);
      this.beatPhase = (this.seed % 997) / 997;
      this.playClock = 0;
      this.lastNow = Date.now();
    }
    if (id === '') {
      this.stopLoop();
      this.clearDisplay();
      return;
    }
    if (this.player.isPlaying) {
      this.startLoop();
    } else {
      this.fadeDeadline = Date.now() + FADE_MS;
    }
  }

  private startLoop(): void {
    if (this.running || this.ds === null || !this.ready) {
      return;
    }
    this.running = true;
    this.lastNow = Date.now();
    this.ds.start();
  }

  private stopLoop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.ds !== null) {
      this.ds.stop();
    }
  }

  private clearDisplay(): void {
    if (this.ready) {
      this.displayCtx.clearRect(0, 0, this.displayCtx.width, this.displayCtx.height);
    }
  }

  private frame(): void {
    if (this.disposed || !this.ready || this.offA === null || this.offB === null) {
      return;
    }
    const now = Date.now();
    // 真机高刷屏上 displaySync 可能超预期回调，按 24fps 节流绘制
    if (now - this.lastNow < FRAME_MIN_INTERVAL) {
      return;
    }
    const dt = Math.min(now - this.lastNow, 66);
    this.lastNow = now;
    const playing = this.player.isPlaying;
    if (playing) {
      this.playClock += dt;
    }
    const t = this.playClock;
    const beat = beatEnvelope(t, bpmFromSeed(this.seed), this.beatPhase);
    const mini = this.variant === 'mini';
    this.feedbackSpin += 0.0000126 * dt;

    const bars = synthSpectrum(this.seed, t, mini ? 24 : 48);
    const active = this.flip ? this.offA : this.offB;
    const W = this.offW;
    const H = this.offH;

    active.clearRect(0, 0, W, H);
    // full：底色固定为 window/系统栏兜底色 #161310（rgb 22,19,16），
    // 画面边缘经渐晕收敛回同色，顶底区域无论露出哪层都无色差；
    // mini 叠在卡片 surface 上保持透明底
    const UNIFY_BG = 'rgb(22,19,16)';
    if (this.variant !== 'mini') {
      active.fillStyle = UNIFY_BG;
      active.fillRect(0, 0, W, H);
    }
    // 反馈层：上一帧重绘成流动拖尾。mini 整幅缩放即可；full 按水平条带
    // 切片、各带附加正弦横向偏移——拖尾如液体般波动流淌而非刚性放大
    if (this.prevBitmap !== null) {
      let a = playing ? 0.972 : 0.90;
      active.save();
      active.globalAlpha = a;
      active.translate(W / 2, H / 2);
      const zoom = 1 + (0.018 + 0.024 * beat) * (mini ? 0.5 : 1);
      active.scale(zoom, zoom);
      active.rotate(this.feedbackSpin);
      active.translate(-W / 2, -H / 2);
      if (mini) {
        active.drawImage(this.prevBitmap, 0, 0, W, H);
      } else {
        const SLICES = 24;
        const sliceH = H / SLICES;
        for (let s = 0; s < SLICES; s++) {
          const y0 = s * sliceH;
          const off = Math.sin(t * 0.0016 + s * 0.55) * W * 0.012 * (0.6 + 0.6 * beat);
          // 条带各多取 1px 源高，避免切片间露缝
          active.drawImage(this.prevBitmap, 0, y0, W, sliceH + 1, off, y0, W, sliceH + 1);
        }
      }
      active.restore();
    }

    active.globalCompositeOperation = mini ? 'source-over' : 'lighter';
    active.globalAlpha = 1;
    if (!mini) {
      // 全屏氛围底光：中心彩色呼吸、向外衰减到完全透明（lighter 叠加）
      const hue = this.hueBase(t);
      const glowR = Math.max(W, H) * (0.66 + 0.30 * beat);
      const c0 = hslToRgb(hue, 0.75, 0.16 + 0.10 * beat);
      const c1 = hslToRgb(hue + 30, 0.7, 0.10);
      const grad = active.createRadialGradient(W / 2, H * 0.46, glowR * 0.32, W / 2, H * 0.46, glowR);
      grad.addColorStop(0, `rgb(${c0[0]},${c0[1]},${c0[2]})`);
      grad.addColorStop(0.55, `rgb(${c1[0]},${c1[1]},${c1[2]})`);
      grad.addColorStop(1, 'rgba(0,0,0,0)');
      active.fillStyle = grad;
      active.fillRect(0, 0, W, H);
      this.drawLiquid(active, t, beat, bars, W, H);
    } else {
      this.drawWaves(active, t, beat, bars, W, H);
    }
    active.globalCompositeOperation = 'source-over';

    const bmp = active.transferToImageBitmap();
    this.displayCtx.clearRect(0, 0, this.displayCtx.width, this.displayCtx.height);
    this.displayCtx.drawImage(bmp, 0, 0, this.displayCtx.width, this.displayCtx.height);
    if (this.prevBitmap !== null) {
      // prevBitmap 仍被反馈层引用；把已上屏数帧的旧位图延迟回收，避开合成管线
      this.recycle.push(this.prevBitmap);
      if (this.recycle.length > 4) {
        const oldest = this.recycle.shift();
        if (oldest !== undefined) {
          oldest.close();
        }
      }
    }
    this.prevBitmap = bmp;
    this.flip = !this.flip;

    if (!playing && now > this.fadeDeadline) {
      this.stopLoop();
    }
  }

  /** 基础色相：随播放时钟慢速漂移，起点由曲目种子决定 */
  private hueBase(t: number): number {
    return (t * 0.02) % 360 + (this.seed % 360);
  }

  /**
   * 液态光团（metaball）：多个径向渐变光球按 Lissajous 曲线永不重复地漂移，
   * 半径随频谱段能量与节拍呼吸；lighter 叠加下光球相遇自然融合分离，
   * 呈水滴/极光般的圆润变幻，配合波动切片拖尾整体如流体涌动。
   */
  private drawLiquid(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = 8;
    const m = Math.min(W, H);
    for (let i = 0; i < N; i++) {
      // 互质近似频率的 Lissajous 轨迹：路径永不重复，变幻莫测
      const fx = 0.00022 + hash01(this.seed + i * 7 + 1) * 0.00062;
      const fy = 0.00019 + hash01(this.seed + i * 13 + 5) * 0.00055;
      const phx = hash01(this.seed + i * 29 + 11) * 6.2831853;
      const phy = hash01(this.seed + i * 41 + 17) * 6.2831853;
      const x = W / 2 + W * 0.31 * Math.sin(t * fx + phx);
      const y = H * 0.47 + H * 0.27 * Math.sin(t * fy + phy);
      const bi = Math.min(bars.length - 1, Math.floor(i * bars.length / N));
      const r = m * (0.085 + 0.10 * bars[bi]) * (0.82 + 0.28 * beat);
      const hue = this.hueBase(t) + i * 38;
      const l = 0.30 + 0.13 * beat + 0.08 * bars[bi];
      const c = hslToRgb(hue, 0.85, l);
      const g = ctx.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},0.66)`);
      g.addColorStop(0.55, `rgba(${c[0]},${c[1]},${c[2]},0.26)`);
      g.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`);
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, 6.2831853);
      ctx.fill();
    }
  }

  /** mini 变体：单色金光带，横向渐变两端渐隐，融入卡片 */
  private drawWaves(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const lanes = 2;
    const step = Math.max(4, Math.floor(W / 90));
    for (let k = 0; k < lanes; k++) {
      const amp = H * (0.36 + 0.10 * k) * (0.6 + 0.4 * beat);
      const phase = this.beatPhase * 6.28 + k * 2.1;
      const dir = k % 2 === 0 ? 1 : -1;
      ctx.beginPath();
      for (let x = 0; x <= W; x += step) {
        const p = x / W;
        const bi = Math.min(bars.length - 1, Math.floor(p * bars.length));
        const env = Math.sin(Math.PI * p);
        const yOff = bars[bi] * amp * env *
          Math.sin(p * 6.28 * (1 + k * 0.4) + phase + t * 0.0024 * (k + 1));
        const y = H / 2 + yOff * dir;
        if (x === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      // accent 金色调（hue≈42），亮度分层；横向两端渐隐融入卡片
      const gold = hslToRgb(42, 0.72, k === 0 ? 0.56 : 0.44);
      const grad = ctx.createLinearGradient(0, 0, W, 0);
      grad.addColorStop(0, `rgba(${gold[0]},${gold[1]},${gold[2]},0)`);
      grad.addColorStop(0.18, `rgba(${gold[0]},${gold[1]},${gold[2]},0.85)`);
      grad.addColorStop(0.82, `rgba(${gold[0]},${gold[1]},${gold[2]},0.85)`);
      grad.addColorStop(1, `rgba(${gold[0]},${gold[1]},${gold[2]},0)`);
      ctx.strokeStyle = grad;
      ctx.lineWidth = 2.2 + 1.4 * beat;
      ctx.stroke();
      ctx.globalAlpha = 0.22;
      ctx.lineWidth = 8;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  }

  
  
  /** Canvas onReady 公共初始化：按内部分辨率建双离屏画布 */
  private initOffscreens(): void {
    const wPx = this.displayCtx.width;
    const hPx = this.displayCtx.height;
    if (wPx <= 0 || hPx <= 0) {
      return;
    }
    const scale = this.variant === 'mini'
      ? 1
      : Math.min(1, OFFSCREEN_MAX_DIM / Math.max(wPx, hPx));
    this.offW = Math.max(2, Math.round(wPx * scale));
    this.offH = Math.max(2, Math.round(hPx * scale));
    // 两个离屏画布各自独立 settings，避免共享状态
    this.offA = new OffscreenCanvasRenderingContext2D(this.offW, this.offH, new RenderingContextSettings(true));
    this.offB = new OffscreenCanvasRenderingContext2D(this.offW, this.offH, new RenderingContextSettings(true));
    this.ready = true;
    this.syncState();
  }

  build() {
    if (this.variant === 'mini') {
      Canvas(this.displayCtx)
        .width('100%')
        .height('100%')
        .onReady(() => this.initOffscreens())
    } else {
      // full：全屏容器自身扩展进系统栏（不依赖外层传导）；子画布必须从
      // 容器左上角布局（Stack 默认居中会把 scale 放大后的画面推偏、顶部
      // 露出 window 兜底色），内部显示画布布局取 1/4 尺寸再 scale(4)
      // 放大铺满——内部分辨率与每帧光栅化面积降为 1/16，合成拉伸由 GPU 完成
      Stack({ alignContent: Alignment.TopStart }) {
        Canvas(this.displayCtx)
          .width('25%')
          .height('25%')
          .scale({ x: 4, y: 4, centerX: '0%', centerY: '0%' })
          .onReady(() => this.initOffscreens())
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
