# music_app（HarmonyOS 音乐播放器）

本目录是 HarmonyOS 应用工程（ArkTS + ArkUI，Stage 模型），仓库级结构与服务端
说明见上级 [AGENTS.md](../AGENTS.md)。以下命令均在本目录（music_app/）内执行。
额外约定如下。

## 架构事实

- 零第三方运行时依赖（仅 devDependencies `@ohos/hypium` 测试框架），全部使用系统能力
- `compatibleSdkVersion`/`targetSdkVersion` 为 `6.0.0(20)`，`modelVersion` 6.0.2（oh-package.json5 与 hvigor-config.json5）；本机 SDK 为 HarmonyOS 6.1.1（API 24），模拟器镜像同为 API 24；bundleName `com.lsyb.musicplayer`（自动签名由华为账号绑定前缀决定）
- **`module.json5` 必须含 `"pages": "$profile:main_pages"`**：缺失时构建不报错，但编译产物 module.json 无路由表，运行时 `loadContent` 返回 401 白屏（已踩坑）
- 播放内核 `AVPlayer`（每次切歌重建实例，靠代际号 `generation` 废弃旧实例回调）：
  - **状态迁移是异步事件**——`url` 赋值后须在 `on('stateChange')` 收到 `initialized` 才能调 `prepare()`，收到 `prepared` 才能调 `play()`；同步连调会 5400102
  - 本地文件用 `player.url = 'fd://<fd>'`（`fs.openSync` 的 fd，播放期间保持打开，release 时关闭）；`file://` 路径不支持；**在线曲目 `player.url` 直接赋 http(s) 流地址**（`fileName` 以 http 开头即网络分支，`module.json5` 需声明 `ohos.permission.INTERNET`，网络请求用 `@ohos.net.http`）
- 媒体会话 `@ohos.multimedia.avsession`：**命令监听必须逐个注册**（`on('play')`/`on('pause')`…，无统一 `'command'` 事件）；`PlaybackPosition` 字段为 `elapsedTime`+`updateTime`
- API 24 已移除 `READ_MEDIA_AUDIO` 权限、`AVMetadataHelper`、`fileAccess`：本地音乐只能走 `AudioViewPicker` 导入（选项字段为 `maxSelectNumber`，非 maxNumber）；mp3 元数据由 `library/Id3Parser.ets` 自解析（ID3v2.3/2.4）；时长由 AVPlayer prepared 后回填；**导入 URI 两坑**（已在 MusicLibrary 防御）：① AudioViewPicker 对 Download 等目录返回 percent-encoded URI（`file://docs/.../%E5%91%A8...mp3`），`fs.statSync` 可读而 `fs.copyFile` 按字面解析报 13900002——须 decodeURIComponent 双形态尝试；② `fs.copyFile` 对 `file://docs/` 来源整体不支持（stat 可过、copy 恒 ENOENT），回退 `openSync`+分块 read/write 拷贝；导入 toast 按 added/dup/failed 分类提示，added=0 不再误报"已在曲库"
- 音乐可视化：平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页 full 变体为 **shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关）；**shader 源码在 `entry/src/main/cpp/shaders/`**（按 GLSL ES 1.00 书写：`varying` / `gl_FragColor` / `texture2D`，uniform 每行一个声明），CMake 构建期经 `tools/gen_shader_header.py` 转成 GLES3 头文件 `shader_src.h`（生成到构建目录、不进源码树；注入头 15/4/5 行，编译报错行号减去它即源文件行号）；**手机端与 `shader_playground/` 当前都启用 `fractal.frag` / `pan.frag` / `aurora.frag` / `spectrum.frag` 四场景**，顺序由 `CMakeLists.txt` 的 `SHADER_SCENES`、`VisualizerCore.ets` 的 `VIZ_PRESET_NAMES` 与 playground `presets.ts` 共同定义，`PRESET_COUNT` 从名称清单派生；增删场景须同步这三处，`pipelineConsistency.test.ts` 会做跨端一致性检查；本地调试器 `shader_playground/`（Vite+TS，`bun run dev` → 8791）读同一份磁盘 GLSL，用 `src/glslPatch.ts` 做等价转换跑 WebGL2，**预览与端侧永远同源**；**防闪烁规范**（沿用至今：色相演化 ≤0.003/ms(~3 分钟一圈)、音频量(beat/bass/treble)只驱动亮度/尺寸绝不进色相、饱和度适中、真硬阈值一律 smoothstep 软化）；**性能架构（pan v17 / aurora v15 起）**：pan 每颗水珠状态是每帧常量，主 pass 前先以 20×4 小视口（`uStateMode=1`）用**同一份 pan.frag** 把状态写进 RGBA16F 纹理（依赖 `EXT_color_buffer_float`/`_half_float`，缺失时 C++ 在 #version 后插 `#define PAN_NO_STATE_TEX 1` 编译逐像素回退变体——状态计算抽成 `dropState()` 单一实现，两路径零分叉；状态纹理尺寸常量 `kPanStateTexW/H` 与 pan.frag 的 `DROPLET_COUNT/PAN_STATE_ROWS`、playground 的 `PAN_STATE_W/H` 三处一致，有测试锁定）；pan 锅椭圆外像素按 `panMask/wallMask/outerMask` 掩模跳过 field/bg/水珠着色（约 70% 像素白算的根除）；aurora 水面倒影只算最近主帘、软特征 fbm 用 common.glsl 的 `fbm3`；**平滑切换**：风格变化启动 1.5s 交叉淡化（presetTrans 0→1 经 NAPI 第 8 参传入，shader 里场景增量乘 smoothstep(uTransition) 渐入，旧画面不清空、靠反馈层衰减余晖自然消散——基于上一画布的 crossfade）；**内部按场景比例**降采样上屏线性放大柔化（`visualizer.cpp` 的 `kPresetScale`：fractal/spectrum 0.5、pan 0.45、aurora 0.33，与 playground `presets.ts` 的 renderScale 逐项对齐、pipelineConsistency.test.ts 锁定；pan/aurora 逐像素成本高且形态柔软，更低比例视觉近无损）；切风格触发反馈纹理重建时先把旧帧 blit 拷贝到新尺寸（保留交叉淡化的旧画面）；帧驱动 displaySync(30fps)→NAPI `renderFrame(t,seed,playing,beat,bass,treble,presetLock,transition,tiltX,tiltY,spin,kick)`，绘帧间隔按场景取 `VisualizerCore` 的 `VIZ_FRAME_INTERVAL_MS`（默认 25ms；aurora 40ms=25fps——慢场景无感，真机 GPU 超载时同步 renderFrame 会阻塞 UI 线程，场景级降帧治本）；beat/bass/treble 仅驱动局部元素亮度/尺寸，速度类恒定；uTilt（设备姿态：VisualizerView full 变体订阅 ORIENTATION 传感器（免权限），gamma→x（左右横滚→水平）、beta→y（前后俯仰→垂直）经 VisualizerCore.normalizeTilt（±4° 死区、±40° 满量程）+低通传入）驱动全场景 uv 相机视差；uSpin（alpha 相对进入舞台时基准的差分经 wrapAngleDelta+normalizeSpin（±5° 死区、±60° 满量程）+低通）驱动全场景滚转（common.glsl 的 motionSpinKick，最大 ±20°）；uKick（LINEAR_ACCELEROMETER 去重力线加速度经 accelKickLevel（阈值 1.5m/s²、满量程 8m/s²）attack、逐帧指数 decay（600ms），需 `ohos.permission.ACCELEROMETER`，被拒降级为 0）驱动已有音频量的亮度/尺寸通道——三者只进几何/亮度不进色相/速度，传感器不可用时保持 0 退化为无体感。mini 迷你条仍 2D Canvas 双离屏 ping-pong。**真机踩坑**：① XComponent 回调须在 NAPI Init 经 `exports.__NATIVE_XCOMPONENT_OBJ__` 早期注册（onLoad 才注册 surface 已创建不回放）；**重进播放页时 XComponent 是新实例，early 注册的对象已失效、created 事件早于 onLoad 的 fallback 注册被丢——EGL 永不初始化（第二次进入必黑屏）**，已加 `OH_NativeXComponent_RegisterSurfaceShowCallback` 兜底（show 晚于 onLoad 注册触发、带 window，VizOnSurfaceShow 幂等补初始化）；destroy 后 `gTexW/gTexH` 必须清零，否则新 context 复用已失效纹理 id；② GLSL `#version 300 es` 须首行（由生成脚本注入，源文件不要写）；③ 过曝防御 0.86+各层≤0.15+半分辨率；④ EGLNativeWindowType 经 uintptr_t 中转；⑤ 节流 25ms<33.3ms(30fps)；⑥ 沉浸全局恒定全屏布局；⑦ 每个场景一个 GL program，uniform 位置在创建时缓存，不要每帧 glGetUniformLocation
- UI 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用
- **真机 V2 渲染依赖大坑（Mate 60 Pro/API24 实测）**：全局单例 `appStore.player`（@ObservedV2）的 @Trace/@Computed 对 **if 分支条件与属性插值（fontColor/visibility 等）均不触发 UI 更新**，仅 Text 内容插值存活——表现为切歌后 mini bar 不出现、当前行高亮/EQ 不刷新、播放页歌名不跟随。**对策（现行架构）**：PlayerController 提供 `addStateListener/removeStateListener` 多播订阅（切歌/启停时 `notifyState()`），页面在 aboutToAppear 订阅并维护 **@Local 镜像**（Index 的 `mini: MiniInfo`、PlayerPage 的 `song`/`isPlaying`）驱动渲染；列表当前行高亮靠回调里 `songSource.reload` 强制重建 LazyForEach 项。**不要**在渲染层直接依赖 player 的响应式状态（进度时间等 Text 插值除外）
- **UI 规范（HarmonyOS Design 对齐，2026-09 审查后确立）**：①触控热区 ≥40vp
  （官方底线，推荐 46）——图标按钮用 padding 补足，固定高度 pill 用
  `constraintSize({ minHeight })`；②纯图标可点元素必须 `accessibilityText`
  （读屏），动态状态（播放/暂停、喜欢/取消）文案随状态变化；③固定高度容器
  （搜索框/菜单行/pill）改 `constraintSize({ minHeight })`，系统大字体时随内容
  撑高不截断；④重 IO（曲库索引全量落盘）走 taskpool `@Concurrent` 顶层函数，
  主线程只做序列化，taskpool 失败回退同步写；⑤prepared 时长回填仅在
  「原时长为 0（首次）」时才整体替换 songs 数组并广播刷新——时长已知曲目
  整刷会让大曲库每次切歌全量重建列表；⑥`deviceTypes` 收敛为 phone（布局
  未做 sm/md/lg 断点适配，声明 tablet/2in1 会构成审核风险，做一多适配前
  勿加回）；⑦AVSession `mediaImage` 直接支持本地封面路径字符串（锁屏封面，
  无需手动转 PixelMap）；⑧迷你条频谱经 `onVisibleAreaChange` 随可见性启停；
  ⑨避让区高度入口是 `AppStore.readSafeArea()`，配置变更（旋转/折叠展开，
  `AppAbilityStage.onConfigurationUpdate`）时会重读；⑩seek 后即时持久化断点；
  ⑪首页**无标题栏**（`hideTitleBar(true)`——「音乐/N 首歌曲」与「全部 N」
  chip 冗余已裁撤，2026-09 用户决策）：首屏直接是源切换胶囊行（导入/设置
  图标居行尾，顶部避让并入该行 padding `safeTopVp+8`）→ 系统 Search →
  筛选行 → 列表；封面占位统一走 `components/CoverArt.ets`（无内嵌封面时
  按曲目 id 哈希派生渐变 + 音符字形：列表/迷你条用浅色 token 板，播放页
  大封面 `onStage` 变体恒暗 viz token 板——勿再手写「灰块+音符」占位）；
  ⑫本地/在线切换走 `Tabs`（`index` 单向受控 + `onChange` 进 `switchSource`，
  点选/滑动一致；SDK 无 Segmented/SegmentButton/CapsuleTabBarStyle，已查证，
  tabBar 用自绘胶囊）；⑬搜索框用系统 `Search`（受控 `value` + `onChange`/
  `onSubmit`，清除键/键盘搜索键系统托管）；⑭迷你条为悬浮磨砂胶囊
  （`backgroundBlurStyle(COMPONENT_THICK)` + radius 24 + token 投影；
  `BlurStyle` 无 `BehindWindow`，窗内列表透出用 COMPONENT 系列）；
  ⑮列表项卡片化（surface 底 + radius 18 + token 投影，按压缩放
  `stateStyles({pressed})`），当前行 `accent_soft` 底 + accent 描边。
- 播放页舞台双态**互斥**：封面模式（默认）以模糊放大的封面做氛围背景、`VisualizerView` 的 `active=false` 停帧 + visibility 隐藏（XComponent 不卸载，避免 EGL 重建黑屏坑），可视化模式才全屏渲染——不要恢复"封面浮于全速可视化之上"的旧设计；播放页手势对齐 Poweramp 官方 Player UI：封面与可视化区**左右滑动切歌**（封面跟手位移 coverDragX、松手 ±60vp 判定、松手弹簧曲线回弹）、舞台点击对称切换——**点按大封面切入可视化舞台、可视化舞台点画面回封面**（返回曲库只走左上箭头/系统侧滑——内容区点击不做导航，曾用 tap-on-cover 跳库，因轻扫切歌未达阈值被判成点击会误退回首页而废弃，用户决策 2026-09）；**XComponent(SURFACE) 原生表面区域收不到点击**（挂在 XComponent、其父容器、透明点击层、TapGesture 全都无效，真机实测），"点画面回封面"必须绑在前景内容层里舞台区域的占位 `Blank().onClick()` 上（旧"点画面循环切风格"在真机一直无响应的根因即此）；切可视化风格走顶栏魔法棒菜单；
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
  深底深字不可见，已踩坑）

## 本地命令

构建/测试/lint/模拟器命令见 README.md「构建与运行」；要点：

- hvigor/ohpm/node 均用 DevEco 内置：`/Applications/DevEco-Studio.app/Contents/tools/...`
- hvigorw 打包需 `JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home`（仅 hvigor 命令需要）且 `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`（本机 6.1.1）
- 模拟器 CLI：`/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list|-start <name>|-stop <name>`
- hdc：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
- 模拟器可安装未签名 HAP，但运行时页面白屏；已配置 DevEco 自动签名（build-profile.json5 的 signingConfigs，密码为本机加密串，仅本机可用），命令行构建自动产出 `entry-default-signed.hap`
- **一键签名构建安装**：`tools/auto_sign.sh`（仓库根下）——校验签名材料存在/有效期/设备绑定后，命令行构建 signed HAP，`install` 参数再安装+启动到已连接设备；签名材料（`~/.ohos/config/default_music_app_*.p12/.cer/.p7b`）由 DevEco 自动签名生成、有效期一年，材料有效期内全程无需打开 IDE；材料缺失/过期/新设备未绑定时脚本会打印指引，只需去 IDE 点一次「Automatically generate signature」重新生成
- UI 自动化验证：`hdc shell uitest dumpLayout` 取 UI 树（应用 root 在 children[0]，检查 children 是否为空判断页面是否渲染）、`hdc shell uinput -T -c <x> <y>` 模拟点击、`snapshot_display` 截图

## 约束

- 系统资源引用（`sys.symbol.*`/`sys.color.*`）先在 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/id_defined.json` 中核实名称存在性再用
- rawfile 演示曲目文件名约定 `demoXX_歌手 - 歌名.wav`，由 `MusicLibrary.fillFromFileName` 解析；重新生成见 git 历史（python3 合成脚本）
