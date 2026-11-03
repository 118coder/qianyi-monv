# native/ — C++ 内核 + GDExtension 插件

> 完整设计见 `docs/多语言架构_CSharp_CPP_WebView2.md`。这里只放"进这个目录需要立刻知道的事"。

## 结构

| 路径 | 内容 | 允许 include godot？ |
|---|---|---|
| `include/qy_native_api.h` | 唯一的 C ABI 契约（C# 也照它写结构体） | ❌ |
| `src/core/` | 纯算法：群体分离等 | ❌ **绝对不允许** |
| `src/gdextension/` | Godot 绑定薄壳（QyNative / QyWebView） | ✅ |
| `src/webview2/` | WebView2 宿主（COM/Win32） | ❌（只依赖 Win32） |
| `bin/` | 构建产物，不入库 | — |

## 三分钟上手

```powershell
# 1) 拉 godot-cpp（分支必须与引擎主版本一致）
git submodule add -b godot-4.7 https://github.com/godotengine/godot-cpp native/godot-cpp
git submodule update --init --recursive

# 2) 构建（需要 MSVC + CMake）
powershell -ExecutionPolicy Bypass -File tools\build_native.ps1 -Config debug
#    带 WebView2：
#    ... -WebView2Root "C:\nuget\Microsoft.Web.WebView2.<ver>\build\native"

# 3) 构建成功后脚本会生成 native/qy_native.gdextension，编辑器启动时自动加载
```

## 改代码前请先看

1. `src/core` 里**不许**出现 `#include <godot_cpp/...>` —— 它是可单测、可复用的算法层。
2. 新增导出**只加字段**，不改已有字段顺序/类型；破坏性变更开 `qy_api_v2`。
3. 内核线程里只能碰 POD；要回游戏一律走主线程轮询或 `call_deferred`。
4. 库名必须与 `qy_native.gdextension` 完全一致（`qy_native.windows.<debug|release>.x86_64.dll`）。

## 没装工具链也能做的验证

```bash
# 只校验纯 C++ 内核（不需要 MSVC / godot-cpp）
g++ -std=c++17 -Wall -Wextra -fsyntax-only -Inative/include -Inative/src/core \
    native/src/core/crowd_kernel.cpp native/src/core/api.cpp
```
