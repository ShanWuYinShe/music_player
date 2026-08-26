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
- 音乐可视化：平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页 full 变体为 **shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关、八风格**仅由点击可视化区域切换**（XComponent onClick→presetLock 0..7 循环，无自动轮换，uPresetSel 直传 shader），全部具备"持续向屏幕内部深入"运动（环境向外涌/向后掠过，无一静止；周期 zoom 涌出的回绕用"每轮 hash 换世界原点/兴趣点/c 相位步进"掩盖成"进入新层"，万花筒用径向 log 空间平移天然无缝循环；分形无穷形态）：0 流动星野=匀速平移穿越(方向缓旋,内容因世界平铺无限更新)+20 颗 3D 深度星流(每颗有真实 z,投影沿双曲线轨迹向外飞出,近亮远暗)、1 穿越分形峡谷=相机沿 z 前行(蛇形)+sdfCanyon 域重复平铺,每胞 hash 出 KIFS 分形参数(abs 折叠+排序+旋转+缩放平移迭代 6 次——Menger 类自相似无穷形态)∩中心管道外(半径 0.55 走廊)，46 步 raymarch+jitter+像素覆盖软边 AA+中心差分法线、2 Julia 之海=经典集边界 c 点集(dendrite/螺旋/枝晶)逐层真深潜(18s/层,e^6≈400 倍,层末换 c 进入全新形态+层界淡入淡出)、3 涡旋隧道=伪 3D 深度管道格子流光（弯道偏移+提速）、4 Mandelbrot 深潜=兴趣点集逐层真深潜(18s/层,步长随深度收窄=匀速深入感,e^8.5≈5000 倍,层末换兴趣点+抖动进入全新结构,结构随深度持续演化——分形演示本体)、5 极光幕=层相位连续推进的帘幕群(每道参数随轮次更替,生入死出穿越)+星空 zoom 涌出、6 万花筒=7 扇区镜像折叠+径向 log 空间平移(无限向中心涌)+花形按径向层号 hash 变化(每层新花,无周期重复)+珠链、7 干涉波纹=波源生命周期场(自中心深处诞生→外漂→消散,新源持续涌现)干涉+中心辉光；uRes uniform 校正纵横比；参数驱动）；FBO 纹理 ping-pong 做上一帧反馈采样（逐像素 domain warp 拖尾，无分块/旋转/矩形边缘等伪影）；内部渲染 1/2 分辨率（608x1344 于本机，跨风格实测 28-29fps 稳定）上屏线性放大（柔化+控耗）；元素=氛围光 + 4 朵 Superformula 花域（styleParam 24s 演化、n1≥0.7 防星刺）+ 螺旋带×2 + 扩散环×3 + 九宫格遍历闪烁光斑；帧驱动 displaySync(30fps) → NAPI renderFrame(t, seed, playing, beat, bass, treble)，节流阈值 25ms；beat/bass/treble 为 VisualizerCore 合成律动参数（beatEnvelope 节拍包络 + synthSpectrum 低/高频段，与迷你条同源、种子派生非真实音频），只驱动局部元素（花域尺寸/边缘亮度、晶体表面漫反射/边缘光/尺寸、隧道格子亮度/中心辉光），速度类参数（自转/流速/漂移）保持恒定——瞬时值乘速度会跳变。mini 迷你条频谱柱仍走 2D Canvas 管线（双离屏画布 + 整帧无变换 alpha 拖尾 + copy 原子上屏）。**真机踩坑**（均在代码防御）：① XComponent 回调必须在 NAPI Init 里经 `exports.__NATIVE_XCOMPONENT_OBJ__`（napi_unwrap 解出 OH_NativeXComponent*）早期注册——onLoad 时才注册则 surface 已完成创建、RegisterCallback 不回放事件（画面永不出现），且回调结构必须静态存储；② GLSL `#version 300 es` 必须在源码首行（C++ raw string 起始换行报 P0005），hsl2rgb 勿用 vec/float 比较；③ 过曝防御：反馈衰减 0.86 + 各层强度 ≤0.15 + 半分辨率放大（稳态亮度≈注入/衰减率，全白即超标）；④ EGLNativeWindowType 为整数型，须经 uintptr_t 中转 void*；⑤ 节流阈值必须小于 displaySync 回调间隔——25ms<33.3ms(30fps) 帧帧落地，36ms 阈值配 30fps 回调则回调被成片跳过、实际帧率腰斩至 15fps（多次踩坑）；⑥ 播放页沉浸仍按 ④ 条目全局恒定全屏布局（EntryAbility 启动即开、各页 safeTopVp/safeBottomVp 避让）
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
