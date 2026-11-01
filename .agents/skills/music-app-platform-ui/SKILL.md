---
name: music-app-platform-ui
description: music_app 平台架构与 UI 规范：AVPlayer 状态机、AVSession 元数据规则、API 24 移除项与导入坑、V2 状态管理红线与真机渲染大坑、本项目 UI 细则、播放页舞台双态与手势、在线源 SWR 缓存、双主题与原生菜单约定。触发：改 music_app 的 ArkTS 页面或组件；动播放内核/媒体会话；改主题与颜色资源；改播放页手势或舞台；改在线源与缓存；排查真机渲染不更新/白屏。
---

# music_app 平台架构与 UI 规范

## 平台基线

- 零第三方运行时依赖（仅 devDependencies `@ohos/hypium` 测试框架），全部使用系统能力。
- `compatibleSdkVersion`/`targetSdkVersion` 为 `6.0.0(20)`，`modelVersion` 6.0.2（oh-package.json5 与 hvigor-config.json5）；本机 SDK 为 HarmonyOS 26.0.0（API 26）；bundleName `com.lsyb.musicplayer`（自动签名由华为账号绑定前缀决定）。
- **`module.json5` 必须含 `"pages": "$profile:main_pages"`**：缺失时构建不报错，但编译产物 module.json 无路由表，运行时 `loadContent` 返回 401 白屏（已踩坑）。
- **脚本/agent 环境调用构建工具链必须补全 env（实测）**：DSH run_code 进程 `HOME` 为 undefined、`PATH` 缺 `/usr/bin:/bin:/usr/sbin:/sbin`（`sed`/`dirname` 等 ENOENT，表象是 ohpm/hvigorw 莫名 exit 126/127）——spawn 时显式传 `HOME=/Users/<user>`、`PATH` 前缀 `/Applications/DevEco-Studio.app/Contents/tools/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`；hvigor 另需 `JAVA_HOME`+`DEVECO_SDK_HOME`（见 music_app/AGENTS.md「本地命令」）。

## 媒体内核：AVPlayer / AVSession / API 24

- 播放内核 `AVPlayer`（每次切歌重建实例，靠代际号 `generation` 废弃旧实例回调）：
  - **状态迁移是异步事件**——`url` 赋值后须在 `on('stateChange')` 收到 `initialized` 才能调 `prepare()`，收到 `prepared` 才能调 `play()`；同步连调会 5400102。
  - 本地文件用 `player.url = 'fd://<fd>'`（`fs.openSync` 的 fd，播放期间保持打开，release 时关闭）；`file://` 路径不支持；**在线曲目 `player.url` 直接赋 http(s) 流地址**（`fileName` 以 http 开头即网络分支，`module.json5` 需声明 `ohos.permission.INTERNET`，网络请求用 `@ohos.net.http`）。
- 媒体会话 `@ohos.multimedia.avsession`：**命令监听必须逐个注册**（`on('play')`/`on('pause')`…，无统一 `'command'` 事件）；`PlaybackPosition` 字段为 `elapsedTime`+`updateTime`；**AVMetadata 可选字段必须整键省略**（真机 API 24 实测：键存在但值为 `undefined` 时系统 NAPI 按「键存在即校验类型」拒绝整条元数据，`setAVMetadata` 返回 401——元数据缺失则进不了系统有效会话列表，实况窗不显示、耳机按键路由到其他应用，`SessionController.updateMetadata` 已按此构造）；播放失败路径须回写会话暂停态，长驻任务在系统焦点打断后会被自行取消、每次 `playing` 都要实际重新申请（不能信内存标志）。
- API 24 已移除 `READ_MEDIA_AUDIO` 权限、`AVMetadataHelper`、`fileAccess`：本地音乐只能走 `AudioViewPicker` 导入（选项字段为 `maxSelectNumber`，非 maxNumber）；mp3 元数据由 `library/Id3Parser.ets` 自解析（ID3v2.3/2.4）；时长由 AVPlayer prepared 后回填。
- **导入 URI 两坑（已在 MusicLibrary 防御）**：① AudioViewPicker 对 Download 等目录返回 percent-encoded URI（`file://docs/.../%E5%91%A8...mp3`），`fs.statSync` 可读而 `fs.copyFile` 按字面解析报 13900002——须 decodeURIComponent 双形态尝试；② `fs.copyFile` 对 `file://docs/` 来源整体不支持（stat 可过、copy 恒 ENOENT），回退 `openSync`+分块 read/write 拷贝；导入 toast 按 added/dup/failed 分类提示，added=0 不再误报「已在曲库」。

## 音乐可视化

- 平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页为 **shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关）。GLSL 源码规范、场景注册、性能架构、帧驱动与真机踩坑见 skill `music-app-shader-pipeline`。

## UI 状态管理（V2）与真机渲染红线

- 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用。
- **真机 V2 渲染依赖大坑（Mate 60 Pro/API24 实测）**：全局单例 `appStore.player`（@ObservedV2）的 @Trace/@Computed 对 **if 分支条件与属性插值（fontColor/visibility 等）均不触发 UI 更新**，仅 Text 内容插值存活——表现为切歌后 mini bar 不出现、当前行高亮/EQ 不刷新、播放页歌名不跟随。**对策（现行架构）**：PlayerController 提供 `addStateListener/removeStateListener` 多播订阅（切歌/启停时 `notifyState()`），页面在 aboutToAppear 订阅并维护 **@Local 镜像**（Index 的 `mini: MiniInfo`、PlayerPage 的 `song`/`isPlaying`）驱动渲染；列表当前行高亮靠回调里 `songSource.reload` 强制重建 LazyForEach 项。**不要**在渲染层直接依赖 player 的响应式状态（进度时间等 Text 插值除外）。

## 播放页舞台双态与手势

- 播放页舞台双态**互斥**：封面模式（默认）以模糊放大的封面做氛围背景、`VisualizerView` 的 `active=false` 停帧 + visibility 隐藏（XComponent 不卸载，避免 EGL 重建黑屏坑），可视化模式才全屏渲染——不要恢复「封面浮于全速可视化之上」的旧设计。
- 播放页手势对齐 Poweramp 官方 Player UI：封面与可视化区**左右滑动切歌**（封面是三格纸带 [上一首|当前|下一首]：邻居格常驻挂载（解码预热，拖动零首帧卡顿）、格间 24vp 空隙、窗口 clip 裁剪、整条只有 stripX 一次平移——成熟播放器 pager 模型；成歌松手**一次性完成「三格内容旋转一格（目标曲进中格）+ 位移反向补偿一格」**（同一帧互抵，屏幕像素一动不动），此后中格恒为目标曲——**落定不再有任何换内容动作**（落定后若再把中格从旧曲换成目标曲，就会出现「滑动完成瞬间文字闪一下」）；吸附动画由 **onFinish** 驱动收敛，严禁按固定时长掐断弹簧（剩余路程瞬移肉眼可见）；未达阈值/曲目未变弹簧回中；空侧 rubber-band 阻尼封顶拖不动（表达「这边没有了」）；成歌判定在子组件——超 60vp 或 120ms 窗口甩速 ≥1vp/ms（≥20vp 快 flick），父组件只按方向切歌不再按阈值拦（甩动位移可不足阈值）；上一首格含 5 秒回曲首规则——超 5 秒右滑空侧）。
- 舞台点击对称切换：**点按大封面切入可视化舞台、可视化舞台点画面回封面**（返回曲库只走左上箭头/系统侧滑——内容区点击不做导航：tap-on-cover 跳库会让轻扫切歌未达阈值时被判成点击而误退回首页，因此不采用）。
- **XComponent(SURFACE) 原生表面区域收不到点击也不收手势**（挂在 XComponent、其父容器、透明点击层、TapGesture 全都无效，真机实测）：可视化舞台的**点击回封面与左右滑动切歌都必须绑在前景内容层的舞台交互层上**（旧「点画面循环切风格」与「滑动切歌」在真机无响应的根因即此；交互层用 `layoutWeight(1)` 透明 Column 而非 Blank——Blank 对 PanGesture 命中不如实体容器可靠）。滑动与点击同层时必须自己区分：PanGesture 记录本次是否达阈值滑过（`vizSwipeMoved`），滑过则吞掉同一笔触尾随的 onClick，否则一滑就误判成点击跳回封面（用户报障现象）。切可视化风格走顶栏魔法棒菜单。

## UI 与主题（细则见 references/ui-conventions.md）

- 字号适配基准 = app 自身宽高的设计定稿，不跟随系统字体缩放（既定口径）：全部 Text 用固定 vp 字号（如歌名 17vp），`app.json5` **不配置** `fontSizeScale`（不配置即不跟随；SDK 该配置在 app configuration 块，`followSystem`/数字倍率两种形态）。实测依据：模拟器系统字体调「超大」档后应用字号零变化，布局稳定。禁止为无障碍跟随而全局接 fontScale——真机 @Trace 不驱动属性插值，响应式字号刷新需每组件 @Local 镜像，成本与版式风险都不可接受；无障碍保障改由触控热区 ≥40vp、constraintSize 适配、显示大小缩放承担。
- 通用 UI 约束（触控热区 ≥40vp、纯图标可点元素必须 `accessibilityText` 且动态状态文案随状态变化、固定高度容器改 `constraintSize({ minHeight })`、原生菜单优先且不要自绘、文本与开关必须显式指定前景/选中色）见用户级 skill `mobile-ui-conventions`，本文件不复述。
- 本项目 UI 细则按主题见 references/ui-conventions.md：首页与一级签、列表行、迷你条、手势分类器、搜索、主题 token 与 window chrome、原生菜单/bindSheet/TextInput/Toggle 约定。

## 在线源与缓存（细则见 references/online-source.md）

- 首页一级签「在线」，`OnlineSource.fetchSongs(q)` 拉取 `/songs`（解析纯函数在 `source/OnlineApi.ets`，可 LocalUnit 单测）；在线搜索由 Index 防抖 600ms 触发，列表即服务端返回不做本地二次过滤；本地曲库时长由服务端解析容器元数据返回（durationMs），客户端 prepared 后仍会校准。
- SWR 缓存（内存按查询词键控 + 默认视图持久化、TTL 10 分钟、强制刷新路径）、`/providers` 登录态与 VIP 标注、播放失败熔断、收藏/最近跨源融合与收藏钉住缓存，见 references/online-source.md。
