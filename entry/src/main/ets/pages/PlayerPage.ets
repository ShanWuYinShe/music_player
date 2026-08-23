import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { PlayerController } from '../player/PlayerController';
import { SongRecord } from '../model/Song';
import { playModeLabel, playModeSymbol } from '../model/PlayMode';
import { formatTime } from '../common/TimeUtils';
import { MenuItemRow } from '../components/MenuItemRow';

const COVER_SIZE = 300;
const SPIN_STEP = 0.6; // 每 tick 旋转角度，配合 animateTo 平滑衔接
const SPIN_INTERVAL = 100;

/** 队列表项 */
interface QueueEntry {
  song: SongRecord;
  inserted: boolean;
}

/**
 * 播放页：沉浸背景 / 旋转封面 / 进度与音量 / 收藏与定时 /
 * 主控制区 / 播放队列半模态。
 */
@ComponentV2
export struct PlayerPage {
  @Param @Require player: PlayerController;
  @Param navPathStack: NavPathStack = new NavPathStack();
  /** 拖动进度条期间的本地值，避免与 timeUpdate 抖动 */
  @Local dragValue: number = -1;
  /** 封面旋转角度，播放中由定时器递增 */
  @Local spinAngle: number = 0;
  /** 播放队列半模态开关 */
  @Local isQueueOpen: boolean = false;
  private spinTimer: number = -1;
  private volumeBeforeMute: number = 1;

  aboutToAppear(): void {
    this.spinTimer = setInterval(() => {
      if (this.player.isPlaying) {
        // animateTo 让相邻两帧间线性过渡，旋转更顺滑
        this.getUIContext().animateTo({ duration: SPIN_INTERVAL, curve: Curve.Linear }, () => {
          this.spinAngle = (this.spinAngle + SPIN_STEP * (SPIN_INTERVAL / 100)) % 360;
        });
      }
    }, SPIN_INTERVAL);
  }

  aboutToDisappear(): void {
    if (this.spinTimer >= 0) {
      clearInterval(this.spinTimer);
      this.spinTimer = -1;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 沉浸背景：封面放大模糊（无封面时用弱色占位），延伸至系统栏下方
      if (this.player.currentSong && this.player.currentSong.coverPath !== '') {
        Image(this.player.currentSong.coverPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(60)
          .opacity(0.35)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.surface_alt'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      Column() {
        // 顶部栏：返回 + 当前歌名 + 队列入口
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.ink')])
            .padding(12)
            .onClick(() => this.navPathStack.pop())
          Blank()
          Text(this.player.currentSong ? this.player.currentSong.title : '')
            .fontSize(15)
            .fontColor($r('app.color.ink_soft'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '52%' })
            .textAlign(TextAlign.Center)
          Blank()
          SymbolGlyph($r('sys.symbol.list_bullet'))
            .fontSize(22)
            .fontColor([$r('app.color.ink')])
            .padding(12)
            .onClick(() => {
              console.info('queue button clicked');
              this.isQueueOpen = true;
            })
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: 8 })

        Blank()

        // 旋转封面
        Stack() {
          if (this.player.currentSong && this.player.currentSong.coverPath !== '') {
            Image(this.player.currentSong.coverPath)
              .width(COVER_SIZE)
              .height(COVER_SIZE)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .border({ width: 0.5, color: $r('app.color.line') })
              .shadow({ radius: 40, color: 'rgba(0,0,0,0.25)', offsetY: 8 })
              .rotate({ angle: this.spinAngle })
          } else {
            Column() {
              SymbolGlyph($r('sys.symbol.music_note_list'))
                .fontSize(96)
                .fontColor([$r('app.color.ink_faint')])
            }
            .width(COVER_SIZE)
            .height(COVER_SIZE)
            .borderRadius(24)
            .backgroundColor($r('app.color.surface_alt'))
            .justifyContent(FlexAlign.Center)
            .shadow({ radius: 40, color: 'rgba(0,0,0,0.12)', offsetY: 8 })
          }
        }

        // 歌名 / 歌手
        Column({ space: 6 }) {
          Text(this.player.currentSong ? this.player.currentSong.title : '未在播放')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.player.currentSong ? this.player.currentSong.artist : '')
            .fontSize(15)
            .fontColor($r('app.color.ink_soft'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .margin({ top: 32 })

        // 进度条
        Column({ space: 4 }) {
          Slider({
            value: this.sliderValue(),
            min: 0,
            max: Math.max(this.player.duration, 1),
            style: SliderStyle.OutSet
          })
            .selectedColor($r('app.color.accent'))
            .trackColor($r('app.color.line'))
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
              .fontColor($r('app.color.ink_faint'))
            Blank()
            Text(formatTime(this.player.duration))
              .fontSize(12)
              .fontColor($r('app.color.ink_faint'))
          }
          .width('100%')
          .padding({ left: 4, right: 4 })
        }
        .margin({ top: 20 })
        .padding({ left: 28, right: 28 })

        // 主控制：模式 / 上一首 / 播放暂停 / 下一首 / 喜欢
        Row({ space: 30 }) {
          SymbolGlyph(playModeSymbol(this.player.playMode))
            .fontSize(26)
            .fontColor([$r('app.color.ink')])
            .onClick(() => {
              this.player.cyclePlayMode();
              promptAction.showToast({ message: playModeLabel(this.player.playMode) });
            })

          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(34)
            .fontColor([$r('app.color.ink')])
            .onClick(() => this.player.previous())

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(36)
              .fontColor([$r('app.color.paper')])
          }
          .width(72)
          .height(72)
          .borderRadius(36)
          .backgroundColor($r('app.color.ink'))
          .shadow({ radius: 16, color: 'rgba(0,0,0,0.15)' })
          .onClick(() => this.player.togglePlay())

          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(34)
            .fontColor([$r('app.color.ink')])
            .onClick(() => this.player.next())

          SymbolGlyph(this.isFavorite() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(26)
            .fontColor([this.isFavorite() ? $r('app.color.accent') : $r('app.color.ink')])
            .onClick(() => this.toggleFavorite())
        }
        .margin({ top: 22 })

        // 副控制：音量 + 定时关闭
        Row({ space: 10 }) {
          SymbolGlyph(this.volumeIcon())
            .fontSize(20)
            .fontColor([$r('app.color.ink')])
            .onClick(() => this.toggleMute())

          Slider({
            value: Math.round(this.player.volume * 100),
            min: 0,
            max: 100,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .selectedColor($r('app.color.accent'))
            .trackColor($r('app.color.line'))
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
        .margin({ top: 18 })
        .padding({ left: 28, right: 28 })

        Blank()

        // 底部留白（含安全区余量）
        Row().height(36)
      }
      .width('100%')
      .height('100%')
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
