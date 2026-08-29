// visualizer.vert：全屏三角形（3 顶点覆盖全屏，无邻接边缝）。
// 与手机端 visualizer.cpp 的 kVertSrc 一致；工具会注入 aPos/vUV 声明。
attribute vec2 aPos;
varying vec2 vUV;

void main() {
    vUV = aPos * 0.5 + 0.5;
    gl_Position = vec4(aPos, 0.0, 1.0);
}
