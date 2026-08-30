# pan.frag — 热炒菜锅水滴动力学（v10 · 独立可移植）

照片级 GLSL ES 1.00 片段着色器，模拟真实热炒菜锅上的水滴动力学：
黑碳钢锅底 + 同心圆燃气加热纹 + 锅心红热 + 水珠沸腾翻滚 + 飞溅 + 白烟。

源码：`music_app/entry/src/main/cpp/shaders/pan.frag`（已 commit 至 main 分支）。
手机端走 `gen_shader_header.py` 注入公共库后编译；playground 走 `glslPatch.ts`。
本文件是文档/使用说明，可独立交付。

## 独立可移植最小依赖

把 `pan.frag` 嵌入其他项目时，从 `common.glsl` 注入以下函数（GLSL ES 1.00）：

| 函数 | 用途 | 是否可替换 |
|------|------|------------|
| `float hash11(float n)` | 1D 哈希（精度安全的 fract 系） | 不可（精度用 mediump sin 会崩） |
| `float hash21(vec2 p)` | 2D 哈希 | 同上 |
| `float vn(vec2 p)` | 值噪声（双线性插值 + smoothstep） | 不可（手写 simplex/perlin 太重） |
| `float fbm(vec2 p)` | 4 倍频 fbm + 旋转消网格 | 可换 `perlin` / `simplex` |
| `float wander(t, scale, seed)` / `wander2` / `wanderBi` | 混沌驱动 | 可改 `noise1d` |
| `mat2 rot(float a)` | 2D 旋转 | 不可 |
| `vec2 sceneUV(vec2 center)` | 宽高比修正场景坐标 | 视项目定 |
| `float aspectRatio()` | 当前画面宽高比 | 视项目定 |
| `float nowSec()` | uT(毫秒) → 秒 | 视项目定 |
| `float seedHash()` | uSeed → [0,1] | 视项目定 |
| `vec3 filmic(vec3 x)` | ACES 近似（亮部滚降） | 可换 `Reinhard` / `filmic_ACES` |

如果用 HLSL：所有 `texture2D` → `tex2D`，`vec2/vec3` → `float2/float3`，`varying`/`gl_FragColor` →
按目标语言调整；函数语义不变。

## Uniform 输入（按现有 playground / 端侧约定）

| uniform | 类型 | 含义 | 默认值 |
|---------|------|------|--------|
| `uT` | float | 时间（毫秒） | 实时 |
| `uSeed` | float | 随机种子（u32，原始设备 ID 之类） | 12345678 |
| `uRes` | vec2 | 渲染分辨率（px） | canvas 尺寸 |
| `uBeat` | float | 节拍能量 [0,1] | 0 |
| `uBass` | float | 低频能量 [0,1] | 0 |
| `uTreble` | float | 高频能量 [0,1] | 0 |
| `uTransition` | float | preset 切换淡入 [0,1] | 1.0 |
| `uPrev` | sampler2D | 上一帧画面（feedback 余晖用） | — |

`vUV`（varying）：片元 UV，[0,1]²。

## 关键参数（按效果分类）

### 锅体几何（一般不用动）

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `PAN_FILL` | 0.42 | 0.35~0.50 | 锅半宽（占屏宽 84%） |
| `PAN_SQUASH` | 0.75 | 0.60~0.85 | y 压扁（俯视透视） |
| `PAN_CENTER` | (0, -0.03) | 略下移 | 锅心位置 |
| `BOWL_RADIUS` | 1.30 | 1.10~1.50 | 球冠半径：越小越深锅 |
| `BOWL_DARK` | 0.30 | 0.15~0.40 | 锅心聚油压暗 |
| `BOTTOM_NEAR` | 0.92 | ≥0.85 | 底缘半径（近侧）——**回归保护** |
| `BOTTOM_FAR` | 0.58 | ≤0.65 | 底缘半径（远侧）——**回归保护** |
| `WALL_W` | 0.28 | 0.20~0.35 | 内壁环带宽度 |
| `OUTER_W` | 0.10 | 0.08~0.15 | 外壁环带宽度 |

### 锅底材质（v10 黑碳钢核心）

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `PAN_DIFF` | 0.55 | 0.40~0.70 | 漫反射占比（黑碳钢哑光主项） |
| `PAN_SPEC` | 0.30 | 0.15~0.45 | 镜面强度（黑碳钢低镜面） |
| `BRUSH_PERTURB` | 0.045 | 0.02~0.08 | 拉丝扰动（黑碳钢极轻） |
| `ALBEDO_BASE` | 0.07 | 0.05~0.10 | 锅底反照率基色 |
| `HEAT_TINT` | 0.55 | 0.30~0.80 | 红热混入强度（>0.7 温度生效） |
| `FLAME_BLUE` | 0.30 | 0.10~0.50 | 灶圈蓝光混入强度（0.4~0.7 温度） |

要"亮锅"（不锈钢）参考：PAN_DIFF 0.18、PAN_SPEC 0.72、ALBEDO_BASE 0.14、HEAT_TINT 0.0。

### 温度场（v10 新增）

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `HEAT_RING_FREQ` | 28.0 | 15~40 | 同心圆加热纹频率（每单位多少环） |
| `HEAT_RING_DRIFT` | 0.20 | 0~0.50 | 加热纹慢漂速度（锅热时纹路游动感） |
| `HEAT_RING_K` | 0.18 | 0.10~0.30 | 加热纹反照率调制深度 |
| `HEAT_CENTER_BIAS` | 0.35 | 0.20~0.50 | 锅心温度偏置（同心圆纹偏向锅心热） |
| `BUBBLE_DARKEN` | 0.55 | 0.30~0.80 | 接触处小气泡暗化强度 |
| `BUBBLE_FREQ` | 80.0 | 40~150 | 接触处小气泡密度 |

### 水滴群

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `DROPLET_COUNT` | 44 | 20~80 | 水滴总数（性能瓶颈之一） |
| `SATELLITE_FROM` | 30.0 | — | 卫星滴起始 index（前面是主滴） |
| `R_MAIN_MIN` / `R_MAIN_MAX` | 0.014 / 0.075 | — | 主滴半径区间（帕累托） |
| `R_SAT_MIN` / `R_SAT_MAX` | 0.010 / 0.030 | — | 卫星滴半径区间 |
| `LIFE_BASE` | 7.0 | 3~15 | 寿命常数项（秒） |
| `LIFE_K` | 1150.0 | 500~2000 | 寿命的 r² 系数（d² 蒸发定律） |
| `GROW_PHASE` / `GROW_MIN` | 0.025 / 0.10 | — | 生长相位 / 最小生长比例 |

### 水滴形状（v9 不规则类球体）

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `WOB_SMALL_AMP` | 0.05 | 0~0.10 | 小珠谐波振幅 |
| `WOB_BIG_AMP` | 0.20 | 0.10~0.30 | 大珠谐波振幅 |
| `WOB_SIZE_LO` / `WOB_SIZE_HI` | 0.060 / 0.240 | — | 大小珠过渡区间 |
| `WOB_STRETCH` | 0.40 | 0.0~0.60 | 定向拉伸（泪滴形）幅度 |
| `WOB_TURN` | 0.32 | 0~0.50 | 拉伸方向慢转速率 |
| `WOB_BOIL_AMP` | 0.50 | 0.20~1.00 | **v10 沸腾变形振幅系数** |

### 水滴动力学

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `HEAT_JITTER` | 0.06 | 0.02~0.15 | 受热震动幅度（半径 ±HEAT_JITTER 脉动） |
| `HEAT_DRIFT` | 11.0 | 5~20 | 热斑漂移周期（秒） |
| `BOIL_KICK` | 0.12 | 0.05~0.25 | **v10 沸腾半径脉动幅度**（"咕嘟咕嘟"翻腾） |
| `BOIL_RATE` | 4.5 | 2~8 | **v10 沸腾主频率**（Hz） |
| `PANIC_FROM` | 0.93 | 0.85~0.98 | 濒死起始 lifeK |
| `PANIC_BOOST` | 5.0 | 2~8 | 濒死加速 |
| `PANIC_HOP` | 0.28 | 0.10~0.40 | 濒死弹跳幅度 |
| `SIZZLE_FROM` | 0.90 | 0.85~0.95 | 沸腾翻滚起始 lifeK |
| `SIZZLE_AMP` | 3.0 | 1~5 | 沸腾翻滚幅度 |
| `TREMBLE_AMP` | 0.026 | 0.01~0.05 | 位置颤动 |
| `TREMBLE_BASS` | 1.6 | 1~3 | bass 颤动增益 |
| `WANDER_NORM` | 1.55 | 1.0~2.0 | 漫游归一化 |
| `SPEED_STRETCH` | 0.22 | 0.10~0.30 | 运动方向拉伸 |
| `BOWL_GATHER` | 0.58 | 0.30~0.80 | 凹底聚拢比例 |
| `ORBIT_RATE` | 0.18 | 0.05~0.40 | 绕锅心盘旋速率 |
| `ORBIT_RATE_K` | 0.30 | 0.0~0.50 | 盘旋速率差异 |

### 表面判定与材质

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `ISO_LO` / `ISO_HI` | 0.85 / 1.15 | — | 场→表面阈值 |
| `CONTACT_DARKEN` | 0.50 | 0.30~0.70 | 接触阴影强度 |
| `AO_DARKEN` | 0.16 | 0.08~0.30 | AO 阴影 |
| `REFRACT_LEN` | 0.28 | 0.15~0.40 | 折射取样偏移 |
| `FOCUS_GAIN` | 0.60 | 0.30~1.00 | 内部聚光 |
| `LENS_GAIN` | 0.70 | 0.50~0.90 | 内部反射（压住"水银球"感） |
| `RIM_DARK` | 0.30 | 0.20~0.50 | 内缘压暗 |
| `GLINT_GAIN` | 2.0 | 1.0~3.0 | 窗光针尖高光 |
| `ABSORB_R` | 0.8 | 0.3~1.5 | 折射吸收系数 |
| `CRESCENT_GAIN` | 0.70 | 0.3~1.2 | 背光新月 |
| `SPARKLE_GAIN` | 1.8 | 0.8~2.5 | 灯泡闪烁 |
| `DROP_DIFF` | 0.10 | 0.05~0.20 | **v9 水珠漫反射** |
| `BULB_GLOW` | 0.35 | 0.20~0.60 | **v9 灯泡泛光高光** |
| `RIM_LIGHT` | 0.22 | 0.10~0.40 | **v9 薄缘透光** |
| `IRID_PATH_NM` | 1500.0 | 800~2500 | 薄膜干涉光程差上限（nm） |
| `IRID_GAIN` | 0.55 | 0.30~0.80 | 牛顿环虹彩强度 |
| `IRID_FALLOFF` | 22.0 | 10~40 | 虹彩环带宽度 |
| `CAUSTIC_GAIN` | 0.52 | 0.30~0.80 | 接触处焦散环 |

### 蒸汽 / 飞溅 / 收尾（v10 重点）

| 常量 | 默认 | 推荐范围 | 说明 |
|------|------|----------|------|
| `STEAM_ALPHA` | 0.55 | 0.30~0.80 | 锅口蒸汽浓度 |
| `STEAM_RISE` | 0.50 | 0.30~0.80 | 上升速度（屏/秒） |
| `STEAM_LOCAL_GAIN` | 0.30 | 0.10~0.50 | **v10 接触处白烟浓度**（每颗水珠周围） |
| `SPLASH_GAIN` | 0.8 | 0.3~1.5 | **v10 飞溅星芒强度**（濒死期溅射） |
| `SEED_SPREAD` | 173.0 | — | seed 散布系数（多通道随机） |

## 性能说明

- 单 pass fragment，DROPLET_COUNT 是循环瓶颈：44 滴对应 608×1344 内部半分辨率
  ~25ms/帧；手机端 NAPI 节流 25ms（30fps）。降到 30 滴省 30%，降到 60 滴多 35%。
- field() 循环里做的事：6 个 hash + 2 个 sin + 2 个 mix + 元球场累加 + 5 项角向谐波
  + 定向拉伸 + sizzle 噪声 + wander 漂移。GLSL ES 1.00 mediump 精度足够（无除 0 风险）。
- tempField() 一次 fbm + 一次 sin + 一次 smoothstep = 锅底逐像素成本 ~0.5ms。
- 飞溅星芒用高频值噪声（cost ≈ 0.2ms/像素）；要更高质量飞溅需几何 shader 单独 pass。
- 白烟（localSteam）用 fbm 二次调用（cost ≈ 0.5ms/像素）；低端机可改 vn 降级。

## 集成示例（WebGL2 GLSL 3.00）

```glsl
// 顶点着色器：全屏三角形，传 UV
#version 300 es
in vec2 aPos;
out vec2 vUV;
void main() {
    vUV = aPos * 0.5 + 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}

// 片段着色器：粘贴本 pan.frag 主体，公共函数 inline
// （手机端的 glslPatch.ts 已经做了 GLSL ES 1.00 → 3.00 自动转换，
//  playground 内可用 source 走同一管线）
```

如果用 Three.js ShaderMaterial：

```js
const mat = new THREE.ShaderMaterial({
    vertexShader: vertSrc,
    fragmentShader: panFragSrc,  // 完整内容
    uniforms: {
        uT: { value: 0 },
        uSeed: { value: 12345 },
        uRes: { value: new THREE.Vector2() },
        uBeat: { value: 0 },
        uBass: { value: 0 },
        uTreble: { value: 0 },
        uTransition: { value: 1 },
        uPrev: { value: null },
    },
});
```

每帧：更新 uT / uRes，按音频更新 uBeat/uBass/uTreble，preset 切换更新 uTransition，
把上一帧画面绑到 uPrev 走余晖反馈。

## 调参建议（按需求类型）

**"看起来像真实热炒"（默认）**：当前参数即可。

**"水珠更密集"**：`DROPLET_COUNT` 60；`R_MAIN_MIN` 0.010 / `R_MAIN_MAX` 0.060
（小珠多）；`BOWL_GATHER` 0.45（更聚拢锅心）。

**"水珠更大更醒目"**：`DROPLET_COUNT` 20；`R_MAIN_MAX` 0.110；`BOIL_KICK` 0.20
（剧烈翻滚）；`SPLASH_GAIN` 1.2（飞溅明显）。

**"锅面加热纹更明显"**：`HEAT_RING_K` 0.30；`HEAT_CENTER_BIAS` 0.50（锅心更红）；
`HEAT_RING_FREQ` 35（环数更密）。

**"白烟更浓"**：`STEAM_ALPHA` 0.80；`STEAM_LOCAL_GAIN` 0.50。

**"性能优先"**：`DROPLET_COUNT` 24；`BUBBLE_FREQ` 40（气泡稀疏一点省 fbm）；
`WOB_BIG_AMP` 0.15（角向谐波项减幅）。

## v10 已知遗留

- 飞溅粒子是单 pass fragment 内的"星芒"近似，不是真正的粒子系统（需要几何
  shader 或单独 pass）；要"真飞溅"建议后续拆分层。
- 锅心红热在低亮度显示器上不容易看出（HEAT_TINT 0.55 + ALBEDO_BASE 0.07 =
  RGB(0.022, 0.004, 0.0014) 已经很暗）；可调大 HEAT_TINT 到 1.0 强制红热。
- 灶圈蓝光在白天环境下不明显（环境天空本就是蓝灰）；要突出可调大 FLAME_BLUE。
- chromium headless 渲染下锅心偏暗（46 lum vs 真 GPU 预期 60~80），是 WebGL 亮
  度域差异，端侧真 GPU 渲染会更接近实拍参考图。

## 验证记录（v10 commit）

- 测试：5 files / 46 tests 全过（一致性 + glslPatch + 回归保护）
- 编译：playground ts + shader 拷贝成功；gen_shader_header.py 端侧转换通过
- 量化（chromium 同环境对比 v9 → v10）：
  - 锅心 86.6 → 47.0 lum（-46%，黑碳钢生效）
  - 远壁 57.0 → 27.8 lum（-51%，黑碳钢生效）
  - 亮斑数 28 → 33（+18%，飞溅星芒 + 白烟贡献）