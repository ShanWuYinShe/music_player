---
name: music-app-shader-pipeline
description: music_app 音乐可视化 shader 管线：GLSL 源码位置与构建期转头、场景三处同步注册、shader_playground 同源调试器、防闪烁规范、pan/aurora 性能架构、帧驱动与体感输入（uTilt/uSpin/uKick）、真机踩坑。触发：改 entry/src/main/cpp/shaders 下 GLSL；增删可视化场景；调 renderFrame/displaySync 帧驱动；接入传感器体感；排查可视化黑屏/闪烁/掉帧；改 shader_playground。
---

# music_app 音乐可视化 shader 管线

## 音乐可视化 shader 管线

### 源码书写与构建

- **shader 源码在 `entry/src/main/cpp/shaders/`**（按 GLSL ES 1.00 书写：`varying` / `gl_FragColor` / `texture2D`，uniform 每行一个声明）。
- CMake 构建期经 `entry/src/main/cpp/tools/gen_shader_header.py` 转成 GLES3 头文件 `shader_src.h`（生成到构建目录、不进源码树；注入头 15/4/5 行，编译报错行号减去它即源文件行号）。

### 场景注册（三处同步）

- **手机端与 `shader_playground/` 当前都启用 `fractal.frag` / `pan.frag` / `aurora.frag` / `spectrum.frag` 四场景**，顺序由 `CMakeLists.txt` 的 `SHADER_SCENES`、`VisualizerCore.ets` 的 `VIZ_PRESET_NAMES` 与 playground `presets.ts` 共同定义，`PRESET_COUNT` 从名称清单派生。
- 增删场景须同步这三处，`pipelineConsistency.test.ts` 会做跨端一致性检查。

### 调试器同源

- 本地调试器 `shader_playground/`（仓库根下，Vite+TS，pnpm-lock.yaml 唯一权威，`pnpm dev` → 8791）读同一份磁盘 GLSL，用 `src/glslPatch.ts` 做等价转换跑 WebGL2，**预览与端侧永远同源**。

### 防闪烁规范（沿用至今）

- 色相演化 ≤0.003/ms（~3 分钟一圈）；音频量（beat/bass/treble）只驱动亮度/尺寸，绝不进色相；饱和度适中；真硬阈值一律 smoothstep 软化。

### 性能架构（pan v17 / aurora v15 起）

- **pan 状态纹理**：每颗水珠状态是每帧常量，主 pass 前先以 20×4 小视口（`uStateMode=1`）用**同一份 pan.frag** 把状态写进 RGBA16F 纹理（依赖 `EXT_color_buffer_float`/`_half_float`，缺失时 C++ 在 #version 后插 `#define PAN_NO_STATE_TEX 1` 编译逐像素回退变体——状态计算抽成 `dropState()` 单一实现，两路径零分叉；状态纹理尺寸常量 `kPanStateTexW/H` 与 pan.frag 的 `DROPLET_COUNT/PAN_STATE_ROWS`、playground 的 `PAN_STATE_W/H` 三处一致，有测试锁定）。
- **pan 锅外裁剪**：锅椭圆外像素按 `panMask/wallMask/outerMask` 掩模跳过 field/bg/水珠着色（约 70% 像素白算的根除）。
- **aurora**：水面倒影只算最近主帘，软特征 fbm 用 common.glsl 的 `fbm3`。
- **平滑切换**：风格变化启动 1.5s 交叉淡化（presetTrans 0→1 经 NAPI 第 8 参传入，shader 里场景增量乘 smoothstep(uTransition) 渐入，旧画面不清空、靠反馈层衰减余晖自然消散——基于上一画布的 crossfade）；切风格触发反馈纹理重建时先把旧帧 blit 拷贝到新尺寸（保留交叉淡化的旧画面）。
- **按场景比例降采样**：内部降采样、上屏线性放大柔化（`visualizer.cpp` 的 `kPresetScale`：fractal/spectrum 0.5、pan 0.45、aurora 0.33，与 playground `presets.ts` 的 renderScale 逐项对齐、pipelineConsistency.test.ts 锁定；pan/aurora 逐像素成本高且形态柔软，更低比例视觉近无损）。

### 帧驱动与体感输入

- 帧驱动 displaySync(30fps)→NAPI `renderFrame(t,seed,playing,beat,bass,treble,presetLock,transition,tiltX,tiltY,spin,kick)`，**返回 bool**（是否真的绘制了——场景 program 由子线程共享 context 异步编译，未就绪时返回 false，ArkTS 侧据此显示"编译中占位"（恒暗底+柔光呼吸，首帧后 300ms 淡出），避免切到可视化时空屏）。
- 绘帧间隔按场景取 `VisualizerCore` 的 `VIZ_FRAME_INTERVAL_MS`（默认 25ms；aurora 40ms=25fps——慢场景无感，真机 GPU 超载时同步 renderFrame 会阻塞 UI 线程，场景级降帧治本）。
- beat/bass/treble 仅驱动局部元素亮度/尺寸，速度类恒定。
- **uTilt**（设备姿态）：VisualizerView 订阅 ORIENTATION 传感器（免权限），gamma→x（左右横滚→水平）、beta→y（前后俯仰→垂直）经 VisualizerCore.normalizeTilt（±4° 死区、±40° 满量程）+低通传入，驱动全场景 uv 相机视差。
- **uSpin**（滚转）：alpha 相对进入舞台时基准的差分经 wrapAngleDelta+normalizeSpin（±5° 死区、±60° 满量程）+低通，驱动全场景滚转（common.glsl 的 motionSpinKick，最大 ±20°）。
- **uKick**（冲击）：LINEAR_ACCELEROMETER 去重力线加速度经 accelKickLevel（阈值 1.5m/s²、满量程 8m/s²）attack、逐帧指数 decay（600ms），需 `ohos.permission.ACCELEROMETER`，被拒降级为 0。
- 三者只进几何/亮度，不进色相/速度；传感器不可用时保持 0 退化为无体感。

### 真机踩坑（勿重蹈）

- ① XComponent 回调须在 NAPI Init 经 `exports.__NATIVE_XCOMPONENT_OBJ__` 早期注册（onLoad 才注册 surface 已创建不回放）；**重进播放页时 XComponent 是新实例，early 注册的对象已失效、created 事件早于 onLoad 的 fallback 注册被丢——EGL 永不初始化（第二次进入必黑屏）**，已加 `OH_NativeXComponent_RegisterSurfaceShowCallback` 兜底（show 晚于 onLoad 注册触发、带 window，VizOnSurfaceShow 幂等补初始化）；destroy 后 `gTexW/gTexH` 必须清零，否则新 context 复用已失效纹理 id。
- ② GLSL `#version 300 es` 须首行（由生成脚本注入，源文件不要写）。
- ③ 过曝防御 0.86+各层≤0.15+半分辨率。
- ④ EGLNativeWindowType 经 uintptr_t 中转。
- ⑤ 节流 25ms<33.3ms(30fps)。
- ⑥ 沉浸全局恒定全屏布局。
- ⑦ 每个场景一个 GL program，uniform 位置在创建时缓存，不要每帧 glGetUniformLocation。
