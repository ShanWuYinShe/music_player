// pan.frag：高温锅底上的莱顿弗罗斯特水珠（照片级重制 v3）。
//
// v3 的物理升级（相对 v2——v2 结构对，材质是"示意图"）：
//   1. 球冠高度场精确法线：h = √(1−1/F) 是元球场 F=r²/d² 下单滴的解析
//      球冠解（d²=r²/F 代入球冠公式直接得）。它自带全部正确的几何：
//      滴心平顶、边缘立墙、斜率 ∝ 1/r（大滴自动摊平、小滴自动更圆），
//      法线 n = normalize(−∇h, 1) 全场连续，颈缩合并处自然过渡。
//      v2 的 tilt=3/(1+(F−1)·k) 是凑的——滴内太平、边缘突变层次错。
//   2. 程序化 3D 环境光 envMap(r)：冷白大窗 + 暖灯泡 + 房间梯度 + 炉灶
//      余温。锅面与水珠共用同一环境——照片感的核心是"所有物体被同一组
//      光照亮"。
//   3. 锅面 = 金属：镜面反射主导（envMap(reflect) × 菲涅耳）+ 拉丝噪声
//      扰动法线（= 刷痕粗糙度，把窗光拉成弧形光带，真拉丝钢的样子），
//      漫反射只占小头。
//   4. 水珠 = 折射/反射能量混合：F = 0.02+0.98(1−cosθ)⁵；滴心看穿
//      （折射锅面 + 吸收 + 焦点亮斑），边缘全反射（窗形高光贴着水珠
//      边缘弯成弧）；再加背光侧亮新月（内全反射的经典标志）。
//   5. 接触阴影：保留从同一份场推出的贴合暗环 + AO，加光源方向不对称。
//   6. 热气：垂直 advect 的 fbm 丝缕，窗侧逆光更可见，bass 增浓。
//   7. 收尾：filmic 色调映射 + 轻暗角 + 亮度加权颗粒（照片后期链）。
//
// 保留 v2 的物理骨架：元球融合、d² 蒸发 + 出生快速长大、蒸气垫颤抖、
// 濒死狂跳 + 边缘泡沫化、角向谐波轮廓、硬约束不出锅沿。
//
// 公共函数（hash/vn/fbm/filmic/dither/…）由工具链从 common.glsl 注入，
// 不要在本文件重复定义。

// ---- 环境光（锅与水珠共用同一组光）----------------------------------------
const vec3 WIN_DIR = vec3(-0.486, 0.549, 0.684);   // 冷白窗（已归一）
const vec3 BULB_DIR = vec3(0.503, 0.302, 0.809);   // 暖灯泡（已归一）
const vec3 WIN_COLOR = vec3(0.92, 1.00, 1.18);
const vec3 BULB_COLOR = vec3(1.30, 0.98, 0.62);
const vec3 ROOM_SKY = vec3(0.085, 0.095, 0.115);   // 房间上半球（厨壁漫反）
const vec3 ROOM_FLOOR = vec3(0.040, 0.028, 0.018); // 下半球（炉灶暗暖）
const float WIN_SHARP = 20.0;      // 窗立体角（pow 锐度；宽一点让更多
                                    //   水珠边缘能挂到窗形高光）
const float BULB_SHARP = 90.0;     // 灯泡更小

// ---- 锅 -------------------------------------------------------------------
const float PAN_R = 0.44;          // 锅内半径（q 空间，圆）
const float PAN_SPEC = 0.62;       // 钢面镜面强度（金属！反射主导）
const float PAN_DIFF = 0.30;       // 钢面漫反射占比
const float BRUSH_PERTURB = 0.085; // 拉丝法线扰动幅度（=粗糙度）
const float DISH_TILT = 0.30;      // 锅底微凹的宏观法线外倾

// ---- 水滴群 ---------------------------------------------------------------
const int DROPLET_COUNT = 15;      // 10 主滴 + 5 卫星滴
const float SATELLITE_FROM = 9.5;
const float R_MAIN_MIN = 0.009;
const float R_MAIN_MAX = 0.058;
const float R_SAT_MIN = 0.005;
const float R_SAT_MAX = 0.016;
const float LIFE_BASE = 7.0;       // 寿命 = BASE + K·r²（d² 蒸发定律）
const float LIFE_K = 9500.0;
const float GROW_PHASE = 0.025;
const float GROW_MIN = 0.10;
const float FIELD_EPS = 1e-7;

// ---- 形状不规则（角向谐波）-------------------------------------------------
const float WOB_SMALL_AMP = 0.05;
const float WOB_BIG_AMP = 0.20;
const float WOB_SIZE_LO = 0.010;
const float WOB_SIZE_HI = 0.045;

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;
const float PANIC_BOOST = 5.0;
const float SIZZLE_FROM = 0.90;
const float SIZZLE_AMP = 2.4;
const float TREMBLE_AMP = 0.0042;
const float TREMBLE_BASS = 1.6;
const float WANDER_NORM = 1.55;
const float SPEED_STRETCH = 0.22;

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;
const float CONTACT_DARKEN = 0.50; // 接触线暗环深度
const float AO_DARKEN = 0.16;

// ---- 水珠材质 -------------------------------------------------------------
const float REFRACT_LEN = 0.052;   // 折射取样偏移量（球透镜）
const float FOCUS_GAIN = 0.50;     // 滴心焦点亮斑（窗光被透镜聚到滴底）
const float LENS_GAIN = 0.45;      // 内部聚光：球透镜把房间环境光聚进
                                    //   滴心——水珠中心比周围锅面亮，
                                    //   这是"活水"的观感来源
const float ABSORB_R = 0.8;        // 边缘路径吸收（克制：内部要亮，
                                    //   暗部交给反射混合去做）
const float CRESCENT_GAIN = 0.70;  // 背光侧内反射亮新月（水珠签名特征）
const float SPARKLE_GAIN = 1.8;    // treble 驱动的闪点

// ---- 热气 / 收尾 ----------------------------------------------------------
const float STEAM_GAIN = 0.05;
const float TRAIL_RISE = 0.0006;
const float TRAIL_GAIN = 0.05;
const float SEED_SPREAD = 173.0;

// 环境辐射：一组方向光照亮整个场景（锅面镜面、水珠反射、锅外炉灶全用它）
vec3 envMap(vec3 r) {
    vec3 c = mix(ROOM_FLOOR, ROOM_SKY, smoothstep(-0.5, 0.45, r.z));
    float w = max(dot(r, WIN_DIR), 0.0);
    c += WIN_COLOR * (pow(w, WIN_SHARP) * 2.8 + pow(w, 6.0) * 0.50);
    float b = max(dot(r, BULB_DIR), 0.0);
    c += BULB_COLOR * (pow(b, BULB_SHARP) * 2.4 + pow(b, 10.0) * 0.22);
    return c;
}

// 水滴元球场：F = Σ r²/d_eff²，g = ∇F（指向滴心的负梯度方向由调用方翻转）。
// d_eff 含运动方向拉伸 + 角向谐波轮廓 + 濒死泡沫化（同 v2）。
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
        float r0 = mix(mix(R_MAIN_MIN, R_MAIN_MAX, pow(h3, 2.6)),
            mix(R_SAT_MIN, R_SAT_MAX, pow(h3, 1.5)), small);
        float P = (LIFE_BASE + LIFE_K * r0 * r0) * (0.70 + 0.60 * h1);
        float age = mod(ts + h2 * P, P);
        float lifeK = age / P;
        float grow = mix(GROW_MIN, 1.0, smoothstep(0.0, GROW_PHASE, lifeK));
        float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
        if (rr < FIELD_EPS) continue;
        float rad = sqrt(rr);
        float sp = (0.9 + 0.5 * h4) * pow(0.020 / max(r0, 0.008), 0.35);
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
        float range = PAN_R - rad - 0.03;
        pos *= range / WANDER_NORM;
        vel *= range / WANDER_NORM;
        vec2 trem = TREMBLE_AMP * panic * (1.0 + TREMBLE_BASS * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        pos += trem;
        float maxR = PAN_R - 2.3 * rad - 0.035;
        if (maxR > 0.0) {
            float pl = length(pos);
            if (pl > maxR) {
                pos *= maxR / pl;
            }
        } else {
            continue;
        }
        vec2 d = q - pos;
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
        w *= 1.0 + sizzle * (vn(q * 260.0 + age * 7.0) - 0.5) * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底：拉丝不锈钢（镜面主导）+ 热氧化回火色 + 使用痕迹 + 锅沿。
// n 由"微凹宏观倾角 + 拉丝法线扰动"构成——扰动即粗糙度，把窗光糊成
// 沿圆周拉长的弧形光带（真拉丝钢的反射形态）。
vec3 bg(vec2 q, float ts) {
    float r = length(q);
    float ang = atan(q.y, q.x);

    // 拉丝：圆周向刷痕（半径高频 / 角度低频）+ 微观法线扰动
    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec2 radialDir = q / max(r, 1e-4);
    vec3 n = normalize(vec3(
        radialDir * (brushHi - 0.5) * BRUSH_PERTURB + q * DISH_TILT, 1.0));

    // 金属着色：漫反射（小头）+ 镜面反射（大头，菲涅耳增强掠射）
    vec3 refl = 2.0 * n.z * n - vec3(0.0, 0.0, 1.0);
    vec3 spec = envMap(refl);
    float fres = 0.55 + 0.40 * pow(1.0 - n.z, 3.0);
    vec3 albedo = vec3(0.30, 0.31, 0.33)
        + vec3(0.045) * (brush - 0.5)
        + vec3(0.026) * (brushHi - 0.5);
    vec3 c = albedo * envMap(vec3(0.0, 0.0, 1.0)) * PAN_DIFF
        + spec * PAN_SPEC * fres;

    // 大尺度使用痕迹（油渍/水垢，低对比乘性）
    c *= 0.92 + 0.16 * fbm(q * 3.2 + 7.0);

    // 热氧化回火色：淡淡的静态径向环带——中心（最热）偏蓝紫，向外渐冷
    // 成稻草黄（不锈钢氧化膜色序，真实炒菜锅底的"彩虹晕"，几乎静止）
    float burner = smoothstep(0.05, 0.14, r) * smoothstep(0.46, 0.30, r);
    float tK = smoothstep(0.10, 0.40, r);
    vec3 temper = mix(vec3(0.42, 0.46, 0.62), vec3(0.60, 0.48, 0.26), tK);
    c = mix(c, temper * (0.35 + 0.65 * fres), burner * 0.22);

    // 锅沿：侧壁渐暗 + 卷边高光弧（用环境光，下侧映炉灶更暗）
    c *= 1.0 - 0.30 * smoothstep(0.36, PAN_R, r);
    float rim = exp(-abs(r - PAN_R) * 80.0);
    c += envMap(normalize(vec3(q / PAN_R * 1.7, 0.6))) * rim * 0.55;

    // 锅外炉灶：近黑微噪
    float outk = smoothstep(PAN_R, 0.54, r);
    c = mix(c, vec3(0.024, 0.024, 0.028) * (0.8 + 0.4 * vn(q * 90.0)), outk);
    return c;
}

void main() {
    float ts = nowSec();
    float sd = seedHash() * SEED_SPREAD;
    vec2 q = sceneUV(vec2(0.5, 0.47));

    // 热空气上升扭曲（锅内全域，越靠锅心越明显）
    float heat = smoothstep(PAN_R, 0.05, length(q));
    vec2 qw = q + (0.0012 + 0.0016 * heat)
        * vec2(vn(q * 13.0 + ts * 1.1), vn(q * 13.0 + 31.0 - ts * 0.9))
        - (0.0006 + 0.0008 * heat);

    // 锅内 mask：用未扭曲坐标判定（场与影都不许溢出锅沿，也不被热浪
    // 抖动带出锅外）
    float panMask = smoothstep(PAN_R + 0.02, PAN_R - 0.05, length(q));

    vec2 g;
    float F = field(qw, ts, sd, g) * panMask;
    F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);

    float m = smoothstep(ISO_LO, ISO_HI, F);

    // ---- 高度场法线：h = √(1−1/F)（单滴解析球冠；斜率 ∝ 1/r 自动缩放）----
    float Fin = max(F, 1.0);
    float hDome = sqrt(max(1.0 - 1.0 / Fin, 0.0));
    // dh/dF = 1/(2F²√(1−1/F))；边缘奇异 → clamp 分母防炸（墙立到 ~88°）
    float dh = 0.5 / (Fin * Fin * max(hDome, 0.035));
    vec3 n = normalize(vec3(-g * dh, 1.0));

    // ---- 贴合阴影（同一份场推出；光源方向不对称：背光侧更深）----
    vec2 gn0 = g / (length(g) + 1e-4);
    float azq = atan(qw.y, qw.x);
    float awayWin = 0.5 - 0.5 * cos(azq - atan(WIN_DIR.y, WIN_DIR.x));
    float ringSh = smoothstep(0.30, ISO_LO, F) * (1.0 - m) * panMask
        * (0.75 + 0.5 * awayWin);
    float ao = smoothstep(0.06, 0.30, F) * (1.0 - m) * panMask;

    vec3 col = bg(qw, ts);
    col *= 1.0 - CONTACT_DARKEN * ringSh - AO_DARKEN * ao;

    // ---- 水珠：折射/反射能量混合 ----
    vec3 V = vec3(0.0, 0.0, 1.0);
    float ndv = max(dot(n, V), 0.0);
    float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);

    // 折射：球透镜放大（偏向滴心；边缘偏移大）；路径吸收（微吸红）；
    // + 内部聚光：透镜把房间环境光聚进滴心（中心明显亮于周围锅面）
    vec2 ruv = qw + gn0 * (1.0 - n.z) * REFRACT_LEN;
    vec3 through = bg(ruv, ts) * 1.45 + envMap(vec3(0.0, 0.0, 1.0)) * LENS_GAIN;
    through *= vec3(0.970, 0.985, 0.998);
    through *= exp(-(1.0 - n.z) * ABSORB_R * vec3(1.35, 1.0, 0.82));
    // 焦点亮斑：窗光被透镜聚到滴底（滴心平顶处最亮）
    through += WIN_COLOR * pow(ndv, 7.0) * FOCUS_GAIN;

    // 反射：环境镜像（边缘高光 = 窗/灯的形状贴着水珠边缘弯成弧）
    vec3 refl = 2.0 * ndv * n - V;
    vec3 mirrored = envMap(refl);

    // 背光侧亮新月：内全反射把环境亮部折到背光侧内缘（水珠的签名特征）
    float crescent = smoothstep(0.35, 0.10, n.z)
        * pow(max(-dot(gn0, normalize(WIN_DIR.xy)), 0.0), 1.6);
    // treble 闪点：细碎的全反射 sparkle（活泼但仍是亮度域）
    float sparkle = pow(max(dot(refl, BULB_DIR), 0.0), 220.0)
        * (0.6 + 0.4 * vn(qw * 320.0 + ts * 5.0));

    vec3 drop = mix(through, mirrored, fres);
    drop += WIN_COLOR * crescent * CRESCENT_GAIN;
    drop += BULB_COLOR * sparkle * SPARKLE_GAIN * (0.7 + 0.6 * uTreble);

    col = mix(col, drop, m);

    // ---- 热气丝缕（窗侧逆光更可见；bass 增浓）----
    float wisp = fbm(vec2(q.x * 6.0 + q.y * 1.5, q.y * 5.0 - ts * 0.5));
    wisp = smoothstep(0.52, 0.78, wisp)
        * smoothstep(PAN_R + 0.06, 0.1, length(q))
        * smoothstep(0.62, 0.30, q.y);
    float litSide = 0.55 + 0.45 * smoothstep(0.2, -0.4, q.x);
    col += WIN_COLOR * wisp * litSide * STEAM_GAIN * (1.0 + 1.2 * uBass)
        * panMask;

    // 极轻反馈：热气拖影
    col += texture2D(uPrev, vUV + vec2(0.0, -TRAIL_RISE)).rgb * TRAIL_GAIN;

    // ---- 照片后期链 ----
    col = filmic(col);
    col *= 1.0 - 0.24 * dot(q * 0.85, q * 0.85);
    float L = dot(col, vec3(0.299, 0.587, 0.114));
    col += vec3((hash21(vUV * uRes + fract(ts) * 13.0) - 0.5)
        * mix(0.014, 0.004, smoothstep(0.0, 0.5, L)));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
