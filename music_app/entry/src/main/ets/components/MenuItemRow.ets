/**
 * 菜单弹层内的通用行：可选图标 + 文案 + 激活勾选，支持危险态红色
 */
@ComponentV2
export struct MenuItemRow {
  @Param label: string = '';
  @Param icon: Resource | null = null;
  @Param active: boolean = false;
  @Param danger: boolean = false;
  @Event onSelect: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      if (this.icon !== null) {
        SymbolGlyph(this.icon)
          .fontSize(18)
          .fontColor([this.danger ? $r('app.color.danger') : $r('app.color.ink')])
      } else {
        Row().width(18).height(1)
      }
      Text(this.label)
        .fontSize(15)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.ink'))
        .layoutWeight(1)
        .maxLines(1)
      if (this.active) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([$r('app.color.ink')])
      }
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .borderRadius(10)
    .onClick(() => this.onSelect())
  }
}
