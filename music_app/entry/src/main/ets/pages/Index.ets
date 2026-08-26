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

/** 曲目来源：本地曲库 / 在线服务 */
enum SourceTab {
  LOCAL = 0,
  ONLINE = 1
}

/** 在线搜索防抖：输入停顿该时长后触发服务端搜索（毫秒） */
const SEARCH_DEBOUNCE_MS = 600;

/**
 * 歌曲列表数据源：包装过滤结果供 LazyForEach 按需创建列表项。
 * 列表总是整体替换（曲库刷新/筛选条件变化后 reload），无增量增删场景。
 */
class SongListDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private list: SongRecord[] = [];

  reload(list: SongRecord[]): void {
    this.list = list;
    this.listeners.forEach((listener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.list.length;
  }

  getData(index: number): SongRecord {
    return this.list[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }
}

/**
 * 主页面：源切换（本地/在线）+ 搜索/分类/排序 + 歌曲列表 + 迷你播放条，
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
  @Local sourceTab: SourceTab = SourceTab.LOCAL;
  @Local onlineLoading: boolean = false;
  /** 在线拉取失败提示（有旧缓存时仍展示缓存列表） */
  @Local onlineError: string = '';
  /** 最近一次成功拉取的在线列表（切回在线 tab 时的兜底缓存） */
  @Local onlineSongs: SongRecord[] = [];
  /** 在线搜索防抖定时器 id（-1 无待触发任务） */
  private searchTimerId: number = -1;
  /** 在线列表下拉刷新态（Refresh 组件绑定） */
  @Local isRefreshing: boolean = false;
  /** 在线请求代际号：新查询使旧响应作废（latest-wins，慢网下不再丢新查询） */
  private onlineRequestId: number = 0;
  /** LazyForEach 数据源 */
  private songSource: SongListDataSource = new SongListDataSource();

  aboutToAppear(): void {
    this.songSource.reload(this.filteredSongs);
  }

  /** 当前 Tab 与搜索词过滤后的列表（缓存计算，build 内多处引用只算一次）。
   * 在线模式列表即最近一次服务端返回（q 已在服务端匹配并聚合网络源），
   * 不再本地二次过滤，避免网络源结果被本地标题匹配误滤掉。 */
  @Computed
  get filteredSongs(): SongRecord[] {
    if (this.sourceTab === SourceTab.ONLINE) {
      return appStore.player.songs;
    }
    const opts: FilterOptions = {
      query: this.searchText,
      tab: this.tab,
      sort: this.sortMode,
      favoriteIds: appStore.userData.favoriteIds,
      recentIds: appStore.userData.recentIds
    };
    return filterAndSort(appStore.player.songs, opts);
  }

  @Monitor('filteredSongs')
  onFilteredSongsChange(): void {
    this.songSource.reload(this.filteredSongs);
  }

  /** 分类计数缓存：三个 chip 多处读取共享一次计算 */
  @Computed
  get tabCounts(): Map<LibraryTab, number> {
    const counts = new Map<LibraryTab, number>();
    counts.set(LibraryTab.ALL, appStore.player.songs.length);
    // O(曲目数+记录数)：以现有曲目 id 建 Set 替代逐条线性扫
    const known = new Set(appStore.player.songs.map((song) => song.id));
    let favCount = 0;
    for (const id of appStore.userData.favoriteIds) {
      if (known.has(id)) {
        favCount++;
      }
    }
    counts.set(LibraryTab.FAVORITES, favCount);
    let recentCount = 0;
    for (const id of appStore.userData.recentIds) {
      if (known.has(id)) {
        recentCount++;
      }
    }
    counts.set(LibraryTab.RECENT, recentCount);
    return counts;
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
            Text(this.sourceTab === SourceTab.ONLINE
              ? (appStore.player.songs.length > 0 ? `在线 · ${appStore.player.songs.length} 首歌曲` : '在线音乐')
              : (appStore.player.songs.length > 0 ? `${appStore.player.songs.length} 首歌曲` : '本地音乐'))
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

        // 源切换：本地曲库 / 在线服务
        Row({ space: 8 }) {
          this.SourceChip(SourceTab.LOCAL, '本地', $r('sys.symbol.music_note_list'))
          this.SourceChip(SourceTab.ONLINE, '在线', $r('sys.symbol.music_note_radiowaves_left_and_right'))
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 2 })

        // 搜索 + 排序（在线列表为服务端顺序，隐藏排序入口）
        Row({ space: 10 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(16)
              .fontColor([$r('app.color.ink_faint')])
            TextInput({
              text: this.searchText,
              placeholder: this.sourceTab === SourceTab.ONLINE ? '搜索歌曲、歌手、网络曲库' : '搜索歌曲、歌手',
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
                if (this.sourceTab === SourceTab.ONLINE) {
                  // 在线搜索由服务端完成（含网络源聚合），输入停顿后触发
                  this.scheduleOnlineSearch();
                  return;
                }
                if (value.trim() !== '' && this.tab !== LibraryTab.ALL) {
                  // 搜索时自动切回全部，避免「喜欢」子集里搜不到造成困惑
                  this.tab = LibraryTab.ALL;
                }
              })
            if (this.sourceTab === SourceTab.ONLINE && this.onlineLoading) {
              // 搜索发起处的即时加载指示（HarmonyOS 规范：异步操作在触发点反馈）
              LoadingProgress()
                .width(14)
                .height(14)
                .color($r('app.color.ink_faint'))
            }
            if (this.searchText !== '') {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(15)
                .fontColor([$r('app.color.ink_faint')])
                .onClick(() => {
                  this.searchText = '';
                  if (this.sourceTab === SourceTab.ONLINE) {
                    // 清空即回到服务器曲库全量
                    this.enterOnline('');
                  }
                })
            }
          }
          .layoutWeight(1)
          .height(38)
          .borderRadius(19)
          .backgroundColor($r('app.color.surface_alt'))
          .padding({ left: 12, right: 12 })

          if (this.sourceTab === SourceTab.LOCAL) {
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
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 2 })

        // 分类 Tab：全部 / 喜欢 / 最近（本地源语义，在线隐藏）
        if (this.sourceTab === SourceTab.LOCAL) {
          Row({ space: 8 }) {
            this.TabChip(LibraryTab.ALL, '全部')
            this.TabChip(LibraryTab.FAVORITES, '喜欢')
            this.TabChip(LibraryTab.RECENT, '最近')
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 10, bottom: 6 })
        }

        // 歌曲列表 / 空态
        if (this.filteredSongs.length === 0) {
          if (this.sourceTab === SourceTab.ONLINE) {
            this.OnlineStatusView()
          } else if (appStore.player.songs.length === 0 && this.searchText.trim() === '') {
            this.LibraryEmptyView()
          } else if (this.searchText.trim() !== '') {
            this.NoResultView()
          } else if (this.tab === LibraryTab.FAVORITES) {
            this.EmptyHintView($r('sys.symbol.heart'), '还没有喜欢的歌曲',
              '长按歌曲或点击播放页 ♥，把喜欢的歌收进来')
          } else {
            this.EmptyHintView($r('sys.symbol.clock'), '还没有播放记录', '点一首歌开始听吧')
          }
        } else if (this.sourceTab === SourceTab.ONLINE) {
          // 在线列表：下拉刷新（HarmonyOS 标准刷新交互），刷新态由加载流程收尾
          Refresh({ refreshing: $$this.isRefreshing }) {
            this.SongList()
          }
          .onRefreshing(() => {
            this.enterOnline(this.searchText.trim()).finally(() => {
              this.isRefreshing = false;
            });
          })
          .layoutWeight(1)
        } else {
          this.SongList()
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
        // 全局恒定全屏布局：背景层已延伸进系统栏，前景内容按预读避让高度留白
        .padding({ top: appStore.safeTopVp, bottom: appStore.safeBottomVp })
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
  }

  /** 歌曲列表：加载中在顶部显示轻量状态行（已有列表时的加载/搜索反馈） */
  @Builder
  SongList() {
    List({ space: 2 }) {
      if (this.onlineLoading) {
        ListItem() {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.ink_faint'))
            Text(this.searchText.trim() !== '' ? `正在搜索"${this.searchText.trim()}"…` : '正在更新在线曲库…')
              .fontSize(13)
              .fontColor($r('app.color.ink_soft'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 10, bottom: 10 })
        }
      }
      LazyForEach(this.songSource, (song: SongRecord) => {
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
    .cachedCount(6)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, bottom: 8 })
    .scrollBar(BarState.Off)
  }

  /** 分类计数：在 Builder 内部读取 @Computed 状态以建立响应依赖（按值传参不刷新） */
  private chipCount(tab: LibraryTab): number {
    return this.tabCounts.get(tab) ?? 0;
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

  /** 源切换 chip */
  @Builder
  SourceChip(tab: SourceTab, label: string, icon: Resource) {
    Row({ space: 5 }) {
      SymbolGlyph(icon)
        .fontSize(14)
        .fontColor([this.sourceTab === tab ? $r('app.color.paper') : $r('app.color.ink_soft')])
      Text(label)
        .fontSize(13)
        .fontColor(this.sourceTab === tab ? $r('app.color.paper') : $r('app.color.ink_soft'))
        .fontWeight(this.sourceTab === tab ? FontWeight.Medium : FontWeight.Normal)
    }
    .padding({ left: 14, right: 14, top: 5, bottom: 5 })
    .borderRadius(15)
    .backgroundColor(this.sourceTab === tab ? $r('app.color.ink') : $r('app.color.surface'))
    .onClick(() => this.switchSource(tab))
  }

  /** 在线列表状态视图：加载中 / 未配置 / 拉取失败 / 服务器空库 / 搜索无结果 */
  @Builder
  OnlineStatusView() {
    if (this.onlineLoading) {
      Column({ space: 14 }) {
        LoadingProgress()
          .width(38)
          .height(38)
          .color($r('app.color.ink_faint'))
        Text('正在拉取在线曲库…')
          .fontSize(14)
          .fontColor($r('app.color.ink_soft'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.onlineError !== '' && appStore.player.songs.length === 0) {
      Column({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(40)
          .fontColor([$r('app.color.ink_faint')])
        Text('在线曲库拉取失败')
          .fontSize(15)
          .fontColor($r('app.color.ink_soft'))
        Text(this.onlineError)
          .fontSize(12)
          .fontColor($r('app.color.ink_faint'))
        Button('重试')
          .height(38)
          .fontSize(14)
          .borderRadius(19)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.ink'))
          .onClick(() => this.enterOnline(this.searchText.trim()))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.searchText.trim() !== '') {
      this.NoResultView()
    } else {
      Column({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(40)
          .fontColor([$r('app.color.ink_faint')])
        Text('服务器曲库还是空的')
          .fontSize(15)
          .fontColor($r('app.color.ink_soft'))
        Text('向服务端曲库目录投放音频后，下拉这里重试')
          .fontSize(12)
          .fontColor($r('app.color.ink_faint'))
        Button('重试')
          .height(38)
          .fontSize(14)
          .borderRadius(19)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.ink'))
          .onClick(() => this.enterOnline(this.searchText.trim()))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
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
      if (this.sourceTab === SourceTab.LOCAL) {
        MenuItemRow({
          label: '从曲库删除',
          icon: $r('sys.symbol.trash'),
          danger: true,
          onSelect: () => appStore.player.removeSong(song.id)
        })
      }
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

      if (this.sourceTab === SourceTab.LOCAL) {
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

  /** 从设置页返回时，仅在服务地址刚变更过才重拉在线曲库；
   * 从播放页等页面返回不再盲目重拉，避免打断现有队列与列表状态 */
  onPageShow(): void {
    if (this.sourceTab === SourceTab.ONLINE && appStore.consumeOnlineConfigDirty()) {
      this.enterOnline(this.searchText.trim());
    }
  }

  /** 切换曲目来源：本地回读曲库，在线重新拉取（重复点击在线等同刷新） */
  private switchSource(tab: SourceTab): void {
    if (this.sourceTab === tab && tab === SourceTab.LOCAL) {
      return;
    }
    this.sourceTab = tab;
    this.searchText = '';
    this.cancelPendingSearch();
    if (tab === SourceTab.ONLINE) {
      this.enterOnline('');
    } else {
      appStore.player.refreshSongs();
    }
  }

  /** 在线搜索防抖：输入停顿后触发服务端搜索 */
  private scheduleOnlineSearch(): void {
    this.cancelPendingSearch();
    this.searchTimerId = setTimeout(() => {
      this.searchTimerId = -1;
      this.enterOnline(this.searchText.trim());
    }, SEARCH_DEBOUNCE_MS);
  }

  private cancelPendingSearch(): void {
    if (this.searchTimerId >= 0) {
      clearTimeout(this.searchTimerId);
      this.searchTimerId = -1;
    }
  }

  /** 进入在线源：按关键词拉取曲目（空=曲库全量）并替换播放队列；失败时回退旧缓存并提示。
   * latest-wins：在途请求期间的新查询立即发出，旧响应按代际号作废丢弃 */
  private async enterOnline(query: string): Promise<void> {
    const reqId = ++this.onlineRequestId;
    this.onlineLoading = true;
    this.onlineError = '';
    try {
      const list = await appStore.onlineSource.fetchSongs(query);
      if (reqId !== this.onlineRequestId) {
        return; // 已有更新的查询在途，过期响应丢弃
      }
      this.onlineSongs = list;
      appStore.player.setOnlineQueue(list);
    } catch (err) {
      if (reqId !== this.onlineRequestId) {
        return;
      }
      this.onlineError = `连接失败：${err instanceof Error ? err.message : '未知错误'}`;
      if (this.onlineSongs.length > 0) {
        // 拉取失败但有旧缓存：继续用旧列表，不打断已有队列
        appStore.player.setOnlineQueue(this.onlineSongs);
        promptAction.showToast({ message: '在线列表拉取失败，正在展示上次结果' });
      }
    } finally {
      // 仅最新请求有权收尾 loading，避免旧响应提前关闭新查询的加载态
      if (reqId === this.onlineRequestId) {
        this.onlineLoading = false;
      }
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
    if (this.scanning) {
      return; // 与导入共用并发守卫，双击不产生重复记录
    }
    this.scanning = true;
    try {
      const added = await appStore.library.importDemoTracks();
      appStore.player.refreshSongs();
      promptAction.showToast({
        message: added > 0 ? `已载入 ${added} 首演示曲目` : '演示曲目已加载过'
      });
    } finally {
      this.scanning = false;
    }
  }
}
