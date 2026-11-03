#include "qy_webview.h"

#ifdef QY_WITH_WEBVIEW2
#  include "webview_host.h"
#endif

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void QyWebView::_bind_methods() {
    ClassDB::bind_static_method("QyWebView", D_METHOD("available"), &QyWebView::available);
    ClassDB::bind_static_method("QyWebView", D_METHOD("runtime_version"), &QyWebView::runtime_version);
    ClassDB::bind_method(D_METHOD("open", "url"), &QyWebView::open);
    ClassDB::bind_method(D_METHOD("set_rect", "rect"), &QyWebView::set_rect);
    ClassDB::bind_method(D_METHOD("set_visible", "visible"), &QyWebView::set_visible);
    ClassDB::bind_method(D_METHOD("set_scale", "dpi_scale"), &QyWebView::set_scale);
    ClassDB::bind_method(D_METHOD("post_json", "json"), &QyWebView::post_json);
    ClassDB::bind_method(D_METHOD("eval_js", "js"), &QyWebView::eval_js);
    ClassDB::bind_method(D_METHOD("focus_web"), &QyWebView::focus_web);
    ClassDB::bind_method(D_METHOD("close"), &QyWebView::close);
    ClassDB::bind_method(D_METHOD("is_ready"), &QyWebView::is_ready);

    /* UI → 游戏：只发 JSON 字符串，协议见 webui/src/bridge.js */
    ADD_SIGNAL(MethodInfo("message_received", PropertyInfo(Variant::STRING, "json")));
}

QyWebView::QyWebView() = default;

QyWebView::~QyWebView() {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr) {
        host_->Shutdown();
        delete host_;
        host_ = nullptr;
    }
#endif
}

bool QyWebView::available() {
#ifdef QY_WITH_WEBVIEW2
    return qy::WebViewHost::Available(nullptr);
#else
    return false;
#endif
}

String QyWebView::runtime_version() {
#ifdef QY_WITH_WEBVIEW2
    std::string v;
    if (qy::WebViewHost::Available(&v)) {
        return String(v.c_str());
    }
#endif
    return String();
}

bool QyWebView::open(const String &url) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ == nullptr) {
        host_ = new qy::WebViewHost();
    }
    if (!host_->IsReady()) {
        /* 首次：用 Godot 主窗口句柄初始化。回调在初始化线程（主线程）上派发。 */
        const uint64_t hwnd = DisplayServer::get_singleton()->window_get_native_handle(
            DisplayServer::WINDOW_HANDLE, 0);
        const String data_dir = OS::get_singleton()->get_user_data_dir() + "/webview2";
        QyWebView *self = this;
        const bool started = host_->Initialize(
            reinterpret_cast<void *>(static_cast<uintptr_t>(hwnd)),
            data_dir.utf8().get_data(),
            [self](const std::string &json) {
                /* 事件可能来自 WebView 的消息泵，统一 deferred 回主线程再发信号 */
                self->call_deferred("emit_signal", StringName("message_received"),
                                    String(json.c_str()));
            });
        if (!started) {
            return false;
        }
        pending_url_ = url;
        opened_ = true;
        return true;
    }
    host_->Navigate(url.utf8().get_data());
    return true;
#else
    (void)url;
    return false;
#endif
}

void QyWebView::set_rect(const Rect2i &rect) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr) {
        host_->SetBounds(rect.position.x, rect.position.y, rect.size.x, rect.size.y);
    }
#else
    (void)rect;
#endif
}

void QyWebView::set_visible(bool visible) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ == nullptr) {
        return;
    }
    host_->SetVisible(visible);
    if (visible) {
        host_->MoveFocus();
        if (opened_ && !pending_url_.is_empty() && host_->IsReady()) {
            host_->Navigate(pending_url_.utf8().get_data());
            pending_url_ = String();
        }
    }
#else
    (void)visible;
#endif
}

void QyWebView::set_scale(double dpi_scale) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr) {
        host_->SetScale(dpi_scale);
    }
#else
    (void)dpi_scale;
#endif
}

bool QyWebView::post_json(const String &json) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr && host_->IsReady()) {
        host_->PostJson(json.utf8().get_data());
        return true;
    }
#endif
    (void)json;
    return false;
}

bool QyWebView::eval_js(const String &js) {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr && host_->IsReady()) {
        host_->EvalJs(js.utf8().get_data());
        return true;
    }
#endif
    (void)js;
    return false;
}

void QyWebView::focus_web() {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr) {
        host_->MoveFocus();
    }
#endif
}

void QyWebView::close() {
#ifdef QY_WITH_WEBVIEW2
    if (host_ != nullptr) {
        host_->Shutdown();
    }
    opened_ = false;
    pending_url_ = String();
#endif
}

bool QyWebView::is_ready() const {
#ifdef QY_WITH_WEBVIEW2
    return host_ != nullptr && host_->IsReady();
#else
    return false;
#endif
}

}  // namespace godot
