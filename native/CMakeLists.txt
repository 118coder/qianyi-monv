# =============================================================================
# qy_native —— Godot GDExtension（C++ 内核 + 可选 WebView2 宿主）
#
# 前置：godot-cpp 必须是**与引擎主版本一致**的分支（4.7.x 用 godot-4.7）
#   git submodule add -b godot-4.7 https://github.com/godotengine/godot-cpp native/godot-cpp
#
# 构建（Debug）：
#   cmake -S native -B native/build -G "Visual Studio 17 2022" -A x64 \
#         -DGODOTCPP_TARGET=template_debug \
#         -DWEBVIEW2_ROOT="<nuget>/Microsoft.Web.WebView2.<ver>/build/native"
#   cmake --build native/build --config Debug
#
# 说明：Windows 上 GDExtension 官方支持 MSVC；MinGW 能编但不被支持（异常/ABI 差异），
#      所以本文件默认按 MSVC 写。开发机上如果没有 MSVC，只能编译 src/core（纯 C++，无引擎依赖）。
# =============================================================================
cmake_minimum_required(VERSION 3.18)
project(qy_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(QY_WITH_WEBVIEW2 "编译 WebView2 UI 宿主（需要 Microsoft.Web.WebView2 native SDK）" ON)
set(GODOTCPP_TARGET "template_debug" CACHE STRING "godot-cpp 构建目标：template_debug / template_release")
set(GODOTCPP_PATH "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp" CACHE PATH "godot-cpp 源码目录")
set(WEBVIEW2_ROOT "" CACHE PATH "Microsoft.Web.WebView2 的 build/native 目录")

if(NOT EXISTS "${GODOTCPP_PATH}/CMakeLists.txt")
    message(FATAL_ERROR
        "找不到 godot-cpp：${GODOTCPP_PATH}\n"
        "先执行： git submodule update --init --recursive  （或 git submodule add ...）")
endif()

add_subdirectory("${GODOTCPP_PATH}" godot-cpp)

set(QY_SOURCES
    src/core/crowd_kernel.cpp
    src/core/api.cpp
    src/gdextension/register_types.cpp
    src/gdextension/qy_native.cpp
)

if(QY_WITH_WEBVIEW2)
    if(WEBVIEW2_ROOT STREQUAL "" OR NOT EXISTS "${WEBVIEW2_ROOT}/include/WebView2.h")
        message(WARNING "未找到 WebView2 SDK（-DWEBVIEW2_ROOT=...），本次**不编译** WebView2 宿主。"
                        "游戏可以用 QyWebView.available() 判断并走原生 UI 降级。")
        set(QY_WITH_WEBVIEW2 OFF)
    else()
        list(APPEND QY_SOURCES
            src/webview2/webview_host.cpp
            src/gdextension/qy_webview.cpp
        )
    endif()
endif()

# 构建标签：日志里能看出加载的是哪次构建
execute_process(
    COMMAND git rev-parse --short HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    OUTPUT_VARIABLE QY_GIT_HASH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(QY_GIT_HASH STREQUAL "")
    set(QY_GIT_HASH "nogit")
endif()

add_library(qy_native SHARED ${QY_SOURCES})

target_include_directories(qy_native PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/core"
)
target_link_libraries(qy_native PRIVATE godot-cpp)

target_compile_definitions(qy_native PRIVATE
    QY_BUILD_TAG="${QY_GIT_HASH}-${GODOTCPP_TARGET}"
)

if(QY_WITH_WEBVIEW2)
    target_compile_definitions(qy_native PRIVATE QY_WITH_WEBVIEW2=1)
    target_include_directories(qy_native PRIVATE "${WEBVIEW2_ROOT}/include")
    target_link_libraries(qy_native PRIVATE
        "${WEBVIEW2_ROOT}/x64/WebView2LoaderStatic.lib"
        ole32 oleaut32 user32 version)
endif()

if(MSVC)
    target_compile_options(qy_native PRIVATE /W4 /permissive- /utf-8 /Zc:__cplusplus)
else()
    target_compile_options(qy_native PRIVATE -Wall -Wextra)
endif()

# 输出名必须与 .gdextension 里的库名逐字一致：
#   <name>.<平台>.<debug|release>.<架构>.dll
set(QY_LIB_NAME "qy_native.windows.${GODOTCPP_TARGET}.x86_64")
set_target_properties(qy_native PROPERTIES
    PREFIX ""
    OUTPUT_NAME "${QY_LIB_NAME}"
)

# 直接落到 res://native/bin/，省去手动拷贝（也是 .gdextension 指向的位置）
add_custom_command(TARGET qy_native POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/bin"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:qy_native>"
            "${CMAKE_CURRENT_SOURCE_DIR}/bin/${QY_LIB_NAME}.dll"
    COMMENT "部署 ${QY_LIB_NAME}.dll → native/bin/"
)
