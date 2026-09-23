// [历史存档] pan v10 旧版快照,与现行 pan.frag(v17)已严重漂移——仅供
// 对照阅读,勿编译、勿当现行实现。
// pan_v10_standalone.glsl — 热炒菜锅水滴动力学 v10 独立可移植版
// = pan.frag + common.glsl 必要函数 inline 合并版
//
// 完整源码：music_app/entry/src/main/cpp/shaders/pan.frag（main 分支）。
// 本文件去除 playground / 端侧工具链依赖，自包含可拷贝到其他 GLSL 项目。
// 语法：GLSL ES 1.00（varying / gl_FragColor / texture2D）。
// HLSL / GLSL 3.00 适配说明见 PAN_V10_README.md。
//
// v10 相对 v9 的五项物理返工（参考实拍炒锅）：
//   1. 锅底材质：拉丝不锈钢 → 黑碳钢/铸铁（PAN_DIFF 0.18→0.55 哑光漫反射主
//      导、PAN_SPEC 0.72→0.30 微镜面、ALBEDO_BASE 0.07）。
//   2. 锅底温度场 + 同心圆加热纹 + 锅心红热：tempField(p) 0~1 温度——同心圆
//      燃气纹（亮环×1.18 / 暗环×0.82 反照率调制）+ fbm 不均匀 + 锅心温度
//      衰减。温度 >0.7 混入暗红热、0.4~0.7 混入灶圈蓝。
//   3. 水珠沸腾翻滚：boilK 调制 wob 振幅（×1~×3 接近爆裂）+ BOIL_KICK 半
//      径脉动（液滴"咕嘟咕嘟"翻腾）。
//   4. 接触处沸腾暗环 + 小气泡群（BUBBLE_FREQ=80 高频值噪声暗点）。
//   5. 飞溅星芒（SPLASH_GAIN=0.8）+ 锅口白烟增强（STEAM_ALPHA 0.55）+ 接
//      触处局部白烟（STEAM_LOCAL_GAIN=0.30）。
//
// 关键参数说明 + 推荐取值范围见同目录 PAN_V10_README.md。

// ============================================================================
// Uniform / Varying 声明（嵌入其他项目时按此声明；playground / 端侧工具
// 链会自动注入这些，这里为独立可移植性显式声明）
// ============================================================================
uniform float uT;            // 时间（毫秒）
uniform float uSeed;         // 随机种子（u32）
uniform vec2 uRes;           // 渲染分辨率（px）
uniform float uBeat;         // 节拍能量 [0,1]
uniform float uBass;         // 低频能量 [0,1]
uniform float uTreble;       // 高频能量 [0,1]
uniform float uTransition;   // preset 切换淡入 [0,1]
uniform sampler2D uPrev;     // 上一帧画面（feedback 余晖用）
varying vec2 vUV;            // 片元 UV [0,1]²

// ============================================================================
// 公共函数（从 common.glsl 提取的最小集合）
// ============================================================================
#define TAU 6.2831853
#define PI 3.1415927

float hash11(float n) {
    n = fract(n * 0.1031);
    n *= n + 33.33;
    n *= n + n;
    return fract(n);
}

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float vn(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    mat2 R = mat2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 4; i++) {
        v += a * vn(p);
        p = R * p * 2.03;
        a *= 0.5;
    }
    return v;
}

float wander(float t, float scale, float seed) {
    float x = t / scale + seed, e = floor(x), u = fract(x);
    u = u * u * (3.0 - 2.0 * u);
    return mix(hash11(e * 0.717 + seed), hash11((e + 1.0) * 0.717 + seed), u);
}

float wander2(float t, float scale, float seed) {
    return wander(t, scale, seed) * 0.65
        + wander(t, scale * 0.271, seed + 11.7) * 0.35;
}

mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

float nowSec() { return uT * 0.001; }
float seedHash() { return hash11(uSeed * 1.0e-7); }
float aspectRatio() { return uRes.x / max(uRes.y, 1.0); }
vec2 sceneUV(vec2 center) {
    return (vUV - center) * vec2(aspectRatio(), 1.0);
}

vec3 filmic(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

vec3 applyTransition(vec3 col) {
    float a = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    return mix(texture2D(uPrev, vUV).rgb, col, a);
}

// ---- 环境光（白天厨房：锅与水珠共用同一组光）--------------------------------
const vec3 WIN_DIR = vec3(-0.486, 0.549, 0.684);   // 冷白窗（已归一）
const vec3 BULB_DIR = vec3(0.503, 0.302, 0.809);   // 暖灯泡（已归一）
const vec3 WIN_COLOR = vec3(1.05, 1.12, 1.30);
const vec3 BULB_COLOR = vec3(1.30, 0.98, 0.62);
const vec3 ROOM_SKY = vec3(0.50, 0.52, 0.56);      // 亮天花板漫射
const vec3 ROOM_FLOOR = vec3(0.14, 0.11, 0.09);    // 台面暖木色
const float WIN_SHARP = 16.0;      // 窗立体角（宽窗：更多水珠挂到窗形高光）
const float BULB_SHARP = 90.0;

// ---- 锅（椭圆透视 × 凹底球冠 × 收进的内壁环带）------------------------------
const float PAN_FILL = 0.42;       // 锅半宽 = FILL × aspect（锅占屏宽 84%）
const float PAN_SQUASH = 0.75;     // y 压扁（俯视透视）
const vec2 PAN_CENTER = vec2(0.0, -0.03);
const float BOWL_RADIUS = 1.30;    // 锅底球冠半径（锅局部坐标；v9 真球冠法线）。
                                   //   曲率集中在锅沿：锅心近平（反射天花板）、
                                   //   底缘处法线 ~45° 快速弯下去——光滑球形面
                                   //   的深度线索；越小锅越深。
const float BOWL_DARK = 0.30;      // 锅心聚油/自阴影压暗（深度线索的一部分；
                                   //   v8.1 0.22→0.30：锅心反射天花板仍然亮，
                                   //   但聚油压暗增强后锅心-锅沿的明暗差更大，
                                   //   "凹下去"的视觉权重更明显）
const float BOTTOM_NEAR = 0.92;    // 底缘半径（近侧）：近侧内壁被沿口遮住，
                                   //   只留一条缝——v8 真·凹底的几何核心
const float BOTTOM_FAR = 0.58;     // 底缘半径（远侧）：远侧内壁宽，底缘
                                   //   收进椭圆内部一大圈
const float WALL_W = 0.28;         // 内壁环带基准宽度（锅局部坐标；v8.1
                                   //   0.24→0.28：环带更宽，远侧"映天花板"
                                   //   的亮区更显著，深锅俯视透视更扎实）
const float OUTER_W = 0.10;        // 外壁环带宽度
const float PAN_DIFF = 0.55;       // 钢面漫反射占比（v10 黑碳钢 0.18→0.55：
                                   //   哑光磨砂碳钢的漫反射是主项，不是镜面；
                                   //   亮反射会让锅变成"厨房用品"质感，不像
                                   //   实拍黑炒锅）
const float PAN_SPEC = 0.30;       // 钢面镜面强度（v10 0.72→0.30：黑碳钢只
                                   //   在窗光直射处出微高光，不抢戏）
const float BRUSH_PERTURB = 0.045; // 拉丝法线扰动（v10 0.060→0.045：黑碳钢
                                   //   比拉丝不锈钢更光滑，只有极轻的拉丝质感）
const float ALBEDO_BASE = 0.07;     // v10 锅底反照率基色（0.14→0.07：黑碳钢
                                   //   比不锈钢暗 1 个 stops）
const float HEAT_TINT = 0.55;       // 锅心红热混入强度（温度 > 0.7 时往暗红
                                   //   偏——参考图锅心是暗红热区）
const float FLAME_BLUE = 0.30;      // 灶圈蓝光混入强度（温度 0.4~0.7 区间，
                                   //   燃气反射的蓝色调）

// ---- 水滴群（锅局部坐标：单位圆 = 锅口内沿）---------------------------------
const int DROPLET_COUNT = 44;      // 30 主滴 + 14 卫星滴（v8：真实莱顿弗罗
                                   //   斯特是"一锅密密麻麻的小珠"+ 少数大珠）
const float SATELLITE_FROM = 30.0;
const float R_MAIN_MIN = 0.014;    // 主滴半径区间（帕累托；真实液滴约锅径 1~4%）
const float R_MAIN_MAX = 0.075;
const float R_SAT_MIN = 0.010;
const float R_SAT_MAX = 0.030;
const float LIFE_BASE = 7.0;       // 寿命 = BASE + K·r²（d² 蒸发定律）
const float LIFE_K = 1150.0;
const float GROW_PHASE = 0.025;
const float GROW_MIN = 0.10;
const float FIELD_EPS = 1e-7;

// ---- 形状不规则（角向谐波 + 定向拉伸 = 不规则类球体）----------------------
const float WOB_SMALL_AMP = 0.05;
const float WOB_BIG_AMP = 0.20;
const float WOB_SIZE_LO = 0.060;
const float WOB_SIZE_HI = 0.240;
const float WOB_STRETCH = 0.40;    // 定向拉伸幅度（v9：受热不均 → 液滴沿
                                   //   受热最弱方向拉长成泪滴形，非球对称）
const float WOB_TURN = 0.32;       // 定向拉伸方向随受热慢转（弧度/滴生命周期）
const float WOB_BOIL_AMP = 0.50;   // v10 沸腾变形振幅系数（boilK × WOB_BOIL_AMP
                                   //   加到 wob 振幅上——沸腾时形状剧烈变形）

// ---- 锅底温度场（v10）---------------------------------------------------
const float HEAT_RING_FREQ = 28.0; // 同心圆加热纹频率（每单位多少环）
const float HEAT_RING_DRIFT = 0.20;// 加热纹慢漂（锅热时纹路在游动）
const float HEAT_RING_K = 0.18;    // 加热纹反照率调制深度（0.82~1.18）
const float HEAT_CENTER_BIAS = 0.35;// 锅心温度偏置（同心圆纹整体偏向锅心热）
const float BUBBLE_DARKEN = 0.55;  // 接触处小气泡暗化强度
const float BUBBLE_FREQ = 80.0;     // 接触处小气泡密度（每单位多少点）

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;
const float PANIC_BOOST = 5.0;
const float PANIC_HOP = 0.28;      // 濒死弹跳：半径脉动幅度（蒸气垫破裂前
                                   //   液滴在锅面上蹦跳——影子随场同步脉动）
const float SIZZLE_FROM = 0.90;
const float SIZZLE_AMP = 3.0;      // v7 加强（受热沸腾翻滚的观感）
const float HEAT_JITTER = 0.06;    // v9 受热震动：蒸气垫把液滴顶起→落下，
                                   //   半径 ±6% 高频脉动（比濒死弹跳小得多，
                                   //   整个生命周期持续）——水珠在热锅上
                                   //   永远是"跳着"的，不是静止的玻璃珠
const float HEAT_DRIFT = 11.0;     // 热斑漂移周期（秒；受热不均随时间的
                                   //   变化速率——每滴的热强度在漂移）
const float BOIL_KICK = 0.12;      // v10 沸腾半径脉动幅度（boilK × BOIL_KICK
                                   //   加到半径上——沸腾时液滴高度大幅脉动）
const float BOIL_RATE = 4.5;        // v10 沸腾主频率（Hz；每滴独立相位）
const float TREMBLE_AMP = 0.026;   // 锅局部坐标（约为屏幕坐标的 1/0.35）
const float TREMBLE_BASS = 1.6;
const float WANDER_NORM = 1.55;
const float SPEED_STRETCH = 0.22;
const float BOWL_GATHER = 0.58;    // 凹底收拢：活动范围向锅心聚拢的比例
const float ORBIT_RATE = 0.18;     // 绕锅心盘旋基础角速度（rad/s，缓慢）
const float ORBIT_RATE_K = 0.30;   // 每滴角速度差异系数

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;
const float CONTACT_DARKEN = 0.50;
const float AO_DARKEN = 0.16;

// ---- 水珠材质 -------------------------------------------------------------
const float REFRACT_LEN = 0.28;    // 折射取样偏移（锅局部坐标）
const float FOCUS_GAIN = 0.60;
const float LENS_GAIN = 0.70;      // 内部聚光（v8 收敛：压住"水银球"感——
                                   //   水珠是暗背景上的透明透镜，不是自发光球）
const float RIM_DARK = 0.30;       // 折射体边缘压暗（接触线全反射+阴影，勾轮廓）
const float GLINT_GAIN = 2.0;      // 窗光针尖高光（每颗水珠一枚——"湿润感"关键）
const float ABSORB_R = 0.8;
const float CRESCENT_GAIN = 0.70;
const float SPARKLE_GAIN = 1.8;
const float DROP_DIFF = 0.10;      // v9 水珠漫反射（天空光 diffuse 项——纯镜面
                                   //   的玻璃球是不存在的，表面有微漫反射，
                                   //   暗侧才不至于死黑）
const float BULB_GLOW = 0.35;      // v9 灯泡泛光高光（pow 60 中锐——与窗光
                                   //   针尖 pow 320 形成双层高光，真实水珠
                                   //   有多枚反射高光而非一枚）
const float RIM_LIGHT = 0.22;      // v9 薄缘透光：接触线外缘一圈背景透亮
                                   //   （薄处透光强），与 RIM_DARK 压暗的内缘
                                   //   形成"暗边 + 亮线"的真实液滴边缘
const float IRID_PATH_NM = 1500.0;  // 薄膜干涉光程差上限（nm；接触线 0 → 向内增）
const float IRID_GAIN = 0.55;       // 牛顿环虹彩强度（实拍里这是"标识性"特征，不能太弱）
const float IRID_FALLOFF = 22.0;    // 虹彩环带宽度（越小越贴接触线；太大扩散成色斑）
const float CAUSTIC_GAIN = 0.52;    // 接触线外缘焦散环强度

// ---- 蒸汽 / 收尾 ----------------------------------------------------------
const float STEAM_ALPHA = 0.55;    // 锅口蒸汽浓度（v10 0.38→0.55：参考图
                                   //   锅口弥漫着浓密白雾）
const float STEAM_RISE = 0.50;     // 上升速度（屏/秒，恒定）
const float STEAM_LOCAL_GAIN = 0.30; // v10 接触处白烟浓度（每颗水珠周围
                                   //   的小范围浓白雾——沸腾先冒小团再合并
                                   //   到锅口大蒸汽）
const float SPLASH_GAIN = 0.8;     // v10 飞溅条纹强度（濒死期从液滴中心
                                   //   沿速度方向射出的 2-3 道短亮线）
const float SEED_SPREAD = 173.0;

// 环境辐射：一组方向光照亮整个场景（锅面镜面、水珠反射、台面全用它）
vec3 envMap(vec3 r) {
    vec3 c = mix(ROOM_FLOOR, ROOM_SKY, smoothstep(-0.5, 0.45, r.z));
    float w = max(dot(r, WIN_DIR), 0.0);
    c += WIN_COLOR * (pow(w, WIN_SHARP) * 2.8 + pow(w, 6.0) * 0.55);
    float b = max(dot(r, BULB_DIR), 0.0);
    c += BULB_COLOR * (pow(b, BULB_SHARP) * 2.4 + pow(b, 10.0) * 0.22);
    return c;
}

// 薄膜干涉：两束反射光的光程差 optPath 逐波长相位不同 → 虹彩。
// 相位偏移 0.5 使零气隙处先破坏（暗），向内扫过整段可见光谱——与
// 牛顿环"接触点暗、向外彩虹"一致。
vec3 thinFilm(float optPath) {
    return 0.5 + 0.5 * cos(TAU * (optPath / vec3(645.0, 510.0, 440.0) + 0.5));
}

// 可见底面边缘半径（随方位变化）——v8 真·凹底的几何核心：
// 远侧（画面上方）底缘收到 0.58（露出一大圈内壁），近侧 0.92（内壁
// 被沿口遮住只剩一条缝）。锅底因此是"比锅口小的椭圆"，俯视透视成立。
float bRAt(vec2 p) {
    float ny = p.y / max(length(p), 1e-4);
    return mix(BOTTOM_NEAR, BOTTOM_FAR, smoothstep(-0.9, 0.9, ny));
}

// 水滴元球场（锅局部单位圆坐标）：F = Σ r²/d_eff²，g = ∇F。
// d_eff 含运动方向拉伸 + 角向谐波轮廓（不规则类球体）+ 受热震动 + 濒死泡沫化。
float field(vec2 p, float ts, float sd, out vec2 g) {
    g = vec2(0.0);
    float F = 0.0;
    for (int i = 0; i < DROPLET_COUNT; i++) {
        float fi = float(i);
        float small = step(SATELLITE_FROM, fi);
        float h1 = hash11(fi * 7.13 + sd);
        float h2 = hash11(fi * 3.71 + sd + 11.0);
        float h3 = hash11(fi * 5.39 + sd + 23.0);
        float h4 = hash11(fi * 9.17 + sd + 37.0);
        float r0 = mix(mix(R_MAIN_MIN, R_MAIN_MAX, pow(h3, 2.6)),
            mix(R_SAT_MIN, R_SAT_MAX, pow(h3, 1.5)), small);
        float P = (LIFE_BASE + LIFE_K * r0 * r0) * (0.70 + 0.60 * h1);
        float age = mod(ts + h2 * P, P);
        float lifeK = age / P;
        float grow = mix(GROW_MIN, 1.0, smoothstep(0.0, GROW_PHASE, lifeK));
        float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
        // 沸腾度（v10）：每滴独立沸腾相位——蒸气速在液滴底部生成气泡，
        // 气泡破裂让液滴"内部在翻腾"。沸腾度同时调制半径脉动幅度和
        // 形状变形振幅，活跃期（lifeK 0.5~0.9）最强，濒死期还伴随
        // 形状极不规则（接近爆裂态）。两个频率叠加避免节拍化
        float boilK = 0.5 + 0.5 * sin(age * BOIL_RATE + fi * 5.7)
            * (0.5 + 0.5 * sin(age * (BOIL_RATE * 0.43) + fi * 1.9));
        // 受热震动（v9）：蒸气垫把液滴顶起→落下，半径 ±6% 高频脉动——
        // 两个不可通约频率叠出"跳着"的活体感
        float heatHop = 1.0 + HEAT_JITTER * sin(age * (9.0 + 7.0 * h2) + fi * 3.7)
            * (0.5 + 0.5 * sin(age * (2.3 + 0.7 * h4) + fi * 1.9));
        // 沸腾半径脉动（v10）：boilK × BOIL_KICK 调制——沸腾时液滴高度
        // 大幅脉动（液滴在"咕嘟咕嘟"地翻）
        float boilKick = 1.0 + BOIL_KICK * boilK
            * sin(age * (BOIL_RATE * 2.7) + fi * 4.3);
        rr *= heatHop * boilKick;
        // 濒死弹跳：蒸气垫破裂前液滴在锅面上蹦跳（半径脉动 → 接触阴影
        // 与轮廓同步搏动；系数最低 0.72，不会反号）
        float hopK = smoothstep(PANIC_FROM, 1.0, lifeK);
        rr *= 1.0 + PANIC_HOP * hopK * sin(age * 36.0 + fi * 7.0);
        if (rr < FIELD_EPS) continue;
        float rad = sqrt(rr);
        // 受热强度（v9）：每滴的热斑随时间慢漂——受热不均 → 运动速度
        // 不是固定公式，而在 0.72×~1.35× 之间随机波动（急转的珠会缓下
        // 来、缓移的珠会窜出去，像真实锅里被不同区域热流推着走）
        float heatK = 0.28 + 0.72 * vn(vec2(age / HEAT_DRIFT + fi * 2.7,
            sd * 0.011 + h1 * 4.0));
        float sp = (0.9 + 0.5 * h4) * pow(0.12 / max(r0, 0.018), 0.35)
            * mix(0.72, 1.35, heatK);
        sp = clamp(sp, 0.6, 3.2);
        float panic = 1.0 + PANIC_BOOST * smoothstep(PANIC_FROM, 1.0, lifeK);
        float w1 = 1.35 * h4 * sp;
        float w2 = 3.10 * h1 * sp;
        float w3 = 1.15 * h2 * sp;
        float w4 = 2.70 * h3 * sp;
        float p1 = fi * 2.1;
        float p2 = fi * 5.3;
        float p3 = fi * 3.7;
        float p4 = fi * 1.9;
        vec2 pos = vec2(
            sin(age * w1 + p1) + 0.55 * sin(age * w2 + p2),
            cos(age * w3 + p3) + 0.55 * cos(age * w4 + p4));
        vec2 vel = vec2(
            w1 * cos(age * w1 + p1) + 0.55 * w2 * cos(age * w2 + p2),
            -w3 * sin(age * w3 + p3) - 0.55 * w4 * sin(age * w4 + p4));
        // 凹底行为：活动范围向锅心收拢（滑向最低点），并绕锅心缓慢盘旋
        // （凹面上蒸气垫近乎无摩擦，液滴沿等势面打转——真实炒锅里水珠
        // 就是在锅心附近绕圈，而不是全域均匀乱跑）
        float range = (1.0 - rad - 0.05) * BOWL_GATHER;
        pos *= range / WANDER_NORM;
        vel *= range / WANDER_NORM;
        float oa = age * (ORBIT_RATE + ORBIT_RATE_K * h2)
            * (h4 < 0.5 ? -1.0 : 1.0);
        pos = rot(oa) * pos;
        vel = rot(oa) * vel;
        vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        pos += trem;
        // 等值面留在可见底面内（不许爬内壁/爬上沿口）——底面边缘随方位
        // 收拢（远侧 0.58 / 近侧 0.92），与 v8 凹底构图一致
        float bR = bRAt(pos);
        float maxR = bR - 2.3 * rad - 0.05;
        if (maxR > 0.0) {
            float pl = length(pos);
            if (pl > maxR) {
                pos *= maxR / pl;
            }
        } else {
            continue;
        }
        vec2 d = p - pos;
        float spd = length(vel);
        float k = clamp(spd * SPEED_STRETCH, 0.0, 0.6);
        vec2 vh = vel / max(spd, 1e-4);
        float dpar = dot(d, vh) * (1.0 - 0.24 * k);
        float dperp = dot(d, vec2(-vh.y, vh.x)) * (1.0 + 0.18 * k);
        float dlen2 = dpar * dpar + dperp * dperp + 1e-6;
        float wsize = smoothstep(WOB_SIZE_LO, WOB_SIZE_HI, rad);
        // 沸腾度调制 wob 振幅（v10）：沸腾时形状剧烈变形——大珠在
        // lifeK 中段 (0.5~0.9) 变形振幅 ×2+，濒死期 (lifeK>0.9) ×3 接近
        // 爆裂态（飞溅条纹的视觉基础）
        float boilShape = 1.0 + boilK * WOB_BOIL_AMP
            * (0.5 + 1.5 * smoothstep(0.85, 0.99, lifeK));
        float wamp = mix(WOB_SMALL_AMP, WOB_BIG_AMP, wsize) * boilShape;
        float wrate = (0.6 + 0.9 * h2) * mix(1.8, 0.7, wsize)
            * (1.0 + 0.6 * boilK * smoothstep(0.85, 0.99, lifeK));
        float da = atan(dperp, dpar);
        // 不规则类球体（v9）：2~7 阶五谐波混合 + 定向拉伸。标准半球是球
        // 对称的；真实蒸气垫液滴是不对称变形体——多阶谐波给出"不是圆
        // 不是椭圆"的随机轮廓，定向拉伸让液滴沿受热最弱方向拉长成泪滴
        // 形，且拉伸方向随受热慢转（每滴在缓慢变形，不是静态轮廓）
        float wob = 1.0 + wamp * (
            0.40 * sin(2.0 * da + h1 * TAU + age * wrate)
            + 0.28 * sin(3.0 * da + h4 * TAU - age * wrate * 1.31)
            + 0.18 * sin(5.0 * da + h3 * TAU + age * wrate * 0.83)
            + 0.12 * sin(4.0 * da + h2 * TAU + age * wrate * 2.11)
            + 0.08 * sin(7.0 * da + h1 * TAU * 3.7 - age * wrate * 0.61));
        float dirA = h2 * TAU + age * (WOB_TURN * 0.5 + 0.12 * heatK);
        wob *= 1.0 + wamp * WOB_STRETCH * (0.5 + 0.5 * cos(da - dirA));
        float d2 = dlen2 * wob * wob;
        float w = rr / d2;
        float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
        w *= 1.0 + sizzle * (vn(p * 150.0 + age * 7.0) - 0.5) * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底温度场（v10）：返回 0..1 的归一化温度。同心圆燃气加热纹（频率由
// HEAT_RING_FREQ 控制）提供周期性骨架，fbm 噪声给不均匀加热，锅心温度
// 衰减（锅心受热最热，靠锅沿较冷）。最终用于反照率调制 + 红热/灶圈蓝
// 染色：t<0.4 冷铁皮、0.4~0.7 灶圈蓝反射、>0.7 红热。
float tempField(vec2 p) {
    float r = length(p);
    float ang = atan(p.y, p.x);
    // 同心圆加热纹（亮环/暗环交替）
    float ring = 0.5 + 0.5 * sin(r * HEAT_RING_FREQ - r * 0.0);
    // 旋涡扰动让纹路不是死板的同心圆（参考图锅底有手摇动的不规则感）
    float swirl = sin(r * HEAT_RING_FREQ * 0.9 + ang * 1.7) * 0.5;
    ring = mix(ring, swirl, 0.3);
    // 不均匀加热（fbm）
    float heat = fbm(p * 4.5 + 11.0);
    // 锅心温度偏置 + 越靠锅沿越冷
    float radial = smoothstep(0.95, 0.10, r);
    return clamp(0.35 * radial + 0.45 * ring + 0.20 * heat, 0.0, 1.0);
}

// 锅底面：黑碳钢/铸铁（v10）× 真球冠 + 温度场 + 同心圆加热纹 + 红热
// + 灶圈蓝光 + 接触处沸腾气泡。v9 的拉丝不锈钢质感被替换：黑碳钢的
// 漫反射主导（PANDIFF 0.55）、镜面锐但能量低（PAN_SPEC 0.30），反射
// 的不是亮天花板，而是更暗的锅周环境——这是炒锅的本色。
vec3 bg(vec2 p, float ts) {
    float r = length(p);
    float ang = atan(p.y, p.x);

    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec2 radialDir = p / max(r, 1e-4);
    // 球冠法线（v9 解析）：p / √(R²−r²) ——曲率集中在锅沿
    float bowlSlope = 1.0 / sqrt(max(BOWL_RADIUS * BOWL_RADIUS - r * r, 1e-4));
    vec3 n = normalize(vec3(
        (brushHi - 0.5) * BRUSH_PERTURB * radialDir + p * bowlSlope, 1.0));

    vec3 refl = 2.0 * n.z * n - vec3(0.0, 0.0, 1.0);
    vec3 spec = envMap(refl);
    float fres = 0.55 + 0.40 * pow(1.0 - n.z, 3.0);
    // 温度场 + 同心圆加热纹调制反照率
    float temp = tempField(p);
    // 锅心红热（高温区往暗红偏）+ 温区灶圈蓝（中等温度偏蓝黑）
    vec3 heatRed = vec3(0.32, 0.06, 0.02);     // 红热色（暗红，避免刺眼）
    vec3 flameBlue = vec3(0.04, 0.07, 0.16);    // 灶圈蓝光（深蓝黑）
    vec3 coldSteel = vec3(0.06, 0.06, 0.07);   // 冷碳钢色
    vec3 baseColor = coldSteel
        + flameBlue * smoothstep(0.40, 0.65, temp) * (1.0 - smoothstep(0.70, 0.85, temp))
        + heatRed * smoothstep(0.70, 0.95, temp) * HEAT_TINT;
    // 同心圆加热纹作为反照率调制（亮环 1.15×、暗环 0.85×）
    float ringK = mix(1.0 - HEAT_RING_K, 1.0 + HEAT_RING_K,
        0.5 + 0.5 * sin(r * HEAT_RING_FREQ + ts * HEAT_RING_DRIFT));
    vec3 albedo = baseColor * ALBEDO_BASE * ringK
        + vec3(0.020) * (brush - 0.5)
        + vec3(0.012) * (brushHi - 0.5);
    vec3 c = albedo * envMap(vec3(0.0, 0.0, 1.0)) * PAN_DIFF
        + spec * PAN_SPEC * fres;

    c *= 0.92 + 0.16 * fbm(p * 3.2 + 7.0);

    // 锅心聚油 + 凹底自阴影：中心压暗（"凹下去"的深度线索之一）
    c *= 1.0 - BOWL_DARK * smoothstep(0.85, 0.10, r);

    // 接触处沸腾气泡（v10）——水珠正下方锅面被高温烫成沸腾区，密集小
    // 气泡群（高频值噪声）作为暗点；只覆盖锅心附近的"沸区"（圆环掩
    // 模，避开锅沿冷区）
    float bubbleMask = smoothstep(0.05, 0.35, temp) * smoothstep(0.85, 0.55, r);
    float bubble = vn(p * BUBBLE_FREQ);
    float bubbleDark = bubbleMask * smoothstep(0.55, 0.30, bubble)
        * (0.5 + 0.5 * sin(ts * 5.7 + r * 60.0));
    c *= 1.0 - BUBBLE_DARKEN * bubbleDark;

    // 远侧底面被内壁轻微遮挡（俯视时远侧底边有一点内壁阴影）
    c *= 1.0 - 0.12 * smoothstep(0.5, 0.95, p.y / max(1e-4, 1.0));
    // 全局压暗保持（v8 立的水珠暗底玻璃体的基调）
    c *= 0.78;
    return c;
}

// 沿口半径（随方位变化）：深锅俯视透视——远侧（画面上方）内壁看得见
// 一大圈（高），近侧只剩沿口卷边（窄）。
float wallTopR(vec2 p, float pr) {
    float ny = p.y / max(pr, 1e-4);
    return 1.0 + WALL_W * mix(0.55, 1.50, smoothstep(-0.9, 0.9, ny));
}

// 可见内壁环带（底缘 → 沿口之间）：远侧宽且映天花板（亮）、近侧窄暗；
// 沿壁面从底缘（暗）到沿口（亮）渐变。这一圈是"看进锅里"的深度证据。
vec3 innerWallColor(vec2 p, float pr, float bR) {
    float ny = p.y / max(pr, 1e-4);
    float shade = mix(0.50, 1.40, smoothstep(-0.9, 0.9, ny));
    float along = mix(0.55, 1.25, smoothstep(bR, 1.0, pr));
    float winSide = 0.80 + 0.35 * clamp(
        dot(normalize(p + 1e-5), normalize(WIN_DIR.xy)), 0.0, 1.0);
    float ang = atan(p.y, p.x);
    vec3 c = vec3(0.17, 0.18, 0.20) * shade * along * winSide;
    c *= 0.92 + 0.16 * vn(vec2(pr * 300.0, ang * 3.0));
    return c;
}

// 内壁环带着色：近侧（画面下方）迎光亮、远侧背光暗 + 沿口卷边高光
vec3 wallColor(vec2 p, float pr, float wTop) {
    vec3 c = vec3(0.30, 0.31, 0.33);
    float wallShade = mix(1.25, 0.34, smoothstep(-0.45, 0.65, p.y));
    float winSide = 0.80 + 0.35 * clamp(
        dot(normalize(p + 1e-5), normalize(WIN_DIR.xy)), 0.0, 1.0);
    c *= wallShade * winSide;
    // 内壁拉丝（同底面纹向）
    float ang = atan(p.y, p.x);
    c *= 0.92 + 0.16 * vn(vec2(pr * 300.0, ang * 3.0));
    // 越靠口沿越亮（深度渐变）
    c *= mix(0.75, 1.25, smoothstep(1.0, wTop, pr));
    // 沿口卷边：窄亮弧（金属外沿反光，下侧映台面更暖）
    float rimK = exp(-pow((pr - wTop) * 55.0, 2.0));
    c += mix(vec3(0.25, 0.22, 0.19), vec3(0.95, 0.97, 1.0),
        smoothstep(0.2, -0.4, p.y)) * rimK * 0.85;
    return c;
}

// 外壁 + 台面：外壁暗钢渐变，台面暖木 + 锅底投影
vec3 outerColor(vec2 p, float pr, float sd, float wTop) {
    // 外壁（锅外侧，背光）
    float outerBand = smoothstep(wTop, wTop + OUTER_W, pr);
    vec3 wall = vec3(0.09, 0.09, 0.10)
        * mix(1.3, 0.6, smoothstep(-0.5, 0.6, p.y));
    // 台面：暖木色微噪 + 使用痕迹
    vec3 counter = vec3(0.15, 0.115, 0.085)
        * (0.75 + 0.5 * vn(p * 22.0 + sd));
    counter *= 0.85 + 0.3 * fbm(p * 3.0 + 31.0);
    vec3 c = mix(wall, counter, outerBand);
    // 锅的落影（台面上椭圆软影）
    float shadow = exp(-pow((pr - (wTop + OUTER_W + 0.06)) * 3.2, 2.0));
    c *= 1.0 - 0.35 * smoothstep(0.0, 0.5, shadow);
    return c;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5, 0.47));
    float aspect = aspectRatio();

    // ---- 锅局部坐标（椭圆透视；单位圆 = 锅口内沿）----
    float RX = PAN_FILL * aspect;
    float RY = RX * PAN_SQUASH;
    vec2 pc = q - PAN_CENTER;
    vec2 p = pc / vec2(RX, RY);
    float pr = length(p);

    // 热空气扭曲（底面全域）
    float heat = smoothstep(1.0, 0.1, pr);
    vec2 pw = p + (0.004 + 0.005 * heat)
        * vec2(vn(p * 13.0 + ts * 1.1), vn(p * 13.0 + 31.0 - ts * 0.9));

    float panMask = smoothstep(1.02, 0.96, length(pw));

    vec2 g;
    float F = field(pw, ts, sd, g) * panMask;
    F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);
    float m = smoothstep(ISO_LO, ISO_HI, F);

    // ---- 高度场法线：h = √(1−1/F)（球冠解析解）----
    float Fin = max(F, 1.0);
    float hDome = sqrt(max(1.0 - 1.0 / Fin, 0.0));
    float dh = 0.5 / (Fin * Fin * max(hDome, 0.035));
    vec3 n = normalize(vec3(-g * dh, 1.0));

    // ---- 贴合阴影（同一份场推出；背光侧更深）----
    vec2 gn0 = g / (length(g) + 1e-4);
    float azq = atan(pw.y, pw.x);
    float awayWin = 0.5 - 0.5 * cos(azq - atan(WIN_DIR.y, WIN_DIR.x));
    float ringSh = smoothstep(0.30, ISO_LO, F) * (1.0 - m) * panMask
        * (0.75 + 0.5 * awayWin);
    float ao = smoothstep(0.06, 0.30, F) * (1.0 - m) * panMask;

    vec3 col = bg(pw, ts);
    col *= 1.0 - CONTACT_DARKEN * ringSh - AO_DARKEN * ao;

    // ---- 凹底构图：可见底缘随方位收拢，底缘与沿口之间是内壁环带 ----
    float bR = bRAt(p);
    float bottomMask = smoothstep(bR + 0.015, bR, pr);
    float innerWallMask = (1.0 - bottomMask)
        * smoothstep(1.02, 1.0, pr);
    col = mix(col, innerWallColor(p, pr, bR), innerWallMask);

    // ---- 水珠：折射/反射能量混合 ----
    vec3 V = vec3(0.0, 0.0, 1.0);
    float ndv = max(dot(n, V), 0.0);
    float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

    vec2 ruv = pw + gn0 * (1.0 - n.z) * REFRACT_LEN;
    vec3 through = bg(ruv, ts) * 1.35 + envMap(vec3(0.0, 0.0, 1.0)) * LENS_GAIN;
    through *= vec3(0.970, 0.985, 0.998);
    through *= exp(-(1.0 - n.z) * ABSORB_R * vec3(1.35, 1.0, 0.82));
    // 折射体边缘压暗：接触线附近全反射 + 贴合阴影把光"关"在滴内，
    // 轮廓因此清晰（v6 通体均匀亮 = 哑光玻璃珠的病根）
    through *= 1.0 - RIM_DARK * smoothstep(0.45, 0.15, n.z);
    through += WIN_COLOR * pow(ndv, 7.0) * FOCUS_GAIN;
    // 薄缘透光（v9）：接触线最外缘一圈背景透亮——真实液滴边缘薄如透镜，
    // 背景光从薄处穿过来。RIM_DARK 压暗的是 0.06~0.45 的内缘反射区（暗边），
    // 这层亮线只贴 <0.06 的最外沿（n.z 越低越靠边缘），叠加出"暗边 + 亮线"
    through += bg(ruv, ts) * RIM_LIGHT
        * (1.0 - smoothstep(0.06, 0.18, n.z));

    vec3 refl = 2.0 * ndv * n - V;
    vec3 mirrored = envMap(refl);

    // 水珠漫反射（v9）：天空光 diffuse——纯镜面球不存在，表面有微漫
    // 反射，暗侧不至于死黑（ndv 越朝上越亮，像湿润的水面被天光点亮）
    vec3 dropDiff = envMap(vec3(0.0, 0.0, 1.0)) * ndv * DROP_DIFF;

    float crescent = smoothstep(0.35, 0.10, n.z)
        * pow(max(-dot(gn0, normalize(WIN_DIR.xy)), 0.0), 1.6);
    float sparkle = pow(max(dot(refl, BULB_DIR), 0.0), 220.0)
        * (0.6 + 0.4 * vn(pw * 180.0 + ts * 5.0));
    // 灯泡泛光高光（v9）：中锐（pow 60）暖色高光——窗光针尖（pow 320）
    // 之外的真实水珠还有一枚灯泡泛光，双层高光更接近实拍
    float bulbGlow = pow(max(dot(refl, BULB_DIR), 0.0), 60.0)
        * (0.65 + 0.35 * vn(pw * 60.0 + ts * 2.3));
    // 窗光针尖高光：每颗水珠一枚（真实照片里水珠的"湿润感"几乎全在
    // 这枚高光上；位置由法线决定，随形状游动自然滑移）
    float glint = pow(max(dot(refl, WIN_DIR), 0.0), 320.0);

    vec3 drop = mix(through, mirrored, fres);
    drop += dropDiff;
    drop += WIN_COLOR * crescent * CRESCENT_GAIN;
    drop += WIN_COLOR * glint * GLINT_GAIN;
    drop += BULB_COLOR * (sparkle * SPARKLE_GAIN + bulbGlow * BULB_GLOW)
        * (0.7 + 0.6 * uTreble);

    // ---- 接触线薄膜干涉：蒸气垫 + 液滴薄缘的牛顿环虹彩 ----
    float optPath = hDome * IRID_PATH_NM;
    float iridZone = exp(-hDome * hDome * IRID_FALLOFF);
    drop += thinFilm(optPath) * iridZone * IRID_GAIN * (0.55 + 0.45 * awayWin);

    // 水珠只落在可见底面上（不爬上内壁/沿口）
    col = mix(col, drop, m * bottomMask);

    // ---- 飞溅星芒（v10 简化实现）---- 
    // 真实粒子系统需几何 shader / 多 pass，单 pass fragment 内做全套代价
    // 太高；这里用"星芒"作为视觉近似：液滴边缘外的辐射状短亮线群（hash
    // 噪声调向打破对称，6 角星芒 + 时间相位），只在液滴边缘薄带出现
    // ——液滴"看起来"在往外溅小液滴。濒死期（m 边缘 + treble 高）触发更
    // 强。真正的方向飞溅（沿速度方向）需要把 field 内部 vel 传出，超出
    // 当前架构；视觉上星芒 + 噪点足够让用户感知"爆裂"
    float splashBand = (1.0 - m) * smoothstep(0.0, 0.30, m); // 液滴边缘薄带
    float splashAz = atan(pw.y, pw.x)
        + vn(pw * 47.0 + sd) * 0.9   // 角度噪打破对称
        + ts * 0.7;                   // 星芒慢转
    float splashStar = pow(0.5 + 0.5 * cos(splashAz * 6.0), 22.0);
    float splashNoise = vn(pw * 110.0 + ts * 4.0);  // 噪点增强飞溅密度感
    col += WIN_COLOR * splashBand * (splashStar + 0.35 * splashNoise)
        * SPLASH_GAIN * (0.6 + 0.6 * uTreble) * (1.0 - m) * panMask
        * awayWin * bottomMask;

    // ---- 接触处白烟（v10）——每颗水珠周围小范围浓白雾，活跃时更浓----
    // 沸腾的水珠在接触处先冒一小团白烟，再合并到锅口大蒸汽层。位置：
    // 液滴边缘（m<1 的过渡带），半径比水珠大约 30%
    float localSteam = (1.0 - m) * smoothstep(0.05, 0.40, m)
        * fbm(pw * 9.0 + ts * 1.3 + vec2(sd));
    vec3 whiteSteam = vec3(0.78, 0.80, 0.84);
    col = mix(col, whiteSteam, localSteam * STEAM_LOCAL_GAIN
        * (0.65 + 0.55 * uBass) * panMask * bottomMask);

    // ---- 焦散环：液滴透镜聚焦上方光，接触线外缘亮边（光侧，底面上）----
    float caustic = exp(-pow((F - 0.80) / 0.12, 2.0));
    col += WIN_COLOR * caustic * CAUSTIC_GAIN * (1.0 - m) * panMask
        * awayWin * bottomMask;

    // ---- 内壁 / 外壁+台面（底面之外环带，按 pr 混合，无缝）----
    // 沿口半径随方位变化：远侧内壁高、近侧只剩卷边（深锅俯视透视）
    float wTop = wallTopR(p, pr);
    float wallMask = smoothstep(1.0, 1.03, pr)
        * smoothstep(wTop + 0.025, wTop, pr);
    float outerMask = smoothstep(wTop, wTop + 0.03, pr);
    vec3 wallC = wallColor(p, pr, wTop)
        * (1.0 - 0.10 * heat * smoothstep(1.0, 1.18, pr));
    col = mix(col, wallC, wallMask);
    col = mix(col, outerColor(p, pr, sd, wTop), outerMask);

    // ---- 蒸汽：从锅口整个开口面升起（v8 修正位置）----
    // 源强 = 锅口椭圆内部（锅心最强、沿口衰减、锅外为零——蒸汽是从锅里
    // 冒出来的，不是从远侧沿一条线喷）；高度越高越散、越淡。
    vec2 openN = pc / vec2(RX, RY);                 // 锅口归一化坐标
    float openR = length(openN);
    float src = smoothstep(1.10, 0.45, openR);      // 开口面内部为源（锅心最强）
    float baseY = PAN_CENTER.y + RY * 0.55;         // 源起点：锅口中部高度
    float hA = clamp((q.y - baseY) / (0.68 - baseY), 0.0, 1.0);
    float sx = pc.x / RX;
    float spread = exp(-sx * sx * mix(3.0, 1.2, hA));  // 越高越散开
    // 竖缕纹理随时间上移 + 域扭曲（蒸汽不是竖直细条，是扭动的气柱）
    vec2 wq = vec2(q.x * 8.0 + sd, q.y * 3.0 - ts * STEAM_RISE);
    wq += vec2(vn(wq * 1.7 + ts * 0.35), vn(wq * 1.9 - ts * 0.31));
    float wisp = smoothstep(0.42, 0.72, fbm(wq));
    float dens = src * spread * wisp * smoothstep(0.0, 0.08, hA)
        * (1.0 - 0.72 * hA);
    vec3 steamCol = vec3(0.68, 0.71, 0.76)
        * (0.75 + 0.45 * smoothstep(0.25, -0.35, q.x));  // 窗侧逆光更亮
    col = mix(col, steamCol, dens * STEAM_ALPHA * (0.8 + 0.5 * uBass));
    col += steamCol * dens * 0.10;

    // ---- 照片后期链 ----
    col = filmic(col);
    col *= 1.0 - 0.22 * dot(pc * 1.1, pc * 1.1);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 13.0) - 0.5)
        * mix(0.014, 0.004, smoothstep(0.0, 0.5, L)));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
