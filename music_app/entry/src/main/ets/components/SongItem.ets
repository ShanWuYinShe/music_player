import { SongRecord } from '../model/Song';
import { formatTime } from '../common/TimeUtils';
import { TextSegment, splitHighlight } from '../common/LibraryFilter';
import { INK_FONT_MEDIUM, INK_FONT_REGULAR } from '../common/InkStyle';
import { EqIndicator } from './EqIndicator';
import { CoverArt } from './CoverArt';

const COVER_SIZE = 44;
const CURRENT_COLOR = $r('app.color.accent');

/**
 * 歌曲列表项（杂志目录行）：无盒子大字排版——歌名是主角（17vp 重字直接
 * 排在页面上），歌手小字随行，时长右对齐如目录页码；行间笔意线分隔。
 * 当前行 = 行首朱砂竖线 + 歌名变朱 + EQ 跳动，无底色无描边无阴影。
 * 搜索关键词高亮保留；VIP 徽标轻量化为字距拉开的小字。
 */
@ComponentV2
export struct SongItem {
  @Param @Require song: SongRecord;
  @Param isCurrent: boolean = false;
  @Param isPlaying: boolean = false;
  /** 网易云已登录：VIP 曲为完整播放，徽标淡化（试听态才强调；播放页另有试听标注） */
  @Param loggedIn: boolean = false;
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

  /** 分段渲染：命中片段以 accent 着色，其余继承 Text 颜色。
   * 文楷排印：正文常规字重，命中片段以 Medium 承担"加粗" */
  @Builder
  HighlightText(segments: TextSegment[], baseColor: ResourceColor, fontSize: number,
    medium: boolean) {
    Text() {
      ForEach(segments, (seg: TextSegment, idx: number) => {
        Span(seg.text)
          .fontFamily(seg.hit || medium ? INK_FONT_MEDIUM : INK_FONT_REGULAR)
          .fontColor(seg.hit ? CURRENT_COLOR : baseColor)
          .fontSize(fontSize)
      }, (seg: TextSegment, idx: number) => `${idx}_${seg.text}`)
    }
    .maxLines(1)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  build() {
    Row({ space: 12 }) {
      // 当前行标记：金色竖线（杂志引言线的用法，替代描边盒子）
      Column()
        .width(3)
        .height(36)
        .borderRadius(1.5)
        .backgroundColor(this.isCurrent ? CURRENT_COLOR : Color.Transparent)

      // 封面缩为行首小方片：排版行的节奏点，不再喧宾夺主；
      // 无封面占位放歌名首字（大字排版，不搞哈希渐变）
      CoverArt({ coverPath: this.song.coverPath, seedId: this.song.id, fallbackText: this.song.title, radius: 8, glyphSize: 15 })
        .width(COVER_SIZE)
        .height(COVER_SIZE)

      // 歌名（主角）/ 歌手（随行）
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          this.HighlightText(this.titleSegments,
            this.isCurrent ? CURRENT_COLOR : $r('app.color.editorial_title'), 17, true)
          // 网易云付费曲目徽标：轻量小字（未登录时播放页追加「VIP 试听」标注）；
          // 已登录播完整版，徽标淡化只做身份说明
          if (this.song.vip === true) {
            Text('VIP')
              .fontSize(9)
              .fontFamily(INK_FONT_MEDIUM)
              .fontColor(CURRENT_COLOR)
              .opacity(this.loggedIn ? 0.45 : 1)
              .letterSpacing(1)
          }
        }
        .alignItems(VerticalAlign.Center)
        this.HighlightText(this.artistSegments, $r('app.color.editorial_meta'), 12, false)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 当前播放：EQ 跳动指示（Poweramp 式，暂停时静止）。isCurrent 由
      // Index 在 onStateChanged 回调中 reload 列表驱动重建求值
      if (this.isCurrent) {
        EqIndicator({ active: this.isPlaying, color: CURRENT_COLOR, songId: this.song.id })
      }

      // 时长：目录页码的用法——等宽感小字右对齐
      Text(this.song.duration > 0 ? formatTime(this.song.duration) : '--:--')
        .fontSize(12)
        .fontFamily(INK_FONT_REGULAR)
        .fontColor($r('app.color.editorial_meta'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 行高：大字排版需要呼吸感；无底色无阴影，触感反馈交给系统默认按压
    .padding({ left: 12, right: 16, top: 14, bottom: 14 })
    .onClick(() => this.onItemClick(this.song.id))
  }
}
