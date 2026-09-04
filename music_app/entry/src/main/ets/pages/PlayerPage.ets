import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { PlayerController } from '../player/PlayerController';
import { SongRecord } from '../model/Song';
import { playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';
import { VisualizerView } from '../components/VisualizerView';
import { WaveformSeekbar } from '../components/WaveformSeekbar';
import { EqIndicator } from '../components/EqIndicator';
import { VIZ_PRESET_NAMES, PRESET_COUNT } from '../common/VisualizerCore';

/** 队列表项 */
interface QueueEntry {
  song: SongRecord;
  inserted: boolean;
}

/**
 * 播放页：舞台双态互斥设计——同一时刻只有一种视觉主体。
 * 封面舞台（默认）：模糊放大的封面做氛围背景 + Poweramp 式大封面，
 *   可视化停渲染不烧 GPU（此前封面浮于全速可视化之上，两套视觉互相
 *   竞争且大部分渲染被遮挡，属设计矛盾）；
 * 可视化舞台：纯全屏 MilkDrop 可视化 + 控件（顶/底垫暗色渐变保证可读），
 *   点击画面切风格；进度与音量 / 收藏与定时 / 播放队列半模态两态共用。
 * 交互对齐 Poweramp（官方 Player UI 手势）：封面/可视化区**左右滑动切歌**
 * （上一首/下一首，封面跟手位移）、**点按封面返回曲库**（Poweramp 的
 * tap-on-cover 跳库行为）；封面↔可视化舞台经顶栏按钮切换。
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
  private stateListener: () => void = (): void => {
  };
  /** 播放队列半模态开关 */
  @Local isQueueOpen: boolean = false;
  /** 当前可视化风格号（顶栏按钮与背景点击共用） */
  @Local vizPreset: number = 0;
  /** 舞台双态（互斥）：true 封面舞台（默认，Poweramp 习惯，可视化停渲染）；
   * false 纯可视化全屏 */
  @Local coverMode: boolean = true;
  /** 封面跟手位移（Poweramp swipe 切歌）：拖动中绑定 translate，松手判定 */
  @Local coverDragX: number = 0;
  private volumeBeforeMute: number = 1;

  /** swipe 判定阈值（vp）：位移超过才切歌——与点击/轻扫误触区分 */
  private static readonly SWIPE_THRESHOLD: number = 60;

  /** Poweramp 手势：横向滑动结束的切歌判定（左滑下一首 / 右滑上一首） */
  private onSwipeEnd(offsetX: number): void {
    this.coverDragX = 0;
    if (offsetX < -PlayerPage.SWIPE_THRESHOLD) {
      this.player.next();
    } else if (offsetX > PlayerPage.SWIPE_THRESHOLD) {
      this.player.previous();
    }
  }

  aboutToAppear(): void {
    this.applyImmersion(true);
    this.stateListener = (): void => {
      const id = this.player.currentSongId;
      this.song = id === '' ? null : this.player.getSong(id);
      this.isPlaying = this.player.isPlaying;
    };
    this.stateListener(); // 进入即同步一次当前状态
    this.player.addStateListener(this.stateListener);
  }

  aboutToDisappear(): void {
    this.applyImmersion(false);
    this.player.removeStateListener(this.stateListener);
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
      // 互斥：XComponent 保持挂载（避免 EGL 重建黑屏坑），切回即恢复
      VisualizerView({
        player: this.player,
        variant: 'full',
        presetIndex: this.vizPreset,
        active: !this.coverMode,
        onPresetChange: (next: number): void => {
          this.vizPreset = next;
          this.toastPreset(next);
        }
      })
        .width('100%')
        .height('100%')
        .visibility(this.coverMode ? Visibility.Hidden : Visibility.Visible)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        // Poweramp 对齐：可视化全屏同样支持左右滑动切歌（点击切风格由
        // VisualizerView 内部 onClick 承担，PanGesture 位移阈值不冲突）
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
            .onActionEnd((e: GestureEvent): void => this.onSwipeEnd(e.offsetX))
        )

      // 封面舞台氛围背景（仅封面模式渲染）：模糊放大的封面做环境光，
      // 叠深色遮罩保证前景可读——封面即舞台光源，无可视化渲染；无封面
      // 时回落暖黑渐变。静态光栅，仅切歌时重绘一次
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
                colors: [['#231C11', 0], ['#0C0A09', 0.55], ['#060504', 1]]
              })
          }
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(8,6,4,0.52)')
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
              colors: [['rgba(5,4,3,0.58)', 0], ['rgba(5,4,3,0)', 1]]
            })
          Blank()
          Column()
            .width('100%')
            .height(380)
            .linearGradient({
              angle: 0,
              colors: [['rgba(5,4,3,0.80)', 0], ['rgba(5,4,3,0)', 1]]
            })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 280, curve: Curve.EaseOut }))
      }

      Column() {
        // 顶部栏：返回 + 舞台视图切换 + 队列入口（歌名由主标题承担，避免重复）。
        // 可视化风格菜单只在可视化舞台出现——封面模式与可视化互斥，此时
        // 切风格无作用，展示属多余入口
        Row() {
          // Poweramp 语义：播放页是自下而上的覆盖层，返回用下箭头（收起）
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(26)
            .fontColor([$r('app.color.viz_fg')])
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => this.navPathStack.pop())
          Blank()
          SymbolGlyph(this.coverMode ? $r('sys.symbol.waveform') : $r('sys.symbol.picture'))
            .fontSize(20)
            .fontColor([$r('app.color.viz_fg')])
            .padding(12)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              this.coverMode = !this.coverMode;
            })
          if (!this.coverMode) {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(22)
              .fontColor([$r('app.color.viz_fg')])
              .padding(12)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .bindMenu(this.VizMenu())
          }
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(22)
            .fontColor([$r('app.color.viz_fg')])
            .padding(12)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              this.isQueueOpen = true;
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })

        // 上部大舞台：封面模式展示 Poweramp 式大封面（底衬模糊封面氛围，
        // 暂停时轻微缩小变暗）；左右滑动切歌、点按返回曲库（Poweramp 手势）。
        // 可视化模式点击画面切风格（由 VisualizerView 内部处理）。
        if (this.coverMode) {
          Column() {
            Stack() {
              if (this.song !== null && this.song.coverPath !== '') {
                Image(this.song.coverPath)
                  .width('100%')
                  .height('100%')
                  .borderRadius(16)
                  .objectFit(ImageFit.Cover)
                  .interpolation(ImageInterpolation.Medium)
              } else {
                Column({ space: 14 }) {
                  SymbolGlyph($r('sys.symbol.music_note_list'))
                    .fontSize(56)
                    .fontColor([$r('app.color.viz_fg_soft')])
                  Text('暂无封面')
                    .fontSize(12)
                    .fontColor($r('app.color.viz_fg_faint'))
                }
                .width('100%')
                .height('100%')
                .borderRadius(16)
                .backgroundColor('rgba(255,255,255,0.06)')
                .justifyContent(FlexAlign.Center)
              }
            }
            .aspectRatio(1)
            .width('84%')
            .clip(true)
            .scale(this.isPlaying ? { x: 1, y: 1 } : { x: 0.94, y: 0.94 })
            .opacity(this.isPlaying ? 1.0 : 0.7)
            .animation({ duration: 360, curve: Curve.EaseOut })
            // Poweramp 招牌手势：封面左右滑动切歌（跟手位移，松手判定±阈值）
            .translate({ x: this.coverDragX })
            .shadow({ radius: 48, color: 'rgba(0,0,0,0.6)', offsetY: 16 })
            .gesture(
              PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
                .onActionUpdate((e: GestureEvent): void => {
                  this.coverDragX = e.offsetX;
                })
                .onActionEnd((e: GestureEvent): void => this.onSwipeEnd(e.offsetX))
                .onActionCancel((): void => {
                  this.coverDragX = 0;
                })
            )
            .onClick(() => {
              // Poweramp tap-on-cover：返回曲库查看当前歌曲（进入可视化
              // 改经顶栏按钮——两种舞台各自单一入口，不再混用点击语义）
              this.navPathStack.pop();
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Blank()
        }

        // 底部控制面板：歌名 → 进度 → 主控制 → 音量，聚拢为一个整体
        Column() {
          Column({ space: 6 }) {
            Text(this.song ? this.song.title : '未在播放')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.viz_fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.song ? this.song.artist : '')
              .fontSize(14)
              .fontColor($r('app.color.viz_fg_soft'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 元数据行（Poweramp 式）：格式 · 来源 · 付费试听提示
            if (this.song !== null) {
              Text() {
                Span(this.songMetaText(this.song))
                  .fontColor($r('app.color.viz_fg_faint'))
                if (this.songTrialHint(this.song) !== '') {
                  Span(` · ${this.songTrialHint(this.song)}`)
                    .fontColor($r('app.color.accent'))
                }
              }
              .fontSize(11)
              .letterSpacing(0.8)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
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

          // 主控制：模式 / 上一首 / 播放暂停 / 下一首 / 喜欢（Poweramp 排布，
          // 全部带按压回弹 clickEffect）
          Row({ space: 30 }) {
          SymbolGlyph(playModeSymbol(this.player.playMode))
            .fontSize(24)
            .fontColor([$r('app.color.viz_fg')])
            .padding(6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => {
              this.player.cyclePlayMode();
              promptAction.showToast({ message: playModeLabel(this.player.playMode) });
            })

          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(32)
            .fontColor([$r('app.color.viz_fg')])
            .padding(6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => this.player.previous())

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(38)
              // accent 底上的前景固定用 on_accent：深浅两模式均为深色、对比受控
              .fontColor([$r('app.color.on_accent')])
          }
          .width(76)
          .height(76)
          .borderRadius(38)
          .backgroundColor($r('app.color.accent'))
          .shadow({ radius: 18, color: 'rgba(0,0,0,0.4)', offsetY: 3 })
          .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.92 })
          .onClick(() => this.player.togglePlay())

          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(32)
            .fontColor([$r('app.color.viz_fg')])
            .padding(6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => this.player.next())

          SymbolGlyph(this.isFavorite() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(24)
            .fontColor([this.isFavorite() ? $r('app.color.accent') : $r('app.color.viz_fg')])
            .padding(6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => this.toggleFavorite())
        }
        .justifyContent(FlexAlign.SpaceEvenly)
        .width('100%')
        .margin({ top: 14 })

        // 副控制：音量 + 定时关闭
        Row({ space: 10 }) {
          SymbolGlyph(this.volumeIcon())
            .fontSize(20)
            .fontColor([$r('app.color.viz_fg')])
            .onClick(() => this.toggleMute())

          Slider({
            value: Math.round(this.player.volume * 100),
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
              if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.End) {
                this.player.setVolume(value / 100);
              }
            })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.timer'))
              .fontSize(16)
              .fontColor([this.player.sleepRemainSec >= 0 ?
                $r('app.color.accent') : $r('app.color.viz_fg_faint')])
            if (this.player.sleepRemainSec >= 0) {
              Text(formatTime(this.player.sleepRemainSec * 1000))
                .fontSize(11)
                .fontColor($r('app.color.accent'))
            }
          }
          .height(30)
          .borderRadius(15)
          .backgroundColor('rgba(255,255,255,0.08)')
          .padding({ left: 10, right: 10 })
          .bindMenu(this.SleepMenu())
        }
        .width('100%')
        .margin({ top: 12 })
        .padding({ left: 28, right: 28 })
        }
        // 控制面板整体水平边距与底部收尾
        .padding({ left: 28, right: 28, bottom: 8 })
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

  /** 半模态播放队列 */
  @Builder
  QueueSheet() {
    Column() {
      // 汇总行
      Row({ space: 8 }) {
        Text(`${this.queueEntries.length} 首 · ${playModeLabel(this.player.playMode)}`)
          .fontSize(12)
          .fontColor($r('app.color.ink_faint'))
        if (this.player.playNextCount > 0) {
          Text(`插播 ${this.player.playNextCount} 首`)
            .fontSize(12)
            .fontColor($r('app.color.accent'))
          Text('清空')
            .fontSize(12)
            .fontColor($r('app.color.ink_soft'))
            .onClick(() => this.player.clearPlayNextQueue())
        }
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      List({ space: 2, initialIndex: this.currentIndexIn(this.queueEntries) }) {
        ForEach(this.queueEntries, (entry: QueueEntry, index: number) => {
          ListItem() {
            Row({ space: 12 }) {
              if (entry.song.id === (this.song?.id ?? '')) {
                Row() {
                  EqIndicator({ active: this.isPlaying, color: $r('app.color.accent') })
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
                    .fontWeight(FontWeight.Medium)
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
            .onClick(() => this.player.playSong(entry.song.id))
          }
        }, (entry: QueueEntry) => `${entry.song.id}${entry.inserted ? '_q' : ''}`)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8, bottom: 12 })
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
      if (this.player.sleepRemainSec >= 0) {
        MenuItemGroup() {
          MenuItem({ content: '取消定时' })
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

  private applySleepTimer(minutes: number): void {
    this.player.startSleepTimer(minutes);
    promptAction.showToast({ message: `将在 ${minutes} 分钟后暂停播放` });
  }

  private isFavorite(): boolean {
    const song = this.song;
    return song !== null && appStore.userData.isFavorite(song.id);
  }

  private toggleFavorite(): void {
    const song = this.song;
    if (!song) {
      return;
    }
    const fav = appStore.userData.toggleFavorite(song.id);
    promptAction.showToast({ message: fav ? '已添加到我喜欢的音乐' : '已取消喜欢' });
  }

  private volumeIcon(): Resource {
    if (this.player.volume <= 0) {
      return $r('sys.symbol.speaker_slash');
    }
    if (this.player.volume < 0.5) {
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
