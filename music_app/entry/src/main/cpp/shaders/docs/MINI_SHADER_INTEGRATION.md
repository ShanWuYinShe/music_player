> **[历史方案,已回退]** 本文描述的迷你条 shader 集成方案未最终落地
> (mini.frag 未进 SHADER_SCENES 构建;迷你条频谱 UI 已于 2026-09 移除;
> renderFrame 签名也已变更为不含 playing 的 11 参形态)。仅供对照阅读,
> 勿按本文实施。

# mini.frag 端侧集成方案 —— 迷你条从 Canvas 2D 迁移到 shader 管线

## 背景

`VisualizerView.ets` 的 `mini` 变体目前用 `CanvasRenderingContext2D` + 双离屏
ping-pong（CPU/合成器路径）画金色频谱柱——这是全部可视化里唯一非 shader
的实现。`mini.frag`（已 commit）已把同一视觉翻译成 GLSL ES 1.00 fragment
shader，playground 验证通过（柱阵渲染 + 动画正常）。

本方案说明如何把端侧 mini 也接入 XComponent(SURFACE) + GLES3 shader 管线，
让全部可视化统一走 GPU shader。

## 现状（VisualizerView.ets）

```
build():
  if variant === 'mini':
    Canvas(displayCtx) ... onReady(initOffscreens)   // ← 2D Canvas，非 shader
  else:
    XComponent({ id: 'viz_full', type: SURFACE, libraryname: 'entry' })  // ← shader
```

`renderFrame`（mini 路径，~每帧）：
```
bars = synthSpectrum(seed, t, 24)      // CPU 合成 24 条频谱
active.clearRect → prev 叠加 → drawBars → transferToImageBitmap → drawImage 上屏
```

## 方案（三处改动）

### 1. VisualizerView.ets —— mini 分支改用 XComponent

把 mini 分支的 `Canvas` 换成 `XComponent(SURFACE)`（与 full 同款），variant
差异只体现在**渲染哪个场景**：

```
build():
  Stack {
    XComponent({ id: variant === 'mini' ? 'viz_mini' : 'viz_full',
                 type: XComponentType.SURFACE, libraryname: 'entry' })
      .width('100%').height('100%')
  }
  onLoad((ctx) => napiRegister(ctx, this.variant))   // variant 传入 NAPI
```

帧驱动：mini 不再走 Canvas 离屏，而是 `entry.renderFrame(t, seed, playing,
beat, bass, treble, presetLock, transition)`（与 full 同一 NAPI，variant 由
`presetLock`/额外参数指定 mini 场景）。

### 2. visualizer.cpp —— 加 mini 固定场景（不参与 preset 轮换）

- `SHADER_SCENES`（CMakeLists）追加 `mini.frag`（4 个场景源一起编译进
  shader_src.h；`gen_shader_header.py` 的 `DEFAULT_SCENE_FILES` 同步追加）。
- `VisualizerCore.ets` 的 preset 轮换**保持 3 个**（fractal/pan/aurora）——
  mini 是 variant 决定的固定场景，不占轮换槽。`pipelineConsistency.test.ts`
  的三端一致性校验只覆盖轮换 3 场景，mini 作为"第 4 个源文件"单独管理。
- NAPI `renderFrame` 增加 variant 参数（0=full 轮换 / 1=mini 固定场景）：
  - variant=0：`program[pendingPreset]` 渲染（现状）
  - variant=1：固定用 `program[3]`（mini.frag），忽略轮换状态
- mini 的分辨率：迷你条卡片较小，内部渲染分辨率可降低（如 1/2），
  与 full 的 608×1344 策略一致；上屏线性放大即可。

### 3. 参数说明（mini.frag 的 uniform）

| uniform | 含义 | mini 取值 |
|---------|------|-----------|
| uT | 播放时钟（ms） | 同 full |
| uSeed | 曲目种子（u32） | 同 full（hash11 内已缩 [0,1]×997 防精度丢失） |
| uRes | 渲染分辨率 | 迷你条内部分辨率 |
| uBeat/uBass/uTreble | 音频量 | beat 用于节拍抬升；bass/treble 可选 |
| uPrev | 上一帧（反馈拖尾） | 必须接（复刻 double-buffer 50% 混合） |
| uTransition | preset 切换 | mini 固定场景恒 1.0 |

## 验证步骤（端侧）

1. `python3 tools/gen_shader_header.py` 确认 4 场景进 shader_src.h
2. hvigorw 构建 libentry.so
3. 真机/模拟器：进迷你条，确认金色频谱柱随音乐律动（柱高、节拍抬升、
   拖尾），与原来 Canvas 版观感一致
4. 对比项：柱阵覆盖下半区、两端包络渐隐、节拍脉冲抬升

## 回退方案

mini.frag 是**新增文件**，VisualizerView 的 Canvas 分支代码保留（git 历史
可回退）。若 shader 版 mini 观感不满意，仅还原 VisualizerView.ets 的 mini
分支即可，不影响 full 三个 preset。

## 遗留

- mini 的频谱是 shader 内确定性合成（复刻 synthSpectrum 结构），与
  VisualizerCore 的 JS 合成**不逐点一致**（hash 算法不同）——视觉律动感
  一致但波形不同。若要逐点一致，需把 synthSpectrum 的 hash01 用 GLSL 复刻
  （JS imul 32bit 位运算，GLSL ES 1.00 无位运算——需 ES 3.00 或改算法）。
- 迷你条若需要半透明背景（卡片圆角外透明），XComponent surface 的 alpha
  通道配置需按卡片样式调（当前 surface 是不透明）。
