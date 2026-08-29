// pan.frag：高温锅底上的莱顿弗罗斯特水滴。
//
// 物理要点：
//  - 蒸发遵守 d² 定律（半径平方随时间线性下降）→ 主滴寿命 38~68 秒，
//    不会"很快消失"；小卫星滴 14~24 秒；
//  - 水滴用元球（metaball）场表达：两滴靠近时场自然颈缩融合，
//    无需特判"合并事件"；
//  - 蒸气垫让水滴不停游走 + 高频颤抖，濒死时疯狂跳动并泡沫化；
//  - 材质：折射锅底（球透镜向心取样）+ 主/辅双高光 + 菲涅尔亮边
//    （下沿反射炉火橙、上沿反射冷光）+ 边缘焦散亮环 + 锅面接触影。
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

// 精度安全 hash（不用 sin）
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
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// 水滴元球场：F = Σ r²/d²，g = ∇F（指向场增大方向即滴心）。
// 9 主滴 + 4 卫星滴；濒死（lifeK→1）时场注入噪声 → 边缘泡沫化。
float field(vec2 q, float ts, float sd, out vec2 g) {
    g = vec2(0.0);
    float F = 0.0;
    for (int i = 0; i < 13; i++) {
        float fi = float(i);
        float small = step(8.5, fi);
        float h1 = hash11(fi * 7.13 + sd);
        float h2 = hash11(fi * 3.71 + sd + 11.0);
        float h3 = hash11(fi * 5.39 + sd + 23.0);
        float h4 = hash11(fi * 9.17 + sd + 37.0);
        float P = mix(38.0 + 30.0 * h1, 14.0 + 10.0 * h1, small);
        float age = mod(ts + h2 * P, P);
        float lifeK = age / P;
        float r0 = mix(0.030 + 0.028 * h3, 0.010 + 0.008 * h3, small);
        // d² 蒸发定律 + 出生 2.5% 寿命内快速长大
        float grow = mix(0.10, 1.0, smoothstep(0.0, 0.025, lifeK));
        float rr = r0 * r0 * grow * max(1.0 - lifeK, 0.0);
        if (rr < 1e-7) continue;
        // 游走轨迹（正弦叠加，光滑且天然限幅 1.55）
        float sp = mix(1.0, 1.9, small);
        float panic = 1.0 + 5.0 * smoothstep(0.93, 1.0, lifeK);
        vec2 pos = vec2(
            sin(age * 0.55 * h4 * sp + fi * 2.1) + 0.55 * sin(age * 1.31 * h1 * sp + fi * 5.3),
            cos(age * 0.47 * h2 * sp + fi * 3.7) + 0.55 * cos(age * 1.13 * h3 * sp + fi * 1.9));
        pos *= (0.44 - sqrt(rr) - 0.03) / 1.55;
        // 蒸气垫高频颤抖（bass 加重）
        pos += 0.0035 * panic * (1.0 + 1.6 * uBass)
            * vec2(sin(age * 23.0 + fi * 9.0), cos(age * 29.0 + fi * 4.0));
        vec2 d = q - pos;
        float d2 = dot(d, d) + 1e-6;
        float w = rr / d2;
        // 濒死泡沫化
        float sizzle = smoothstep(0.90, 1.0, lifeK);
        w *= 1.0 + sizzle * (vn(q * 260.0 + age * 7.0) - 0.5) * 2.4;
        F += w;
        g += -2.0 * w * d / d2;
    }
    return F;
}

// 锅底：铸铁暗底 + 车削同心纹 + 炉头炽热环 + 锅沿金属边
vec3 bg(vec2 q, float ts) {
    float r = length(q);
    float rings = 0.5 + 0.5 * sin(r * 240.0 + vn(q * 36.0) * 2.5);
    float grain = vn(q * 300.0);
    vec3 c = vec3(0.040, 0.042, 0.048);
    c += vec3(0.014, 0.014, 0.015) * rings;
    c += vec3(0.012) * (grain - 0.5);
    float pulse = 0.85 + 0.15 * sin(ts * 0.8);
    float ring = exp(-pow((r - 0.29) * 7.0, 2.0));
    c += vec3(0.42, 0.09, 0.02) * ring * 0.55 * pulse;
    float core = exp(-r * 4.2);
    c += vec3(0.30, 0.06, 0.015) * core * 0.5 * pulse;
    float rim = exp(-abs(r - 0.44) * 90.0);
    c += vec3(0.20, 0.22, 0.26) * rim * (0.5 + 0.3 * clamp(-q.y, 0.0, 1.0));
    c *= 1.0 - smoothstep(0.44, 0.52, r) * 0.7;
    return c;
}

void main() {
    float ts = uT * 0.001;
    float sd = hash11(uSeed * 1.0e-7) * 173.0;
    float aspect = uRes.x / max(uRes.y, 1.0);
    vec2 q = (vUV - vec2(0.5, 0.47)) * vec2(aspect, 1.0);

    // 热空气上升扭曲（轻微）
    vec2 qw = q + 0.0018 * vec2(vn(q * 13.0 + ts * 1.1), vn(q * 13.0 + 31.0 - ts * 0.9)) - 0.0009;

    vec2 g;
    float F = field(qw, ts, sd, g);
    F *= 1.0 + 0.05 * uBeat * sin(ts * 31.0);   // 节拍 → 表面微沸腾

    float m = smoothstep(0.85, 1.15, F);

    // 接触影（主光来自左上 → 影落右下，只在水滴外）
    vec2 gs;
    float Fs = field(qw + vec2(0.016, -0.014), ts, sd, gs);
    float shadow = smoothstep(0.45, 1.3, Fs) * (1.0 - m);

    vec3 col = bg(qw, ts);
    col *= 1.0 - 0.42 * shadow;

    // ---- 水滴材质 ----
    // 球冠剖面：边缘斜率最大、滴心平顶（tilt 随 F 增大而减小）
    vec2 gn = g / (length(g) + 1e-4);
    float tilt = 3.0 / (1.0 + max(F - 1.0, 0.0) * 1.2);
    vec3 n = normalize(vec3(-gn * tilt, 1.0));

    vec3 L = normalize(vec3(-0.42, 0.60, 0.68));
    vec3 V = vec3(0.0, 0.0, 1.0);

    // 折射：向滴心取样（球透镜倒像），折射量随斜率增大、限制在滴内
    vec2 ruv = qw + gn * tilt * 0.022;
    vec3 through = bg(ruv, ts);
    through *= vec3(0.90, 0.96, 1.04);
    through *= mix(0.85, 0.68, clamp((F - 1.0) * 0.15, 0.0, 1.0));

    float spec = pow(max(dot(reflect(-L, n), V), 0.0), 110.0);
    vec3 L2 = normalize(vec3(0.55, -0.35, 0.55));
    float spec2 = pow(max(dot(reflect(-L2, n), V), 0.0), 45.0);
    float fres = pow(1.0 - max(n.z, 0.0), 2.2);
    // 菲涅尔亮边：下沿拾取炉火橙，上沿冷光
    float down = clamp(0.5 - n.y * 2.4, 0.0, 1.0);
    vec3 rimCol = mix(vec3(0.55, 0.72, 1.0), vec3(1.0, 0.42, 0.12), down);
    // 边缘内侧焦散亮环（treble 让环面闪烁）
    float ca = smoothstep(1.05, 1.35, F) * smoothstep(2.9, 1.45, F);
    ca *= 0.75 + 0.5 * uTreble * vn(q * 160.0 + ts * 3.0);

    vec3 drop = through;
    drop += rimCol * fres * 0.60;
    drop += vec3(1.0, 0.97, 0.90) * spec * (1.3 + 0.6 * uTreble);
    drop += vec3(0.8, 0.9, 1.0) * spec2 * 0.30;
    drop += vec3(1.0, 0.85, 0.6) * ca * 0.40;

    col = mix(col, drop, m);

    // 极轻反馈：热气拖影（向上飘）
    col += texture2D(uPrev, vUV + vec2(0.0, -0.0006)).rgb * 0.06;

    col = 1.0 - exp(-col * 1.05);
    col = pow(col, vec3(0.95));

    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    col = mix(texture2D(uPrev, vUV).rgb, col, transA);

    gl_FragColor = vec4(col, 1.0);
}
