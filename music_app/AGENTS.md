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
- 音乐可视化（MilkDrop 风格）：平台无频谱 API（ArkTS/native 均无 Visualizer/FFT，已查证 API 24 SDK），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id，多频正弦+节拍包络，LocalUnit 可测）；`components/VisualizerView.ets` 双 `OffscreenCanvasRenderingContext2D` ping-pong 反馈——每帧把上一帧整帧无变换 alpha 叠加（衰减 0.958，颜色融合拖尾——无分块/旋转/缩放，故无接缝与矩形边界，画面自然铺满），叠加 Superformula 花域（r(θ)=(|cos(mθ/4)|^n2+|sin(mθ/4)|^n3)^(-1/n1) 光滑有机曲线，m/n 由 styleParam 在 24s 周期间 hash 平滑插值演化——不预设形态、参数空间连续漂移出无穷变换；单层大光晕演化为漂浮多色星云，另叠加 10 颗 Lissajous 轨道漂浮光斑粒子与曲线扩散光带（2 条阿基米德螺线旋涡自带内亮外淡分段描边 + 3 条由内向外推移淡出的扩散弧环，全为局部连续曲线、无边界效应），，色相域扭曲），上屏整帧 filter blur(1.2px) 柔化一切锐边；displaySync 限 24fps、离屏最长边 300；**lighter 反馈会累积过曝**，花域 alpha≤0.28、氛围光 L≤0.16、反馈衰减 0.958、底色 rgb(12,10,9) 压暗保前景可读；挂载于 PlayerPage 全屏背景（full 变体，无封面卡片、深底铺满含系统栏，播放页前景用 viz_fg 系资源），mini 变体为全宽金色频谱背景垫于迷你条整卡片（**必须固定高度**——height 100% 与 Stack 高度互引会把迷你条撑高）；暂停后 0.9s 收敛为静帧并停帧循环。**真机踩坑**（均已在代码防御）：① 上屏后的 ImageBitmap 不能立即 close（GPU 异步合成采样脏数据→花屏色块盖控件），需延迟数帧环形回收；② displaySync 高刷真机回调超预期，帧内需自行节流 ≥30ms；③ Canvas 显示画布按真机全物理分辨率每帧 CPU 光栅化一帧数百毫秒（体感 ~1fps），full 变体显示画布布局 1/4 尺寸 + scale(4) 放大铺满（面积 1/16 后流畅）；④ 播放页沉浸需要画面真正延伸到系统栏下：**必须 setWindowLayoutFullScreen(true)**——组件级 expandSafeArea 无法让 Canvas 画进系统栏区域（系统栏露出 window 固定兜底色，与画面动态颜色割裂，真机踩坑）；但全屏布局必须**全局恒定**：EntryAbility onWindowStageCreate 启动即开启且任何页面不得再开关——页面级开关的恢复经 aboutToDisappear 异步执行、滞后于首页首帧，返回首页时首页会在全屏布局残留期以物理屏幕坐标渲染（内容顶进状态栏/导航条）、恢复生效后再骤然收缩，表现为返回时布局跳动（已踩坑）。各页面（Index/SettingsPage/PlayerPage）前景内容统一用 AppStore.safeTopVp/safeBottomVp（EntryAbility 首页加载前经 getWindowAvoidArea TYPE_SYSTEM/TYPE_NAVIGATION_INDICATOR 预读，display.densityPixels 换算 vp）padding 避让；系统栏透明 #00000000 与字色、window 底色按页面切换；自定义系统栏不透明色在浅色模式下不生效（实测顶灰底白被系统主题覆盖）；⑤ 显示画布"小布局+scale 放大"方案中，父容器 Stack 默认 alignContent: Center 会把放大画面推偏（顶部 37.5% 恒露 window 兜底色，像素分析表现为上部死黑），容器必须显式 Alignment.TopStart；⑥ displaySync 调度帧率必须与帧内节流阈值匹配——expected 30fps（回调≈33ms）配 FRAME_MIN_INTERVAL=42ms 会把每次回调都跳过，实际帧率腰斩至 15fps、画面呈闪烁感（已踩坑），须 expected 24fps 配 36ms 阈值保证帧帧落地；上屏用 copy 合成模式单指令原子替换，clearRect+drawImage 两步在指令间可被合成器采样到空帧闪底色；⑦ 可视化管线逐项伪影（均已在代码修复）：分块流场变形的块间错位接缝呈“矩形光带拉扯”、全屏尺寸元素（氛围光半径/亮度、反馈层缩放）每拍频率的 beat 脉冲呈“整屏主色刷闪”、反馈层旋转帧的矩形边缘与底色分界呈“显示区域矩形框”——三者均为用户不可接受的伪影：反馈层必须是整帧无变换叠加，beat 只允许驱动局部元素（花域大小/频谱柱）；⑧ 上屏 blur 柔化位图放大硬边，实测 2.5px 过糊、1.2px 为平衡点；⑨ Superformula 花域 n1 < ~0.7 时轮廓呈星刺尖角（半径无爆炸、尖角明显），下限抬到 0.7 后形态圆润；⑩ 节流阈值必须按“调度帧间隔 - 实测帧耗”配对——本机 full 整帧 31ms（反馈 7+花域 22+上屏 1），选 24fps 调度（41.7ms 间隔）+36ms 阈值才帧帧落地：阈值高于回调间隔时回调被成片跳过、实际帧率腰斩（30fps 调度+42ms 阈值 → 实测 15fps，画面以不规则脉冲整替，表现为闪）
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
