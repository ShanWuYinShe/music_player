import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { SongRecord } from '../model/Song';
import { LibraryTab, SortMode, FilterOptions, filterAndSort, sortLabel } from '../common/LibraryFilter';
import { SongItem } from '../components/SongItem';
import { MenuItemRow } from '../components/MenuItemRow';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { PlayerPage } from './PlayerPage';
import { SettingsPage } from './SettingsPage';

/**
 * 主页面：搜索/分类/排序 + 歌曲列表 + 迷你播放条，
 * Navigation 承载播放页与设置页。
 */
@Entry
@ComponentV2
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @Local searchText: string = '';
  @Local tab: LibraryTab = LibraryTab.ALL;
  @Local sortMode: SortMode = SortMode.DEFAULT;
  @Local scanning: boolean = false;

  /** 当前 Tab 与搜索词过滤后的列表 */
  private visibleSongs(): SongRecord[] {
    const opts: FilterOptions = {
      query: this.searchText,
      tab: this.tab,
      sort: this.sortMode,
      favoriteIds: appStore.userData.favoriteIds,
      recentIds: appStore.userData.recentIds
    };
    return filterAndSort(appStore.player.songs, opts);
  }

  private existingCount(ids: string[]): number {
    return ids.filter((id) => appStore.library.getSongById(id) !== null).length;
  }

  build() {
    Navigation(this.pathStack) {
      Stack() {
        // 全屏背景层：延伸至状态栏与导航条下方，消除顶部/底部割裂
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.page_bg'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        Column() {
        // 标题区：大标题 + 曲目数副标题 + 设置入口
        Row() {
          Column({ space: 4 }) {
            Text('音乐')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
            Text(appStore.player.songs.length > 0 ? `${appStore.player.songs.length} 首歌曲` : '本地音乐')
              .fontSize(13)
              .fontColor($r('app.color.ink_soft'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(22)
            .fontColor([$r('app.color.ink')])
            .padding(10)
            .onClick(() => this.pathStack.pushPathByName('settings', null))
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 14, bottom: 4 })

        // 搜索 + 排序
        Row({ space: 10 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(16)
              .fontColor([$r('app.color.ink_faint')])
            TextInput({
              text: this.searchText,
              placeholder: '搜索歌曲、歌手',
            })
              .layoutWeight(1)
              .height(34)
              .fontSize(14)
              .placeholderFont({ size: 14 })
              .placeholderColor($r('app.color.ink_faint'))
              .fontColor($r('app.color.ink'))
              .backgroundColor(Color.Transparent)
              .padding(0)
              .onChange((value: string) => {
                this.searchText = value;
                if (value.trim() !== '' && this.tab !== LibraryTab.ALL) {
                  // 搜索时自动切回全部，避免「喜欢」子集里搜不到造成困惑
                  this.tab = LibraryTab.ALL;
                }
              })
            if (this.searchText !== '') {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(15)
                .fontColor([$r('app.color.ink_faint')])
                .onClick(() => {
                  this.searchText = '';
                })
            }
          }
          .layoutWeight(1)
          .height(38)
          .borderRadius(19)
          .backgroundColor($r('app.color.surface_alt'))
          .padding({ left: 12, right: 12 })

          // 排序入口
          Row({ space: 3 }) {
            Text(sortLabel(this.sortMode))
              .fontSize(13)
              .fontColor($r('app.color.ink'))
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(12)
              .fontColor([$r('app.color.ink_soft')])
          }
          .height(38)
          .borderRadius(19)
          .backgroundColor($r('app.color.surface'))
          .padding({ left: 13, right: 11 })
          .bindMenu(this.SortMenu())
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 2 })

        // 分类 Tab：全部 / 喜欢 / 最近
        Row({ space: 8 }) {
          this.TabChip(LibraryTab.ALL, '全部')
          this.TabChip(LibraryTab.FAVORITES, '喜欢')
          this.TabChip(LibraryTab.RECENT, '最近')
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 10, bottom: 6 })

        // 歌曲列表 / 空态
        if (this.visibleSongs().length === 0) {
          if (appStore.player.songs.length === 0 && this.searchText.trim() === '') {
            this.LibraryEmptyView()
          } else if (this.searchText.trim() !== '') {
            this.NoResultView()
          } else if (this.tab === LibraryTab.FAVORITES) {
            this.EmptyHintView($r('sys.symbol.heart'), '还没有喜欢的歌曲',
              '长按歌曲或点击播放页 ♥，把喜欢的歌收进来')
          } else {
            this.EmptyHintView($r('sys.symbol.clock'), '还没有播放记录', '点一首歌开始听吧')
          }
        } else {
          List({ space: 2 }) {
            ForEach(this.visibleSongs(), (song: SongRecord) => {
              ListItem() {
                SongItem({
                  song: song,
                  isCurrent: song.id === appStore.player.currentSongId,
                  isPlaying: appStore.player.isPlaying,
                  onItemClick: (id: string) => appStore.player.playSong(id)
                })
                  .bindContextMenu(this.SongMenu(song), ResponseType.LongPress)
              }
              .swipeAction({
                end: {
                  builder: (): void => {
                    this.SwipeActions(song.id)
                  }
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
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
  }

  /** 分类计数：在 Builder 内部读取状态以建立响应依赖（按值传参不刷新） */
  private chipCount(tab: LibraryTab): number {
    if (tab === LibraryTab.ALL) {
      return appStore.player.songs.length;
    }
    if (tab === LibraryTab.FAVORITES) {
      return this.existingCount(appStore.userData.favoriteIds);
    }
    return this.existingCount(appStore.userData.recentIds);
  }

  @Builder
  TabChip(tab: LibraryTab, label: string) {
    Text(this.chipCount(tab) > 0 ? `${label} ${this.chipCount(tab)}` : label)
      .fontSize(13)
      .fontColor(this.tab === tab ? $r('app.color.paper') : $r('app.color.ink_soft'))
      .fontWeight(this.tab === tab ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .borderRadius(15)
      .backgroundColor(this.tab === tab ? $r('app.color.ink') : $r('app.color.surface'))
      .onClick(() => {
        this.tab = tab;
      })
  }

  /** 长按歌曲菜单 */
  @Builder
  SongMenu(song: SongRecord) {
    Column({ space: 2 }) {
      MenuItemRow({
        label: '下一首播放',
        icon: $r('sys.symbol.list_bullet'),
        onSelect: () => {
          const count = appStore.player.queueNext(song.id);
          promptAction.showToast({ message: count > 0 ? `已加入下一首播放 · 共 ${count} 首` : '已在插播队列中' });
        }
      })
      MenuItemRow({
        label: appStore.userData.isFavorite(song.id) ? '取消喜欢' : '喜欢',
        icon: appStore.userData.isFavorite(song.id) ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
        onSelect: () => {
          const fav = appStore.userData.toggleFavorite(song.id);
          promptAction.showToast({ message: fav ? '已添加到我喜欢的音乐' : '已取消喜欢' });
        }
      })
      MenuItemRow({
        label: '从曲库删除',
        icon: $r('sys.symbol.trash'),
        danger: true,
        onSelect: () => appStore.player.removeSong(song.id)
      })
    }
    .width(196)
    .padding(6)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.15)' })
  }

  /** 排序菜单 */
  @Builder
  SortMenu() {
    Column({ space: 2 }) {
      MenuItemRow({
        label: sortLabel(SortMode.DEFAULT),
        active: this.sortMode === SortMode.DEFAULT,
        onSelect: () => {
          this.sortMode = SortMode.DEFAULT;
        }
      })
      MenuItemRow({
        label: sortLabel(SortMode.TITLE),
        active: this.sortMode === SortMode.TITLE,
        onSelect: () => {
          this.sortMode = SortMode.TITLE;
        }
      })
      MenuItemRow({
        label: sortLabel(SortMode.ARTIST),
        active: this.sortMode === SortMode.ARTIST,
        onSelect: () => {
          this.sortMode = SortMode.ARTIST;
        }
      })
      MenuItemRow({
        label: sortLabel(SortMode.DURATION),
        active: this.sortMode === SortMode.DURATION,
        onSelect: () => {
          this.sortMode = SortMode.DURATION;
        }
      })
    }
    .width(160)
    .padding(6)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.15)' })
  }

  /** 左滑操作：下一首播放 + 删除 */
  @Builder
  SwipeActions(id: string) {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.paper')])
      }
      .width(52)
      .height('100%')
      .borderRadius(12)
      .backgroundColor($r('app.color.accent'))
      .justifyContent(FlexAlign.Center)
      .margin({ left: 6 })
      .onClick(() => {
        const count = appStore.player.queueNext(id);
        promptAction.showToast({ message: count > 0 ? `已加入下一首播放 · 共 ${count} 首` : '已在插播队列中' });
      })

      Column() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(20)
          .fontColor([$r('app.color.paper')])
      }
      .width(52)
      .height('100%')
      .borderRadius(12)
      .backgroundColor($r('app.color.danger'))
      .justifyContent(FlexAlign.Center)
      .margin({ left: 6 })
      .onClick(() => appStore.player.removeSong(id))
    }
    .height('100%')
  }

  /** 曲库空态：导入 / 演示曲目 */
  @Builder
  LibraryEmptyView() {
    Column({ space: 20 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(44)
          .fontColor([$r('app.color.ink_faint')])
      }
      .width(96)
      .height(96)
      .borderRadius(48)
      .backgroundColor($r('app.color.surface_alt'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 6 }) {
        Text('曲库还是空的')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
        Text('导入设备音频，或先听听内置演示曲目')
          .fontSize(13)
          .fontColor($r('app.color.ink_faint'))
      }

      Row({ space: 12 }) {
        Button('导入音乐')
          .height(42)
          .fontSize(15)
          .borderRadius(21)
          .backgroundColor($r('app.color.ink'))
          .fontColor($r('app.color.paper'))
          .onClick(() => this.importFromPicker())
        Button('载入演示曲目')
          .height(42)
          .fontSize(15)
          .borderRadius(21)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.ink'))
          .onClick(() => this.loadDemos())
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 60 })
  }

  /** 搜索无结果 */
  @Builder
  NoResultView() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(40)
        .fontColor([$r('app.color.ink_faint')])
      Text(`未找到 "${this.searchText.trim()}" 相关歌曲`)
        .fontSize(15)
        .fontColor($r('app.color.ink_soft'))
      Text('换个关键词试试，支持歌名与歌手')
        .fontSize(12)
        .fontColor($r('app.color.ink_faint'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 喜欢/最近空态提示 */
  @Builder
  EmptyHintView(icon: Resource, title: string, subtitle: string) {
    Column({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(40)
        .fontColor([$r('app.color.ink_faint')])
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.ink_soft'))
      Text(subtitle)
        .fontSize(12)
        .fontColor($r('app.color.ink_faint'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 40, right: 40 })
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
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
      .hideTitleBar(true)
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
