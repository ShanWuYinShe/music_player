# music_player 长期记忆

## shader 管线事实
- 源文件 GLSL ES 1.00（`varying`/`gl_FragColor`/`texture2D`），位于
  `music_app/entry/src/main/cpp/shaders/`：visualizer.vert / blit.frag / common.glsl /
  fractal.frag / pan.frag / aurora.frag / kaleido.frag。**不要直接写 WebGL2 源**——
  playground(glslPatch.ts) 与端侧(gen_shader_header.py) 各自把 GLES1.00 转译到
  WebGL2 / GLES3，规则等价，改一处须同步另一处。
- `shader_src.h` 是构建产物（gen_shader_header.py 生成），**别手写**；playground 与端侧读同一份磁盘源。
- `common.glsl` 共享库，注入「头之后、场景源之前」；行号换算
  `报错行 − 12(头) − common行数 = 场景行号`；两端注入内容须逐字节一致。
- `mirror.frag` 已被 `kaleido.frag` 取代。
- `visualizer.cpp`：一场景一 program；`SceneLocs` 建时缓存 uniform；presetLock 越界回落 0；无 `uPresetSel`。

## 约定
- 临时文件放项目根 `.workwork/`（已 gitignore），**别用 /tmp**。
- `uT` 单位毫秒；`uSeed` 可到 4e9（先 `×1e-7` 再 hash）；hash 用 fract 系，**别用 sin**（大 seed 移动端精度崩）。
- `hue2rgb` 色轮（**不是 HSL**）：0=红 / .17=紫 / .33=蓝 / .5=青 / .67=绿 / .83=黄。
- KIFS 自相似比 `s` 别超 ~2.3（再大吸引子稀疏近黑）；着色用轨道驻留密度。
- 端侧只打包 `CMakeLists.txt` 的 `SHADER_SCENES`（当前 `aurora.frag`）；增删场景须同步 4 处：
  `SHADER_SCENES` / `VisualizerCore.ets` `PRESET_COUNT` / `VisualizerView.ets` `PRESET_COUNT` / `VIZ_PRESET_NAMES`。

## 运动 / 结构经验
- **混沌非重复运动用 `wander(t,scale,seed)`/`wander2`/`wanderBi`**（common.glsl，整数时间格 hash11+smoothstep，数学无周期），**别用 sin 叠加**（准周期）。
- 万花筒/镜类须**直绘**：反馈深潜（uPrev 逐帧缩放+旋转）双线性重采样必糊成雾。
- 逐环/逐滴抽签参数须**压亮度方差**：色度归一只压不抬(lum>REF 压回)；纹样按覆盖率归一化增益+`pow(I,0.75)`；增益区间压窄(0.82+0.18)；基底微光兜暗相位。**别用 uPrev 抽头做自动曝光伺服**（结构尺度≥抽头间距→亮度估计噪→逐帧增益抖=闪烁）。

## 验证（改 shader 后）
- 包管理器只用 pnpm；跑前**摘 shim 环境变量**
  `env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED`，**别用后台**（前台+长 timeout）。
  bun 已连根拔（vitest；pnpm-lock.yaml；35 测试全过）。
- 无头 Chrome 脚本在 `~/.workbuddy-ai/binaries/node/workspace/`，**写死连 `localhost:8792`**
  → 须先 `pnpm run build` 再 `pnpm run preview`（8791 仅人工调试）；跑前 `lsof` 清掉 8791/8792 遗留 server。
  - `shader_verify.mjs`：编译状态 + 截图(→`.workwork/shader_preset_N.png`)
  - `shader_stats.mjs`：目标带 lum .10~.25 / bright 10~30% / sat .4~.7（pan lum≈.12 正常）；
    **dark 恒 0 = 过曝强信号**（查全屏加法项改调制）；sat>.9 过饱和
  - `shader_stability.mjs <preset>`：亮度起伏应 <1.8×
  - `shader_flow.mjs <preset>`：闪烁(中位<.02/最大<.15) + 径向光流(对数极坐标匹配，行位移=八度/秒)
- 端侧：`gen_shader_header.py` 生成头 + `.workwork/cpp_stub` 桩 `g++ -fsyntax-only`；
  `glBindVertexArray` 收 `GLuint`，传 `0` 非 `nullptr`。

## 分形深潜经验
- 别「每层换参数」制造变化（跳变=闪一下+平移）；变化靠**连续坐标慢漂移**。
- 自相似周期对齐屏幕径向跨度（fractal `NOCT`，rho .02~.7 约 5~6 八度）；错位→整屏周期明暗（实测 4.2×→对齐 1.65×）。
- 逃逸场「集内」别写反：`sm=N` = N 次迭代**从未逃逸**；写成 `1−sm/N` 会把整个外围铺雾、画面全灰。
