/**
 * 朱砂印章：圆角方印 + 印文单字（朱底宣白字），水墨版式的签名/落款语言。
 * 颜色走 accent/on_accent token（深浅板自适配）。
 * 注意：边长参数名不可用 size（与组件基类 size() 通用属性方法冲突，编译报错）。
 */

@ComponentV2
export struct SealMark {
  /** 印文单字（如「乐」） */
  @Param @Require text: string;
  /** 印面边长（vp） */
  @Param side: number = 18;
  /** 印角圆角（vp） */
  @Param radius: number = 4;

  build() {
    Text(this.text)
      .fontSize(Math.round(this.side * 0.62))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.on_accent'))
      .width(this.side)
      .height(this.side)
      .borderRadius(this.radius)
      .backgroundColor($r('app.color.accent'))
      .textAlign(TextAlign.Center)
  }
}
