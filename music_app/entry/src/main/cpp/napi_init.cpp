/**
 * napi_init: 模块入口 entry，导出可视化渲染接口。
 *
 * registerXComponent(nativeObject):
 *   解包 XComponent 的 OH_NativeXComponent 句柄并注册表面生命周期回调。
 * renderFrame(t, seed, playing, beat, bass, treble, presetLock, transition,
 *             tiltX, tiltY, spin, kick):
 *   同步渲染一帧（由 ArkTS displaySync 回调驱动）。
 * destroy():
 *   释放渲染资源（组件销毁时）。
 */

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <cstdint>
#include <string>

#include <napi/native_api.h>

#include "visualizer.h"

#undef LOG_TAG
#define LOG_TAG "VizNative"

namespace {

void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    VizOnSurfaceCreated(component, window);
}
void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    VizOnSurfaceChanged(component, window);
}
void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
    VizOnSurfaceDestroyed(component, window);
}
// surface show 兜底:重进播放页时 XComponent 新实例的 created 事件早于
// onLoad 注册(fallback register 不回放),而 show 事件晚于注册——由它补发
// EGL 初始化(内部幂等),修复"第二次进入可视化必黑屏"。
void OnSurfaceShow(OH_NativeXComponent* component, void* window) {
    VizOnSurfaceShow(component, window);
}

// 框架保存回调结构指针, 必须静态存储直至 OnSurfaceDestroyed
OH_NativeXComponent_Callback gCallback = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = nullptr,
};

void TryRegisterWith(OH_NativeXComponent* component) {
    if (component == nullptr) {
        return;
    }
    int32_t ret = OH_NativeXComponent_RegisterCallback(component, &gCallback);
    OH_LOG_INFO(LOG_APP, "[%s] RegisterCallback ret=%{public}d", LOG_TAG, ret);
    // show 兜底注册(created 丢失时的第二初始化路径)
    ret = OH_NativeXComponent_RegisterSurfaceShowCallback(component, OnSurfaceShow);
    OH_LOG_INFO(LOG_APP, "[%s] RegisterSurfaceShowCallback ret=%{public}d", LOG_TAG, ret);
}

napi_value Undefined(napi_env env) {
    napi_value value = nullptr;
    napi_get_undefined(env, &value);
    return value;
}

napi_value RegisterXComponent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 1 || args[0] == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[%s] registerXComponent missing native object", LOG_TAG);
        return Undefined(env);
    }
    OH_NativeXComponent* component = nullptr;
    status = napi_unwrap(env, args[0], reinterpret_cast<void**>(&component));
    if (status != napi_ok || component == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[%s] registerXComponent unwrap failed status=%{public}d", LOG_TAG, status);
        return Undefined(env);
    }
    OH_LOG_INFO(LOG_APP, "[%s] registerXComponent fallback register", LOG_TAG);
    TryRegisterWith(component);
    return Undefined(env);
}

napi_value RenderFrame(napi_env env, napi_callback_info info) {
    size_t argc = 12;
    napi_value args[12] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 12) {
        napi_value no = nullptr;
        napi_get_boolean(env, false, &no);
        return no;
    }
    double t = 0, seed = 0, beat = 0, bass = 0, treble = 0, presetLock = -1, transition = 1;
    double tiltX = 0, tiltY = 0, spin = 0, kick = 0;
    bool playing = false;
    napi_get_value_double(env, args[0], &t);
    napi_get_value_double(env, args[1], &seed);
    napi_get_value_bool(env, args[2], &playing);
    napi_get_value_double(env, args[3], &beat);
    napi_get_value_double(env, args[4], &bass);
    napi_get_value_double(env, args[5], &treble);
    napi_get_value_double(env, args[6], &presetLock);
    napi_get_value_double(env, args[7], &transition);
    napi_get_value_double(env, args[8], &tiltX);
    napi_get_value_double(env, args[9], &tiltY);
    napi_get_value_double(env, args[10], &spin);
    napi_get_value_double(env, args[11], &kick);
    bool drew = VizRenderFrame(t, seed, playing, beat, bass, treble, presetLock, transition,
                               tiltX, tiltY, spin, kick);
    // 返回是否真的绘制：未就绪（场景 program 后台编译中）时 false，ArkTS
    // 侧据此显示编译中占位过渡，避免切到可视化时的空屏
    napi_value out = nullptr;
    napi_get_boolean(env, drew, &out);
    return out;
}

napi_value Destroy(napi_env env, napi_callback_info info) {
    VizOnSurfaceDestroyed(nullptr, nullptr);
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"registerXComponent", nullptr, RegisterXComponent, nullptr,
            nullptr, nullptr, napi_default, nullptr},
        {"renderFrame", nullptr, RenderFrame, nullptr,
            nullptr, nullptr, napi_default, nullptr},
        {"destroy", nullptr, Destroy, nullptr,
            nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    // 官方路径: 框架会把 __NATIVE_XCOMPONENT_OBJ__ 注入 exports,
    // 在此注册可赶在 surface 创建之前(早于 onLoad)
    napi_value nativeObj = nullptr;
    if (napi_get_named_property(env, exports, "__NATIVE_XCOMPONENT_OBJ__", &nativeObj) == napi_ok
        && nativeObj != nullptr) {
        OH_NativeXComponent* component = nullptr;
        if (napi_unwrap(env, nativeObj, reinterpret_cast<void**>(&component)) == napi_ok
            && component != nullptr) {
            OH_LOG_INFO(LOG_APP, "[%s] early register in Init", LOG_TAG);
            TryRegisterWith(component);
        }
    }
    return exports;
}

}  // namespace

static napi_module gModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&gModule);
}
