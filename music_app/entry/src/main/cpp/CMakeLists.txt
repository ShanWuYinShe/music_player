cmake_minimum_required(VERSION 3.5)
project(musicplayer)

set(CMAKE_CXX_STANDARD 17)

add_library(entry SHARED
  visualizer.cpp
  napi_init.cpp
)

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
