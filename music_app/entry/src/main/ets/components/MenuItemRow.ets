/**
 * 菜单弹层内的通用行：可选图标 + 文案 + 激活勾选，支持危险态红色与
 * 图标着色（如已收藏的心形用主题金）。文字与图标色均取自适应资源，
 * 深浅模式下与 MenuPanel 底色的对比度均受控。
 */
@ComponentV2
export struct MenuItemRow {
  @Param label: string = '';
  @Param icon: Resource | null = null;
  /** 图标着色覆盖（非空时替代默认 ink），仅对非 danger 图标生效 */
  @Param iconTint: Resource | null = null;
  @Param active: boolean = false;
  @Param danger: boolean = false;
  @Event onSelect: () => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      if (this.icon !== null) {
        SymbolGlyph(this.icon)
          .fontSize(18)
          .fontColor([this.danger ? $r('app.color.danger')
            : (this.iconTint !== null ? this.iconTint : $r('app.color.ink'))])
      } else {
        Row().width(18).height(1)
      }
      Text(this.label)
        .fontSize(15)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.ink'))
        .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
        .maxLines(1)
      if (this.active) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor([$r('app.color.accent')])
      }
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
    .onClick(() => this.onSelect())
  }
}
