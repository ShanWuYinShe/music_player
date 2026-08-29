// pan.frag：高温锅底上的莱顿弗罗斯特水珠（照片级 v4：椭圆透视锅 + 内壁）。
//
// v4 相对 v3 的三处结构返工：
//   1. 椭圆透视锅（v3"看不出是锅内侧"的病根）：v3 锅半径 0.44 定义在
//      宽高比修正坐标里——竖屏 x 可视半宽只有约 0.23，锅沿左右溢出屏幕，
//      锅口根本看不见，只剩中央一块圆面+回火色环 = 看起来像锅外底。
//      v4 锅是**椭圆**：宽按屏宽 84% 自适应（RX=0.42×aspect），y 压扁
//      0.75（俯视透视），并渲染**内壁环带**：近侧内壁（画面下方）迎光
//      反射天花板、远侧背光渐暗、沿口卷边高光弧——一眼看进锅里的构图。
//      水珠场在锅局部坐标（单位圆）计算：屏幕上呈椭圆轨迹与椭圆水珠，
//      与俯视透视物理一致。
//   2. 明亮厨房（v3"水珠黑"的另一半病根）：v3 环境光是深夜厨房（房间
//      上半球 0.045），锅面漫反射底子 ~0.03——水珠透过去必然黑。
//      v4 白天厨房：亮天花板 + 强窗 + 台面暖色，锅面均值亮度提 3~4 倍，
//      水珠内景（透射+聚光）显著亮于周围。
//   3. 蒸汽改为**锅口上方的上升气流**（v3 贴着锅面的亮雾 = "蒸汽沉在锅
//      底"）：竖长条纹理随时间上移、随高度展开消散、半透明白纱混合
//      （不是加亮），窗侧逆光亮化，bass 增浓。
//
// 保留 v3 已验证的物理：球冠高度场法线 h=√(1−1/F)、元球融合、d² 蒸发、
// 蒸气垫颤抖、濒死狂跳+边缘泡沫化、角向谐波轮廓、折射/反射能量混合、
// 背光新月、焦点亮斑、回火色静态径向环带（中心蓝→外缘黄）。
//
// 公共函数（hash/vn/fbm/filmic/dither/…）由工具链从 common.glsl 注入，
// 不要在本文件重复定义。

// ---- 环境光（白天厨房：锅与水珠共用同一组光）--------------------------------
const vec3 WIN_DIR = vec3(-0.486, 0.549, 0.684);   // 冷白窗（已归一）
const vec3 BULB_DIR = vec3(0.503, 0.302, 0.809);   // 暖灯泡（已归一）
const vec3 WIN_COLOR = vec3(1.05, 1.12, 1.30);
const vec3 BULB_COLOR = vec3(1.30, 0.98, 0.62);
const vec3 ROOM_SKY = vec3(0.50, 0.52, 0.56);      // 亮天花板漫射
const vec3 ROOM_FLOOR = vec3(0.14, 0.11, 0.09);    // 台面暖木色
const float WIN_SHARP = 16.0;      // 窗立体角（宽窗：更多水珠挂到窗形高光）
const float BULB_SHARP = 90.0;

// ---- 锅（椭圆透视）---------------------------------------------------------
const float PAN_FILL = 0.42;       // 锅半宽 = FILL × aspect（锅占屏宽 84%）
const float PAN_SQUASH = 0.75;     // y 压扁（俯视透视）
const vec2 PAN_CENTER = vec2(0.0, -0.03);
const float WALL_W = 0.18;         // 内壁环带宽度（锅局部坐标）
const float OUTER_W = 0.10;        // 外壁环带宽度
const float PAN_DIFF = 0.42;       // 钢面漫反射占比
const float PAN_SPEC = 0.62;       // 钢面镜面强度（金属反射主导）
const float BRUSH_PERTURB = 0.085; // 拉丝法线扰动（=粗糙度）

// ---- 水滴群（锅局部坐标：单位圆 = 锅口内沿）---------------------------------
const int DROPLET_COUNT = 15;      // 10 主滴 + 5 卫星滴
const float SATELLITE_FROM = 9.5;
const float R_MAIN_MIN = 0.055;    // 主滴半径区间（帕累托；锅局部单位坐标）
const float R_MAIN_MAX = 0.300;
const float R_SAT_MIN = 0.030;
const float R_SAT_MAX = 0.090;
const float LIFE_BASE = 7.0;       // 寿命 = BASE + K·r²（d² 蒸发定律）
const float LIFE_K = 1150.0;
const float GROW_PHASE = 0.025;
const float GROW_MIN = 0.10;
const float FIELD_EPS = 1e-7;

// ---- 形状不规则（角向谐波）-------------------------------------------------
const float WOB_SMALL_AMP = 0.05;
const float WOB_BIG_AMP = 0.20;
const float WOB_SIZE_LO = 0.060;
const float WOB_SIZE_HI = 0.240;

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;
const float PANIC_BOOST = 5.0;
const float SIZZLE_FROM = 0.90;
const float SIZZLE_AMP = 2.4;
const float TREMBLE_AMP = 0.026;   // 锅局部坐标（约为屏幕坐标的 1/0.35）
const float TREMBLE_BASS = 1.6;
const float WANDER_NORM = 1.55;
const float SPEED_STRETCH = 0.22;

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;
const float CONTACT_DARKEN = 0.50;
const float AO_DARKEN = 0.16;

// ---- 水珠材质 -------------------------------------------------------------
const float REFRACT_LEN = 0.28;    // 折射取样偏移（锅局部坐标）
const float FOCUS_GAIN = 0.50;
const float LENS_GAIN = 0.70;      // 内部聚光（透镜把环境光聚进滴心）
const float ABSORB_R = 0.8;
const float CRESCENT_GAIN = 0.70;
const float SPARKLE_GAIN = 1.8;

// ---- 蒸汽 / 收尾 ----------------------------------------------------------
const float STEAM_ALPHA = 0.30;
const float STEAM_RISE = 0.55;     // 上升速度（屏/秒，恒定）
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

// 水滴元球场（锅局部单位圆坐标）：F = Σ r²/d_eff²，g = ∇F。
// d_eff 含运动方向拉伸 + 角向谐波轮廓 + 濒死泡沫化。
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
        if (rr < FIELD_EPS) continue;
        float rad = sqrt(rr);
        float sp = (0.9 + 0.5 * h4) * pow(0.12 / max(r0, 0.05), 0.35);
        sp = clamp(sp, 0.6, 2.4);
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
        float range = 1.0 - rad - 0.05;
        pos *= range / WANDER_NORM;
        vel *= range / WANDER_NORM;
        vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        pos += trem;
        // 等值面留在底面内（不许爬内壁）
        float maxR = 1.0 - 2.3 * rad - 0.05;
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
        float wamp = mix(WOB_SMALL_AMP, WOB_BIG_AMP, wsize);
        float wrate = (0.6 + 0.9 * h2) * mix(1.8, 0.7, wsize);
        float da = atan(dperp, dpar);
        float wob = 1.0 + wamp * (
            0.55 * sin(2.0 * da + h1 * TAU + age * wrate)
            + 0.30 * sin(3.0 * da + h4 * TAU - age * wrate * 1.37)
            + 0.20 * sin(5.0 * da + h3 * TAU + age * wrate * 0.83));
        float d2 = dlen2 * wob * wob;
        float w = rr / d2;
        float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
        w *= 1.0 + sizzle * (vn(p * 150.0 + age * 7.0) - 0.5) * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底面：拉丝不锈钢（镜面主导）+ 静态回火色环带 + 使用痕迹（锅局部坐标）
vec3 bg(vec2 p, float ts) {
    float r = length(p);
    float ang = atan(p.y, p.x);

    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec2 radialDir = p / max(r, 1e-4);
    vec3 n = normalize(vec3((brushHi - 0.5) * BRUSH_PERTURB * radialDir, 1.0));

    vec3 refl = 2.0 * n.z * n - vec3(0.0, 0.0, 1.0);
    vec3 spec = envMap(refl);
    float fres = 0.55 + 0.40 * pow(1.0 - n.z, 3.0);
    vec3 albedo = vec3(0.38, 0.39, 0.41)
        + vec3(0.045) * (brush - 0.5)
        + vec3(0.026) * (brushHi - 0.5);
    vec3 c = albedo * envMap(vec3(0.0, 0.0, 1.0)) * PAN_DIFF
        + spec * PAN_SPEC * fres;

    c *= 0.92 + 0.16 * fbm(p * 3.2 + 7.0);

    // 回火色：静态径向环带（中心热偏蓝紫 → 外缘冷稻草黄，淡淡的）
    float burner = smoothstep(0.04, 0.12, r) * smoothstep(0.95, 0.60, r);
    float tK = smoothstep(0.12, 0.45, r);
    vec3 temper = mix(vec3(0.42, 0.46, 0.62), vec3(0.60, 0.48, 0.26), tK);
    c = mix(c, temper * (0.35 + 0.65 * fres), burner * 0.22);

    // 远侧底面被内壁轻微遮挡（俯视时远侧底边有一点内壁阴影）
    c *= 1.0 - 0.12 * smoothstep(0.5, 0.95, p.y / max(1e-4, 1.0));
    return c;
}

// 内壁环带着色：近侧（画面下方）迎光亮、远侧背光暗 + 沿口卷边高光
vec3 wallColor(vec2 p, float pr) {
    vec3 c = vec3(0.30, 0.31, 0.33);
    float wallShade = mix(1.25, 0.34, smoothstep(-0.45, 0.65, p.y));
    float winSide = 0.80 + 0.35 * clamp(
        dot(normalize(p + 1e-5), normalize(WIN_DIR.xy)), 0.0, 1.0);
    c *= wallShade * winSide;
    // 内壁拉丝（同底面纹向）
    float ang = atan(p.y, p.x);
    c *= 0.92 + 0.16 * vn(vec2(pr * 300.0, ang * 3.0));
    // 越靠口沿越亮（深度渐变）
    c *= mix(0.75, 1.25, smoothstep(1.0, 1.0 + WALL_W, pr));
    // 沿口卷边：窄亮弧（金属外沿反光，下侧映台面更暖）
    float rimK = exp(-pow((pr - (1.0 + WALL_W)) * 55.0, 2.0));
    c += mix(vec3(0.25, 0.22, 0.19), vec3(0.95, 0.97, 1.0),
        smoothstep(0.2, -0.4, p.y)) * rimK * 0.85;
    return c;
}

// 外壁 + 台面：外壁暗钢渐变，台面暖木 + 锅底投影
vec3 outerColor(vec2 p, float pr, float sd) {
    // 外壁（锅外侧，背光）
    float outerBand = smoothstep(1.0 + WALL_W, 1.0 + WALL_W + OUTER_W, pr);
    vec3 wall = vec3(0.09, 0.09, 0.10)
        * mix(1.3, 0.6, smoothstep(-0.5, 0.6, p.y));
    // 台面：暖木色微噪 + 使用痕迹
    vec3 counter = vec3(0.15, 0.115, 0.085)
        * (0.75 + 0.5 * vn(p * 22.0 + sd));
    counter *= 0.85 + 0.3 * fbm(p * 3.0 + 31.0);
    vec3 c = mix(wall, counter, outerBand);
    // 锅的落影（台面上椭圆软影）
    float shadow = exp(-pow((pr - (1.0 + WALL_W + OUTER_W + 0.06)) * 3.2, 2.0));
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

    // ---- 水珠：折射/反射能量混合 ----
    vec3 V = vec3(0.0, 0.0, 1.0);
    float ndv = max(dot(n, V), 0.0);
    float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

    vec2 ruv = pw + gn0 * (1.0 - n.z) * REFRACT_LEN;
    vec3 through = bg(ruv, ts) * 1.55 + envMap(vec3(0.0, 0.0, 1.0)) * LENS_GAIN;
    through *= vec3(0.970, 0.985, 0.998);
    through *= exp(-(1.0 - n.z) * ABSORB_R * vec3(1.35, 1.0, 0.82));
    through += WIN_COLOR * pow(ndv, 7.0) * FOCUS_GAIN;

    vec3 refl = 2.0 * ndv * n - V;
    vec3 mirrored = envMap(refl);

    float crescent = smoothstep(0.35, 0.10, n.z)
        * pow(max(-dot(gn0, normalize(WIN_DIR.xy)), 0.0), 1.6);
    float sparkle = pow(max(dot(refl, BULB_DIR), 0.0), 220.0)
        * (0.6 + 0.4 * vn(pw * 180.0 + ts * 5.0));

    vec3 drop = mix(through, mirrored, fres);
    drop += WIN_COLOR * crescent * CRESCENT_GAIN;
    drop += BULB_COLOR * sparkle * SPARKLE_GAIN * (0.7 + 0.6 * uTreble);

    col = mix(col, drop, m);

    // ---- 内壁 / 外壁+台面（底面之外环带，按 pr 混合，无缝）----
    float wallMask = smoothstep(1.0, 1.03, pr)
        * smoothstep(1.0 + WALL_W + 0.025, 1.0 + WALL_W, pr);
    float outerMask = smoothstep(1.0 + WALL_W, 1.0 + WALL_W + 0.03, pr);
    vec3 wallC = wallColor(p, pr) * (1.0 - 0.10 * heat * smoothstep(1.0, 1.18, pr));
    col = mix(col, wallC, wallMask);
    col = mix(col, outerColor(p, pr, sd), outerMask);

    // ---- 蒸汽：锅口上方的上升气流（屏幕空间；竖长条缕 + 展开消散）----
    // 高度基准 = 锅口远侧沿（画面上方的锅沿）
    float baseY = PAN_CENTER.y + RY;
    float hA = clamp((q.y - baseY) / (0.62 - baseY), 0.0, 1.0); // 0=锅口 → 1=上缘
    float sx = pc.x / RX;
    float spread = exp(-sx * sx * mix(2.6, 1.1, hA));           // 越高越散开
    float wisp = fbm(vec2(q.x * 9.0 + sd, q.y * 2.6 - ts * STEAM_RISE));
    wisp = smoothstep(0.44, 0.74, wisp);
    float dens = spread * wisp * smoothstep(0.0, 0.10, hA)
        * (1.0 - 0.75 * hA);
    vec3 steamCol = vec3(0.66, 0.69, 0.74)
        * (0.75 + 0.45 * smoothstep(0.25, -0.35, q.x));          // 窗侧逆光更亮
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
