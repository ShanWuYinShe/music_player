# music_app UI 细则

> 本文是 skill `music-app-platform-ui` 的细节补充。平台基线、媒体内核、V2 渲染红线、播放页舞台双态在 SKILL.md；本文按 UI 主题组织项目特有约定。

## 首页、一级签与搜索

- 首页**无标题栏**（`hideTitleBar(true)`——「音乐/N 首歌曲」chip 冗余已裁撤，2026-09 用户决策）：首屏是一级签排印行（**曲库/喜欢/最近/在线 四签平铺**，喜欢/最近为跨源一级视图不挂在本地签下——2026-09 用户决策；导入/设置图标居行尾，顶部避让并入该行 padding `safeTopVp+8`）→ 系统 Search → 列表头行（左「N 首」计数 + 右排序入口，在线签只显计数无排序）→ 列表。
- 封面占位统一走 `components/CoverArt.ets`（无内嵌封面时以**歌名首字**做大字排版占位：列表/迷你条浅色 token 板 `surface_alt`，播放页纸带 `onStage` 变体恒暗 viz token 板；不做哈希派生渐变——2026-09 用户决策「默认封面放歌名，不要哈希当颜色」——勿再手写「灰块+音符」占位）。
- 一级签切换走 `Tabs`（4 个 TabContent，`index` 单向受控 + `onChange` 进 `switchTab`，点选/滑动一致；SDK 只有 advanced `SegmentButton`（@since 11 的材质化分段按钮），无 `Segmented`/`CapsuleTabBarStyle`（已查证），一级签按排印风自绘、不引入 advanced 组件；切换行是排印风自绘文字标签——选中金色加粗 + 下方短金线，无底色无图标；TabContent 不挂 tabBar（`barHeight(0)` + `barOverlap` 压掉系统预留空栏，否则顶部留 91vp 空隙，已实测））。
- 搜索框用系统 `Search`（受控 `value` + `onChange`/`onSubmit`，清除键/键盘搜索键系统托管）。
- 队列与切签自愈：喜欢/最近签进入时队列恢复为本地曲库（`refreshSongs`，队列是内容签列表的筛选源，切签必须自愈——真机踩坑：进喜欢后最近只剩收藏里的在线歌）；点播时喜欢/最近两签把队列替换为该视图跨源列表（`playFromList`，连播跟随所见），曲库签不替换（防搜索清空后列表剩残集）；搜索不跳签——内容签内搜索即筛其子集，在线签仍服务端搜索。

## 导航手势（迷你条）

- 手势映射（2026-09 三次迭代后定稿，按频率分工）：迷你条**平直横滑 = 切歌**（最高频场景拿最顺手的手势）——左滑下一首、右滑上一首，与播放页纸带 pager 同向（内容跟手，下一首在右）；**折返画 `>`/`<` = 顶部一级签切换**——`>` 下一个签、`<` 上一个签，四签循环越界回绕。
- 反模式：旧双层「折返切源 + 横滑切分类」已被取代——扁平化后曾统一为单事件相邻签循环，真机反馈横滑只能到曲库/在线，最终拆回双事件但语义换成切签/切歌。不要再按「切源/切分类」理解手势。
- 手势约定（2026-09 用户决策，每操作一条自然路径）：歌曲操作唯一入口是长按菜单（左滑 `swipeAction` 已整链路移除；「喜欢」只在播放页 ♥）；迷你条挂单一全向 PanGesture + 轨迹采样路径分类器（不拆互斥组——弧线起始段是横向的会被横滑抢先认领）：折返**不等抬手**，笔画中早认（一次触摸只触发一次，触发后锁定到抬手；直线横滑故意不等抬手——它是折返的前半段，早认必误杀）：折返早认 = x 顶点（向一侧走出 45vp 后折回 25vp，右顶点 `>` = 下一个签、左顶点 `<` = 上一个签，不要求标准形，纵向漂移 <50vp）；抬手兜底（折返跨度 ≥70vp + 折回量 ≥30vp + 纵向 ≥15vp → 切签；平直横滑纵净移 <40vp、横净移 ≥40vp → 切歌；其余忽略）。分类器定「何时触发与方向」，事件语义见上文「导航手势」的横滑切歌/折返切签（双事件 `onSwipeTrack`/`onSwipeTab`）。
- **已整链路移除（2026-09 用户决策）**：手势切源/切分类的 toast 提示（结果由高亮直接可见）、迷你条纵拉「下拉悬停」（Reachability 整页下沉 + 收起 pill + 首次教学 toast + 偏好键）——现有手势已覆盖单手操作，不要恢复。

## 列表

- 列表项为杂志目录行（无盒子无阴影：17vp 粗歌名直接排版 + 时长右对齐如页码 + 行间发丝线；当前行 = 行首金色竖线 + 歌名变金 + EQ 跳动；按压反馈用系统默认——`stateStyles` 对象字面量在 V2 组件触发 `TypeError: undefined is not callable` 闪退，真机日志定位，已踩坑，勿用）。
- **列表水平内距只有一层**：`SongList` 容器 padding 左右为 0，行内边距 `SongItem` 左右 16 是唯一一层——容器+行双层叠加曾让每行两侧白让 ~30vp、标题列被挤压（真机反馈），发丝线 margin-left 87 对齐歌名起排（16+竖线3+间距12+封面44+间距12）。

## 迷你条

- 迷你条为底部通栏（与页面同宽、上缘发丝线分隔）+ `backgroundBlurStyle(COMPONENT_THICK)` 磨砂；`BlurStyle` 无 `BehindWindow`，窗内列表透出用 COMPONENT 系列。
- **迷你条常驻不随曲目显隐（2026-09 用户决策）**：无播放曲目时显示占位态（保留封面位与条高、标题「未在播放」、播放/下一首禁用）。迷你条是 Column 内普通兄弟节点、不叠压列表（列表视口到其上缘为止），列表底部只留 12vp 收尾——**不要**再按「迷你条悬浮」给列表预留 `MINI_BAR_HEIGHT`（62vp），那会让视口每屏空出一条高度（真机反馈过）。
- 迷你条进度线经 `@Local` 镜像 + displaySync(4Hz) 帧驱动（**不能**直读 `player.currentTime` 做 `width()` 插值——真机上 `@Trace` 不驱动属性插值，线是死的），随 `onVisibleAreaChange` 与播放态启停。

## 数据、引擎与设备声明

- 重 IO（曲库索引全量落盘）走 taskpool `@Concurrent` 顶层函数，主线程只做序列化，taskpool 失败回退同步写。
- prepared 时长回填仅在「原时长为 0（首次）」时才整体替换 songs 数组并广播刷新——时长已知曲目整刷会让大曲库每次切歌全量重建列表。
- `deviceTypes` 收敛为 phone（布局未做 sm/md/lg 断点适配，声明 tablet/2in1 会构成审核风险，做一多适配前勿加回）。
- AVSession `mediaImage` 直接支持本地封面路径字符串（锁屏封面，无需手动转 PixelMap）。
- 避让区高度入口是 `AppStore.readSafeArea()`，配置变更（旋转/折叠展开，`AppAbilityStage.onConfigurationUpdate`）时会重读；seek 后即时持久化断点。
- **注意回调方法名不得叫 `onVisibleAreaChange`**（与组件内置属性重名会与基类签名冲突、编译报错，与 `onDragStart` 同类坑），且该回调签名为 `(isExpanding: boolean, ratio: number)`（单值非数组）。

## 主题与 window chrome

- 自适应深浅双主题（暖纸浅色 + Poweramp 深色）：`base/element/color.json` = 浅色板（page_bg #F7F4EE / surface #FFFFFF / accent #A8791F 深金），`dark/element/color.json` = 深色板（page_bg #121212 / surface #1D1C1A / accent #DBA84E 亮金）；全部 UI 颜色经 `$r('app.color.*')` 引用由资源限定符自动切换，代码不得写死色值。
- 卡片体系另有 `accent_soft`（当前行底）/`card_shadow`（卡片投影）/`accent_shadow`（当前行光晕）三 token，两套板同步值；`viz_*` 四个舞台 token 两套板保持相同——播放页封面/可视化舞台恒定深底浅字（媒体播放页惯例）。
- `applyImmersion` 只维护 `AppStore.stageImmersion` 标记（进入置位/退出清除），`applyWindowChrome` 据此分流——舞台沉浸期间应用恒定深色舞台 chrome，其余时候按当前模式自适应。window 兜底色与系统栏字色的唯一入口是 `AppStore.applyWindowChrome`（自适应分支经 `resourceManager.getColorSync` 按当前模式解析），启动（EntryAbility）、系统配置变更（`AppAbilityStage.onConfigurationUpdate`——UIAbility 无此回调，全局配置变更只通知 AbilityStage）与播放页进出都会重应用；标记保证在播放页期间切系统深浅时系统栏字色不会被自适应成深字压在深舞台上（不可见）。

## 原生控件（菜单 / sheet / 输入 / 开关）

- 弹出菜单一律用原生 `Menu`/`MenuItem`/`MenuItemGroup` 组件（bindMenu/bindContextMenu 的 builder 内写 `Menu(){ MenuItem(...).onClick() }`）：磨砂材质、圆角、行高、字号、按压高亮、分组分隔线全部系统托管，深浅色自动适配——**不要自绘菜单卡片**（实心底+描边+重投影是 Android 风格，与系统割裂；`backgroundBlurStyle` 自绘玻璃的文字色错配曾致浅色模式浅底浅字，已踩坑）。
- 选中态勾选用 `symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark'))`，分组标题用 `MenuItemGroup({ header: '字符串' })`；原生菜单无红色危险项语义，破坏性操作（如从曲库删除）菜单项走 `AlertDialog` 二次确认（已按 surface 底+大圆角适配）。
- `bindSheet`/`AlertDialog` 用实心自适应底色（surface）托管；accent 底上的前景图标/文字固定用 `on_accent`，`paper` 只用于 ink 底。
- **bindSheet 三个不受控项（2026-10-15 恒暗化实测）**：① `showClose` **默认值即 true**，想隐藏必须显式 `showClose: false`——省略选项后系统钮与自绘关闭钮同屏重叠（真机抓拍双 ×）；② 系统 `title` 的字色随**系统深浅模式**走、不受 `backgroundColor` 控制，恒暗 sheet 上浅色系统会出深字压深底——恒暗 sheet 一律去 title 自绘标题行；③ 系统 showClose 钮位置固定右上，与自绘标题行不同轴。项目内两个 sheet（队列/分享）已按「viz_card_bg 底 + 自绘标题行 + 自绘 xmark（40vp 热区）」统一处理，新增 sheet 沿用该模式。
- `TextInput` 必须显式设 `fontColor`/`placeholderColor`（默认色随系统主题，浅色模式下会在深色输入底上形成深底深字不可见，已踩坑）；`Toggle` 必须显式 `selectedColor(accent)`——系统默认蓝与整包金主题割裂（真机走查：设置页麦克风开关）。
