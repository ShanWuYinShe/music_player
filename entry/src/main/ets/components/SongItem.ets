import { SongRecord } from '../model/Song';
import { formatTime } from '../common/TimeUtils';

const COVER_SIZE = 52;
const CURRENT_COLOR = '#34C77B';

/**
 * 歌曲列表项：封面 / 歌名 / 歌手 + 当前播放标记
 */
@ComponentV2
export struct SongItem {
  @Param @Require song: SongRecord;
  @Param isCurrent: boolean = false;
  @Param isPlaying: boolean = false;
  onItemClick: (id: string) => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Stack() {
        if (this.song.coverPath !== '') {
          Image(this.song.coverPath)
            .width(COVER_SIZE)
            .height(COVER_SIZE)
            .borderRadius(8)
            .autoResize(true)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(24)
              .fontColor([$r('sys.color.font_secondary')])
          }
          .width(COVER_SIZE)
          .height(COVER_SIZE)
          .borderRadius(8)
          .backgroundColor($r('sys.color.background_tertiary'))
          .justifyContent(FlexAlign.Center)
        }
      }

      Column({ space: 4 }) {
        Text(this.song.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isCurrent ? CURRENT_COLOR : $r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.song.artist)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.isCurrent && this.isPlaying) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(16)
          .fontColor([CURRENT_COLOR])
      }
      Text(this.song.duration > 0 ? formatTime(this.song.duration) : '--:--')
        .fontSize(13)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('sys.color.background_primary'))
    .onClick(() => this.onItemClick(this.song.id))
  }
}
