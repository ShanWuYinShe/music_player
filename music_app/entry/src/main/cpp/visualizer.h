/**
 * visualizer.h：XComponent 渲染管线的对外接口。
 * 生命周期回调与一帧渲染函数由 napi_init 绑定到 XComponent 与本模块。
 */

#ifndef MUSICPLAYER_VISUALIZER_H
#define MUSICPLAYER_VISUALIZER_H

struct OH_NativeXComponent;

void VizOnSurfaceCreated(OH_NativeXComponent* component, void* window);
void VizOnSurfaceChanged(OH_NativeXComponent* component, void* window);
void VizOnSurfaceDestroyed(OH_NativeXComponent* component, void* window);
void VizRenderFrame(double t, double seed, bool playing, double beat, double bass, double treble);

#endif  // MUSICPLAYER_VISUALIZER_H
