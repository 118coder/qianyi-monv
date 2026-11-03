/*
 * webview_host.h — WebView2 宿主（Win32 / COM）
 *
 * 定位：把一块 Chromium 渲染的子窗口"贴"在 Godot 窗口的指定矩形上，并双向传消息。
 * 关键事实（决定了它的能力边界）：
 *   · WebView2 的 controller 会在父 HWND 下创建自己的**子 HWND**，绘制在 Godot 的交换链之上，
 *     无法被游戏图层遮挡 —— 所以它适合做"模态 UI / 全屏菜单"，不适合做世界内 HUD；
 *   · 事件回调在创建它的线程（也就是 Godot 主线程）上派发，但仍建议 deferred 回脚本，避免重入；
 *   · 分辨率/DPI：用 ICoreWebView2Controller3::put_RasterizationScale 对齐显示缩放，
 *     否则 125%/150% 缩放下 UI 会糊或错位。
 *
 * 依赖：
 *   · Microsoft.Web.WebView2（NuGet，native 包）—— 提供 WebView2.h 与 WebView2Loader
 *   · WebView2 Runtime（Evergreen）必须已安装；用 Available() 探测并降级
 */
#ifndef QY_WEBVIEW_HOST_H
#define QY_WEBVIEW_HOST_H

#include <functional>
#include <string>

namespace qy {

class WebViewHost {
public:
    using MessageFn = std::function<void(const std::string &json)>;

    WebViewHost();
    ~WebViewHost();

    WebViewHost(const WebViewHost &) = delete;
    WebViewHost &operator=(const WebViewHost &) = delete;

    /* 探测运行时；成功时把版本号写进 out_version。没有运行时必须优雅降级（用 Godot 原生 UI 兜底） */
    static bool Available(std::string *out_version);

    /*
     * 异步初始化。parent_hwnd 传 Godot 主窗口句柄（DisplayServer::window_get_native_handle）。
     * user_data_dir 必须是可写目录（%LOCALAPPDATA%/... ），不要放进 res://（打包后是只读 PCK）。
     * 返回 true 只代表"已开始初始化"，真正可用看 IsReady()。
     */
    bool Initialize(void *parent_hwnd, const std::string &user_data_dir, MessageFn on_message);

    bool IsReady() const;

    void SetBounds(int x, int y, int width, int height);
    void SetVisible(bool visible);
    void SetScale(double dpi_scale);
    void Navigate(const std::string &url_utf8);
    void PostJson(const std::string &json_utf8);
    void EvalJs(const std::string &js_utf8);
    void MoveFocus();
    void Shutdown();

private:
    struct Impl;
    Impl *impl_ = nullptr;
};

}  // namespace qy

#endif  // QY_WEBVIEW_HOST_H
