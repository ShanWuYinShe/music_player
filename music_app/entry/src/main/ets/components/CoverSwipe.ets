import { curves } from '@kit.ArkUI';
import { CoverArt } from './CoverArt';
import { CoverRef } from '../player/PlayerController';

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
/** 滑出/滑入距离量不到时的兜底宽度（vp） */
const FALLBACK_WIDTH_VP: number = 320;

/**
 * 封面滑动 pager：三层结构——live 层（当前参数）、快照层（按下瞬间冻结）、
 * 预览层（隔壁封面，父组件经 peekNext/peekPrevCover 下发）。
 * 拖动中 live 层跟手、预览层从对侧同步跟进（手指走到哪隔壁封面跟到哪，
 * 不是松手后才补）；松手成功且预判命中时快照层滑出、预览层归位，全程无
 * 黑层。链上无任何隐式 .animation——跟手 translate 必须即时（隐式动画会让
 * 位移被 360ms 缓追，旧 bug 根因），暂停态缩放/过渡一律显式 animateTo。
 * 未达阈值、曲目未变（右滑回曲首/单曲重播/空队列）弹簧回弹；无预览
 * （随机模式）或预判落空时直接切 live 淡入，不硬滑一张错封面。
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
  /** 滑动切歌回调（超阈值才调）：返回 'same'（曲目未变→回弹）或新曲 id
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
  /** 当前/快照层位移：拖动跟手 / 退出滑出 */
  @Local dragX: number = 0;
  /** 暂停态缩放（显式动画驱动，无隐式 animation） */
  @Local playScale: number = 1;
  /** 按钮切歌交叉淡化（1 常态，0 瞬隐后显式淡入） */
  @Local swapFade: number = 1;
  /** 按下瞬间的冻结快照（退出动画全程用它，不受切歌参数更新影响） */
  @Local snapPath: string = '';
  @Local snapSeed: string = '';
  @Local snapNext: CoverRef | null = null;
  @Local snapPrev: CoverRef | null = null;
  /** 当前激活的预览（拖动方向实时决定，过零切换；退出时按释放方向锁定） */
  @Local hasActivePreview: boolean = false;
  @Local activePath: string = '';
  @Local activeSeed: string = '';
  /** 组件实宽（vp）：滑出/归位距离 */
  @Local widthVp: number = 0;
  /** 退出收尾定时器 */
  private finishTimer: number = -1;
  /** 期望的新曲 id（收尾核对：退出期间又有外部切歌则淡入遮一下交接） */
  private expectedSeed: string = '';

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
      this.snapNext = this.nextCover;
      this.snapPrev = this.prevCover;
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

  /** 预览层位移：拖动中跟手（方向由拖动符号实时决定），退出时归位到 0。
   * 公式统一为 dragX + dir*dist——退出动画把 dragX 推向 -dir*dist 时，
   * 预览位移自然收敛到 0，无需第二套动画 */
  private previewX(): number {
    if (!this.hasActivePreview) {
      return 0;
    }
    const dir = this.exiting ? this.exitDir : (this.dragX < 0 ? -1 : 1);
    if (dir === 0) {
      return 0;
    }
    return this.dragX + dir * this.slideDist();
  }

  /** 按方向取快照预览并激活（拖动中每次位移更新都调，过零自动切换） */
  private refreshActive(dir: number): void {
    const preview = dir < 0 ? this.snapNext : (dir > 0 ? this.snapPrev : null);
    this.hasActivePreview = preview !== null;
    if (preview !== null) {
      this.activePath = preview.path;
      this.activeSeed = preview.seed;
    }
  }

  /** 滑动成功收尾：快照层滑出、预览层归位（预判命中才进此路径） */
  private beginExit(dir: number, newId: string): void {
    this.expectedSeed = newId;
    this.exitDir = dir;
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
    this.hasActivePreview = false;
    // 退出期间又有外部切歌（实际与期望不一致）：live 淡入遮一下交接
    if (this.seedId !== this.expectedSeed) {
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
    }
    this.expectedSeed = '';
  }

  /** 未达阈值 / 曲目未变：弹簧回弹（取消语义；音频动作如回曲首已生效） */
  private springBack(): void {
    this.swiping = false;
    this.hasActivePreview = false;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.dragX = 0;
    });
  }

  /** 松手成功：先让父组件同步切歌，拿返回值决定视觉路径——'same' 回弹；
   * 预判命中（预览种子 == 新曲）滑出/归位；否则（无预览/预判落空）直接
   * 回到 live（参数已是新封面）淡入，不硬滑一张错封面 */
  private commitSwipe(offsetX: number): void {
    const dir = offsetX < 0 ? -1 : 1;
    this.refreshActive(dir);
    const preview = dir < 0 ? this.snapNext : this.snapPrev;
    const result = this.onSwipeEnd(offsetX);
    if (result === 'same') {
      this.springBack();
      return;
    }
    if (preview === null || preview.seed !== result) {
      this.swiping = false;
      this.hasActivePreview = false;
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
        // 预览层：同步归位到中央（预判命中才有）
        if (this.hasActivePreview) {
          CoverArt({ coverPath: this.activePath, seedId: this.activeSeed, radius: 16, glyphSize: 56, onStage: true })
            .width('100%')
            .height('100%')
            .scale({ x: this.playScale, y: this.playScale })
            .translate({ x: this.previewX() })
            .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        }
      } else {
        // live 层：静止展示 / 拖动跟手
        CoverArt({ coverPath: this.coverPath, seedId: this.seedId, radius: 16, glyphSize: 56, onStage: true })
          .width('100%')
          .height('100%')
          .scale({ x: this.playScale, y: this.playScale })
          .opacity(this.swapFade * (this.isPlaying ? 1.0 : 0.7))
          .translate({ x: this.dragX })
          .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
        // 预览层：拖动中从对侧跟进（方向过零自动切换）
        if (this.swiping && this.hasActivePreview) {
          CoverArt({ coverPath: this.activePath, seedId: this.activeSeed, radius: 16, glyphSize: 56, onStage: true })
            .width('100%')
            .height('100%')
            .scale({ x: this.playScale, y: this.playScale })
            .translate({ x: this.previewX() })
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
          // 按下冻结快照：后续参数更新（切歌）不干扰本次手势
          this.snapPath = this.coverPath;
          this.snapSeed = this.seedId;
          this.snapNext = this.nextCover;
          this.snapPrev = this.prevCover;
          this.hasActivePreview = false;
          this.swiping = true;
        })
        .onActionUpdate((e: GestureEvent): void => {
          if (this.exiting) {
            return;
          }
          this.dragX = e.offsetX;
          this.refreshActive(e.offsetX < 0 ? -1 : (e.offsetX > 0 ? 1 : 0));
        })
        .onActionEnd((e: GestureEvent): void => {
          if (this.exiting) {
            return;
          }
          const offsetX = e.offsetX;
          if (Math.abs(offsetX) < COVER_SWIPE_THRESHOLD) {
            this.springBack();
            return;
          }
          this.commitSwipe(offsetX);
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
