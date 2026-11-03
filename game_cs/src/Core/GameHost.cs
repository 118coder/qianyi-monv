// GameHost.cs — C# 逻辑层的入口节点：负责"编排"，不负责算法，也不管渲染。
//
// 三层在这里汇合：
//   · C++ 内核（NativeApi）      —— 每帧一次批量调用，Span 直通，零 Variant
//   · Godot 场景（Node/场景树）  —— 只做生命周期与输入
//   · WebView2 UI（WebUiBridge） —— 10Hz 推快照、收命令
//
// 约定：这个类里不许出现"逐个体循环调引擎对象"的写法（那是 C++ 的活）。
using System;
using Godot;
using Qy.Bridge;

namespace Qy.Core;

public partial class GameHost : Node
{
    private WebUiBridge? _ui;
    private GodotObject? _webview;
    private double _uiTimer;

    // 真实项目里这些来自 rpg_state / 队伍系统；这里只放最小快照字段
    public int Hp = 100, MaxHp = 100, Sp = 50, Gold = 0, Floor = 1;

    public bool NativeReady { get; private set; }

    public override void _Ready()
    {
        NativeReady = NativeApi.TryInitialize(out var err);
        if (!NativeReady)
        {
            GD.PushWarning($"[native] 未加载：{err} → 分离等热点退回 GDScript 实现");
        }

        SetupWebUi();
    }

    private void SetupWebUi()
    {
        // QyWebView 是 C++ 注册的类，不是 C# 类：只能 ClassDB 动态实例化
        if (!ClassDB.ClassExists("QyWebView"))
        {
            GD.PushWarning("[ui] 未找到 QyWebView（native 未编译或未加载）→ UI 走 Godot 原生实现");
            return;
        }
        if (!(ClassDB.Instantiate("QyWebView") is GodotObject webview))
        {
            return;
        }
        _webview = webview;
        if (webview is Node node)
        {
            AddChild(node);
        }
        _ui = new WebUiBridge(_webview);
        _ui.CommandReceived += OnUiCommand;
        _ui.CloseRequested += () => _ui?.SetVisible(false);
        _webview.Connect("message_received", Callable.From<string>(json => _ui?.HandleFromUi(json)));

        if (!_ui.IsAvailable && !(bool)webview.Call("available"))
        {
            GD.PushWarning("[ui] 本机没有 WebView2 Runtime → UI 走 Godot 原生实现");
            return;
        }

        // 开发期连 Vite dev server（改 CSS/JS 立即生效）；发布期加载打包后的 index.html
        string url = OS.HasFeature("editor")
            ? "http://localhost:5173/"
            : ToFileUrl("res://webui/index.html");
        _ui.Open(url);
    }

    private static string ToFileUrl(string resPath)
    {
        string abs = ProjectSettings.GlobalizePath(resPath).Replace('\\', '/');
        return "file:///" + abs;
    }

    private void OnUiCommand(UiCommand cmd)
    {
        // UI 只表达意图，这里才是"改状态"的地方
        switch (cmd.Id)
        {
            case "buy":
                GD.Print($"[ui] buy {cmd.Args}");
                break;
            case "close":
                _ui?.SetVisible(false);
                break;
            default:
                GD.PushWarning($"[ui] 未知命令 {cmd.Id}");
                break;
        }
    }

    public override void _Process(double delta)
    {
        // 快照节流到 10Hz：UI 不需要 60Hz，Chromium 侧也不会被消息洪水打满
        _uiTimer += delta;
        if (_uiTimer < 0.1) return;
        _uiTimer = 0.0;
        _ui?.PushSnapshot(Hp, MaxHp, Sp, Gold, Floor);
    }

    public override void _ExitTree()
    {
        // WebView2 进程很贵：切场景时保留实例、只隐藏；真退出时才 close
        _webview?.Call("set_visible", false);
    }
}
