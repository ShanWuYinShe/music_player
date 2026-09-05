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
/** surface show 兜底:未就绪时等价 created(幂等初始化),已就绪仅刷新尺寸 */
void VizOnSurfaceShow(OH_NativeXComponent* component, void* window);
void VizRenderFrame(double t, double seed, bool playing, double beat, double bass, double treble,
                     double presetLock, double transition, double tiltX, double tiltY);

#endif  // MUSICPLAYER_VISUALIZER_H
