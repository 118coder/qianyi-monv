// WebUiBridge.cs — C# 与 WebView2 UI 的唯一通道（JSON 消息，单向数据流）
//
// 协议（与 webui/src/bridge.js 一一对应，改一边必须改另一边）：
//
//   Host → UI
//     {"t":"snapshot","seq":12,"hp":87,"maxHp":120,"sp":40,"gold":312,"floor":3,
//      "party":[{"name":"剑士·凛","hp":100,"max":120,"cmd":"follow"}],"toast":"获得 3G"}
//     {"t":"open","screen":"shop","payload":{...}}
//     {"t":"close","screen":"shop"}
//
//   UI → Host
//     {"t":"ready"}                              页面加载完，可以开始推快照
//     {"t":"cmd","id":"buy","args":{"item":"potion"}}
//     {"t":"close"}                              玩家按 Esc / 关面板
//
// 约束：
//   · UI 只发"意图"，从不发"状态"；游戏状态权威永远在 C#/C++ 侧；
//   · 快照节流到 10Hz，且只在数值变化时推（菜单类 UI 不需要 60Hz）；
//   · 一帧内不得 Send 多条 —— 合并成一条快照。
using System;
using System.Text.Json;
using System.Text.Json.Nodes;
using Godot;

namespace Qy.Bridge;

public sealed class UiCommand
{
    public string Id = string.Empty;
    public JsonObject Args = new();
}

public sealed class WebUiBridge
{
    private readonly GodotObject? _webview;
    private long _seq;

    public event Action<UiCommand>? CommandReceived;
    public event Action? Ready;
    public event Action? CloseRequested;

    public bool IsAvailable => _webview != null && _webview.Call("is_ready").AsBool();

    /// <param name="webview">QyWebView 节点（GDExtension 类，C# 侧只能用 GodotObject 动态访问）</param>
    public WebUiBridge(GodotObject? webview)
    {
        _webview = webview;
    }

    public bool Open(string url)
    {
        if (_webview == null) return false;
        return _webview.Call("open", url).AsBool();
    }

    public void SetRect(Rect2I rect) => _webview?.Call("set_rect", rect);
    public void SetVisible(bool visible) => _webview?.Call("set_visible", visible);

    /// <summary>UI → Host 的唯一入口；由 GameHost 连到 QyWebView.message_received。</summary>
    public void HandleFromUi(string json)
    {
        try
        {
            var node = JsonNode.Parse(json) as JsonObject;
            if (node == null) return;
            switch (node["t"]?.GetValue<string>())
            {
                case "ready":
                    Ready?.Invoke();
                    break;
                case "close":
                    CloseRequested?.Invoke();
                    break;
                case "cmd":
                    CommandReceived?.Invoke(new UiCommand
                    {
                        Id = node["id"]?.GetValue<string>() ?? string.Empty,
                        Args = node["args"] as JsonObject ?? new JsonObject(),
                    });
                    break;
            }
        }
        catch (JsonException e)
        {
            GD.PushWarning($"[ui] 非法消息：{e.Message}");
        }
    }

    /// <summary>推一帧快照。调用方负责节流（建议 100ms）。</summary>
    public void PushSnapshot(int hp, int maxHp, int sp, int gold, int floor,
                             JsonArray? party = null, string? toast = null)
    {
        if (_webview == null || !IsAvailable) return;

        var msg = new JsonObject
        {
            ["t"] = "snapshot",
            ["seq"] = ++_seq,
            ["hp"] = hp,
            ["maxHp"] = maxHp,
            ["sp"] = sp,
            ["gold"] = gold,
            ["floor"] = floor,
        };
        if (party != null) msg["party"] = party;
        if (!string.IsNullOrEmpty(toast)) msg["toast"] = toast;

        _webview.Call("post_json", msg.ToJsonString());
    }

    public void OpenScreen(string screen, JsonObject? payload = null)
    {
        if (_webview == null) return;
        var msg = new JsonObject { ["t"] = "open", ["screen"] = screen };
        if (payload != null) msg["payload"] = payload;
        _webview.Call("post_json", msg.ToJsonString());
    }

    public void CloseScreen(string screen)
    {
        if (_webview == null) return;
        var msg = new JsonObject { ["t"] = "close", ["screen"] = screen };
        _webview.Call("post_json", msg.ToJsonString());
    }
}
