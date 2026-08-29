cmake_minimum_required(VERSION 3.5)
project(musicplayer)

set(CMAKE_CXX_STANDARD 17)

# ---------------------------------------------------------------------------
# shader：磁盘上的 GLSL ES 1.00 源文件 → 构建期生成 shader_src.h（GLES3）。
#
# 源文件目录 cpp/shaders/ 与 shader_playground 预览同源（同一份磁盘文件），
# 转换规则与 shader_playground/src/glslPatch.ts 一一对应（注入头行数一致，
# 因此手机端编译报错的行号减去头行数 = 源文件行号）。
# 手机端目前只打包极光一个场景（--scenes aurora.frag）；其余场景留在
# playground 里调，不进 so。要加场景就改 SHADER_SCENES 并同步 ArkTS 的
# PRESET_COUNT / VIZ_PRESET_NAMES。
# ---------------------------------------------------------------------------
set(SHADER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/shaders)
set(SHADER_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
set(SHADER_GEN_HEADER ${SHADER_GEN_DIR}/shader_src.h)
set(SHADER_SCENES "aurora.frag")

find_package(Python3 COMPONENTS Interpreter QUIET)
if(NOT Python3_Interpreter_FOUND)
    # 退而求其次：PATH 里的 python3
    find_program(PYTHON3_BIN NAMES python3 python)
    if(NOT PYTHON3_BIN)
        message(FATAL_ERROR
            "生成 shader_src.h 需要 python3（或把 shaders/ 改动回退后手动提供头文件）")
    endif()
    set(Python3_EXECUTABLE ${PYTHON3_BIN})
endif()

file(GLOB SHADER_SOURCES ${SHADER_DIR}/*.frag ${SHADER_DIR}/*.vert)
add_custom_command(
    OUTPUT ${SHADER_GEN_HEADER}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SHADER_GEN_DIR}
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_shader_header.py
            --shader-dir ${SHADER_DIR}
            --scenes ${SHADER_SCENES}
            --out ${SHADER_GEN_HEADER}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_shader_header.py ${SHADER_SOURCES}
    COMMENT "生成 shader_src.h（GLSL ES 1.00 → GLES3，场景：${SHADER_SCENES}）"
    VERBATIM
)

add_library(entry SHARED
  visualizer.cpp
  napi_init.cpp
  ${SHADER_GEN_HEADER}
)

# 生成的头文件在构建目录里
target_include_directories(entry PRIVATE ${SHADER_GEN_DIR})

# ArkUI XComponent / NAPI 与图形系统库
target_link_libraries(entry PUBLIC
  ace_napi.z
  ace_ndk.z
  egl
  GLESv3
  hilog_ndk.z
  z
)

# 编译选项: 降低日志符号体积
target_compile_options(entry PRIVATE -fno-exceptions -fno-rtti)
