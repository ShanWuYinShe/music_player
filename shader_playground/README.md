# Shader Playground · 本地 shader 调试器

在电脑浏览器里实时编辑、编译、预览 `music_app/entry/src/main/cpp/shaders/`
下的 GLSL ES 1.00 fragment shader，调试完再回到手机构建。**磁盘上的源文件
就是项目里那份**，改完保存后下次跑构建自然生效（构建期 CMake 读源文件 → 写
`shader_src.h` → 打包进 `libentry.so`）。

## 启动

需要 Python 3（macOS 自带）：

```bash
cd /Users/liyou/work/music_player
python3 -m http.server 8791
```

打开 <http://127.0.0.1:8791/shader_playground/> 即可。

> 端口 8791 是任选的，只要不和 music_server（默认 8790）冲突就行。

## 功能

- **左侧 4 个 preset 文件**（fractal / pan / aurora / mirror），点击切换
- **GLSL 编辑器**：实时编辑，保存即重编译（可关）。可改任意 fragment 文件
- **音乐律动参数滑杆**：seed / bpm / beat / bass / treble / transition，
  数值定义与 `common/VisualizerCore.ets` 完全一致
- **🥁 触发节拍**：手动叠加一个 beat 脉冲，方便看 shader 对节拍的响应
- **🎲 随机 seed**：模拟"切歌"，验证不同种子的画面差异
- **内部分辨率滑杆**：对应手机的 `2/3 渲染比例`，调到 1.0 看全分辨率画质
- **目标帧率滑杆**：默认 30fps，对齐手机 displaySync
- **截图**（按钮 / 快捷键 S）：保存当前画面为 PNG
- **实时错误浮层**：编译/链接失败显示完整 log，不打断渲染
- **FPS 计数 + 时间显示**

## 快捷键

- `Cmd/Ctrl + S`：强制重编译当前文件
- `Space`：暂停/恢复渲染（暂停时画面冻结在最后一帧）
- `S`：截图
- `Esc`：关闭错误浮层
- `1` / `2` / `3` / `4`：直接切换 preset
- 点击预览画布：循环切换到下一个 preset

## 与移动端的一致性

工具内 WebGL2 渲染管线与 `cpp/visualizer.cpp` 完全一致：

- 4 个 GLSL ES 1.00 fragment shader 直接从
  `music_app/entry/src/main/cpp/shaders/*.frag` 读
- GLSL ES 1.00 → WebGL2 兼容仅做最小化 patch：
  - 删掉 `#version 100`
  - `texture2D` → `texture`，`attribute` → `in`，`varying` → `out`/`in`
  - 顶点 vs 输出 `out vec2 vUV`，片段 vs 显式声明 `out vec4 fragColor`
- 反馈 FBO ping-pong + 内部分辨率（默认 0.67×）+ GL_LINEAR 上屏，
  与 `visualizer.cpp` 的 `kRenderScale` / `SwapFbo` / blit pass 一一对应
- 音乐律动参数来自与 `VisualizerCore.ets` 完全等价的 JS 实现
  （FNV-1a 种子 / `synthSpectrum` / `beatEnvelope` / `bpmFromSeed`）

## 与移动端的差异（仅工具方便性，不影响内容）

- 编辑器里的代码改动只影响浏览器预览，**不会自动写回磁盘**。
  按"⤺ 还原磁盘"按钮可丢弃编辑器改动，回到原始源文件
- 关闭"保存即重编"复选框后，编辑时不会触发重编（适合一次性粘贴大段代码）
- 截图按钮把当前画布内容导出为 PNG；移动端没有此功能

## 调试流程建议

1. 浏览器打开 <http://127.0.0.1:8791/shader_playground/>
2. 左侧选要调的 preset（默认 fractal）
3. 改右栏 GLSL 文本，工具自动重编并实时预览
4. 误改乱了按"⤺ 还原磁盘"
5. 满意后保存（在 macOS Finder / VS Code 等直接编辑对应 `.frag` 文件），
   下次跑 `hvigorw` / `ohpm` 构建时 CMake 会读最新源文件

## 端口选择

- 8790：默认 music_server 端口（避免冲突）
- 8791：默认 shader_playground 端口
- 选其它端口也可，只是不与上述冲突即可
