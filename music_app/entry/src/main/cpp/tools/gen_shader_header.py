#!/usr/bin/env python3
"""把 shaders/ 下的 GLSL ES 1.00 源文件转成 GLES3 可用的 shader_src.h。

与 shader_playground 的 src/glslPatch.ts 是同一套规则的两份实现
（注入内容的行数必须完全一致，否则手机端编译报错的行号对不上源文件）：
  - 注入 #version 300 es 头：精度 + uniform/varying/out 声明
  - 源文件里已声明的 uniform/varying/precision/attribute 一律"整行置空"
    （不是删行！保留行数 → 编译报错行号 − 头行数 = 源文件行号）
  - texture2D → texture、attribute → in、gl_FragColor → fragColor
  - 场景共享公共库 common.glsl 走同一套置空/替换管线后，注入到
    "头之后、场景源之前"；场景源不得重复定义其中的函数。
    行号换算：报错行号 − 头行数(13) − common 行数 = 场景源行号；
    落在 common 区间内则是 common.glsl 自身行号。

手机端（GLES 3.0）与 playground（WebGL2）因此共用同一份磁盘 GLSL 源文件。

用法：
  python3 tools/gen_shader_header.py --shader-dir shaders --out build/shader_src.h
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FRAG_UNIFORMS = [
    "uT",
    "uSeed",
    "uRes",
    "uBeat",
    "uBass",
    "uTreble",
    "uTilt",
    "uSpin",
    "uKick",
    "uTransition",
    "uPrev",
]

# 行数必须与 glslPatch.ts 的 *_HEADER_LINES 一致（15 / 4 / 5）
FRAG_HEADER = (
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform float uT;\n"
    "uniform float uSeed;\n"
    "uniform vec2 uRes;\n"
    "uniform float uBeat;\n"
    "uniform float uBass;\n"
    "uniform float uTreble;\n"
    "uniform vec2 uTilt;\n"
    "uniform float uSpin;\n"
    "uniform float uKick;\n"
    "uniform float uTransition;\n"
    "uniform sampler2D uPrev;\n"
    "in vec2 vUV;\n"
    "out vec4 fragColor;\n"
)
VERT_HEADER = (
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 aPos;\n"
    "out vec2 vUV;\n"
)
BLIT_HEADER = (
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 vUV;\n"
    "uniform sampler2D uTex;\n"
    "out vec4 fragColor;\n"
)

# 默认场景槽顺序必须与 CMake SHADER_SCENES、VisualizerCore.ets 和
# shader_playground/src/presets.ts 的 PRESETS 一致。
DEFAULT_SCENE_FILES = ["fractal.frag", "pan.frag", "aurora.frag", "spectrum.frag"]

# 场景共享公共库：注入到每个场景"头之后、场景源之前"（presets.ts COMMON_FILE）
COMMON_FILE = "common.glsl"

# 整行置空的规则（与 glslPatch.ts 同构）
VERSION_RE = re.compile(r"^[ \t]*#version[^\n]*")
PRECISION_RE = re.compile(r"^[ \t]*precision[ \t]+\w+[ \t]+\w+[ \t]*;[ \t]*", re.M)
VARYING_RE = re.compile(r"^[ \t]*varying[ \t]+[^;\n]+;[ \t]*", re.M)
APOS_RE = re.compile(r"^[ \t]*(?:attribute|in)[ \t]+vec2[ \t]+aPos[ \t]*;[ \t]*", re.M)
TEXTURE2D_RE = re.compile(r"\btexture2D[ \t]*\(")

# raw string 分隔符：GLSL 里不可能出现 )GLSL"
DELIM = "GLSL"


def uniform_re(names: list[str]) -> re.Pattern[str]:
    alt = "|".join(re.escape(n) for n in names)
    return re.compile(rf"^[ \t]*uniform[ \t]+\w+[ \t]+(?:{alt})[ \t]*;[ \t]*", re.M)


FRAG_UNIFORM_RE = uniform_re(FRAG_UNIFORMS)
BLIT_UNIFORM_RE = uniform_re(["uTex"])


def read(path: Path) -> str:
    if not path.is_file():
        sys.exit(f"[gen_shader_header] 源文件不存在：{path}")
    return path.read_text(encoding="utf-8")


def strip_common(src: str, label: str) -> str:
    """注入头相关的声明一律整行置空（保留行数 → 报错行号可换算）"""
    out = VERSION_RE.sub("", src, count=1)          # 只吃第一行的 #version
    assert_no_version_left(out, label)              # 其余任何 #version 都是源文件问题
    out = PRECISION_RE.sub("", out)
    out = VARYING_RE.sub("", out)
    return out


def transform_frag_body(src: str, label: str) -> str:
    """fragment 源码体（场景或 common.glsl）的统一变换：
    置空注入头已声明的行 + 词汇替换。所有置空都保留行数。
    与 glslPatch.ts 的 transformFragBody 一一对应。"""
    out = strip_common(src, label)
    out = FRAG_UNIFORM_RE.sub("", out)
    out = TEXTURE2D_RE.sub("texture(", out)
    out = re.sub(r"\battribute[ \t]+", "in ", out)
    out = out.replace("gl_FragColor", "fragColor")
    return out


def patch_vert(src: str) -> str:
    out = strip_common(src, "visualizer.vert")
    out = APOS_RE.sub("", out)
    out = TEXTURE2D_RE.sub("texture(", out)
    return VERT_HEADER + out


def patch_frag(src: str, label: str, common: str) -> str:
    """common.glsl 注入到"头之后、场景源之前"（与 glslPatch.ts 同序）"""
    lib = transform_frag_body(common, COMMON_FILE)
    if not lib.endswith("\n"):
        lib += "\n"
    body = transform_frag_body(src, label)
    return FRAG_HEADER + lib + body


def patch_blit(src: str) -> str:
    out = strip_common(src, "blit.frag")
    out = BLIT_UNIFORM_RE.sub("", out)
    out = TEXTURE2D_RE.sub("texture(", out)
    out = re.sub(r"\battribute[ \t]+", "in ", out)
    out = out.replace("gl_FragColor", "fragColor")
    return BLIT_HEADER + out


def assert_no_version_left(body: str, label: str) -> None:
    """与 glslPatch.ts 一致：剥掉首行后若仍有 #version，给出可读错误"""
    if re.search(r"(^|\n)[ \t]*#version", body):
        sys.exit(f"[gen_shader_header] {label}：#version 只能出现在第一行（或不要写）")


def raw_string(name: str, body: str) -> str:
    if f"){DELIM}\"" in body:
        sys.exit(f"[gen_shader_header] {name} 含 raw string 终止序列，无法安全嵌入")
    if not body.endswith("\n"):
        body += "\n"
    return f'const char* {name} = R"{DELIM}({body}){DELIM}";\n'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shader-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--scenes", default=",".join(DEFAULT_SCENE_FILES))
    args = ap.parse_args()

    scene_files = [s.strip() for s in args.scenes.split(",") if s.strip()]
    if not scene_files:
        sys.exit("[gen_shader_header] --scenes 为空")

    d = args.shader_dir
    vert = read(d / "visualizer.vert")
    blit = read(d / "blit.frag")
    common = read(d / COMMON_FILE)
    scenes = [(f, read(d / f)) for f in scene_files]

    vert_p = patch_vert(vert)
    blit_p = patch_blit(blit)
    scene_p = [(f, patch_frag(s, f, common)) for f, s in scenes]

    # 注入区行数（头 + common），编译报错行号减去它即场景源文件行号
    common_norm = common if common.endswith("\n") else common + "\n"
    frag_injected = 15 + common_norm.count("\n")

    var_name = {f: "kFragScene" + f.split(".")[0].capitalize() for f in scene_files}
    parts: list[str] = []
    parts.append(
        "/**\n"
        " * shader_src.h：由 tools/gen_shader_header.py 自动生成，请勿手改。\n"
        " *\n"
        " * 源：entry/src/main/cpp/shaders/ 下的 GLSL ES 1.00 文件（与\n"
        " * shader_playground 预览、shader_playground/src/glslPatch.ts 同源）。\n"
        f" * frag 注入区 {frag_injected} 行（头 15 + common.glsl {common_norm.count(chr(10))}），\n"
        " * vert/blit 注入头 4/5 行；编译报错行号减去对应注入区行数即源文件行号。\n"
        " */\n"
        "\n"
        "#ifndef MUSICPLAYER_SHADER_SRC_H\n"
        "#define MUSICPLAYER_SHADER_SRC_H\n"
        "\n"
        "namespace {\n\n"
    )
    parts.append(raw_string("kVertSrc", vert_p))
    parts.append("\n")
    for f, body in scene_p:
        parts.append(raw_string(var_name[f], body))
    parts.append("\nconst char* kFragScene[] = {\n")
    for f in scene_files:
        parts.append(f"    {var_name[f]},\n")
    parts.append("};\n")
    parts.append(f"constexpr int kVizPresetCount = {len(scene_files)};\n")
    parts.append("\n")
    parts.append(raw_string("kFragBlit", blit_p))
    parts.append("\n}  // namespace\n\n#endif  // MUSICPLAYER_SHADER_SRC_H\n")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(parts), encoding="utf-8")
    print(f"[gen_shader_header] 已生成 {args.out}（{len(scene_files)} 个场景）")


if __name__ == "__main__":
    main()
