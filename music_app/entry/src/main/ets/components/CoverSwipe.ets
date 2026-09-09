import { curves } from '@kit.ArkUI';
import { CoverArt } from './CoverArt';
import { CoverPair, CoverRef } from '../player/PlayerController';

/** 滑动切歌成功阈值（vp）：与 PlayerPage 可视化舞台手势共用同一判定 */
export const COVER_SWIPE_THRESHOLD: number = 60;
/** 滑出时长（ms）：快照层沿手势方向滑出、预览层同步归位 */
const SWIPE_EXIT_MS: number = 260;
/** 按钮/队列切歌的交叉淡化时长（ms）：旧 crossfade 效果不退化 */
const SWAP_FADE_MS: number = 260;
/** 暂停态缩放过渡时长（ms）：沿用旧隐式动画的 360ms 手感 */
const PLAYSCALE_MS: number = 360;
/** 暂停态缩放比例 */
const PAUSED_SCALE: number = 0.94;
/** 滑出/归位距离量不到时的兜底宽度（vp） */
const FALLBACK_WIDTH_VP: number = 320;
/** 甩动成歌最小位移（vp）：低于此值只认阈值，防抖动误甩 */
const FLING_MIN_OFFSET: number = 20;
/** 甩速统计窗口（ms）：只看松手前这一段的平均速度 */
const FLING_WINDOW_MS: number = 120;
/** 甩动成歌速度（vp/ms）：≈1000vp/s，轻快 flick 远超、沉稳拖动不及 */
const FLING_VP_PER_MS: number = 1.0;
/** 速度采样上限（点）：120ms 窗口足够覆盖，旧点移出 */
const VEL_PTS_CAP: number = 10;

/**
 * 封面滑动 pager：live 层（当前参数）+ 按下冻结的快照（退出层 + 双侧预览）。
 * 拖动中 live 层跟手、双侧预览（上一首在左/下一首在右）同步跟进——真 pager
 * 纸带，过零换向无挂载抖动（双侧常驻，只随位移平移）；松手成功且预判命中
 * 时快照层滑出、对应侧预览归位，全程无黑层。链上无任何隐式 .animation——
 * 跟手 translate 必须即时（隐式动画会让位移被 360ms 缓追，旧 bug 根因），
 * 暂停态缩放/过渡一律显式 animateTo。未达阈值（且非甩动）、曲目未变（右滑
 * 回曲首/单曲重播/空队列）弹簧回弹；无预览（随机模式）或预判落空时直接切
 * live 淡入，不硬滑一张错封面。快甩（低位移高速度）同样成歌。
 */
@ComponentV2
export struct CoverSwipe {
  /** 播放态：驱动暂停缩放/变暗（渲染读 @Param，父子直连可靠） */
  @Param isPlaying: boolean = true;
  /** 当前封面路径（父组件 song 镜像传入） */
  @Param coverPath: string = '';
  /** 当前曲 id（封面种子 + 切歌检测） */
  @Param seedId: string = '';
  /** 相邻封面预览（父组件经 peek 下发；随机模式/空队列为 null） */
  @Param nextCover: CoverRef | null = null;
  @Param prevCover: CoverRef | null = null;
  /** 按下回调：父组件同步快照预览对并返回（@Param 下发异步，按下时读必旧，
   * 返回值才是新鲜快照；含 5 秒回曲首规则，拖动全程冻结用它） */
  @Event onPressCovers: () => CoverPair = () => ({ prev: null, next: null });
  /** 滑动切歌回调（超阈值/甩动才调）：返回 'same'（曲目未变→回弹）或新曲 id
   * （真换轨→滑出/归位）；父组件内同步完成切歌 */
  @Event onSwipeEnd: (offsetX: number) => string = () => '';
  /** 点按封面回调（父组件切入可视化舞台） */
  @Event onTap: () => void = () => {
  };
  /** 手势进行中（按下→收尾）：图层走快照，live 参数更新不干扰拖动 */
  @Local swiping: boolean = false;
  /** 退出中（预判命中的成功滑动）：快照层滑出、预览层归位，live 隐藏 */
  @Local exiting: boolean = false;
  /** 退出方向（±1，仅 exiting 有效）：预览层归位公式用 */
  @Local exitDir: number = 0;
  /** 当前/快照层位移：拖动跟手 / 退出滑出（逐 tick 唯一的 @Local 写） */
  @Local dragX: number = 0;
  /** 暂停态缩放（显式动画驱动，无隐式 animation） */
  @Local playScale: number = 1;
  /** 按钮切歌交叉淡化（1 常态，0 瞬隐后显式淡入） */
  @Local swapFade: number = 1;
  /** 按下瞬间的冻结快照（退出动画全程用它，不受切歌参数更新影响） */
  @Local snapPath: string = '';
  @Local snapSeed: string = '';
  /** 双侧预览快照（打平为 string + bool，build 内无类型窄化风险） */
  @Local hasPrev: boolean = false;
  @Local prevPath: string = '';
  @Local prevSeed: string = '';
  @Local hasNext: boolean = false;
  @Local nextPath: string = '';
  @Local nextSeed: string = '';
  /** 退出时展示匹配预览（预判命中才置位；落空不硬滑错封面） */
  @Local showExitPreview: boolean = false;
  /** 组件实宽（vp）：滑出/归位距离 */
  @Local widthVp: number = 0;
  /** 退出收尾定时器 */
  private finishTimer: number = -1;
  /** 期望的新曲 id（收尾核对：退出期间又有外部切歌则淡入遮一下交接） */
  private expectedSeed: string = '';
  /** 甩速采样（[位移, 时间戳]，松手前 120ms 窗口算平均速度；private 不触发重建） */
  private velPts: number[][] = [];

  aboutToAppear(): void {
    this.playScale = this.isPlaying ? 1 : PAUSED_SCALE;
  }

  aboutToDisappear(): void {
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
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

  /** 曲目变化：退出中由收尾定时器接应（不与滑出动画打架）；拖动中把快照
   * 换新（播完连播等外部切歌，拖动在新封面上继续）；静止态走交叉淡化 */
  @Monitor('seedId')
  onSeedChange(): void {
    if (this.exiting) {
      return;
    }
    if (this.swiping) {
      this.snapPath = this.coverPath;
      this.snapSeed = this.seedId;
      this.snapCovers(this.prevCover, this.nextCover);
      return;
    }
    this.swapFade = 0;
    this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
      this.swapFade = 1;
    });
  }

  private slideDist(): number {
    return this.widthVp > 0 ? this.widthVp : FALLBACK_WIDTH_VP;
  }

  /** 预览层位移（dir=-1 左侧上一首，1 右侧下一首）：dragX + dir*dist——
   * 拖动跟手、退出归位同一公式（退出把 dragX 推向 -dir*dist 时自然收敛 0） */
  private previewX(dir: number): number {
    return this.dragX + dir * this.slideDist();
  }

  /** 冻结双侧预览快照（按下返回值 / 参数更新两种来源，打平存 string） */
  private snapCovers(prev: CoverRef | null, next: CoverRef | null): void {
    this.hasPrev = prev !== null;
    this.prevPath = prev !== null ? prev.path : '';
    this.prevSeed = prev !== null ? prev.seed : '';
    this.hasNext = next !== null;
    this.nextPath = next !== null ? next.path : '';
    this.nextSeed = next !== null ? next.seed : '';
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

  /** 滑动成功收尾：快照层滑出、匹配侧预览归位（预判命中才进此路径） */
  private beginExit(dir: number, newId: string): void {
    this.expectedSeed = newId;
    this.exitDir = dir;
    this.showExitPreview = true;
    this.exiting = true;
    this.getUIContext().animateTo({ duration: SWIPE_EXIT_MS, curve: Curve.EaseOut }, () => {
      this.dragX = -dir * this.slideDist();
    });
    this.finishTimer = setTimeout(() => {
      this.finishTimer = -1;
      this.finishExit();
    }, SWIPE_EXIT_MS + 80);
  }

  private finishExit(): void {
    if (!this.exiting) {
      return;
    }
    this.exiting = false;
    this.swiping = false;
    this.exitDir = 0;
    this.dragX = 0;
    this.showExitPreview = false;
    // 退出期间又有外部切歌（实际与期望不一致）：live 淡入遮一下交接
    if (this.seedId !== this.expectedSeed) {
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
    }
    this.expectedSeed = '';
  }

  /** 未达阈值（且非甩动）/ 曲目未变：弹簧回弹（取消语义；音频动作如回曲首已生效） */
  private springBack(): void {
    this.swiping = false;
    this.showExitPreview = false;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.dragX = 0;
    });
  }

  /** 松手成功：先让父组件同步切歌，拿返回值决定视觉路径——'same' 回弹；
   * 预判命中（快照预览种子 == 新曲）滑出/归位；否则（无预览/预判落空）
   * 直接回到 live（参数已是新封面）淡入，不硬滑一张错封面 */
  private commitSwipe(offsetX: number): void {
    const dir = offsetX < 0 ? -1 : 1;
    const previewSeed = dir < 0 ? (this.hasNext ? this.nextSeed : '') : (this.hasPrev ? this.prevSeed : '');
    const result = this.onSwipeEnd(offsetX);
    if (result === 'same') {
      this.springBack();
      return;
    }
    if (previewSeed === '' || previewSeed !== result) {
      this.swiping = false;
      this.showExitPreview = false;
      this.dragX = 0;
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
      return;
    }
    this.beginExit(dir, result);
  }

  build() {
    Stack() {
      if (this.exiting) {
        // 快照层：沿手势方向滑出
        CoverArt({ coverPath: this.snapPath, seedId: this.snapSeed, radius: 16, glyphSize: 56, onStage: true })
          .width('100%')
          .height('100%')
          .translate({ x: this.dragX })
        // 匹配侧预览：同步归位到中央
        if (this.showExitPreview) {
          CoverArt({
            coverPath: this.exitDir < 0 ? this.nextPath : this.prevPath,
            seedId: this.exitDir < 0 ? this.nextSeed : this.prevSeed,
            radius: 16, glyphSize: 56, onStage: true
          })
            .width('100%')
            .height('100%')
            .scale({ x: this.playScale, y: this.playScale })
            .translate({ x: this.previewX(this.exitDir) })
            .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        }
      } else {
        // 左侧预览（上一首）：拖动中常驻跟进，无挂载抖动
        if (this.swiping && this.hasPrev) {
          CoverArt({ coverPath: this.prevPath, seedId: this.prevSeed, radius: 16, glyphSize: 56, onStage: true })
            .width('100%')
            .height('100%')
            .scale({ x: this.playScale, y: this.playScale })
            .translate({ x: this.previewX(-1) })
            .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        }
        // live 层：静止展示 / 拖动跟手
        CoverArt({ coverPath: this.coverPath, seedId: this.seedId, radius: 16, glyphSize: 56, onStage: true })
          .width('100%')
          .height('100%')
          .scale({ x: this.playScale, y: this.playScale })
          .opacity(this.swapFade * (this.isPlaying ? 1.0 : 0.7))
          .translate({ x: this.dragX })
          .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        // 右侧预览（下一首）：拖动中常驻跟进
        if (this.swiping && this.hasNext) {
          CoverArt({ coverPath: this.nextPath, seedId: this.nextSeed, radius: 16, glyphSize: 56, onStage: true })
            .width('100%')
            .height('100%')
            .scale({ x: this.playScale, y: this.playScale })
            .translate({ x: this.previewX(1) })
            .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.widthVp = area.width as number;
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .onActionStart((): void => {
          if (this.exiting) {
            return;
          }
          // 按下冻结快照：返回值是父组件同步现算的（含 5 秒规则），必新鲜；
          // 后续参数更新不干扰本次手势
          const pair = this.onPressCovers();
          this.snapPath = this.coverPath;
          this.snapSeed = this.seedId;
          this.snapCovers(pair.prev, pair.next);
          this.showExitPreview = false;
          this.velPts = [];
          this.swiping = true;
        })
        .onActionUpdate((e: GestureEvent): void => {
          if (this.exiting) {
            return;
          }
          // 逐 tick 唯一的 @Local 写（速度采样走 private，不触发重建）
          this.dragX = e.offsetX;
          if (this.velPts.length >= VEL_PTS_CAP) {
            this.velPts.shift();
          }
          this.velPts.push([e.offsetX, Date.now()]);
        })
        .onActionEnd((e: GestureEvent): void => {
          if (this.exiting) {
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
          if (this.exiting) {
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
