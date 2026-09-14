/**
 * 封面统一渲染：有内嵌封面走 Image，无封面以歌名首字做大字排版占位
 * （首页列表/迷你条/播放页纸带三处共用）。尺寸由父级定（width/height），
 * 内部 100% 填充；圆角与字号按场景传入。
 * 占位底色恒定（浅色 surface_alt / 深舞台恒暗 viz token），不做哈希渐变——
 * 用户决策 2026-09：默认封面放歌名，不要哈希派生颜色。
 * 占位首字用文楷 Medium：无封面时以书法字撑起画面（水墨版式以字入画）。
 */
import { INK_FONT_MEDIUM } from '../common/InkStyle';

@ComponentV2
export struct CoverArt {
  @Param @Require coverPath: string;
  /** 占位首字来源（歌名首字符）：空串时不渲染占位字 */
  @Param @Require seedId: string;
  /** 占位大字（歌名首字）：列表/迷你条短、播放页大 */
  @Param fallbackText: string = '';
  @Param radius: number = 14;
  @Param glyphSize: number = 22;
  /** 播放页舞台变体：舞台恒定深底（媒体页惯例），占位走恒暗 viz token 族，
   * 浅色系统模式下不与深舞台冲突 */
  @Param onStage: boolean = false;

  /** 歌名首字：取第一个字符（含代理对保护——emoji 等增补平面字符按
   * code point 取，避免劈成乱码）；无字时不显示 */
  @Computed
  get initialChar(): string {
    if (this.fallbackText === '') {
      return '';
    }
    const code = this.fallbackText.codePointAt(0);
    if (code === undefined) {
      return '';
    }
    return String.fromCodePoint(code);
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
        Text(this.initialChar)
          .fontSize(this.glyphSize)
          .fontFamily(INK_FONT_MEDIUM)
          .fontColor($r('app.color.viz_fg_soft'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .backgroundColor($r('app.color.viz_fg_faint'))
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        Text(this.initialChar)
          .fontSize(this.glyphSize)
          .fontFamily(INK_FONT_MEDIUM)
          .fontColor($r('app.color.ink_soft'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .backgroundColor($r('app.color.surface_alt'))
      .justifyContent(FlexAlign.Center)
    }
  }
}
