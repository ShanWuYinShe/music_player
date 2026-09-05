/**
 * visualizer：XComponent + EGL/GLES 的 shader 式音乐可视化渲染管线。
 *
 * 架构：ArkTS 侧 XComponent(SURFACE) 挂载原生表面，本模块在
 * OnSurfaceCreated 创建 EGL 上下文与 GLES 3.0 管线；每次 displaySync
 * 回调经 NAPI 调 renderFrame(t, seed, playing) 同步渲染一帧。
 *
 * 渲染方式：全屏三角形（3 顶点覆盖视口），顶点阶段只做全屏覆盖——
 * 所有视觉在 fragment shader 逐像素解算，运算量只与像素数相关。
 * 拖尾反馈：FBO 纹理 ping-pong，上一帧结果作为 uPrev 采样。
 *
 * 内部分辨率按场景区分（kPresetScale）：pan/aurora 逐像素成本高且形态
 * 柔软，更低内部比例上屏线性放大视觉近无损；切风格触发反馈纹理重建时，
 * 先把旧帧 blit 拷贝到新尺寸纹理，保留 uTransition 交叉淡化的旧画面。
 *
 * pan 状态预通道：每颗水珠的状态是每帧常量，主 pass 之前先用同一份
 * pan.frag 以 20×4 小视口（uStateMode=1）把状态写进 RGBA16F 纹理，
 * 主循环 texelFetch 取用（见 pan.frag 头注释）。依赖浮点颜色缓冲可渲染
 * 扩展；不支持时以 PAN_NO_STATE_TEX 编译期开关退回逐像素路径。
 *
 * shader 源码：磁盘上 cpp/shaders 目录下的 .frag 文件（GLSL ES 1.00，与
 * shader_playground 预览同源），由 CMake 在构建期经
 * tools/gen_shader_header.py 转成 GLES3 头文件 shader_src.h（生成到构建目录，
 * 不进源码树）。每个场景一个 program，按 presetLock 切换。
 *
 * 参数：t(有效播放时钟 ms)、seed(曲目 id 派生)、playing(暂停分支)、
 *       tiltX/tiltY(设备姿态归一化倾斜，uniform uTilt——全场景相机视差)。
 */

#include "visualizer.h"
#include "shader_src.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>


#undef LOG_TAG
#define LOG_TAG "VizNative"

namespace {

// 全屏三角形顶点（3 个点即可覆盖整个视口，fragment 承担全部工作）
const float kQuad[] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};

// pan 在 SHADER_SCENES（fractal,pan,aurora,spectrum）中的槽位；状态预通道
// 只对 pan 生效。顺序变更须同步 CMakeLists.txt / VisualizerCore.ets /
// playground presets.ts（pipelineConsistency.test.ts 有跨端断言）。
constexpr int kVizPresetPan = 1;
// pan 状态纹理尺寸：宽 = DROPLET_COUNT(20)、高 = PAN_STATE_ROWS(4)，
// 与 pan.frag 内的常量一一对应（改那边必须同步这里）。
constexpr int kPanStateTexW = 20;
constexpr int kPanStateTexH = 4;

// 各场景内部分辨率比例（相对表面尺寸）：pan/aurora 逐像素负载高、形态
// 柔软，更低比例上屏放大视觉近无损；fractal/spectrum 维持 1/2。
// 切风格引起比例变化时，反馈纹理经 blit 拷贝重建（保留交叉淡化旧画面）。
constexpr float kPresetScale[kVizPresetCount] = {0.5f, 0.45f, 0.33f, 0.5f};

EGLConfig gEglConfig = nullptr;
EGLContext gEglContext = nullptr;
EGLSurface gEglSurface = nullptr;
EGLDisplay gEglDisplay = nullptr;

/** 场景 uniform 位置缓存（每个场景 program 一套，避免每帧 glGetUniformLocation） */
struct SceneLocs {
    GLint t = -1;
    GLint seed = -1;
    GLint res = -1;
    GLint beat = -1;
    GLint bass = -1;
    GLint treble = -1;
    GLint transition = -1;
    GLint tilt = -1;        // 设备倾斜视差 uTilt（vec2，全场景共用）
    GLint prev = -1;
    GLint stateMode = -1;   // pan 专用：uStateMode（其他场景无此 uniform，恒 -1）
    GLint state = -1;       // pan 专用：uState 采样器
};

GLuint gProgramScene[kVizPresetCount] = {0};
SceneLocs gLocs[kVizPresetCount];
GLuint gProgramBlit = 0;
GLint gBlitTex = -1;
GLuint gVao = 0;
GLuint gVbo = 0;

int gWidth = 0;
int gHeight = 0;
bool gReady = false;

// FBO 纹理 ping-pong（拖尾反馈）
GLuint gFbo[2] = {0, 0};
GLuint gTex[2] = {0, 0};
int gTexW = 0;
int gTexH = 0;
int gFlip = 0;
// 内部渲染目标分辨率(半: fragment 负载降 4 倍,上屏线性放大柔化)
int gRenderW = 0;
int gRenderH = 0;

// pan 状态预通道资源：RGBA16F 纹理 + FBO（20×4）；gStateMode 含义与
// pan.frag 的 uStateMode 对齐：2=主 pass 读状态纹理，0=回退逐像素。
GLuint gFboState = 0;
GLuint gTexState = 0;
int gStateMode = 0;

GLuint CompileShader(GLenum type, const char* src) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        OH_LOG_ERROR(LOG_APP, "[%s] shader type=%{public}d compile: %{public}s", LOG_TAG, type, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/** 链接一个 program 并缓存 uniform 位置；失败返回 0 */
GLuint LinkProgram(GLuint vs, GLuint fs, SceneLocs* locs) {
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint linked = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[1024] = {0};
        glGetProgramInfoLog(prog, sizeof(log) - 1, nullptr, log);
        OH_LOG_ERROR(LOG_APP, "[%s] link failed: %{public}s", LOG_TAG, log);
        glDeleteProgram(prog);
        return 0;
    }
    if (locs != nullptr) {
        locs->t = glGetUniformLocation(prog, "uT");
        locs->seed = glGetUniformLocation(prog, "uSeed");
        locs->res = glGetUniformLocation(prog, "uRes");
        locs->beat = glGetUniformLocation(prog, "uBeat");
        locs->bass = glGetUniformLocation(prog, "uBass");
        locs->treble = glGetUniformLocation(prog, "uTreble");
        locs->transition = glGetUniformLocation(prog, "uTransition");
        locs->tilt = glGetUniformLocation(prog, "uTilt");
        locs->prev = glGetUniformLocation(prog, "uPrev");
        locs->stateMode = glGetUniformLocation(prog, "uStateMode");
        locs->state = glGetUniformLocation(prog, "uState");
    }
    return prog;
}

/** pan 回退变体源码：#version 必须保持首行，把编译期开关插到它之后 */
std::string WithPanStateDisabled(const char* src) {
    std::string s(src);
    size_t nl = s.find('\n');
    if (nl == std::string::npos) {
        return s;
    }
    return s.substr(0, nl + 1) + "#define PAN_NO_STATE_TEX 1\n" + s.substr(nl + 1);
}

void SwapFbo() {
    // 当前帧已渲染到 gFbo[gFlip] 并存于 gTex[gFlip]；下一帧作为反馈源
    gFlip = 1 - gFlip;
}

}  // namespace

void VizOnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    OH_LOG_INFO(LOG_APP, "[%s] surface created", LOG_TAG);
    if (gReady && gEglDisplay != EGL_NO_DISPLAY) {
        return; // 幂等:created 与 show 双路径都可能触发初始化
    }
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    gWidth = static_cast<int>(w);
    gHeight = static_cast<int>(h);

    gEglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (gEglDisplay == EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglGetDisplay failed", LOG_TAG);
        return;
    }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(gEglDisplay, &major, &minor)) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglInitialize failed", LOG_TAG);
        return;
    }
    EGLint configAttrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_BLUE_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_RED_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE};
    EGLint numCfg = 0;
    if (!eglChooseConfig(gEglDisplay, configAttrs, &gEglConfig, 1, &numCfg) || numCfg == 0) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglChooseConfig failed", LOG_TAG);
        return;
    }
    EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    gEglContext = eglCreateContext(gEglDisplay, gEglConfig, EGL_NO_CONTEXT, ctxAttrs);
    if (gEglContext == EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglCreateContext failed", LOG_TAG);
        return;
    }
    EGLNativeWindowType eglWin = static_cast<EGLNativeWindowType>(
        reinterpret_cast<uintptr_t>(window));
    gEglSurface = eglCreateWindowSurface(gEglDisplay, gEglConfig, eglWin, nullptr);
    if (gEglSurface == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglCreateWindowSurface failed", LOG_TAG);
        return;
    }
    if (!eglMakeCurrent(gEglDisplay, gEglSurface, gEglSurface, gEglContext)) {
        OH_LOG_ERROR(LOG_APP, "[%s] eglMakeCurrent failed", LOG_TAG);
        return;
    }

    // 顶点缓冲
    glGenBuffers(1, &gVbo);
    glBindBuffer(GL_ARRAY_BUFFER, gVbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kQuad), kQuad, GL_STATIC_DRAW);
    glGenVertexArrays(1, &gVao);
    glBindVertexArray(gVao);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glBindVertexArray(0);

    // 反馈 FBO 纹理（先建最小尺寸 1x1 占位, renderFrame 首次按实际尺寸重建）
    for (int i = 0; i < 2; i++) {
        glGenTextures(1, &gTex[i]);
        glBindTexture(GL_TEXTURE_2D, gTex[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glGenFramebuffers(1, &gFbo[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, gFbo[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gTex[i], 0);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    // 反馈纹理尺寸标记重置:renderFrame 首帧据此重建纹理——旧 context 的
    // 纹理 id 已随 eglTerminate 失效,残留尺寸会跳过重建采样到脏数据
    gTexW = 0;
    gTexH = 0;

    // pan 状态预通道资源：RGBA16F 颜色缓冲。ES3.0 核心不保证浮点格式可
    // 渲染，查 EXT_color_buffer_float（32F+16F）/EXT_color_buffer_half_float
    // （16F）；任一可用且 FBO 完整性通过才启用（gStateMode=2），否则以
    // PAN_NO_STATE_TEX 编译 pan 回退变体（逐像素路径，见 pan.frag）
    const char* exts = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
    bool floatColor = exts != nullptr &&
        (strstr(exts, "EXT_color_buffer_float") != nullptr ||
         strstr(exts, "EXT_color_buffer_half_float") != nullptr);
    if (floatColor) {
        glGenTextures(1, &gTexState);
        glBindTexture(GL_TEXTURE_2D, gTexState);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, kPanStateTexW, kPanStateTexH, 0,
            GL_RGBA, GL_HALF_FLOAT, nullptr);
        glGenFramebuffers(1, &gFboState);
        glBindFramebuffer(GL_FRAMEBUFFER, gFboState);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D, gTexState, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            OH_LOG_WARN(LOG_APP, "[%s] RGBA16F FBO incomplete, pan falls back",
                LOG_TAG);
            glDeleteFramebuffers(1, &gFboState);
            gFboState = 0;
            glDeleteTextures(1, &gTexState);
            gTexState = 0;
            floatColor = false;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    } else {
        OH_LOG_WARN(LOG_APP, "[%s] no float color buffer ext, pan falls back",
            LOG_TAG);
    }
    gStateMode = floatColor ? 2 : 0;

    // 顶点 shader 编译一次，供全部 program 复用
    GLuint vs = CompileShader(GL_VERTEX_SHADER, kVertSrc);
    if (!vs) {
        OH_LOG_ERROR(LOG_APP, "[%s] vertex shader compile failed", LOG_TAG);
        return;
    }
    // 每个场景一个 program（程序清单由 CMake 的 SHADER_SCENES 决定）；
    // pan 在无浮点 FBO 时编译带 PAN_NO_STATE_TEX 的回退变体（同一份源码
    // 插一个编译期开关，两条路径的寄存器压力互不影响）
    for (int i = 0; i < kVizPresetCount; i++) {
        const char* sceneSrc = kFragScene[i];
        std::string fallbackSrc;
        if (i == kVizPresetPan && gStateMode != 2) {
            fallbackSrc = WithPanStateDisabled(sceneSrc);
            sceneSrc = fallbackSrc.c_str();
        }
        GLuint fs = CompileShader(GL_FRAGMENT_SHADER, sceneSrc);
        if (!fs) {
            OH_LOG_ERROR(LOG_APP, "[%s] scene %{public}d compile failed", LOG_TAG, i);
            glDeleteShader(vs);
            return;
        }
        gProgramScene[i] = LinkProgram(vs, fs, &gLocs[i]);
        glDeleteShader(fs);
        if (!gProgramScene[i]) {
            glDeleteShader(vs);
            return;
        }
    }
    GLuint fsBlit = CompileShader(GL_FRAGMENT_SHADER, kFragBlit);
    if (!fsBlit) {
        glDeleteShader(vs);
        return;
    }
    gProgramBlit = LinkProgram(vs, fsBlit, nullptr);
    if (!gProgramBlit) {
        glDeleteShader(vs);
        return;
    }
    gBlitTex = glGetUniformLocation(gProgramBlit, "uTex");
    glDeleteShader(vs);
    glDeleteShader(fsBlit);
    gReady = true;
    OH_LOG_INFO(LOG_APP, "[%s] GLES init ok, size=%{public}dx%{public}d, presets=%{public}d",
        LOG_TAG, gWidth, gHeight, kVizPresetCount);
}

void VizOnSurfaceShow(OH_NativeXComponent* component, void* window) {
    if (!gReady || gEglDisplay == EGL_NO_DISPLAY) {
        OH_LOG_INFO(LOG_APP, "[%s] surface show -> init", LOG_TAG);
        VizOnSurfaceCreated(component, window);
        return;
    }
    // 已就绪:同步最新尺寸(surface 变化经 changed 处理,这里兜底)
    uint64_t w = 0, h = 0;
    if (OH_NativeXComponent_GetXComponentSize(component, window, &w, &h) == 0) {
        gWidth = static_cast<int>(w);
        gHeight = static_cast<int>(h);
    }
}

void VizOnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    gWidth = static_cast<int>(w);
    gHeight = static_cast<int>(h);
    OH_LOG_INFO(LOG_APP, "[%s] surface changed %dx%d", LOG_TAG, gWidth, gHeight);
}

void VizOnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
    OH_LOG_INFO(LOG_APP, "[%s] surface destroyed", LOG_TAG);
    gReady = false;
    // 状态预通道资源随 context 一并失效，标记复位（下次 created 重建）
    gStateMode = 0;
    gFboState = 0;
    gTexState = 0;
    if (gEglDisplay != EGL_NO_DISPLAY) {
        eglMakeCurrent(gEglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (gEglSurface != EGL_NO_SURFACE) {
            eglDestroySurface(gEglDisplay, gEglSurface);
            gEglSurface = EGL_NO_SURFACE;
        }
        if (gEglContext != EGL_NO_CONTEXT) {
            eglDestroyContext(gEglDisplay, gEglContext);
            gEglContext = EGL_NO_CONTEXT;
        }
        eglTerminate(gEglDisplay);
        gEglDisplay = EGL_NO_DISPLAY;
    }
}

/** 在 newSize 重建两块反馈纹理；若旧纹理有效则先把旧帧 blit 拷贝过去
 *  （线性重采样），保住 uTransition 交叉淡化依赖的旧画面——切风格改变
 *  内部分辨率时，淡化源不落空、不闪花 */
void ResizeFeedbackTextures(int newW, int newH) {
    GLuint newTex[2] = {0, 0};
    GLuint newFbo[2] = {0, 0};
    for (int i = 0; i < 2; i++) {
        glGenTextures(1, &newTex[i]);
        glBindTexture(GL_TEXTURE_2D, newTex[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, newW, newH, 0,
            GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glGenFramebuffers(1, &newFbo[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, newFbo[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D, newTex[i], 0);
    }
    // 旧帧内容拷贝（首次初始化时旧纹理为 1×1 占位，拷贝无意义但无害）
    if (gProgramBlit != 0 && gTexW > 1 && gTexH > 1) {
        glBindVertexArray(gVao);
        glUseProgram(gProgramBlit);
        glViewport(0, 0, newW, newH);
        for (int i = 0; i < 2; i++) {
            glBindFramebuffer(GL_FRAMEBUFFER, newFbo[i]);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, gTex[i]);
            glUniform1i(gBlitTex, 0);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glBindVertexArray(0);
    }
    // 替换旧资源（id 已随本次 glTexImage2D 重定义失效，直接覆盖）
    for (int i = 0; i < 2; i++) {
        if (gTex[i] != 0) {
            glDeleteTextures(1, &gTex[i]);
        }
        if (gFbo[i] != 0) {
            glDeleteFramebuffers(1, &gFbo[i]);
        }
        gTex[i] = newTex[i];
        gFbo[i] = newFbo[i];
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    gTexW = newW;
    gTexH = newH;
}

void VizRenderFrame(double t, double seed, bool playing, double beat, double bass, double treble,
                     double presetLock, double transition, double tiltX, double tiltY) {
    if (!gReady || gWidth <= 0 || gHeight <= 0) {
        return;
    }
    if (gEglDisplay == EGL_NO_DISPLAY || !eglMakeCurrent(gEglDisplay, gEglSurface, gEglSurface, gEglContext)) {
        return;
    }
    // 场景选择：presetLock 越界时回落 0（ArkTS 保证 0..kVizPresetCount-1）
    int idx = static_cast<int>(presetLock + 0.5);
    if (idx < 0 || idx >= kVizPresetCount) {
        idx = 0;
    }
    // 内部目标分辨率：按场景比例（pan/aurora 低一档，上屏线性放大柔化）
    gRenderW = std::max(1, static_cast<int>(gWidth * kPresetScale[idx]));
    gRenderH = std::max(1, static_cast<int>(gHeight * kPresetScale[idx]));
    // 反馈纹理按内部尺寸初始化/重建（切风格变比例时旧帧 blit 保留）
    if (gTexW != gRenderW || gTexH != gRenderH) {
        ResizeFeedbackTextures(gRenderW, gRenderH);
    }
    glBindVertexArray(gVao);
    const SceneLocs& loc = gLocs[idx];

    // pass S（仅 pan）：状态预通道——20×4 小视口，uStateMode=1，把每颗
    // 水珠的常量状态写进 RGBA16F 纹理（主 pass 循环 texelFetch 取用）。
    // 80 像素开销可忽略；uPrev 绑定反馈纹理仅为采样器合法，写出分支不采样
    if (idx == kVizPresetPan && gStateMode == 2) {
        glBindFramebuffer(GL_FRAMEBUFFER, gFboState);
        glViewport(0, 0, kPanStateTexW, kPanStateTexH);
        glUseProgram(gProgramScene[idx]);
        glUniform1f(loc.t, static_cast<float>(t));
        glUniform1f(loc.seed, static_cast<float>(seed));
        glUniform1f(loc.beat, static_cast<float>(beat));
        glUniform1f(loc.bass, static_cast<float>(bass));
        glUniform1f(loc.treble, static_cast<float>(treble));
        glUniform1f(loc.transition, static_cast<float>(transition));
        glUniform2f(loc.tilt, static_cast<float>(tiltX), static_cast<float>(tiltY));
        glUniform1f(loc.stateMode, 1.0f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, gTex[1 - gFlip]);
        glUniform1i(loc.prev, 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }

    // pass A：场景 + 反馈拖尾 -> 当前 FBO 纹理（采样另一张上一帧纹理）
    glViewport(0, 0, gRenderW, gRenderH);
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo[gFlip]);
    glUseProgram(gProgramScene[idx]);
    glUniform1f(loc.t, static_cast<float>(t));
    glUniform1f(loc.seed, static_cast<float>(seed));
    glUniform2f(loc.res, static_cast<float>(gRenderW), static_cast<float>(gRenderH));
    glUniform1f(loc.beat, static_cast<float>(beat));
    glUniform1f(loc.bass, static_cast<float>(bass));
    glUniform1f(loc.treble, static_cast<float>(treble));
    glUniform1f(loc.transition, static_cast<float>(transition));
    glUniform2f(loc.tilt, static_cast<float>(tiltX), static_cast<float>(tiltY));
    if (idx == kVizPresetPan) {
        // 2=读状态纹理（常规）；0=回退逐像素（无浮点 FBO 的设备）
        glUniform1f(loc.stateMode, gStateMode == 2 ? 2.0f : 0.0f);
        if (gStateMode == 2) {
            glActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, gTexState);
            glUniform1i(loc.state, 1);
        }
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gTex[1 - gFlip]);
    glUniform1i(loc.prev, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    // pass B：反馈帧 -> 屏幕(全尺寸, GPU 拉伸)
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, gWidth, gHeight);
    glUseProgram(gProgramBlit);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gTex[gFlip]);
    glUniform1i(gBlitTex, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
    SwapFbo();
    eglSwapBuffers(gEglDisplay, gEglSurface);
}
