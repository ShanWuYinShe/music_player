import { curves } from '@kit.ArkUI';
import { CoverArt } from './CoverArt';

/** 滑动切歌成功阈值（vp）：与 PlayerPage 可视化舞台手势共用同一判定 */
export const COVER_SWIPE_THRESHOLD: number = 60;
/** 旧封面滑出时长（ms）：切歌过渡约 250~300ms */
const SWIPE_EXIT_MS: number = 260;
/** 新封面滑入时长（ms） */
const SWIPE_ENTER_MS: number = 260;
/** 按钮/队列切歌的交叉淡化时长（ms）：旧 crossfade 效果不退化 */
const SWAP_FADE_MS: number = 260;
/** 暂停态缩放过渡时长（ms）：沿用旧隐式动画的 360ms 手感 */
const PLAYSCALE_MS: number = 360;
/** 暂停态缩放比例 */
const PAUSED_SCALE: number = 0.94;
/** 滑出/滑入距离量不到时的兜底宽度（vp） */
const FALLBACK_WIDTH_VP: number = 320;

/**
 * 封面滑动容器：把跟手位移下沉到子组件，避免页面级逐帧重建。
 * 链上无任何隐式 .animation——跟手 translate 必须即时（隐式动画会让
 * 位移被 360ms 缓追，旧 bug 根因），暂停态缩放/切歌过渡一律显式
 * animateTo 触发。滑动切歌成功时旧封面沿滑动方向滑出、新封面从对侧
 * 滑入（禁止弹簧回弹）；未达阈值松手弹簧回弹（取消语义）。
 */
@ComponentV2
export struct CoverSwipe {
  /** 播放态：驱动暂停缩放/变暗（渲染读 @Param，父子直连可靠） */
  @Param isPlaying: boolean = true;
  /** 当前封面路径（父组件 song 镜像传入） */
  @Param coverPath: string = '';
  /** 当前曲 id（封面种子 + 切歌检测） */
  @Param seedId: string = '';
  /** 滑动切歌成功回调（超阈值才调，父组件做实际切歌） */
  @Event onSwipeEnd: (offsetX: number) => void = () => {
  };
  /** 点按封面回调（父组件切入可视化舞台） */
  @Event onTap: () => void = () => {
  };
  /** 当前层位移：拖动跟手 / 新封面滑入，二者互斥同一时刻只处其一 */
  @Local dragX: number = 0;
  /** 暂停态缩放（显式动画驱动，无隐式 animation） */
  @Local playScale: number = 1;
  /** 按钮切歌交叉淡化（1 常态，0 瞬隐后显式淡入） */
  @Local swapFade: number = 1;
  /** 退出层可见性：成功滑动后承载旧封面滑出 */
  @Local showExit: boolean = false;
  /** 退出层旧封面快照 */
  @Local oldPath: string = '';
  @Local oldSeed: string = '';
  /** 退出层位移（从跟手位置起沿滑动方向滑出） */
  @Local exitX: number = 0;
  /** 进行中的滑动方向（0 无过渡，-1 左滑下一首，1 右滑上一首） */
  private slideDir: number = 0;
  /** 当前层是否在位：滑动成功后隐藏，等新封面参数到达再从对侧滑入 */
  @Local entered: boolean = true;
  /** 组件实宽（vp）：滑出/滑入距离 */
  @Local widthVp: number = 0;
  /** 滑动起始位移（曲目未变化时的回弹兜底起点） */
  private startX: number = 0;
  /** 进入收尾定时器 / 曲目未变化兜底定时器 */
  private finishTimer: number = -1;
  private fallbackTimer: number = -1;

  aboutToAppear(): void {
    this.playScale = this.isPlaying ? 1 : PAUSED_SCALE;
  }

  aboutToDisappear(): void {
    this.clearTimers();
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

  /** 曲目变化：滑动成功走新封面对侧滑入，其余（按钮/队列）走交叉淡化 */
  @Monitor('seedId')
  onSeedChange(): void {
    if (this.slideDir === 0) {
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
      return;
    }
    const dir = this.slideDir;
    this.clearFallback();
    this.entered = true;
    this.dragX = -dir * this.slideDist();
    this.getUIContext().animateTo({ duration: SWIPE_ENTER_MS, curve: Curve.EaseOut }, () => {
      this.dragX = 0;
    });
    this.finishTimer = setTimeout(() => {
      this.finishTimer = -1;
      this.showExit = false;
      this.slideDir = 0;
      this.exitX = 0;
    }, SWIPE_ENTER_MS + 80);
  }

  private slideDist(): number {
    return this.widthVp > 0 ? this.widthVp : FALLBACK_WIDTH_VP;
  }

  private clearFallback(): void {
    if (this.fallbackTimer >= 0) {
      clearTimeout(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
  }

  private clearTimers(): void {
    this.clearFallback();
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
    }
  }

  /** 滑动成功：旧封面继续滑出，通知父组件切歌，新封面到达后滑入 */
  private beginSlideOut(offsetX: number): void {
    const dir = offsetX < 0 ? -1 : 1;
    this.slideDir = dir;
    this.startX = offsetX;
    this.entered = false;
    this.oldPath = this.coverPath;
    this.oldSeed = this.seedId;
    this.showExit = true;
    this.exitX = this.dragX;
    // 当前层复位在隐藏中进行，无可见跳变
    this.dragX = 0;
    this.getUIContext().animateTo({ duration: SWIPE_EXIT_MS, curve: Curve.EaseOut }, () => {
      this.exitX = dir * this.slideDist();
    });
    // 音频立即切换（父组件切歌），新封面由 seedId 监听接应滑入
    this.onSwipeEnd(offsetX);
    // 兜底：曲目未变化（单曲循环同一首等）时退化为弹簧回弹，不留黑层
    this.fallbackTimer = setTimeout(() => {
      this.fallbackTimer = -1;
      if (this.slideDir !== 0) {
        this.showExit = false;
        this.entered = true;
        this.dragX = this.startX;
        this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
          this.dragX = 0;
        });
        this.slideDir = 0;
        this.exitX = 0;
      }
    }, SWIPE_EXIT_MS + 150);
  }

  /** 未达阈值：弹簧回弹（取消语义） */
  private springBack(): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.dragX = 0;
    });
  }

  build() {
    Stack() {
      if (this.showExit) {
        CoverArt({ coverPath: this.oldPath, seedId: this.oldSeed, radius: 16, glyphSize: 56, onStage: true })
          .width('100%')
          .height('100%')
          .translate({ x: this.exitX })
      }
      CoverArt({ coverPath: this.coverPath, seedId: this.seedId, radius: 16, glyphSize: 56, onStage: true })
        .width('100%')
        .height('100%')
        .scale({ x: this.playScale, y: this.playScale })
        .opacity(this.swapFade * (this.isPlaying ? 1.0 : 0.7))
        .translate({ x: this.dragX })
        .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        .visibility(this.entered ? Visibility.Visible : Visibility.Hidden)
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.widthVp = area.width as number;
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .onActionUpdate((e: GestureEvent): void => {
          if (this.slideDir !== 0) {
            return;
          }
          this.dragX = e.offsetX;
        })
        .onActionEnd((e: GestureEvent): void => {
          if (this.slideDir !== 0) {
            return;
          }
          const offsetX = e.offsetX;
          if (Math.abs(offsetX) < COVER_SWIPE_THRESHOLD) {
            this.springBack();
            return;
          }
          this.beginSlideOut(offsetX);
        })
        .onActionCancel((): void => {
          if (this.slideDir !== 0) {
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
