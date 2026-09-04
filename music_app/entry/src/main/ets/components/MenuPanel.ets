/**
 * 弹出菜单通用容器与分组元素：实心自适应底色（浅色=纯白浮层、深色=比
 * surface 略亮的浮层灰）+ 发丝描边 + 大圆角 + 柔和投影。
 * 替代旧的半透明玻璃方案——backgroundBlurStyle 的材质色随系统深浅模式翻转，
 * 与恒定文字色组合在浅色模式下会出现浅底浅字（不可见），实心底色则完全
 * 跟随 color.json 自适应，深浅两种模式下对比度均受控。
 */
@ComponentV2
export struct MenuPanel {
  /** 菜单面板宽度（vp）；成员名不能用 width——与通用属性方法同名冲突 */
  @Param panelWidth: number = 200;
  @BuilderParam content: () => void = this.empty;

  @Builder
  empty() {
  }

  build() {
    Column({ space: 2 }) {
      this.content()
    }
    .width(this.panelWidth)
    .padding(6)
    .borderRadius(20)
    .backgroundColor($r('app.color.menu_bg'))
    .border({ width: 0.5, color: $r('app.color.line') })
    .shadow({ radius: 28, color: 'rgba(0,0,0,0.22)', offsetY: 8 })
  }
}

/** 菜单分组标题：小号弱化文字，垫在条目组之前 */
@ComponentV2
export struct MenuHeader {
  @Param title: string = '';

  build() {
    Text(this.title)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.ink_faint'))
      .letterSpacing(0.5)
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 4 })
  }
}

/** 菜单分组分隔线：与条目文字左缘对齐的内缩发丝线 */
@ComponentV2
export struct MenuDivider {
  build() {
    Row()
      .width('100%')
      .height(0.5)
      .margin({ top: 5, bottom: 5, left: 14, right: 14 })
      .backgroundColor($r('app.color.line'))
  }
}
