// mirror.frag：反馈深潜 · 无尽镜渊。
//
// 每一帧以上一帧为画布：围绕一个缓缓游走的焦点做「缩放 + 旋转 +
// 桶形畸变 + 卷曲扰动」再采样——画面内容被不断拉向观者，焦点本身
// 又在移动（摄像机跟随视线），于是一路向屏幕深处行进、永无止境。
// 焦点处持续注入新的程序化内容（万花筒曼陀罗 + 脉冲光环 + 核心辉光
// + 星火粒子），被反馈流卷出层层结构，永不"糊成纯色"。
// RGB 三通道以微差异采样率分离出色散，节拍会加快俯冲速度。
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
mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}
vec3 pal(float t) {
    return 0.5 + 0.5 * cos(TAU * (vec3(0.9, 1.0, 1.1) * t + vec3(0.0, 0.12, 0.38)));
}

void main() {
    float ts = uT * 0.001;
    float sd = hash11(uSeed * 1.0e-7) * 173.0;
    float aspect = uRes.x / max(uRes.y, 1.0);
    float transA = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));

    // ---- 游走焦点：摄像机缓慢跟随的"视线" ----
    vec2 c = vec2(0.5)
        + 0.16 * vec2(sin(ts * 0.113 + sd), cos(ts * 0.097 + sd * 1.7))
        + 0.05 * vec2(sin(ts * 0.031 + sd * 2.3), cos(ts * 0.043 + sd));

    vec2 d = vUV - c;
    float r = length(d * vec2(aspect, 1.0));

    // ---- 反馈变换：每帧向焦点内俯冲（beat 加速）+ 螺旋 + 畸变 ----
    float k = 0.9865 - 0.007 * uBeat - 0.003 * uBass;
    float ang = 0.010 * sin(ts * 0.21 + sd)
        + (0.16 + 0.20 * uBass) * exp(-r * 2.6) * sin(ts * 0.07 + sd * 2.0)
        + 0.02 * uTreble * sin(ts * 0.6);
    vec2 dp = rot(ang) * d * k;
    dp *= 1.0 + 0.06 * r * r;                       // 桶形畸变
    dp += 0.0016 * vec2(                            // 卷曲扰动
        vn(vUV * 7.0 + ts * 0.30) - 0.5,
        vn(vUV * 7.0 + 41.0 - ts * 0.26) - 0.5);

    // 色散：RGB 以微差异速率采样
    vec3 prev;
    prev.r = texture2D(uPrev, c + dp * 0.9965).r;
    prev.g = texture2D(uPrev, c + dp).g;
    prev.b = texture2D(uPrev, c + dp * 1.0035).b;
    prev *= 0.950;                                   // 衰减，给注入留位
    // 边缘压暗：避免采样夹取产生的边框拖痕
    float edge = smoothstep(1.30, 0.80, r);
    prev *= mix(0.90, 1.0, edge);

    // ---- 焦点注入：被反馈流卷成无穷结构的新内容 ----
    vec2 iq = (vUV - c) * vec2(aspect, 1.0);
    float ir = length(iq);
    float ia = atan(iq.y, iq.x);

    // 万花筒曼陀罗
    float K = 7.0;
    float fa = abs(mod(ia + ts * 0.05, TAU / K) - 3.14159265 / K);
    float mandala = exp(-abs(sin(fa * 2.5 + ts * 0.35 + ir * 15.0)) * 3.2)
        * exp(-ir * 5.0);
    // 脉冲光环（随节拍亮度呼吸）
    float rings = exp(-pow(fract(ir * 3.2 - ts * 0.16) - 0.5, 2.0) * 26.0)
        * exp(-ir * 1.6) * (0.45 + 0.85 * uBeat);
    // 核心辉光
    float core = exp(-ir * ir * 260.0) * (0.8 + 1.0 * uBeat);
    // 星火粒子：焦点附近随机闪现，被反馈拉成外流星轨
    vec2 cell = floor(vUV * uRes / 3.0);
    float spark = step(0.9982, fract(hash21(cell) + ts * 0.6)) * exp(-ir * 2.4);

    float hueBase = ts * 0.014 + sd * 0.02 + uTreble * 0.05;
    vec3 inject = pal(hueBase + ir * 0.35) * (mandala * 0.85 + rings + core * 0.9);
    inject += vec3(0.9, 0.95, 1.0) * spark * 0.85;
    inject *= transA;                                // 切换时内容渐入，反馈不断

    vec3 col = prev + inject * 0.85;

    // 软映射 + 轻饱和 + 暗角
    col = 1.0 - exp(-col * 1.05);
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(lum), col, 1.12);
    col *= 1.0 - 0.32 * dot((vUV - 0.5) * vec2(aspect, 1.0), (vUV - 0.5) * vec2(aspect, 1.0));

    gl_FragColor = vec4(col, 1.0);
}
