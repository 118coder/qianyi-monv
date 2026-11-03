/*
 * webview_host.cpp — WebView2 最小可用宿主实现
 *
 * ⚠️ 本文件依赖 Microsoft.Web.WebView2 的 native SDK 头文件（WebView2.h）。
 *    它没有在开发机上编译过（该机无 MSVC / CMake / WebView2 SDK），
 *    首次接入请按 docs/ARCH-多语言架构.md 的"WebView2 落地检查清单"逐项核对：
 *      1) NuGet 包的 include 目录已加入 CMake target_include_directories
 *      2) WebView2Loader 链接方式（静态 / 复制 DLL）
 *      3) ICoreWebView2Controller3 的 QI 失败时要能退回 Controller2（老运行时）
 */
#if defined(_WIN32)

#include "webview_host.h"

#include <windows.h>
#include <wrl.h>

#include <WebView2.h>

#include <string>

using namespace Microsoft::WRL;

namespace qy {
namespace {

std::wstring Utf8ToWide(const std::string &s) {
    if (s.empty()) {
        return std::wstring();
    }
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

std::string WideToUtf8(const std::wstring &s) {
    if (s.empty()) {
        return std::string();
    }
    const int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                                      nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                        out.data(), n, nullptr, nullptr);
    return out;
}

}  // namespace

struct WebViewHost::Impl {
    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    MessageFn on_message;
    bool ready = false;
    RECT bounds{0, 0, 0, 0};
    bool visible = false;
    double scale = 1.0;
};

WebViewHost::WebViewHost() : impl_(new Impl()) {}

WebViewHost::~WebViewHost() {
    Shutdown();
    delete impl_;
}

bool WebViewHost::Available(std::string *out_version) {
    LPWSTR version = nullptr;
    const HRESULT hr = GetAvailableCoreWebView2BrowserVersionString(nullptr, &version);
    if (SUCCEEDED(hr) && version != nullptr) {
        if (out_version != nullptr) {
            *out_version = WideToUtf8(version);
        }
        CoTaskMemFree(version);
        return true;
    }
    if (version != nullptr) {
        CoTaskMemFree(version);
    }
    return false;
}

bool WebViewHost::Initialize(void *parent_hwnd, const std::string &user_data_dir, MessageFn on_message) {
    if (parent_hwnd == nullptr) {
        return false;
    }
    impl_->on_message = std::move(on_message);

    /* Godot 主线程可能已初始化过 COM；RPC_E_CHANGED_MODE 说明模式不同，能继续用就别当失败 */
    const HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    (void)co;

    const std::wstring data_dir = Utf8ToWide(user_data_dir);
    Impl *impl = impl_;

    auto env_handler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [impl, parent_hwnd](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
            if (FAILED(result) || env == nullptr) {
                return result;
            }
            impl->env = env;
            HWND hwnd = static_cast<HWND>(parent_hwnd);
            return env->CreateCoreWebView2Controller(
                hwnd,
                Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [impl](HRESULT res, ICoreWebView2Controller *controller) -> HRESULT {
                        if (FAILED(res) || controller == nullptr) {
                            return res;
                        }
                        impl->controller = controller;
                        impl->controller->get_CoreWebView2(&impl->webview);

                        /* DPI：Controller3 才有 RasterizationScale，老运行时退回 1.0 */
                        ComPtr<ICoreWebView2Controller3> c3;
                        if (SUCCEEDED(impl->controller.As(&c3)) && c3 != nullptr) {
                            c3->put_RasterizationScale(impl->scale);
                            c3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RASTERIZATION_SCALE);
                        }

                        /* UI → 宿主：默认只收 JSON 字符串消息（协议见 webui/src/bridge.js） */
                        impl->webview->add_WebMessageReceived(
                            Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                [impl](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                                    LPWSTR raw = nullptr;
                                    if (SUCCEEDED(args->TryGetWebMessageAsString(&raw)) && raw != nullptr) {
                                        if (impl->on_message) {
                                            impl->on_message(WideToUtf8(raw));
                                        }
                                        CoTaskMemFree(raw);
                                    }
                                    return S_OK;
                                })
                                .Get(),
                            nullptr);

                        /* 关掉右键菜单 / 开发者工具提示，游戏里不需要 */
                        ComPtr<ICoreWebView2Settings> settings;
                        if (SUCCEEDED(impl->webview->get_Settings(&settings)) && settings != nullptr) {
                            settings->put_AreDefaultContextMenusEnabled(FALSE);
                            settings->put_IsStatusBarEnabled(FALSE);
                            settings->put_AreDevToolsEnabled(TRUE);  // 调试期留着，发布前改 FALSE
                        }

                        impl->controller->put_Bounds(impl->bounds);
                        impl->controller->put_IsVisible(impl->visible ? TRUE : FALSE);
                        impl->ready = true;
                        return S_OK;
                    })
                    .Get());
        });

    const HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, data_dir.c_str(), nullptr, env_handler.Get());
    return SUCCEEDED(hr);
}

bool WebViewHost::IsReady() const {
    return impl_ != nullptr && impl_->ready;
}

void WebViewHost::SetBounds(int x, int y, int width, int height) {
    impl_->bounds = RECT{x, y, x + width, y + height};
    if (impl_->controller != nullptr) {
        impl_->controller->put_Bounds(impl_->bounds);
    }
}

void WebViewHost::SetVisible(bool visible) {
    impl_->visible = visible;
    if (impl_->controller != nullptr) {
        impl_->controller->put_IsVisible(visible ? TRUE : FALSE);
    }
}

void WebViewHost::SetScale(double dpi_scale) {
    impl_->scale = (dpi_scale > 0.1) ? dpi_scale : 1.0;
    ComPtr<ICoreWebView2Controller3> c3;
    if (impl_->controller != nullptr && SUCCEEDED(impl_->controller.As(&c3)) && c3 != nullptr) {
        c3->put_RasterizationScale(impl_->scale);
    }
}

void WebViewHost::Navigate(const std::string &url_utf8) {
    if (impl_->webview != nullptr) {
        impl_->webview->Navigate(Utf8ToWide(url_utf8).c_str());
    }
}

void WebViewHost::PostJson(const std::string &json_utf8) {
    if (impl_->webview != nullptr) {
        impl_->webview->PostWebMessageAsJson(Utf8ToWide(json_utf8).c_str());
    }
}

void WebViewHost::EvalJs(const std::string &js_utf8) {
    if (impl_->webview != nullptr) {
        impl_->webview->ExecuteScript(Utf8ToWide(js_utf8).c_str(), nullptr);
    }
}

void WebViewHost::MoveFocus() {
    if (impl_->controller != nullptr) {
        impl_->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
}

void WebViewHost::Shutdown() {
    if (impl_ == nullptr) {
        return;
    }
    impl_->ready = false;
    if (impl_->controller != nullptr) {
        impl_->controller->Close();
    }
    impl_->webview.Reset();
    impl_->controller.Reset();
    impl_->env.Reset();
}

}  // namespace qy

#endif  // _WIN32
