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
- 音乐可视化：平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页 full 变体为 **shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关）；**shader 源码在 `entry/src/main/cpp/shaders/`**（按 GLSL ES 1.00 书写：`varying` / `gl_FragColor` / `texture2D`，uniform 每行一个声明），CMake 构建期经 `tools/gen_shader_header.py` 转成 GLES3 头文件 `shader_src.h`（生成到构建目录、不进源码树；注入头 12/4/5 行，编译报错行号减去它即源文件行号）；**手机端与 `shader_playground/` 当前都启用 `fractal.frag` / `pan.frag` / `aurora.frag` / `spectrum.frag` 四场景**，顺序由 `CMakeLists.txt` 的 `SHADER_SCENES`、`VisualizerCore.ets` 的 `VIZ_PRESET_NAMES` 与 playground `presets.ts` 共同定义，`PRESET_COUNT` 从名称清单派生；增删场景须同步这三处，`pipelineConsistency.test.ts` 会做跨端一致性检查；本地调试器 `shader_playground/`（Vite+TS，`bun run dev` → 8791）读同一份磁盘 GLSL，用 `src/glslPatch.ts` 做等价转换跑 WebGL2，**预览与端侧永远同源**；**防闪烁规范**（沿用至今：色相演化 ≤0.003/ms(~3 分钟一圈)、音频量(beat/bass/treble)只驱动亮度/尺寸绝不进色相、饱和度适中、真硬阈值一律 smoothstep 软化）；**平滑切换**：风格变化启动 1.5s 交叉淡化（presetTrans 0→1 经 NAPI 第 8 参传入，shader 里场景增量乘 smoothstep(uTransition) 渐入，旧画面不清空、靠反馈层衰减余晖自然消散——基于上一画布的 crossfade）；内部 1/2 分辨率（608x1344）上屏线性放大柔化；帧驱动 displaySync(30fps)→NAPI `renderFrame(t,seed,playing,beat,bass,treble,presetLock,transition)` 节流 25ms；beat/bass/treble 仅驱动局部元素亮度/尺寸，速度类恒定。mini 迷你条仍 2D Canvas 双离屏 ping-pong。**真机踩坑**：① XComponent 回调须在 NAPI Init 经 `exports.__NATIVE_XCOMPONENT_OBJ__` 早期注册（onLoad 才注册 surface 已创建不回放）；② GLSL `#version 300 es` 须首行（由生成脚本注入，源文件不要写）；③ 过曝防御 0.86+各层≤0.15+半分辨率；④ EGLNativeWindowType 经 uintptr_t 中转；⑤ 节流 25ms<33.3ms(30fps)；⑥ 沉浸全局恒定全屏布局；⑦ 每个场景一个 GL program，uniform 位置在创建时缓存，不要每帧 glGetUniformLocation
- UI 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用
- 深浅色：只用 `sys.color.*` 系统分层色，应用不自定义主题色

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
