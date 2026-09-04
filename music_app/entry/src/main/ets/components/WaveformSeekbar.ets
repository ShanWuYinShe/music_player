import { PlayerController } from '../player/PlayerController';
import { seedFromId, synthSpectrum } from '../common/VisualizerCore';

/** 波形柱数量：太少颗粒感、太多小屏挤迫 */
const BAR_COUNT = 52;
/** 波形高度区间（vp）：min 保证可见，max 在 32 以内与控制区间协调 */
const BAR_MIN_VP = 5;
const BAR_MAX_VP = 30;

/**
 * 波形进度条（Poweramp 招牌交互）：以曲目 id 为种子的确定性伪波形，
 * 已播部分 accent 着色、未播部分暗色；点击任意位置或横向拖动 seek。
 * 平台无音频 PCM 数据，波形高度由 synthSpectrum 固定时刻采样合成
 * （同曲恒定，切歌换形），视觉语义与 Poweramp 的预计算波形一致。
 */
@ComponentV2
export struct WaveformSeekbar {
  @Param @Require player: PlayerController;
  /** 当前曲 id（父组件镜像传入驱动波形重算；直读 player.currentSongId 的
   * @Computed 在真机上不触发，已踩坑） */
  @Param songId: string = '';
  @Param playedColor: Resource = $r('app.color.accent');
  @Param trackColor: Resource = $r('app.color.viz_line');
  /** 拖动中的局部预览比例（-1 无拖动），避免与 timeUpdate 抖动 */
  @Local dragFraction: number = -1;
  /** 组件宽度（vp），手势换算比例用 */
  @Local widthVp: number = 1;
  /** 拖动起始时的进度比例（offsetX 为累计偏移，须从起点换算） */
  private startFraction: number = 0;

  /** 波形柱高度（0~1）：依赖 @Param songId，切歌由父组件镜像驱动重算 */
  @Computed
  get bars(): number[] {
    return synthSpectrum(seedFromId(this.songId), 0, BAR_COUNT);
  }

  /** 当前进度比例（0~1）：拖动预览优先 */
  private fraction(): number {
    if (this.dragFraction >= 0) {
      return this.dragFraction;
    }
    if (this.player.duration <= 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.player.currentTime / this.player.duration));
  }

  private seekTo(fraction: number): void {
    if (this.player.duration <= 0 || !this.player.isPrepared) {
      return;
    }
    this.player.seek(Math.floor(fraction * this.player.duration));
  }

  build() {
    Row({ space: 1.5 }) {
      ForEach(this.bars, (h: number, index: number) => {
        Column()
          .width(0)
          .layoutWeight(1)
          .height(BAR_MIN_VP + h * (BAR_MAX_VP - BAR_MIN_VP))
          .borderRadius(1)
          .backgroundColor(index < this.fraction() * BAR_COUNT ? this.playedColor : this.trackColor)
          .animation({ duration: 120 })
      }, (h: number, index: number) => `${index}_${h.toFixed(3)}`)
    }
    .width('100%')
    // 触控热区达标（≥40vp）：柱体仍 ≤30vp 视觉高度，容器上下留白居中
    .height(40)
    .alignItems(VerticalAlign.Center)
    .accessibilityText('播放进度，点按或拖动调节')
    .onAreaChange((_old: Area, area: Area) => {
      this.widthVp = area.width as number;
    })
    .onClick((event: ClickEvent) => {
      if (this.widthVp > 0) {
        this.seekTo(Math.min(1, Math.max(0, event.x / this.widthVp)));
      }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 4 })
        .onActionStart(() => {
          this.startFraction = this.fraction();
          this.dragFraction = this.startFraction;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.widthVp > 0) {
            this.dragFraction = Math.min(1, Math.max(0, this.startFraction + event.offsetX / this.widthVp));
          }
        })
        .onActionEnd(() => {
          if (this.dragFraction >= 0) {
            this.seekTo(this.dragFraction);
          }
          this.dragFraction = -1;
        })
    )
  }
}
