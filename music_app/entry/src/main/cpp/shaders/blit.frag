// blit.frag：内部 FBO → 屏幕上屏，纯采样（GL_LINEAR 放大到全分辨率）。
uniform sampler2D uTex;
varying vec2 vUV;

void main() {
    gl_FragColor = texture2D(uTex, vUV);
}
