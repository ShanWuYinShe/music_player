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
- 音乐可视化：平台无音频频谱 API（已查证 API 24），频段能量由 `common/VisualizerCore.ets` 纯函数合成（种子=曲目 id FNV-1a、多频正弦+beat 包络，LocalUnit 可测）。播放页 full 变体为 **真透视 shader 管线**：XComponent(SURFACE, libraryname=entry) + `entry/src/main/cpp`（libentry.so, EGL/GLES3, 零第三方依赖）——vertex 仅画全屏三角形，fragment shader 逐像素解算全部视觉（运算量只与像素数相关、与形态复杂度无关；**十风格仅由点击可视化区域切换**（XComponent onClick→presetLock 0..9 循环，无自动轮换，uPresetSel 直传 shader）；**全风格防闪烁规范**（水晶洞窟重做为水晶圣殿时确立，已全量整改到 10 风格：色相演化 ≤0.003/ms(~3 分钟一圈)、音频量(beat/bass/treble)只驱动亮度/尺寸绝不进色相、fov 固定不随音频、饱和度 ≤0.88、真硬阈值一律 smoothstep 软化——chaosA/chaosB 已平滑插值可安全使用）；**平滑切换**：风格变化启动 1.5s 交叉淡化（uPresetSel 变化→presetTrans 0→1 经 NAPI 第 8 参传入，shader 里场景增量乘 smoothstep(uTransition) 渐入，旧画面不清空、靠反馈层衰减余晖自然消散——基于上一画布的 crossfade）；**闪烁源防御**：chaosA/chaosB 由 floor-hash 跳变改为相邻 hash smoothstep 插值（不可预测但连续），分形等高线的 bassPow 硬阈值 step 改 smoothstep 宽过渡（能量抖动不再开关线条），**全部为真实透视相机而非简单缩放**（每风格独立 FOV 焦距呼吸 `focal=1/tan(fov/2)` + yaw/pitch/roll + dolly 位移，ray 由透视投影 `normalize(vec3((uv-0.5)*vec2(aspect,1)*focal,1))` 经相机旋转生成，深度层按 `1/depth` 视差缩放/位移/雾化——近大近亮近快、远小远暗远慢并向消失点汇聚；反馈拖尾亦为距消失点 `vp` 径向透视流动 `persWarp=toP*(0.012*rvp+0.0045)` 近快远慢，非均匀位移）：0 流动星野·透视分层=世界平铺花域改为三深度层透视投影 `toCell=(cellCenter-wp)/depth` + 深度雾 `exp(-depth*0.55)` + 20 颗双曲线星流；1 分形峡谷·真透视=FOV 呼吸(62°+7°bass)+yaw/pitch 摇摆蛇形前行+ray 经 yaw/pitch 旋转+ `sdfCanyon` 域重复平铺 KIFS(6 次迭代)×中心管外 46 步 raymarch+jitter+像素覆盖 AA+差分法线；2 Julia 之海·俯冲透视=俯角 18° 掠射 Julia 平面(`tPlane=-ro.y/rd.y`, `hit=ro.xz+rd.xz*tPlane`)+地平线汇聚 `1/(1+depth*0.55)` + 高度指数俯冲 `zf=exp(fract*6)` + 层末换 c；3 涡旋隧道·真圆柱=真圆柱透视管道(FOV 64°+8°bass+yaw/pitch 弯道跟随，`depth=0.22/rad+t*` 格子 foreshortening `persFade=exp(-depth*0.055)`)；4 Mandelbrot·推轨变焦=dolly 指数趋近 `camDist=2.8*exp(-dolly*2.4)` + FOV 线性收窄 `76°→52°` 的推轨变焦透视(`plane=ro+rd*tPlane` 再 `z0=poi+(plane-poi)*(0.18+0.82*persF)+q*zf*persF`)；5 极光幕·透视帘片=帘幕改为不等距深度平面 ray-plane 求交 `tC=(worldZ-ro.z)/rd.z` 近宽厚亮远窄薄`persA=1/(1+depth*0.38)`+生入死出；6 万花筒·棱镜隧道=3 层深度棱镜 `depth=0.55+fract*2.4` 经 `1/depth` 透视缩放`ring=exp(fract(lr))* (0.92+0.16*persK)`+每层 hash 新花+珠链 foreshortening；7 干涉波纹·俯视水面=高位俯角 68° 水面 ray-plane 求交 `tWater=-ro.y/rd.y` 远密近疏 `persWv=1/(1+depth*0.42)` + `waveK*(0.75+0.45*persWv)`；8 晶体环廊·环阵=沿 z 复用圆环 SDF `sdTorus` `repZ=1.55` 每环 hash 半径/倾角 36 步 raymarch+局部法线逆旋转+漫反射/菲涅尔+雾；9 云海俯冲·分层容量=三高度 `0/0.22/-0.14` 云层 ray-plane+`fbm2` 值噪声视差 `persC=1/(1+depth*0.42)`+风场漂移；uRes 校正纵横比，参数驱动；FBO ping-pong 反馈逐像素 domain warp 拖尾，无分块伪影；内部 1/2 分辨率（608x1344，跨风格 28-30fps 稳定）上屏线性放大柔化；帧驱动 displaySync(30fps)→NAPI `renderFrame(t,seed,playing,beat,bass,treble,presetLock)` 节流 25ms；beat/bass/treble 仅驱动局部元素亮度/尺寸，速度类恒定。mini 迷你条仍 2D Canvas 双离屏 ping-pong。**真机踩坑**：① XComponent 回调须在 NAPI Init 经 `exports.__NATIVE_XCOMPONENT_OBJ__` 早期注册（onLoad 才注册 surface 已创建不回放）；② GLSL `#version 300 es` 须首行；③ 过曝防御 0.86+各层≤0.15+半分辨率；④ EGLNativeWindowType 经 uintptr_t 中转；⑤ 节流 25ms<33.3ms(30fps)；⑥ 沉浸全局恒定全屏布局
- UI 状态管理统一 V2 体系：`@ObservedV2`/`@Trace`（PlayerController）+ `@ComponentV2`/`@Param`/`@Local`；modelVersion 6.0.2 起 V2 组件**普通成员禁止父组件初始化**（回调用 `@Event`、入参用 `@Param`）；对象字面量必须对应 interface/class，回调集合用具名类实现；`@Trace` 数组元素字段变化不触发 UI，需整体替换数组引用
- 深浅色：只用 `sys.color.*` 系统分层色，应用不自定义主题色

## 本地命令

构建/测试/lint/模拟器命令见 README.md「构建与运行」；要点：

- hvigor/ohpm/node 均用 DevEco 内置：`/Applications/DevEco-Studio.app/Contents/tools/...`
- hvigorw 打包需 `JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home`（仅 hvigor 命令需要）且 `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`（本机 6.1.1）
- 模拟器 CLI：`/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -list|-start <name>|-stop <name>`
- hdc：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
- 模拟器可安装未签名 HAP，但运行时页面白屏；已配置 DevEco 自动签名（build-profile.json5 的 signingConfigs，密码为本机加密串，仅本机可用），命令行构建自动产出 `entry-default-signed.hap`
- UI 自动化验证：`hdc shell uitest dumpLayout` 取 UI 树（应用 root 在 children[0]，检查 children 是否为空判断页面是否渲染）、`hdc shell uinput -T -c <x> <y>` 模拟点击、`snapshot_display` 截图

## 约束

- 系统资源引用（`sys.symbol.*`/`sys.color.*`）先在 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/id_defined.json` 中核实名称存在性再用
- rawfile 演示曲目文件名约定 `demoXX_歌手 - 歌名.wav`，由 `MusicLibrary.fillFromFileName` 解析；重新生成见 git 历史（python3 合成脚本）
