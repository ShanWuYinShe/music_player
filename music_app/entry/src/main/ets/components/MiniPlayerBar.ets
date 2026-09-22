import { PlayerController } from '../player/PlayerController';
import displaySync from '@ohos.graphics.displaySync';
import { CoverArt } from './CoverArt';

const BAR_HEIGHT = 62;

/** 条高（vp）：导出供首页给列表留底部空间——迷你条常驻，不再随有无播放
 * 曲目显隐（用户决策），列表须常留这段高度避免最后一行被压住 */
export const MINI_BAR_HEIGHT: number = BAR_HEIGHT;

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
 * 底部迷你播放条（常驻）：封面 + 歌名 + 播放/暂停 + 下一首，顶部细线为实时
 * 播放进度，磨砂通栏，点击整条进入播放页。
 * 无播放曲目时（info = null）显示占位态：保留封面位与条高，标题为「未在
 * 播放」，播放/下一首禁用——常驻不消失，UI 不跳动。
 */
@ComponentV2
export struct MiniPlayerBar {
  @Param @Require player: PlayerController;
  /** 当前曲镜像；null = 无播放曲目（占位态） */
  @Param info: MiniInfo | null = null;
  @Event onTapOpen: () => void = () => {
  };
  /**
   * 横向笔画 = 一级签相邻循环（> 右移下一个 / < 左移上一个，四签全参与、
   * 越界回绕）。一级签扁平化后无「分类/源」两层之分——平直横滑与折返
   * 统一为相邻移动（2026-09 用户决策：滑动必须能到达全部签），分类器
   * 只负责何时触发（折返早认/横滑抬手），方向语义一致：
   * direction +1 = 序列中的下一个签，-1 = 上一个
   */
  @Event onSwipeCycle: (direction: number) => void = (_direction: number) => {
  };
  /** 底部安全区高度（vp）：磨砂底延伸进安全区，与系统导航条同色不割裂 */
  @Param bottomInset: number = 0;

  private progressPercent(): number {
    if (this.info === null || this.player.duration <= 0) {
      return 0;
    }
    return Math.min(100, this.player.currentTime / this.player.duration * 100);
  }

  /** 是否有可操作的曲目（占位态下禁用播放/下一首） */
  private hasTrack(): boolean {
    return this.info !== null;
  }

  /** 进度条百分比（@Local 镜像）：真机上 player 的 @Trace 不驱动属性插值
   * （width 就是属性插值），必须在帧回调里显式写入 @Local 才会跟着走 */
  @Local progressPct: number = 0;
  private ds: displaySync.DisplaySync | null = null;
  /** frame 具名回调：匿名闭包无法 off('frame') 注销，重进会堆积 */
  private frameCb: () => void = () => this.tickProgress();
  private running = false;
  private progressClock = 0;

  aboutToAppear(): void {
    this.ds = displaySync.create();
    // 进度线 4Hz 足够（细线宽度变化肉眼无感，30fps 纯浪费）
    this.ds.setExpectedFrameRateRange({ min: 0, max: 4, expected: 4 });
    this.ds.on('frame', this.frameCb);
    this.tickProgress();
    this.syncLoop();
  }

  aboutToDisappear(): void {
    this.stopLoop();
    if (this.ds !== null) {
      this.ds.off('frame', this.frameCb);
      this.ds = null;
    }
  }

  /** 播放态/曲目变化：进度线随播放推进，暂停即停帧（省电） */
  @Monitor('info.isPlaying', 'info.seedId')
  onInfoChange(): void {
    this.tickProgress();
    this.syncLoop();
  }

  /** 按可见性启停（被下级页面盖住时不必推进）：visible 由 onVisibleAreaChange
   * 回调维护。方法名避开组件内置属性 onVisibleAreaChange（重名会与基类签名
   * 冲突，编译报错——与 onDragStart 同类坑） */
  private applyVisible(ratio: number): void {
    this.visible = ratio > 0;
    this.syncLoop();
  }

  @Local visible: boolean = true;

  private syncLoop(): void {
    const want = this.visible && this.info !== null && this.info.isPlaying;
    if (want) {
      this.startLoop();
    } else {
      this.stopLoop();
    }
  }

  private startLoop(): void {
    if (this.running || this.ds === null) {
      return;
    }
    this.running = true;
    this.ds.start();
  }

  private stopLoop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.ds !== null) {
      this.ds.stop();
    }
  }

  /** 每帧：读一次 player 进度写 @Local（变化才赋值，避免无谓重建） */
  private tickProgress(): void {
    const pct = this.progressPercent();
    if (Math.abs(pct - this.progressPct) >= 0.05) {
      this.progressPct = pct;
    }
  }

  /** 手势轨迹采样点（[相对起点的 dx, dy]，间隔 >6vp 记一条，上限 32 点）：
   * 折返/纵拉在 onActionUpdate 中早认（顶点一出现即触发，不等抬手），
   * onActionEnd 只做兜底分类 */
  private pathPts: number[][] = [];
  /** 本次触摸已触发过动作（早认锁定）：后半段笔画不再判定，抬手只复位 */
  private gestureFired: boolean = false;

  /** 折返早认：`>`/`<` 的本质特征是 x 方向反转（顶点）——向一侧走出
   * OUT_VP 后折回 BACK_VP 即触发，不等抬手（抬手分类只做兜底）。顶点在
   * 右（先右后左，`>`）= 下一个签，顶点在左（`<`）= 上一个签。
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
    // 走抬手兜底通道，不在这里抢）
    if (Math.abs(ey) < 50) {
      // 右顶点（`>`：向右走出 maxX，从顶点折回 maxX-ex）
      if (maxX >= 45 && maxX - ex >= 25) {
        this.gestureFired = true;
        this.onSwipeCycle(1);
        return;
      }
      // 左顶点（`<`：向左走出 -minX，从顶点折回 ex-minX）
      if (-minX >= 45 && ex - minX >= 25) {
        this.gestureFired = true;
        this.onSwipeCycle(-1);
        return;
      }
    }
  }

  build() {
    // clip 使进度细线跟随卡片圆角。整条高度含底部安全区：磨砂底一铺到
    // 屏幕物理底，内容行仍锁定 BAR_HEIGHT（安全区只是同色延伸）
    Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 12 }) {
            // 封面也承担打开播放页（行点击已下沉到文本区，按钮不再被冒泡误带跳页：
            // ClickEvent 无 stopPropagation，只能结构规避）；无封面占位放歌名首字
            CoverArt({
              coverPath: this.info?.coverPath ?? '',
              seedId: this.info?.seedId ?? '',
              fallbackText: this.info?.title ?? '',
              radius: 8, glyphSize: 17
            })
              .width(40)
              .height(40)
              .onClick(() => this.onTapOpen())

            Column() {
              Text(this.info !== null ? this.info.title : '未在播放')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.info !== null ? $r('app.color.editorial_title') : $r('app.color.editorial_meta'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.info !== null ? this.info.artist : '选一首歌开始')
                .fontSize(12)
                .fontColor($r('app.color.editorial_meta'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .accessibilityText(this.info !== null
              ? `正在播放：${this.info.title}，${this.info.artist}，点按打开播放页`
              : '未在播放，点按打开播放页')
            .onClick(() => this.onTapOpen())

            SymbolGlyph(this.info?.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(26)
              .fontColor([this.hasTrack() ? $r('app.color.ink') : $r('app.color.ink_faint')])
              .opacity(this.hasTrack() ? 1 : 0.4)
              .padding(7)
              .accessibilityText(this.info?.isPlaying ? '暂停' : '播放')
              .onClick(() => {
                if (this.hasTrack()) {
                  this.player.togglePlay();
                }
              })

            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(26)
              .fontColor([this.hasTrack() ? $r('app.color.ink') : $r('app.color.ink_faint')])
              .opacity(this.hasTrack() ? 1 : 0.4)
              .padding(7)
              .accessibilityText('下一首')
              .onClick(() => {
                if (this.hasTrack()) {
                  this.player.next();
                }
              })
          }
          .width('100%')
          .height(BAR_HEIGHT)
          .padding({ left: 16, right: 16 })

          // 实时进度细线（progressPct 为 @Local 镜像，帧驱动写入）
          Row()
            .width(`${this.progressPct}%`)
            .height(2.5)
            .borderRadius({ bottomRight: 2 })
            .backgroundColor($r('app.color.accent'))
            .opacity(this.info?.isPlaying ? 0.5 : 0.3)
        }
        .width('100%')
        .height(BAR_HEIGHT)
      }
    .width('100%')
    .height(BAR_HEIGHT + this.bottomInset)
    .clip(true)
    // 进度线帧循环随可见性启停（被下级页面盖住时不必推进）
    .onVisibleAreaChange([0.0, 1.0], (_isExpanding: boolean, ratio: number) => {
      this.applyVisible(ratio);
    })
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
    // 上限 32 点）并做早认——折返顶点成形即触发，不等抬手；
    // onActionEnd 只做兜底分类（慢笔画/漂移大没触发早认的）：
    //   折返笔画（横向跨度 ≥70vp + 折回量 ≥30vp + 纵向轻微推进）→ 相邻签
    //   平直横滑（纵向净移 <40vp、横向净移 ≥40vp）→ 相邻签
    //   两者方向语义一致：右移/`>` = 下一个，左移/`<` = 上一个
    //   其余（普通斜滑/纵向）→ 忽略，不误触发
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
          // 折返侧定方向：向左折返（顶点在左）= 上一个签，向右折返 = 下一个签
          if (xSpan >= 70 && (xSpan - adx) >= 30 && ady >= 15) {
            const apexLeft = -minX > maxX - dxNet;
            this.onSwipeCycle(apexLeft ? -1 : 1);
            return;
          }
          // 平直横滑：相邻签循环（无折返倾向：跨度 ≈ |净移|）
          if (ady < 40 && adx >= 40) {
            this.onSwipeCycle(dxNet < 0 ? -1 : 1);
          }
        })
    )
  }
}
