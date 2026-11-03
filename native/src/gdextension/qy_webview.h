/*
 * qy_webview.h — WebView2 的 Godot 节点封装
 *
 * 约定：**一个场景只放一个 QyWebView**（Chromium 进程很贵，反复创建/销毁会卡）；
 * 用完不 close，只 `set_visible(false)`；换页面用 `open()`。
 *
 * 坐标：`set_rect` 收的是**物理像素**（相对 Godot 窗口客户区左上角）。
 * DPI 缩放由调用方算（`DisplayServer.screen_get_scale()` 之类），再用 `set_scale()` 同步给 WebView2，
 * 这样这一层不依赖具体的 DisplayServer API 版本。
 */
#ifndef QY_GODOT_WEBVIEW_H
#define QY_GODOT_WEBVIEW_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/string.hpp>

namespace qy {
class WebViewHost;
}

namespace godot {

class QyWebView : public Node {
    GDCLASS(QyWebView, Node)

protected:
    static void _bind_methods();

public:
    QyWebView();
    ~QyWebView() override;

    /* WebView2 Runtime 是否可用；未安装时必须走 Godot 原生 UI 降级 */
    static bool available();
    static String runtime_version();

    bool open(const String &url);
    void set_rect(const Rect2i &rect);
    void set_visible(bool visible);
    void set_scale(double dpi_scale);
    bool post_json(const String &json);
    bool eval_js(const String &js);
    void focus_web();
    void close();
    bool is_ready() const;

private:
    qy::WebViewHost *host_ = nullptr;
    bool opened_ = false;
    String pending_url_;
};

}  // namespace godot

#endif  // QY_GODOT_WEBVIEW_H
