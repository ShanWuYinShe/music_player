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
- API 24 已移除 `READ_MEDIA_AUDIO` 权限、`AVMetadataHelper`、`fileAccess`：本地音乐只能走 `AudioViewPicker` 导入（选项字段为 `maxSelectNumber`，非 maxNumber）；mp3 元数据由 `library/Id3Parser.ets` 自解析（ID3v2.3/2.4）；时长由 AVPlayer prepared 后回填
- 音乐可视化（MilkDrop 风格）：平台无频谱 API（ArkTS/native 均无 Visualizer/FFT，已查证 API 24 SDK），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id，多频正弦+节拍包络，LocalUnit 可测）；`components/VisualizerView.ets` 双 `OffscreenCanvasRenderingContext2D` ping-pong 反馈（每帧 `transferToImageBitmap` 把上一帧缩放/微旋转重绘成流动拖尾）+ `displaySync` 限 30fps；挂载于 PlayerPage 全屏背景（full 变体，无封面卡片、近黑沉浸底铺满含系统栏，播放页前景用 `viz_fg` 系资源）与 MiniPlayerBar 底部光带（mini 变体，单色金两端渐隐融入卡片）；暂停后 0.9s 收敛为静帧并停帧循环。**真机踩坑**（均已在代码防御）：① 上屏后的 `ImageBitmap` 不能立即 `close()`（GPU 异步合成采样脏数据→花屏色块盖控件），需延迟数帧环形回收；② `displaySync` 高刷真机回调超预期，帧内需自行节流 ≥30ms；③ Canvas 显示画布按真机全物理分辨率每帧 CPU 光栅化一帧数百毫秒（体感 ~1fps），full 变体显示画布布局 1/3 尺寸 + `scale(3)` 放大铺满（面积 1/9 后流畅），离屏上限 500；④ 播放页沉浸需系统栏背景设**透明**（`statusBarColor`/`navigationBarColor` 传 `'#00000000'`，不透明栏会把可视化挡在安全区内形成"矩形画布"观感）+ `setWindowBackgroundColor` 深色兜底，退出按深浅模式恢复 page_bg 不透明色；⑤ 显示画布"小布局+scale 放大"方案中，父容器 Stack 默认 `alignContent: Center` 会把放大画面推偏（顶部 37.5% 恒露 window 兜底色，像素分析表现为上部死黑），容器必须显式 `Alignment.TopStart`；显示画布现为 1/4+scale(4)、离屏上限 420、24fps 节流；⑥ 画面底色必须固定为兜底色 #161310（rgb 22,19,16）并加四周渐晕收边（反向径向渐变 source-over），氛围光渐变边缘收敛到透明——底色随 hue 变化或氛围光边缘不透明时，画面边缘与 window 兜底色产生色差割裂
- UI 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用
- 深浅色：只用 `sys.color.*` 系统分层色，应用不自定义主题色

## 本地命令

构建/测试/lint/模拟器命令见 README.md「构建与运行」；要点：

- hvigor/ohpm/node 均用 DevEco 内置：`/Applications/DevEco-Studio.app/Contents/tools/...`
- hvigorw 打包需 `JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home`（仅 hvigor 命令需要）
- 模拟器 CLI：`/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list|-start <name>|-stop <name>`
- hdc：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
- 模拟器可安装未签名 HAP，但运行时页面白屏；已配置 DevEco 自动签名（build-profile.json5 的 signingConfigs，密码为本机加密串，仅本机可用），命令行构建自动产出 `entry-default-signed.hap`
- UI 自动化验证：`hdc shell uitest dumpLayout` 取 UI 树（应用 root 在 children[0]，检查 children 是否为空判断页面是否渲染）、`hdc shell uinput -T -c <x> <y>` 模拟点击、`snapshot_display` 截图

## 约束

- 系统资源引用（`sys.symbol.*`/`sys.color.*`）先在 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/id_defined.json` 中核实名称存在性再用
- rawfile 演示曲目文件名约定 `demoXX_歌手 - 歌名.wav`，由 `MusicLibrary.fillFromFileName` 解析；重新生成见 git 历史（python3 合成脚本）
