/**
 * VisualizerView：MilkDrop 风格音乐可视化（@ComponentV2）。
 *
 * 平台无频谱 API，频段能量由 VisualizerCore 合成（种子 = 曲目 id）。
 * full：双离屏画布 ping-pong 反馈——上一帧按网格分块沿连续正弦流场偏移
 * 重绘（domain warp 变形，shader 式），叠加 Superformula 超级公式花域
 * （光滑有机曲线，参数 m/n 由 styleParam 在参数空间慢速漂移演化——
 * 不预设形态，几个基元函数产生无穷变换；三层自相似缩放呈分形层次，
 * 色相经域扭曲流动），上屏整帧 blur 柔化，无任何多边形锐边。
 * mini：全宽金色频谱柱，垫于迷你条卡片底层。
 * 帧驱动 displaySync 限 24fps，暂停后跑约 0.9s 收敛动画即停。
 */

import displaySync from '@ohos.graphics.displaySync';
import { PlayerController } from '../player/PlayerController';
import {
  seedFromId, synthSpectrum, beatEnvelope, bpmFromSeed, hash01, hslToRgb, rgbStyle
} from '../common/VisualizerCore';

/** 离屏画布最长边上限：全屏模式下降采样（blur 反馈本身柔化，观感优先） */
const OFFSCREEN_MAX_DIM = 360;
/** 暂停后收敛动画时长（ms），之后停帧保留静帧 */
const FADE_MS = 900;
/** 绘帧最小间隔：24fps 对拖尾流动观感无感知差异，控制 CPU 总耗 */
const FRAME_MIN_INTERVAL = 42;
/** 风格参数演化周期（ms）：参数空间在此周期间平滑漂移，效果无穷演化 */
const STYLE_PERIOD = 24000;

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
    // 涡流：旋转只是微弱配角，变形才是主角
    this.feedbackSpin += (0.0000045 + 0.0000090 * beat) * dt;

    const bars = synthSpectrum(this.seed, t, mini ? 24 : 48);
    const active = this.flip ? this.offA : this.offB;
    const W = this.offW;
    const H = this.offH;

    active.clearRect(0, 0, W, H);
    // full：底色为深暗色，画面边缘与屏幕物理边缘连续；mini 透明底
    if (!mini) {
      active.fillStyle = 'rgb(12,10,9)';
      active.fillRect(0, 0, W, H);
    }
    // 反馈层：网格流场变形（domain warp）——上一帧按网格分块，每块沿连续
    // 正弦流场偏移重绘（shader 经典 warp 的 Canvas 近似），叠加微弱缩放
    // 旋转与衰减，画面被持续揉捏变形而非简单旋转放大
    if (this.prevBitmap !== null) {
      active.save();
      active.globalAlpha = playing ? (mini ? 0.50 : 0.958) : 0.90;
      active.translate(W / 2, H / 2);
      const zoom = 1 + (0.008 + 0.012 * beat) * (mini ? 0.5 : 1);
      active.scale(zoom, zoom);
      active.rotate(this.feedbackSpin);
      active.translate(-W / 2, -H / 2);
      if (mini) {
        active.drawImage(this.prevBitmap, 0, 0, W, H);
      } else {
        const GX = 8;
        const GY = 11;
        const cw = W / GX;
        const ch = H / GY;
        // 流场参数：频率/相位/幅度由种子与慢演化参数决定（见 styleParam）
        const amp = W * (0.010 + 0.012 * beat) * this.styleParam(1, t, 0.5, 1.5);
        const k1 = (2.0 + 4.0 * this.styleParam(2, t, 0, 1)) * 6.2831853 / H;
        const k2 = (1.5 + 3.5 * this.styleParam(3, t, 0, 1)) * 6.2831853 / W;
        const w1 = 0.00045 + 0.0009 * this.styleParam(4, t, 0, 1);
        const w2 = 0.00035 + 0.0008 * this.styleParam(5, t, 0, 1);
        for (let gy = 0; gy < GY; gy++) {
          for (let gx = 0; gx < GX; gx++) {
            const x0 = gx * cw;
            const y0 = gy * ch;
            const cx = x0 + cw / 2;
            const cy = y0 + ch / 2;
            const ox = amp * Math.sin(cy * k1 + t * w1);
            const oy = amp * Math.sin(cx * k2 - t * w2);
            // 目标块放大 8% 盖住邻块错位缝，配合上屏 blur 柔化
            active.drawImage(this.prevBitmap, x0, y0, cw, ch,
              x0 + ox, y0 + oy, cw * 1.08, ch * 1.08);
          }
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
      const c0 = hslToRgb(hue, 0.75, 0.10 + 0.06 * beat);
      const c1 = hslToRgb(hue + 30, 0.7, 0.06);
      const grad = active.createRadialGradient(W / 2, H * 0.46, glowR * 0.32, W / 2, H * 0.46, glowR);
      grad.addColorStop(0, `rgb(${c0[0]},${c0[1]},${c0[2]})`);
      grad.addColorStop(0.55, `rgb(${c1[0]},${c1[1]},${c1[2]})`);
      grad.addColorStop(1, 'rgba(0,0,0,0)');
      active.fillStyle = grad;
      active.fillRect(0, 0, W, H);
      this.drawBlooms(active, t, beat, bars, W, H);
    } else {
      this.drawBars(active, t, beat, bars, W, H);
    }
    active.globalCompositeOperation = 'source-over';

    const bmp = active.transferToImageBitmap();
    this.displayCtx.clearRect(0, 0, this.displayCtx.width, this.displayCtx.height);
    // 上屏整帧 blur：网格接缝与一切锐边在此柔化（MilkDrop 的"柔"）
    if (!mini) {
      this.displayCtx.filter = 'blur(2.5px)';
    }
    this.displayCtx.drawImage(bmp, 0, 0, this.displayCtx.width, this.displayCtx.height);
    this.displayCtx.filter = 'none';
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
   * 风格参数自动化（shader 大赛式）：第 id 号参数在长周期 STYLE_PERIOD 之间
   * 从一组 hash 值平滑过渡到下一组——参数空间连续漂移，效果无穷演化、
   * 永不重复，无需预设任何具体形态。返回 [lo, hi] 区间值。
   */
  private styleParam(id: number, t: number, lo: number, hi: number): number {
    const ph = t / STYLE_PERIOD + hash01(this.seed + id * 131) * 64;
    const k = Math.floor(ph);
    const f = ph - k;
    // smoothstep 缓动，避免周期边界跳变
    const s = f * f * (3 - 2 * f);
    const v0 = hash01(this.seed + id * 101 + k * 7);
    const v1 = hash01(this.seed + id * 101 + (k + 1) * 7);
    return lo + (hi - lo) * (v0 + (v1 - v0) * s);
  }

  /**
   * 绽放花域（Superformula）：极坐标超级公式生成光滑有机曲线（花瓣/海星/
   * 液滴等无穷形态由 m/n1/n2/n3 决定，全部连续无棱角），参数由 styleParam
   * 慢速演化；每个花域叠三层自相似缩放（分形层次），色相经域扭曲
   * （domain warp：hue 随位置正弦扰动），lighter 叠加融合。
   */
  private drawBlooms(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = 5;
    const m0 = Math.min(W, H);
    for (let i = 0; i < N; i++) {
      const fx = 0.00022 + hash01(this.seed + i * 7 + 1) * 0.00062;
      const fy = 0.00019 + hash01(this.seed + i * 13 + 5) * 0.00055;
      const phx = hash01(this.seed + i * 29 + 11) * 6.2831853;
      const phy = hash01(this.seed + i * 41 + 17) * 6.2831853;
      const x = W / 2 + W * 0.32 * Math.sin(t * fx + phx);
      const y = H * 0.47 + H * 0.28 * Math.sin(t * fy + phy);
      const bi = Math.min(bars.length - 1, Math.floor(i * bars.length / N));
      const baseR = m0 * (0.14 + 0.14 * bars[bi]) * (0.84 + 0.26 * beat);
      // Superformula 参数：非整数 m 使花瓣错位缓旋，永不重复
      const m = 1.5 + 5.5 * this.styleParam(10 + i, t, 0, 1);
      const n1 = 0.3 + 1.0 * this.styleParam(20 + i, t, 0, 1);
      const n2 = 0.3 + 1.7 * this.styleParam(30 + i, t, 0, 1);
      const n3 = 0.3 + 1.7 * this.styleParam(40 + i, t, 0, 1);
      const rot = t * (0.00008 + 0.00022 * this.styleParam(50 + i, t, 0, 1));
      const baseHue = this.hueBase(t) + i * 30;
      // 三层自相似缩放：分形层次感
      const layers = [1.0, 0.58, 0.32];
      for (let l = 0; l < layers.length; l++) {
        const R = baseR * layers[l];
        // 色相域扭曲：随位置与层深正弦扰动，色彩自身也在流动变形
        const hue = baseHue
          + 26 * Math.sin(t * 0.0006 + i * 2.1 + l * 1.3)
          + 18 * Math.sin(t * 0.00023 + l * 0.9);
        const lgt = 0.24 + 0.08 * beat + 0.05 * bars[bi] - l * 0.03;
        const c = hslToRgb(hue, 0.82, lgt);
        const alphaCore = 0.28 - l * 0.06;
        const g = ctx.createRadialGradient(x, y, 0, x, y, R);
        g.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},${alphaCore})`);
        g.addColorStop(0.6, `rgba(${c[0]},${c[1]},${c[2]},${alphaCore * 0.4})`);
        g.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`);
        ctx.fillStyle = g;
        ctx.beginPath();
        const STEPS = 84;
        for (let s2 = 0; s2 <= STEPS; s2++) {
          const th = s2 / STEPS * 6.2831853;
          const t1 = Math.pow(Math.abs(Math.cos(m * th / 4)), n2);
          const t2 = Math.pow(Math.abs(Math.sin(m * th / 4)), n3);
          const r = R / Math.pow(t1 + t2, 1 / n1);
          const px2 = x + r * Math.cos(th + rot + l * 0.6);
          const py2 = y + r * Math.sin(th + rot + l * 0.6);
          if (s2 === 0) {
            ctx.moveTo(px2, py2);
          } else {
            ctx.lineTo(px2, py2);
          }
        }
        ctx.closePath();
        ctx.fill();
      }
    }
  }

  /** mini 变体：全宽背景频谱——金色圆头竖柱铺满迷你条卡片，垫在内容之下 */
  private drawBars(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = bars.length;
    const pad = Math.max(3, Math.floor(W * 0.03));
    const slot = (W - pad * 2) / N;
    const bw = Math.max(2, slot * 0.42);
    const gold = hslToRgb(38, 0.62, 0.48);
    ctx.strokeStyle = `rgb(${gold[0]},${gold[1]},${gold[2]})`;
    ctx.lineCap = 'round';
    ctx.lineWidth = bw;
    ctx.globalAlpha = 0.5;
    for (let i = 0; i < N; i++) {
      const cx = pad + slot * (i + 0.5);
      // 高度：频段能量 + 相位差摆动，整排错落起伏
      const sway = 0.82 + 0.18 * Math.sin(t * 0.0035 + i * 0.9);
      const h = Math.max(bw, bars[i] * H * 0.9 * sway);
      ctx.beginPath();
      ctx.moveTo(cx, H - bw / 2 - 1);
      ctx.lineTo(cx, H - 1 - h);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
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
