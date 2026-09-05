import { PlayerController } from '../player/PlayerController';
import { VisualizerView } from './VisualizerView';

const BAR_HEIGHT = 62;

/** 迷你条展示镜像：由 Index 经 onStateChanged 回调维护的 @Local 整体替换
 * 传入（@Local→@Param 链路可靠）；进度/时长仍直读 player 的 @Trace */
export interface MiniInfo {
  title: string;
  artist: string;
  coverPath: string;
  isPlaying: boolean;
}

/**
 * 底部迷你播放条：封面 + 歌名 + 播放/暂停 + 下一首，顶部细线为实时播放进度，
 * 整卡片区垫全宽金色频谱背景（播放中跳动），点击整条进入播放页。
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
  /** 迷你条是否在屏幕可见区：不可见（如切到播放页）时停掉频谱动画省电 */
  @Local barVisible: boolean = true;

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
          // 全卡片频谱背景（先声明垫底；固定高度与内容行一致，'100%' 会
          // 与 Stack 高度互引把迷你条撑高）；随可见性启停渲染
          VisualizerView({ player: this.player, variant: 'mini', active: this.barVisible })
            .width('100%')
            .height(BAR_HEIGHT)

          Row({ space: 12 }) {
            if (this.info.coverPath !== '') {
              Image(this.info.coverPath)
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
              Text(this.info.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ink'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.info.artist)
                .fontSize(12)
                .fontColor($r('app.color.ink_soft'))
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
        // 离开可见区（进播放页/切后台）停掉频谱动画，回来自动恢复
        .onVisibleAreaChange([0.0, 1.0], (isExpanding: boolean, currentRatio: number) => {
          this.barVisible = isExpanding && currentRatio >= 1.0;
        })
      }
    .width('100%')
    .clip(true)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 0.5, color: $r('app.color.line') })
    .shadow({ radius: 16, color: 'rgba(0,0,0,0.30)', offsetY: 2 })
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
