import { picker } from '@kit.CoreFileKit';
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { SongRecord } from '../model/Song';
import { LibraryTab, SortMode, FilterOptions, filterAndSort, sortLabel } from '../common/LibraryFilter';
import { SongItem } from '../components/SongItem';
import { MiniPlayerBar, MiniInfo } from '../components/MiniPlayerBar';
import { PlayerPage } from './PlayerPage';
import { SettingsPage } from './SettingsPage';

/** 金色 accent 文件级常量：@Builder 内引用组件字段需 this 前缀，常量直引更净 */
const CURRENT_TINT: Resource = $r('app.color.accent');

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
  /** 列表滚动控制器：本地/在线各持一个（Scroller 不可绑定多个滚动组件） */
  private localScroller: Scroller = new Scroller();
  private onlineScroller: Scroller = new Scroller();
  /** 远离顶部时在拇指区露出回顶按钮（onScrollIndex 驱动） */
  @Local showBackTop: boolean = false;
  /** 下拉悬停位移（vp）：>0 时整页内容下沉，顶部控件落入拇指区（同一套 UI 映射，无重复入口） */
  @Local reachY: number = 0;
  /** 页面可视高度（vp）：悬停目标位移按该值比例计算 */
  private pageH: number = 800;

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
      const hadMini = this.mini !== null;
      this.mini = song === null ? null : {
        seedId: song.id,
        title: song.title,
        artist: song.artist,
        coverPath: song.coverPath,
        isPlaying: appStore.player.isPlaying
      };
      // 迷你条首次出现时教一次下滑悬停（手势入口无可见控件，须告知）
      if (!hadMini && this.mini !== null && !appStore.userData.hasSeenReachHint()) {
        promptAction.showToast({ message: '在迷你条上向下滑，可把顶部拉下来单手操作', duration: 3000 });
        appStore.userData.markReachHintSeen();
      }
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
      // alignContent=Bottom：悬停收起 pill 叠在底部中央（满幅子层不受影响）
      Stack({ alignContent: Alignment.Bottom }) {
        // 全屏背景层：延伸至状态栏与导航条下方，消除顶部/底部割裂；
        // 播放中叠当前曲封面的模糊氛围层（低透明度，压暗不抢内容）
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.page_bg'))
          if (this.mini !== null && this.mini.coverPath !== '') {
            Image(this.mini.coverPath)
              .width('120%')
              .height('40%')
              .position({ x: '-10%', y: 0 })
              .blur(90)
              .opacity(0.28)
          }
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .clip(true)

        Column() {
        // 源切换（主模式）+ 页面级操作：点选走 switchSource 改受控 index，
        // 列表区滑动由 Tabs onChange 回写同一入口；导入/设置居右（原
        // Navigation menus 迁入——标题栏已整条去除）
        Row({ space: 8 }) {
          this.SourceChip(SourceTab.LOCAL, '本地', $r('sys.symbol.music_note_list'))
          this.SourceChip(SourceTab.ONLINE, '在线', $r('sys.symbol.music_note_radiowaves_left_and_right'))
          Blank()
          if (this.sourceTab === SourceTab.LOCAL) {
            // 本地曲库常驻导入入口：平台(API 24)已移除静默扫描公共媒体库的
            // 权限与 API，AudioViewPicker 用户选择是唯一导入途径
            SymbolGlyph($r('sys.symbol.folder_badge_plus'))
              .fontSize(20)
              .fontColor([$r('app.color.ink')])
              .padding(10)
              .accessibilityText('导入音乐')
              .onClick(() => this.importFromPicker())
          }
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(20)
            .fontColor([$r('app.color.ink')])
            .padding(10)
            .accessibilityText('设置')
            .onClick(() => this.pathStack.pushPathByName('settings', null))
        }
        .width('100%')
        // 顶部留白含状态栏避让（标题栏去除后内容顶到系统栏下）
        .padding({ left: 20, right: 16, top: appStore.safeTopVp + 8, bottom: 2 })

        // 系统搜索框（样式/清除键/键盘搜索键由系统托管，深浅自动适配）：
        // 输入语义与旧自绘框一致（本地即时过滤 + 切全部，在线防抖服务端搜）
        Row() {
          Search({
            value: this.searchText,
            placeholder: this.sourceTab === SourceTab.ONLINE ? '搜索歌曲、歌手、网络曲库' : '搜索歌曲、歌手',
          })
            .layoutWeight(1)
            .constraintSize({ minHeight: 40 })
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faint'))
            .onChange((value: string) => {
              const prev = this.searchText;
              this.searchText = value;
              if (this.sourceTab === SourceTab.ONLINE) {
                // 在线搜索由服务端完成（含网络源聚合），输入停顿后触发；
                // 框内清除键清空即回到服务器曲库全量
                if (value === '' && prev !== '') {
                  this.enterOnline('');
                } else {
                  this.scheduleOnlineSearch();
                }
                return;
              }
              if (value.trim() !== '' && this.tab !== LibraryTab.ALL) {
                // 搜索时自动切回全部，避免「喜欢」子集里搜不到造成困惑
                this.tab = LibraryTab.ALL;
              }
            })
            .onSubmit((value: string) => {
              // 键盘搜索键：在线立即触发一次（不等防抖），本地已是即时过滤
              if (this.sourceTab === SourceTab.ONLINE) {
                this.cancelPendingSearch();
                this.enterOnline(value.trim());
              }
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 2 })

        // 列表过滤器（本地源语义，在线隐藏）：分类 + 排序是列表的就近过滤器，
        // 章节索引文字风放搜索下方
        if (this.sourceTab === SourceTab.LOCAL) {
          Row({ space: 0 }) {
            this.TabChip(LibraryTab.ALL, '全部')
            this.TabChip(LibraryTab.FAVORITES, '喜欢')
            this.TabChip(LibraryTab.RECENT, '最近')
            Blank()
            this.SortButton()
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 4 })
        }

        // 源切换 Tabs（系统滑动手势 + 切换动画）：TabContent 不带 tabBar
        // （系统栏定高 91vp 且两项左右散开，不符合分段控件观感），切换条用
        // 自绘胶囊行（点选经 switchSource 改受控 index；滑动经 onChange 回写）
        Tabs({ barPosition: BarPosition.Start, index: this.sourceTab }) {
          TabContent() {
            if (this.filteredSongs.length === 0) {
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
              this.SongList(this.localScroller)
            }
          }

          TabContent() {
            if (this.filteredSongs.length === 0) {
              this.OnlineStatusView()
            } else {
              // 在线列表：下拉刷新（HarmonyOS 标准刷新交互），刷新态由加载流程收尾
              Refresh({ refreshing: $$this.isRefreshing }) {
                this.SongList(this.onlineScroller)
              }
              .onRefreshing(() => {
                this.enterOnline(this.searchText.trim()).finally(() => {
                  this.isRefreshing = false;
                });
              })
              // TabContent 非线性布局：layoutWeight 失效致内容居中留白，
              // 用足高替代（空态 Column 居中即所求，保留 layoutWeight 无碍）
              .height('100%')
            }
          }
        }
        // TabContent 不挂 tabBar 时系统仍保留 91vp 空栏（实测截图布局树
        // TabBar bounds 182px），barHeight(0)+barOverlap 压掉，页面零空隙
        .barHeight(0)
        .barOverlap(true)
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number) => {
          if (index !== this.sourceTab) {
            this.switchSource(index);
          }
        })

        // 底部回顶：远离顶部时才在拇指区占位，回到顶部自动收起不留白
        if (this.showBackTop) {
          this.BottomToolbar()
        }

        // 底部迷你播放条（内容经 @Local 镜像，见 mini 字段注释）：
        // 其上的手势 = 半屏拇指遥控：下滑拉悬停 / 横滑切分类 / 画 <> 切源
        if (this.mini !== null) {
          MiniPlayerBar({
            player: appStore.player,
            info: this.mini,
            onTapOpen: () => this.pathStack.pushPathByName('player', null),
            onPullDown: () => this.setReach(true),
            onSwipeTab: (direction: number) => this.cycleTab(direction),
            onSwipeSource: (direction: number) => this.cycleSource(direction)
          })
        }
        }
        .width('100%')
        .height('100%')
        // 顶部避让已并入源切换行 padding（safeTopVp+8），此处只留底部避让
        // （背景层仍延伸进系统栏）；下拉悬停时整体下沉（translate 由
        // reachY 驱动，动画在 setReach 内指定）
        .padding({ bottom: appStore.safeBottomVp })
        .translate({ y: this.reachY })
        .onAreaChange((_old: Area, area: Area) => {
          const h = area.height as number;
          if (h > 0) {
            this.pageH = h;
          }
        })

        // 悬停收起 pill：悬停态才叠在底部中央；内容整体下沉后它仍固定可点
        if (this.reachY > 0) {
          this.ReachExit()
        }
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    // 标题栏整条去除（「音乐/N 首歌曲」与「全部 N」chip 冗余）：内容顶到
    // 状态栏下，导入/设置并入源切换行右端（TopToolbar）
    .hideTitleBar(true)
    .navDestination(this.pageMap)
  }

  /** 歌曲列表（杂志目录）：行间零间距 + 发丝线分隔（分隔由ListItem边界线
   * 承担），排版行的密度优势靠这个兑现。加载反馈不插顶部状态行：无旧列表
   * 时列表区域由 OnlineStatusView 居中呈现加载态，有旧列表时保留展示
   * （搜索框内小 loading 与下拉刷新指示反馈进行中），避免列表内容跳动 */
  @Builder
  SongList(scroller: Scroller) {
    List({ space: 0, scroller: scroller }) {
      LazyForEach(this.songSource, (song: SongRecord) => {
        ListItem() {
          Column() {
            SongItem({
              song: song,
              isCurrent: song.id === appStore.player.currentSongId,
              isPlaying: appStore.player.isPlaying,
              keyword: this.searchText,
              onItemClick: (id: string) => appStore.player.playSong(id)
            })
              .bindContextMenu(this.SongMenu(song), ResponseType.LongPress)
            // 发丝线：目录行的分隔语言（最后一行由列表底部自然收尾，不画）
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.editorial_rule'))
              .margin({ left: 71 })
          }
        }
      }, (song: SongRecord) => song.id)
    }
    .cachedCount(6)
    .width('100%')
    // TabContent 非线性布局：layoutWeight 失效致列表按内容高居中、
    // 上方留白，必须足高
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .scrollBar(BarState.Auto)
    .onScrollIndex((start: number) => {
      // 远离顶部才在拇指区露出回顶按钮，回到顶部自动收起
      this.showBackTop = start > 2;
    })
  }

  /** 分类计数：在 Builder 内部读取 @Computed 状态以建立响应依赖（按值传参不刷新） */
  private chipCount(tab: LibraryTab): number {
    return this.tabCounts.get(tab) ?? 0;
  }

  @Builder
  TabChip(tab: LibraryTab, label: string) {
    Text(this.chipCount(tab) > 0 ? `${label} ${this.chipCount(tab)}` : label)
      .fontSize(14)
      .fontColor(this.tab === tab ? CURRENT_TINT : $r('app.color.editorial_meta'))
      .fontWeight(this.tab === tab ? FontWeight.Bold : FontWeight.Normal)
      .letterSpacing(this.tab === tab ? 0.5 : 0)
      // 文字标签风（章节索引）：无底无框，热区由 padding 保 40vp
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .accessibilityText(`分类${label}`)
      .onClick(() => {
        this.tab = tab;
        this.showBackTop = false;
        this.localScroller.scrollToIndex(0);
      })
  }

  /** 源切换（Tabs 系统栏不用后，由该行点选驱动受控 index；
   * 选中态读 sourceTab，滑动切页经 onChange 回写后同样刷新）。
   * 排印风：选中项金色加粗 + 下方短金线（书脊标记），无底色 */
  @Builder
  SourceChip(tab: SourceTab, label: string, icon: Resource) {
    Column({ space: 4 }) {
      Row({ space: 5 }) {
        SymbolGlyph(icon)
          .fontSize(14)
          .fontColor([this.sourceTab === tab ? CURRENT_TINT : $r('app.color.editorial_meta')])
        Text(label)
          .fontSize(15)
          .fontColor(this.sourceTab === tab ? CURRENT_TINT : $r('app.color.editorial_meta'))
          .fontWeight(this.sourceTab === tab ? FontWeight.Bold : FontWeight.Normal)
      }
      // 选中项下方短金线（书脊标记）
      Row()
        .width(20)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.sourceTab === tab ? CURRENT_TINT : Color.Transparent)
    }
    // 上下 padding 补足 40vp 触控热区
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .accessibilityText(`切换到${label}`)
    .onClick(() => this.switchSource(tab))
  }

  /** 底部回顶（情境出现才占位）：底部常驻触发器只剩它 + 迷你条，
   * 源/分类/排序已回顶部，悬停映射由迷你条下滑触发 */
  @Builder
  BottomToolbar() {
    Row() {
      Blank()
      SymbolGlyph($r('sys.symbol.arrow_up'))
        .fontSize(18)
        .fontColor([$r('app.color.on_accent')])
        // 18 + 上下 padding 22 = 40vp 热区
        .padding(11)
        .borderRadius(20)
        .backgroundColor($r('app.color.accent'))
        .accessibilityText('回到顶部')
        .onClick(() => {
          this.activeScroller().scrollToIndex(0, true);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 8 })
  }

  /** 下拉悬停开关：整页内容下沉 45% 高度，顶部控件落入拇指区；
   * 同一套 UI 做位移映射，不复制入口，审美保持经典布局 */
  private setReach(on: boolean): void {
    const target = on ? Math.round(this.pageH * 0.45) : 0;
    this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.reachY = target;
    });
  }

  /** 悬停收起 pill：悬停态才叠在底部中央，点按回弹（不挡顶部操作区） */
  @Builder
  ReachExit() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.chevron_up'))
        .fontSize(14)
        .fontColor([$r('app.color.on_accent')])
      Text('收起')
        .fontSize(13)
        .fontColor($r('app.color.on_accent'))
    }
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .borderRadius(20)
    .backgroundColor($r('app.color.accent'))
    .accessibilityText('收起悬停，回到正常布局')
    .margin({ bottom: 40 })
    .onClick(() => this.setReach(false))
  }

  /** 排序按钮（本地源语义：在线列表为服务端顺序，无排序入口）。
   * 排印风：meta 色文字，与分类同行右对齐 */
  @Builder
  SortButton() {
    Row({ space: 3 }) {
      Text(sortLabel(this.sortMode))
        .fontSize(13)
        .fontColor($r('app.color.editorial_meta'))
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([$r('app.color.editorial_meta')])
    }
    // constraintSize 替代固定高度：热区达标（≥40vp），大字体时随内容撑高
    .constraintSize({ minHeight: 40 })
    .padding({ left: 12, right: 8 })
    .accessibilityText(`排序，当前${sortLabel(this.sortMode)}`)
    .bindMenu(this.SortMenu())
  }

  /** 当前可见列表的滚动控制器（本地/在线二选一） */
  private activeScroller(): Scroller {
    return this.sourceTab === SourceTab.ONLINE ? this.onlineScroller : this.localScroller;
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
          // constraintSize 替代固定高度：热区达标，大字体不截断
          .constraintSize({ minHeight: 40 })
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
        Text('在线曲库还没有内容')
          .fontSize(15)
          .fontColor($r('app.color.ink_soft'))
        Text('稍后再来看看，也可以下拉重试')
          .fontSize(12)
          .fontColor($r('app.color.ink_faint'))
        Button('重试')
          // constraintSize 替代固定高度：热区达标，大字体不截断
          .constraintSize({ minHeight: 40 })
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

  /** 长按歌曲菜单（歌曲操作的唯一入口，左滑已移除——每操作一条路径）：
   * 原生 Menu/MenuItem，磨砂底/圆角/行高/按压态由系统托管 */
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
          .constraintSize({ minHeight: 42 })
          .fontSize(15)
          .borderRadius(21)
          .backgroundColor($r('app.color.ink'))
          .fontColor($r('app.color.paper'))
          .onClick(() => this.importFromPicker())
        Button('载入演示曲目')
          .constraintSize({ minHeight: 42 })
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
    // 空态按钮落在拇指区：不再上推 60vp
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

  /** 切换曲目来源：本地回读曲库，在线重新拉取（重复点击在线等同刷新）；
   * 搜索词保留——切源不丢查询，切在线时直接按词搜 */
  private switchSource(tab: SourceTab): void {
    if (this.sourceTab === tab && tab === SourceTab.LOCAL) {
      return;
    }
    this.sourceTab = tab;
    this.showBackTop = false;
    this.cancelPendingSearch();
    if (tab === SourceTab.ONLINE) {
      this.enterOnline(this.searchText.trim());
    } else {
      appStore.player.refreshSongs();
    }
    this.activeScroller().scrollToIndex(0);
  }

  /** 迷你条弧线手势：顶层源循环切换（> 下一个 / < 上一个，两源即往返） */
  private cycleSource(direction: number): void {
    const next = direction > 0 ? SourceTab.ONLINE : SourceTab.LOCAL;
    if (next !== this.sourceTab) {
      this.switchSource(next);
      promptAction.showToast({
        message: next === SourceTab.ONLINE ? '已切换到在线' : '已切换到本地',
        duration: 1200
      });
    }
  }

  /** 迷你条横滑手势：本地分类标签循环（> 下一个 / < 上一个，越界回绕）。
   * 仅本地源响应——在线页无分类标签行；目标为当前分类时不动作 */
  private cycleTab(direction: number): void {
    if (this.sourceTab !== SourceTab.LOCAL) {
      return;
    }
    const order: LibraryTab[] = [LibraryTab.ALL, LibraryTab.FAVORITES, LibraryTab.RECENT];
    const idx = order.indexOf(this.tab);
    const next = order[(idx + direction + order.length) % order.length];
    if (next !== this.tab) {
      this.tab = next;
      this.showBackTop = false;
      this.localScroller.scrollToIndex(0);
      const label = next === LibraryTab.ALL ? '全部' : (next === LibraryTab.FAVORITES ? '喜欢' : '最近');
      promptAction.showToast({ message: label, duration: 1000 });
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
