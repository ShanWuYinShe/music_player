import { SongRecord } from '../model/Song';
import { formatTime } from '../common/TimeUtils';

const COVER_SIZE = 48;
const CURRENT_COLOR = $r('app.color.accent');

/**
 * 歌曲列表项：封面 / 歌名 / 歌手 + 当前播放高亮
 */
@ComponentV2
export struct SongItem {
  @Param @Require song: SongRecord;
  @Param isCurrent: boolean = false;
  @Param isPlaying: boolean = false;
  @Event onItemClick: (id: string) => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      // 封面
      Stack() {
        if (this.song.coverPath !== '') {
          Image(this.song.coverPath)
            .width(COVER_SIZE)
            .height(COVER_SIZE)
            .borderRadius(10)
            .autoResize(true)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(22)
              .fontColor([$r('app.color.ink_soft')])
          }
          .width(COVER_SIZE)
          .height(COVER_SIZE)
          .borderRadius(10)
          .backgroundColor($r('app.color.surface_alt'))
          .justifyContent(FlexAlign.Center)
        }
      }

      // 歌名 / 歌手
      Column({ space: 4 }) {
        Text(this.song.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isCurrent ? CURRENT_COLOR : $r('app.color.ink'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.song.artist)
          .fontSize(13)
          .fontColor($r('app.color.ink_soft'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 当前播放标记 + 时长（图标语义与 MiniPlayerBar 一致：播放中显示暂停符）
      if (this.isCurrent) {
        SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(16)
          .fontColor([CURRENT_COLOR])
      }
      Text(this.song.duration > 0 ? formatTime(this.song.duration) : '--:--')
        .fontSize(12)
        .fontColor($r('app.color.ink_faint'))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent ? $r('app.color.surface') : $r('app.color.page_bg'))
    .onClick(() => this.onItemClick(this.song.id))
  }
}
