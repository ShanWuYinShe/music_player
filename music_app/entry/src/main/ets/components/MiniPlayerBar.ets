import { PlayerController } from '../player/PlayerController';
import { CoverArt } from './CoverArt';

const BAR_HEIGHT = 62;

/** 迷你条展示镜像：由 Index 经 onStateChanged 回调维护的 @Local 整体替换
 * 传入（@Local→@Param 链路可靠）；进度/时长仍直读 player 的 @Trace */
export interface MiniInfo {
  /** 占位首字来源曲目 id（组件 key/语义标识；占位字用 title） */
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
   * 折返/纵拉在 onActionUpdate 中早认（顶点一出现即触发，不等抬手），
   * onActionEnd 只做兜底分类 */
  private pathPts: number[][] = [];
  /** 本次触摸已触发过动作（早认锁定）：后半段笔画不再判定，抬手只复位 */
  private gestureFired: boolean = false;

  /** 折返早认：`>`/`<` 的本质特征是 x 方向反转（顶点）——向一侧走出
   * OUT_VP 后折回 BACK_VP 即触发，不等抬手（抬手分类只做兜底）。顶点在
   * 右（先右后左，`>`）= 下一个源，顶点在左（`<`）= 上一个源。
   * 纵拉早认：下滑深且横向没散开即下拉悬停（ deliberate 的下拉不等抬手）。
   * 直线横滑故意不等抬手早认——它是折返的前半段，早认必误杀 `>`/`<`。
   * 一次触摸只触发一次，触发后锁定到抬手 */
  private earlyClassify(): void {
    const pts = this.pathPts;
    if (this.gestureFired || pts.length < 2) {
      return;
    }
    const first = pts[0];
    const cur = pts[pts.length - 1];
    const ex = cur[0] - first[0];
    const ey = cur[1] - first[1];
    let minX = 0;
    let maxX = 0;
    for (const p of pts) {
      const rx = p[0] - first[0];
      minX = Math.min(minX, rx);
      maxX = Math.max(maxX, rx);
    }
    // 折返顶点：走出 45vp + 折回 25vp；纵向漂移 <50vp 才认（大对角下滑
    // 走纵拉通道，不在这里抢）
    if (Math.abs(ey) < 50) {
      // 右顶点（`>`：向右走出 maxX，从顶点折回 maxX-ex）
      if (maxX >= 45 && maxX - ex >= 25) {
        this.gestureFired = true;
        this.onSwipeSource(1);
        return;
      }
      // 左顶点（`<`：向左走出 -minX，从顶点折回 ex-minX）
      if (-minX >= 45 && ex - minX >= 25) {
        this.gestureFired = true;
        this.onSwipeSource(-1);
        return;
      }
    }
    // 纵拉早认：下滑超 80vp 且横向跨度 <50vp（横向散开的不认，防横滑抖动
    // 下坠 half-way 被提前认成下拉；阈值高于抬手兜底的 60vp，早认只接
    // 明确的下拉意图）
    if (ey > 80 && maxX - minX < 50) {
      this.gestureFired = true;
      this.onPullDown();
    }
  }

  build() {
    // clip 使进度细线跟随卡片圆角
    Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 12 }) {
            // 封面也承担打开播放页（行点击已下沉到文本区，按钮不再被冒泡误带跳页：
            // ClickEvent 无 stopPropagation，只能结构规避）；无封面占位放歌名首字
            CoverArt({ coverPath: this.info.coverPath, seedId: this.info.seedId, fallbackText: this.info.title, radius: 8, glyphSize: 17 })
              .width(40)
              .height(40)
              .onClick(() => this.onTapOpen())

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
            .accessibilityText(`正在播放：${this.info.title}，${this.info.artist}，点按打开播放页`)
            .onClick(() => this.onTapOpen())

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
    // 上限 32 点）并做早认——折返顶点/纵拉成形即触发，不等抬手；
    // onActionEnd 只做兜底分类（慢笔画/漂移大没触发早认的）：
    //   折返笔画（横向跨度 ≥70vp + 折回量 ≥30vp + 纵向轻微推进）→ 源循环
    //   纵拉（下滑为主：纵向 >60vp 且 ≥ 横向）→ 下拉悬停
    //   平直横滑（纵向净移 <40vp、横向净移 ≥40vp）→ 分类标签循环
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
          this.earlyClassify();
        })
        .onActionEnd((e: GestureEvent): void => {
          const pts = this.pathPts;
          this.pathPts = [];
          // 早认已触发：后半段笔画不再判定，复位即回（一次触摸只动作一次）
          if (this.gestureFired) {
            this.gestureFired = false;
            return;
          }
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
          // 折返笔画（不要求标准 < / > 形，任何「横向走出去又折回来」的
          // 笔画都算——用户决策）：横向跨度达标 + 有明确折回量（跨度−净移，
          // 平直横滑虽跨度大但无折回，靠它区分，不再要求纵向大推进——压平
          // 的 </> 也认）；纵向只要求轻微推进（15vp），过滤手指抖动。
          // 折返侧定方向：向左折返（顶点在左）= 上一个源，向右折返 = 下一个源
          if (xSpan >= 70 && (xSpan - adx) >= 30 && ady >= 15) {
            const apexLeft = -minX > maxX - dxNet;
            this.onSwipeSource(apexLeft ? -1 : 1);
            return;
          }
          // 纵拉：下拉悬停（只认下拉，上推忽略）。以下滑为主（纵向 ≥ 横向）
          // 即认——斜着往下拉不再被忽略；横向跨度大的先走上面的折返判定
          if (dyNet > 0 && ady > 60 && ady >= xSpan) {
            this.onPullDown();
            return;
          }
          // 平直横滑：切分类标签（无折返倾向：跨度 ≈ |净移|）
          if (ady < 40 && adx >= 40) {
            this.onSwipeTab(dxNet < 0 ? -1 : 1);
          }
        })
    )
  }
}
