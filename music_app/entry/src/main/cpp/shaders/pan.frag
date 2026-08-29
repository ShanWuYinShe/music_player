// pan.frag：高温锅底上的莱顿弗罗斯特水滴（写实向重制版）。
//
// 重制对照（旧版三处"假"的根源）：
//   1. 锅底：旧版是规则 sin 同心圆纹 + 近黑铸铁色 + 烧红炉环——
//      规则等距圆纹读起来就是年轮；锅底烧到红热 (>500°C) 时水滴早已
//      瞬间汽化，莱顿弗罗斯特效应 (~200°C) 的锅底不该发红光。
//      新版 = 拉丝不锈钢：刷痕沿圆周方向的高频低对比各向异性噪声
//      （真锅底的拉丝是亚毫米细纹，明暗差肉眼刚可辨）+ 宽阔镜面光泽
//      梯度 + 炉头区的热氧化回火色（稻草黄↔钢蓝的不规则斑块——
//      这才是热锅底最真实的标志性特征）+ 大尺度使用痕迹。
//   2. 水珠：旧版全是正圆（元球仅沿运动方向拉伸）。新版给每滴水
//      加角向谐波扰动（2/3/5 阶正弦叠加在有效距离上）——轮廓呈
//      圆三角/椭圆/不规则 blob 且随时间 churn；大小改帕累托分布
//      （大量小滴 + 少量大滴），寿命按 d² 蒸发定律 ∝ 初始面积
//      （大滴活得久），小滴蹿得快、大滴晃得慢——全是物理一致的方向。
//   3. 阴影/贴合：旧版是整块偏移采样的"投影"，水滴像浮在锅上。
//      真实水滴没有分离投影：蒸气隙在接触线形成紧贴边缘的暗环 +
//      一圈极轻的环境光遮蔽。新阴影全部从同一份元球场推出
//      （F 的等值带），水滴必然贴合锅底，且省掉第二次全场求值。
//
// 保留的物理骨架（这些是对的）：元球场融合（靠近自然颈缩合并）、
// d² 蒸发 + 出生快速长大、蒸气垫高频颤抖（真水滴是"蹿"不是"漂"）、
// 濒死狂跳 + 边缘泡沫化、硬约束不出锅沿、球透镜向心折射 +
// 主/辅双高光 + 菲涅尔亮边 + 边缘内侧焦散环。
//
// 公共函数（hash/vn/fbm/hue2rgb/toneExp/applyTransition/…）由工具链从
// common.glsl 注入，不要在本文件重复定义。

// ---- 锅 -------------------------------------------------------------------
const float PAN_R = 0.44;            // 锅内半径（q 空间，圆）

// ---- 水滴群 -------------------------------------------------------------
const int DROPLET_COUNT = 15;        // 10 主滴 + 5 卫星滴
const float SATELLITE_FROM = 9.5;    // fi ≥ 9.5 的是卫星滴
const float R_MAIN_MIN = 0.009;      // 主滴半径区间（帕累托：pow(u,2.6)，
const float R_MAIN_MAX = 0.058;      //   大量小滴 + 少量大滴）
const float R_SAT_MIN = 0.005;       // 卫星滴半径区间
const float R_SAT_MAX = 0.016;
const float LIFE_BASE = 7.0;         // 寿命 = BASE + K·r²（d² 蒸发定律：
const float LIFE_K = 9500.0;         //   蒸发时间 ∝ 初始面积。r=0.01→~8s，
                                     //   r=0.03→~16s，r=0.058→~39s）
const float GROW_PHASE = 0.025;      // 出生后快速长大的寿命占比
const float GROW_MIN = 0.10;         // 出生时的初始半径比例
const float FIELD_EPS = 1e-7;        // 场贡献下限（蒸发完的滴跳过）

// ---- 形状不规则（角向谐波扰动）--------------------------------------------
const float WOB_SMALL_AMP = 0.05;    // 小滴：近球形，仅微扰
const float WOB_BIG_AMP = 0.20;      // 大滴：摊成水洼，轮廓大幅晃动
const float WOB_SIZE_LO = 0.010;     // 扰动幅度随半径插值的区间
const float WOB_SIZE_HI = 0.045;

// ---- 游走与濒死 ----------------------------------------------------------
const float PANIC_FROM = 0.93;       // 寿命占比超过它开始狂跳
const float PANIC_BOOST = 5.0;       // 濒死颤抖放大倍数
const float SIZZLE_FROM = 0.90;      // 寿命占比超过它场注入噪声 → 边缘泡沫化
const float SIZZLE_AMP = 2.4;
const float TREMBLE_AMP = 0.0042;    // 蒸气垫高频颤抖幅度
const float TREMBLE_BASS = 1.6;      // bass 加重颤抖
const float WANDER_NORM = 1.55;      // 正弦叠加的天然限幅
const float SPEED_STRETCH = 0.22;    // 运动方向拉长系数（速度 → 变形；
                                     //   幅度低于旧版——形状不规则已由
                                     //   角向扰动承担，别再叠出"香蕉形"）

// ---- 场到表面的判定 -------------------------------------------------------
const float ISO_LO = 0.85;           // 水滴表面等值区间（smoothstep 两端）
const float ISO_HI = 1.15;
const float BEAT_BOIL = 0.05;        // 节拍 → 表面微沸腾
const float CONTACT_DARKEN = 0.52;   // 接触线暗环深度
const float AO_DARKEN = 0.16;        // 外围环境遮蔽深度

// ---- 材质 -----------------------------------------------------------------
const float REFRACT_LEN = 0.030;     // 折射取样向滴心偏移量（球透镜放大）
const vec3 LIGHT_MAIN = vec3(-0.42, 0.60, 0.68);
const vec3 LIGHT_FILL = vec3(0.55, -0.35, 0.55);
const float SPEC_MAIN_POW = 110.0;   // 主高光锐度（小滴上也要看得出亮点，
                                     //   160 在小滴上收成亚像素点 = 看不见）
const float SPEC_FILL_POW = 45.0;
const float FRESNEL_POW = 4.0;       // 菲涅尔亮边锐度（收窄到贴边一薄圈，
                                     //   3.0 的宽边 + 焦散叠出"垫圈"感）
const vec3 RIM_UP = vec3(0.72, 0.80, 0.94);   // 上沿反射环境光（窗/灯，亮）
const vec3 RIM_DOWN = vec3(0.05, 0.05, 0.06); // 下沿反射炉灶（暗）

// ---- 收尾 -----------------------------------------------------------------
const float TRAIL_RISE = 0.0006;     // 热气拖影上飘速度
const float TRAIL_GAIN = 0.06;       // 极轻反馈（重了就糊）
const float SEED_SPREAD = 173.0;

// 水滴元球场：F = Σ r²/d_eff²，g = ∇F（近似，指向滴心）。
// d_eff 含两项变形：运动方向各向异性拉伸 + 角向谐波轮廓扰动（不规则感核心）。
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
        // 帕累托大小分布：pow 偏置小滴（主滴 2.6 次、卫星滴 1.5 次）
        float r0 = mix(mix(R_MAIN_MIN, R_MAIN_MAX, pow(h3, 2.6)),
            mix(R_SAT_MIN, R_SAT_MAX, pow(h3, 1.5)), small);
        // d² 蒸发定律：寿命 ∝ 初始面积（大滴持久、小滴转瞬即逝）
        float P = (LIFE_BASE + LIFE_K * r0 * r0) * (0.70 + 0.60 * h1);
        float age = mod(ts + h2 * P, P);
        float lifeK = age / P;
        // d² 蒸发：半径平方随时间线性下降 + 出生一小段寿命内快速长大
        float grow = mix(GROW_MIN, 1.0, smoothstep(0.0, GROW_PHASE, lifeK));
        float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
        if (rr < FIELD_EPS) continue;
        float rad = sqrt(rr);
        // 游走轨迹（正弦叠加，光滑且天然限幅 WANDER_NORM）；
        // 小滴蹿得快、大滴挪得慢（蒸气垫托小滴更灵）
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
        // 运动方向拉长：沿速度压缩、横向膨胀
        float spd = length(vel);
        float k = clamp(spd * SPEED_STRETCH, 0.0, 0.6);
        vec2 vh = vel / max(spd, 1e-4);
        float dpar = dot(d, vh) * (1.0 - 0.24 * k);
        float dperp = dot(d, vec2(-vh.y, vh.x)) * (1.0 + 0.18 * k);
        // 角向谐波轮廓扰动：有效距离随方向按 2/3/5 阶正弦起伏 →
        // 轮廓呈圆三角/椭圆/不规则 blob；相位随时间旋转 = 形状在 churn；
        // 大滴（摊成水洼）扰动大且晃得慢，小滴近球形且抖得快
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
        // 濒死泡沫化
        float sizzle = smoothstep(SIZZLE_FROM, 1.0, lifeK);
        w *= 1.0 + sizzle * (vn(q * 260.0 + age * 7.0) - 0.5) * SIZZLE_AMP;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底：拉丝不锈钢 + 宽阔光泽梯度 + 热氧化回火色斑块 + 使用痕迹 + 锅沿。
// 没有任何规则同心纹——拉丝是沿圆周方向的各向异性噪声，不是年轮。
vec3 bg(vec2 q, float ts) {
    float r = length(q);
    float ang = atan(q.y, q.x);

    // 拉丝：刷痕沿圆周方向（半径方向高频、角度方向低频的各向异性噪声），
    // 幅度 ±0.02 量级——真锅底的亚毫米细纹，刚可辨，不是沟
    float brush = vn(vec2(r * 260.0, ang * 3.0));
    float brushHi = vn(vec2(r * 720.0 + 40.0, ang * 9.0));
    vec3 c = vec3(0.30, 0.31, 0.33);
    c += vec3(0.045) * (brush - 0.5);
    c += vec3(0.026) * (brushHi - 0.5);

    // 宽阔镜面光泽：主光从左上来 → 左上软亮、右下渐暗（体积光感）
    c *= 0.80 + 0.42 * clamp(0.5 - q.x * 0.8 + q.y * 0.6, 0.0, 1.0);

    // 大尺度使用痕迹：油渍/水垢/烧灼斑（fbm 斑块，低对比）
    c *= 0.92 + 0.16 * fbm(q * 3.2 + 7.0);

    // 热氧化回火色：不锈钢长烧后炉头区的氧化膜色——稻草黄/琥珀 ↔ 钢蓝
    // 的不规则斑块（热锅底最真实的标志；不是发红光，200°C 远不到红热）
    float burner = smoothstep(0.08, 0.16, r) * smoothstep(0.44, 0.30, r);
    float tp = fbm(vec2(ang * 2.5 + 3.0, r * 9.0 - 2.0));
    vec3 temper = mix(vec3(0.55, 0.38, 0.16), vec3(0.16, 0.26, 0.50),
        smoothstep(0.25, 0.75, tp));
    c = mix(c, temper, burner * 0.50 * (0.4 + 0.6 * fbm(q * 5.0 + 11.0)));

    // 锅底中部微凹的柔光斑
    c += vec3(0.030, 0.032, 0.035) * exp(-r * r * 18.0);

    // 锅沿：侧壁向沿渐暗 + 卷边金属高光弧（下侧受环境反光更亮）
    c *= 1.0 - 0.30 * smoothstep(0.36, PAN_R, r);
    float rim = exp(-abs(r - PAN_R) * 80.0);
    c += vec3(0.20, 0.21, 0.23) * rim * (0.45 + 0.40 * clamp(-q.y + 0.3, 0.0, 1.0));

    // 锅外炉灶：近黑（微噪，别死黑）
    float outk = smoothstep(PAN_R, 0.54, r);
    c = mix(c, vec3(0.028, 0.028, 0.032) * (0.8 + 0.4 * vn(q * 90.0)), outk);
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

    // 锅内 mask：场与影都不许溢出锅沿
    float panMask = smoothstep(PAN_R + 0.02, PAN_R - 0.05, length(qw));

    vec2 g;
    float F = field(qw, ts, sd, g) * panMask;
    F *= 1.0 + BEAT_BOIL * uBeat * sin(ts * 31.0);

    float m = smoothstep(ISO_LO, ISO_HI, F);

    // 贴合阴影（全部从同一份场推出，水滴必然贴锅）：
    //   接触环 = 紧贴水滴外缘的暗环（蒸气隙阴影 + 边缘全反射），
    //   AO     = 外扩一圈极轻的环境遮蔽；
    //   只在水滴外、锅内。旧版"偏移采样投影"会让水滴看起来像浮起来，已拆。
    float ringSh = smoothstep(0.30, ISO_LO, F) * (1.0 - m) * panMask;
    float ao = smoothstep(0.06, 0.30, F) * (1.0 - m) * panMask;

    vec3 col = bg(qw, ts);
    col *= 1.0 - CONTACT_DARKEN * ringSh - AO_DARKEN * ao;

    // ---- 水滴材质 ----
    // 球冠剖面：边缘斜率最大、滴心平顶（tilt 随 F 增大而减小）
    vec2 gn = g / (length(g) + 1e-4);
    float tilt = 3.0 / (1.0 + max(F - 1.0, 0.0) * 1.2);
    vec3 n = normalize(vec3(-gn * tilt, 1.0));

    vec3 L = normalize(LIGHT_MAIN);
    vec3 V = vec3(0.0, 0.0, 1.0);

    // 折射：向滴心取样（球透镜放大倒像），折射量随斜率增大、限制在滴内；
    // 放大的是新锅底的拉丝与回火色斑——透过水滴看得到锅面纹理才叫贴锅
    vec2 ruv = qw + gn * tilt * REFRACT_LEN;
    vec3 through = bg(ruv, ts);
    through *= vec3(0.90, 0.96, 1.04);
    through *= mix(0.92, 0.70, clamp((F - 1.0) * 0.15, 0.0, 1.0));

    float spec = pow(max(dot(reflect(-L, n), V), 0.0), SPEC_MAIN_POW);
    vec3 L2 = normalize(LIGHT_FILL);
    float spec2 = pow(max(dot(reflect(-L2, n), V), 0.0), SPEC_FILL_POW);
    float fres = pow(1.0 - max(n.z, 0.0), FRESNEL_POW);
    // 菲涅尔亮边：上沿拾取环境亮光、下沿没入炉灶暗部（光源方向唯一）
    float up = clamp(0.5 + n.y * 2.4, 0.0, 1.0);
    vec3 rimCol = mix(RIM_DOWN, RIM_UP, up);
    // 边缘内侧焦散亮环（treble 让环面闪烁）
    float ca = smoothstep(1.05, 1.35, F) * smoothstep(2.9, 1.45, F);
    ca *= 0.75 + 0.5 * uTreble * vn(q * 160.0 + ts * 3.0);

    vec3 drop = through;
    drop += rimCol * fres * 0.45;
    drop += vec3(1.0, 0.98, 0.94) * spec * (2.2 + 0.8 * uTreble);
    drop += vec3(0.8, 0.9, 1.0) * spec2 * 0.30;
    drop += vec3(0.95, 0.92, 0.80) * ca * 0.25;

    col = mix(col, drop, m);

    // 极轻反馈：热气拖影（向上飘）
    col += texture2D(uPrev, vUV + vec2(0.0, -TRAIL_RISE)).rgb * TRAIL_GAIN;

    col = toneExp(col, 1.05);
    col = pow(col, vec3(0.95));

    col = applyTransition(col);

    gl_FragColor = vec4(col, 1.0);
}
