import { curves } from '@kit.ArkUI';
import { CoverArt } from './CoverArt';
import { CoverRef } from '../player/PlayerController';

/** 滑动切歌成功阈值（vp）：与 PlayerPage 可视化舞台手势共用同一判定 */
export const COVER_SWIPE_THRESHOLD: number = 60;
/** 相邻封面间距（vp）：成熟播放器（Poweramp/Apple Music）的页间留白 */
const CELL_GAP_VP: number = 24;
/** 按钮/队列切歌的交叉淡化时长（ms）：旧 crossfade 效果不退化 */
const SWAP_FADE_MS: number = 260;
/** 暂停态缩放过渡时长（ms）：沿用旧隐式动画的 360ms 手感 */
const PLAYSCALE_MS: number = 360;
/** 暂停态缩放比例 */
const PAUSED_SCALE: number = 0.94;
/** 纸带吸附时长（ms）：松手后滑向相邻格位 */
const SETTLE_MS: number = 300;
/** 宽度量不到时的兜底（vp） */
const FALLBACK_WIDTH_VP: number = 320;
/** 甩动成歌最小位移（vp）：低于此值只认阈值，防抖动误甩 */
const FLING_MIN_OFFSET: number = 20;
/** 甩速统计窗口（ms）：只看松手前这一段的平均速度 */
const FLING_WINDOW_MS: number = 120;
/** 甩动成歌速度（vp/ms）：≈1000vp/s，轻快 flick 远超、沉稳拖动不及 */
const FLING_VP_PER_MS: number = 1.0;
/** 速度采样上限（点）：120ms 窗口足够覆盖，旧点移出 */
const VEL_PTS_CAP: number = 10;
/** 空侧阻尼系数：没有相邻封面的一侧拖动按此比例 rubber-band（封顶见下） */
const RUBBER_FACTOR: number = 0.2;
/** 空侧阻尼最大位移（vp） */
const RUBBER_MAX_VP: number = 24;

/**
 * 封面滑动纸带（成熟播放器的 pager 模型）：
 * 三格纸带 [上一首 | 当前 | 下一首] 常驻挂载（邻居图进场前已解码，拖动
 * 零首帧卡顿），格间留 CELL_GAP_VP 空隙，窗口 .clip 裁剪——整条纸带只有
 * stripX 一次平移，跟手即时（链上无隐式动画）。松手：
 *   成歌（超阈值/甩动 + 目标侧有封面 + 换轨确认）→ 纸带沿手指方向弹簧
 *   滑向相邻格位（露出目标格），落定同帧把内容序旋转一格 + 纸带瞬时
 *   复位（两步互抵画面零变化，视觉无缝）；
 *   未达阈值/曲目未变 → 弹簧回中；
 *   目标侧无封面（随机/空队列/5 秒回曲首）→ 该侧 rubber-band 阻尼 +
 *   回中（拖不出去是明确的"这边没有了"）；
 *   落定时曲目与预期不符（罕见竞态）→ 交叉淡化遮交接。
 */
@ComponentV2
export struct CoverSwipe {
  /** 播放态：驱动暂停缩放/变暗（渲染读 @Param，父子直连可靠） */
  @Param isPlaying: boolean = true;
  /** 当前封面路径（父组件 song 镜像传入） */
  @Param coverPath: string = '';
  /** 当前曲 id（封面种子 + 切歌检测） */
  @Param seedId: string = '';
  /** 相邻封面预览（父组件状态订阅经 peek 下发；随机/空队列/5 秒规则为 null） */
  @Param nextCover: CoverRef | null = null;
  @Param prevCover: CoverRef | null = null;
  /** 滑动切歌回调（超阈值/甩动才调）：返回 'same'（曲目未变→回中）或新曲 id
   * （真换轨→滑向相邻格位）；父组件内同步完成切歌 */
  @Event onSwipeEnd: (offsetX: number) => string = () => '';
  /** 点按封面回调（父组件切入可视化舞台） */
  @Event onTap: () => void = () => {
  };
  /** 纸带平移：静止 = -(格宽+间距)（当前格居中），拖动叠加跟手位移，
   * 收尾动画滑向相邻格位或回中（逐 tick 唯一的 @Local 写） */
  @Local stripX: number = 0;
  /** 落定内容旋转标记：成歌吸附途中保持旧序（中格=旧曲，纸带滑出新曲
   * 格位），落定同帧旋转一格 + 纸带复位，画面零变化（普通切歌时 @Param
   * 更新照常驱动；此标记只为取格内容时的顺序判断） */
  @Local rotated: boolean = false;
  /** 是否已测量（widthVp>0 后纸带才有意义，未测量只画当前格） */
  @Local measured: boolean = false;
  /** 暂停态缩放（显式动画驱动，无隐式 animation） */
  @Local playScale: number = 1;
  /** 按钮切歌交叉淡化（1 常态，0 瞬隐后显式淡入；纸带路径不用它） */
  @Local swapFade: number = 1;
  /** 组件实宽（vp）＝格宽 */
  @Local widthVp: number = 0;
  /** 手势进行中（拖动跟手，纸带内容此时冻结不换） */
  private dragging: boolean = false;
  /** 吸附落定定时器（滑向相邻格位后回中） */
  private settleTimer: number = -1;
  /** 期望的新曲 id（落定核对：落定时实际曲目不符则交叉淡化遮交接） */
  private expectedSeed: string = '';
  /** 甩速采样（[位移, 时间戳]，松手前 120ms 窗口算平均速度；private 不触发重建） */
  private velPts: number[][] = [];

  aboutToAppear(): void {
    this.playScale = this.isPlaying ? 1 : PAUSED_SCALE;
  }

  aboutToDisappear(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /** 暂停态变化：显式动画缩放（链上无隐式动画，快照式切换会生硬） */
  @Monitor('isPlaying')
  onPlayingChange(): void {
    const target = this.isPlaying ? 1 : PAUSED_SCALE;
    if (target !== this.playScale) {
      this.getUIContext().animateTo({ duration: PLAYSCALE_MS, curve: Curve.EaseOut }, () => {
        this.playScale = target;
      });
    }
  }

  /** 曲目变化：拖动/吸附中不动纸带（落定回中会带上新内容）；静止且非本次
   * 手势结果（按钮/队列/外部切歌）走交叉淡化 */
  @Monitor('seedId')
  onSeedChange(): void {
    if (this.dragging || this.settleTimer >= 0) {
      return;
    }
    this.swapFade = 0;
    this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
      this.swapFade = 1;
    });
  }

  private cellW(): number {
    return this.widthVp > 0 ? this.widthVp : FALLBACK_WIDTH_VP;
  }

  /** 静止纸带位移：当前格居中（左格完全在窗外） */
  private restX(): number {
    return -(this.cellW() + CELL_GAP_VP);
  }

  /** 目标侧是否有封面（决定成歌后能否滑过去） */
  private sideHasCover(dir: number): boolean {
    return dir < 0 ? this.nextCover !== null : this.prevCover !== null;
  }

  /** 甩动判定：位移未达阈值但松手前 120ms 平均速度达标、且方向一致——
   * 轻快 flick 同样成歌（PanGesture 无速度字段，自采时间戳计算） */
  private isFling(offsetX: number): boolean {
    const dist = Math.abs(offsetX);
    if (dist < FLING_MIN_OFFSET || dist >= COVER_SWIPE_THRESHOLD) {
      return false;
    }
    const pts = this.velPts;
    if (pts.length < 2) {
      return false;
    }
    const lastPt = pts[pts.length - 1];
    const windowStart = lastPt[1] - FLING_WINDOW_MS;
    let refX = pts[0][0];
    let refT = pts[0][1];
    for (let i = 0; i < pts.length; i++) {
      if (pts[i][1] >= windowStart) {
        refX = pts[i][0];
        refT = pts[i][1];
        break;
      }
    }
    const dt = lastPt[1] - refT;
    if (dt <= 0) {
      return false;
    }
    const v = (lastPt[0] - refX) / dt;
    return Math.abs(v) >= FLING_VP_PER_MS && (v < 0) === (offsetX < 0);
  }

  /** 松手成功：切歌 + 纸带滑向相邻格位。成歌条件（子组件已判：超阈值或
   * 甩动）+ 目标侧有封面 + 返回值确认换轨。落定后无动画瞬时回中（当前格
   * 内容已是新曲，画面无缝） */
  private commitSwipe(offsetX: number): void {
    const dir = offsetX < 0 ? -1 : 1;
    const result = this.onSwipeEnd(offsetX);
    if (result === 'same' || !this.sideHasCover(dir)) {
      this.springBack();
      return;
    }
    this.dragging = false;
    this.expectedSeed = result;
    // 纸带朝手指方向滑：左滑(dir=-1)纸带左移露出右格(下一首)——
    // 与手指推动方向一致，落到相邻格位（旧版符号反了，反向滑+回中
    // 被看成"滑一下弹回来"）
    this.getUIContext().animateTo({ duration: SETTLE_MS, curve: curves.springMotion(0.75, 0.9) }, () => {
      this.stripX = this.restX() + dir * (this.cellW() + CELL_GAP_VP);
    });
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      this.finishSettle();
    }, SETTLE_MS + 60);
  }

  /** 吸附落定：先无动画瞬时换带再回中——纸带此刻停在新格位（露出目标
   * 格内容），同帧把内容序旋转一格（当前格=目标曲）并复位纸带，两件事
   * 同一帧生效，画面零变化；竞态（曲目与预期不符）才交叉淡化遮交接 */
  private finishSettle(): void {
    this.rotated = true;
    this.stripX = this.restX();
    if (this.seedId !== this.expectedSeed) {
      this.swapFade = 0;
      this.getUIContext().animateTo({ duration: SWAP_FADE_MS, curve: Curve.EaseOut }, () => {
        this.swapFade = 1;
      });
    }
    this.expectedSeed = '';
  }

  /** 未达阈值（且非甩动）/ 曲目未变：弹簧回中（取消语义；音频动作如回曲首已生效） */
  private springBack(): void {
    this.dragging = false;
    this.rotated = false;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.stripX = this.restX();
    });
  }

  /** 左格内容：吸附中 = 旧当前曲（被滑出的，冻结快照）；否则 = 上一首 */
  private leftCell(): CoverRef | null {
    if (this.rotated) {
      return null;
    }
    return this.prevCover;
  }

  /** 中格内容：吸附中 = 旧当前曲；否则 = 当前曲 */
  private midCell(): CoverRef | null {
    if (this.rotated) {
      return this.prevCover;
    }
    return { path: this.coverPath, seed: this.seedId };
  }

  /** 中格透明度：正常随 swapFade/播放态；吸附中滑出者恒 1（暗态由
   * playScale 缩放层表达，不重复叠加） */
  private midCellOpacity(): number {
    if (this.rotated) {
      return 1;
    }
    return this.swapFade * (this.isPlaying ? 1.0 : 0.7);
  }

  /** 右格内容：吸附中 = 目标新曲（返回的新曲 id + 当前参数已是它的封面）；
   * 否则 = 下一首 */
  private rightCell(): CoverRef | null {
    if (this.rotated) {
      return { path: this.coverPath, seed: this.seedId };
    }
    return this.nextCover;
  }

  build() {
    Stack() {
      if (this.measured) {
        // 三格纸带：整条只有 stripX 一次平移；邻居常驻挂载（解码预热），
        // 拖动零首帧卡顿；格间 CELL_GAP_VP 空隙，窗口裁剪。
        // 吸附途中(rotated=false)保持旧序[旧上|旧曲|目标]，落定帧旋转
        // 成[目标|新曲|新下一]并复位纸带，同一帧内两步互抵画面零变化
        Row({ space: CELL_GAP_VP }) {
          // 左格：吸附中 = 旧当前曲（滑出者）或无；正常 = 上一首或无
          if (this.leftCell() !== null) {
            CoverArt({
              coverPath: (this.leftCell() as CoverRef).path,
              seedId: (this.leftCell() as CoverRef).seed,
              radius: 16, glyphSize: 56, onStage: true
            })
              .width(this.widthVp)
              .height(this.widthVp)
              .scale({ x: this.playScale, y: this.playScale })
              .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          } else {
            Column()
              .width(this.widthVp)
              .height(this.widthVp)
          }
          // 中格：吸附中 = 旧当前曲（被滑出的）；正常 = 当前曲
          if (this.midCell() !== null) {
            CoverArt({
              coverPath: (this.midCell() as CoverRef).path,
              seedId: (this.midCell() as CoverRef).seed,
              radius: 16, glyphSize: 56, onStage: true
            })
              .width(this.widthVp)
              .height(this.widthVp)
              .scale({ x: this.playScale, y: this.playScale })
              .opacity(this.midCellOpacity())
              .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          } else {
            Column()
              .width(this.widthVp)
              .height(this.widthVp)
          }
          // 右格：吸附中 = 目标新曲（滑入者）；正常 = 下一首或无
          if (this.rightCell() !== null) {
            CoverArt({
              coverPath: (this.rightCell() as CoverRef).path,
              seedId: (this.rightCell() as CoverRef).seed,
              radius: 16, glyphSize: 56, onStage: true
            })
              .width(this.widthVp)
              .height(this.widthVp)
              .scale({ x: this.playScale, y: this.playScale })
              .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetY: 8 })
          } else {
            Column()
              .width(this.widthVp)
              .height(this.widthVp)
          }
        }
        .translate({ x: this.stripX })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((_old: Area, area: Area) => {
      const w = area.width as number;
      if (w > 0 && !this.measured) {
        // 首次测量：初始化纸带居中位移（无动画，避免从 0 飞入）
        this.widthVp = w;
        this.stripX = this.restX();
        this.measured = true;
      }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .onActionStart((): void => {
          if (this.settleTimer >= 0) {
            return;
          }
          this.dragging = true;
          this.rotated = false;
          this.velPts = [];
        })
        .onActionUpdate((e: GestureEvent): void => {
          if (this.settleTimer >= 0 || !this.dragging) {
            return;
          }
          const raw = e.offsetX;
          // 空侧 rubber-band：没有相邻封面的一侧拖不动（阻尼 + 封顶），
          // 拖出去多少弹回多少，"这边没有了"的手感
          const dir = raw < 0 ? -1 : 1;
          const eff = this.sideHasCover(dir) ? raw
            : Math.sign(raw) * Math.min(Math.abs(raw) * RUBBER_FACTOR, RUBBER_MAX_VP);
          // 逐 tick 唯一的 @Local 写（速度采样走 private，不触发重建）
          this.stripX = this.restX() + eff;
          if (this.velPts.length >= VEL_PTS_CAP) {
            this.velPts.shift();
          }
          this.velPts.push([raw, Date.now()]);
        })
        .onActionEnd((e: GestureEvent): void => {
          if (this.settleTimer >= 0 || !this.dragging) {
            return;
          }
          const offsetX = e.offsetX;
          if (Math.abs(offsetX) >= COVER_SWIPE_THRESHOLD || this.isFling(offsetX)) {
            this.commitSwipe(offsetX);
            return;
          }
          this.springBack();
        })
        .onActionCancel((): void => {
          if (this.settleTimer >= 0) {
            return;
          }
          this.springBack();
        })
    )
    .onClick(() => {
      this.onTap();
    })
  }
}
