# 项目进度（music_player）

> 快照态文档。每轮迭代收尾必须更新「已完成 / 当前状态 / 待办」三段；
> 流水账写同目录 `YYYY-MM-DD.md`，长期技术约定写 `MEMORY.md`。
> 换会话开工前先读本文件 + 最近几天的日志。

最后更新：2026-08-29 23:59

---

## 一、已完成

### 检查点（已提交 main @ 5956836）

- **common.glsl 公共库 + kaleido 工具链落地**：playground(glslPatch.ts) 与端侧
  (gen_shader_header.py) 逐字节一致注入「注入头之后、场景源之前」，行号可映射回
  common.glsl；mirror.frag 被 kaleido.frag 取代；playground 迁移 bun→pnpm（vitest）。
- **验证**：vitest 35/35、build、biome lint 全绿；无头 Chrome 4 preset 编译成功 29~30fps。

### fractal / pan / aurora 重做（已提交 c00995f / ff743b0 / 2c667f0）

- fractal：对数极坐标八度流 + KIFS×Julia 双形态；pan：拉丝不锈钢+不规则水珠；
  aurora：直绘结构化帘幕取代反馈雾。各自验证闭环通过后提交。

### kaleido 对数极坐标重写 + wander 混沌驱动（本轮，待提交）

- **新需求（chaoset 2026-08-29 23:24）**：pan/aurora → 照片级质感；
  fractal/kaleido → 混沌非重复（永不重复、单调非线性变化）。
- **wander 入库 common.glsl**：整数时间格 hash11 + smoothstep 插值的时域随机游走
  （wander/wander2/wanderBi），数学无周期，取代 sin 驱动；注入头 highp 精度无忧。
- **kaleido 架构推翻重来**（chaoset 拍板）：旧反馈深潜的双线性重采样必糊镜像结构
  （bright 87~96% + 粉绿雾）。新版 = fractal 同款对数极坐标八度流直绘：
  每八度环独立身份（环号 hash：重数 3~11/旋向/纹样密度/色相/增益），
  D_n↔C_n 模式 morph，五纹样 winner-take-most，环旋转有界随机游走（过零换向），
  镜片缝线+环缘亮边，拖尾仅 0.30 对齐流速。
- **验证**：lum 0.15~0.20 / sat 0.52~0.69 / bright 11~23% 全带内；稳定性 1.76× ✓；
  闪烁中位 0.033 最大 0.063 ✓；光流 0.50 oct/s ✓；vitest 35/35、build、lint、
  4 preset 编译 29fps、C++ 桩编译全绿。

## 二、当前状态（进行中）

执行顺序（任务表）：~~kaleido 收尾~~ → kaleido 混沌化（已并入重写）→
fractal 混沌化 → pan 照片级 → aurora 照片级 → 复测提交 → UI 双主题 → 端侧同步。

- kaleido 重写已完成待提交（提交后即检查点）。
- 下一步：fractal 混沌化（Julia c 有界游走、KIFS 参数 wander、
  Julia↔燃烧船↔Tricorn 连续 morph、重数对 wander；八度周期结构保留）。
- 待做判据脚本：`shader_novelty.mjs`（60s 长采样帧间距离矩阵，
  混沌驱动应无周期性相似度回升）。

## 三、待办

1. **fractal 混沌化**（见上）。约束：八度周期结构不动（无缝深潜根基）。
2. **pan 照片级**：球冠折射(放大倒像+RGB色差)、方向性接触影(光左上→影右下)、
   焦散亮弧随滴形、各向异性拉丝高光、胶片颗粒+bloom+暗角。
3. **aurora 照片级**：1D切向光柱+垂直剪切、氮蓝紫下缘常驻、地面反射极光(泛绿)、
   星色温差异、ISO色噪+轻bloom。
4. **UI PowerAMP 化**（深浅双主题）：色彩系统、首页、播放页、迷你条、
   SongItem、菜单/队列。
5. **端侧同步**：4 场景打包决策落地、C++ 桩编译、AGENTS.md/README 更新。
6. 未验证项：**真机编译**（需 DevEco + 设备，`hvigorw` 要 `JAVA_HOME=DevEco jbr`）。

## 四、接手须知（详见 `MEMORY.md`）

- `uT` 单位毫秒；hash 用 fract 系不用 sin；`uSeed` 先 `*1e-7` 再 hash。
- `hue2rgb(h)=0.5+0.5cos(TAU*(h+vec3(0,.33,.67)))`：0=红 / .17=紫 / .33=蓝 /
  .5=青 / .67=绿 / .83=黄（不是 HSL）。
- 改 shader 后必须走完整验证清单，不允许「看着差不多」就交付。
- playground 命令：`pnpm --dir /Users/liyou/work/music_player/shader_playground test|build|lint`，
  先摘 shim 环境变量（`env -u NODE_OPTIONS -u CODEBUDDY_BROKERED_FS_HOOK_ENABLED`），
  pnpm 用绝对路径 `/Users/liyou/.nvm/versions/node/v26.2.0/bin/pnpm`。
- 验证脚本：`NODE_PATH=~/.workbuddy-ai/binaries/node/workspace/node_modules \
  ~/.workbuddy-ai/binaries/node/versions/22.22.2/bin/node \
  ~/.workbuddy-ai/binaries/node/workspace/shader_{verify,stats,stability,flow}.mjs`
  （需 dev server 8791/8792 在跑）。
