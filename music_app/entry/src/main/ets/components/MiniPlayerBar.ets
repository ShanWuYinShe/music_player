import { PlayerController } from '../player/PlayerController';

const BAR_HEIGHT = 62;

/**
 * 底部迷你播放条：封面 + 歌名 + 播放/暂停 + 下一首，顶部细线为实时播放进度，
 * 点击整条进入播放页。
 */
@ComponentV2
export struct MiniPlayerBar {
  @Param @Require player: PlayerController;
  @Event onTapOpen: () => void = () => {
  };

  private progressPercent(): number {
    if (this.player.duration <= 0) {
      return 0;
    }
    return Math.min(100, this.player.currentTime / this.player.duration * 100);
  }

  build() {
    if (this.player.currentSong !== null) {
      // clip 使进度细线跟随卡片圆角
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 12 }) {
            if (this.player.currentSong?.coverPath !== '') {
              Image(this.player.currentSong?.coverPath ?? '')
                .width(40)
                .height(40)
                .borderRadius(8)
            } else {
              Column() {
                SymbolGlyph($r('sys.symbol.music_note_list'))
                  .fontSize(20)
                  .fontColor([$r('app.color.ink_soft')])
              }
              .width(40)
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.surface_alt'))
              .justifyContent(FlexAlign.Center)
            }

            Column() {
              Text(this.player.currentSong?.title ?? '')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ink'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.player.currentSong?.artist ?? '')
                .fontSize(12)
                .fontColor($r('app.color.ink_soft'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(26)
              .fontColor([$r('app.color.ink')])
              .onClick(() => this.player.togglePlay())

            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(26)
              .fontColor([$r('app.color.ink')])
              .onClick(() => this.player.next())
          }
          .width('100%')
          .height(BAR_HEIGHT)
          .padding({ left: 16, right: 16 })
          .onClick(() => this.onTapOpen())

          // 实时进度细线
          Row()
            .width(`${this.progressPercent()}%`)
            .height(2.5)
            .borderRadius({ bottomRight: 2 })
            .backgroundColor($r('app.color.accent'))
            .opacity(this.player.isPlaying ? 0.5 : 0.3)
        }
        .width('100%')
      }
      .width('100%')
      .clip(true)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .shadow({ radius: 16, color: 'rgba(0,0,0,0.08)', offsetY: 2 })
    }
  }
}
