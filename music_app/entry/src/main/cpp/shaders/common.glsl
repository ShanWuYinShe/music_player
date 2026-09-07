// common.glsl：四个场景共享的公共函数库。
//
// 本文件不是独立 shader：工具链（playground 的 glslPatch.ts / 端侧构建的
// gen_shader_header.py）把它原样注入到每个场景"注入头之后、场景源之前"。
// 场景文件直接使用这里的函数，**不要重复定义**（重复定义会编译报错）。
//
// uniform（uT/uSeed/uRes/uBeat/uBass/uTreble/uTilt/uSpin/uKick/uTransition/uPrev）与 vUV 由
// 注入头声明，本文件的函数直接读取。书写风格与场景源一致：GLSL ES 1.00
// （texture2D / 无 #version），词汇替换由工具链统一完成。
//
// 行号换算：编译器报错行号 − 注入头行数(15) − 本文件行数 = 场景源文件行号。
// 报错行号落在本文件区间内时，工具会标注为 common.glsl 的行号。

#define TAU 6.2831853
#define PI 3.1415927

// ---- 精度安全 hash ------------------------------------------------------
// fract 系，不用 sin：大 seed（可到 4e9）在移动端 mediump 下 sin 精度崩坏。
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

// ---- 值噪声 + fbm -------------------------------------------------------
float vn(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// 4 倍频 + 倍频间旋转，消掉网格方向感
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 R = mat2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 4; i++) {
        v += a * vn(p);
        p = R * p * 2.03;
        a *= 0.5;
    }
    return v;
}

// 3 倍频降阶版：给本就柔软的低频载体（极光绸带蜿蜒/银河云絮/蒸汽缕）用，
// 每次调用省 1 档 vn（4 hash21）；这些场景上的差异肉眼不可辨。硬边/结构
// 特征仍用完整 fbm，勿盲目替换。
float fbm3(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 R = mat2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 3; i++) {
        v += a * vn(p);
        p = R * p * 2.03;
        a *= 0.5;
    }
    return v;
}

// ---- 时域随机游走（混沌驱动，无周期）----------------------------------------
// 整数时间格 hash + smoothstep 插值：一条数学上无周期的平滑轨迹。
// 正弦驱动再不可通约也是准周期——观众几分钟后就会察觉"在循环"；wander
// 永不回头，每一刻的参数组合都是历史首次出现。
// t 秒；scale 一格的秒数（越小变化越快）；seed 区分通道。
float wander(float t, float scale, float seed) {
    float x = t / scale + seed;
    float e = floor(x);
    float u = fract(x);
    u = u * u * (3.0 - 2.0 * u);
    return mix(hash11(e * 0.717 + seed), hash11((e + 1.0) * 0.717 + seed), u);
}

// 双尺度叠加：中长波定走向 + 快波添细节，轨迹更"活"
float wander2(float t, float scale, float seed) {
    return wander(t, scale, seed) * 0.65
        + wander(t, scale * 0.271, seed + 11.7) * 0.35;
}

// 以 0 为中心的有界双向游走（输出 −1..1）：给旋转/偏移类参数用
float wanderBi(float t, float scale, float seed) {
    return wander2(t, scale, seed) * 2.0 - 1.0;
}

// ---- 小工具 -------------------------------------------------------------
mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

// ---- 体感运动（uTilt/uSpin/uKick，只进几何/亮度，不进色相/速度）-----------
// 最大滚转 ±0.35rad（≈±20°，手机转 60° 饱和）；抛甩缩放脉冲最大收缩 6%。
// pivot 是旋转/缩放中心：sceneUV 系场景传原点，vUV 系场景传屏中。
#define SPIN_MAX_RAD 0.35
#define KICK_ZOOM 0.06
vec2 motionSpinKick(vec2 q, vec2 pivot) {
    q = pivot + rot(uSpin * SPIN_MAX_RAD) * (q - pivot);
    q = pivot + (q - pivot) * (1.0 - uKick * KICK_ZOOM);
    return q;
}

// uT 单位是毫秒，场景里一律用秒
float nowSec() {
    return uT * 0.001;
}

// 大 seed 先缩小再 hash（精度安全约定）；场景再乘各自的散布系数
float seedHash() {
    return hash11(uSeed * 1.0e-7);
}

float aspectRatio() {
    return uRes.x / max(uRes.y, 1.0);
}

// 以 center 为原点、按宽高比修正的场景坐标
vec2 sceneUV(vec2 center) {
    return (vUV - center) * vec2(aspectRatio(), 1.0);
}

// ---- 调色 ---------------------------------------------------------------
// 余弦色轮：0=红 .17=紫 .33=蓝 .5=青 .67=绿 .83=黄（不是 HSL，别按 HSL 调）
vec3 hue2rgb(float h) {
    return 0.5 + 0.5 * cos(TAU * (h + vec3(0.0, 0.33, 0.67)));
}

// iq 余弦调色板（a=b=0.5 形态），c/d 由场景按自己的色族给出
vec3 palIQ(float t, vec3 c, vec3 d) {
    return 0.5 + 0.5 * cos(TAU * (c * t + d));
}

// 饱和度拉伸：k>1 更艳，k<1 向灰靠
vec3 satBoost(vec3 col, float k) {
    return mix(vec3(dot(col, vec3(0.299, 0.587, 0.114))), col, k);
}

// ---- 收尾 ---------------------------------------------------------------
// 柔和色调映射（曝光系数由场景定）
vec3 toneExp(vec3 col, float exposure) {
    return 1.0 - exp(-col * exposure);
}

// ACES 电影感近似（Narkowicz）：HDR 线性 → 展示色。高亮滚降比 toneExp
// 柔和，超亮区域向白过渡而不是钳成色块——照片感的关键一环
vec3 filmic(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// 抖动去色带；fragPx 传 vUV*uRes（像素坐标），ts 为秒
vec3 dither(vec2 fragPx, float ts) {
    return vec3((hash21(fragPx + fract(ts) * 7.0) - 0.5) * (1.5 / 255.0));
}

// preset 切换交叉淡化：uTransition 0→1 时从上一帧画面渐入新画面
vec3 applyTransition(vec3 col) {
    float a = smoothstep(0.0, 1.0, clamp(uTransition, 0.0, 1.0));
    return mix(texture2D(uPrev, vUV).rgb, col, a);
}
