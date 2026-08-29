// fractal.frag：无限分形深潜（对数极坐标 · 自相似八度流 · Julia 逃逸时间丝）。
//
// 为什么这样才"无限、且看得出在变近"：
//   1. 画面按对数极坐标展开：八度坐标 lr = −log_S(ρ) + D，D 随播放时钟连续增长。
//      固定屏幕半径处的内容随 D 指数向外流动 → 真正的"飞进去"光流，中心是消失点。
//   2. 图案沿 lr 方向**严格周期**（周期 NOCT 个八度）：Julia 的初始点沿一条闭合
//      参数曲线取值，于是每放大 S 倍图案自然接续——无绕接、无闪烁、无精度上限
//      （坐标量级恒定，float 永不溢出），也不会退化成"一圈圈互不相关的补丁"。
//   3. 每个八度落在 Julia 集的不同切片上 → 结构持续翻出新形态，不是同一张图缩放；
//      逃逸时间的等值丝随缩放不断从中心涌出 → 细节越来越多。
//   4. 反馈拖尾的缩放率与八度流速对齐 → 只是运动模糊，不会跑到内容前面成鬼影。
//
// uniform 由工具链注入（uT 毫秒 / uSeed / uRes / uBeat / uBass / uTreble /
// uTransition / uPrev），源文件按 GLSL ES 1.00 书写。
uniform float uT;
uniform float uSeed;
uniform vec2 uRes;
uniform float uBeat;
uniform float uBass;
uniform float uTreble;
uniform float uTransition;
uniform sampler2D uPrev;
varying vec2 vUV;

#define TAU 6.2831853

// 精度安全 hash（不用 sin，避免大 seed 在移动端精度崩坏）
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

mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

// iq 余弦调色板
vec3 pal(float t) {
    return vec3(0.5) + vec3(0.5) * cos(TAU * (vec3(1.0, 0.95, 0.9) * t + vec3(0.0, 0.15, 0.35)));
}

// 周期性值噪声：格点索引对 per 取模 → 沿八度方向严格周期
float pnoise(vec2 p, vec2 per) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(mod(i, per));
    float b = hash21(mod(i + vec2(1.0, 0.0), per));
    float c = hash21(mod(i + vec2(0.0, 1.0), per));
    float d = hash21(mod(i + vec2(1.0, 1.0), per));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void main() {
    float ts = uT * 0.001;
    float sd = hash11(uSeed * 1.0e-7) * 211.0;
    float aspect = uRes.x / max(uRes.y, 1.0);
    vec2 q = (vUV - 0.5) * vec2(aspect, 1.0);

    // ------------------------------------------------------------------
    // 八度流：S = 每个八度的放大倍数；D = 已深入的八度数（连续，永不绕接）
    // ------------------------------------------------------------------
    const float S = 2.0;
    const float LNS = 0.6931472;                  // log(2)
    // 图案周期取"屏幕径向跨度"（rho 0.02~0.7 约 5~6 个八度）附近：
    // 屏幕正好覆盖完整周期 → 整屏平均亮度与时间无关（周期取太大时，
    // 窗口滑过周期的不同位置会让集内面积忽大忽小，整屏周期性忽明忽暗）
    const float NOCT = 6.0;

    // 深潜速度 0.58 八度/秒 ≈ 每秒放大 1.5 倍；beat 时略加速
    float D = ts * (0.58 + 0.14 * uBeat) + sd * 0.37;

    float rho = max(length(q), 1e-4);
    float ang = atan(q.y, q.x);

    // 八度坐标：中心恒为无限深，边缘最浅
    float lr = -log(rho) / LNS + D;
    float fN = fract(lr / NOCT);                  // 周期坐标：跨 NOCT 个八度走完一圈
    float angN = ang / TAU + 0.5 + 0.06 * sin(ts * 0.017 + sd);

    // 角向整数重对称折叠（万花筒；必须整数，否则角向 mod 会留一道缝）
    const float sym = 6.0;
    float a = abs(fract(angN * sym) - 0.5) * 2.0;

    // ---- Julia 逃逸时间：初值沿闭合曲线取（沿八度方向周期 → 缩放无缝）----
    // 主环沿八度方向绕行：到 Julia 集的距离大致恒定 → 集内面积稳定，
    // 整体明暗不会随深度大幅起伏（此前用 sin/cos 直接摆位，某些八度整屏陷进集内 → 忽明忽暗）。
    // 角向 a 沿环的切线方向展开 → 保留角向结构，同时不破坏周期性。
    float th = TAU * fN;
    vec2 ring = vec2(1.16 * cos(th), 1.00 * sin(th));
    vec2 tang = vec2(-sin(th), cos(th));
    vec2 z0 = ring + (a - 0.5) * 1.15 * tang;
    // c 随播放时钟极慢漂移：整体形态缓慢演化，同时不破坏八度周期性
    vec2 cc = vec2(-0.7269, 0.1889)
        + 0.10 * vec2(sin(ts * 0.013 + sd), cos(ts * 0.011 + sd * 1.7))
        + 0.03 * uBass * vec2(sin(ts * 0.004 + sd), cos(ts * 0.004 + sd));

    vec2 zc = z0;
    float esc = -1.0;
    float trap = 1e9;
    for (int i = 0; i < 12; i++) {
        zc = vec2(zc.x * zc.x - zc.y * zc.y, 2.0 * zc.x * zc.y) + cc;
        float r2 = dot(zc, zc);
        trap = min(trap, r2);
        if (r2 > 24.0) {
            esc = float(i);
            break;
        }
    }
    // 平滑逃逸计数：消掉整数阶梯，等值丝才连续
    float sm = 12.0;
    if (esc >= 0.0) {
        float r2 = max(dot(zc, zc), 1e-4);
        sm = clamp(esc + 1.0 - log(max(log(r2) * 0.5, 1e-4)) / LNS, 0.0, 12.0);
    }
    // 注意：sm=12 表示"12 次迭代内从未逃逸"= 集内。deep=1 才是集内
    // （此前写成 1−sm/12，含义正好相反，等于给整个外围铺雾，画面全灰）
    float deep = clamp(sm / 12.0, 0.0, 1.0);

    // ---- 分形丝：逃逸等值线 + 轨道陷阱 + 周期噪声细纹 ----
    float band = abs(fract(sm * 0.85 - ts * 0.04) - 0.5) * 2.0;
    float fil = pow(1.0 - band, 7.0);
    float trapGlow = exp(-trap * 1.4);
    // 周期噪声给丝面加细密纹理（频率整数 → 不破坏八度周期）
    float tex = pnoise(vec2(a * 12.0, fN * 16.0), vec2(16.0)) * 0.5
        + pnoise(vec2(a * 24.0, fN * 32.0), vec2(32.0)) * 0.25;

    // 纹理**调制**丝线而非单独加亮——否则每一项都铺满全屏，整体泛白
    fil *= 0.55 + 0.45 * tex;

    float hue = 0.55 * deep + 0.22 * fil + 0.12 * trapGlow
        + 0.10 * tex + 0.03 * sin(ts * 0.02 + sd) + uTreble * 0.05;

    // 暗底 + 明亮的逃逸等值丝：主体只由 fil 决定，其余项只做很轻的辅助。
    // beat 只轻微提亮（大比例调亮会被看成"闪一下"），主要靠加速深潜来响应节拍
    vec3 col = pal(hue) * fil * (0.95 + 0.18 * uBeat) * 1.40;
    col += pal(hue + 0.32) * deep * 0.015;              // 集内微弱填充
    col += pal(hue + 0.62) * trapGlow * 0.020;          // 轨道陷阱辉光
    col += pal(hue + 0.5) * 0.005;                      // 极暗底，避免死黑

    // 中心是消失点：淡出消锯齿 + 核心辉光强化"往里钻"
    col *= smoothstep(0.0, 0.045, rho);
    col += pal(hue + 0.10) * exp(-rho * rho * 700.0) * (0.45 + 0.55 * uBeat);
    col *= 1.0 - 0.22 * dot(q, q);

    // 反馈拖尾：缩放率与八度流速对齐（2^(−0.58/30) ≈ 0.9867，30fps）
    // → 拖尾只是沿光流方向的运动模糊，不会跑到内容前面形成前导鬼影
    vec2 prevUV = (vUV - 0.5) * 0.9867 + 0.5;
    col += texture2D(uPrev, prevUV).rgb * 0.26;

    col = 1.0 - exp(-col);
    // 抬暗部压缩"周期性忽明忽暗"的观感幅度（0.70 太狠会掉饱和度，取 0.82）
    col = pow(col, vec3(0.82));

    // 风格切换：与上一画面交叉淡化
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    col = mix(texture2D(uPrev, vUV).rgb, col, transA);

    gl_FragColor = vec4(col, 1.0);
}
