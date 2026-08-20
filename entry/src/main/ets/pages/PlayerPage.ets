import { PlayerController } from '../player/PlayerController';
import { playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';

const COVER_SIZE = 300;
const SPIN_STEP = 1.2; // 每 100ms 旋转 1.2°，约 30s 一圈
const SPIN_INTERVAL = 100;

/**
 * 播放页：沉浸背景 / 旋转封面 / 进度条 / 播放控制
 */
@ComponentV2
export struct PlayerPage {
  @Param @Require player: PlayerController;
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 拖动进度条期间的本地值，避免与 timeUpdate 抖动 */
  @Local dragValue: number = -1;
  /** 封面旋转角度，播放中由定时器递增 */
  @Local spinAngle: number = 0;
  private spinTimer: number = -1;

  aboutToAppear(): void {
    this.spinTimer = setInterval(() => {
      if (this.player.isPlaying) {
        this.spinAngle = (this.spinAngle + SPIN_STEP) % 360;
      }
    }, SPIN_INTERVAL);
  }

  aboutToDisappear(): void {
    if (this.spinTimer >= 0) {
      clearInterval(this.spinTimer);
      this.spinTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 沉浸背景：封面放大模糊（无封面时用弱色占位）
      if (this.player.currentSong && this.player.currentSong.coverPath !== '') {
        Image(this.player.currentSong.coverPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(60)
          .opacity(0.35)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('sys.color.background_tertiary'))
      }

      Column() {
        // 顶部栏：返回 + 当前歌名
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('sys.color.font_primary')])
            .padding(12)
            .onClick(() => this.navPathStack.pop())
          Blank()
          Text(this.player.currentSong ? this.player.currentSong.title : '')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Blank()
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_secondary')])
            .padding(12)
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: 8 })

        Blank()

        // 旋转封面
        Stack() {
          if (this.player.currentSong && this.player.currentSong.coverPath !== '') {
            Image(this.player.currentSong.coverPath)
              .width(COVER_SIZE)
              .height(COVER_SIZE)
              .borderRadius(20)
              .objectFit(ImageFit.Cover)
              .border({ width: 0.5, color: $r('sys.color.comp_divider') })
              .shadow({ radius: 32, color: 'rgba(0,0,0,0.2)' })
              .rotate({ angle: this.spinAngle })
          } else {
            Column() {
              SymbolGlyph($r('sys.symbol.music_note_list'))
                .fontSize(96)
                .fontColor([$r('sys.color.font_tertiary')])
            }
            .width(COVER_SIZE)
            .height(COVER_SIZE)
            .borderRadius(20)
            .backgroundColor($r('sys.color.background_tertiary'))
            .justifyContent(FlexAlign.Center)
          }
        }

        // 歌名 / 歌手
        Column({ space: 6 }) {
          Text(this.player.currentSong ? this.player.currentSong.title : '未在播放')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.player.currentSong ? this.player.currentSong.artist : '')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .margin({ top: 32 })

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
          .padding({ left: 4, right: 4 })
        }
        .margin({ top: 24 })
        .padding({ left: 28, right: 28 })

        // 控制条
        Row({ space: 36 }) {
          SymbolGlyph(playModeSymbol(this.player.playMode))
            .fontSize(26)
            .fontColor([$r('sys.color.font_primary')])
            .onClick(() => this.player.cyclePlayMode())

          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(34)
            .fontColor([$r('sys.color.font_primary')])
            .onClick(() => this.player.previous())

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(36)
              .fontColor([$r('sys.color.font_on_primary')])
          }
          .width(72)
          .height(72)
          .borderRadius(36)
          .backgroundColor($r('sys.color.font_primary'))
          .shadow({ radius: 16, color: 'rgba(0,0,0,0.15)' })
          .onClick(() => this.player.togglePlay())

          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(34)
            .fontColor([$r('sys.color.font_primary')])
            .onClick(() => this.player.next())

          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(26)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .margin({ top: 24 })

        // 播放模式提示
        Text(playModeLabel(this.player.playMode))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 16, bottom: 40 })
      }
      .width('100%')
      .height('100%')
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
