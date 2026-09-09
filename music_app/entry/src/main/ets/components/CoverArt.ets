import { seedFromId, hash01 } from '../common/VisualizerCore';

/** 渐变角度档：曲目 id 哈希散列，避免无封面占位长一个样 */
const COVER_ANGLES: number[] = [135, 45, 90, 160];

/**
 * 封面统一渲染：有内嵌封面走 Image，无封面按曲目 id 派生渐变占位+
 * 音符字形（首页卡片 / 迷你条 / 播放页大封面三处共用；只用现有 token
 * 色，深浅自动适配）。尺寸由父级定（width/height），内部 100% 填充；
 * 圆角与字形大小按场景传入。
 */
@ComponentV2
export struct CoverArt {
  @Param @Require coverPath: string;
  @Param @Require seedId: string;
  @Param radius: number = 14;
  @Param glyphSize: number = 22;
  /** 播放页舞台变体：舞台恒定深底（媒体页惯例），占位走恒暗 viz token 族，
   * 浅色系统模式下不与深舞台冲突 */
  @Param onStage: boolean = false;

  /** 渐变种子（一次哈希，多处复用：角度档 + 方向反转） */
  @Computed
  get gradSeed(): number {
    return seedFromId(this.seedId);
  }

  /** 渐变角度档（哈希取模循环） */
  @Computed
  get angleSlot(): number {
    return this.gradSeed % COVER_ANGLES.length;
  }

  /** 渐变方向是否反转（散列高位 bit，保证相邻曲目不撞脸） */
  @Computed
  get reversed(): boolean {
    return hash01(this.gradSeed) > 0.5;
  }

  build() {
    if (this.coverPath !== '') {
      Image(this.coverPath)
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .objectFit(ImageFit.Cover)
        .autoResize(true)
        .interpolation(ImageInterpolation.Medium)
    } else if (this.onStage) {
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(this.glyphSize)
          .fontColor([$r('app.color.viz_fg_soft')])
      }
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .linearGradient({
        angle: COVER_ANGLES[this.angleSlot],
        colors: this.reversed ?
          [[$r('app.color.viz_line'), 0], [$r('app.color.viz_fg_faint'), 1]] :
          [[$r('app.color.viz_fg_faint'), 0], [$r('app.color.viz_line'), 1]]
      })
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(this.glyphSize)
          .fontColor([$r('app.color.ink_soft')])
      }
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .linearGradient({
        angle: COVER_ANGLES[this.angleSlot],
        colors: this.reversed ?
          [[$r('app.color.surface_alt'), 0], [$r('app.color.accent_soft'), 1]] :
          [[$r('app.color.accent_soft'), 0], [$r('app.color.surface_alt'), 1]]
      })
      .justifyContent(FlexAlign.Center)
    }
  }
}
