import { promptAction, window } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { appStore } from '../viewmodel/AppStore';
import { PlayerController } from '../player/PlayerController';
import { SongRecord } from '../model/Song';
import { playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';
import { MenuItemRow } from '../components/MenuItemRow';
import { VisualizerView } from '../components/VisualizerView';

/** 队列表项 */
interface QueueEntry {
  song: SongRecord;
  inserted: boolean;
}

/**
 * 播放页：全屏 MilkDrop 可视化背景（无封面卡片，控件浮于其上）/
 * 进度与音量 / 收藏与定时 / 主控制区 / 播放队列半模态。
 * 进入时系统栏字色切浅色以融合深底，离开时按深浅模式恢复。
 */
@ComponentV2
export struct PlayerPage {
  @Param @Require player: PlayerController;
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 拖动进度条期间的本地值，避免与 timeUpdate 抖动 */
  @Local dragValue: number = -1;
  /** 播放队列半模态开关 */
  @Local isQueueOpen: boolean = false;
  /** 全屏布局下前景内容自行避让：系统栏/导航指示区高度（vp） */
  @Local sysBarTop: number = 0;
  @Local sysBarBottom: number = 0;
  private volumeBeforeMute: number = 1;

  aboutToAppear(): void {
    this.applyImmersion(true);
  }

  aboutToDisappear(): void {
    this.applyImmersion(false);
  }

  /**
   * 播放页沉浸态：进入时开启全屏布局（应用真正延伸到系统栏下，系统栏
   * 透明后直接透出 canvas 画面，不再存在独立色层——不依赖系统栏自定义
   * 色，浅色模式下自定义色不生效的坑已实测）+ window 深色兜底；前景
   * 内容按避让区高度自行留白。离开时关闭全屏布局并按深浅恢复。
   */
  private applyImmersion(enter: boolean): void {
    const ctx = appStore.abilityContext;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win) => {
      const dark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      const fg = enter || dark ? '#F3EFE4' : '#26221B';
      const bg = enter ? '#0C0A09' : (dark ? '#16140F' : '#F6F3EC');
      if (enter) {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.sysBarTop = this.getUIContext().px2vp(sys.topRect.height);
        this.sysBarBottom = this.getUIContext().px2vp(nav.bottomRect.height);
      }
      win.setWindowLayoutFullScreen(enter);
      win.setWindowBackgroundColor(bg);
      win.setWindowSystemBarProperties({
        statusBarColor: enter ? '#00000000' : bg,
        navigationBarColor: enter ? '#00000000' : bg,
        statusBarContentColor: fg,
        navigationBarContentColor: fg
      });
    }).catch((err: Error) => {
      console.info(`apply immersion failed: ${err.message}`);
    });
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 全屏可视化底景：MilkDrop 风格频谱流动层，延伸至系统栏下自然融合
      VisualizerView({ player: this.player, variant: 'full' })
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // 顶部栏：仅返回 + 队列入口（歌名由主标题承担，避免重复）
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.viz_fg')])
            .padding(12)
            .onClick(() => this.navPathStack.pop())
          Blank()
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(22)
            .fontColor([$r('app.color.viz_fg')])
            .padding(12)
            .onClick(() => {
              console.info('queue button clicked');
              this.isQueueOpen = true;
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })

        // 上部大舞台：可视化主展示区
        Blank()

        // 底部控制面板：歌名 → 进度 → 主控制 → 音量，聚拢为一个整体
        Column() {
          Column({ space: 6 }) {
            Text(this.player.currentSong ? this.player.currentSong.title : '未在播放')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.viz_fg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.player.currentSong ? this.player.currentSong.artist : '')
              .fontSize(15)
              .fontColor($r('app.color.viz_fg_soft'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')

          // 进度条
          Column({ space: 4 }) {
            Slider({
              value: this.sliderValue(),
              min: 0,
              max: Math.max(this.player.duration, 1),
              style: SliderStyle.OutSet
            })
              .selectedColor($r('app.color.accent'))
              .trackColor($r('app.color.viz_line'))
              .blockColor($r('app.color.accent'))
              .enabled(this.player.isPrepared)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  this.dragValue = value;
                } else if (mode === SliderChangeMode.End) {
                  this.player.seek(Math.floor(value));
                  this.dragValue = -1;
                }
              })
            Row() {
              Text(formatTime(this.sliderValue()))
                .fontSize(12)
                .fontColor($r('app.color.viz_fg_faint'))
              Blank()
              Text(formatTime(this.player.duration))
                .fontSize(12)
                .fontColor($r('app.color.viz_fg_faint'))
            }
            .width('100%')
            .padding({ left: 4, right: 4 })
          }
          .width('100%')
          .margin({ top: 24 })

          // 主控制：模式 / 上一首 / 播放暂停 / 下一首 / 喜欢
          Row({ space: 30 }) {
          SymbolGlyph(playModeSymbol(this.player.playMode))
            .fontSize(26)
            .fontColor([$r('app.color.viz_fg')])
            .onClick(() => {
              this.player.cyclePlayMode();
              promptAction.showToast({ message: playModeLabel(this.player.playMode) });
            })

          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(34)
            .fontColor([$r('app.color.viz_fg')])
            .onClick(() => this.player.previous())

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(36)
              .fontColor([$r('app.color.paper')])
          }
          .width(72)
          .height(72)
          .borderRadius(36)
          .backgroundColor($r('app.color.accent'))
          .shadow({ radius: 16, color: 'rgba(0,0,0,0.35)', offsetY: 2 })
          .onClick(() => this.player.togglePlay())

          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(34)
            .fontColor([$r('app.color.viz_fg')])
            .onClick(() => this.player.next())

          SymbolGlyph(this.isFavorite() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(26)
            .fontColor([this.isFavorite() ? $r('app.color.accent') : $r('app.color.viz_fg')])
            .onClick(() => this.toggleFavorite())
        }
        .justifyContent(FlexAlign.SpaceEvenly)
        .width('100%')
        .margin({ top: 18 })

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
                $r('app.color.ink') : $r('app.color.ink_faint')])
            if (this.player.sleepRemainSec >= 0) {
              Text(formatTime(this.player.sleepRemainSec * 1000))
                .fontSize(11)
                .fontColor($r('app.color.ink'))
            }
          }
          .height(30)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface'))
          .padding({ left: 10, right: 10 })
          .bindMenu(this.SleepMenu())
        }
        .width('100%')
        .margin({ top: 16 })
        .padding({ left: 28, right: 28 })
        }
        // 控制面板整体水平边距与底部收尾
        .padding({ left: 28, right: 28, bottom: 8 })
      }
      .width('100%')
      .height('100%')
      // 全屏布局下系统避让关闭，前景内容按避让区高度自行留白
      .padding({ top: this.sysBarTop, bottom: this.sysBarBottom })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .bindSheet(this.isQueueOpen, this.QueueSheet(), {
      height: SheetSize.MEDIUM,
      showClose: true,
      title: { title: '播放队列' },
      onDisappear: (): void => {
        this.isQueueOpen = false;
      }
    })
  }

  /** 队列展示顺序：插播在前，其余按曲库顺序 */
  private queueEntries(): QueueEntry[] {
    const insertedIds = this.player.playNextIds();
    const entries: QueueEntry[] = [];
    for (const id of insertedIds) {
      const song = appStore.library.getSongById(id);
      if (song) {
        entries.push({ song: song, inserted: true });
      }
    }
    for (const song of this.player.songs) {
      if (!insertedIds.includes(song.id)) {
        entries.push({ song: song, inserted: false });
      }
    }
    return entries;
  }

  private currentIndexIn(entries: QueueEntry[]): number {
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].song.id === this.player.currentSongId) {
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
        Text(`${this.queueEntries().length} 首 · ${playModeLabel(this.player.playMode)}`)
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

      List({ space: 2, initialIndex: this.currentIndexIn(this.queueEntries()) }) {
        ForEach(this.queueEntries(), (entry: QueueEntry, index: number) => {
          ListItem() {
            Row({ space: 12 }) {
              if (entry.song.id === this.player.currentSongId) {
                SymbolGlyph(this.player.isPlaying ?
                  $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'))
                  .fontSize(14)
                  .fontColor([$r('app.color.accent')])
                  .width(22)
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
                    .fontColor(entry.song.id === this.player.currentSongId ?
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
            .backgroundColor(entry.song.id === this.player.currentSongId ?
              $r('app.color.surface') : Color.Transparent)
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

  /** 定时关闭菜单 */
  @Builder
  SleepMenu() {
    Column({ space: 2 }) {
      MenuItemRow({
        label: '15 分钟后停止',
        onSelect: (): void => this.applySleepTimer(15)
      })
      MenuItemRow({
        label: '30 分钟后停止',
        onSelect: (): void => this.applySleepTimer(30)
      })
      MenuItemRow({
        label: '60 分钟后停止',
        onSelect: (): void => this.applySleepTimer(60)
      })
      if (this.player.sleepRemainSec >= 0) {
        MenuItemRow({
          label: '取消定时',
          danger: true,
          onSelect: () => {
            this.player.cancelSleepTimer();
            promptAction.showToast({ message: '已取消定时关闭' });
          }
        })
      }
    }
    .width(180)
    .padding(6)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.15)' })
  }

  private applySleepTimer(minutes: number): void {
    this.player.startSleepTimer(minutes);
    promptAction.showToast({ message: `将在 ${minutes} 分钟后暂停播放` });
  }

  private isFavorite(): boolean {
    const song = this.player.currentSong;
    return song !== null && appStore.userData.isFavorite(song.id);
  }

  private toggleFavorite(): void {
    const song = this.player.currentSong;
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

  private sliderValue(): number {
    if (this.dragValue >= 0) {
      return this.dragValue;
    }
    return this.player.currentTime;
  }
}
