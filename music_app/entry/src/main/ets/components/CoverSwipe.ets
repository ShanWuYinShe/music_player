import { curves } from '@kit.ArkUI';
import { CoverArt } from './CoverArt';
import { CoverRef } from '../player/PlayerController';

/** 滑动切歌成功阈值（vp）：与 PlayerPage 可视化舞台手势共用同一判定 */
export const COVER_SWIPE_THRESHOLD: number = 60;
/** 相邻封面间距（vp）：成熟播放器（Poweramp/Apple Music）的页间留白 */
const CELL_GAP_VP: number = 24;
/** 按钮/队列切歌的交叉淡化时长（ms）：旧 crossfade 效果不退化 */
const SWAP_FADE_MS: number = 260;
/** 暂停态缩放过渡时长（ms）：沿用旧隐式动画的 360ms 手感 */
const PLAYSCALE_MS: number = 360;
/** 暂停态缩放比例 */
const PAUSED_SCALE: number = 0.94;
/** 纸带吸附安全兜底（毫秒）：交接由动画 onFinish 驱动，此定时器只防动画
 * 未回调的极端情况（页面隐藏动画挂起等）；finishSettle 幂等可重入 */
const SAFETY_SETTLE_MS: number = 1500;
/** 宽度量不到时的兜底（vp） */
const FALLBACK_WIDTH_VP: number = 320;
/** 甩动成歌最小位移（vp）：低于此值只认阈值，防抖动误甩 */
const FLING_MIN_OFFSET: number = 20;
/** 甩速统计窗口（ms）：只看松手前这一段的平均速度 */
const FLING_WINDOW_MS: number = 120;
/** 甩动成歌速度（vp/ms）：≈1000vp/s，轻快 flick 远超、沉稳拖动不及 */
const FLING_VP_PER_MS: number = 1.0;
/** 速度采样上限（点）：120ms 窗口足够覆盖，旧点移出 */
const VEL_PTS_CAP: number = 10;
/** 空侧阻尼系数：没有相邻封面的一侧拖动按此比例 rubber-band（封顶见下） */
const RUBBER_FACTOR: number = 0.2;
/** 空侧阻尼最大位移（vp） */
const RUBBER_MAX_VP: number = 24;

/**
 * 封面滑动纸带（成熟播放器的 pager 模型）：
 * 三格 [上一首 | 当前 | 下一首] 常驻挂载（邻居图进场前已解码，拖动零首帧
 * 卡顿），格间 CELL_GAP_VP 空隙，窗口 .clip 裁剪，整条纸带只有 stripX 一次
 * 平移，跟手即时（链上无隐式动画）。
 *
 * 三格内容是**权威来源**（trioL/trioM/trioR），静止态从实况参数同步。
 * 松手成歌时一次性完成"内容旋转 + 位移补偿"：
 *   左滑（下一首）：[上,当,下] → [当,下(目标),空]，stripX += 格距
 *   右滑（上一首）：[上,当,下] → [空,上(目标),当]，stripX -= 格距
 * 内容与位移同帧互抵，**屏幕像素一动不动**，且从此中间格就是目标曲——
 * 后续滑行到落定再无任何"换内容"动作（旧版落定把中格从旧曲换成目标曲，
 * 正是"滑动完成瞬间文字闪一下"的根因）。
 * 落定只做收尾：吸附动画由 onFinish 驱动收敛（禁止固定时长掐断弹簧），
 * 之后同步实况（中格同为它，仅右格补新下一首——在窗外不可见）。
 */
@ComponentV2
export struct CoverSwipe {
  /** 播放态：驱动暂停缩放/变暗（渲染读 @Param，父子直连可靠） */
  @Param isPlaying: boolean = true;
  /** 当前封面路径（父组件 song 镜像传入） */
  @Param coverPath: string = '';
  /** 当前曲 id（封面种子 + 切歌检测） */
  @Param seedId: string = '';
  /** 当前曲歌名（占位首字来源；相邻格经 CoverRef.title 传入） */
  @Param fallbackCurrent: string = '';
  /** 相邻封面预览（父组件状态订阅经 peek 下发；随机/空队列/5 秒规则为 null） */
  @Param nextCover: CoverRef | null = null;
  @Param prevCover: CoverRef | null = null;
  /** 滑动切歌回调（超阈值/甩动才调）：返回 'same'（曲目未变→回中）或新曲 id
   * （真换轨→内容旋转+吸附）；父组件内同步完成切歌 */
  @Event onSwipeEnd: (offsetX: number) => string = () => '';
  /** 点按封面回调（父组件切入可视化舞台） */
  @Event onTap: () => void = () => {
  };
  /** 纸带平移：静止 = -(格宽+间距)（中格居中），拖动叠加跟手位移；内容
   * 旋转时反向补偿一格（逐 tick 唯一的 @Local 写） */
  @Local stripX: number = 0;
  /** 是否已测量（widthVp>0 后纸带才有意义，未测量不画） */
  @Local measured: boolean = false;
  /** 暂停态缩放（显式动画驱动，无隐式 animation） */
  @Local playScale: number = 1;
  /** 按钮切歌交叉淡化（1 常态，0 瞬隐后显式淡入；外部切歌走它） */
  @Local swapFade: number = 1;
  /** 组件实宽（vp）＝格宽 */
  @Local widthVp: number = 0;
  /** 三格内容·左（上一首；旋转后可能为 null＝未知，静止同步时补齐） */
  @Local trioL: CoverRef | null = null;
  /** 三格内容·中（当前曲；成歌后恒为目标曲） */
  @Local trioM: CoverRef = { path: '', seed: '', title: '' };
  /** 三格内容·右（下一首；旋转后可能为 null＝未知，静止同步时补齐） */
  @Local trioR: CoverRef | null = null;
  /** 吸附中（内容与位移已旋转补偿，等待吸附动画收敛） */
  private settling: boolean = false;
  /** 手势进行中（拖动跟手） */
  private dragging: boolean = false;
  /** 吸附安全兜底定时器 */
  private settleTimer: number = -1;
  /** 期望的新曲 id（落定核对：实际曲目不符则交叉淡化遮交接） */
  private expectedSeed: string = '';
  /** 甩速采样（[位移, 时间戳]，松手前 120ms 窗口算平均速度；private 不触发重建） */
  private velPts: number[][] = [];

  aboutToAppear(): void {
    this.playScale = this.isPlaying ? 1 : PAUSED_SCALE;
    this.syncTrio();
  }

  aboutToDisappear(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /** 暂停态变化：显式动画缩放（链上无隐式动画，快照式切换会生硬） */
  @Monitor('isPlaying')
  onPlayingChange(): void {
    const target = this.isPlaying ? 1 : PAUSED_SCALE;
    if (target !== this.playScale) {
      this.getUIContext().animateTo({ duration: PLAYSCALE_MS, curve: Curve.EaseOut }, () => {
        this.playScale = target;
      });
    }
  }

  /** 曲目变化（外部切歌：按钮/队列/播完连播）：静止态才同步三格并交叉淡化；
   * 拖动/吸附中不动（吸附中中格已是目标曲，同步反而是干扰） */
  @Monitor('seedId')
  onSeedChange(): void {
    if (this.dragging || this.settling) {
      return;
    }
    this.syncTrio();
    this.swapFade = 0;
    this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
      this.swapFade = 1;
    });
  }

  /** 邻居变化（队列增删等）：静止态静默同步，不动淡化 */
  @Monitor('prevCover', 'nextCover')
  onNeighborChange(): void {
    if (this.dragging || this.settling) {
      return;
    }
    this.syncTrio();
  }

  /** 从实况参数同步三格（静止态调用：进入页/落定/外部切歌/邻居变化） */
  private syncTrio(): void {
    this.trioL = this.prevCover;
    this.trioM = { path: this.coverPath, seed: this.seedId, title: this.fallbackCurrent };
    this.trioR = this.nextCover;
  }

  private cellW(): number {
    return this.widthVp > 0 ? this.widthVp : FALLBACK_WIDTH_VP;
  }

  /** 格距（格宽+间距）：内容旋转一格的位移补偿量 */
  private pitch(): number {
    return this.cellW() + CELL_GAP_VP;
  }

  /** 静止纸带位移：中格居中 */
  private restX(): number {
    return -this.pitch();
  }

  /** 目标侧是否有封面（决定能否滑过去；静止/拖动时实况即当前曲的邻居） */
  private sideHasCover(dir: number): boolean {
    return dir < 0 ? this.trioR !== null : this.trioL !== null;
  }

  /** 甩动判定：位移未达阈值但松手前 120ms 平均速度达标、且方向一致——
   * 轻快 flick 同样成歌（PanGesture 无速度字段，自采时间戳计算） */
  private isFling(offsetX: number): boolean {
    const dist = Math.abs(offsetX);
    if (dist < FLING_MIN_OFFSET || dist >= COVER_SWIPE_THRESHOLD) {
      return false;
    }
    const pts = this.velPts;
    if (pts.length < 2) {
      return false;
    }
    const lastPt = pts[pts.length - 1];
    const windowStart = lastPt[1] - FLING_WINDOW_MS;
    let refX = pts[0][0];
    let refT = pts[0][1];
    for (let i = 0; i < pts.length; i++) {
      if (pts[i][1] >= windowStart) {
        refX = pts[i][0];
        refT = pts[i][1];
        break;
      }
    }
    const dt = lastPt[1] - refT;
    if (dt <= 0) {
      return false;
    }
    const v = (lastPt[0] - refX) / dt;
    return Math.abs(v) >= FLING_VP_PER_MS && (v < 0) === (offsetX < 0);
  }

  /** 松手成功：切歌 → 内容旋转一格（目标进中格）+ 位移反向补偿一格 →
   * 吸附动画滑到居中。旋转与补偿同帧互抵，屏幕像素不动；此后中格恒为
   * 目标曲，落定不再换内容 */
  private commitSwipe(offsetX: number): void {
    const dir = offsetX < 0 ? -1 : 1;
    const target = dir < 0 ? this.trioR : this.trioL;
    const result = this.onSwipeEnd(offsetX);
    if (result === 'same' || target === null || target.seed !== result) {
      // 曲目未变（回曲首）/目标格缺失（随机模式）/目标与切歌分叉：回中。
      // 分叉时实况已换轨，同步三格并用交叉淡化遮交接
      if (result !== 'same') {
        this.syncTrio();
        this.swapFade = 0;
        this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
          this.swapFade = 1;
        });
      }
      this.springBack();
      return;
    }
    this.dragging = false;
    this.settling = true;
    this.expectedSeed = result;
    this.rotateTrio(dir);
    // 内容旋转一格 → 位移反向补偿一格（左滑 +格距 / 右滑 -格距）：每首歌
    // 在屏幕上的位置原地不动（本次唯一"变化"是纯状态重排，无像素位移）
    this.stripX = this.stripX + (dir < 0 ? this.pitch() : -this.pitch());
    // 吸附：从当前（补偿后的）位置继续沿手指方向滑到中格居中。onFinish
    // 在弹簧逻辑到位时回调（FinishCallbackType.LOGICALLY_COMPLETE 语义），
    // 严禁按固定时长掐断——剩余路程瞬移肉眼可见
    this.getUIContext().animateTo({
      duration: 350,
      curve: curves.springMotion(0.75, 0.9),
      onFinish: (): void => this.finishSettle()
    }, () => {
      this.stripX = this.restX();
    });
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      this.finishSettle();
    }, SAFETY_SETTLE_MS);
  }

  /** 三格内容旋转一格：目标格内容进中格，另一侧空出（静止同步时补齐）
   *   左滑（下一首）：[上,当,下] → [当,下,空]
   *   右滑（上一首）：[上,当,下] → [空,上,当] */
  private rotateTrio(dir: number): void {
    if (dir < 0) {
      this.trioL = this.trioM;
      this.trioM = this.trioR as CoverRef;
      this.trioR = null;
      return;
    }
    this.trioR = this.trioM;
    this.trioM = this.trioL as CoverRef;
    this.trioL = null;
  }

  /** 吸附落定（onFinish 或安全兜底触发，幂等）：此刻中格已是目标曲，只需
   * 收尾——同步实况（中格同为它；右格补上新下一首，在窗外不可见）+ 竞态
   * （实际曲目与预期不符）才交叉淡化遮交接。**不做任何中格内容替换** */
  private finishSettle(): void {
    if (!this.settling) {
      return;
    }
    this.clearSafety();
    this.settling = false;
    this.stripX = this.restX();
    this.syncTrio();
    if (this.seedId !== this.expectedSeed) {
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
    }
    this.expectedSeed = '';
  }

  /** 未达阈值（且非甩动）/ 曲目未变：弹簧回中（取消语义；音频动作如回曲首已生效） */
  private springBack(): void {
    this.dragging = false;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.stripX = this.restX();
    });
  }

  private clearSafety(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  build() {
    Stack() {
      if (this.measured) {
        // 三格纸带：整条只有 stripX 一次平移（内容旋转时同帧补偿，像素不动）
        Row({ space: CELL_GAP_VP }) {
          if (this.trioL !== null) {
            CoverArt({
              coverPath: (this.trioL as CoverRef).path,
              seedId: (this.trioL as CoverRef).seed,
              fallbackText: (this.trioL as CoverRef).title,
              radius: 16, glyphSize: 88, onStage: true
            })
              .width(this.widthVp)
              .height(this.widthVp)
              .scale({ x: this.playScale, y: this.playScale })
              .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          } else {
            Column()
              .width(this.widthVp)
              .height(this.widthVp)
          }
          // 中格：静止=当前曲，成歌后恒为目标曲（全程不再替换）
          CoverArt({
            coverPath: this.trioM.path,
            seedId: this.trioM.seed,
            fallbackText: this.trioM.title,
            radius: 16, glyphSize: 88, onStage: true
          })
            .width(this.widthVp)
            .height(this.widthVp)
            .scale({ x: this.playScale, y: this.playScale })
            .opacity(this.swapFade * (this.isPlaying ? 1.0 : 0.7))
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          if (this.trioR !== null) {
            CoverArt({
              coverPath: (this.trioR as CoverRef).path,
              seedId: (this.trioR as CoverRef).seed,
              fallbackText: (this.trioR as CoverRef).title,
              radius: 16, glyphSize: 88, onStage: true
            })
              .width(this.widthVp)
              .height(this.widthVp)
              .scale({ x: this.playScale, y: this.playScale })
              .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          } else {
            Column()
              .width(this.widthVp)
              .height(this.widthVp)
          }
        }
        .translate({ x: this.stripX })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((_old: Area, area: Area) => {
      const w = area.width as number;
      if (w > 0 && !this.measured) {
        // 首次测量：初始化纸带居中位移（无动画，避免从 0 飞入）
        this.widthVp = w;
        this.stripX = this.restX();
        this.measured = true;
      }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .onActionStart((): void => {
          if (this.settling) {
            return;
          }
          this.dragging = true;
          this.velPts = [];
        })
        .onActionUpdate((e: GestureEvent): void => {
          if (this.settling || !this.dragging) {
            return;
          }
          const raw = e.offsetX;
          // 空侧 rubber-band：没有相邻封面的一侧拖不动（阻尼 + 封顶），
          // "这边没有了"的手感
          const dir = raw < 0 ? -1 : 1;
          const eff = this.sideHasCover(dir) ? raw
            : Math.sign(raw) * Math.min(Math.abs(raw) * RUBBER_FACTOR, RUBBER_MAX_VP);
          // 逐 tick 唯一的 @Local 写（速度采样走 private，不触发重建）
          this.stripX = this.restX() + eff;
          if (this.velPts.length >= VEL_PTS_CAP) {
            this.velPts.shift();
          }
          this.velPts.push([raw, Date.now()]);
        })
        .onActionEnd((e: GestureEvent): void => {
          if (this.settling || !this.dragging) {
            return;
          }
          const offsetX = e.offsetX;
          if (Math.abs(offsetX) >= COVER_SWIPE_THRESHOLD || this.isFling(offsetX)) {
            this.commitSwipe(offsetX);
            return;
          }
          this.springBack();
        })
        .onActionCancel((): void => {
          if (this.settling) {
            return;
          }
          this.springBack();
        })
    )
    .onClick(() => {
      this.onTap();
    })
  }
}
