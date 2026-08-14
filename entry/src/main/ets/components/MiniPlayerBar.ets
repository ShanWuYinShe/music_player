import { PlayerController } from '../player/PlayerController';

/**
 * 底部迷你播放条：封面 + 歌名 + 播放/暂停 + 下一首，点击整条进入播放页
 */
@ComponentV2
export struct MiniPlayerBar {
  @Param @Require player: PlayerController;
  @Event onTapOpen: () => void = () => {
  };

  build() {
    if (this.player.currentSong !== null) {
      Row({ space: 12 }) {
        if (this.player.currentSong?.coverPath !== '') {
          Image(this.player.currentSong?.coverPath ?? '')
            .width(40)
            .height(40)
            .borderRadius(6)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(20)
              .fontColor([$r('sys.color.font_secondary')])
          }
          .width(40)
          .height(40)
          .borderRadius(6)
          .backgroundColor($r('sys.color.background_tertiary'))
          .justifyContent(FlexAlign.Center)
        }

        Column() {
          Text(this.player.currentSong?.title ?? '')
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.player.currentSong?.artist ?? '')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(26)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.player.togglePlay())

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(26)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.player.next())
      }
      .width('100%')
      .height(64)
      .padding({ left: 16, right: 16 })
      .borderRadius(16)
      .backgroundColor($r('sys.color.background_secondary'))
      .onClick(() => this.onTapOpen())
    }
  }
}
