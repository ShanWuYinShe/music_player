---
name: music-app-platform-ui
description: music_app 平台架构与 UI 规范：AVPlayer 状态机、AVSession 元数据规则、API 24 移除项与导入坑、V2 状态管理红线与真机渲染大坑、本项目 UI 细则、播放页舞台双态与手势、在线源 SWR 缓存、双主题与原生菜单约定。触发：改 music_app 的 ArkTS 页面或组件；动播放内核/媒体会话；改主题与颜色资源；改播放页手势或舞台；改在线源与缓存；排查真机渲染不更新/白屏。
---

# music_app 平台架构与 UI 规范

- **bindSheet 三个不受控项（2026-10-15 恒暗化实测）**：① `showClose` **默认值即 true**，想隐藏必须显式 `showClose: false`——省略选项后系统钮与自绘关闭钮同屏重叠（真机抓拍双 × ）；② 系统 `title` 的字色随**系统深浅模式**走、不受 `backgroundColor` 控制，恒暗 sheet 上浅色系统会出深字压深底——恒暗 sheet 一律去 title 自绘标题行；③ 系统 showClose 钮位置固定右上，与自绘标题行不同轴。项目内两个 sheet（队列/分享）已按「viz_card_bg 底 + 自绘标题行 + 自绘 xmark（40vp 热区）」统一处理，新增 sheet 沿用该模式

- 零第三方运行时依赖（仅 devDependencies `@ohos/hypium` 测试框架），全部使用系统能力
- `compatibleSdkVersion`/`targetSdkVersion` 为 `6.0.0(20)`，`modelVersion` 6.0.2（oh-package.json5 与 hvigor-config.json5）；本机 SDK 为 HarmonyOS 26.0.0（API 26）；bundleName `com.lsyb.musicplayer`（自动签名由华为账号绑定前缀决定）
- **脚本/agent 环境调用构建工具链必须补全 env**（2026-10-15 实测）：DSH run_code 进程 `HOME` 为 undefined、`PATH` 缺 `/usr/bin:/bin:/usr/sbin:/sbin`（`sed`/`dirname` 等 ENOENT，表象是 ohpm/hvigorw 莫名 exit 126/127）——spawn 时显式传 `HOME=/Users/<user>`、`PATH` 前缀 `/Applications/DevEco-Studio.app/Contents/tools/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`，hvigor 另需 `JAVA_HOME`+`DEVECO_SDK_HOME`（见 music_app/AGENTS.md「本地命令」）
- **`module.json5` 必须含 `"pages": "$profile:main_pages"`**：缺失时构建不报错，但编译产物 module.json 无路由表，运行时 `loadContent` 返回 401 白屏（已踩坑）
- 播放内核 `AVPlayer`（每次切歌重建实例，靠代际号 `generation` 废弃旧实例回调）：
  - **状态迁移是异步事件**——`url` 赋值后须在 `on('stateChange')` 收到 `initialized` 才能调 `prepare()`，收到 `prepared` 才能调 `play()`；同步连调会 5400102
  - 本地文件用 `player.url = 'fd://<fd>'`（`fs.openSync` 的 fd，播放期间保持打开，release 时关闭）；`file://` 路径不支持；**在线曲目 `player.url` 直接赋 http(s) 流地址**（`fileName` 以 http 开头即网络分支，`module.json5` 需声明 `ohos.permission.INTERNET`，网络请求用 `@ohos.net.http`）
- 媒体会话 `@ohos.multimedia.avsession`：**命令监听必须逐个注册**（`on('play')`/`on('pause')`…，无统一 `'command'` 事件）；`PlaybackPosition` 字段为 `elapsedTime`+`updateTime`；**AVMetadata 可选字段必须整键省略**（真机 API 24 实测：键存在但值为 `undefined` 时系统 NAPI 按「键存在即校验类型」拒绝整条元数据，`setAVMetadata` 返回 401——元数据缺失则进不了系统有效会话列表，实况窗不显示、耳机按键路由到其他应用，`SessionController.updateMetadata` 已按此构造）；播放失败路径须回写会话暂停态，长驻任务在系统焦点打断后会被自行取消、每次 `playing` 都要实际重新申请（不能信内存标志）
- API 24 已移除 `READ_MEDIA_AUDIO` 权限、`AVMetadataHelper`、`fileAccess`：本地音乐只能走 `AudioViewPicker` 导入（选项字段为 `maxSelectNumber`，非 maxNumber）；mp3 元数据由 `library/Id3Parser.ets` 自解析（ID3v2.3/2.4）；时长由 AVPlayer prepared 后回填；**导入 URI 两坑**（已在 MusicLibrary 防御）：① AudioViewPicker 对 Download 等目录返回 percent-encoded URI（`file://docs/.../%E5%91%A8...mp3`），`fs.statSync` 可读而 `fs.copyFile` 按字面解析报 13900002——须 decodeURIComponent 双形态尝试；② `fs.copyFile` 对 `file://docs/` 来源整体不支持（stat 可过、copy 恒 ENOENT），回退 `openSync`+分块 read/write 拷贝；导入 toast 按 added/dup/failed 分类提示，added=0 不再误报"已在曲库"
- 音乐可视化：平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页为 **shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关）。源码规范、场景注册、性能架构、帧驱动与真机踩坑见下方「音乐可视化 shader 管线」专节。
- UI 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用
- **真机 V2 渲染依赖大坑（Mate 60 Pro/API24 实测）**：全局单例 `appStore.player`（@ObservedV2）的 @Trace/@Computed 对 **if 分支条件与属性插值（fontColor/visibility 等）均不触发 UI 更新**，仅 Text 内容插值存活——表现为切歌后 mini bar 不出现、当前行高亮/EQ 不刷新、播放页歌名不跟随。**对策（现行架构）**：PlayerController 提供 `addStateListener/removeStateListener` 多播订阅（切歌/启停时 `notifyState()`），页面在 aboutToAppear 订阅并维护 **@Local 镜像**（Index 的 `mini: MiniInfo`、PlayerPage 的 `song`/`isPlaying`）驱动渲染；列表当前行高亮靠回调里 `songSource.reload` 强制重建 LazyForEach 项。**不要**在渲染层直接依赖 player 的响应式状态（进度时间等 Text 插值除外）

- **UI 规范**：通用约束（触控热区 ≥40vp、纯图标可点元素必须 `accessibilityText` 且动态状态文案随状态变化、固定高度容器改 `constraintSize({ minHeight })` 以适配系统大字体、原生菜单优先且不要自绘、文本与开关必须显式指定前景/选中色）见用户级 skill `mobile-ui-conventions`，本文件不复述。以下为本项目特有：④重 IO（曲库索引全量落盘）走 taskpool `@Concurrent` 顶层函数，
  主线程只做序列化，taskpool 失败回退同步写；⑤prepared 时长回填仅在
  「原时长为 0（首次）」时才整体替换 songs 数组并广播刷新——时长已知曲目
  整刷会让大曲库每次切歌全量重建列表；⑥`deviceTypes` 收敛为 phone（布局
  未做 sm/md/lg 断点适配，声明 tablet/2in1 会构成审核风险，做一多适配前
  勿加回）；⑦AVSession `mediaImage` 直接支持本地封面路径字符串（锁屏封面，
  无需手动转 PixelMap）；⑧迷你条进度线经 `@Local` 镜像 + displaySync(4Hz)
  帧驱动（**不能**直读 `player.currentTime` 做 `width()` 插值——真机上
  `@Trace` 不驱动属性插值，线是死的），随 `onVisibleAreaChange` 与播放态
  启停；**注意回调方法名不得叫 `onVisibleAreaChange`**（与组件内置属性重名
  会与基类签名冲突、编译报错，与 `onDragStart` 同类坑），且该回调签名为
  `(isExpanding: boolean, ratio: number)`（单值非数组）；
  ⑨避让区高度入口是 `AppStore.readSafeArea()`，配置变更（旋转/折叠展开，
  `AppAbilityStage.onConfigurationUpdate`）时会重读；⑩seek 后即时持久化断点；
  ⑪首页**无标题栏**（`hideTitleBar(true)`——「音乐/N 首歌曲」chip 冗余已裁撤，
  2026-09 用户决策）：首屏是一级签排印行（**曲库/喜欢/最近/在线 四签平铺**，
  喜欢/最近为跨源一级视图不挂在本地签下——2026-09 用户决策；导入/设置
  图标居行尾，顶部避让并入该行 padding `safeTopVp+8`）→ 系统 Search →
  列表头行（左「N 首」计数 + 右排序入口，在线签只显计数无排序）→ 列表；
  封面占位统一走 `components/CoverArt.ets`（无内嵌封面时
  以**歌名首字**做大字排版占位：列表/迷你条浅色 token 板 `surface_alt`，
  播放页纸带 `onStage` 变体恒暗 viz token 板；不做哈希派生渐变——
  2026-09 用户决策「默认封面放歌名，不要哈希当颜色」——勿再手写
  「灰块+音符」占位）；
  ⑫一级签切换走 `Tabs`（4 个 TabContent，`index` 单向受控 + `onChange` 进
  `switchTab`，点选/滑动一致；SDK 无 Segmented/SegmentButton/CapsuleTabBarStyle，
  已查证；切换行是排印风自绘文字标签——选中金色加粗 + 下方短金线，无底色
  无图标；TabContent 不挂 tabBar（`barHeight(0)` + `barOverlap` 压掉系统预留
  空栏，否则顶部留 91vp 空隙，已实测）。手势映射（2026-09 三次迭代后
  定稿，按频率分工）：迷你条**平直横滑 = 切歌**（最高频场景拿最顺手
  的手势）——左滑下一首、右滑上一首，与播放页纸带 pager 同向（内容
  跟手，下一首在右）；**折返画 `>`/`<` = 顶部一级签切换**——`>` 下一个
  签、`<` 上一个签，四签循环越界回绕。历程：旧双层「折返切源+横滑切
  分类」→ 扁平化后曾统一为单事件相邻签循环，真机反馈横滑只能到曲库/
  在线，最终按用户决策拆回双事件但语义换成切签/切歌。
  喜欢/最近签进入时队列恢复为本地曲库（`refreshSongs`，队列是内容签
  列表的筛选源，切签必须自愈——真机踩坑：进喜欢后最近只剩收藏里的
  在线歌）；点播时喜欢/最近两签把队列替换为该视图跨源列表
  （`playFromList`，连播跟随所见），曲库签不替换（防搜索清空后列表
  剩残集）；搜索不跳签——内容签内搜索即筛其子集，在线签仍服务端搜索；⑬搜索框用系统 `Search`（受控 `value` + `onChange`/
  `onSubmit`，清除键/键盘搜索键系统托管）；⑭迷你条为底部通栏（与页面同宽、
  上缘发丝线分隔）+ `backgroundBlurStyle(COMPONENT_THICK)` 磨砂；
  `BlurStyle` 无 `BehindWindow`，窗内列表透出用 COMPONENT 系列）；
  **迷你条常驻不随曲目显隐**（2026-09 用户决策）：无播放曲目时显示占位
  态（保留封面位与条高、标题「未在播放」、播放/下一首禁用），列表底部
  常留 `MINI_BAR_HEIGHT`（62vp）避免最后一行被压住；
  ⑮列表项为杂志目录行（无盒子无阴影：17vp 粗歌名直接排版 + 时长右对齐
  如页码 + 行间发丝线；当前行 = 行首金色竖线 + 歌名变金 + EQ 跳动；
  按压反馈用系统默认——`stateStyles` 对象字面量在 V2 组件触发
  `TypeError: undefined is not callable` 闪退，真机日志定位，已踩坑，勿用）。
  **列表水平内距只有一层**：`SongList` 容器 padding 左右为 0，行内边距
  `SongItem` 左右 16 是唯一一层——容器+行双层叠加曾让每行两侧白让
  ~30vp、标题列被挤压（真机反馈），发丝线 margin-left 87 对齐歌名起排
  （16+竖线3+间距12+封面44+间距12）；
  ⑯手势约定（2026-09 用户决策，每操作一条自然路径）：歌曲操作唯一入口
  是长按菜单（左滑 `swipeAction` 已整链路移除；「喜欢」只在播放页 ♥）；
  迷你条挂单一全向 PanGesture + 轨迹采样路径分类器（不拆互斥组——弧线
  起始段是横向的会被横滑抢先认领）：折返**不等抬手**，笔画中早认（一次
  触摸只触发一次，触发后锁定到抬手；直线横滑故意不等抬手——它是折返的
  前半段，早认必误杀）：折返早认 = x 顶点（向一侧走出 45vp 后折回 25vp，
  右顶点 `>` = 下一个签、左顶点 `<` = 上一个签，不要求标准形，纵向漂移
  <50vp）；抬手兜底（折返跨度 ≥70vp + 折回量 ≥30vp + 纵向 ≥15vp → 切签；
  平直横滑纵净移 <40vp、横净移 ≥40vp → 切歌；其余忽略）。分类器定
  「何时触发与方向」，事件语义见⑫（横滑切歌/折返切签，双事件
  `onSwipeTrack`/`onSwipeTab`）。
  **已整链路移除（2026-09 用户决策）**：手势切源/切分类的 toast 提示
  （结果由高亮直接可见）、迷你条纵拉「下拉悬停」（Reachability 整页
  下沉 + 收起 pill + 首次教学 toast + 偏好键）——现有手势已覆盖单手
  操作，不要恢复。

- 播放页舞台双态**互斥**：封面模式（默认）以模糊放大的封面做氛围背景、`VisualizerView` 的 `active=false` 停帧 + visibility 隐藏（XComponent 不卸载，避免 EGL 重建黑屏坑），可视化模式才全屏渲染——不要恢复"封面浮于全速可视化之上"的旧设计；播放页手势对齐 Poweramp 官方 Player UI：封面与可视化区**左右滑动切歌**（封面是三格纸带 [上一首|当前|下一首]：邻居格常驻挂载（解码预热，拖动零首帧卡顿）、格间 24vp 空隙、窗口 clip 裁剪、整条只有 stripX 一次平移——成熟播放器 pager 模型；成歌松手**一次性完成"三格内容旋转一格（目标曲进中格）+ 位移反向补偿一格"**（同一帧互抵，屏幕像素一动不动），此后中格恒为目标曲——**落定不再有任何换内容动作**（旧版落定把中格从旧曲换成目标曲，正是"滑动完成瞬间文字闪一下"的根因）；吸附动画由 **onFinish** 驱动收敛，严禁按固定时长掐断弹簧（剩余路程瞬移肉眼可见）；未达阈值/曲目未变弹簧回中；空侧 rubber-band 阻尼封顶拖不动（表达"这边没有了"）；成歌判定在子组件——超 60vp 或 120ms 窗口甩速 ≥1vp/ms（≥20vp 快 flick），父组件只按方向切歌不再按阈值拦（甩动位移可不足阈值）；上一首格含 5 秒回曲首规则——超 5 秒右滑空侧）、舞台点击对称切换——**点按大封面切入可视化舞台、可视化舞台点画面回封面**（返回曲库只走左上箭头/系统侧滑——内容区点击不做导航，曾用 tap-on-cover 跳库，因轻扫切歌未达阈值被判成点击会误退回首页而废弃，用户决策 2026-09）；**XComponent(SURFACE) 原生表面区域收不到点击也不收手势**（挂在 XComponent、其父容器、透明点击层、TapGesture 全都无效，真机实测），可视化舞台的**点击回封面与左右滑动切歌都必须绑在前景内容层的舞台交互层上**（旧"点画面循环切风格"与"滑动切歌"在真机无响应的根因即此；交互层用 `layoutWeight(1)` 透明 Column 而非 Blank——Blank 对 PanGesture 命中不如实体容器可靠）；滑动与点击同层时必须自己区分：PanGesture 记录本次是否达阈值滑过（`vizSwipeMoved`），滑过则吞掉同一笔触尾随的 onClick，否则一滑就误判成点击跳回封面（用户报障现象）；切可视化风格走顶栏魔法棒菜单；
- **在线源（`OnlineSource`）**：首页一级签「在线」，`OnlineSource.fetchSongs(q)` 拉取 `/songs`（解析纯函数在 `source/OnlineApi.ets`，可 LocalUnit 单测）；在线搜索由 Index 防抖 600ms 触发，列表即服务端返回不做本地二次过滤；本地曲库时长由服务端解析容器元数据返回（durationMs），客户端 prepared 后仍会校准。**在线列表缓存（SWR）**：成功结果进 OnlineSource 内存缓存（按查询词键控，容量 8，来回切源秒开），默认视图（空查询）同时持久化 `filesDir/online_list_cache.json`（杀进程重开秒开）；进在线页先展示缓存（不再整页 loading），TTL 10 分钟内不发网络、过期静默刷新，下拉刷新/重复点在线标签/重试/改服务地址强制绕过缓存，换 baseUrl 缓存整体失效（纯函数 `isCacheFresh`/`serializeOnlineCache`/`parseOnlineCache` 在 OnlineApi.ets）；在线页同时拉 `/providers`（`fetchProviders`）获取网易云登录态（仅用于试听曲不进缓存与播放页「VIP 试听」标注的判定；服务端源状态不进客户端 UI），曲目 `vip` 字段驱动 VIP 徽标与播放页「VIP 试听」标注；播放失败（无版权/网络错误）由 `PlayerController.handlePlaybackFailure` 统一 toast + 自动跳下一首，连续 3 首失败熔断；服务地址设置页持久化，留空回落默认地址（契约见上级 AGENTS.md）。**收藏/最近跨源融合（2026-09 用户决策「喜欢不区分在线离线」）**：在线歌元数据持久化在 `source/OnlineSongStore.ets`（`filesDir/online_songs.json`，纯函数 `serializeOnlineSongStore`/`parseOnlineSongStore` 在 OnlineApi.ets），收藏（`AppStore.toggleFavorite` 唯一入口，PlayerPage ♥ 调用）与播放（`playSongInternal` 内 upsert）时注册；喜欢/最近 Tab 经 `LibraryFilter.FilterOptions.onlineSongs` 补位混排（ALL Tab 不混入；注册表非响应式，靠 favoriteIds/recentIds 的 @Trace 改写触发 @Computed 重算）；`PlayerController.findSong` 第三级兜底注册表（点播收藏在线歌/续播恢复都走这条）；换服务地址时注册表条目流地址按当前生效地址重拼（服务端 id 稳定）。**收藏钉住缓存**：收藏的在线歌同步进 `OnlineCache` pin 集合（不持久化，启动由收藏∩注册表重建），淘汰垫后（纯函数 `evictOrder`：非 pin 最旧在前、pin 垫后、在途跳过；全 pin 超限时 pin 内按 lastAccess 兜底，磁盘 500MB 硬上限不破），未缓存的收藏歌主动排队整曲下载（VIP 未登录试听曲不下载防污染）；下载队列限并发 2（`MAX_ACTIVE_DOWNLOADS`），播放伴随下载与收藏补下载共用，播放下载随切歌中止（代际号）、收藏下载不中止；取消收藏解除 pin（已下音频回归普通 LRU，不删文件）；注册表只留收藏∪最近引用的条目（`retain`），清空曲库时一并清。长按菜单「从曲库删除」对在线歌不显示（`isOnlineId` 判定）。

- 自适应深浅双主题（暖纸浅色 + Poweramp 深色）：`base/element/color.json`=浅色板
  （page_bg #F7F4EE / surface #FFFFFF / accent #A8791F 深金），`dark/element/color.json`=
  深色板（page_bg #121212 / surface #1D1C1A / accent #DBA84E 亮金），全部 UI 颜色经
  `$r('app.color.*')` 引用由资源限定符自动切换，代码不得写死色值；卡片体系另有
  `accent_soft`（当前行底）/`card_shadow`（卡片投影）/`accent_shadow`（当前行光晕）
  三 token，两套板同步值；`viz_*` 四个舞台
  token 两套板保持相同——播放页封面/可视化舞台恒定深底浅字（媒体播放页惯例）：
  `applyImmersion` 只维护 `AppStore.stageImmersion` 标记（进入置位/退出清除），
  `applyWindowChrome` 据此分流——舞台沉浸期间应用恒定深色舞台 chrome，其余时候
  按当前模式自适应。window 兜底色与系统栏字色的唯一入口是
  `AppStore.applyWindowChrome`（自适应分支经 `resourceManager.getColorSync` 按
  当前模式解析），启动（EntryAbility）、系统配置变更
  （`AppAbilityStage.onConfigurationUpdate`——UIAbility 无此回调，全局配置变更
  只通知 AbilityStage）与播放页进出都会重应用；标记保证在播放页期间切系统
  深浅时系统栏字色不会被自适应成深字压在深舞台上（不可见）。弹出菜单一律用原生
  `Menu`/`MenuItem`/`MenuItemGroup` 组件（bindMenu/bindContextMenu 的 builder 内写
  `Menu(){ MenuItem(...).onClick() }`）：磨砂材质、圆角、行高、字号、按压高亮、
  分组分隔线全部系统托管，深浅色自动适配——**不要自绘菜单卡片**（实心底+描边+
  重投影是 Android 风格，与系统割裂；`backgroundBlurStyle` 自绘玻璃的文字色错配
  曾致浅色模式浅底浅字，已踩坑）；选中态勾选用 `symbolEndIcon: new
  SymbolGlyphModifier($r('sys.symbol.checkmark'))`，分组标题用
  `MenuItemGroup({ header: '字符串' })`；原生菜单无红色危险项语义，破坏性操作
  （如从曲库删除）菜单项走 `AlertDialog` 二次确认（已按 surface 底+大圆角适配）。
  `bindSheet`/`AlertDialog` 用实心自适应底色（surface）托管；accent 底上的前景
  图标/文字固定用 `on_accent`，`paper` 只用于 ink 底；`TextInput` 必须显式设
  fontColor/placeholderColor（默认色随系统主题，浅色模式下会在深色输入底上形成
  深底深字不可见，已踩坑）；`Toggle` 必须显式 `selectedColor(accent)`——系统
  默认蓝与整包金主题割裂（真机走查：设置页麦克风开关）。
