import { SongRecord } from '../model/Song';
import { formatTime } from '../common/TimeUtils';
import { TextSegment, splitHighlight } from '../common/LibraryFilter';
import { EqIndicator } from './EqIndicator';

const COVER_SIZE = 48;
const CURRENT_COLOR = $r('app.color.accent');

/**
 * 歌曲列表项：封面 / 歌名 / 歌手（搜索关键词高亮）+ 当前播放高亮
 * （EQ 跳动指示）+ VIP 徽标
 */
@ComponentV2
export struct SongItem {
  @Param @Require song: SongRecord;
  @Param isCurrent: boolean = false;
  @Param isPlaying: boolean = false;
  /** 搜索关键词（大小写不敏感高亮命中片段，空串不高亮） */
  @Param keyword: string = '';
  @Event onItemClick: (id: string) => void = () => {
  };

  /** 歌名/歌手命中片段（高亮渲染用） */
  @Computed
  get titleSegments(): TextSegment[] {
    return splitHighlight(this.song.title, this.keyword);
  }

  @Computed
  get artistSegments(): TextSegment[] {
    return splitHighlight(this.song.artist, this.keyword);
  }

  /** 分段渲染：命中片段以 accent 着色，其余继承 Text 颜色 */
  @Builder
  HighlightText(segments: TextSegment[], baseColor: ResourceColor, fontSize: number,
    fontWeight: FontWeight) {
    Text() {
      ForEach(segments, (seg: TextSegment, idx: number) => {
        Span(seg.text)
          .fontColor(seg.hit ? CURRENT_COLOR : baseColor)
          .fontWeight(seg.hit ? FontWeight.Medium : fontWeight)
          .fontSize(fontSize)
      }, (seg: TextSegment, idx: number) => `${idx}_${seg.text}`)
    }
    .maxLines(1)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

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
        Row({ space: 6 }) {
          this.HighlightText(this.titleSegments,
            this.isCurrent ? CURRENT_COLOR : $r('app.color.ink'), 16, FontWeight.Medium)
          // 网易云付费曲目徽标（未登录时播放页会追加「VIP 试听」标注）
          if (this.song.vip === true) {
            Text('VIP')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(CURRENT_COLOR)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4)
              .border({ width: 0.5, color: CURRENT_COLOR })
          }
        }
        .alignItems(VerticalAlign.Center)
        this.HighlightText(this.artistSegments, $r('app.color.ink_soft'), 13, FontWeight.Normal)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 当前播放：EQ 跳动指示（Poweramp 式，暂停时静止）。isCurrent 由
      // Index 在 onStateChanged 回调中 reload 列表驱动重建求值
      if (this.isCurrent) {
        EqIndicator({ active: this.isPlaying, color: CURRENT_COLOR })
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
