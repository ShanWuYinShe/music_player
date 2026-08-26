/**
 * napi_init: 模块入口 entry，导出可视化渲染接口。
 *
 * registerXComponent({ id, handle, width, height }):
 *   绑定 XComponent 的 OH_NativeXComponent 句柄并注册表面生命周期回调。
 * renderFrame(t, seed, playing):
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
}

napi_value RegisterXComponent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    OH_NativeXComponent* component = nullptr;
    napi_status status = napi_unwrap(env, args[0], reinterpret_cast<void**>(&component));
    OH_LOG_INFO(LOG_APP, "[%s] registerXComponent ok", LOG_TAG);
    if (component == nullptr) {
        return nullptr;
    }
    TryRegisterWith(component);
    return nullptr;
}

napi_value RenderFrame(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 6) {
        return nullptr;
    }
    double t = 0, seed = 0, beat = 0, bass = 0, treble = 0;
    bool playing = false;
    napi_get_value_double(env, args[0], &t);
    napi_get_value_double(env, args[1], &seed);
    napi_get_value_bool(env, args[2], &playing);
    napi_get_value_double(env, args[3], &beat);
    napi_get_value_double(env, args[4], &bass);
    napi_get_value_double(env, args[5], &treble);
    VizRenderFrame(t, seed, playing, beat, bass, treble);
    return nullptr;
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
