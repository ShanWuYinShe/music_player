// kaleido.frag：万花筒多形态引擎（22s 形态轮换 × 四套结构互异场）。
//
// v3.1 返工要点（"还是年轮缩放"的两层病根）：
//   1. 删掉环带深潜（RINGS）——同心环+恒速缩放正是被点名的无聊形态；
//   2. 形态轮换周期 72s → 22s（两侧 1.5s crossfade）：72s 只对"自动
//      轮播回到本场景"成立，手动挑中本场景盯看时 72s 才换一次脸 =
//      看起来根本没有多形态；22s 保证连续盯看 30s 必见换脸，且大部分
//      18s 出场内也会换一次（crossfade 平滑无跳变）；
//   3. 四套形态的运动语言全部脱离"匀速旋转/缩放"：
//     CHAMBER 真镜室：两面镜夹角 2π/n 的扇形镜室里漂浮半透明玻璃碎块
//               与亮珠；每片对镜轴 abs 一次 = 一片变两片的真实双像；
//               运动 = 碎块漂移 + 亮珠快闪 + 整体摆动（wanderBi 来回）；
//     TUNNEL  透视隧道：n 折管壁面板 + 恒速前飞 + 沿壁扫过的灯环 +
//               镜缝折角阴影（立体管，不是平面环）——唯一的缩放类；
//     MANDALA 呼吸曼陀罗：三层互素重数花瓣、绽放外扩慢周期为运动主轴
//               （v3.1 去掉了三层匀速旋转，花瓣角度改双向摆动）；
//     ROSE    域扭曲玫瑰：两层 rose 花边被演化中的 fbm 域扭曲（v3.1
//               提速 3.5×，流动肉眼可见），花边上有沿边跑的行波微光；
//               θ 只小幅摆动，r 恒定不缩放。
//   形态跳变落在 1.5s crossfade 内，锁定观看/轮播切换都不闪。
//
// 防闪烁与速度铁律沿用（别回退）：色相慢漂 ≤ 每几分钟一圈；音频量只进
// 亮度/幅度；速度类恒定；硬阈值 smoothstep 软化。
//
// 公共函数（hash/vn/fbm/wander/rot/palIQ/satBoost/toneExp/dither/…）由
// 工具链从 common.glsl 注入，不要在本文件重复定义。

// ---- 出场轮换调度 ----------------------------------------------------------
// v3.1：形态周期 72s → 22s。72s 的设计只对"自动轮播回到本场景"成立，
// 用户手动挑中本场景盯看时 72s 才换一次脸 = 看起来根本没有多形态。
// 22s + 两侧 1.5s crossfade：连续盯看 30s 必见一次换形态；轮播场景下
// 一次 18s 出场内也常有一次换脸（crossfade 平滑，无跳变）。
// mod 97 保护 hash 精度（97 质数 → 序列看似不循环）。
const float FORM_PERIOD = 22.0;
const float FORM_KEY_MOD = 97.0;
const float FORM_XF_SEC = 1.5;       // 形态切换的 crossfade 时长（秒）

// ---- CHAMBER（镜室碎玻璃）--------------------------------------------------
const float CH_N_MIN = 6.0;          // 镜室重数下限（6..10 整数）
const float CH_N_SPAN = 4.999;
const float CH_SWAY_RATE = 21.0;     // 整体慢摆（wanderBi 双向，非匀速转）
const float CH_SWAY_AMP = 0.55;      // 摆幅（弧度）
const int CH_SHARDS = 6;             // 碎块数（每片经镜轴双像 × n 折重复）
const float CH_DRIFT_SCALE = 17.0;   // 碎块漂移时间尺度（快一档：
                                     //   镜室要"活着"，慢漂读作静物）
const float CH_BODY_ALPHA = 0.42;    // 片体透射（半透明玻璃）
const float CH_EDGE_GAIN = 0.75;     // 边线（切玻璃轮廓）
const float CH_STREAK_GAIN = 0.30;   // 片内高光条（假环境亮带）
const float CH_BEAD_DENSITY = 0.64;  // 亮珠密度
const float CH_TW_SCALE = 1.6;       // 亮珠闪烁时间尺度（快闪 = 星火感）
const float CH_BASE = 0.045;         // 镜室底色微光

// ---- TUNNEL（透视隧道）-----------------------------------------------------
const float TN_N_MIN = 4.0;
const float TN_N_SPAN = 4.999;
const float TN_SPEED = 0.50;         // 前飞速度（恒定！）
const float TN_PERSP = 0.55;         // 透视系数（深度 = PERSP/r + t·SPEED）
const float TN_RING_RATE = 0.30;     // 灯环空间频率
const float TN_SEAM_DARK = 0.55;     // 镜缝折角阴影深度

// ---- MANDALA（呼吸曼陀罗）--------------------------------------------------
// v3.1：去掉三层匀速旋转（那正是"只是旋转"的观感来源）——花瓣角度改
// wanderBi 来回摆动，运动主轴 = 绽放：花瓣从中心生成、外扩、淡出。
const float MD_BLOOM_RATE = 0.060;   // 绽放周期（~17s 一轮，恒定）
const float MD_SWAY_AMP = 0.45;      // 花瓣层角度摆幅（双向摆动）
const float MD_PETAL_POW = 3.0;      // 花瓣横向锐度

// ---- ROSE（域扭曲玫瑰）-----------------------------------------------------
const float RS_N1_MIN = 5.0;         // 内层玫瑰重数（5..7）
const float RS_N1_SPAN = 2.999;
const float RS_N2_MIN = 8.0;         // 外层玫瑰重数（8..11）
const float RS_N2_SPAN = 3.999;
const float RS_WARP_RATE = 0.16;     // 域扭曲相位演化速率（v3.1 提速 3.5×：
                                     //   花边流动要肉眼可见）
const float RS_EDGE_K = 240.0;       // 花边锐度
const float RS_SWAY_AMP = 0.35;      // θ 摆幅（wanderBi 来回，非匀速旋转）
const float RS_SHIM_RATE = 1.4;      // 花边行波微光（沿边流动的光）

// ---- 色彩 / 收尾 -----------------------------------------------------------
const vec3 PAL_C = vec3(0.9, 1.0, 1.1);
const vec3 PAL_D = vec3(0.0, 0.12, 0.38);
const vec3 PAL_C2 = vec3(1.1, 0.9, 1.0);
const vec3 PAL_D2 = vec3(0.35, 0.10, 0.55);
const float HUE_WANDER = 0.25;
const float TONE_EXPOSURE = 1.05;
const float SAT_BOOST = 0.72;
const float VIGNETTE = 0.30;
const float TRAIL_ZOOM_SOFT = 0.996; // 轻运动模糊（近恒等；隧道前飞在
const float TRAIL_GAIN = 0.30;       //   不同 r 处缩放率不同，无法精确
const float SEED_SPREAD = 173.0;     //   对齐，统一轻模糊即可）

vec3 pal(float t) {
    return palIQ(t, PAL_C, PAL_D);
}

vec3 pal2(float t) {
    return palIQ(t, PAL_C2, PAL_D2);
}

// ---- 玻璃碎块 SDF（type 混合三原型：菱片 / 胶囊 / 环片）---------------------
float shardSDF(vec2 p, float type) {
    if (type < 0.40) {
        // 菱形片
        vec2 s = vec2(0.34, 0.20);
        return (length(max(abs(p) - s, 0.0)) + min(max(abs(p).x - s.x, abs(p).y - s.y), 0.0)) - 0.05;
    } else if (type < 0.75) {
        // 胶囊
        return length(vec2(abs(p.x) - 0.26, p.y * 1.4)) - 0.12;
    }
    // 环片
    return abs(length(p) - 0.28) - 0.07;
}

// ---- 形态 0：真镜室（碎玻璃双像 × 镜缝亮线）---------------------------------
vec3 modeChamber(vec2 q, float ts, float sd) {
    float n = CH_N_MIN + floor(hash11(sd * 0.31 + 3.0) * CH_N_SPAN);
    // 整体慢摆（来回），叠加轻微 bass 摇晃——不是匀速旋转
    float rotA = CH_SWAY_AMP * wanderBi(ts, CH_SWAY_RATE, sd + 5.0)
        + 0.05 * uBass * sin(ts * 1.7);
    float ang = atan(q.y, q.x) + rotA;
    float seg = TAU / n;
    // aa：0 = 镜轴，1 = 镜缝（扇区界）
    float aa = abs(mod(ang, seg) - seg * 0.5) / (seg * 0.5);
    float r = length(q);

    // 镜室底色：径向渐变
    float hueBase = hash11(sd + 7.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4);
    vec3 col = pal(hueBase) * CH_BASE * (1.2 - 0.7 * r);

    // 镜面坐标：u 以镜轴为 0（后续 abs 复制 → 一片变两片）
    float u = (1.0 - aa) * 0.5;      // 0..1（镜轴 → 缝）
    float v = r * 1.35 + 0.05;
    float acc = 0.0;
    for (int j = 0; j < CH_SHARDS; j++) {
        float fj = float(j);
        float h1 = hash11(fj * 7.7 + sd + 1.0);
        float h2 = hash11(fj * 3.3 + sd + 9.0);
        float h3 = hash11(fj * 5.9 + sd + 17.0);
        // 碎块缓漂（wander；纵向缓慢下沉 = 镜筒倾斜转动的观感）
        vec2 sp = vec2(
            (wander2(ts, CH_DRIFT_SCALE, sd + fj * 11.0) - 0.5) * 1.05,
            1.30 - mod(wander2(ts, CH_DRIFT_SCALE * 1.3, sd + fj * 13.0)
                * 1.2 + ts * 0.010 * (0.5 + h1), 1.45));
        float size = 0.13 + 0.16 * h2;
        vec2 d = (vec2(abs(u - sp.x), v - sp.y)) / size;
        float dj = shardSDF(d, h3);
        float alpha = smoothstep(0.03, -0.03, dj);
        float edge = exp(-abs(dj) * 26.0);
        // 片内高光条（假环境：碎块上斜的亮带，h 决定方位）
        float streak = exp(-pow((d.x + d.y * 0.6) - (h1 - 0.5) * 1.2, 2.0) * 22.0)
            * alpha;
        float hue = hueBase + 0.18 * fj / float(CH_SHARDS)
            + 0.06 * sin(ts * 0.02 + fj);
        vec3 sc = mix(pal(hue), pal2(hue),
            smoothstep(0.2, 0.8, wander2(ts, 97.0, sd + 8.8)));
        // 半透明玻璃：透射叠色 + 前片遮挡后片（acc 衰减）
        col += sc * alpha * CH_BODY_ALPHA * (1.0 - acc * 0.6)
            * (0.8 + 0.4 * uBeat);
        col += mix(vec3(1.0), sc, 0.4) * edge * CH_EDGE_GAIN * (1.0 - acc * 0.5);
        col += vec3(0.95, 0.98, 1.05) * streak * CH_STREAK_GAIN;
        acc += alpha * 0.42;
    }

    // 亮珠层（细小高亮点，随 wander 闪烁）
    vec2 bc = floor(vec2(u * 9.0, v * 9.0));
    float bh = hash21(bc + sd);
    float bead = step(1.0 - CH_BEAD_DENSITY * 0.25, bh)
        * exp(-length(fract(vec2(u * 9.0, v * 9.0)) - 0.5
            - vec2(hash21(bc + 3.1), hash21(bc + 5.7))) * 18.0);
    float tw = wander(ts, CH_TW_SCALE, bh * 40.0 + sd);
    col += mix(vec3(1.0), pal(hueBase + 0.15), 0.5) * bead * tw * 1.6;

    // 镜缝亮线（切玻璃感）+ 中心淡出（镜筒尽头的暗腔）
    float seam = exp(-aa * 34.0);
    col += mix(vec3(1.0), pal(hueBase + 0.3), 0.35) * seam * 0.30;
    col *= smoothstep(0.0, 0.05, r);
    return col;
}

// ---- 形态 1：透视隧道飞行 ---------------------------------------------------
vec3 modeTunnel(vec2 q, float ts, float sd) {
    float n = TN_N_MIN + floor(hash11(sd * 0.47 + 11.0) * TN_N_SPAN);
    float rotA = ts * 0.02 + wanderBi(ts, 83.0, sd + 2.0) * 0.8;
    float ang = atan(q.y, q.x) + rotA;
    float seg = TAU / n;
    float fa = abs(mod(ang, seg) - seg * 0.5) / (seg * 0.5); // 0 镜轴 1 缝
    float r = max(length(q), 1e-4);

    // 透视深度：中心 = 极远（消失点），恒速前飞
    float depth = TN_PERSP / r + ts * TN_SPEED;
    // 管壁面板：角向 × 深度网格，每格 hash 明暗
    vec2 pan = vec2(fa * n * 0.85, depth * 2.0);
    vec2 id = floor(pan);
    float hp = hash21(id + sd * 0.17);
    vec2 fp = fract(pan);
    float panelEdge = exp(-min(min(fp.x, 1.0 - fp.x), min(fp.y, 1.0 - fp.y)) * 14.0);
    float panel = 0.30 + 0.70 * hp * hp;

    // 灯环：沿深度周期分布的亮环 + 行波脉冲
    float ringPos = fract(depth * TN_RING_RATE);
    float ring = exp(-pow((ringPos - 0.5) * 4.2, 2.0))
        * (0.5 + 0.8 * hash11(floor(depth * TN_RING_RATE) + sd));
    float pulse = 0.60 + 0.40 * sin(depth * 3.1 + uTreble * 2.0);

    // 折角阴影：靠近镜缝的面板背光更暗 → 立体管
    float shade = mix(1.0, TN_SEAM_DARK, pow(fa, 2.0));

    float hueBase = hash11(sd + 19.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4)
        + 0.06 * depth * 0.05;
    float hue = hueBase + 0.22 * hp + 0.10 * ring;
    vec3 col = pal(hue) * panel * shade * 0.34;
    col += mix(vec3(1.0), pal(hue + 0.12), 0.45) * panelEdge * 0.30 * shade;
    col += pal(hue + 0.30) * ring * pulse * (0.9 + 0.5 * uBeat) * 0.55 * shade;

    // 消失点淡出 + 核心微光
    col *= smoothstep(0.0, 0.07, r);
    col += pal(hueBase + 0.1) * exp(-r * r * 900.0) * (0.4 + 0.6 * uBeat) * 0.7;
    return col;
}

// ---- 形态 2：呼吸曼陀罗 -----------------------------------------------------
vec3 modeMandala(vec2 q, float ts, float sd) {
    float r = length(q);
    float ang = atan(q.y, q.x);
    float breath = 1.0 + 0.05 * uBeat; // beat → 尺寸呼吸（合规：尺寸域）

    vec3 col = vec3(0.0);
    // 三层花瓣：重数互素、绽放相位错开 1/3 周期；角度各做独立摆动
    // （wanderBi 双向，不是匀速旋转——运动主轴是"绽放外扩"）
    float n1 = 5.0 + floor(hash11(sd + 1.0) * 3.0);
    float n2 = 8.0 + floor(hash11(sd + 7.0) * 4.0);
    float n3 = 12.0 + floor(hash11(sd + 13.0) * 5.0);
    float hueBase = hash11(sd + 23.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4);

    // 层 1：内层
    float a1 = ang + MD_SWAY_AMP * wanderBi(ts, 29.0, sd + 1.0) + sd;
    float fa1 = abs(fract(a1 / TAU * n1) - 0.5) * 2.0;
    float b1 = fract(ts * MD_BLOOM_RATE);
    float rr1 = r / (0.34 * breath);
    float env1 = smoothstep(0.05, 0.25, rr1 - b1 * 0.9)
        * smoothstep(1.0, 0.55, rr1 - b1 * 0.9)
        * (1.0 - b1 * 0.55);
    col += pal(hueBase) * pow(max(sin(fa1 * PI), 0.0), MD_PETAL_POW) * env1 * 1.1;

    // 层 2：中层（摆动方向/速率不同）
    float a2 = ang - MD_SWAY_AMP * wanderBi(ts, 37.0, sd + 2.0) + sd * 1.7;
    float fa2 = abs(fract(a2 / TAU * n2) - 0.5) * 2.0;
    float b2 = fract(ts * MD_BLOOM_RATE + 0.33);
    float rr2 = r / (0.62 * breath);
    float env2 = smoothstep(0.05, 0.30, rr2 - b2 * 0.85)
        * smoothstep(1.05, 0.6, rr2 - b2 * 0.85)
        * (1.0 - b2 * 0.55);
    col += pal(hueBase + 0.18) * pow(max(sin(fa2 * PI), 0.0), MD_PETAL_POW * 1.3)
        * env2 * 0.9;

    // 层 3：外层细瓣（摆得更慢）
    float a3 = ang + MD_SWAY_AMP * wanderBi(ts, 23.0, sd + 3.0) + sd * 2.3;
    float fa3 = abs(fract(a3 / TAU * n3) - 0.5) * 2.0;
    float b3 = fract(ts * MD_BLOOM_RATE + 0.66);
    float rr3 = r / (0.95 * breath);
    float env3 = smoothstep(0.05, 0.35, rr3 - b3 * 0.8)
        * smoothstep(1.1, 0.65, rr3 - b3 * 0.8)
        * (1.0 - b3 * 0.55);
    col += pal2(hueBase + 0.36) * pow(max(sin(fa3 * PI), 0.0), 2.2)
        * env3 * 0.75;

    // 核心辉光（beat 镀亮）+ 瓣尖辉光
    col += pal(hueBase + 0.1) * exp(-r * r * 380.0)
        * (0.5 + 0.6 * uBeat);
    col += pal(hueBase + 0.42) * env1 * env2 * 0.30 * (0.6 + 0.6 * uBeat);
    col += pal(hueBase + 0.2) * 0.016; // 基底微光
    return col;
}

// ---- 形态 3：域扭曲玫瑰 -----------------------------------------------------
vec3 modeRose(vec2 q, float ts, float sd) {
    float r = length(q);
    // θ 只小幅来回摆动（wanderBi，非匀速旋转）；r 不缩放
    float th = atan(q.y, q.x) + RS_SWAY_AMP * wanderBi(ts, 41.0, sd + 7.0);

    float n1 = RS_N1_MIN + floor(hash11(sd + 3.0) * RS_N1_SPAN);
    float n2 = RS_N2_MIN + floor(hash11(sd + 9.0) * RS_N2_SPAN);
    float hueBase = hash11(sd + 31.0) + HUE_WANDER * wanderBi(ts, 67.0, sd + 4.4);

    // 域扭曲：两组演化中的 fbm 把 rose 花边揉出流动变形（运动的主轴
    // 是"边界在变形"，不是旋转/缩放）
    float w1 = fbm(vec2(th * 1.6, ts * RS_WARP_RATE) + sd) - 0.5;
    float w2 = fbm(vec2(r * 3.0 - ts * RS_WARP_RATE * 0.7, th * 1.2)
        + sd * 1.7) - 0.5;
    float d1 = abs(r - (0.46 + 0.20 * cos(n1 * th + w1 * 2.4)));
    float d2 = abs(r - (0.72 + 0.16 * cos(n2 * th + 1.7 + w2 * 2.2)));
    float e1 = exp(-d1 * d1 * RS_EDGE_K);
    float e2 = exp(-d2 * d2 * (RS_EDGE_K * 0.8));
    // 沿花边流动的行波微光（光沿边跑，不是花在转）
    float shim = 0.72 + 0.38 * sin(n1 * th * 2.0 + ts * RS_SHIM_RATE
        + uTreble * 2.5);
    e1 *= shim;
    e2 *= 0.80 + 0.30 * sin(n2 * th * 2.0 - ts * RS_SHIM_RATE * 0.8);
    // 花瓣体内渐变填充
    float fill1 = smoothstep(0.22, 0.0, d1) * 0.30;
    float fill2 = smoothstep(0.18, 0.0, d2) * 0.26;

    float hue = hueBase + 0.10 * cos(n1 * th) + 0.10 * sin(ts * 0.008 + sd);
    vec3 col = pal(hue) * (e1 * 1.15 + fill1);
    col += pal(hue + 0.16) * (e2 * 0.9 + fill2);
    col += pal2(hue + 0.38) * e1 * e2 * 0.8 * (0.6 + 0.5 * uBeat);
    // 花心辉光
    col += pal(hueBase + 0.08) * exp(-r * r * 320.0) * (0.45 + 0.55 * uBeat);
    col += pal(hueBase + 0.2) * 0.016; // 基底微光
    return col;
}

// 形态分发
vec3 evalMode(int idx, vec2 q, float ts, float sd) {
    if (idx == 0) return modeChamber(q, ts, sd);
    if (idx == 1) return modeTunnel(q, ts, sd);
    if (idx == 2) return modeMandala(q, ts, sd);
    return modeRose(q, ts, sd);
}

// 出场序号 → 形态（与上一出场不同，避免连续两场同一形态）
float modeForShow(float showIdx, float sd) {
    float key = mod(showIdx, FORM_KEY_MOD);
    float sel = floor(hash11(key * 0.913 + sd) * 4.0);
    float prev = floor(hash11(mod(showIdx - 1.0, FORM_KEY_MOD) * 0.913 + sd) * 4.0);
    if (sel == prev) {
        sel = mod(sel + 1.0 + floor(hash11(key * 3.31 + sd * 1.7) * 3.0), 4.0);
    }
    return sel;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5));

    // ---- 形态轮换：22s 一换，两侧 crossfade（连续盯看 30s 必见换脸）----
    float cyc = ts / FORM_PERIOD;
    float showIdx = floor(cyc);
    float ph = fract(cyc);
    int modeIdx = int(modeForShow(showIdx, sd));
    vec3 col = evalMode(modeIdx, q, ts, sd);
    float xf = FORM_XF_SEC / FORM_PERIOD;
    if (ph < xf) {
        // 向上一形态淡入
        float k = smoothstep(0.0, xf, ph);
        int prevIdx = int(modeForShow(showIdx - 1.0, sd));
        col = mix(evalMode(prevIdx, q, ts, sd), col, k);
    } else if (ph > 1.0 - xf) {
        // 向下一形态淡出
        float k = smoothstep(1.0 - xf, 1.0, ph);
        int nextIdx = int(modeForShow(showIdx + 1.0, sd));
        col = mix(col, evalMode(nextIdx, q, ts, sd), k);
    }

    // beat 只进亮度
    col *= 0.94 + 0.18 * uBeat;
    col *= 1.0 - VIGNETTE * dot(q, q);

    // 反馈拖尾：轻运动模糊（近恒等）
    col += texture2D(uPrev, (vUV - 0.5) * TRAIL_ZOOM_SOFT + 0.5).rgb
        * TRAIL_GAIN;

    col = toneExp(col, TONE_EXPOSURE);
    col = satBoost(col, SAT_BOOST);
    col += dither(vUV * uRes, ts);

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
