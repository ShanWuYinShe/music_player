// pan.frag：高温锅底上的莱顿弗罗斯特水滴。
//
// 物理要点：
//  - 蒸发遵守 d² 定律（半径平方随时间线性下降）→ 主滴寿命 38~68 秒，
//    不会"很快消失"；小卫星滴 14~24 秒；
//  - 水滴用元球（metaball）场表达：两滴靠近时场自然颈缩融合，
//    无需特判"合并事件"；
//  - 蒸气垫让水滴快速游走 + 高频颤抖（真水滴是"蹿"不是"漂"），
//    濒死时疯狂跳动并泡沫化；
//  - 水滴被硬约束在锅内：游走中心按半径收边 + 场乘锅内 mask，
//    等值面不可能溢出锅沿（旧版水滴会跑到锅外）；
//  - 运动方向轻微拉长（真水滴蹿动时会沿速度方向变形）；
//  - 材质：折射锅底（球透镜向心取样）+ 主/辅双高光 + 菲涅尔亮边
//    （下沿反射炉火橙、上沿反射冷光）+ 边缘焦散亮环 + 锅面接触影。
//
// 锅底刻画：铸铁暗底 + 车削同心纹 + 油膜薄干涉彩 + 炉头炽热余烬环
// （fbm 调制的热点）+ 锅壁向沿渐暗（体积感）+ 锅沿金属反光弧。
//
// 公共函数（hash/vn/fbm/hue2rgb/toneExp/applyTransition/…）由工具链从
// common.glsl 注入，不要在本文件重复定义。

// ---- 锅 -------------------------------------------------------------------
const float PAN_R = 0.44;            // 锅内半径（q 空间，圆）

// ---- 水滴群 -------------------------------------------------------------
const int DROPLET_COUNT = 13;        // 9 主滴 + 4 卫星滴
const float SATELLITE_FROM = 8.5;    // fi ≥ 8.5 的是卫星滴
const float LIFE_MAIN_MIN = 38.0;    // 主滴寿命区间（秒）
const float LIFE_MAIN_SPAN = 30.0;
const float LIFE_SAT_MIN = 14.0;     // 卫星滴寿命区间（秒）
const float LIFE_SAT_SPAN = 10.0;
const float R_MAIN_BASE = 0.030;     // 主滴半径区间
const float R_MAIN_SPAN = 0.028;
const float R_SAT_BASE = 0.010;      // 卫星滴半径区间
const float R_SAT_SPAN = 0.008;
const float GROW_PHASE = 0.025;      // 出生后快速长大的寿命占比
const float GROW_MIN = 0.10;         // 出生时的初始半径比例
const float FIELD_EPS = 1e-7;        // 场贡献下限（蒸发完的滴跳过）

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;       // 寿命占比超过它开始狂跳
const float PANIC_BOOST = 5.0;       // 濒死颤抖放大倍数
const float SIZZLE_FROM = 0.90;      // 寿命占比超过它场注入噪声 → 边缘泡沫化
const float SIZZLE_AMP = 2.4;
const float TREMBLE_AMP = 0.0042;    // 蒸气垫高频颤抖幅度
const float TREMBLE_BASS = 1.6;      // bass 加重颤抖
const float WANDER_NORM = 1.55;      // 正弦叠加的天然限幅
const float SPEED_STRETCH = 0.30;    // 运动方向拉长系数（速度 → 变形）

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;           // 水滴表面等值区间（smoothstep 两端）
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;        // 节拍 → 表面微沸腾
const vec2 SHADOW_OFFSET = vec2(0.016, -0.014); // 主光来自左上 → 影落右下
const float SHADOW_DARKEN = 0.50;

// ---- 材质 -----------------------------------------------------------------
const float REFRACT_LEN = 0.030;     // 折射取样向滴心偏移量（球透镜放大）
const vec3 LIGHT_MAIN = vec3(-0.42, 0.60, 0.68);
const vec3 LIGHT_FILL = vec3(0.55, -0.35, 0.55);
const float SPEC_MAIN_POW = 140.0;   // 主高光锐度（更紧更玻璃）
const float SPEC_FILL_POW = 45.0;
const float FRESNEL_POW = 3.0;       // 菲涅尔亮边锐度（更薄更真）
const vec3 RIM_COLD = vec3(0.55, 0.72, 1.0);  // 上沿反射冷光
const vec3 RIM_WARM = vec3(1.0, 0.42, 0.12);  // 下沿反射炉火橙

// ---- 收尾 -----------------------------------------------------------------
const float TRAIL_RISE = 0.0006;     // 热气拖影上飘速度
const float TRAIL_GAIN = 0.06;       // 极轻反馈（重了就糊）
const float SEED_SPREAD = 173.0;

// 水滴元球场：F = Σ r²/d²（运动方向各向异性拉长），g = ∇F（近似，指向滴心）。
// 濒死（lifeK→1）时场注入噪声 → 边缘泡沫化。
float field(vec2 q, float ts, float sd, out vec2 g) {
    g = vec2(0.0);
    float F = 0.0;
    for (int i = 0; i < DROPLET_COUNT; i++) {
        float fi = float(i);
        float small = step(SATELLITE_FROM, fi);
        float h1 = hash11(fi * 7.13 + sd);
        float h2 = hash11(fi * 3.71 + sd + 11.0);
        float h3 = hash11(fi * 5.39 + sd + 23.0);
        float h4 = hash11(fi * 9.17 + sd + 37.0);
        float P = mix(LIFE_MAIN_MIN + LIFE_MAIN_SPAN * h1, LIFE_SAT_MIN + LIFE_SAT_SPAN * h1, small);
        float age = mod(ts + h2 * P, P);
        float lifeK = age / P;
        float r0 = mix(R_MAIN_BASE + R_MAIN_SPAN * h3, R_SAT_BASE + R_SAT_SPAN * h3, small);
        // d² 蒸发定律 + 出生一小段寿命内快速长大
        float grow = mix(GROW_MIN, 1.0, smoothstep(0.0, GROW_PHASE, lifeK));
        float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
        if (rr < FIELD_EPS) continue;
        float rad = sqrt(rr);
        // 游走轨迹（正弦叠加，光滑且天然限幅 WANDER_NORM）；
        // 角速度 ~2.5×旧版——真水滴是快速蹿动，不是缓慢漂浮
        float sp = mix(1.0, 1.9, small);
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
        // 解析速度（用于运动方向拉长）
        vec2 vel = vec2(
            w1 * cos(age * w1 + p1) + 0.55 * w2 * cos(age * w2 + p2),
            -w3 * sin(age * w3 + p3) - 0.55 * w4 * sin(age * w4 + p4));
        float range = PAN_R - rad - 0.03;
        pos *= range / WANDER_NORM;
        vel *= range / WANDER_NORM;
        // 蒸气垫高频颤抖（bass 加重）
        vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        pos += trem;
        // 硬约束：等值面（约 2.1 倍半径）必须留在锅内，一滴都不许出锅
        float maxR = PAN_R - 2.1 * rad - 0.012;
        if (maxR > 0.0) {
            float pl = length(pos);
            if (pl > maxR) {
                pos *= maxR / pl;
            }
        } else {
            continue; // 滴太大收不进锅（理论上不发生），跳过
        }
        vec2 d = q - pos;
        // 运动方向拉长：沿速度压缩、横向膨胀（真水滴蹿动变形）
        float spd = length(vel);
        float k = clamp(spd * SPEED_STRETCH, 0.0, 0.6);
        vec2 vh = vel / max(spd, 1e-4);
        float dpar = dot(d, vh) * (1.0 - 0.24 * k);
        float dperp = dot(d, vec2(-vh.y, vh.x)) * (1.0 + 0.18 * k);
        float d2 = dpar * dpar + dperp * dperp + 1e-6;
        float w = rr / d2;
        // 濒死泡沫化
        float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
        w *= 1.0 + sizzle * (vn(q * 260.0 + age * 7.0) - 0.5) * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底：铸铁暗底 + 车削同心纹 + 油膜薄干涉彩 + 炉头余烬环 + 锅壁渐暗 + 锅沿金属弧
vec3 bg(vec2 q, float ts) {
    float r = length(q);
    // 铸铁：暗底 + 同心车削纹 + 颗粒
    float rings = 0.5 + 0.5 * sin(r * 240.0 + vn(q * 36.0) * 2.5);
    float grain = vn(q * 300.0);
    vec3 c = vec3(0.030, 0.032, 0.038);
    c += vec3(0.016, 0.016, 0.018) * rings;
    c += vec3(0.014) * (grain - 0.5);
    // 腌渍/使用痕迹：大尺度暗斑
    c *= 0.85 + 0.30 * fbm(q * 3.4 + 17.0);
    // 油膜薄干涉彩（极轻，转动视角般的虹彩）
    float film = fbm(q * 5.2 + vec2(3.1, ts * 0.008));
    c += hue2rgb(film * 1.6 + 0.55) * 0.012 * smoothstep(0.15, 0.40, r);
    // 炉头余烬环：收窄到一圈（旧版太宽整锅泛红），fbm 调制的热点 + 呼吸
    float pulse = 0.85 + 0.15 * sin(ts * 0.8);
    float embers = 0.55 + 0.45 * fbm(vec2(atan(q.y, q.x) * 4.0, r * 30.0 - ts * 0.35));
    float ring = exp(-pow((r - 0.29) * 10.0, 2.0));
    c += vec3(0.42, 0.09, 0.02) * ring * (0.28 + 0.32 * embers) * pulse;
    float core = exp(-r * 5.5);
    c += vec3(0.24, 0.05, 0.012) * core * (0.30 + 0.30 * embers) * pulse;
    // 锅壁向沿渐暗（体积感：光是斜射进锅的）
    c *= 1.0 - 0.38 * smoothstep(0.28, PAN_R, r);
    // 锅沿金属反光弧（下侧受炉火反光更亮）
    float rim = exp(-abs(r - PAN_R) * 90.0);
    c += vec3(0.22, 0.24, 0.28) * rim * (0.55 + 0.35 * clamp(-q.y, 0.0, 1.0));
    // 锅外压暗
    c *= 1.0 - smoothstep(PAN_R, 0.52, r) * 0.72;
    return c;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5, 0.47));

    // 热空气上升扭曲（炉环上方更明显）
    float heat = exp(-pow((length(q) - 0.29) * 3.0, 2.0));
    vec2 qw = q + (0.0018 + 0.0016 * heat)
        * vec2(vn(q * 13.0 + ts * 1.1), vn(q * 13.0 + 31.0 - ts * 0.9))
        - (0.0009 + 0.0008 * heat);

    // 锅内 mask：场与影都不许溢出锅沿
    float panMask = smoothstep(PAN_R + 0.02, PAN_R - 0.05, length(qw));

    vec2 g;
    float F = field(qw, ts, sd, g) * panMask;
    F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);

    float m = smoothstep(ISO_LO, ISO_HI, F);

    // 接触影（只在水滴外、锅内）
    vec2 gs;
    float Fs = field(qw + SHADOW_OFFSET, ts, sd, gs);
    float shadow = smoothstep(0.45, 1.3, Fs) * (1.0 - m) * panMask;

    vec3 col = bg(qw, ts);
    col *= 1.0 - SHADOW_DARKEN * shadow;

    // ---- 水滴材质 ----
    // 球冠剖面：边缘斜率最大、滴心平顶（tilt 随 F 增大而减小）
    vec2 gn = g / (length(g) + 1e-4);
    float tilt = 3.0 / (1.0 + max(F - 1.0, 0.0) * 1.2);
    vec3 n = normalize(vec3(-gn * tilt, 1.0));

    vec3 L = normalize(LIGHT_MAIN);
    vec3 V = vec3(0.0, 0.0, 1.0);

    // 折射：向滴心取样（球透镜放大倒像），折射量随斜率增大、限制在滴内
    vec2 ruv = qw + gn * tilt * REFRACT_LEN;
    vec3 through = bg(ruv, ts);
    through *= vec3(0.88, 0.95, 1.05);
    through *= mix(0.88, 0.66, clamp((F - 1.0) * 0.15, 0.0, 1.0));

    float spec = pow(max(dot(reflect(-L, n), V), 0.0), SPEC_MAIN_POW);
    vec3 L2 = normalize(LIGHT_FILL);
    float spec2 = pow(max(dot(reflect(-L2, n), V), 0.0), SPEC_FILL_POW);
    float fres = pow(1.0 - max(n.z, 0.0), FRESNEL_POW);
    // 菲涅尔亮边：下沿拾取炉火橙，上沿冷光
    float down = clamp(0.5 - n.y * 2.4, 0.0, 1.0);
    vec3 rimCol = mix(RIM_COLD, RIM_WARM, down);
    // 边缘内侧焦散亮环（treble 让环面闪烁）
    float ca = smoothstep(1.05, 1.35, F) * smoothstep(2.9, 1.45, F);
    ca *= 0.75 + 0.5 * uTreble * vn(q * 160.0 + ts * 3.0);

    vec3 drop = through;
    drop += rimCol * fres * 0.55;
    drop += vec3(1.0, 0.97, 0.90) * spec * (1.6 + 0.7 * uTreble);
    drop += vec3(0.8, 0.9, 1.0) * spec2 * 0.30;
    drop += vec3(1.0, 0.85, 0.6) * ca * 0.40;

    col = mix(col, drop, m);

    // 极轻反馈：热气拖影（向上飘）
    col += texture2D(uPrev, vUV + vec2(0.0, -TRAIL_RISE)).rgb * TRAIL_GAIN;

    col = toneExp(col, 1.05);
    col = pow(col, vec3(0.95));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
