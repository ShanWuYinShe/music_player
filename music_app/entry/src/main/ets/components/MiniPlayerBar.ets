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
  /** 水平滑 = 分类标签切换（全部→喜欢→最近循环，方向即顺序），仅本地源 */
  @Event onSwipeTab: (direction: number) => void = (_direction: number) => {
  };
  /** 弧线画 < / > = 顶层源切换（< 上一个 / > 下一个，循环） */
  @Event onSwipeSource: (direction: number) => void = (_direction: number) => {
  };

  private progressPercent(): number {
    if (this.player.duration <= 0) {
      return 0;
    }
    return Math.min(100, this.player.currentTime / this.player.duration * 100);
  }

  /** 手势轨迹采样点（[相对起点的 dx, dy]，间隔 >6vp 记一条，上限 32 点）：
   * onActionEnd 据此做路径形状分类（纵拉/折返/横滑） */
  private pathPts: number[][] = [];

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
    // 单一全向手势 + 路径分类器（不拆互斥组：弧线「<」的起始段是横向的，
    // 拆组会被横滑手势抢先认领）。onActionUpdate 采样轨迹点（间隔取样，
    // 上限 32 点），onActionEnd 按轨迹形状一次判定四类：
    //   纵拉（|dy| 大、横向跨度小）→ 下拉悬停
    //   折返笔画（横向净移小 + 横向跨度大 = 走出去又折回来）→ 源切换 < />
    //   平直横滑（横向跨度达标、纵向净移小）→ 分类标签切换
    //   其余（普通斜滑）→ 忽略，不误触发
    .priorityGesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 25 })
        .onActionUpdate((e: GestureEvent): void => {
          // 轨迹采样：间隔 >6vp 才记录（uinput/手指上报频率远超需要）
          const last = this.pathPts.length > 0 ? this.pathPts[this.pathPts.length - 1] : null;
          const dx = last === null ? 999 : e.offsetX - last[0];
          const dy = last === null ? 999 : e.offsetY - last[1];
          if (dx * dx + dy * dy < 36) {
            return;
          }
          if (this.pathPts.length >= 32) {
            this.pathPts.shift();
          }
          this.pathPts.push([e.offsetX, e.offsetY]);
        })
        .onActionEnd((e: GestureEvent): void => {
          const pts = this.pathPts;
          this.pathPts = [];
          if (pts.length < 2) {
            return;
          }
          const first = pts[0];
          const lastPt = pts[pts.length - 1];
          const dxNet = lastPt[0] - first[0];
          const dyNet = lastPt[1] - first[1];
          let minX = 0;
          let maxX = 0;
          for (const p of pts) {
            minX = Math.min(minX, p[0] - first[0]);
            maxX = Math.max(maxX, p[0] - first[0]);
          }
          const xSpan = maxX - minX;
          const ady = Math.abs(dyNet);
          const adx = Math.abs(dxNet);
          // 纵拉：下拉悬停（只认下拉，上推忽略）
          if (ady > 60 && xSpan < 60) {
            if (dyNet > 0) {
              this.onPullDown();
            }
            return;
          }
          // 折返笔画（画 < / >）：横向走出去又折回来（净移小、跨度大），
          // 且纵向同步推进（尖角开口有高度）。顶点侧 = 折返方向：
          //   画 <（左尖角）：先向右走、折返越过起点，minX << 0
          //   画 >（右尖角）：先向左走、折返越过终点，maxX >> dxNet
          if (adx < 60 && xSpan >= 90 && ady >= 40) {
            const apexLeft = -minX > maxX - dxNet;
            this.onSwipeSource(apexLeft ? -1 : 1);
            return;
          }
          // 平直横滑：切分类标签
          if (ady < 40 && adx >= 40) {
            this.onSwipeTab(dxNet < 0 ? -1 : 1);
          }
        })
    )
  }
}
