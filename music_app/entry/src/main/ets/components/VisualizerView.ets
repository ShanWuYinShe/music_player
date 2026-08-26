/**
 * VisualizerView：MilkDrop 风格音乐可视化（@ComponentV2）。
 *
 * 平台无频谱 API，频段能量由 VisualizerCore 合成（种子 = 曲目 id）。
 * full：双离屏画布 ping-pong 反馈——上一帧经 blur(3px) + 缩放 + 随节拍
 * 起伏的旋转重绘为基底，锐利边缘随帧指数衰减成色雾，叠加液态光域
 * （metaball，lighter 融合），呈大面积柔和流转的流体色彩。
 * mini：经典频谱柱（金色圆头竖柱），挂于迷你条播放按钮位。
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
    // 涡流：旋转速度随节拍起伏，画面绕中心持续缓旋
    this.feedbackSpin += (0.0000095 + 0.0000180 * beat) * dt;

    const bars = synthSpectrum(this.seed, t, mini ? 4 : 48);
    const active = this.flip ? this.offA : this.offB;
    const W = this.offW;
    const H = this.offH;

    active.clearRect(0, 0, W, H);
    // full：底色为深暗色，画面边缘与屏幕物理边缘连续；mini 透明底
    if (!mini) {
      active.fillStyle = 'rgb(22,19,16)';
      active.fillRect(0, 0, W, H);
    }
    // 反馈层：上一帧经 blur 重绘成柔化拖尾——任何锐利边缘随帧指数衰减成
    // 色雾（MilkDrop 的"柔"正源于此），叠加缩放+旋转形成涡流涌动
    if (this.prevBitmap !== null) {
      active.save();
      active.globalAlpha = playing ? (mini ? 0.55 : 0.978) : 0.90;
      active.translate(W / 2, H / 2);
      const zoom = 1 + (0.018 + 0.024 * beat) * (mini ? 0.5 : 1);
      active.scale(zoom, zoom);
      active.rotate(this.feedbackSpin);
      active.translate(-W / 2, -H / 2);
      if (!mini) {
        active.filter = 'blur(3px)';
      }
      active.drawImage(this.prevBitmap, 0, 0, W, H);
      active.filter = 'none';
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
      this.drawBars(active, t, beat, bars, W, H);
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
   * 液态光域（metaball）：少量大而柔的径向渐变光球按 Lissajous 曲线永不
   * 重复地漂移，半径随频谱段与节拍呼吸；lighter 叠加相遇融合，配合 blur
   * 反馈拖尾呈大面积柔和流转的色域——圆润无棱角。
   */
  private drawLiquid(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = 6;
    const m = Math.min(W, H);
    for (let i = 0; i < N; i++) {
      // 互质近似频率的 Lissajous 轨迹：路径永不重复，变幻莫测
      const fx = 0.00022 + hash01(this.seed + i * 7 + 1) * 0.00062;
      const fy = 0.00019 + hash01(this.seed + i * 13 + 5) * 0.00055;
      const phx = hash01(this.seed + i * 29 + 11) * 6.2831853;
      const phy = hash01(this.seed + i * 41 + 17) * 6.2831853;
      const x = W / 2 + W * 0.32 * Math.sin(t * fx + phx);
      const y = H * 0.47 + H * 0.28 * Math.sin(t * fy + phy);
      const bi = Math.min(bars.length - 1, Math.floor(i * bars.length / N));
      const r = m * (0.16 + 0.16 * bars[bi]) * (0.84 + 0.26 * beat);
      const hue = this.hueBase(t) + i * 30;
      const l = 0.28 + 0.11 * beat + 0.07 * bars[bi];
      const c = hslToRgb(hue, 0.8, l);
      const g = ctx.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},0.5)`);
      g.addColorStop(0.55, `rgba(${c[0]},${c[1]},${c[2]},0.18)`);
      g.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`);
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, 6.2831853);
      ctx.fill();
    }
  }

  /** mini 变体：经典频谱柱——4 根金色圆头竖柱随频段跳动，底部对齐 */
  private drawBars(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = bars.length;
    const pad = Math.max(2, Math.floor(W * 0.10));
    const slot = (W - pad * 2) / N;
    const bw = Math.max(2.5, slot * 0.42);
    const gold = hslToRgb(38, 0.68, 0.50);
    ctx.strokeStyle = `rgb(${gold[0]},${gold[1]},${gold[2]})`;
    ctx.lineCap = 'round';
    ctx.lineWidth = bw;
    for (let i = 0; i < N; i++) {
      const cx = pad + slot * (i + 0.5);
      // 高度：频段能量 + 各柱相位差的轻微摆动，跳动错落
      const sway = 0.85 + 0.15 * Math.sin(t * 0.004 + i * 1.7);
      const h = Math.max(bw, bars[i] * H * 0.88 * sway);
      ctx.beginPath();
      ctx.moveTo(cx, H - bw / 2 - 1);
      ctx.lineTo(cx, H - 1 - h);
      ctx.stroke();
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
