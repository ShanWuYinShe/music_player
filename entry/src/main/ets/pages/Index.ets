import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { SongRecord } from '../model/Song';
import { SongItem } from '../components/SongItem';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { PlayerPage } from './PlayerPage';
import { SettingsPage } from './SettingsPage';

/**
 * 主页面：歌曲列表 + 导入 + 迷你播放条，Navigation 承载播放页与设置页
 */
@Entry
@ComponentV2
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @Local scanning: boolean = false;

  build() {
    Navigation(this.pathStack) {
      Column() {
        // 标题区：大标题 + 曲目数副标题 + 操作按钮
        Row() {
          Column({ space: 4 }) {
            Text('音乐')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text(appStore.player.songs.length > 0 ? `${appStore.player.songs.length} 首歌曲` : '本地音乐')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')])
            .padding(10)
            .onClick(() => this.importFromPicker())
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(22)
            .fontColor([$r('sys.color.font_primary')])
            .padding(10)
            .onClick(() => this.pathStack.pushPathByName('settings', null))
        }
        .width('100%')
        .padding({ left: 20, right: 12, top: 14, bottom: 6 })

        // 歌曲列表
        if (appStore.player.songs.length === 0) {
          this.EmptyView()
        } else {
          List({ space: 2 }) {
            ForEach(appStore.player.songs, (song: SongRecord) => {
              ListItem() {
                SongItem({
                  song: song,
                  isCurrent: song.id === appStore.player.currentSongId,
                  isPlaying: appStore.player.isPlaying,
                  onItemClick: (id: string) => appStore.player.playSong(id)
                })
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.DeleteButton(song.id)
                  },
                  onAction: () => appStore.player.removeSong(song.id)
                }
              })
            }, (song: SongRecord) => song.id)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 12, right: 12, bottom: 8 })
          .scrollBar(BarState.Off)
        }

        // 底部迷你播放条
        if (appStore.player.currentSong !== null) {
          MiniPlayerBar({
            player: appStore.player,
            onTapOpen: () => this.pathStack.pushPathByName('player', null)
          })
            .margin({ left: 12, right: 12, bottom: 12 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
  }

  @Builder
  EmptyView() {
    Column({ space: 20 }) {
      // 音符圆形底
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(44)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .width(96)
      .height(96)
      .borderRadius(48)
      .backgroundColor($r('sys.color.background_tertiary'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 6 }) {
        Text('曲库还是空的')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('导入设备音频，或先听听内置演示曲目')
          .fontSize(13)
          .fontColor($r('sys.color.font_tertiary'))
      }

      Row({ space: 12 }) {
        Button('导入音乐')
          .height(42)
          .fontSize(15)
          .borderRadius(21)
          .backgroundColor($r('sys.color.font_primary'))
          .fontColor($r('sys.color.font_on_primary'))
          .onClick(() => this.importFromPicker())
        Button('载入演示曲目')
          .height(42)
          .fontSize(15)
          .borderRadius(21)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('sys.color.background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => this.loadDemos())
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 60 })
  }

  @Builder
  DeleteButton(id: string) {
    Column() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(20)
        .fontColor([$r('sys.color.font_on_primary')])
    }
    .width(56)
    .height('100%')
    .borderRadius(12)
    .backgroundColor('#E84040')
    .justifyContent(FlexAlign.Center)
    .margin({ left: 8 })
    .onClick(() => appStore.player.removeSong(id))
  }

  @Builder
  pageMap(name: string) {
    if (name === 'player') {
      NavDestination() {
        PlayerPage({ player: appStore.player, navPathStack: this.pathStack })
      }
      .hideTitleBar(true)
    } else if (name === 'settings') {
      NavDestination() {
        SettingsPage({ navPathStack: this.pathStack })
      }
      .title('设置')
      .hideTitleBar(false)
    }
  }

  /** 系统音频选择器导入 */
  private async importFromPicker(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    try {
      const audioPicker = new picker.AudioViewPicker();
      const selectOptions: picker.AudioSelectOptions = { maxSelectNumber: 100 };
      const uris: Array<string> = await audioPicker.select(selectOptions);
      if (uris.length > 0) {
        const added = await appStore.library.importFromUris(uris);
        appStore.player.refreshSongs();
        promptAction.showToast({
          message: added > 0 ? `已导入 ${added} 首歌曲` : '所选歌曲已在曲库中'
        });
      }
    } catch (err) {
      // 用户取消选择不提示
      console.info(`picker canceled or failed: ${JSON.stringify(err)}`);
    } finally {
      this.scanning = false;
    }
  }

  /** 载入 rawfile 内置演示曲目 */
  private async loadDemos(): Promise<void> {
    const added = await appStore.library.importDemoTracks();
    appStore.player.refreshSongs();
    promptAction.showToast({
      message: added > 0 ? `已载入 ${added} 首演示曲目` : '演示曲目已加载过'
    });
  }
}
