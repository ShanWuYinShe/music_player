# music_player 长期记忆

## 可视化 shader 管线（当前形态）

- **单一 shader 源**：`music_app/entry/src/main/cpp/shaders/`（visualizer.vert /
  blit.frag / common.glsl / fractal.frag / pan.frag / aurora.frag / kaleido.frag），
  按 GLSL ES 1.00 书写（`varying`/`gl_FragColor`/`texture2D`，uniform 每行一个声明）。
  `shader_playground/` 预览与手机端构建读的是同一份磁盘文件。
- **`common.glsl` 是场景共享公共库**：两端各自读盘后走同一套置空/替换管线，
  注入到「头之后、场景源之前」；行号换算
  `报错 − 头(12) − common 行数 = 场景行号`，两端注入内容必须逐字节一致。
  `mirror.frag` 已被 `kaleido.frag`（无尽万花筒）取代。
  （2026-08-29 21:40 注：这轮改动**在工作区未提交、尚未验证**，
  最新现状一律看 `PROGRESS.md`。）
- **端侧只打包 `cpp/CMakeLists.txt` 的 `SHADER_SCENES`**（当前仅 `aurora.frag`）。
  增删场景要同步四处：`SHADER_SCENES`、`VisualizerCore.ets` 的 `PRESET_COUNT`、
  `VisualizerView.ets` 的 `PRESET_COUNT`、`VIZ_PRESET_NAMES`。
- **`shader_src.h` 是构建产物**：`cpp/tools/gen_shader_header.py` 在构建期把
  GLSL ES 1.00 转成 GLES3 头（注入头 12/4/5 行、声明整行置空以对齐行号、
  texture2D→texture、varying→in/out、gl_FragColor→fragColor），
  规则与 `shader_playground/src/glslPatch.ts` 完全等价，改一处要同步另一处。
  **手写的那份已删**，别再往源码树里加同名头文件（会遮蔽生成的）。
- `visualizer.cpp`：一场景一个 program，`SceneLocs` 在创建时缓存 uniform 位置，
  presetLock 越界回落 0，无 `uPresetSel`。

## 约定

- `uT` 单位是**毫秒**；uSeed 可到 4e9（先 `uSeed*1e-7` 再 hash）。
- hash 用 fract 系，**不要用 sin**（大 seed 在移动端精度崩）。
- `hue2rgb(h)=0.5+0.5cos(TAU*(h+vec3(0,.33,.67)))` 色轮：
  0=红 / .17=紫 / .33=蓝 / .5=青 / .67=绿 / .83=黄（不是 HSL）。
- KIFS 自相似比 s 别超 ~2.3，再大吸引子稀疏到画面近黑；着色用轨道驻留密度。

## 验证清单（改 shader 后）

1. `cd shader_playground`，**包管理器只用 pnpm**，且必须摘掉 shim 环境变量
   （否则 fs.symlink 被 `[CODEBUDDY_BROKER_DENY]` 硬拒）：
   `env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED pnpm test`，
   build / lint 同理。**不要用后台任务跑**，前台 + 长 timeout。
2. 无头 Chrome（脚本在 `~/.workbuddy-ai/binaries/node/workspace/`，需 dev server 8791/8792）：
   - `shader_verify.mjs`：编译状态 + 截图
   - `shader_stats.mjs`：亮度/饱和度/明暗占比（目标带：lum 0.10~0.25、
     bright 10~30%、sat 0.4~0.7；pan 例外 lum≈0.12 正常）
   - `shader_stability.mjs <preset>`：多个时间点的亮度起伏（应 <1.8×）
   - `shader_flow.mjs <preset>`：**闪烁 + 径向光流**——这是"看起来在不在前进"的
     客观判据。先把图重采样成对数极坐标（行 = −log2 r，列 = 角度），再做二维
     位移匹配，行位移即径向流速（八度/秒，正=向外扩张=在往里飞）。
     直接对整幅图做缩放匹配会被"静态径向包络"（中心辉光/暗角/中心淡出）带偏，
     对"角度平均后的径向剖面"做相关也会被多重对称结构抹平——必须用对数极坐标。
3. 端侧 C++：生成头 + `/tmp/cpp_stub` 桩 `g++ -fsyntax-only`。
   GLES3 的 `glBindVertexArray` 收 `GLuint`，传 `0` 不是 `nullptr`。
完整流程见技能 `shader-pipeline-verify`。

## 分形深潜的两条硬经验

- **别用"每层换参数"制造变化**：参数按层号（整数八度序号）跳变 = 每隔几秒画面
  突变一次，用户看到的就是"闪一下 + 平移一点"。变化要靠**连续坐标上的慢漂移**。
- **图案的自相似周期要对齐屏幕径向跨度**（fractal 里 `NOCT`，屏幕 rho 0.02~0.7
  约 5~6 个八度）：周期取太大，窗口滑过周期不同位置时"集内面积"忽大忽小，
  整屏周期性忽明忽暗（实测起伏 4.2× → 对齐后 1.65×）。
- 逃逸时间场里"集内"别写反：`sm=N` 表示 N 次迭代内**从未逃逸**（=集内），
  写成 `1−sm/N` 就变成"逃逸极快的外围"，等于给整个外围铺雾、画面全灰。
