import { PlayerController } from '../player/PlayerController';
import { playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';

/**
 * 播放页：大封面 / 歌曲信息 / 进度条 / 播放控制
 */
@ComponentV2
export struct PlayerPage {
  @Param @Require player: PlayerController;
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 拖动进度条期间的本地值，避免与 timeUpdate 抖动 */
  @Local dragValue: number = -1;

  build() {
    Column({ space: 20 }) {
      // 封面
      Stack() {
        if (this.player.currentSong && this.player.currentSong.coverPath !== '') {
          Image(this.player.currentSong.coverPath)
            .width(280)
            .height(280)
            .borderRadius(24)
            .objectFit(ImageFit.Cover)
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.25)' })
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(96)
              .fontColor([$r('sys.color.font_tertiary')])
          }
          .width(280)
          .height(280)
          .borderRadius(24)
          .backgroundColor($r('sys.color.background_tertiary'))
          .justifyContent(FlexAlign.Center)
        }
      }
      .margin({ top: 24 })

      // 歌名 / 歌手
      Column({ space: 6 }) {
        Text(this.player.currentSong ? this.player.currentSong.title : '未在播放')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.player.currentSong ? this.player.currentSong.artist : '')
          .fontSize(16)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 进度条
      Column({ space: 4 }) {
        Slider({
          value: this.sliderValue(),
          min: 0,
          max: Math.max(this.player.duration, 1),
          style: SliderStyle.OutSet
        })
          .selectedColor($r('sys.color.font_primary'))
          .trackColor($r('sys.color.background_tertiary'))
          .blockColor($r('sys.color.font_primary'))
          .enabled(this.player.isPrepared)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.dragValue = value;
            } else if (mode === SliderChangeMode.End) {
              this.player.seek(Math.floor(value));
              this.dragValue = -1;
            }
          })
        Row() {
          Text(formatTime(this.sliderValue()))
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
          Blank()
          Text(formatTime(this.player.duration))
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
      .padding({ left: 16, right: 16 })

      // 控制条
      Row({ space: 40 }) {
        SymbolGlyph(playModeSymbol(this.player.playMode))
          .fontSize(28)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.player.cyclePlayMode())

        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(36)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.player.previous())

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(36)
            .fontColor([$r('sys.color.font_on_primary')])
        }
        .width(76)
        .height(76)
        .borderRadius(38)
        .backgroundColor($r('sys.color.font_primary'))
        .onClick(() => this.player.togglePlay())

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(36)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.player.next())

        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(28)
          .fontColor([$r('sys.color.font_primary')])
          .onClick(() => this.navPathStack.pop())
      }
      .margin({ top: 8 })

      // 播放模式提示
      Text(playModeLabel(this.player.playMode))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }

  private sliderValue(): number {
    if (this.dragValue >= 0) {
      return this.dragValue;
    }
    return this.player.currentTime;
  }
}
