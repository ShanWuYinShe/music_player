import { picker } from '@kit.CoreFileKit';
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { SongRecord } from '../model/Song';
import { LibraryTab, SortMode, FilterOptions, filterAndSort, sortLabel } from '../common/LibraryFilter';
import { SongItem } from '../components/SongItem';
import { MiniPlayerBar, MiniInfo } from '../components/MiniPlayerBar';
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
  /** 曲库排序方式：初始值来自持久化偏好，变更即落盘（重启恢复） */
  @Local sortMode: SortMode = appStore.userData.sortMode;
  @Local scanning: boolean = false;
  @Local sourceTab: SourceTab = SourceTab.LOCAL;
  @Local onlineLoading: boolean = false;
  /** 在线拉取失败提示（有旧列表时仍展示旧列表） */
  @Local onlineError: string = '';
  /** 在线列表唯一展示数据源：最近一次成功拉取的结果。播放队列
   * (player.songs) 在拉取返回前仍是本地曲库，展示层直读会让在线 tab
   * 在加载期间闪现本地曲目（逻辑错误）；拉取失败时保留旧值兜底 */
  @Local onlineSongs: SongRecord[] = [];
  /** 在线搜索防抖定时器 id（-1 无待触发任务） */
  private searchTimerId: number = -1;
  /** 在线列表下拉刷新态（Refresh 组件绑定） */
  @Local isRefreshing: boolean = false;
  /** 在线请求代际号：新查询使旧响应作废（latest-wins，慢网下不再丢新查询） */
  private onlineRequestId: number = 0;
  /** LazyForEach 数据源 */
  private songSource: SongListDataSource = new SongListDataSource();

  /** 播放镜像：真机上 player(@ObservedV2) 的 @Trace/@Computed 对 if 分支与
   * 属性插值均不触发 UI 更新（仅 Text 内容插值存活，已实测），改由
   * onStateChanged 显式回调驱动 @Local（@Local 的 if 分支可靠） */
  @Local mini: MiniInfo | null = null;
  private stateListener: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.songSource.reload(this.filteredSongs);

    // 播放失败（在线无版权/网络中断等）统一 toast 反馈，由 PlayerController 回调
    appStore.player.onPlaybackError = (message: string): void => {
      promptAction.showToast({ message: message, duration: 2500 });
    };
    // 播放状态镜像：切歌/启停时刷新 mini bar 并重建列表当前行。
    // 上轮提交此处接线丢失（文本替换静默失败），导致 mini bar 永不出现——已回踩
    this.stateListener = (): void => {
      const song = appStore.player.currentSong;
      this.mini = song === null ? null : {
        title: song.title,
        artist: song.artist,
        coverPath: song.coverPath,
        isPlaying: appStore.player.isPlaying
      };
      // 当前播放行(高亮/EQ)在 LazyForEach 项内不随状态刷新，重建列表驱动
      this.songSource.reload(this.filteredSongs);
    };
    appStore.player.addStateListener(this.stateListener);
    // 冷启动恢复的播放态发生在本组件挂载前(init 早于 aboutToAppear)，补一次同步
    this.stateListener();
  }

  /** 当前 Tab 与搜索词过滤后的列表（缓存计算，build 内多处引用只算一次）。
   * 在线模式展示 onlineSongs（最近一次成功结果，q 已在服务端匹配并聚合
   * 网络源），不再本地二次过滤，避免网络源结果被本地标题匹配误滤掉，
   * 也不直读 player.songs——它是播放队列，加载期间还是本地曲库。 */
  @Computed
  get filteredSongs(): SongRecord[] {
    if (this.sourceTab === SourceTab.ONLINE) {
      return this.onlineSongs;
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
              ? (this.onlineSongs.length > 0 ? `在线 · ${this.onlineSongs.length} 首歌曲` : '在线音乐')
              : (appStore.player.songs.length > 0 ? `${appStore.player.songs.length} 首歌曲` : '本地音乐'))
              .fontSize(13)
              .fontColor($r('app.color.ink_soft'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.sourceTab === SourceTab.LOCAL) {
            // 本地曲库常驻导入入口：平台(API 24)已移除静默扫描公共媒体库的
            // 权限与 API，AudioViewPicker 用户选择是唯一导入途径，不能只藏在空态
            SymbolGlyph($r('sys.symbol.folder_badge_plus'))
              .fontSize(22)
              .fontColor([$r('app.color.ink')])
              .padding(10)
              .accessibilityText('导入音乐')
              .onClick(() => this.importFromPicker())
          }
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(22)
            .fontColor([$r('app.color.ink')])
            .padding(10)
            .accessibilityText('设置')
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

        // 网易云未登录提示：VIP 歌曲仅试听片段（登录后自动消失）
        if (this.sourceTab === SourceTab.ONLINE && appStore.neteaseEnabled && !appStore.neteaseLoggedIn) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(14)
              .fontColor([$r('app.color.accent')])
            Text('网易云未登录：VIP 歌曲仅 30 秒试听，在服务器管理面板「音乐曲库」扫码登录可解锁')
              .fontSize(11)
              .fontColor($r('app.color.ink_soft'))
              .layoutWeight(1)
              .maxLines(2)
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 0.5, color: $r('app.color.line') })
          .margin({ top: 4 })
        }

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
              .constraintSize({ minHeight: 34 })
              .fontSize(14)
              .placeholderFont({ size: 14 })
              .placeholderColor($r('app.color.ink_faint'))
              .fontColor($r('app.color.ink'))
              .caretColor($r('app.color.accent'))
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
                .padding(4)
                .accessibilityText('清空搜索')
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
          // minHeight 替代固定高度：系统大字体时搜索框随内容撑高不截断
          .constraintSize({ minHeight: 38 })
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

        // 底部迷你播放条（内容经 @Local 镜像，见 mini 字段注释）
        if (this.mini !== null) {
          MiniPlayerBar({
            player: appStore.player,
            info: this.mini,
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

  /** 歌曲列表。加载反馈不插顶部状态行：无旧列表时列表区域由
   * OnlineStatusView 居中呈现加载态，有旧列表时保留展示（搜索框内
   * 小 loading 与下拉刷新指示反馈进行中），避免列表内容跳动 */
  @Builder
  SongList() {
    List({ space: 2 }) {
      LazyForEach(this.songSource, (song: SongRecord) => {
        ListItem() {
          SongItem({
            song: song,
            isCurrent: song.id === appStore.player.currentSongId,
            isPlaying: appStore.player.isPlaying,
            keyword: this.searchText,
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
      .fontColor(this.tab === tab ? $r('app.color.on_accent') : $r('app.color.ink_soft'))
      .fontWeight(this.tab === tab ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .borderRadius(15)
      .backgroundColor(this.tab === tab ? $r('app.color.accent') : $r('app.color.surface'))
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
        .fontColor([this.sourceTab === tab ? $r('app.color.on_accent') : $r('app.color.ink_soft')])
      Text(label)
        .fontSize(13)
        .fontColor(this.sourceTab === tab ? $r('app.color.on_accent') : $r('app.color.ink_soft'))
        .fontWeight(this.sourceTab === tab ? FontWeight.Medium : FontWeight.Normal)
    }
    .padding({ left: 14, right: 14, top: 5, bottom: 5 })
    .borderRadius(15)
    .backgroundColor(this.sourceTab === tab ? $r('app.color.accent') : $r('app.color.surface'))
    .onClick(() => this.switchSource(tab))
  }

  /** 在线列表状态视图（列表区域整体呈现，非顶部插行）：加载中 /
   * 拉取失败 / 服务器空库 / 搜索无结果 */
  @Builder
  OnlineStatusView() {
    if (this.onlineLoading) {
      Column({ space: 14 }) {
        LoadingProgress()
          .width(38)
          .height(38)
          .color($r('app.color.ink_faint'))
        Text(this.searchText.trim() !== '' ? `正在搜索 "${this.searchText.trim()}"…` : '正在拉取在线曲库…')
          .fontSize(14)
          .fontColor($r('app.color.ink_soft'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.onlineError !== '' && this.onlineSongs.length === 0) {
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

  /** 长按歌曲菜单：原生 Menu/MenuItem，磨砂底/圆角/行高/按压态由系统托管 */
  @Builder
  SongMenu(song: SongRecord) {
    Menu() {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet')),
        content: '下一首播放'
      })
        .onClick(() => {
          const count = appStore.player.queueNext(song.id);
          promptAction.showToast({ message: count > 0 ? `已加入下一首播放 · 共 ${count} 首` : '已在插播队列中' });
        })
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier(
          appStore.userData.isFavorite(song.id) ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart')),
        content: appStore.userData.isFavorite(song.id) ? '取消喜欢' : '喜欢'
      })
        .onClick(() => {
          const fav = appStore.userData.toggleFavorite(song.id);
          promptAction.showToast({ message: fav ? '已添加到我喜欢的音乐' : '已取消喜欢' });
        })
      if (this.sourceTab === SourceTab.LOCAL) {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')),
          content: '从曲库删除'
        })
          .onClick(() => this.confirmRemoveSong(song))
      }
    }
  }

  /** 排序菜单：MenuItemGroup 分组标题 + 原生勾选（当前排序项） */
  @Builder
  SortMenu() {
    Menu() {
      MenuItemGroup({ header: '排序方式' }) {
        MenuItem({
          content: sortLabel(SortMode.DEFAULT),
          symbolEndIcon: this.sortCheckIcon(this.sortMode === SortMode.DEFAULT)
        })
          .onClick(() => {
            this.changeSortMode(SortMode.DEFAULT);
          })
        MenuItem({
          content: sortLabel(SortMode.TITLE),
          symbolEndIcon: this.sortCheckIcon(this.sortMode === SortMode.TITLE)
        })
          .onClick(() => {
            this.changeSortMode(SortMode.TITLE);
          })
        MenuItem({
          content: sortLabel(SortMode.ARTIST),
          symbolEndIcon: this.sortCheckIcon(this.sortMode === SortMode.ARTIST)
        })
          .onClick(() => {
            this.changeSortMode(SortMode.ARTIST);
          })
        MenuItem({
          content: sortLabel(SortMode.DURATION),
          symbolEndIcon: this.sortCheckIcon(this.sortMode === SortMode.DURATION)
        })
          .onClick(() => {
            this.changeSortMode(SortMode.DURATION);
          })
      }
    }
  }

  /** 切换排序并持久化（重启恢复） */
  private changeSortMode(mode: SortMode): void {
    this.sortMode = mode;
    appStore.userData.setSortMode(mode);
  }

  /** 原生菜单勾选图标：激活项出勾，非激活传 undefined */
  private sortCheckIcon(active: boolean): SymbolGlyphModifier | undefined {
    return active ? new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined;
  }

  /** 删除曲目二次确认：原生菜单无红色警示项，破坏性操作走确认对话框 */
  private confirmRemoveSong(song: SongRecord): void {
    AlertDialog.show({
      title: '从曲库删除',
      message: `将删除「${song.title}」及其音频文件，不可恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      backgroundColor: $r('app.color.surface'),
      cornerRadius: 24,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.ink_soft'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => appStore.player.removeSong(song.id)
      }
    });
  }

  /** 左滑操作：下一首播放 + 删除 */
  @Builder
  SwipeActions(id: string) {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(20)
          .fontColor([$r('app.color.on_accent')])
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
            .fontColor([$r('app.color.on_accent')])
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

  /** 进入在线源：按关键词拉取曲目（空=曲库全量），成功后更新展示列表
   * (onlineSongs) 并替换播放队列；失败时保留旧列表并提示。
   * latest-wins：在途请求期间的新查询立即发出，旧响应按代际号作废丢弃 */
  private async enterOnline(query: string): Promise<void> {
    const reqId = ++this.onlineRequestId;
    this.onlineLoading = true;
    this.onlineError = '';
    appStore.refreshOnlineProviders().catch(() => {
    });
    try {
      const list = await appStore.onlineSource.fetchSongs(query);
      if (reqId !== this.onlineRequestId) {
        return; // 已有更新的查询在途，过期响应丢弃
      }
      if (this.sourceTab !== SourceTab.ONLINE) {
        return; // 已切回本地：晚到的响应不得替换 player.songs 污染本地列表
        // （切回在线时 switchSource 会重新拉取）
      }
      this.onlineSongs = list;
      appStore.player.setOnlineQueue(list);
    } catch (err) {
      if (reqId !== this.onlineRequestId || this.sourceTab !== SourceTab.ONLINE) {
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
        const result = await appStore.library.importFromUris(uris);
        appStore.player.refreshSongs();
        // 分类提示：IO/URI 失败不得误报为"已在曲库"
        let message = '';
        if (result.added > 0 && result.failed === 0 && result.dup === 0) {
          message = `已导入 ${result.added} 首歌曲`;
        } else if (result.added > 0) {
          message = `已导入 ${result.added} 首` +
            (result.dup > 0 ? `，${result.dup} 首已在曲库` : '') +
            (result.failed > 0 ? `，${result.failed} 首导入失败` : '');
        } else if (result.dup > 0 && result.failed === 0) {
          message = '所选歌曲已在曲库中';
        } else if (result.dup > 0) {
          message = `${result.dup} 首已在曲库，${result.failed} 首导入失败`;
        } else {
          message = '导入失败，请重试';
        }
        promptAction.showToast({ message: message });
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
