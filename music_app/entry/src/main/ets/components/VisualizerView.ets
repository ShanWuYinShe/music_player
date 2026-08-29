/**
 * VisualizerView：MilkDrop 风格音乐可视化（@ComponentV2）。
 *
 * 平台无频谱 API，频段能量由 VisualizerCore 合成（种子 = 曲目 id）。
 * full：XComponent(SURFACE)+GLES3 shader 管线（当前打包单一场景「全屏极光」）——
 *   5 层 fbm 帘幕沿整个画面高度铺开（底层帘从画面下缘升起、光柱贯穿全屏），
 *   颜色随高度翠绿→青→蓝→紫粉渐变 + 缓慢面相漂移，配银河斜带、双层闪烁星空
 *   与地平线山脊剪影；柔和色调映射出梦幻感。
 *   运算量只与像素数相关、半分辨率（1/2）渲染线性上屏；反馈拖尾轻度参与柔化。
 * mini：全宽金色频谱柱，垫于迷你条卡片底层（2D Canvas 双离屏 ping-pong）。
 * 帧驱动 displaySync 限 30fps，暂停后跑约 0.9s 收敛即停。
 */

import displaySync from '@ohos.graphics.displaySync';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlayerController } from '../player/PlayerController';
import {
  seedFromId, synthSpectrum, beatEnvelope, bpmFromSeed, hash01, hslToRgb
} from '../common/VisualizerCore';
import entry from 'libentry.so';

/** 可视化风格总数（与 CMakeLists.txt 的 SHADER_SCENES 条数一致）；当前只有极光一个场景 */
export const PRESET_COUNT = 1;

/** 风格显示名（与 cpp/shaders/ 下打包进 so 的场景一一对应） */
export const VIZ_PRESET_NAMES: string[] = ['全屏极光'];

/** XComponent onLoad 回调的运行时 context 形态（声明层面为 object，此处收窄） */
interface XComponentNativeHandle {
  getNativeHandle(): number;
}

interface XComponentVizContext {
  __NATIVE_XCOMPONENT_OBJ__: XComponentNativeHandle;
}

/** 离屏画布最长边上限：全屏模式下降采样（blur 反馈本身柔化，观感优先） */
const OFFSCREEN_MAX_DIM = 300;
/** 暂停后收敛动画时长（ms），之后停帧保留静帧 */
const FADE_MS = 900;
/** 绘帧最小间隔：须小于 displaySync 回调间隔 + 余量才能保证每次回调都
 * 落帧。高刷真机上 displaySync 超预期回调（30fps≈33.3ms），阈值取 25ms
 * 容差；此前 36ms 阈值把 33.3ms 回调成片跳过（实际 15fps 脉冲闪，已踩坑，
 * 与 2D 管线内容耗时 46ms 时"内容主导"的失败模式不同）。 */
const FRAME_MIN_INTERVAL = 25;
/** 风格参数演化周期（ms）：参数空间在此周期间平滑漂移，效果无穷演化 */
const STYLE_PERIOD = 24000;

@ComponentV2
export struct VisualizerView {
  @Param @Require player: PlayerController;
  /** 'full' 播放页全屏；'mini' 迷你条内嵌 */
  @Param variant: string = 'full';
  /** 当前风格号（父页面持有，切换按钮与背景点击共用同一数据源） */
  @Param presetIndex: number = 0;
  /** 风格过渡进度 0→1（切换后 1.5s 内新场景渐入，旧画面靠反馈余晖消散） */
  private presetTrans: number = 1;
  /** 请求切换风格（背景点击触发；父页面更新 presetIndex 后经 @Param 回流） */
  @Event onPresetChange: (next: number) => void = (): void => {};

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
  /** 当前风格号（仅点击可视化区域切换，无自动轮换） */
  private presetLock: number = 0;
  private beatPhase = 0;
  /** 有效播放时钟：暂停期间不走，保证画面冻结在暂停时刻 */
  private playClock = 0;
  private lastNow = 0;
  private fadeDeadline = 0;
  private frameLog = 0;

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

  /** 外部 presetIndex 变化时同步到渲染用的 presetLock */
  @Monitor('presetIndex')
  onPresetIndexChange(): void {
    const next = ((this.presetIndex % PRESET_COUNT) + PRESET_COUNT) % PRESET_COUNT;
    if (next !== this.presetLock) {
      this.presetTrans = 0;   // 风格变化：启动渐入过渡（不清空反馈画布）
    }
    this.presetLock = next;
  }

  /** 点击可视化区域：循环切换到下一个风格（本地即时生效 + 通知父页面同步状态） */
  private cyclePreset(): void {
    const next = (this.presetLock + 1) % PRESET_COUNT;
    this.presetLock = next;
    this.onPresetChange(next);
  }

  private frame(): void {
    if (this.disposed || !this.ready) {
      return;
    }
    // mini 依赖离屏画布; full 走 XComponent 原生表面, 无离屏上下文
    if (this.variant === 'mini' && (this.offA === null || this.offB === null)) {
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
    // full：shader 管线上屏（XComponent 原生表面，fragment 逐像素解算——
    // 运算量与像素数相关、与效果复杂度无关，参数驱动）。帧驱动沿用
    // displaySync 节流；暂停时不渲染即冻结帧。
    if (this.variant !== 'mini') {
      // 音乐律动参数（平台无频谱 API，为种子+时间的确定性合成——与迷你条同源）：
      // beat 节拍包络 / bass 低频段 / treble 高频段，仅驱动 shader 局部元素
      const beat = beatEnvelope(t, bpmFromSeed(this.seed), this.beatPhase);
      const spec = synthSpectrum(this.seed, t, 8);
      const bass = (spec[0] + spec[1]) / 2;
      const treble = (spec[6] + spec[7]) / 2;
      if (this.presetTrans < 1) {
        this.presetTrans = Math.min(1, this.presetTrans + dt / 1500);
      }
      entry.renderFrame(t, this.seed, playing, beat, bass, treble, this.presetLock, this.presetTrans);
      if (!playing && now > this.fadeDeadline) {
        this.stopLoop();
      }
      return;
    }
    const beat = beatEnvelope(t, bpmFromSeed(this.seed), this.beatPhase);

    const bars = synthSpectrum(this.seed, t, 24);
    const active = (this.flip ? this.offA : this.offB) as OffscreenCanvasRenderingContext2D;
    const W = this.offW;
    const H = this.offH;

    active.clearRect(0, 0, W, H);
    // 反馈层：无变换整帧 alpha 叠加（颜色融合拖尾）。
    if (this.prevBitmap !== null) {
      active.globalAlpha = playing ? 0.50 : 0.90;
      active.drawImage(this.prevBitmap, 0, 0, W, H);
    }

    active.globalCompositeOperation = 'source-over';
    active.globalAlpha = 1;
    this.drawBars(active, t, beat, bars, W, H);
    active.globalCompositeOperation = 'source-over';

    const bmp = active.transferToImageBitmap();
    // 原子上屏：copy 模式单条指令完成「清空+绘制」，避免 clearRect 与
    // drawImage 两条指令之间被合成器采样到空帧（整屏闪一下底色）。
    this.displayCtx.globalCompositeOperation = 'copy';
    this.displayCtx.drawImage(bmp, 0, 0, this.displayCtx.width, this.displayCtx.height);
    this.displayCtx.globalCompositeOperation = 'source-over';
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
   * 慢速演化；每个花域叠两层自相似缩放（分形层次），色相经域扭曲
   * （domain warp：hue 随位置正弦扰动），lighter 叠加融合。
   */
  private drawBlooms(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = 4;
    const m0 = Math.min(W, H);
    for (let i = 0; i < N; i++) {
      // 位置：主漂移 + 双频扰动（Lissajous）——更快更灵动的漂浮轨迹
      const fx = 0.0007 + hash01(this.seed + i * 7 + 1) * 0.0016;
      const fy = 0.0006 + hash01(this.seed + i * 13 + 5) * 0.0013;
      const wx = 0.0016 + hash01(this.seed + i * 17 + 3) * 0.0022;
      const wy = 0.0014 + hash01(this.seed + i * 23 + 7) * 0.0018;
      const phx = hash01(this.seed + i * 29 + 11) * 6.2831853;
      const phy = hash01(this.seed + i * 41 + 17) * 6.2831853;
      const phx2 = hash01(this.seed + i * 67 + 19) * 6.2831853;
      const phy2 = hash01(this.seed + i * 71 + 23) * 6.2831853;
      const x = W / 2 + W * 0.30 * Math.sin(t * fx + phx) + W * 0.08 * Math.sin(t * wx + phx2);
      const y = H * 0.47 + H * 0.26 * Math.sin(t * fy + phy) + H * 0.07 * Math.sin(t * wy + phy2);
      const bi = Math.min(bars.length - 1, Math.floor(i * bars.length / N));
      const baseR = m0 * (0.14 + 0.14 * bars[bi]) * (0.84 + 0.26 * beat);
      // Superformula 参数：非整数 m 使花瓣错位缓旋，永不重复
      const m = 1.5 + 5.5 * this.styleParam(10 + i, t, 0, 1);
      const n1 = 0.7 + 0.7 * this.styleParam(20 + i, t, 0, 1);
      const n2 = 0.3 + 1.7 * this.styleParam(30 + i, t, 0, 1);
      const n3 = 0.3 + 1.7 * this.styleParam(40 + i, t, 0, 1);
      const rot = t * (0.00008 + 0.00022 * this.styleParam(50 + i, t, 0, 1));
      // 各花色相以不同速率独立流动，色彩层次更丰富
      const baseHue = (t * (0.020 + 0.0045 * i) + this.seed + i * 47) % 360;
      const layers = [1.0];
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
        const STEPS = 40;
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

  /**
   * 曲线扩散光带：螺旋旋涡带（两次采样、阿基米德螺线、内亮外淡、慢速
   * 自转）+ 扩散弧环（从中心向外推移淡出、相位错开循环）。全部为连续
   * 曲线描边——无矩形边界、无全屏脉冲；alpha 低避免 lighter 累积过曝。
   */
  private drawRibbons(ctx: OffscreenCanvasRenderingContext2D, t: number, W: number, H: number): void {
    const m0 = Math.min(W, H);
    const cx = W / 2;
    const cy = H * 0.47;
    ctx.lineCap = 'round';
    // 螺旋带：两条,不同速率与色相,分段绘制以做内亮外淡的衰减
    for (let s = 0; s < 2; s++) {
      const rot = t * (0.00010 + 0.00010 * s) + s * 2.6;
      const hue = (t * (0.016 + 0.005 * s) + this.seed + s * 130) % 360;
      const c = hslToRgb(hue, 0.85, 0.55);
      const turns = 2.0 + 0.4 * s;
      const segs = 6;
      for (let seg = 0; seg < segs; seg++) {
        const a0 = seg / segs;
        const dt = 1 / segs;
        ctx.beginPath();
        const steps = Math.max(6, Math.round(turns * 36 / segs));
        for (let j = 0; j <= steps; j++) {
          const u = a0 + dt * j / steps;
          const th = u * turns * 2 * Math.PI + rot;
          const r = m0 * (0.06 + 0.85 * u) * (1 + 0.06 * Math.sin(t * 0.0004 + s * 1.3));
          const x = cx + r * Math.cos(th);
          const y = cy + r * Math.sin(th);
          if (j === 0) {
            ctx.moveTo(x, y);
          } else {
            ctx.lineTo(x, y);
          }
        }
        ctx.strokeStyle = `rgba(${c[0]},${c[1]},${c[2]},${0.22 * (1 - a0)})`;
        ctx.lineWidth = 4;
        ctx.stroke();
      }
    }
    // 扩散弧环：三条相位错开,由内向外推移并淡出,周期循环
    for (let q = 0; q < 3; q++) {
      const prog = (t * 0.00022 + q / 3) % 1;
      const rad = m0 * (0.16 + 0.72 * prog);
      const alpha = 0.15 * (1 - prog);
      const hue = (t * 0.012 + this.seed + q * 90) % 360;
      const c = hslToRgb(hue, 0.8, 0.5);
      ctx.beginPath();
      const start = t * 0.0008 + q * 2.1;
      ctx.arc(cx, cy, rad, start, start + Math.PI * 1.7);
      ctx.strokeStyle = `rgba(${c[0]},${c[1]},${c[2]},${alpha})`;
      ctx.lineWidth = 4;
      ctx.stroke();
    }
  }

  /**
   * 漂浮光斑：十余颗小光点沿 Lissajous 轨道缓慢漂移、亮度轻闪，色彩随
   * 全色环低速流动。全部为局部小元素（半径 ≤6px 离屏单位），填充用
   * 小矩形+径向渐变省去 path，不形成任何全屏/边界效应。
   */
  private drawMotes(ctx: OffscreenCanvasRenderingContext2D, t: number, W: number, H: number): void {
    const N = 10;
    for (let i = 0; i < N; i++) {
      const w1 = 0.0008 + hash01(this.seed + i * 5 + 2) * 0.0012;
      const w2 = 0.0010 + hash01(this.seed + i * 9 + 4) * 0.0016;
      const px = hash01(this.seed + i * 31 + 6) * 6.2831853;
      const py = hash01(this.seed + i * 37 + 8) * 6.2831853;
      const x = W / 2 + W * 0.42 * Math.sin(t * w1 + px) * Math.cos(t * w2 * 0.6 + py);
      const y = H * 0.47 + H * 0.34 * Math.cos(t * w1 * 0.8 + py) * Math.sin(t * w2 + px);
      const r = 2 + 4 * hash01(this.seed + i * 43 + 12);
      const flare = 0.55 + 0.45 * Math.sin(t * 0.002 + i * 1.7);
      const hue = (t * 0.012 + this.seed + i * 31) % 360;
      const c = hslToRgb(hue, 0.8, 0.5);
      const g = ctx.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},${0.5 * flare})`);
      g.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`);
      ctx.fillStyle = g;
      ctx.fillRect(x - r, y - r, r * 2, r * 2);
    }
  }

  /** mini 变体：全宽背景频谱——金色圆头竖柱铺满迷你条卡片，垫在内容之下；
   *  柱阵限制在卡片下半区、垂直渐隐（柱顶淡出）+ 横向两端包络，像从卡片
   *  底部轻涌的金色微光，与卡片圆角和前景内容自然融合 */
  private drawBars(ctx: OffscreenCanvasRenderingContext2D, t: number, beat: number,
    bars: number[], W: number, H: number): void {
    const N = bars.length;
    const pad = Math.max(3, Math.floor(W * 0.03));
    const slot = (W - pad * 2) / N;
    const bw = Math.max(2, slot * 0.42);
    const gold = hslToRgb(38, 0.62, 0.48);
    // 垂直渐变：柱底清晰 → 柱顶淡出
    const grad = ctx.createLinearGradient(0, H, 0, H * 0.35);
    grad.addColorStop(0, `rgba(${gold[0]},${gold[1]},${gold[2]},0.5)`);
    grad.addColorStop(1, `rgba(${gold[0]},${gold[1]},${gold[2]},0.08)`);
    ctx.strokeStyle = grad;
    ctx.lineCap = 'round';
    ctx.lineWidth = bw;
    for (let i = 0; i < N; i++) {
      const cx = pad + slot * (i + 0.5);
      // 高度：频段能量 + 相位差摆动，整排错落起伏；只占下半区
      const sway = 0.82 + 0.18 * Math.sin(t * 0.0035 + i * 0.9);
      const h = Math.max(bw, bars[i] * H * 0.42 * sway);
      // 横向两端包络（sin 半波），边缘柱渐隐融入卡片圆角
      const side = Math.sin(Math.PI * (i + 0.5) / N);
      ctx.globalAlpha = 0.35 + 0.65 * side;
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
      // full：shader 渲染原生表面。XComponent(SURFACE) + EGL/GLES，
      // fragment shader 逐像素解算全部效果——运算量固定、参数驱动，
      // 无 Canvas 分块/位图放大等 CPU 管线与伪影。
      Stack({ alignContent: Alignment.TopStart }) {
        XComponent({
          id: 'viz_full',
          type: XComponentType.SURFACE,
          libraryname: 'entry'
        })
          .width('100%')
          .height('100%')
          .onClick(() => this.cyclePreset())
          .onLoad((context) => {
            // 官方模板桥接：把 __NATIVE_XCOMPONENT_OBJ__ 包装对象传给 NAPI，
            // native 侧 napi_unwrap 解出 OH_NativeXComponent* 再注册回调
            entry.registerXComponent((context as XComponentVizContext).__NATIVE_XCOMPONENT_OBJ__);
            // 渲染管线就绪(原 Canvas 路径由 onReady 置位, XComponent 无对应事件):
            // 立即启动帧循环, 正在播放时画面即刻出现
            this.ready = true;
            this.syncState();
          })
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
