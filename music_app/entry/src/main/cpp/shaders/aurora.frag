// aurora.frag：照片级极光（发射谱分层 × 磁天顶光线汇聚 × HDR 直绘）。
//
// v15.1 真机性能（用户真机反馈：切到极光整个 app 卡顿——GPU 超载时同步
//   renderFrame 阻塞 UI 线程）：反馈余晖从 RGB 三次采样（色散）降为单次
//   采样（色散量 0.0009 本就低于感知阈值，省 2 次/像素纹理采样）；配合
//   端侧渲染比例 0.40→0.33 与场景帧间隔 25fps（慢流动场景无感），总负载
//   再降约四成。
//
// v15 性能优化（用户反馈：全屏极光严重卡顿——保证效果的前提下优化）：
//   1. **水面倒影只算最近主帘**：v11 注释一直写"倒影只算主帘（depth=1.0）
//      + 宽光晕，避免 2 帘翻倍"，代码却调了完整 auroraEmission（两帘全部
//      重算）——注释与实现不符的浪费。v15 对齐注释意图：倒影区只算 fi=1、
//      depth=1 的最近帘（水面保留最亮结构的镜像），倒影成本减半，观感
//      与 v11 设计初衷一致。
//   2. **软特征 fbm→fbm3**：绸带蜿蜒有机扰动、英雄褶 fold、银河云絮×2、
//      尘带、远山脊线、水岸线——全是低频柔软载体，4 倍频降到 3 倍频
//      （common.glsl 的 fbm3）每次省 1 档 vn，肉眼不可辨；射线/存在感等
//      结构性 vn 全部保持原样。
//
// v14 氛围增强（用户："增强氛围感"）：WIDE_GAIN 0.07→0.10（光带周围弥散
// 光晕）、GROUND_GLOW 0.10→0.16（雪原被极光照亮）、STAR_GAIN 1.25→1.45
// （星空氛围）、SKY_HORIZON 微提（地景衔接）、新增低空大气绿弥散 AIRGLOW
// （极光漫射点亮低空一层淡绿余晖）。暗天空纪律保持（sky_top ≈10.9 仍暗）。
//
// v13 绸带重构（用户："真实的极光不是竖直射线光幕，是多变的像绸带一样"）：
//   v12 把"薄带"改成"光幕"（大片竖直射线）又错了——真实极光是**绸带**：
//   细长柔软、持续蛇形游动的丝带。核心改动：
//   1. **流动蜿蜒中心线**：蜿蜒相位**持续前进**（-t*RIB_FLOW），不是 v12 的
//      wander 慢漂（那等于"固定弧带偶尔换姿势"）。三频蜿蜒（大 S 主蜿蜒 +
//      反向次级 + 高频细蜿蜒）+ fbm 扰动——绸带像被风吹动的丝绸一样蛇形
//      游动，形态持续变化。
//   2. **带体高度 0.20**（薄带 0.13 < 绸带 < 光幕 0.34）：柔软渐隐，不是
//      "线"也不是"墙"。
//   3. **绸带折叠**：沿带大尺度明暗起伏（RIB_FOLD）——"被拧转"的立体感/
//      厚度，这是绸带区别于"布"和"幕"的关键。
//   4. **射线弱化**：BODY_RAY_W 0.30 / HERO_GAIN 0.70 / RAY_GAIN 1.00——
//      射线退为绸带内部的柔和纹理，蜿蜒形态才是主体。
//   保留：涡旋 curl、方向随机、四段色阶、品红爆发、传播波、水面倒影、
//   底缘自然边界（v12 已删锐利亮线）。
//
// v12 完全重构（用户反馈："你还是放不下这个破线——极光需要完全重构"）：
//   病根是 v7 以来的"薄弧带 + 底缘锐利亮线"——BORDER_W 那条下缘亮线
//   （EDGE_GAIN=2.6 的"刀刃"）是 v5 就反馈过的"画上去的线"，之后不但没删
//   反而一路强化，让极光读作"一条细带子 + 一条画线"，而非真实极光。重构：
//   1. **删底缘锐利亮线**：去掉 border / eI / EDGE_GAIN / BORDER_W / 粉紫下
//      缘线——极光的底缘是光幕 body 的自然亮度边界（presence² 让底缘有明
//      暗断续，实拍里亮段/暗段自然过渡），不是画上去的线。
//   2. **薄带 → 光幕**：BODY_H 0.13→0.34（带体向上渐隐更缓）——真实极光是
//      "大片竖直射线光幕"，不是细带子。峰值改由英雄褶 + 竖直射线承担
//      （BODY_GAIN 1.0→0.75 光幕更柔，不洗屏）。
//   3. 射线仍解耦、S 弯/涡旋/方向随机/四段色阶/品红爆发/传播波/水面倒影
//      全部保留——这些是对的，重构只动"线"和"带体高度"。
//
// v11 相对 v10 的水面倒影（方案遗留项：图2/3 的水面反射是沉浸感大杀器）：
//   **水面**：近侧山脊改为水岸（远山脊保留为剪影），水面区域（水岸线以下）
//   用**镜像坐标重算同一场极光**（把帘幕循环包成 auroraEmission 函数，主
//   极光与倒影共用——水面反射的就是天上那场，不是另一条假带）。波纹：
//   两频横向偏移扰动 + 亮度调制；衰减：离岸越远越暗（exp）+ 水面吸收偏
//   蓝绿。成本控制：倒影只算主帘（depth=1.0）+ 宽光晕，避免 2 帘翻倍。
//
// v10 相对 v9 的方向随机化（用户反馈："极光方向不应固定竖直——电子入射
// 方向不固定，与磁场作用后出现位置/方向都不确定"）：
//   **整场方向角 dirAngle**（wander 慢漂，±31°）：把"带坐标系"旋转后再算
//   弧带与射线——极光本体可以从任意角度横穿画面（不只是水平弧带），射线
//   汇聚方向随带倾斜。磁天顶游走幅度加大（APEX_WANDER 0.22→0.35 / 0.18→
//   0.30，汇聚点位置更多变）。背景（夜空/银河/星空/山脊）保持固定，只有
//   极光本体旋转——空间感不破坏。
//
// v9 相对 v8 的补充（方案 docs/AURORA_V8_PLAN.md 中列为下轮的 G4）：
//   **涡旋 curl**（图3 签名形态——弧带局部打结旋转，最有生命感的形态）：
//   底缘线在涡旋影响区叠加"角向螺旋波"（2 臂 + 随距离缠绕 + 时间旋转），
//   射线坐标同步扭转（同一份影响场，卷曲处射线绕涡旋弯而不是直柱硬插），
//   涡旋区存在感/发射抬升（卷曲处更亮更实）。防假关键：中心位置与生命
//   周期都由 wander 慢漂——每次出现的位置不同、出现→增强→消散有完整
//   生命周期；幅度 0.22 是"打结"级（远大于 WOB 0.075 的波浪），旋转速度
//   恒定（音频永不进速度）。
//
// v8 相对 v7.1 的"贴实拍"改进（参考 4 张实拍照片，方案全文见
// docs/AURORA_V8_PLAN.md；差距清单 G1~G8）：
//   1. **带内四段色阶（G1）**：v7.1 是"底绿→中青→顶红"单调渐变，实拍是
//      "底缘白绿→主体黄绿→上部橙红→带顶衰减"四段（白芯 = 亮线饱和，
//      上部 = 氧红/蓝紫混入）。altK 分段 mix 重写。
//   2. **亮芯白化增强（G1）**：起点 0.75→0.55、强度 0.8→0.9——实拍最亮
//      芯部几乎全白（传感器饱和）。
//   3. **爆发品红层（G2）**：图2 的 substorm 冠冕里品红/粉红是主导色。
//      v7.1 的 EMIT_PINK 只在下缘弱出现；v8 加整带品红层（act>0.55 起
//      效，沿射线亮度调制）——爆发时色变而不只是亮度变化。
//   4. **S 弯大弧（G3）**：实拍大弧带是 S 形（波长 ≈1 屏宽），不是对称
//      抛物线。v8 加 S_AMP×sin 大尺度弯 + ARC_K 1.35→0.90（抛物线减弱、
//      让位给 S 弯）。
//   5. **竖直褶皱增强（G5）**：WOB 0.030→0.075——图4 证明底缘波浪褶皱
//      真实存在（v6 的问题是"整体摇曳"，不是"褶皱本身"）。
//   6. **射线解耦（G6，本轮最重要）**：v7.1 射线是帘内纹理（rays/hero/
//      needles 都乘 body），永远无法比帘体亮。v8 拆三层：帘体基础
//      （含弱射线）+ 英雄褶独立亮层 + **独立射线层**（衰减高度 3.5H
//      ——射线穿过带顶延伸到暗天空，图4 观感）。射线扫动：STRIPE_DRIFT
//      0.9→1.6 + 射线相位沿高度倾斜（上端相位偏移 = 视觉扫动）。
//   7. **涌动改传播波（G8）**：surge 从"随机亮度脉冲"改为"沿弧带传播
//      的亮度波"（速度恒定，方向单一）——动态有方向性。
//   8. **地平线低空辉光（G7）**：雪原/水面被极光照亮（图4 雪地泛绿）。
//      山脊上方加贴地辉光层，随极光总亮度起伏。
//   9. **星空微增（C2）**：三层星亮度 ×1.25。
//   未做（下轮）：涡旋 curl（G4）——实现成本高且容易做假，值得单独
//   一轮打磨。
//   回归测试（v7.1 三条断言）不受影响：dneg 断崖 / body 含 dneg /
//   whiteK 起点 0.55 ≥ 0.5 合规。
//
// v7 相对 v6 的形态重做（用户反馈："撑死了算一个窗帘在天上飘着，根本
// 就不是极光"——v6 的"波浪帘幕"几何本质是**布料窗帘**：大褶皱、整片
// 发光、整体摇曳。真实极光的标志性形态是**弧带**，不是织物）：
//   1. 一条主弧带（+一条淡次带），薄而高悬：底缘锐利、向上 ~0.3 屏高
//      内快速渐隐——BODY_H 0.36→0.13、BORDER_W 0.014→0.010、EDGE_GAIN
//      →2.6（下缘是最亮元素，帘体只是它的余晖）。
//   2. 弧线几何：底边 = 干净抛物线（中部拱起，两端坠到山脊后）+
//      轻倾斜 + 小幅度慢蜿蜒——不是大幅 fbm 织物褶皱（WOB 0.115→0.030、
//      ARC fbm 项砍到 0.12，换成 ARC_K 抛物线）。
//   3. 射线近竖直细直：RAY_BEND 0.38→0.10（真实弧带的射线沿磁场线，
//      近乎笔直；v6 的大弯曲是"布料褶皱"感的另一半来源）、条纹频率
//      110/190 更细。
//   4. 2 帘而非 3 帘：一场极光只有一条主弧（+可能一条淡副弧）；上方
//      暗天空、下方暗天空 + 山脊——光带被黑暗包围才是极光的观感。
//   5. 出没行为：substorm 时主弧整体增亮、底缘泛紫、慢蜿蜒幅度抬升；
//      音频只进亮度。
//
// v6 相对 v5 的形态返工（用户反馈："完全不像极光，是从天而降的笔直光线，
// 像演唱会探照灯"——v5 颜色/谱线对了，但**几何语言**还是光束而不是帘幕）：
//   1. 光柱去"探照灯化"：磁天顶 1.42→2.90（远天顶 = 近平行光柱，不再从
//      一个近点扇形发散——扇形光束正是探照灯阵列的观感）；条纹频率同步
//      放大补偿视角压缩。
//   2. 光柱随帘波弯曲：条纹坐标叠加 RAY_BEND×(帘边波位移)——真实极光的
//      射线跟着帘幕褶皱走（同一片电离层沿场线发光），不再是切割帘幕的
//      刚直直线。
//   3. 杀掉"扫描光束"：stream 垂直亮斑振幅 0.20→0.10、再放缓——沿光柱
//      上下跑的亮斑是演唱会灯效的另一半来源。
//   4. 帘幕读作"帘"：褶皱幅度 0.055→0.115（肉眼可见的波浪底边）、大弧
//      0.34→0.44、帘体高度 0.42→0.54、增益 1.15→1.55，倾斜角加慢游走
//      （整帘缓慢摇曳）；英雄柱/针柱增益下调——帘体主导，光柱退为纹理。
//   5. 帘体内垂直色渐变：底边黄绿 → 中层青 → 顶部暗红（海拔分层本来就
//      是渐变，v5 的"绿帘+独立红层"读起来是两条色带而不是过渡）。
//   6. 曝光与占比重调（同环境对比 v5 后确认：v5 本身也满屏洗白——这才是
//      "不像极光"的最大单一因素）：4 帘→3 帘、帘体高度 0.42→0.36（顶部
//      留出暗天空）、帘体增益 1.15→0.85、宽光晕 0.28→0.12、存在感下限
//      0.55→0.35（帘间有暗隙）。真实极光照片里暗天空占主导，亮帘带只
//      是画面的一部分——明暗对比才是"极光感"的本体。
//
// v5 相对 v4 的"真实感"返工（v4 及更早都还停在"插画"档，逐项把错的东西改对）：
//   1. 光柱去"梳子化"：旧 150/260 硬值噪声造出跨屏 ~70 条锐利细纹（百叶窗/
//      琴键感），是"假极光"的头号来源。v5 降到 40/70 中频、幂律从 2.4 收到
//      1.6，并叠一道大尺度 fbm 褶皱（少数几道亮褶）——光柱宽、软、亮度平滑
//      渐变，像真的帘幕而不是竖条纹。
//   2. 颜色校准：绿 (0.30,1.0,0.45)→(0.36,0.92,0.20) 黄绿（557.7nm 不是霓虹
//      绿）；下缘 N2+ 粉紫 → 蓝紫 (0.52,0.30,1.0)（391.4/427.8nm 是蓝紫，不是
//      粉）。真实极光的颜色是"稳"的，霓虹感一出来就露馅。
//   3. 下缘"去画线化"：BORDER_W 0.0045→0.014、EDGE_GAIN 4.6→2.2——旧的是
//      一条画上去的亮线，真实下缘是有界但柔软的过渡；宽光晕 WIDE_GAIN 0.14→
//      0.28，极光是"大面积柔和辉光"，不是细线。
//
// v4 相对 v3 的两处真实感补齐：
//   1. 垂直涌动：亮斑沿磁力线上下移动（"跳舞的帘幕"），活跃爆发时更快
//      更明显——v3 只有水平漂移，缺了极光最标志性的纵向"舞动"。
//   2. 前景山脊剪影 + 极光绿色上光：极光发生在 100–300km 高空，没有
//      前景它就是屏幕上的色块；山脊把它推到天上、给出纵深与尺度，且
//      爆发时山脊顶缘被极光染绿（光真的会照亮地面）。
//
// v3 相对 v2 的"照片感"差距清单（v2 是结构对的"插画"，v3 按实拍照片逐项补）：
//   1. 发射谱而不是色轮：557.7nm 氧绿 (0.28,1.0,0.42) 是唯一主体色；
//      630nm 氧红是**更高海拔的独立发光层**（沿同一条磁力线向上抬升、
//      更宽更慢——不是对绿光插值)；N2+ 粉紫只在活跃下缘以亮线形态出现
//      （picket fence）。颜色稳、形态变——真实极光从不彩虹。
//   2. 磁天顶汇聚：所有光柱沿"汇聚到磁天顶的直线族"分布（摄影里放射状
//      收敛的铁轨透视，极光照片的身份证）。光柱坐标 az = atan(q-apex)，
//      同一条线上 az 恒定 → 条纹自动沿场线拉直、向天顶收拢。
//   3. 动态范围：下缘亮线与英雄光柱按 HDR 叠加（单帘峰值可到 3+），
//      经 ACES 滚降——亮而不溢，暗部仍有结构。
//   4. 光柱幂律亮度：pow(hash,3.2) 少数英雄柱 + 大量暗柱，亮度差跨一个
//      数量级（实拍里帘幕永远是有主次的，不是均匀亮带）。
//   5. 下缘锐利：d² 型亮线（σ≈0.008）贴着帘幕基线，活跃时沿亮线泛粉。
//   6. 深度堆叠：远帘暗/细/偏蓝（瑞利散射）/慢，近帘亮/宽/快，线性叠加
//      自然产生纵深。
//   7. 摄影"后期链"：ACES → 天光底色（夜空不是纯黑）→ 亮度加权胶片颗粒
//      （暗部颗粒重）→ 轻暗角。星空/银河/山脊是"锚"，帘幕再亮也盖不穿。
//   8. 行为：wander 慢相位驱动"平静帘 ↔ 活跃爆发"（substorm），爆发时
//      英雄柱增益×3、下缘泛粉、褶皱幅度抬升；beat/bass/treble 只进亮度/
//      幅度/闪烁，永不进速度与色相。
//
// 公共函数（hash/vn/fbm/wander/rot/filmic/dither/…）由工具链从 common.glsl
// 注入，不要在本文件重复定义。

// ---- 反馈（只做轻柔光晕余晖，不参与结构）--------------------------------
const float FB_GAIN = 0.20;         // 反馈增益（>0.35 会拖泥带水盖过直绘）
const float FB_ZOOM = 1.004;        // 采样微胀——余晖微微向外晕开
// v15.1 性能：RGB 三次采样（色散 FB_CHROMA=0.0009）降为单次采样——色散量
// 本就低于感知阈值，省 2 次/像素纹理采样（移动 GPU 带宽敏感）

// ---- 磁天顶（光柱汇聚点，画面上方远处，慢游走）----------------------------
// v6 推到 2.90：远天顶 = 近平行光柱。旧 1.42 离屏上缘不到一个屏高，
// 光柱从近点扇形发散——"演唱会探照灯阵列"观感的几何根源
const vec2 APEX_BASE = vec2(0.02, 2.90);
const vec2 APEX_WANDER = vec2(0.35, 0.30); // v10 0.22/0.18→0.35/0.30：汇聚点
                                           //   游走幅度加大——方向更多样

// ---- 弧带结构（v7：一场极光 = 一条薄弧带，不是飘动的布）---------------------
// 竖屏构图：主弧带底边落在画面中上部 0.10~0.40，中部微拱、两端坠向
// 山脊后；带体极薄（H=0.13，向上约 0.3 屏高内渐隐），下方大段暗天空。
const int CURTAIN_N = 2;            // v7：主弧带 + 一条淡次带（真实"一场
                                    //   极光"只有一条主弧，偶尔带一条副弧；
                                    //   3+ 条叠起来就是"窗帘"）
const float BASE_Y_LO = 0.10;       // 弧带底边区间（画面中上部——极光在天上）
const float BASE_Y_HI = 0.40;
const float TILT_AMP = 0.22;        // 弧带整体倾斜（轻斜跨，不是横着飘的布）
const float TILT_SWAY = 55.0;       // 倾斜角慢游走时标（秒/格；极光变位很慢）
const float WOB_AMP = 0.075;        // 底缘波浪褶皱（v8 0.030→0.075：图4 证明
                                    //   竖直褶皱真实存在；v6 的病根是"整体
                                    //   摇曳"（TILT/ARC 大弯），不是褶皱本身——
                                    //   整体形态仍由 S 弯+抛物线锁定）

// ---- v13 绸带蜿蜒（用户："像绸带一样流动多变"——不是固定弧带/光幕/窗帘）---
// 绸带 = 细长柔软、持续蛇形游动的丝带。蜿蜒相位**持续前进**（-t*flow），
// 不是 wander 慢漂（那等于"固定弧带偶尔换姿势"）；多频叠加 + fbm 扰动
// 产生"被风吹动的丝绸"的复杂蛇形。
const float RIB_AMP = 0.16;         // 绸带蜿蜒主幅度（跨屏蛇形游动）
const float RIB_FLOW1 = 0.16;       // 主蜿蜒流动速度（rad/s；优雅游动）
const float RIB_FLOW2 = 0.10;       // 次级蜿蜒流动速度（反向）
const float RIB_FLOW3 = 0.07;       // 高频细蜿蜒流动速度
const float RIB_FOLD = 0.30;        // 绸带折叠幅度（沿带大尺度明暗起伏，
                                    //   "被拧转"的立体感/厚度）
const float RIB_FOLD_W = 6.0;       // 折叠空间频率

// ---- v9 涡旋 curl（图3 签名形态：弧带局部打结旋转）-------------------------
// 极光涡旋 = 底缘线在某段绕一个缓慢旋转的中心卷 1.5~2 圈——最有生命感
// 的形态。实现：底缘线在涡旋影响区内叠加"角向螺旋波"（极角多臂 + 随
// 距离缠绕 + 时间旋转），射线坐标同步扭曲（跟着带子转），涡旋区发射
// 增强（卷曲处发射更密）。防假关键：中心位置/生命周期都由 wander 慢漂
// （出现→增强→消散，每次位置不同），且幅度大（0.22，"打结"级，不是波浪）。
const float CURL_SIGMA = 0.17;      // 涡旋空间尺度（影响半径，屏坐标）
const float CURL_AMP = 0.22;        // 涡旋幅度（底缘卷曲深度；"打结"级）
const float CURL_ARMS = 2.0;        // 螺旋臂数（2 臂 = 最常见的单涡观感）
const float CURL_WIND = 26.0;       // 缠绕密度（随距离的相位增速，越大圈多）
const float CURL_SPIN = 0.85;       // 旋转速度（rad/s，恒定——速度不进音频）
const float CURL_TWIST = 0.55;      // 射线跟随扭曲幅度（射线跟着带子转）
const float CURL_LIFE = 37.0;       // 涡旋生命周期时标（秒/格；出现→消散）
const float CURL_BOOST = 0.45;      // 涡旋区发射增强（卷曲处更亮）
const float BODY_H = 0.20;          // 带体向上衰减高度（v13 绸带：0.13 薄带
                                    //   →0.34 光幕 →0.20 绸带——比细带高、比
                                    //   光幕矮，柔软渐隐，不是"线"也不是"墙"）
const float RED_LIFT = 0.10;        // 氧红层相对绿层的抬升量（薄带里贴近带顶）
const float RED_H_K = 1.0;          // 氧红层衰减高度 = BODY_H × K
const float STRIPE_FREQ_A = 110.0;  // 射线频率 A（细直射线——弧带内沿磁场
                                    //   线的纹理，真实极光的"身份证"）
const float STRIPE_FREQ_B = 190.0;  // 射线频率 B（次级，更细）
const float STRIPE_DRIFT = 1.6;     // 射线沿带漂移（v8 0.9→1.6：实拍视频里
                                    //   射线"跳舞"的扫动感）
const float RAY_TILT_H = 0.50;      // v8 射线相位沿高度倾斜（上端相位偏移
                                    //   = 射线上端滞后扫动，"跳舞"观感）
const float RAY_BEND = 0.10;        // 射线随带边波的弯曲（真实射线近乎笔直；
                                    //   0.38 的大弯曲 = 布料褶皱感）
const float BODY_GAIN = 0.80;        // 带体增益（v13 绸带：光幕 0.75 基础上微调
                                    //   ——绸带更集中，柔和不洗屏）
const float WIDE_GAIN = 0.10;       // 宽尺度环境光晕（收敛：光带周围只有
                                    //   一丝弥散，不能被光晕糊成一片）

// ---- v8 射线解耦（v13 弱化：射线是绸带内部的柔和纹理，不是主导）-----------
const float BODY_RAY_W = 0.30;      // 帘体基础里的射线权重（v13 0.45→0.30，
                                    //   射线退为绸带内部的细节纹理）
const float HERO_GAIN = 0.70;       // 英雄褶独立亮层增益（v13 0.90→0.70）
const float RAY_GAIN = 1.00;        // 独立射线层增益（v13 1.60→1.00——射线
                                    //   不再主导，绸带的蜿蜒形态才是主体）
const float RAY_H_K = 2.0;          // 射线衰减高度 = H × K（穿过带顶延伸暗天空）
const float RAY_POW = 2.2;          // 射线幂律（少数亮 + 多数暗）
// ---- v8 爆发品红（substorm 冠冕的主导色，图2）-----------------------------
const vec3 EMIT_MAGENTA = vec3(1.00, 0.30, 0.55); // 品红粉（N2 强电离爆发色）
const float MAG_ACT_GAIN = 0.50;    // 爆发品红增益（act>0.55 起效）

// ---- 发射谱色（线性 HDR）----------------------------------------------------
const vec3 EMIT_GREEN = vec3(0.360, 0.920, 0.200);  // OI 557.7nm 黄绿（真实极光偏黄绿，非霓虹绿）
const vec3 EMIT_RED = vec3(0.950, 0.160, 0.100);    // OI 630.0nm 暗红（高层）
const vec3 EMIT_PINK = vec3(0.520, 0.300, 1.000);   // N2+ 427.8/391.4nm 蓝紫下缘（真实是蓝紫，非粉）
const float RED_BASE = 0.06;        // 氧红常驻量（v6 帘体内已有垂直渐变，
                                    //   独立红层退为补充，避免两条色带）
const float RED_ACT = 0.30;         // 活跃时氧红增强量

// ---- 行为相位 --------------------------------------------------------------
const float ACT_SCALE = 71.0;       // substorm 慢相位（秒/格）
const float SURGE_WAVE_FREQ = 1.8;  // v8 传播波空间频率（沿带波长）
const float SURGE_SPEED = 0.9;      // v8 传播波速度（rad/s，恒定方向）
const float GROUND_GLOW = 0.16;     // v8 地平线低空辉光增益（雪原被照亮）
const float AIRGLOW = 0.10;        // v14 低空大气绿弥散（极光漫射点亮低空）
const float STAR_GAIN = 1.45;       // v8 星空亮度增益（照片里星更明显）

// ---- 背景 ------------------------------------------------------------------
// 背景必须比帘幕暗一档（v3 星空/银河抢戏，帘幕淹没）——锚点要，但要收敛
const vec3 SKY_ZENITH = vec3(0.007, 0.011, 0.021);
const vec3 SKY_HORIZON = vec3(0.030, 0.043, 0.062);
const float MW_GAIN = 0.30;
const float RIDGE_FAR_Y = -0.335;
const float RIDGE_NEAR_Y = -0.435;
const float SEED_SPREAD = 173.0;

// ---- v11 水面倒影（图2/3 沉浸感大杀器：水面反射极光）-----------------------
const float WATER_Y = -0.36;        // 水岸线高度（远山脊下方；近侧山脊改为水岸）
const float RIPPLE_AMP = 0.028;     // 波纹横向偏移幅度（镜像坐标扰动）
const float REFLECT_GAIN = 0.50;    // 倒影亮度增益（真实水面反射率 ~5-8%，
                                    //   但夜景长曝光下视觉上更亮——取折中）

// 星层：幂律亮度 + 温度色 + 亮星衍射星芒（摄影衍射Artifact，加一点就够）
vec3 starLayer(vec2 q, float S, float thresh, float ts, float sd) {
    vec2 cell = floor(q * S);
    vec2 pos = fract(q * S) - 0.5;
    float h = hash21(cell);
    if (h < thresh) return vec3(0.0);
    vec2 off = (vec2(hash21(cell + 7.1), hash21(cell + 13.3)) - 0.5) * 0.72;
    vec2 sp = pos - off;
    float d2 = dot(sp, sp);
    float mag = pow(hash21(cell + 29.7), 7.0);   // 幂律：绝大多数肉眼刚可辨
    float twk = 0.72 + 0.28 * sin(ts * (1.3 + 2.6 * hash21(cell + 3.3))
        + hash21(cell + 5.5) * 40.0);
    float star = exp(-d2 * 250.0) * mag * twk;
    // 最亮的一撮加十字星芒
    float spike = step(0.965, hash21(cell + 41.0));
    star += spike * mag * 0.22 * exp(-d2 * 60.0)
        * (exp(-abs(sp.x) * 30.0) + exp(-abs(sp.y) * 30.0));
    float tt = hash21(cell + 61.0);
    vec3 sc = mix(vec3(1.0, 0.80, 0.62), vec3(0.70, 0.80, 1.0), tt);
    sc = mix(vec3(0.94, 0.95, 1.0), sc, 0.7);
    return sc * star;
}

// 帘幕层：返回线性 HDR 发射量。depth 0=最远 → 1=最近。
// azx：伪透视角坐标（条纹近竖直、微微向天顶汇聚），main 里一次算好。
// out wideEnv：宽尺度环境光晕（bloom 解析近似），主循环外统一收。
vec3 curtain(vec2 q, float azx, float fi, float ts, float sd, float depth,
    float act, float beatG, out float wideEnv) {
    float h1 = hash11(fi * 3.77 + sd);
    float h2 = hash11(fi * 7.31 + sd + 5.0);
    float h3 = hash11(fi * 11.9 + sd + 13.0);

    float span = mix(0.62, 1.55, depth);

    // 绸带中心线（v13）：持续流动的蜿蜒——相位持续前进（-t*flow），绸带
    // 像被风吹动的丝绸一样蛇形游动（不是固定弧带）。三频蜿蜒叠加 + fbm
    // 有机扰动 + 轻倾斜。底缘波浪（wobA）是绸带的"褶皱"（柔软，不是锐线）
    float baseY = mix(BASE_Y_LO, BASE_Y_HI, fi / float(CURTAIN_N - 1))
        + 0.03 * sin(ts * 0.05 + fi * 2.2 + h2 * 6.28);
    float tilt = TILT_AMP * (h1 - 0.5) * 2.0
        * (0.55 + 0.75 * wander2(ts, TILT_SWAY, sd + fi * 5.3));
    // 主蜿蜒（大 S，持续流动）+ 次级（反向流动）+ 高频细蜿蜒
    float yc = baseY + tilt * q.x
        + RIB_AMP * span * sin(q.x * 2.0 - ts * RIB_FLOW1 + fi * 2.1 + h2 * TAU)
        + 0.5 * RIB_AMP * span * sin(q.x * 3.1 + ts * RIB_FLOW2 + fi * 4.7 + h1 * TAU)
        + 0.3 * RIB_AMP * span * sin(q.x * 5.3 - ts * RIB_FLOW3 + fi * 1.9 + h3 * TAU)
        + (fbm3(vec2(q.x * 1.3 - ts * 0.020 + fi * 7.7, sd * 0.7)) - 0.5)
            * 0.10 * span;                              // 有机扰动
    // 底缘波浪（绸带的褶皱；幅度随活跃度抬升——不是速度）
    float wobA = WOB_AMP * span * (0.55 + 0.75 * act);
    yc += wobA * sin(q.x * (2.3 + 1.1 * h2) - ts * (0.20 + 0.12 * h3) + fi * 2.1);
    yc += wobA * 0.6 * sin(q.x * (4.9 + 1.6 * h1) + ts * (0.13 + 0.09 * h2) + fi * 4.7);

    // 涡旋 curl（v9，图3 签名形态）：底缘线在涡旋影响区内叠加角向螺旋
    // 波——中心沿带慢漂（wander），生命周期慢起慢落（出现→增强→消散），
    // 爆发期更频繁更强。atan 的多值性由 sin 截断成 2 臂螺旋的"卷曲"
    // 观感；缠绕密度 CURL_WIND 让底缘在涡旋区卷 1.5~2 圈。out 出
    // curlK 供射线扭曲与发射增强复用（同一份影响场，保证三者同相）
    float curlPhase = wander2(ts, 43.0, sd + fi * 17.0);
    float curlX = mix(-0.55, 0.55, curlPhase);
    float curlAct = smoothstep(0.55, 0.85, wander2(ts, CURL_LIFE, sd + fi * 23.0))
        * (0.30 + 0.70 * act);
    float toCx = q.x - curlX;
    float distC = abs(toCx);
    float influ = exp(-distC * distC / (CURL_SIGMA * CURL_SIGMA)) * curlAct;
    float curlK = 0.0;
    if (influ > 0.004) {
        float ang = atan(q.y - (yc + CURL_AMP * span * 0.6), toCx);
        float spiral = sin(ang * CURL_ARMS + distC * CURL_WIND - ts * CURL_SPIN);
        yc += influ * CURL_AMP * span * spiral;
        curlK = influ;
    }

    // 水平存在感：绸带要有明暗断点（强弱起伏），下限 0.25——暗处接近
    // 消失，绸带就不是"一条贴上去的带子"。涡旋区存在感抬升（卷曲处更亮）。
    // v13 叠加绸带折叠（沿带大尺度明暗起伏——"被拧转"的立体感/厚度）
    float presence = 0.25 + 0.75 * smoothstep(0.35, 0.65,
        0.6 * vn(vec2(q.x * 0.55 + fi * 11.0, ts * 0.010 + sd * 0.7))
        + 0.4 * vn(vec2(q.x * 1.7 + fi * 3.0, ts * 0.017 + sd * 1.9)));
    float ribbonFold = 1.0 + RIB_FOLD * sin(q.x * RIB_FOLD_W
        - ts * (RIB_FLOW1 * 1.3) + fi * 3.3 + h2 * TAU);
    presence *= ribbonFold;
    presence = min(1.0, presence + curlK * CURL_BOOST);

    // 射线（v8 解耦三层）：细直软柱沿磁场线近乎笔直。条纹相位沿高度
    // 倾斜（RAY_TILT_H × dd）——射线上端相位滞后 = 视觉"扫动/跳舞"。
    // 大尺度 fbm 褶皱（少数几道亮褶）+ 中频值噪声。treble 驱动闪烁。
    // v9：射线坐标在涡旋区跟着带子扭转（与底缘同一份影响场 curlK 同相
    // ——卷曲处射线绕涡旋弯曲，不是直柱插进涡旋）
    float ddRay = max(q.y - yc, 0.0);   // 带内高度（供射线相位倾斜用）
    float rayX = azx + RAY_BEND * (yc - baseY - tilt * q.x);
    if (curlK > 0.004) {
        rayX += curlK * CURL_TWIST
            * sin(distC * CURL_WIND * 0.7 - ts * CURL_SPIN + ddRay * 1.3);
    }
    float fold = fbm3(vec2(rayX * 9.0 + fi * 7.0, sd * 0.31 + ts * 0.010));
    float sA = vn(vec2(rayX * STRIPE_FREQ_A + ts * STRIPE_DRIFT + fi * 31.0
        + ddRay * RAY_TILT_H * STRIPE_FREQ_A * 0.02,
        fi * 3.1 + sd));
    float sB = vn(vec2(rayX * STRIPE_FREQ_B - ts * STRIPE_DRIFT * 0.7
        + fi * 17.0 + ddRay * RAY_TILT_H * STRIPE_FREQ_B * 0.014,
        fi * 7.7 + sd));
    float rf = 0.55 * sA + 0.45 * sB;
    float rays = 0.28 + 0.72 * pow(rf, 1.6);
    float hero = fold * fold * (0.8 + 2.6 * act);
    float flick = 0.86 + 0.14 * sin(ts * (2.6 + 2.2 * h3) + rayX * 40.0
        + fi * 5.0 + uTreble * 5.0);

    // 剖面（v12 完全重构：删除底缘锐利亮线）：d>0 光幕指数衰减；d<0 同样
    // 截止（v7.1 血泪修复，勿回退——底边以下 body=1 永不衰减 = "亮布"）。
    // 底缘不再是"画上去的亮线"，而是光幕 body 的自然边界：d≈0 处 presence²
    // 调制让底缘有明暗断续（亮段/暗段自然过渡，实拍观感）
    float d = q.y - yc;
    float dd = max(d, 0.0);
    float dneg = min(d, 0.0);
    float H = BODY_H * mix(1.30, 1.0, depth) * (0.85 + 0.30 * h2);
    // 底缘自然边界：body 在底缘附近用 presence 加强断续感（不是叠加亮线）
    float body = exp(-dd / H) * exp(dneg / (H * 0.30))
        * (presence * presence * 0.75 + presence * 0.25);
    // 宽光晕在底边下方也要衰减（0.55H），否则辉光把下方天空糊亮
    wideEnv = exp(-dd / (H * 3.0)) * exp(dneg / (H * 0.55)) * presence;

    // 沿帘传播的增亮波（v8：从"随机亮度脉冲"改为"方向性传播波"——
    // 一波亮度沿弧带从一端跑向另一端，速度恒定、方向单一；slowstep 门
    // 控让波有明确的"经过"感，爆发期更频繁）
    float surgeWave = sin(q.x * SURGE_WAVE_FREQ - ts * SURGE_SPEED + fi * 5.0)
        * 0.5 + 0.5;
    float surge = smoothstep(0.55, 0.90, surgeWave)
        * smoothstep(0.30, 0.55, vn(vec2(fi * 7.7, sd + 3.0)) + act * 0.4);

    // 垂直涌动：v7 再收敛（0.10→0.06，更慢）——极光是缓慢的呼吸式
    // 明暗起伏，任何"亮斑沿带快速上下跑"都会变成扫描灯
    float stream = 0.94 + 0.06 * sin(q.y * (2.4 + 1.2 * h3)
        - ts * (0.6 + 0.5 * act) + rayX * 4.0 + fi * 2.6);

    // 强度三层解耦（v8）：帘体基础（含弱射线纹理）+ 英雄褶独立亮层 +
    // 独立射线层（衰减高度 RAY_H_K×H——射线穿过光幕顶部延伸到暗天空）。
    // 射线幂律 RAY_POW：少数亮、多数暗，亮度差跨一个数量级。
    // v12：删除下缘亮线 eI（"破线"），峰值改由英雄褶 + 竖直射线承担
    float dk = mix(0.30, 1.0, depth);
    float bI = body * (0.55 + BODY_RAY_W * rays) * flick * stream
        * (1.0 + 0.7 * surge);
    float heroI = body * hero * HERO_GAIN * (0.5 + 0.5 * rf) * flick;
    float rayUp = exp(-dd / (H * RAY_H_K)) * exp(dneg / (H * 0.30));
    float beamI = presence * pow(0.5 + 0.5 * rf, RAY_POW) * rayUp
        * (0.55 + 0.85 * act) * flick * stream * (1.0 + 1.1 * surge);

    // 带内四段色阶（v8，v12 光幕化后 altK 范围随 H 重分布）：底缘白绿
    // （光幕最亮处）→ 主体黄绿（557.7nm）→ 上部橙红（氧红混入）→ 带顶
    // 快速衰减（body 的指数衰减保证）。白芯来自亮处传感器饱和，由白化项补足
    float altK = clamp(dd / (H * 1.2), 0.0, 1.0);
    vec3 bodyCol = mix(EMIT_GREEN * 1.45, EMIT_GREEN,
        smoothstep(0.0, 0.14, altK));                       // 底缘白绿→主体黄绿
    bodyCol = mix(bodyCol, vec3(0.72, 0.62, 0.30),
        smoothstep(0.40, 0.72, altK));                      // 黄→橙（过渡）
    bodyCol = mix(bodyCol, EMIT_RED,
        smoothstep(0.62, 1.0, altK) * 0.80);                // 上部氧红

    vec3 emis = bodyCol * bI * BODY_GAIN * dk * beatG;
    emis += EMIT_GREEN * heroI * dk * beatG;                // 英雄褶亮层
    emis += EMIT_GREEN * beamI * RAY_GAIN * dk * beatG;     // 独立射线层
    // 氧红：独立薄层贴在带顶（RED_LIFT 小——光幕里红边离绿边很近）；
    // 底边下方同样快速截止
    float dr = d - RED_LIFT * span;
    float red = exp(-max(dr, 0.0) / (H * RED_H_K)) * exp(dneg / (H * 0.30))
        * presence * (0.55 + 0.45 * rf);
    emis += EMIT_RED * red * (RED_BASE + RED_ACT * act)
        * (0.5 + 0.9 * h2) * dk * beatG;
    // N2+ 蓝紫：只挂在活跃期光幕底缘的弥散薄层（picket fence 观感——粉紫
    // 在绿幕的下缘外侧；v12 改为挂 body 底缘，不再依赖已删除的亮线）
    float under = d < 0.0 ? exp(-d * d / (2.0 * (H * 0.05) * (H * 0.05))) : 0.0;
    emis += EMIT_PINK * under * presence * act * 0.30 * dk * beatG;
    // 爆发品红层（v8）：substorm 冠冕的主导色（图2）——act 高时整条带
    // 沿射线亮度叠加品红，不只是亮度变化而是"色变"。沿 rayUp 分布
    // （射线结构上），rf 调制让品红跟着射线断续
    float magK = smoothstep(0.55, 0.85, act)
        * rayUp * (0.4 + 0.6 * rf) * presence;
    emis += EMIT_MAGENTA * magK * MAG_ACT_GAIN * dk * beatG;
    // 远帘偏蓝（大气散射）+ 已由 dk 压暗
    emis = mix(emis * vec3(0.60, 0.72, 1.15), emis, depth);
    return emis;
}

// 极光发射（带坐标系 q 内计算）：帘幕线性 HDR 叠加 + 宽尺度光晕。
// 主极光与水面倒影共用——倒影用镜像坐标重算同一场极光（水面反射的
// 就是天上那场，不是另一条假带）。out wide 供宽光晕合成用。
vec3 auroraEmission(vec2 q, vec2 apex, float ts, float sd, float act,
    float beatG, out float wide) {
    float azx = (q.x - apex.x) / max(apex.y - q.y, 0.25);
    vec3 emis = vec3(0.0);
    wide = 0.0;
    for (int i = 0; i < CURTAIN_N; i++) {
        float wenv;
        emis += curtain(q, azx, float(i), ts, sd,
            float(i) / float(CURTAIN_N - 1), act, beatG, wenv);
        wide += wenv * mix(0.3, 1.0, float(i) / float(CURTAIN_N - 1));
    }
    return emis;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    // uTilt 视差（设备倾斜）：整场（天幕/雪原/倒影）反向轻移 = 相机视差；
    // uSpin 滚转 + uKick 缩放脉冲经公共 motionSpinKick（含背景整场转）；
    // 只进几何不进色相（防闪烁纪律）
    vec2 q = sceneUV(vec2(0.5, 0.42) - uTilt * 0.05);
    q = motionSpinKick(q, vec2(0.0));
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // 活跃度（substorm 慢相位）：平静帘 ↔ 爆发
    float act = smoothstep(0.40, 0.78, wander2(ts, ACT_SCALE, sd + 7.0));
    // 节拍/kick 只进亮度（局部元素增益）：kick 是抛甩激励包络
    float beatG = 1.0 + 0.32 * uBeat + 0.30 * uKick;

    // ---- v10 方向随机化：电子入射方向不固定 → 极光带出现的位置/方向都
    // 不确定（用户反馈"极光不应固定竖直"）。整场方向角 dirAngle（wander
    // 慢漂，每场不同）把"带坐标系"旋转：弧带可以从任意角度横穿画面（不
    // 只是水平），射线汇聚方向随带倾斜。背景（夜空/银河/星空/山脊）保持
    // 固定，只有极光本体旋转
    float dirAngle = wanderBi(ts, 140.0, sd + 31.0) * 0.55;  // ±31°，慢变
    vec2 qr = rot(dirAngle) * q;                             // 带坐标系（旋转后）

    // 磁天顶（慢游走，v10 游走幅度加大——汇聚点位置更多变）——光柱直线族
    // 的汇聚点，随带方向一起倾斜
    vec2 apex = APEX_BASE + APEX_WANDER
        * vec2(wanderBi(ts, 61.0, sd + 3.0), wanderBi(ts, 47.0, sd + 9.0));

    // ---- 帘幕线性 HDR 叠加 + 宽尺度光晕（带坐标系 qr；azx 在函数内算）----
    float wide = 0.0;
    vec3 emis = auroraEmission(qr, apex, ts, sd, act, beatG, wide);
    emis *= transA;
    wide *= transA;

    // ---- 亮芯白化（v8 增强）：发射最强的芯部向白偏移（传感器饱和的观
    // 感）。实拍里最亮的褶皱/英雄柱芯部几乎全白——起点 0.75→0.55、上限
    // 2.8→2.2、强度 0.8→0.9，让白化真的"白"出来而不是微微偏灰
    float eL = dot(emis, vec3(0.299, 0.587, 0.114));
    float whiteK = smoothstep(0.55, 2.2, eL) * 0.9;
    emis = mix(emis, vec3(1.02, 1.08, 1.00) * eL * 1.12, whiteK);

    // ---- 夜空底色（天顶→地平线渐变，不是纯黑）----
    float horiz = smoothstep(0.30, -0.42, q.y);
    vec3 sky = mix(SKY_ZENITH, SKY_HORIZON, horiz);
    // 地平线大气辉光（淡绿，极光夜的常客）
    sky += vec3(0.020, 0.045, 0.030)
        * exp(-pow((q.y - (-0.28)) * 5.5, 2.0)) * (0.5 + 0.5 * act);

    // ---- 银河：斜带 + 云絮 + 尘带（暗线是辨识度的关键）----
    vec2 mwDir = normalize(vec2(0.83, 1.0));
    float mwAxis = dot(q, mwDir) - 0.05;
    float band = exp(-mwAxis * mwAxis * 6.0);
    float cloud = 0.6 * fbm3(q * 4.0 + 31.0) + 0.4 * fbm3(q * 9.0 + 7.0);
    float dust = smoothstep(0.40, 0.62, fbm3(q * 5.0 + 77.0));
    float along = dot(q, vec2(-mwDir.y, mwDir.x));
    vec3 mwCol = mix(vec3(0.10, 0.12, 0.19), vec3(0.21, 0.17, 0.13),
        smoothstep(-0.3, 0.35, along));
    sky += mwCol * band * (0.35 + 0.65 * cloud) * (1.0 - 0.60 * dust)
        * MW_GAIN * transA;

    // ---- 星空（透过帘：按发射亮度衰减透射率，薄处仍见星）----
    // v8 星亮度 ×STAR_GAIN：照片里星星清晰锐利（v7.1 偏保守）
    float veil = exp(-dot(emis, vec3(0.299, 0.587, 0.114)) * 0.85);
    vec3 stars = starLayer(q, 110.0, 0.82, ts, sd) * 1.6
        + starLayer(q, 46.0, 0.88, ts, sd) * 1.9
        + starLayer(q, 19.0, 0.94, ts, sd) * 2.4;
    sky += stars * veil * transA * STAR_GAIN;

    // ---- 合成：直绘 + 宽光晕 + 低空大气绿 + 反馈余晖 ----
    // 宽光晕偏蓝：散射光把绿拉向青蓝（夜空里帘幕周围的弥散光就是这样）
    vec3 col = sky + emis
        + mix(EMIT_GREEN, vec3(0.40, 0.70, 1.00), 0.35) * wide * WIDE_GAIN
        // v14 氛围：极光漫射在空气中的淡绿余晖，贴地平线一层（像极光把
        // 低空大气点亮），很淡不抢戏
        + EMIT_GREEN * exp(-pow((q.y - RIDGE_FAR_Y) * 5.0, 2.0))
            * AIRGLOW * transA;

    // 反馈余晖：微胀采样 + 轻色散（镜头感），只做柔光不参与结构
    vec2 fuv = (vUV - 0.5) * FB_ZOOM + 0.5;
    vec3 prev = texture2D(uPrev, fuv).rgb;   // v15.1：单次采样（色散量 < 感知阈值）
    col += prev * FB_GAIN;

    // ---- 前景：远山脊剪影（水岸）+ 极光绿色上光 + 地平线辉光 ----
    // 近侧山脊（RIDGE_NEAR_Y）在 v11 改为水面（见下），只保留远山脊
    // 作为水岸线后面的剪影
    float ridgeFar = smoothstep(0.0, -0.035,
        q.y - RIDGE_FAR_Y - 0.16 * fbm3(vec2(q.x * 2.2, 3.1)));
    vec3 ridge = vec3(0.008, 0.013, 0.020);
    float auroraLum = dot(emis, vec3(0.299, 0.587, 0.114));
    float upF = exp(-pow((q.y - RIDGE_FAR_Y) * 24.0, 2.0));
    ridge += EMIT_GREEN * upF
        * clamp(auroraLum * 0.7, 0.0, 0.6) * 0.09;
    col = mix(col, ridge, ridgeFar);

    // ---- 水面（v11）：近侧山脊改为水岸——极光倒影（图2/3 沉浸感大杀器）。
    // 镜像坐标重算同一场极光（auroraEmission），叠加波纹扰动 + 距离衰减。
    // 倒影只算主帘（depth=1.0 最近最亮）+ 宽光晕——水面反射最亮的结构，
    // 完整 2 帘会让倒影区成本翻倍，主帘近似在 1/3 屏内视觉足够
    float waterY = WATER_Y + 0.04 * fbm3(vec2(q.x * 1.3 + 5.0, 7.7)); // 水岸线微起伏
    float waterMask = smoothstep(waterY + 0.02, waterY, q.y);
    if (waterMask > 0.01) {
        // 波纹：两频横向偏移（时间流动），镜像坐标扰动
        float ripple = 0.5 + 0.5 * sin(q.x * 26.0 - ts * 1.1 + waterY * 40.0);
        vec2 mq = vec2(q.x + RIPPLE_AMP * (sin(q.x * 30.0 - ts * 1.4)
            + 0.5 * sin(q.x * 47.0 + ts * 0.8)) * ripple,
            2.0 * waterY - q.y);
        // 镜像坐标也进带坐标系（倒影随极光方向一起倾斜）
        vec2 mqr = rot(dirAngle) * mq;
        // v15：倒影只算最近主帘（fi=CURTAIN_N-1、depth=1）——v11 注释一直
        // 这么设计（"倒影只算主帘 + 宽光晕，避免 2 帘翻倍"），代码此前却
        // 完整重算两帘；对齐设计意图，水面保留最亮结构的镜像，成本减半
        float mazx = (mqr.x - apex.x) / max(apex.y - mqr.y, 0.25);
        float mwide;
        vec3 memis = curtain(mqr, mazx, float(CURTAIN_N - 1), ts, sd, 1.0,
            act, beatG, mwide);
        // 亮芯白化（与主极光一致的后期）
        float meL = dot(memis, vec3(0.299, 0.587, 0.114));
        memis = mix(memis, vec3(1.02, 1.08, 1.00) * meL * 1.12,
            smoothstep(0.55, 2.2, meL) * 0.9);
        // 距离衰减（越靠画面底部越暗）+ 波纹亮度调制 + 水面吸收偏蓝绿
        float depth = clamp((q.y - waterY) / 0.38, 0.0, 1.0);
        float att = REFLECT_GAIN * exp(-depth * 2.2) * (0.5 + 0.5 * ripple);
        col += (memis + mix(EMIT_GREEN, vec3(0.30, 0.55, 0.90), 0.4)
            * mwide * 0.5) * att * transA;
    }
    // 地平线低空辉光（v8）：水岸上方的贴地辉光——雪原/水面被极光整体照亮
    float ground = exp(-pow((q.y - RIDGE_FAR_Y) * 6.0, 2.0)) * (1.0 - ridgeFar);
    col += EMIT_GREEN * ground * clamp(auroraLum * 0.7, 0.0, 0.6)
        * GROUND_GLOW * transA;

    // ---- 摄影后期链：ACES → 暗角 → 亮度加权颗粒 ----
    col = filmic(col);
    col *= 1.0 - 0.30 * dot(q * 0.75, q * 0.75);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 17.0) - 0.5)
        * mix(0.022, 0.005, smoothstep(0.0, 0.35, L)));

    gl_FragColor = vec4(col, 1.0);
}
