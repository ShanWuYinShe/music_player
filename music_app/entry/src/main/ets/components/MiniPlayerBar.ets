import { PlayerController } from '../player/PlayerController';
import { CoverArt } from './CoverArt';

const BAR_HEIGHT = 62;

/** 迷你条展示镜像：由 Index 经 onStateChanged 回调维护的 @Local 整体替换
 * 传入（@Local→@Param 链路可靠）；进度/时长仍直读 player 的 @Trace */
export interface MiniInfo {
  /** 渐变占位种子：曲目 id（无封面时 CoverArt 按此派生渐变） */
  seedId: string;
  title: string;
  artist: string;
  coverPath: string;
  isPlaying: boolean;
}

/**
 * 底部迷你播放条：封面 + 歌名 + 播放/暂停 + 下一首，顶部细线为实时播放进度，
 * 悬浮磨砂胶囊，点击整条进入播放页。
 */
@ComponentV2
export struct MiniPlayerBar {
  @Param @Require player: PlayerController;
  @Param @Require info: MiniInfo;
  @Event onTapOpen: () => void = () => {
  };
  /** 迷你条下滑：单手够不到顶部时，把首页内容下拉悬停到拇指区（Reachability） */
  @Event onPullDown: () => void = () => {
  };

  private progressPercent(): number {
    if (this.player.duration <= 0) {
      return 0;
    }
    return Math.min(100, this.player.currentTime / this.player.duration * 100);
  }

  build() {
    // clip 使进度细线跟随卡片圆角
    Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 12 }) {
            CoverArt({ coverPath: this.info.coverPath, seedId: this.info.seedId, radius: 8, glyphSize: 20 })
              .width(40)
              .height(40)

            Column() {
              Text(this.info.title)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.editorial_title'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.info.artist)
                .fontSize(12)
                .fontColor($r('app.color.editorial_meta'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            SymbolGlyph(this.info.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(26)
              .fontColor([$r('app.color.ink')])
              .padding(7)
              .accessibilityText(this.info.isPlaying ? '暂停' : '播放')
              .onClick(() => this.player.togglePlay())

            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(26)
              .fontColor([$r('app.color.ink')])
              .padding(7)
              .accessibilityText('下一首')
              .onClick(() => this.player.next())
          }
          .width('100%')
          .height(BAR_HEIGHT)
          .padding({ left: 16, right: 16 })
          .accessibilityText(`正在播放：${this.info.title}，${this.info.artist}，点按打开播放页`)
          .onClick(() => this.onTapOpen())

          // 实时进度细线
          Row()
            .width(`${this.progressPercent()}%`)
            .height(2.5)
            .borderRadius({ bottomRight: 2 })
            .backgroundColor($r('app.color.accent'))
            .opacity(this.info.isPlaying ? 0.5 : 0.3)
        }
        .width('100%')
      }
    .width('100%')
    .clip(true)
    // 排印风：无胶囊圆角——底部通栏（与页面同宽），上缘一根发丝线分隔
    // （EdgeWidths 对象需四边齐全，单边省略会绘制异常）
    .border({
      width: { left: 0, right: 0, top: 0.5, bottom: 0 },
      color: $r('app.color.editorial_rule')
    })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .backgroundColor($r('app.color.surface'))
    // 迷你条下滑 = 下拉悬停触发器：distance 阈值保证点按不受影响
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 30 })
        .onActionEnd((e: GestureEvent): void => {
          if (e.offsetY > 60) {
            this.onPullDown();
          }
        })
    )
  }
}
