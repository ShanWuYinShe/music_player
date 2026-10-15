import { promptAction, SymbolGlyphModifier, componentSnapshot } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appStore } from '../viewmodel/AppStore';
import { PlayerController, CoverRef } from '../player/PlayerController';
import { ReloadDataSource } from '../common/ReloadDataSource';
import { firstGlyph } from '../common/TextFormat';
import { SongRecord } from '../model/Song';
import { PlayMode, playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';
import { VisualizerView } from '../components/VisualizerView';
import { WaveformSeekbar } from '../components/WaveformSeekbar';
import { CoverSwipe, COVER_SWIPE_THRESHOLD } from '../components/CoverSwipe';
import { EqIndicator } from '../components/EqIndicator';
import { SealMark } from '../components/SealMark';
import { VIZ_PRESET_NAMES, PRESET_COUNT } from '../common/VisualizerCore';

/** 队列表项 */
interface QueueEntry {
  song: SongRecord;
  inserted: boolean;
}

/** 分享卡题款词句：按歌名哈希稳定选取——同一首歌恒定一句，分享图内容稳定 */
const INK_VERSES: string[] = [
  '曲终人不见 江上数峰青',
  '此时无声胜有声',
  '乐者 天地之和也',
  '余音绕梁 三日不绝',
  '高山流水 知音相逢',
  '清风明月本无价',
  '近水遥山皆有情',
  '大音希声 大象无形'
];

function verseFor(title: string): string {
  let sum = 0;
  for (let i = 0; i < title.length; i++) {
    sum += title.codePointAt(i) ?? 0;
  }
  return INK_VERSES[sum % INK_VERSES.length];
}

/**
 * 播放页：舞台双态互斥设计——同一时刻只有一种视觉主体。
 * 封面舞台（默认）：模糊放大的封面做氛围背景 + Poweramp 式大封面，
 *   可视化停渲染不烧 GPU（此前封面浮于全速可视化之上，两套视觉互相
 *   竞争且大部分渲染被遮挡，属设计矛盾）；
 * 可视化舞台：纯全屏 MilkDrop 可视化 + 控件（顶/底垫暗色渐变保证可读），
 *   点击画面回封面；进度与音量 / 收藏与定时 / 播放队列半模态两态共用。
 * 交互对齐 Poweramp（官方 Player UI 手势）：封面/可视化区**左右滑动切歌**
 * （上一首/下一首，封面跟手位移）；**点按大封面切入可视化舞台**（返回曲库
 * 走左上箭头或系统侧滑，返回路径唯一、不占内容区点击）；封面↔可视化舞台
 * 经顶栏按钮双向切换。
 * 进入时系统栏字色切浅色以融合深底，离开恢复。
 */
@ComponentV2
export struct PlayerPage {
  @Param @Require player: PlayerController;
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 当前曲 @Local 镜像：经状态订阅维护（player 的 @Computed 渲染依赖在
   * 真机上不触发，已踩坑；@Local 驱动的 if/插值可靠） */
  @Local song: SongRecord | null = null;
  @Local isPlaying: boolean = false;
  /** 当前曲收藏态 @Local 镜像：userData 与 player 同为 @ObservedV2 全局单例，
   * 真机上其 @Trace 对属性插值不触发 UI（同坑机制），收藏图标刷新走本镜像 */
  @Local isFavoriteNow: boolean = false;
  private stateListener: () => void = (): void => {
  };
  /** 播放队列半模态开关 */
  @Local isQueueOpen: boolean = false;
  /** 当前可视化风格号（顶栏按钮与背景点击共用） */
  @Local vizPreset: number = 0;
  /** 舞台双态（互斥）：true 封面舞台（默认，Poweramp 习惯，可视化停渲染）；
   * false 纯可视化全屏 */
  @Local coverMode: boolean = true;
  /** 可视化是否已挂载（单调：一旦挂载不再卸载）——默认封面模式不挂
   * XComponent，省掉 UI 线程同步编译全场景 shader 的进页卡顿；首次切入
   * 可视化才挂载，之后保持（卸载重建会触发 EGL 黑屏坑，见 AGENTS） */
  @Local vizMounted: boolean = false;
  /** 可视化舞台本次笔触是否已判为滑动（达阈值切歌）——用于吞掉同一笔触
   * 尾随的 onClick，避免"滑一下跳回封面"（XComponent 表面收不到手势，交互
   * 全在前景占位上，点击与滑动必须自己区分） */
  private vizSwipeMoved: boolean = false;
  /** 播放模式 @Local 镜像：经状态订阅维护（player 的 @Trace 在真机上不驱动
   * glyph/文案插值，已踩坑； cyclePlayMode/setVolume/启停定时器末尾会调
   * notifyState，见 PlayerController 前提契约） */
  @Local playMode: PlayMode = PlayMode.SEQUENCE;
  /** 音量 @Local 镜像（0~1）：Slider 渲染读它，不直读 player */
  @Local volume: number = 1;
  /** 定时剩余秒数 @Local 镜像（-1 无定时）：只承担「有无定时」的属性态
   * 判断（图标着色/if 分支——真机 @Trace 不驱动属性插值）；剩余时间的
   * 数字显示直读 player @Trace（每秒 tick 不 notify，Text 内容插值存活） */
  @Local sleepRemainSec: number = -1;
  /** 音量拖动预览（-1 无拖动）：Moving 只写它不调 setVolume，End 才真正生效 */
  @Local volumePreview: number = -1;
  /** 相邻封面预览 @Local 镜像（状态订阅里经 peek 同步，下发 CoverSwipe
   * 做 pager 跟进；随机模式为 null——无预览退化为淡入） */
  @Local prevCover: CoverRef | null = null;
  @Local nextCover: CoverRef | null = null;
  /** 麦克风律动 @Local 镜像（状态订阅刷新，下发 VisualizerView） */
  @Local micOn: boolean = appStore.micOn;
  /** 分享卡片半模态开关（魔法棒菜单入口） */
  @Local shareShow: boolean = false;
  /** 队列数据源（LazyForEach）：queueEntries 变化经 @Monitor 整表 reload */
  private queueSource: ReloadDataSource<QueueEntry> =
    new ReloadDataSource<QueueEntry>((entry: QueueEntry) => `${entry.song.id}${entry.inserted ? '_q' : ''}`);
  private volumeBeforeMute: number = 1;

  @Monitor('queueEntries')
  onQueueEntriesChange(): void {
    this.queueSource.reload(this.queueEntries);
  }

  /** swipe 判定阈值（vp）由 CoverSwipe 导出：封面路径在子组件内判定，
   * 可视化舞台手势（无封面场景）在此判定，二者同值 */
  private static readonly SWIPE_THRESHOLD: number = COVER_SWIPE_THRESHOLD;

  /** 横向滑动结束的切歌判定（左滑下一首 / 右滑上一首）。
   * 封面路径：CoverSwipe 做阈值判定与 pager 过渡，这里只做实际切歌并返回
   * 结果——'same'（曲目未变：右滑回曲首/单曲重播/空队列→子组件回弹）或
   * 新曲 id（真换轨→子组件滑出/归位）；切歌同步生效，返回值即对账依据 */
  private onSwipeEnd(offsetX: number): void {
    if (offsetX < -PlayerPage.SWIPE_THRESHOLD) {
      this.player.next();
    } else if (offsetX > PlayerPage.SWIPE_THRESHOLD) {
      this.player.previous();
    }
  }

  /** 封面滑动对账入口（CoverSwipe 事件）：子组件已判成歌（含甩动），方向
   * 以释放点/甩速方向为准，这里只按方向切歌并返回结果供子组件选视觉路径。
   * 甩动位移可能不足 SWIPE_THRESHOLD（子组件按速度放行），不得再按阈值拦 */
  private swipeOutcome(offsetX: number): string {
    const before = this.player.currentSongId;
    if (offsetX < 0) {
      this.player.next();
    } else {
      this.player.previous();
    }
    const after = this.player.currentSongId;
    return after === '' || after === before ? 'same' : after;
  }

  aboutToAppear(): void {
    this.applyImmersion(true);
    this.stateListener = (): void => {
      const id = this.player.currentSongId;
      this.song = id === '' ? null : this.player.getSong(id);
      this.isPlaying = this.player.isPlaying;
      this.isFavoriteNow = id !== '' && appStore.userData.isFavorite(id);
      this.playMode = this.player.playMode;
      this.volume = this.player.volume;
      this.sleepRemainSec = this.player.sleepRemainSec;
      this.prevCover = this.player.peekPrevCover();
      this.nextCover = this.player.peekNextCover();
      this.micOn = appStore.micOn;
    };
    this.queueSource.reload(this.queueEntries); // 队列数据源首灌：@Monitor 只捕变化，初值必须手动灌（真机实测首开空列表）
    this.stateListener(); // 进入即同步一次当前状态
    this.player.addStateListener(this.stateListener);
  }

  aboutToDisappear(): void {
    this.applyImmersion(false);
    this.player.removeStateListener(this.stateListener);
  }

  /** 切入可视化时才挂载 XComponent（延迟挂载：默认封面模式用不到它，挂载
   * 会在 UI 线程同步编译全场景 shader，是首次进页卡顿的根因）；切回封面
   * 不卸载——卸载重建会触发 EGL 黑屏坑（见 AGENTS 真机踩坑①） */
  @Monitor('coverMode')
  onCoverModeChange(): void {
    if (!this.coverMode && !this.vizMounted) {
      this.vizMounted = true;
    }
  }

  /**
   * 播放页沉浸态：只维护 stageImmersion 标记并经 applyWindowChrome 统一出口
   * 应用——进入置位后应用恒定深色舞台 chrome（封面/可视化舞台底色恒定深，
   * viz_* 舞台 token 同理恒定），退出清除标记恢复随系统模式自适应；播放页
   * 期间系统切换深浅模式时，AppAbilityStage 重应用的就是舞台态，不会把系统
   * 栏字色自适应成深字压在深舞台上。
   * 画面延伸到系统栏下靠全局恒定的 setWindowLayoutFullScreen（EntryAbility
   * 启动即开启，组件级 expandSafeArea 无法让 Canvas 画进系统栏区域，真机踩坑）；
   * 页面不得开关全屏布局——异步恢复滞后会让返回首页时布局跳动。
   * 前景控件用 AppStore 预读的避让区高度自行留白。
   */
  private applyImmersion(enter: boolean): void {
    appStore.stageImmersion = enter;
    appStore.applyWindowChrome();
  }

  private toastPreset(index: number): void {
    const name = VIZ_PRESET_NAMES[index] ?? `风格 ${index + 1}`;
    promptAction.showToast({ message: `${index + 1}/${PRESET_COUNT} · ${name}` });
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 全屏可视化（可视化舞台的视觉主体）：MilkDrop 风格频谱流动层，
      // 延伸至系统栏下自然融合。封面模式下停帧并隐藏——封面与可视化
      // 互斥：XComponent 一旦挂载就保持（避免 EGL 重建黑屏坑），切回即
      // 恢复。**延迟挂载**：默认封面模式用不到它，而 XComponent 挂载会在
      // UI 线程同步编译全场景 shader（首次进页卡顿的根因）——首次切入
      // 可视化才挂载，之后不再卸载（vizMounted 只增不减）。
      // 注意其原生表面区域不接收点击——可视化舞台"点画面回封面"由
      // 前景层的舞台占位 Blank 承担（见下方 else 分支）
      if (this.vizMounted) {
        VisualizerView({
          isPlaying: this.isPlaying,
          songId: this.song?.id ?? '',
          presetIndex: this.vizPreset,
          active: !this.coverMode,
          micLive: this.micOn
        })
          .width('100%')
          .height('100%')
          .visibility(this.coverMode ? Visibility.Hidden : Visibility.Visible)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          // 不在此挂手势：XComponent 原生表面收不到触摸事件（真机实测），
          // 可视化舞台的点击/滑动统一绑在前景占位 Blank 上（见 else 分支）
      }

      // 封面舞台氛围背景（仅封面模式渲染）：模糊放大的封面做环境光，
      // 叠深色遮罩保证前景可读——封面即舞台光源，无可视化渲染；无封面
      // 时回落墨色渐变。静态光栅，仅切歌时重绘一次
      if (this.coverMode) {
        Stack() {
          if (this.song !== null && this.song.coverPath !== '') {
            Image(this.song.coverPath)
              .width('146%')
              .height('146%')
              .objectFit(ImageFit.Cover)
              .blur(50)
              .opacity(0.55)
          } else {
            Column()
              .width('100%')
              .height('100%')
              .linearGradient({
                angle: 135,
                colors: [[$r('app.color.viz_stage_grad_far'), 0], [$r('app.color.viz_stage_grad_mid'), 0.55], [$r('app.color.viz_stage_grad_near'), 1]]
              })
          }
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.viz_scrim'))
        }
        .width('100%')
        .height('100%')
        .clip(true)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .transition(TransitionEffect.OPACITY.animation({ duration: 280, curve: Curve.EaseOut }))
      }

      // 可视化模式可读性衬底（仅可视化舞台渲染）：顶栏与底部控制面板后垫
      // 暗色渐变——Poweramp 可视化模式下控件压暗背景保证可读；不拦截手势
      // （可视化区点击切风格、左右滑切歌照常生效）
      if (!this.coverMode) {
        Column() {
          Column()
            .width('100%')
            .height(132)
            .linearGradient({
              angle: 180,
              colors: [[$r('app.color.viz_fade_soft'), 0], [$r('app.color.viz_fade_clear'), 1]]
            })
          Blank()
          Column()
            .width('100%')
            .height(380)
            .linearGradient({
              angle: 0,
              colors: [[$r('app.color.viz_fade_strong'), 0], [$r('app.color.viz_fade_clear'), 1]]
            })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 280, curve: Curve.EaseOut }))
      }

      Column() {
        // 顶部栏：返回 + 舞台视图切换（队列入口已沉底到控制面板，此为唯一入口）。
        // 可视化风格菜单只在可视化舞台出现——封面模式与可视化互斥，此时
        // 切风格无作用，展示属多余入口
        Row() {
          // Poweramp 语义：播放页是自下而上的覆盖层，返回用下箭头（收起）
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(26)
            .fontColor([$r('app.color.viz_fg')])
            .padding(10)
            .accessibilityText('收起播放页')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => this.navPathStack.pop())
          Blank()
          SymbolGlyph($r('sys.symbol.arrow_up_and_rectangle_on_rectangle'))
            .fontSize(20)
            .fontColor([$r('app.color.viz_fg')])
            .padding(12)
            .accessibilityText('分享歌曲卡片')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              this.shareShow = true;
            })
            .bindSheet(this.shareShow, this.ShareSheet(), {
              // 分享半模态：预览 + 安全控件保存（SaveButton 临时授权写相册，
              // 免申请受限的 WRITE_IMAGEVIDEO 权限）
              detents: [SheetSize.MEDIUM, SheetSize.LARGE],
              showClose: true,
              backgroundColor: $r('app.color.surface'),
              title: { title: '分享歌曲卡片' },
              onDisappear: (): void => {
                this.shareShow = false;
              }
            })
          // 魔法棒常驻、语义随模式连续(特效域统一入口):
          // 封面模式 = 进入可视化舞台;可视化模式 = 弹出风格选择菜单。
          // 回封面不再设按钮——可视化舞台点任意画面即回(既有手势),
          // 原 waveform「~」双态按钮与冗余 picture 按钮一并移除。
          if (this.coverMode) {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(22)
              .fontColor([$r('app.color.viz_fg')])
              .padding(12)
              .accessibilityText('进入可视化舞台')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => {
                this.coverMode = false;
              })
          } else {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(22)
              .fontColor([$r('app.color.viz_fg')])
              .padding(12)
              .accessibilityText('可视化风格列表')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .bindMenu(this.VizMenu())
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })

        // 上部大舞台：封面模式展示 Poweramp 式大封面（底衬模糊封面氛围，
        // 暂停时轻微缩小变暗）；左右滑动切歌、点按返回曲库（Poweramp 手势）。
        // 可视化模式点击画面切风格（由 VisualizerView 内部处理）。
        if (this.coverMode) {
          Column() {
            // 大封面滑动纸带（三格 [上一首|当前|下一首] 常驻 + 格间空隙 +
            // 窗口裁剪，整条只有一次平移；链上无隐式 animation，跟手即时；
            // 成歌滑向相邻格位，未达/曲目未变弹簧回中，空侧 rubber-band
            // 拖不动；轻快 flick 低位移也成歌；点按切入可视化舞台）
            CoverSwipe({
              isPlaying: this.isPlaying,
              coverPath: this.song?.coverPath ?? '',
              seedId: this.song?.id ?? '',
              fallbackCurrent: this.song?.title ?? '',
              prevCover: this.prevCover,
              nextCover: this.nextCover,
              onSwipeEnd: (offsetX: number): string => this.swipeOutcome(offsetX),
              onTap: (): void => {
                // 点按大封面切入可视化舞台（可视化里点画面回封面）；返回曲库
                // 只走左上箭头/系统侧滑，内容区点击不做导航，避免轻扫切歌
                // 未达阈值被判成点击而误退回首页
                this.coverMode = false;
              }
            })
            .aspectRatio(1)
            .width('84%')
            // 读屏语义与可视化舞台交互层对齐：点按/滑动手势无视觉提示
            .accessibilityText('大封面。轻点进入可视化舞台，左右滑动切换歌曲')
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          // 可视化舞台的交互层（顶栏与控制面板之间）：**点击回封面** +
          // **左右滑动切歌**都绑在这里。原因（真机实测）：VisualizerView 是
          // XComponent 原生表面，其区域收不到触摸事件——挂它上面的
          // PanGesture 是死的（点画面切风格当年无响应、左右滑也不生效），
          // 唯一能收到事件的是这个前景层。
          // 用 layoutWeight(1) 的实心容器而非 Blank：与封面分支同构、占位
          // 确定（Blank 对 PanGesture 的命中不如实体容器可靠），背景透明
          // 不影响可视化画面
          Column()
            .layoutWeight(1)
            .width('100%')
            .backgroundColor(Color.Transparent)
            // 读屏用户没有「点画面」的视觉提示：把整块交互层的语义说出来
            .accessibilityText('可视化舞台。轻点返回封面视图，左右滑动切换歌曲')
            .onClick(() => {
              // 同一笔触刚做过滑动：这次 click 是滑动收尾的副作用，忽略
              // （否则一滑就误判成点击跳回封面——用户报障的现象）
              if (this.vizSwipeMoved) {
                this.vizSwipeMoved = false;
                return;
              }
              this.coverMode = true;
            })
            .gesture(
              PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
                .onActionStart((): void => {
                  this.vizSwipeMoved = false;
                })
                .onActionUpdate((e: GestureEvent): void => {
                  if (Math.abs(e.offsetX) >= PlayerPage.SWIPE_THRESHOLD) {
                    this.vizSwipeMoved = true;
                  }
                })
                .onActionEnd((e: GestureEvent): void => {
                  if (Math.abs(e.offsetX) < PlayerPage.SWIPE_THRESHOLD) {
                    // 未达阈值：不算滑动（留给 onClick 判定为点击）
                    this.vizSwipeMoved = false;
                    return;
                  }
                  this.vizSwipeMoved = true;
                  this.onSwipeEnd(e.offsetX);
                })
            )
        }

        // 底部控制面板：歌名 → 进度 → 主控制 → 音量，聚拢为一个整体。
        // 三行信息各行 **constraintSize 锁最小高度**：面板高度与具体曲目无关
        // （空串/长短歌名/有无试听提示均同高）——舞台区是 layoutWeight(1)
        // 吸收剩余高度，面板高度一旦波动，aspectRatio(1) 的封面就会被等比
        // 缩放（封面大小随曲目变化的根因）
        Column() {
          Column({ space: 6 }) {
            Row({ space: 10 }) {
              // 钤印式喜欢：已收藏的曲子在歌名旁落一枚朱印（出现即盖印）
              if (this.isFavoriteNow) {
                SealMark({ text: '喜', side: 30, radius: 7 })
                  .rotate({ angle: 8 })
                  .transition(TransitionEffect.OPACITY
                    .combine(TransitionEffect.scale({ x: 1.7, y: 1.7 }))
                    .animation({ duration: 300, curve: Curve.EaseOut }))
              }
              Text(this.song ? this.song.title : '未在播放')
              .fontSize(22)
              .fontColor($r('app.color.viz_fg'))
              .maxLines(1)
              // 占满钤印外全部宽度：长歌名不再把钤印挤出/挤压（MARQUEE
              // 也需要有界宽度才会滚动）
              .layoutWeight(1)
              // 超长歌名跑马灯滚动展示全名（截断替代方案，播放页大标题
              // 不换行以免顶乱一屏版式）
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .constraintSize({ minHeight: 30 })
            }
            // 歌手行：在线歌歌手拼在标题、artist 为空——空串时整行收起，
            // 不留 minHeight 空白占位（真机走查：播放页歌手处一块空档）
            if (this.song !== null && this.song.artist !== '') {
              Text(this.song.artist)
                .fontSize(14)
                .fontColor($r('app.color.viz_fg_soft'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            // 元数据行（Poweramp 式）：格式 · 来源 · 付费试听提示。常驻占位
            Text() {
              Span(this.song !== null ? this.songMetaText(this.song) : ' ')
                .fontColor($r('app.color.viz_fg_faint'))
              if (this.song !== null && this.songTrialHint(this.song) !== '') {
                Span(` · ${this.songTrialHint(this.song)}`)
                  .fontColor($r('app.color.accent'))
              }
            }
            .fontSize(11)
            .letterSpacing(0.8)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ minHeight: 16 })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 波形进度条（Poweramp 招牌）：已播 accent 着色，点击/拖动 seek
          Column({ space: 4 }) {
            WaveformSeekbar({ player: this.player, songId: this.song?.id ?? '' })
            Row() {
              Text(formatTime(this.player.currentTime))
                .fontSize(12)
                .fontColor($r('app.color.viz_fg_faint'))
              Blank()
              Text(formatTime(this.player.duration))
                .fontSize(12)
                .fontColor($r('app.color.viz_fg_faint'))
            }
            .width('100%')
            .padding({ left: 2, right: 2 })
          }
          .width('100%')
          .margin({ top: 16 })

          // 队列入口（顶栏旧入口已删，此为唯一入口）：沉底到拇指区。
          // 不展示动态计数——player 的 @Trace 在真机上不驱动此类文本刷新，
          // 静态文案避免过期数字误导，计数进 sheet 汇总行看
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(16)
              .fontColor([$r('app.color.viz_fg_soft')])
            Text('播放队列')
              .fontSize(13)
              .fontColor($r('app.color.viz_fg_soft'))
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([$r('app.color.viz_fg_faint')])
          }
          .width('100%')
          .constraintSize({ minHeight: 44 })
          .borderRadius(12)
          .backgroundColor($r('app.color.viz_btn_bg'))
          .padding({ left: 14, right: 12 })
          .margin({ top: 10 })
          .accessibilityText('打开播放队列')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            this.isQueueOpen = true;
          })

          this.MainControls()

          this.SubControls()
        }
        // 控制面板整体水平边距与底部收尾
        .padding({ left: 16, right: 16, bottom: 8 })
      }
        .width('100%')
        .height('100%')
        // 全局恒定全屏布局下系统避让关闭，前景内容按预读的避让区高度自行留白
        .padding({ top: appStore.safeTopVp, bottom: appStore.safeBottomVp })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    .bindSheet(this.isQueueOpen, this.QueueSheet(), {
      height: SheetSize.MEDIUM,
      showClose: true,
      // 半模态底色用自适应 surface：默认底随系统主题走，浅色模式下会与
      // 内容层的恒定浅色文字冲突（浅底浅字不可见）
      backgroundColor: $r('app.color.surface'),
      title: { title: '播放队列' },
      onDisappear: (): void => {
        this.isQueueOpen = false;
      }
    })
  }

  /** 主控制：模式 / 上一首 / 播放暂停 / 下一首 / 喜欢（Poweramp 排布，
   * 全部带按压回弹 clickEffect；padding 保证热区 ≥40vp） */
  @Builder
  MainControls() {
    Row({ space: 30 }) {
    SymbolGlyph(playModeSymbol(this.playMode))
      .fontSize(24)
      .fontColor([$r('app.color.viz_fg')])
      .padding(8)
      .accessibilityText(`播放模式，当前${playModeLabel(this.playMode)}`)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
      .onClick(() => {
        this.player.cyclePlayMode();
        promptAction.showToast({ message: playModeLabel(this.playMode) });
      })

    SymbolGlyph($r('sys.symbol.backward_end_fill'))
      .fontSize(32)
      .fontColor([$r('app.color.viz_fg')])
      .padding(6)
      .accessibilityText('上一首')
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
      .onClick(() => this.player.previous())

    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(38)
        // accent 底上的前景固定用 on_accent：深浅两模式均为深色、对比受控
        .fontColor([$r('app.color.on_accent')])
    }
    .width(72)
    .height(72)
    .borderRadius(18)
    // 朱砂渐变键面（亮端 accent_hi → accent）替代平涂：暗舞台上更有体积感
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.accent_hi'), 0], [$r('app.color.accent'), 1]]
    })
    .accessibilityText(this.isPlaying ? '暂停' : '播放')
    .shadow({ radius: 18, color: $r('app.color.accent_shadow'), offsetY: 3 })
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.92 })
    .onClick(() => this.player.togglePlay())

    SymbolGlyph($r('sys.symbol.forward_end_fill'))
      .fontSize(32)
      .fontColor([$r('app.color.viz_fg')])
      .padding(6)
      .accessibilityText('下一首')
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
      .onClick(() => this.player.next())

    SymbolGlyph(this.isFavoriteNow ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
      .fontSize(24)
      .fontColor([this.isFavoriteNow ? $r('app.color.accent') : $r('app.color.viz_fg')])
      .padding(8)
      .accessibilityText(this.isFavoriteNow ? '取消喜欢' : '喜欢')
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
      .onClick(() => this.toggleFavorite())
  }
  .justifyContent(FlexAlign.SpaceEvenly)
  .width('100%')
  .margin({ top: 14 })
  }

  /** 副控制：音量 + 定时关闭。两侧收窄：给音量 Slider 与波形条留出拇指拖动行程 */
  @Builder
  SubControls() {
  Row({ space: 10 }) {
    SymbolGlyph(this.volumeIcon())
      .fontSize(20)
      .fontColor([$r('app.color.viz_fg')])
      .padding(10)
      .accessibilityText(this.volume > 0 ? '静音' : '恢复音量')
      .margin({ left: -10 })
      .onClick(() => this.toggleMute())

    Slider({
      value: this.volumePreview >= 0 ?
        Math.round(this.volumePreview * 100) : Math.round(this.volume * 100),
      min: 0,
      max: 100,
      style: SliderStyle.OutSet
    })
      .layoutWeight(1)
      .showTips(false)
      .selectedColor($r('app.color.accent'))
      .trackColor($r('app.color.viz_line'))
      .blockColor($r('app.color.accent'))
      .onChange((value: number, mode: SliderChangeMode) => {
        if (mode === SliderChangeMode.Moving) {
          // 拖动中只写本地预览，不调 setVolume（避免每帧跨单例写 @Trace）
          this.volumePreview = value / 100;
        } else if (mode === SliderChangeMode.End) {
          this.volumePreview = -1;
          this.player.setVolume(value / 100);
        }
      })

    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.timer'))
        .fontSize(16)
        .fontColor([this.sleepRemainSec >= 0 ?
          $r('app.color.accent') : $r('app.color.viz_fg_faint')])
      if (this.sleepRemainSec >= 0) {
        // 直读 player @Trace：每秒 tick 不 notify，倒计时走 Text 内容
        // 插值（真机存活的唯一路径）；有无定时的启停切换有 notify，
        // 上方 fontColor/if 分支用镜像才可靠
        Text(formatTime(this.player.sleepRemainSec * 1000))
          .fontSize(11)
          .fontColor($r('app.color.accent'))
      }
    }
    // minHeight 替代固定高度：触控热区达标（≥40vp），系统大字体时随内容撑高
    .constraintSize({ minHeight: 40 })
    .borderRadius(20)
    .backgroundColor($r('app.color.viz_btn_bg_strong'))
    .padding({ left: 12, right: 12 })
    .accessibilityText('定时关闭')
    .bindMenu(this.SleepMenu())
  }
  .width('100%')
  .margin({ top: 12 })
  // 两侧收窄：给音量 Slider 与波形条留出拇指拖动行程
  .padding({ left: 16, right: 16 })
  }

  /** 队列展示顺序：插播在前，其余按队列顺序。
   * @Computed 缓存一次结果，sheet 汇总行/定位/List 数据源共享，插播查重用 Set */
  @Computed
  get queueEntries(): QueueEntry[] {
    const insertedIds = new Set(this.player.playNextIds());
    const entries: QueueEntry[] = [];
    for (const id of insertedIds) {
      // 插播队列含在线曲目：播放队列索引优先，本地曲库兜底（旧数据）
      const song = this.player.getSong(id) ?? appStore.library.getSongById(id);
      if (song) {
        entries.push({ song: song, inserted: true });
      }
    }
    for (const song of this.player.songs) {
      if (!insertedIds.has(song.id)) {
        entries.push({ song: song, inserted: false });
      }
    }
    return entries;
  }

  private currentIndexIn(entries: QueueEntry[]): number {
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].song.id === (this.song?.id ?? '')) {
        return i;
      }
    }
    return 0;
  }

  /** 半模态播放队列（queueEntries 为 @Computed：同次 build 多次读取共享
   * 同一份缓存快照，无重复计算；真 LazyForEach 重构待真机验证后再定） */
  @Builder
  QueueSheet() {
    Column() {
      // 汇总行
      Row({ space: 8 }) {
        Text(`${this.queueEntries.length} 首 · ${playModeLabel(this.playMode)}`)
          .fontSize(12)
          .fontColor($r('app.color.ink_faint'))
        if (this.player.playNextCount > 0) {
          Text(`插播 ${this.player.playNextCount} 首`)
            .fontSize(12)
            .fontColor($r('app.color.accent'))
          Text('清空')
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
            // padding 补足 40vp 热区（原光秃文字几乎点不中）
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .accessibilityText('清空插播队列')
            .onClick(() => this.player.clearPlayNextQueue())
        }
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      List({ space: 2, initialIndex: this.currentIndexIn(this.queueEntries) }) {
        LazyForEach(this.queueSource, (entry: QueueEntry, index: number) => {
          ListItem() {
            Row({ space: 12 }) {
              if (entry.song.id === (this.song?.id ?? '')) {
                Row() {
                  EqIndicator({ active: this.isPlaying, color: $r('app.color.accent'),
                    songId: entry.song.id })
                }
                .width(22)
                .justifyContent(FlexAlign.Center)
              } else {
                Text(`${index + 1}`)
                  .fontSize(13)
                  .fontColor($r('app.color.ink_faint'))
                  .width(22)
                  .textAlign(TextAlign.Center)
              }

              Column({ space: 3 }) {
                Row({ space: 6 }) {
                  Text(entry.song.title)
                    .fontSize(15)
                    .fontColor(entry.song.id === (this.song?.id ?? '') ?
                      $r('app.color.accent') : $r('app.color.ink'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (entry.inserted) {
                    Text('插播')
                      .fontSize(9)
                      .fontColor($r('app.color.accent'))
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.accent') })
                  }
                }
                .alignItems(VerticalAlign.Center)
                Text(entry.song.artist)
                  .fontSize(12)
                  .fontColor($r('app.color.ink_soft'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(entry.song.duration > 0 ? formatTime(entry.song.duration) : '--:--')
                .fontSize(12)
                .fontColor($r('app.color.ink_faint'))
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .borderRadius(12)
            // sheet 底色为 surface，当前行高亮用更亮一档的 surface_alt 区分
            .backgroundColor(entry.song.id === (this.song?.id ?? '') ?
              $r('app.color.surface_alt') : Color.Transparent)
            .accessibilityText(`播放${entry.song.title}，${entry.song.artist}`)
            .onClick(() => this.player.playSong(entry.song.id))
            .bindContextMenu(this.QueueRowMenu(entry), ResponseType.LongPress)
          }
        }, (entry: QueueEntry) => `${entry.song.id}${entry.inserted ? '_q' : ''}`)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8, bottom: 12 })
  }

  /** 队列行长按菜单：插播行可移除、普通行可加插；当前行无菜单。
   * 原生 Menu 磨砂/圆角/按压态系统托管（与首页长按菜单同约定） */
  @Builder
  QueueRowMenu(entry: QueueEntry) {
    Menu() {
      if (entry.inserted) {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.xmark')),
          content: '从插播移除'
        })
          .onClick(() => this.player.removePlayNext(entry.song.id))
      } else if (entry.song.id !== (this.song?.id ?? '')) {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet')),
          content: '下一首播放'
        })
          .onClick(() => {
            const count = this.player.queueNext(entry.song.id);
            promptAction.showToast({
              message: count > 0 ? `已加入下一首播放 · 共 ${count} 首` : '已在插播队列中'
            });
          })
      }
    }
  }

  /** 定时关闭菜单：原生 Menu/MenuItem，MenuItemGroup 分组标题 */
  @Builder
  SleepMenu() {
    Menu() {
      MenuItemGroup({ header: '定时关闭' }) {
        MenuItem({ content: '15 分钟后停止' })
          .onClick((): void => this.applySleepTimer(15))
        MenuItem({ content: '30 分钟后停止' })
          .onClick((): void => this.applySleepTimer(30))
        MenuItem({ content: '60 分钟后停止' })
          .onClick((): void => this.applySleepTimer(60))
      }
      // 菜单打开瞬间构建，直读即时值——镜像只在启停 notify 时同步，会滞后
      if (this.player.sleepRemainSec >= 0) {
        MenuItemGroup() {
          MenuItem({ content: `取消定时（剩 ${formatTime(this.player.sleepRemainSec * 1000)}）` })
            .onClick(() => {
              this.player.cancelSleepTimer();
              promptAction.showToast({ message: '已取消定时关闭' });
            })
        }
      }
    }
  }

  /** 可视化风格选择列表：点击魔法棒后弹出，不再直接跳到下一个风格 */
  @Builder
  VizMenu() {
    Menu() {
      MenuItemGroup({ header: '可视化风格' }) {
        ForEach(VIZ_PRESET_NAMES, (name: string, index: number) => {
          MenuItem({
            content: `${index + 1}. ${name}`,
            symbolEndIcon: this.vizPreset === index
              ? new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined
          })
            .onClick((): void => {
              this.vizPreset = index;
              this.toastPreset(index);
            })
        }, (name: string) => name)
      }
    }
  }

  /** 分享卡片半模态：深色舞台风预览卡（封面/纸带 + 歌名歌手 + 落款），
   * 保存走 SaveButton 安全控件（点击即临时授权写相册，无需受限权限） */
  @Builder
  ShareSheet() {
    Column({ space: 16 }) {
      // 预览卡片（快照即截它；id 是 componentSnapshot 的定位锚）
      Column({ space: 14 }) {
        if (this.song !== null && this.song.coverPath !== '') {
          Image(this.song.coverPath)
            .width('100%')
            .aspectRatio(1)
            .borderRadius(18)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            if (this.song !== null) {
              Text(firstGlyph(this.song.title))
                .fontSize(72)
                .fontColor($r('app.color.viz_fg_faint'))
            } else {
              // 无曲目占位用系统符号，不用 Unicode 字符当图标（项目 UI 约定）
              SymbolGlyph($r('sys.symbol.waveform'))
                .fontSize(72)
                .fontColor([$r('app.color.viz_fg_faint')])
            }
          }
          .width('100%')
          .aspectRatio(1)
          .borderRadius(18)
          .backgroundColor($r('app.color.viz_card_bg_alt'))
        }
        Text(this.song !== null ? this.song.title : '未在播放')
          .fontSize(22)
          .fontColor($r('app.color.viz_fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.song !== null ? this.song.artist : '')
          .fontSize(14)
          .fontColor($r('app.color.viz_fg_soft'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        // 题款：按歌名稳定选取的山水词句（隐约居中，不与落款抢）
        Text(this.song !== null ? verseFor(this.song.title) : '')
          .fontSize(11)
          .fontColor($r('app.color.viz_fg_faint'))
          .letterSpacing(3)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        // 落款：朱砂小印 + 应用名（印章是水墨版式的签名语言）
        Row({ space: 6 }) {
          SealMark({ text: '乐', side: 16, radius: 3 })
          Text('音乐播放器')
            .fontSize(11)
            .fontColor($r('app.color.viz_fg_faint'))
            .letterSpacing(2)
        }
        .margin({ top: 2 })
        .width('100%')
      }
      .padding(18)
      .borderRadius(24)
      .backgroundColor($r('app.color.viz_card_bg'))
      .id('share_card')

      SaveButton({ text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
        .width('60%')
        .constraintSize({ minHeight: 44 })
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult): void => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.saveShareCard();
          } else {
            promptAction.showToast({ message: '保存未授权' });
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24, bottom: 16 })
  }

  /** 生成预览卡快照并写入相册（SaveButton onClick 内调用，已在临时授权期） */
  private async saveShareCard(): Promise<void> {
    const ctx = appStore.abilityContext;
    if (ctx === null) {
      return;
    }
    // 快照与打包器都是 native 资源，成功/失败路径都必须释放
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      pixelMap = await componentSnapshot.get('share_card');
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        packer = image.createImagePacker();
        await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: '已保存到相册' });
    } catch (err) {
      hilog.warn(0x0004, 'PlayerPage', 'save share card failed: %{public}s',
        JSON.stringify(err));
      promptAction.showToast({ message: '保存失败' });
    } finally {
      packer?.release().catch(() => {});
      pixelMap?.release().catch(() => {});
    }
  }

  private applySleepTimer(minutes: number): void {
    this.player.startSleepTimer(minutes);
    promptAction.showToast({ message: `将在 ${minutes} 分钟后暂停播放` });
  }

  private toggleFavorite(): void {
    const song = this.song;
    if (!song) {
      return;
    }
    // 统一收藏入口：在线歌经 AppStore 注册元数据并钉住缓存补下载
    const fav = appStore.toggleFavorite(song);
    this.isFavoriteNow = fav; // @Trace 插值在真机不可靠，图标刷新显式走镜像
    promptAction.showToast({ message: fav ? '已喜欢' : '已取消喜欢' });
    // 收藏动作触觉反馈：软震动一档（权限被拒/无马达时静默失败）
    const effect: vibrator.VibratePreset = {
      type: 'preset',
      effectId: vibrator.HapticFeedback.EFFECT_SOFT,
      count: 1
    };
    vibrator.startVibration(effect, { usage: 'touch' }).catch(() => {});
  }

  /** 音量图标：渲染读 @Local 镜像（真机上 player @Trace 不驱动属性插值） */
  private volumeIcon(): Resource {
    if (this.volume <= 0) {
      return $r('sys.symbol.speaker_slash');
    }
    if (this.volume < 0.5) {
      return $r('sys.symbol.speaker_wave_1_fill');
    }
    return $r('sys.symbol.speaker_wave_2_fill');
  }

  private toggleMute(): void {
    if (this.player.volume > 0) {
      this.volumeBeforeMute = this.player.volume;
      this.player.setVolume(0);
    } else {
      this.player.setVolume(this.volumeBeforeMute > 0 ? this.volumeBeforeMute : 1);
    }
  }

  /** 元数据行文案：格式 · 来源（在线/本地）；本地按文件扩展名推断 */
  private songMetaText(song: SongRecord): string {
    let format = song.format ?? '';
    if (format === '' && !song.fileName.startsWith('http')) {
      const dot = song.fileName.lastIndexOf('.');
      if (dot >= 0 && dot < song.fileName.length - 1) {
        format = song.fileName.substring(dot + 1).toUpperCase();
      }
    }
    const origin = song.fileName.startsWith('http') ? '在线' : '本地';
    return format !== '' ? `${format} · ${origin}` : origin;
  }

  /** 付费试听提示：VIP 曲目且服务端未登录时展示（登录后自动消失） */
  private songTrialHint(song: SongRecord): string {
    if (song.vip === true && !appStore.neteaseLoggedIn) {
      return 'VIP 试听 30 秒';
    }
    return '';
  }
}
