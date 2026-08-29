# 项目进度（music_player）

> 快照态文档。每轮迭代收尾必须更新「已完成 / 当前状态 / 待办」三段；
> 流水账写同目录 `YYYY-MM-DD.md`，长期技术约定写 `MEMORY.md`。
> 换会话开工前先读本文件 + 最近几天的日志。

最后更新：2026-08-29 21:40

---

## 一、已完成

### 基线（已提交至 main @ 626c7e8）

- **shader 源文件单一来源**：新建 `music_app/entry/src/main/cpp/shaders/`，
  playground 预览与端侧构建读同一份磁盘文件（GLSL ES 1.00 书写）。
- **四个场景落地**：`fractal`（对数极坐标 + 周期 Julia 逃逸时间，严格自相似深潜）、
  `pan`（莱顿弗罗斯特水滴，元球场融合）、`aurora`（5 层 fbm 帘幕 + 银河星空 + 山脊）、
  `mirror`（uPrev 反馈万花筒）。
- **端侧构建期生成**：`cpp/tools/gen_shader_header.py` 在 CMake 期把 GLSL ES 1.00
  转成 GLES3 头 `shader_src.h`；与 `shader_playground/src/glslPatch.ts` 规则等价
  （注入头 12/4/5 行、置空保行号、texture2D→texture、varying→in/out、
  gl_FragColor→fragColor）。手写的 `cpp/shader_src.h` 已删（会遮蔽生成物）。
- **端侧只打包极光**：`SHADER_SCENES = aurora.frag`；ArkTS `PRESET_COUNT` 10→1
  （`VisualizerCore.ets` + `VisualizerView.ets`）、`VIZ_PRESET_NAMES=['全屏极光']`。
- **验证闭环**：shader 编译成功（SwiftShader 29fps）；`pnpm test` 26/26、build、lint 全绿；
  端侧生成头 + `/tmp/cpp_stub` 桩 `g++ -fsyntax-only` 通过（曾抓出
  `glBindVertexArray(nullptr)` 真 bug，GLES3 要传 0）。
- **客观画质判据脚本**（在 `~/.workbuddy-ai/binaries/node/workspace/`，需 dev server 8791/8792）：
  `shader_verify.mjs`（编译+截图）、`shader_stats.mjs`（lum/sat/明暗占比）、
  `shader_stability.mjs`（时间起伏）、`shader_flow.mjs`（对数极坐标位移匹配 →
  径向流速八度/秒 + 闪烁）。目标带：lum 0.10~0.25、bright 10~30%、sat 0.4~0.7、
  起伏 <1.8×。fractal 实测：闪烁 0.010/0.139、光流 0.60 oct/s、起伏 1.65×。
- **清理**：三个 worktree 与对应分支全部删除，只剩主仓 main。
- 该闭环已沉淀为技能 `~/.workbuddy-ai/skills/shader-pipeline-verify/`。

## 二、当前状态（**未提交，在改**）

工作区有大量未提交改动（`git status --short` 可见 17 个文件，+1090/−527），
主题是「**公共库抽取 + mirror → kaleido 换场景**」：

| 改动 | 内容 |
|---|---|
| `shaders/common.glsl`（新，110 行） | 场景共享函数库 |
| `shaders/kaleido.frag`（新，201 行） | 新增「无尽万花筒」 |
| `shaders/mirror.frag`（**已删**） | 被 kaleido 取代 |
| `aurora.frag` / `fractal.frag` / `pan.frag` | 大量改写（各 250~310 行 diff），应是在改为复用 common.glsl |
| `tools/gen_shader_header.py`（+47） | 支持注入 common.glsl，与 playground 保持一致 |
| `CMakeLists.txt` | `file(GLOB ...)` 增加 `*.glsl`，把公共库纳入依赖与生成 |
| `shader_playground/src/glslPatch.ts`（+82） | 新增 `countLines` / `fragInjectedLines` / `mapFragErrorLine`：公共库插在注入头之后、场景源之前，行号换算支持定位到 common.glsl |
| `presets.ts` | preset 3 改 `kaleido.frag`「无尽万花筒」；导出 `COMMON_FILE='common.glsl'` |
| `vite.config.ts` | `SHADER_FILES` 加 `common.glsl`、去掉 `mirror.frag`；MIME 加 `.glsl` |
| `renderer.ts`（+79）、`main.ts`、`errors.ts` | 读盘/注入/common 传递链路 |
| `tests/glslPatch.test.ts`（+53） | 覆盖行号映射 |
| `PlayerPage.ets` | 可视化菜单 bindMenu（**与 shader 需求无关**，此前遗留） |

**状态判定：改到一半，尚未验证。** 未跑过 test / build / lint，也没跑过
shader 编译与像素统计，kaleido 的画质完全未知。行号映射是新引入的复杂度，
最易出错的地方（注入头 + common 行数必须两端逐字节一致）。

## 三、待办

1. **跑通验证闭环**（`shader-pipeline-verify` 技能）：
   `pnpm test && pnpm run build && pnpm run lint`（**注意摘掉 shim 环境变量**：
   `env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED`，且不要放后台跑）。
2. 无头 Chrome 跑 4 个 preset：`shader_verify` 看编译是否全过，
   `shader_stats` 看 kaleido / 改写后的 aurora·fractal·pan 是否落在目标带。
3. `shader_stability` + `shader_flow` 复测 fractal（换 common 抽取后是否退化）。
4. 端侧：重新生成 `shader_src.h` + `/tmp/cpp_stub` 桩 `g++ -fsyntax-only`，
   确认 common 注入后 C++ 侧仍能编。
5. **决定端侧打包哪些场景**：目前仍只有 `aurora.frag`，若 kaleido 达标
   需同步 `SHADER_SCENES` + 两处 ArkTS `PRESET_COUNT` + `VIZ_PRESET_NAMES`。
6. 更新 `music_app/AGENTS.md` / `shader_playground/README.md`：改述 common.glsl
   注入机制与「mirror → kaleido」。
7. 处理未提交改动：先确认 `PlayerPage.ets` 是否与 shader 工作一起提交
   （chaoset 此前说它与本次需求无关）；index.lock 若再卡住需先排查。
8. 未验证项：**真机编译**（需 DevEco + 设备，`hvigorw` 要 `JAVA_HOME=DevEco jbr`）。

## 四、接手须知（详见 `MEMORY.md`）

- `uT` 单位毫秒；hash 用 fract 系不用 sin；`uSeed` 先 `*1e-7` 再 hash。
- `hue2rgb(h)=0.5+0.5cos(TAU*(h+vec3(0,.33,.67)))`：0=红 / .17=紫 / .33=蓝 /
  .5=青 / .67=绿 / .83=黄（不是 HSL）。
- 改 shader 后必须走完整验证清单，不允许「看着差不多」就交付。
