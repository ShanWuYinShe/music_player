import displaySync from '@ohos.graphics.displaySync';
import { dayPhaseOverlay } from '../common/InkMood';
import { picker } from '@kit.CoreFileKit';
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { appStore } from '../viewmodel/AppStore';
import { SongRecord } from '../model/Song';
import { LibraryTab, SortMode, FilterOptions, filterAndSort, sortLabel } from '../common/LibraryFilter';
import { ReloadDataSource } from '../common/ReloadDataSource';
import { isOnlineId } from '../source/OnlineApi';
import { SongItem } from '../components/SongItem';
import { MiniPlayerBar, MiniInfo } from '../components/MiniPlayerBar';
import { PlayerPage } from './PlayerPage';
import { SettingsPage } from './SettingsPage';

/** 金色 accent 文件级常量：@Builder 内引用组件字段需 this 前缀，常量直引更净 */
const CURRENT_TINT: Resource = $r('app.color.accent');

/**
 * 首页一级签：曲库（本地全部）/ 喜欢 / 最近（两者跨源：本地+在线混排）
 * / 在线（服务端曲库+网络源）。喜欢/最近升为一级入口——收藏不区分在线
 * 离线后它们是跨源视图，不再挂在本地签下当筛选器（2026-09 用户决策）
 */
enum HomeTab {
  LIBRARY = 0,
  FAVORITES = 1,
  RECENT = 2,
  ONLINE = 3
}

/** 在线搜索防抖：输入停顿该时长后触发服务端搜索（毫秒） */
const SEARCH_DEBOUNCE_MS = 600;
/** 在线清空小防抖：清除键连点 150ms 后直发全量（毫秒） */
const CLEAR_DEBOUNCE_MS = 150;
/** 本地搜索微防抖：击键停顿该时长后触发过滤重算（毫秒） */
const LOCAL_DEBOUNCE_MS = 120;

/**
 * 主页面：源切换（本地/在线）+ 搜索/分类/排序 + 歌曲列表 + 迷你播放条，
 * Navigation 承载播放页与设置页。
 */
@Entry
@ComponentV2
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @Local searchText: string = '';
  /** 曲库排序方式：初始值来自持久化偏好，变更即落盘（重启恢复） */
  @Local sortMode: SortMode = appStore.userData.sortMode;
  @Local scanning: boolean = false;
  /** 当前一级签（受控 Tabs index；滑动切页经 onChange 回写同一状态） */
  @Local homeTab: HomeTab = HomeTab.LIBRARY;
  @Local onlineLoading: boolean = false;
  /** 在线拉取失败提示（有旧列表时仍展示旧列表） */
  @Local onlineError: string = '';
  /** 在线列表唯一展示数据源：最近一次成功拉取的结果。播放队列
   * (player.songs) 在拉取返回前仍是本地曲库，展示层直读会让在线 tab
   * 在加载期间闪现本地曲目（逻辑错误）；拉取失败时保留旧值兜底 */
  @Local onlineSongs: SongRecord[] = [];
  /** 在线搜索防抖定时器 id（-1 无待触发任务） */
  private searchTimerId: number = -1;
  /** 在线清空小防抖 id：清除键连点不堆连接（600ms 主防抖不动） */
  private clearTimerId: number = -1;
  /** 本地搜索微防抖 id：击键 120ms 后同步过滤词（O(n) 双遍不同时刷） */
  private localTimerId: number = -1;
  /** 本地过滤词（微防抖后同步 searchText，击键不直接触发全量重算） */
  @Local debouncedQuery: string = '';
  /** 网易云登录态 @Local 镜像：VIP 徽标淡化用（enterOnline 等 providers 后同步） */
  @Local loggedIn: boolean = false;
  /** 在线列表下拉刷新态（Refresh 组件绑定） */
  @Local isRefreshing: boolean = false;
  /** 在线请求代际号：新查询使旧响应作废（latest-wins，慢网下不再丢新查询） */
  private onlineRequestId: number = 0;
  /** LazyForEach 数据源 */
  private songSource: ReloadDataSource<SongRecord> =
    new ReloadDataSource<SongRecord>((song: SongRecord) => song.id);
  /** 最近签冻结快照：进签时按当时 MRU 顺序冻结，会话内切歌不再重排显示。
   * 最近列表按播放时间倒序，每次切歌 addRecent 都会把它顶到最前——若显示层
   * 直读 live recentIds，切一次歌整表重排一次，播放队列（点播瞬间快照）立刻
   * 与屏幕对不上，第二次左滑右滑就乱跳（真机报障）。冻结后队列、迷你条、
   * 播放页 pager、锁屏走同一快照，全部一致；MRU 真值仍经 addRecent 持久化，
   * 下次进签重新冻结即最新。离签/导入/删歌时置空回 live。 */
  @Local recentFrozen: SongRecord[] | null = null;
  /** 列表滚动控制器：四个一级签各持一个（Scroller 不可绑定多个滚动组件） */
  private localScroller: Scroller = new Scroller();
  private favScroller: Scroller = new Scroller();
  private recentScroller: Scroller = new Scroller();
  private onlineScroller: Scroller = new Scroller();
  /** 远离顶部时在拇指区露出回顶按钮（onScrollIndex 驱动） */
  @Local showBackTop: boolean = false;
  /** 卷首双层漂移位（vp，displaySync 帧驱动正弦往复）：远层 96s/近层 64s
   * 周期、相位错开成视差。属性动画 .animation() 对该结构实测不生效
   * （连拍零位移），改用迷你条进度线同款帧驱动，12Hz 足够顺滑 */
  @Local driftFar: number = 0;
  @Local driftNear: number = 0;
  private driftSync: displaySync.DisplaySync | null = null;
  private driftFrameCb: () => void = () => this.tickDrift();
  private driftT0 = 0;
  /** 卷首视差：列表下滚时卷首以慢速跟随上移（展卷感），帧循环里读滚动偏移 */
  @Local parallaxFar: number = 0;
  @Local parallaxNear: number = 0;

  /** 播放镜像：真机上 player(@ObservedV2) 的 @Trace/@Computed 对 if 分支与
   * 属性插值均不触发 UI 更新（仅 Text 内容插值存活，已实测），改由
   * onStateChanged 显式回调驱动 @Local（@Local 的 if 分支可靠） */
  @Local mini: MiniInfo | null = null;
  private stateListener: (reason: string) => void = (_reason: string): void => {
  };

  aboutToAppear(): void {
    this.songSource.reload(this.filteredSongs);
    // 卷首漂移帧循环（随页面可见性启停，见底部 onVisibleAreaChange 绑定）
    this.driftSync = displaySync.create();
    this.driftSync.setExpectedFrameRateRange({ min: 0, max: 12, expected: 12 });
    this.driftSync.on('frame', this.driftFrameCb);
    this.driftSync.start();

    // 播放失败（在线无版权/网络中断等）统一 toast 反馈，由 PlayerController 回调
    appStore.player.onPlaybackError = (message: string): void => {
      promptAction.showToast({ message: message, duration: 2500 });
    };
    // 播放状态镜像：切歌/启停时刷新 mini bar 并重建列表当前行。
    // 上轮提交此处接线丢失（文本替换静默失败），导致 mini bar 永不出现——已回踩
    this.stateListener = (reason: string): void => {
      const song = appStore.player.currentSong;
      this.mini = song === null ? null : {
        seedId: song.id,
        title: song.title,
        artist: song.artist,
        coverPath: song.coverPath,
        isPlaying: appStore.player.isPlaying
      };
      // 当前播放行(高亮/EQ)在 LazyForEach 项内不随状态刷新，需主动通知：
      //   reason='playing' → 只有启停变化，精确刷新当前行（EQ 跳动/暂停态），
      //                      避免大曲库下每次播放/暂停全列表重建
      //   reason='song'    → 切歌，旧行与新行当前态都要刷，走整表 reload
      //   reason='prefs'   → 音量/模式/定时，不涉及行状态，跳过
      // 其余（曲库变更等）同样整表 reload
      if (reason === 'playing') {
        const id = appStore.player.currentSongId;
        if (id !== '') {
          this.songSource.notifyChanged(id);
        }
      } else if (reason !== 'prefs') {
        this.songSource.reload(this.filteredSongs);
      }
    };
    appStore.player.addStateListener(this.stateListener);
    // 冷启动恢复的播放态发生在本组件挂载前(init 早于 aboutToAppear)，补一次同步
    this.stateListener('song');
  }

  aboutToDisappear(): void {
    // 根页面常驻导航栈底，状态订阅不摘（摘了若不再触发 aboutToAppear 会断
    // mini 更新）；只清短时防抖定时器与漂移帧循环
    if (this.driftSync !== null) {
      this.driftSync.off('frame', this.driftFrameCb);
      this.driftSync.stop();
      this.driftSync = null;
    }
    this.cancelPendingSearch();
    this.cancelClearSearch();
    this.cancelLocalFilter();
  }

  /** 当前签与搜索词过滤后的列表（缓存计算，build 内多处引用只算一次）。
   * 在线签展示 onlineSongs（最近一次成功结果，q 已在服务端匹配并聚合
   * 网络源），不再本地二次过滤，避免网络源结果被本地标题匹配误滤掉，
   * 也不直读 player.songs——它是播放队列，加载期间还是本地曲库。
   * 内容签读微防抖后的 debouncedQuery：击键不同时触发全量 filter+sort */
  @Computed
  get filteredSongs(): SongRecord[] {
    if (this.homeTab === HomeTab.ONLINE) {
      return this.onlineSongs;
    }
    if (this.homeTab === HomeTab.RECENT && this.recentFrozen !== null) {
      // 最近冻结会话：以进签快照为底，只做搜索过滤+排序，不再跟随 live
      // recentIds（切歌 addRecent 会持续改写它，跟随即每次整表重排）。
      // tab 取 ALL 绕开 LibraryFilter 的 MRU 重建，保留快照顺序；sort 强制
      // DEFAULT——最近=播放时间序，不随曲库的排序选择漂移（用户决策 2026-09）
      const frozen: SongRecord[] = this.recentFrozen;
      const snapOpts: FilterOptions = {
        query: this.debouncedQuery,
        tab: LibraryTab.ALL,
        sort: SortMode.DEFAULT,
        favoriteIds: appStore.userData.favoriteIds,
        recentIds: appStore.userData.recentIds,
        onlineSongs: appStore.onlineStore.all()
      };
      return filterAndSort(frozen, snapOpts);
    }
    const opts: FilterOptions = {
      query: this.debouncedQuery,
      tab: this.filterTab(),
      sort: this.sortMode,
      favoriteIds: appStore.userData.favoriteIds,
      recentIds: appStore.userData.recentIds,
      // 喜欢/最近的在线歌经注册表补位与本地歌混排。注册表本身非响应式，
      // 但收藏/播放在线歌的动作都先改写 favoriteIds/recentIds（@Trace），
      // 本 @Computed 随之重算，届时读到的注册表已是最新
      onlineSongs: appStore.onlineStore.all()
    };
    return filterAndSort(appStore.player.songs, opts);
  }

  /** 一级签 → 筛选语义：曲库=全部本地，喜欢/最近同名映射（跨源补位在
   * LibraryFilter 内完成） */
  private filterTab(): LibraryTab {
    if (this.homeTab === HomeTab.FAVORITES) {
      return LibraryTab.FAVORITES;
    }
    if (this.homeTab === HomeTab.RECENT) {
      return LibraryTab.RECENT;
    }
    return LibraryTab.ALL;
  }

  @Monitor('filteredSongs')
  onFilteredSongsChange(): void {
    this.songSource.reload(this.filteredSongs);
  }

  build() {
    Navigation(this.pathStack) {
      // alignContent=Bottom：悬停收起 pill 叠在底部中央（满幅子层不受影响）
      Stack({ alignContent: Alignment.Bottom }) {
        // 全屏背景层：延伸至状态栏与导航条下方，消除顶部/底部割裂。
        // 墨晕宣纸全屏底（晕染洇痕+旧纸晕角，深浅板各一张）+ 卷首水墨长卷
        // （低伏远山，上部雾区留白承载状态栏与源切换行），均不拦截触摸；
        // 播放中再叠当前曲封面的模糊氛围层（低透明度）
        Stack({ alignContent: Alignment.Top }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.page_bg'))
          Image($r('app.media.paper_tex'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .hitTestBehavior(HitTestMode.None)
          // 卷首双层山水：远/近两层以不同周期极慢往复漂移（渲染管线
          // 属性动画，UI 线程零每帧工作），云雾流动的手卷感。图幅加大
          // 并负偏移，为往复平移留余量不露边
          Image($r('app.media.scroll_far'))
            .width('114%')
            .height(122)
            .objectFit(ImageFit.Cover)
            .position({ x: '-7%', y: 0 })
            .translate({ x: this.driftFar, y: this.parallaxFar })
            .hitTestBehavior(HitTestMode.None)
          Image($r('app.media.scroll_near'))
            .width('114%')
            .height(115)
            .objectFit(ImageFit.Cover)
            .position({ x: '-7%', y: 0 })
            .translate({ x: this.driftNear, y: this.parallaxNear })
            .hitTestBehavior(HitTestMode.None)
          // 时辰晨昏罩色：晨青/昼无/昏赭/夜黛，约一成浓度染纸（见 InkMood）
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(dayPhaseOverlay())
            .hitTestBehavior(HitTestMode.None)
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
        .onVisibleAreaChange([0.0, 1.0],
          (_isExpanding: boolean, ratio: number): void => this.applyDriftVisible(ratio))

        Column() {
        // 一级签（曲库/喜欢/最近/在线）+ 页面级操作：点选走 switchTab 改
        // 受控 index，列表区滑动由 Tabs onChange 回写同一入口；导入/设置
        // 居右（原 Navigation menus 迁入——标题栏已整条去除）
        Row({ space: 2 }) {
          this.HomeTabChip(HomeTab.LIBRARY, '曲库')
          this.HomeTabChip(HomeTab.FAVORITES, '喜欢')
          this.HomeTabChip(HomeTab.RECENT, '最近')
          this.HomeTabChip(HomeTab.ONLINE, '在线')
          Blank()
          if (this.homeTab === HomeTab.LIBRARY) {
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
        .padding({ left: 12, right: 8, top: appStore.safeTopVp + 8, bottom: 2 })

        // 系统搜索框（清除键/键盘搜索键由系统托管，深浅自动适配）：
        // 输入语义随签——内容签即时过滤（在喜欢/最近内搜索即筛其子集），
        // 在线防抖服务端搜；暖纸底+小圆角融入排印版面
        Row() {
          Search({
            value: this.searchText,
            placeholder: this.homeTab === HomeTab.ONLINE ? '搜索歌曲、歌手、网络曲库' : '搜索歌曲、歌手',
          })
            .id('home_search')
            .layoutWeight(1)
            .constraintSize({ minHeight: 40 })
            .fontColor($r('app.color.ink'))
            .placeholderColor($r('app.color.ink_faint'))
            .backgroundColor($r('app.color.surface_alt'))
            .borderRadius(12)
            .onChange((value: string) => {
              const prev = this.searchText;
              this.searchText = value;
              if (this.homeTab === HomeTab.ONLINE) {
                // 在线搜索由服务端完成（含网络源聚合），输入停顿后触发；
                // 框内清除键清空走 150ms 小防抖回到服务器曲库全量（连点清空
                // 不堆连接，在途旧查询由 OnlineSource abort）
                if (value === '' && prev !== '') {
                  this.cancelPendingSearch();
                  this.cancelClearSearch();
                  this.clearTimerId = setTimeout(() => {
                    this.clearTimerId = -1;
                    this.enterOnline('');
                  }, CLEAR_DEBOUNCE_MS);
                } else {
                  this.cancelClearSearch();
                  this.scheduleOnlineSearch();
                }
                return;
              }
              // 内容签即时过滤，不跳签——在喜欢/最近里搜索就是筛其子集，
              // 找不到时空态如实呈现（跨源签里搜不到比误跳曲库更诚实）
              this.scheduleLocalFilter();
            })
            .onSubmit((value: string) => {
              // 键盘搜索键：在线立即触发一次（不等防抖），本地已是微防抖过滤
              if (this.homeTab === HomeTab.ONLINE) {
                this.cancelPendingSearch();
                this.cancelClearSearch();
                this.enterOnline(value.trim());
              } else {
                this.cancelLocalFilter();
                this.debouncedQuery = value;
              }
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 2 })

        // 列表头（章节题注）：左侧「N 首」计数，右侧排序入口（内容签语义，
        // 在线列表为服务端顺序无排序）
        Row() {
          Text(this.headerCountText())
            .fontSize(12)
            .fontColor($r('app.color.editorial_meta'))
            .letterSpacing(0.5)
          Blank()
          // 最近签无排序入口：最近=播放时间倒序（MRU），排序选择会破坏
          // 语义（用户决策 2026-09）；曲库/喜欢保留
          if (this.homeTab === HomeTab.LIBRARY || this.homeTab === HomeTab.FAVORITES) {
            this.SortButton()
          }
        }
        .width('100%')
        .padding({ left: 20, right: 8, top: 4, bottom: 2 })

        // 列表区（Stack 让回顶按钮悬浮其上——旧版按钮插在 Column 布局流
        // 内，一出现就挤占 layoutWeight 列表视口、整列表跳缩一截）：
        // TabContent 不带 tabBar（系统栏定高 91vp 且两项左右散开，不符合
        // 分段控件观感），切换条用自绘排印签行（点选经 switchTab 改受控
        // index；滑动经 onChange 回写）
        Stack({ alignContent: Alignment.BottomEnd }) {
          Tabs({ barPosition: BarPosition.Start, index: this.homeTab }) {
            TabContent() {
              this.ContentTabBody(this.localScroller)
            }

            TabContent() {
              this.ContentTabBody(this.favScroller)
            }

            TabContent() {
              this.ContentTabBody(this.recentScroller)
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
                  this.enterOnline(this.searchText.trim(), true).finally(() => {
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
          .width('100%')
          .height('100%')
          .onChange((index: number) => {
            if (index !== this.homeTab) {
              this.switchTab(index as HomeTab);
            }
          })

          // 底部回顶（FAB 悬浮）：远离顶部时才出现在列表右下角，回到顶部
          // 自动收起；悬浮不参与布局流，出现/消失不再改变列表视口高度
          if (this.showBackTop) {
            this.BottomToolbar()
          }
        }
        .layoutWeight(1)
        .width('100%')

        // 底部迷你播放条（常驻：无播放曲目时显示占位态，不再随曲目显隐
        // 造成 UI 跳动——用户决策）。其内容经 @Local 镜像（见 mini 字段注释）；
        // 其上的手势 = 半屏拇指遥控：平直横滑切歌（最高频）/ 画 <> 换签。
        // 占位态点按不开空播放页，改聚焦搜索直接选歌（真机走查）
        MiniPlayerBar({
          player: appStore.player,
          info: this.mini,
          bottomInset: appStore.safeBottomVp,
          onTapOpen: () => this.onMiniBarTap(),
          onSwipeTab: (direction: number) => this.cycleTab(direction),
          onSwipeTrack: (direction: number) => this.swipeTrack(direction)
        })
        }
        .width('100%')
        .height('100%')
        // 顶部避让已并入一级签行 padding（safeTopVp+8）；迷你条为 Column
        // 内普通兄弟节点（不叠压列表），自带 bottomInset 直贴屏幕物理底
        // （磨砂延伸进安全区），列表视口到迷你条上缘为止、不再额外预留
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
              loggedIn: this.loggedIn,
              onItemClick: (id: string) => this.playFromList(id)
            })
              .bindContextMenu(this.SongMenu(song), ResponseType.LongPress)
            // 笔意线：目录行的分隔语言（最后一行由列表底部自然收尾，不画）。
            // 左实右渐隐——起笔重收笔轻，像一笔掠过的墨线；左端对齐歌名
            // 起排处（行内边距16 + 竖线3 + 间距12 + 封面44 + 间距12 = 87）
            Row()
              .height(0.5)
              .margin({ left: 87 })
              .linearGradient({
                angle: 90,
                colors: [
                  [$r('app.color.editorial_rule'), 0],
                  [$r('app.color.editorial_rule'), 0.55],
                  [Color.Transparent, 1]
                ]
              })
          }
        }
      }, (song: SongRecord) => song.id)
    }
    .cachedCount(6)
    .width('100%')
    // TabContent 非线性布局：layoutWeight 失效致列表按内容高居中、
    // 上方留白，必须足高
    .height('100%')
    // 水平不留容器 padding（行组件自带内边距，双层叠加曾让每行两侧
    // 白让 ~30vp）。底部只留 12vp 收尾呼吸——迷你条是 Column 内的普通
    // 兄弟节点（不叠压列表），ArkUI 的 List padding 会收缩视口而非
    // 抬高滚动内容：旧版按「迷你条悬浮」预留的 底部 padding 曾让视口
    // 底部每屏空出 ~迷你条高度（真机反馈列表到迷你条之间大片留白）
    .padding({ bottom: 12 })
    .scrollBar(BarState.Auto)
    .onScrollIndex((start: number) => {
      // 滚过约一屏半才在拇指区露出回顶按钮（阈值太小稍滚即出，抢底部拇指区），
      // 回到顶部自动收起
      this.showBackTop = start > 8;
    })
  }

  /** 列表头计数文案：在线首次加载未出结果时显示加载中，避免「0 首」闪现 */
  private headerCountText(): string {
    if (this.homeTab === HomeTab.ONLINE && this.onlineLoading && this.filteredSongs.length === 0) {
      return '正在加载';
    }
    return `${this.filteredSongs.length} 首`;
  }

  /**
   * 一级签（排印章节风）：纯文字标签，选中金粗 + 下方书脊短金线，无底色
   * 无图标——章节索引的杂志目录语言。选中加粗宽度微涨由同行 space 吸收
   */
  @Builder
  HomeTabChip(tab: HomeTab, label: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(17)
        .fontColor(this.homeTab === tab ? CURRENT_TINT : $r('app.color.editorial_meta'))
        .fontWeight(this.homeTab === tab ? FontWeight.Bold : FontWeight.Normal)
        .letterSpacing(this.homeTab === tab ? 1 : 0.5)
      // 选中项下方书脊短金线
      Row()
        .width(26)
        .height(2.5)
        .borderRadius(1.25)
        .backgroundColor(this.homeTab === tab ? CURRENT_TINT : Color.Transparent)
    }
    // 上下 padding 补足 40vp 触控热区
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .accessibilityText(`切换到${label}`)
    .onClick(() => this.switchTab(tab))
  }

  /** 内容签主体（曲库/喜欢/最近共用）：非空出列表；空态分流——搜索无结果 /
   * 曲库空（导入引导）/ 喜欢与最近各自的空态提示 */
  @Builder
  ContentTabBody(scroller: Scroller) {
    if (this.filteredSongs.length === 0) {
      if (this.searchText.trim() !== '') {
        this.NoResultView()
      } else if (this.homeTab === HomeTab.LIBRARY && appStore.player.songs.length === 0) {
        this.LibraryEmptyView()
      } else if (this.homeTab === HomeTab.FAVORITES) {
        this.EmptyHintView($r('sys.symbol.heart'), '还没有喜欢的歌曲',
          '在播放页点 ♥，喜欢的本地与在线歌都会收进来')
      } else if (this.homeTab === HomeTab.RECENT) {
        this.EmptyHintView($r('sys.symbol.clock'), '还没有播放记录', '点一首歌开始听吧')
      }
    } else {
      this.SongList(scroller)
    }
  }

  /** 底部回顶按钮（FAB 悬浮于列表区右下角，不参与布局流）：18 + 上下
   * padding 22 = 40vp 热区；出现/消失不改变列表视口高度 */
  @Builder
  BottomToolbar() {
    SymbolGlyph($r('sys.symbol.arrow_up'))
      .fontSize(18)
      .fontColor([$r('app.color.on_accent')])
      .padding(11)
      .borderRadius(20)
      .backgroundColor($r('app.color.accent'))
      .shadow({ radius: 12, color: $r('app.color.floating_shadow'), offsetY: 2 })
      .margin({ right: 16, bottom: 14 })
      .accessibilityText('回到顶部')
      .onClick(() => {
        this.activeScroller().scrollToIndex(0, true);
      })
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

  /** 冻结最近快照：进最近签时按当前 MRU 顺序快照（与显示层 live 推导同源，
   * 含在线歌注册表补位）。快照后显示与队列都走它，切歌 addRecent 只改持久化
   * 真值不再重排屏幕——左滑右滑逐行走快照，与所见一致。sort 强制 DEFAULT：
   * 最近=播放时间倒序，无排序语义（用户决策 2026-09） */
  private freezeRecent(): void {
    const opts: FilterOptions = {
      query: this.debouncedQuery,
      tab: LibraryTab.RECENT,
      sort: SortMode.DEFAULT,
      favoriteIds: appStore.userData.favoriteIds,
      recentIds: appStore.userData.recentIds,
      onlineSongs: appStore.onlineStore.all()
    };
    this.recentFrozen = filterAndSort(appStore.player.songs, opts);
  }

  /** 列表点播：喜欢/最近两签先把队列替换为该签可见列表（跨源连播跟随
   * 所见；最近签可见列表即冻结快照，队列与屏幕同源，后续左滑右滑逐行
   * 一致）；曲库签不替换——队列即本地曲库整库（filterAndSort 的筛选源），
   * 搜索中点播若按结果替换队列，清空搜索后曲库会剩残集（真机推演）。
   * 两签的队列污染由切签时 refreshSongs 自愈（见 switchTab）；在线签
   * 队列已是服务端列表，直接播 */
  private playFromList(id: string): void {
    if (this.homeTab === HomeTab.FAVORITES || this.homeTab === HomeTab.RECENT) {
      appStore.player.setOnlineQueue(this.filteredSongs.slice());
    }
    appStore.player.playSong(id);
  }

  /** 当前可见列表的滚动控制器（四个一级签二选一取当前） */
  private activeScroller(): Scroller {
    if (this.homeTab === HomeTab.ONLINE) {
      return this.onlineScroller;
    }
    if (this.homeTab === HomeTab.FAVORITES) {
      return this.favScroller;
    }
    if (this.homeTab === HomeTab.RECENT) {
      return this.recentScroller;
    }
    return this.localScroller;
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
      this.StatusColumn($r('sys.symbol.exclamationmark_circle'), '在线曲库拉取失败',
        this.onlineError, true)
    } else if (this.searchText.trim() !== '') {
      this.NoResultView()
    } else {
      this.StatusColumn($r('sys.symbol.music_note_list'), '在线曲库还没有内容',
        '稍后再来看看，也可以下拉重试', true)
    }
  }

  /** 状态列（图标 + 标题 + 副标题 + 可选重试）：在线签错误/空库两态共用 */
  @Builder
  StatusColumn(icon: Resource, title: string, subtitle: string, showRetry: boolean) {
    Column({ space: 14 }) {
      SymbolGlyph(icon)
        .fontSize(40)
        .fontColor([$r('app.color.ink_faint')])
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.ink_soft'))
      Text(subtitle)
        .fontSize(12)
        .fontColor($r('app.color.ink_faint'))
      if (showRetry) {
        Button('重试')
          // constraintSize 替代固定高度：热区达标，大字体不截断
          .constraintSize({ minHeight: 40 })
          .fontSize(14)
          .borderRadius(19)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor($r('app.color.surface_alt'))
          .fontColor($r('app.color.ink'))
          .onClick(() => this.enterOnline(this.searchText.trim(), true))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
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
      if (!isOnlineId(song.id)) {
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
        action: () => {
          appStore.player.removeSong(song.id);
          // 曲库条目删除：最近快照可能含已删引用，置空回 live 重建
          this.recentFrozen = null;
        }
      }
    });
  }

  /** 曲库空态：导入 / 演示曲目 */
  @Builder
  LibraryEmptyView() {
    Column({ space: 20 }) {
      Column() {
        // 曲库空态主视觉：「乐」大字（水墨版式以字入画，不用系统音符图标）
        Text('乐')
          .fontSize(44)
          .fontColor($r('app.color.ink_faint'))
      }
      .width(96)
      .height(96)
      .borderRadius(48)
      .backgroundColor($r('app.color.surface_alt'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 6 }) {
        Text('曲库还是空的')
          .fontSize(17)
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
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.on_accent'))
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
    if (this.homeTab === HomeTab.ONLINE && appStore.consumeOnlineConfigDirty()) {
      this.enterOnline(this.searchText.trim(), true);
    }
  }

  /** 切换一级签：内容签（曲库/喜欢/最近）统一回读本地曲库队列——队列是
   * 内容签列表的筛选源（filterAndSort 入参），点播时才按可见列表替换
   * （见 playFromList），切签必须先自愈，否则上一签替换过的队列会让
   * 本签漏歌（真机实测：进喜欢后最近只剩收藏里的在线歌）；在线优先展示
   * 缓存（TTL 内不联网）。重复点击已选中的「在线」等同强制刷新。
   * 搜索词保留——切签不丢查询 */
  private switchTab(tab: HomeTab): void {
    if (this.homeTab === tab && tab === HomeTab.LIBRARY) {
      return;
    }
    // 重复点在线=强制刷新（缓存旁路，保留原「重复点击在线等同刷新」语义）
    const forceOnline = this.homeTab === tab && tab === HomeTab.ONLINE;
    this.homeTab = tab;
    this.showBackTop = false;
    this.cancelPendingSearch();
    this.cancelClearSearch();
    this.cancelLocalFilter();
    this.debouncedQuery = this.searchText;
    if (tab === HomeTab.ONLINE) {
      this.recentFrozen = null;
      this.enterOnline(this.searchText.trim(), forceOnline);
    } else {
      appStore.player.refreshSongs();
      if (tab === HomeTab.RECENT) {
        // 进最近即冻结：以当前 MRU 顺序快照，会话内显示与队列都走它
        this.freezeRecent();
        // 队列同拍对齐快照：横滑切歌不经过 playFromList（没点播直接滑），
        // 队列若仍是上面 refreshSongs 恢复的整库顺序，左滑右滑切到的歌与
        // 列表所见对不上（真机报障）。点播与横滑同源后，播放页 pager、
        // 锁屏、卡片走同一队列全部一致；离签 refreshSongs 已自愈
        const snap = this.recentFrozen;
        if (snap !== null && snap.length > 0) {
          appStore.player.setOnlineQueue(snap.slice());
        }
      } else {
        this.recentFrozen = null;
        if (tab === HomeTab.FAVORITES) {
          // 喜欢签同理：直接横滑（没点播）也沿收藏列表逐行——整库顺序的
          // 下一首未必是收藏，会滑到列表外的歌
          const fav = this.filteredSongs;
          if (fav.length > 0) {
            appStore.player.setOnlineQueue(fav.slice());
          }
        }
      }
    }
    this.activeScroller().scrollToIndex(0);
  }

  /** 迷你条点按：有曲目进播放页；占位态（未在播放）聚焦搜索框直接
   * 选歌——空播放页没有信息量（真机走查）。requestFocus 失败（罕见）
   * 静默，退化为无操作 */
  private onMiniBarTap(): void {
    if (this.mini !== null) {
      this.pathStack.pushPathByName('player', null);
      return;
    }
    this.getUIContext().getFocusController().requestFocus('home_search');
  }

  /** 迷你条折返手势（画 > / <）：一级签相邻切换——> 下一个 / < 上一个，
   * 四签循环、越界回绕。不弹 toast——结果由一级签高亮直接可见 */
  private cycleTab(direction: number): void {
    const order: HomeTab[] = [HomeTab.LIBRARY, HomeTab.FAVORITES, HomeTab.RECENT, HomeTab.ONLINE];
    const idx = order.indexOf(this.homeTab);
    const next = order[(idx + direction + order.length) % order.length];
    if (next !== this.homeTab) {
      this.switchTab(next);
    }
  }

  /** 迷你条平直横滑（最高频手势留给播放控制，2026-09 用户决策）：
   * 左滑 = 下一首、右滑 = 上一首，与播放页纸带 pager 同向（内容跟手，
   * 下一首在右）。方向参数：-1 = 左滑，+1 = 右滑 */
  private swipeTrack(direction: number): void {
    if (direction < 0) {
      appStore.player.next();
    } else {
      appStore.player.previous();
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

  /** 清空小防抖取消（切源/新输入/提交时调用） */
  private cancelClearSearch(): void {
    if (this.clearTimerId >= 0) {
      clearTimeout(this.clearTimerId);
      this.clearTimerId = -1;
    }
  }

  /** 本地微防抖：120ms 后把 searchText 同步给 debouncedQuery 触发过滤 */
  private scheduleLocalFilter(): void {
    this.cancelLocalFilter();
    this.localTimerId = setTimeout(() => {
      this.localTimerId = -1;
      this.debouncedQuery = this.searchText;
    }, LOCAL_DEBOUNCE_MS);
  }

  private cancelLocalFilter(): void {
    if (this.localTimerId >= 0) {
      clearTimeout(this.localTimerId);
      this.localTimerId = -1;
    }
  }

  /** 每帧：双层正弦漂移（远 96s / 近 64s 一个来回，相位差 1/3 周期成视差）
   * + 卷首随列表滚动的慢速跟随（远层 22% / 近层 36% 速，约一屏后到顶） */
  private tickDrift(): void {
    if (this.driftT0 === 0) {
      this.driftT0 = Date.now();
    }
    const t = (Date.now() - this.driftT0) / 1000;
    this.driftFar = Math.sin(t * 2 * Math.PI / 96) * 9;
    this.driftNear = Math.sin(t * 2 * Math.PI / 64 + Math.PI / 3) * 9;
    // scroller 未挂载（首帧前）时 currentOffset 返回 undefined，判空兜底
    const offsetResult = this.activeScroller().currentOffset();
    const y = offsetResult === undefined ? 0 : offsetResult.yOffset;
    const off = Math.min(Math.max(y, 0), 380);
    this.parallaxFar = -off * 0.22;
    this.parallaxNear = -off * 0.36;
  }

  /** 漂移帧循环随页面可见性启停（被播放页盖住时不推进）；方法名避开
   * 组件内置 onVisibleAreaChange（重名与基类签名冲突会编译报错，已踩坑） */
  private applyDriftVisible(ratio: number): void {
    if (this.driftSync === null) {
      return;
    }
    if (ratio > 0) {
      this.driftT0 = 0;
      this.driftSync.start();
    } else {
      this.driftSync.stop();
    }
  }

  /** 进入在线源：按关键词拉取曲目（空=曲库全量），成功后更新展示列表
   * (onlineSongs) 并替换播放队列；失败时保留旧列表并提示。
   * 缓存秒开：命中列表缓存立即展示（TTL 内不发网络；过期则旧列表保持
   * 可见 + 静默刷新，不置 loading），来回切源/杀进程重开不再整页重拉；
   * force=true（重复点在线标签/重试/改服务地址）绕过缓存强制拉取。
   * latest-wins：在途请求期间的新查询立即发出，旧响应按代际号作废丢弃；
   * 在途旧查询由 OnlineSource abort，不占连接 */
  private async enterOnline(query: string, force: boolean = false): Promise<void> {
    const reqId = ++this.onlineRequestId;
    this.onlineLoading = false;
    this.onlineError = '';
    const cached = force ? null : appStore.onlineSource.peekCache(query);
    if (cached !== null) {
      this.onlineSongs = cached.songs;
      this.loggedIn = appStore.neteaseLoggedIn;
      appStore.player.setOnlineQueue(cached.songs);
      if (cached.fresh) {
        // 登录态不阻塞展示（下一首真正起播由 isOnlineCacheable 实时读取
        // appStore.neteaseLoggedIn）：fire-and-forget，回来仅更新提示
        appStore.refreshOnlineProviders().then(() => {
          if (reqId === this.onlineRequestId) {
            this.loggedIn = appStore.neteaseLoggedIn;
          }
        }).catch(() => {
        });
        return;
      }
    } else {
      this.onlineLoading = true;
    }
    // 先等登录态（本地 /providers 一次短 RTT）：VIP 完整曲的 prefetch 判定
    // 依赖它；fire-and-forget 会让首批曲目在登录态晚到时误判试听跳过缓存
    try {
      await appStore.refreshOnlineProviders();
    } catch (err) {
    }
    if (reqId !== this.onlineRequestId) {
      return; // 等待期间被新查询取代
    }
    this.loggedIn = appStore.neteaseLoggedIn;
    try {
      const list = await appStore.onlineSource.fetchSongs(query);
      if (reqId !== this.onlineRequestId) {
        return; // 已有更新的查询在途，过期响应丢弃
      }
      if (this.homeTab !== HomeTab.ONLINE) {
        return; // 已切走：晚到的响应不得替换 player.songs 污染内容签列表
        // （切回在线时 switchTab 会重新拉取）
      }
      this.onlineSongs = list;
      appStore.player.setOnlineQueue(list);
    } catch (err) {
      if (reqId !== this.onlineRequestId || this.homeTab !== HomeTab.ONLINE) {
        return;
      }
      this.onlineError = `连接失败：${err instanceof Error ? err.message : '未知错误'}`;
      if (this.onlineSongs.length > 0) {
        // 拉取失败但有旧缓存：队列本就是旧列表，无需重复 setOnlineQueue，
        // 只提示继续用旧列表
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
        this.recentFrozen = null; // 曲库新增：最近快照失效回 live
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
        // 选择器单次上限 100：选满即可能截断，提示分批
        if (uris.length >= 100) {
          message += '（单次最多 100 首，剩余请分批导入）';
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
      this.recentFrozen = null; // 曲库新增：最近快照失效回 live
      promptAction.showToast({
        message: added > 0 ? `已载入 ${added} 首演示曲目` : '演示曲目已加载过'
      });
    } finally {
      this.scanning = false;
    }
  }
}
