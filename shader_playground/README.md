# Shader Playground · 本地 shader 调试器

在电脑浏览器里实时编辑、编译、预览 `music_app/entry/src/main/cpp/shaders/`
下的 GLSL ES 1.00 fragment shader，调试完再回到手机构建。**磁盘上的源文件
就是项目里那份**，改完保存后手机端跑构建时 CMake 读源文件 → 写
`shader_src.h` → 打包进 `libentry.so`。

前端工程基于 Vite + TypeScript，编辑器为 CodeMirror 6（GLSL 语法高亮）。
shader 源文件由 Vite 插件以 `/shaders/*` 直接透传磁盘目录（dev 中间件 +
preview 中间件 + build 期快照拷贝三种形态），预览与手机端构建永远同源。

## 启动

依赖 pnpm（仓库只用这一个包管理器，首次需 `pnpm install`）：

```bash
cd shader_playground
pnpm install
pnpm run dev       # 开发服务器，http://localhost:8791/
```

其它命令：

```bash
pnpm test          # 纯函数单测（律动合成 / GLSL 补丁 / 错误格式化）
pnpm run lint      # biome 检查
pnpm run build     # tsc 类型检查 + 产物构建（dist/）
pnpm run preview   # 预览构建产物，http://localhost:8792/
```

> 若 `pnpm install` 报 `[CODEBUDDY_BROKER_DENY]`（WorkBuddy 沙箱注入的 fs shim
> 把 `fs.symlink` 的 EEXIST 覆盖流程掐断了），先摘掉两个环境变量再跑：
> `env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED pnpm install`。
> 同时**不要放后台跑**——会把 shell 打死，之后所有命令返回 127。

> 8791 延续旧版端口习惯；8792 给 build 产物预览，均避开 music_server 的 8790。

## 功能

- **左侧 3 个 preset 文件**（fractal / pan / aurora），点击或按 `1`-`3` 切换
- **CodeMirror 编辑器**：GLSL 高亮、行号、撤销历史；编辑即重编译（可关）
- **文件拖拽**：把 `.frag` / `.vert` 从 Finder 拖进窗口即试跑——
  `.frag` 按顺序填入场景槽（从当前槽开始），`.vert` 替换顶点源；
  拖入内容只在会话内生效，不写回磁盘，按「⤺ 还原磁盘」可随时丢弃
- **↻ 重读磁盘**：在 VS Code 等编辑器里改完 `.frag` 保存后，点它重新读取
  当前文件（无需刷新整个页面）
- **音乐律动参数滑杆**：seed / bpm / beat / bass / treble / transition，
  数值定义与 `common/VisualizerCore.ets` 完全一致
- **🥁 触发节拍**：手动叠加一个 beat 脉冲，看 shader 对节拍的响应
- **🎲 随机 seed**：模拟"切歌"，验证不同种子的画面差异
- **内部分辨率滑杆**：对应手机的 2/3 渲染比例，调到 1.0 看全分辨率画质
- **目标帧率滑杆**：默认 30fps，对齐手机 displaySync
- **截图**（按钮 / 快捷键 `S`）：保存当前画面为 PNG
- **实时错误浮层**：编译 / 链接 / 源码问题显示完整诊断日志，
  并给出换算后的源文件行号；任何内部异常也会以可读文案呈现（不会显示 undefined）

## 快捷键

- `Cmd/Ctrl + S`：重编译（编辑器内外都生效）
- `Space`：暂停/恢复渲染（暂停时画面冻结在最后一帧）
- `S`：截图
- `Esc`：关闭错误浮层
- `1` / `2` / `3` / `4`：直接切换 preset
- 点击预览画布：循环切换到下一个 preset

## 与移动端的一致性

> 工具与手机端都启用 3 个 preset 槽（fractal / pan / aurora），
> 顺序由 `src/presets.ts`、`music_app/entry/src/main/cpp/CMakeLists.txt` 的
> `SHADER_SCENES` 和 `VisualizerCore.ets` 的名称清单共同定义。
> `tests/pipelineConsistency.test.ts` 会校验三端顺序、名称和源文件是否一致。

工具内 WebGL2 渲染管线与 `cpp/visualizer.cpp` 完全一致：

- 4 个 GLSL ES 1.00 fragment shader 经 `/shaders/*` 读取
  `music_app/entry/src/main/cpp/shaders/*.frag` 磁盘原件
- GLSL ES 1.00 → WebGL2 兼容仅做最小化 patch（`src/glslPatch.ts`）：
  - 注入 `#version 300 es` 头（精度 / uniform / varying / out 声明）
  - **strip 一律"整行置空"而非删行**，编译器报错行号减去头行数即源文件行号
  - `texture2D` → `texture`、`attribute` → `in`、`gl_FragColor` → `fragColor`
- 反馈 FBO ping-pong + GL_LINEAR 上屏与端侧一致；playground 内部分辨率为 0.67×，
  手机端为固定 0.5×（移动 GPU 性能预算不同，画面逻辑与采样方式不变）
- 音乐律动参数来自与 `VisualizerCore.ets` 完全等价的 JS 实现
  （FNV-1a 种子 / `synthSpectrum` / `beatEnvelope` / `bpmFromSeed`）

## 与移动端的差异（仅工具方便性，不影响内容）

- 编辑器与拖入的改动只影响浏览器预览，**不会写回磁盘**；
  「⤺ 还原磁盘」回到本次页面加载时的磁盘版本，「↻ 重读磁盘」重新读取
- 关闭"保存即重编"后，编辑不触发重编（适合一次性粘贴大段代码）
- 截图把当前画布导出 PNG；移动端没有此功能

## 调试流程建议

1. `pnpm run dev` 后打开 <http://localhost:8791/>
2. 左侧选要调的 preset（默认 fractal），右栏改 GLSL 自动重编预览
3. 误改乱了按「⤺ 还原磁盘」；在 VS Code 改了磁盘文件按「↻ 重读磁盘」
4. 满意后把改动写回 `music_app/entry/src/main/cpp/shaders/` 对应源文件
   （工具不代写磁盘），下次 `hvigorw` 构建时 CMake 自动打包最新源文件

## 目录结构

```
shader_playground/
├── index.html            # 页面骨架（三栏：参数 / 编辑器 / 预览）
├── vite.config.ts        # /shaders/* 透传插件 + dev/preview/build 配置
├── src/
│   ├── main.ts           # 装配入口：状态、UI 绑定、主循环
│   ├── presets.ts        # preset 清单（与手机端 kVizFragPresets 同序）
│   ├── renderer.ts       # WebGL2 管线：ping-pong FBO / blit / uniform
│   ├── glslPatch.ts      # GLSL ES 1.00 → 3.00 行号对齐补丁
│   ├── audioSim.ts       # 与 VisualizerCore.ets 等价的律动纯函数
│   ├── errors.ts         # 统一诊断格式化（杜绝 "undefined" 报错文案）
│   ├── editor.ts         # CodeMirror 6 封装（GLSL 高亮 / ⌘S）
│   ├── dnd.ts            # 窗口级文件拖拽
│   └── style.css
└── tests/                # vitest 单测（纯函数层）
```
