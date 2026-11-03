# 技术架构：Godot + C# + C++(GDExtension) + WebView2

> 目标：把"高性能内核 / 游戏逻辑 / 表现层"三件事分给三种运行时，各自用最合适的语言，
> 并让每一层都能**单独降级**（C++ 挂了退回 GDScript，WebView2 缺失退回 Godot 原生 UI）。
> 本文是落地约定，不是构想：`native/`、`game_cs/`、`webui/` 里的骨架按本文实现。

---

## 0. 一句话结论

**C++ 只做"算得快"的事，C# 只做"改得勤"的事，WebView2 只做"画得美、更得频"的事。**
三者之间只有两条数据通路：**POD 缓冲（C++ ↔ C#）** 和 **JSON 消息（C# ↔ UI）**。
没有例外，也不允许"临时直连一下"。

---

## 1. 分层与调用边界

```
┌──────────────────────────────────────────────────────────────┐
│  UI 层  WebView2 (Chromium, 独立进程)                          │
│  HTML/CSS/JS · 只画界面 · 只发"意图" · 不持有游戏状态            │
└───────────────▲──────────────────────────┬───────────────────┘
        JSON 快照 │                          │ JSON 命令
                 │                          ▼
┌────────────────┴─────────────────────────────────────────────┐
│  逻辑层  C# (.NET, Godot .NET 版)                              │
│  游戏规则 / 状态机 / 配置 / 存档编排 / UI 桥 / 生命周期          │
│  用 Span<T> + fixed 直连内核；不逐个体调 Godot API              │
└───────────────▲──────────────────────────┬───────────────────┘
       C ABI 调用 │ (P/Invoke, 零 Variant)    │ GDExtension 类（给 GDScript/编辑器）
                 │                          ▼
┌────────────────┴─────────────────────────────────────────────┐
│  内核层  C++ (qy_native.dll)                                   │
│  空间哈希 / 群体分离 / 流程场 / 弹道宽相 / 哈希 / WebView2 宿主   │
│  不含引擎头、不含业务规则、无状态或显式状态                        │
└──────────────────────────────────────────────────────────────┘
```

### 1.1 各语言职责

| 层 | 语言 | 负责 | 明确不做 |
|---|---|---|---|
| 内核 | C++17 | 每帧 O(n·k) 的数值计算、空间索引、宽相碰撞、确定性哈希、WebView2 宿主（COM/Win32） | 不读配置、不判断"该不该打"、不碰场景树 |
| 逻辑 | C# | 战斗规则、AI 高层决策、任务/商店/背包、存档编排、输入、相机调度、UI 桥 | 不做逐个体循环、不写热路径的 `Call()` |
| 表现 | WebView2 (JS) | 菜单/背包/商店/结算/设置等**模态或整屏**界面 | 不做世界内 HUD、不计算伤害、不持有权威状态 |
| 现存脚本 | GDScript | 现有 `arpg/` 玩法与编辑器工具，逐步迁移 | 不新增热点逻辑 |

### 1.2 调用方向（只允许向下，不允许向上）

- ✅ C# → C++（P/Invoke 函数表）、C# → Godot API、CSS/JS → C#（JSON 消息）
- ✅ GDScript → C++（GDExtension 注册的类）
- ❌ C++ → C# / GDScript 直接调用（唯一例外：通过 `call_deferred` 发信号，且必须挂在节点上）
- ❌ JS → 文件系统 / 直接改游戏状态（只能发命令）

> 这条"单向依赖"是整套架构能长期维护的根本：内核不知道游戏存在，UI 不知道引擎存在。

---

## 2. 目录结构

```
E:/游戏制作/
├── project.godot                  # 现有 GDScript 项目（保持可运行）
├── arpg/  core/  data/  tests/    # 现有玩法与数据（逐步迁移，不推倒）
│
├── native/                        # ★ C++ 内核 + GDExtension
│   ├── CMakeLists.txt
│   ├── godot-cpp/                 # git submodule（分支必须 = 引擎主版本）
│   ├── qy_native.gdextension.template  # 插件描述模板（构建后生成 .gdextension）
│   ├── include/qy_native_api.h    # 唯一的 C ABI 契约（C# 也读它）
│   ├── src/core/                  # 纯 C++：不含任何引擎/系统头
│   │   ├── crowd_kernel.{h,cpp}   #   群体分离（已实现，替换 GDScript 的 1.2s/万体）
│   │   └── api.cpp                #   C ABI 出口（qy_get_api）
│   ├── src/gdextension/           # Godot 绑定薄壳（QyNative / QyWebView）
│   ├── src/webview2/              # WebView2 宿主（COM，QY_WITH_WEBVIEW2 开关）
│   └── bin/                       # 构建产物（.gitignore，不进库）
│
├── game_cs/                       # ★ C# 逻辑层（切 .NET 版引擎后成为主工程）
│   ├── QyGame.csproj              # Godot.NET.Sdk/4.7.2
│   └── src/
│       ├── Bridge/NativeApi.cs    #   P/Invoke + 函数指针表
│       ├── Bridge/WebUiBridge.cs  #   UI 消息协议
│       └── Core/GameHost.cs       #   编排入口节点
│
├── webui/                         # ★ WebView2 UI（纯前端，可独立迭代）
│   ├── index.html
│   └── src/{bridge.js,app.js,style.css}
│
├── tools/build_native.ps1         # 一键构建（CMake + 拷贝 DLL）
└── docs/                          # 本文所在
```

**为什么 `native/` 不放在 `arpg/` 下**：内核与具体玩法无关，未来 `srpg/` 或新项目也要用；
放顶层才不会出现"引用了 arpg 里的东西"的耦合。

---

## 3. C++ 层：双出口 + 版本化 ABI

### 3.1 同一个 DLL，两种被调用的方式

| 出口 | 符号 | 谁用 | 代价 |
|---|---|---|---|
| GDExtension | `qy_library_init` | GDScript / 编辑器 | 每次调用过一次 Variant 封送 |
| C ABI | `qy_get_api` / `qy_api_version` | C#（P/Invoke）、外部工具 | 零封送，Span 直通 |

两条路**共享同一份内核状态与算法**，所以行为不会分叉。

### 3.2 为什么用"函数指针表"而不是直接导出一堆函数

```c
typedef struct qy_api_v1 {
    uint32_t version;
    void (*crowd_separation)(const qy_vec2*, const qy_crowd_desc*, float*, float*, int32_t*);
    void (*crowd_separation_mt)(...);
    uint64_t (*hash64)(const void*, size_t, uint64_t);
    const char* (*build_info)(void);
} qy_api_v1;
QY_API const qy_api_v1* qy_get_api(uint32_t min_version);
```

- **只增不改**：加功能加字段（升到 v2），老二进制照样能跑；不会出现"头文件对了、DLL 是旧的"这种
  最难查的崩溃。
- **能做能力协商**：`qy_get_api(2)` 返回 NULL 就说明该降级，C# 侧启动日志直接打出来。
- **符号表干净**：只有一个导出符号需要维护，不会和引擎/第三方 DLL 抢名字。

### 3.3 GDExtension 的关键约定

`.gdextension`（源码里叫 `native/qy_native.gdextension.template`，**构建成功后由脚本生成正式的
`.gdextension`**。之所以不直接提交生效文件：DLL 还没编译时它会让每次启动都报"找不到动态库"，
把错误噪音带进日常开发）：

```ini
[configuration]
entry_symbol = "qy_library_init"
compatibility_minimum = "4.4"
reloadable = true

[libraries]
windows.debug.x86_64 = "res://native/bin/qy_native.windows.debug.x86_64.dll"
windows.release.x86_64 = "res://native/bin/qy_native.windows.release.x86_64.dll"
```

- **库名必须逐字匹配**：`<name>.<平台>.<debug|release>.<架构>.dll`。名字差一个字符的表现是
  "编辑器能跑、导出后报找不到库"。
- `entry_symbol` 与 `register_types.cpp` 里 `GDE_EXPORT` 的函数名一致。
- `reloadable = true` 让编辑器在重编译后热替换（不用重启编辑器，但**正在运行的场景状态会丢**）。
- 类注册只在 `MODULE_INITIALIZATION_LEVEL_SCENE` 做。

### 3.4 构建流程

```powershell
# 0) 一次性：拉 godot-cpp（分支必须与引擎一致：4.7.x → godot-4.7）
git submodule add -b godot-4.7 https://github.com/godotengine/godot-cpp native/godot-cpp
git submodule update --init --recursive

# 1) 配置（Visual Studio 2022 / x64）
cmake -S native -B native/build -G "Visual Studio 17 2022" -A x64 `
      -DGODOTCPP_TARGET=template_debug `
      -DWEBVIEW2_ROOT="<nuget>/Microsoft.Web.WebView2.1.0.x/build/native"

# 2) 编译（产物自动拷到 native/bin/）
cmake --build native/build --config Debug
#    或： tools\build_native.ps1 -Config debug -WebView2Root "<...>"
```

构建产物**不进 git**（`native/bin/*.dll`、`native/build/`），只提交源码与 `.gdextension`——
否则每次合并二进制都会冲突。

---

## 4. C# 层

- 工程用 `Godot.NET.Sdk/<与引擎完全一致的版本>`，`.csproj` 里 `AllowUnsafeBlocks=true`（函数指针表需要）。
- **必须使用 Godot 的 .NET 版引擎**（`Godot_v*_mono_*`）。标准版没有 .NET 运行时，
  放进去的 C# 代码不会被执行。
- `QyWebView` / `QyNative` 是 C++ 注册的类，不是 C# 类：C# 侧只能
  `ClassDB.Instantiate("QyNative")` 得到 `GodotObject`，再用 `Call(...)` 动态调。
  所以**C# 的热路径一律走 `NativeApi`（P/Invoke），不走 `Call`**。

### 4.1 DLL 加载路径（导出后最容易踩的坑）

```csharp
// 依次尝试：exe 同级（导出后） → res://native/bin（编辑器） → 环境变量
Path.Combine(AppContext.BaseDirectory, dll)
ProjectSettings.GlobalizePath("res://native/bin/" + dll)
Environment.GetEnvironmentVariable("QY_NATIVE_DLL")
```

编辑器里 `res://` 是真实文件；导出后 `.dll` 被放在可执行文件旁（PCK 内无法 `dlopen`）。
两条路径都要覆盖，否则会出现"编辑器好好的，导出就崩"。

---

## 5. 跨语言数据交互

### 5.1 四条通道，各有明确用途

| 通道 | 方向 | 典型用途 | 单次成本 | 规则 |
|---|---|---|---|---|
| P/Invoke + `Span<T>`/`fixed` | C# → C++ | 万体分离、宽相、流程场 | ~ns 级（只传指针） | 只传 POD 数组；调用方保证长度；内核不保存指针 |
| GDExtension 类方法 | GDScript → C++ | 编辑器工具、低频调用 | 一次 Variant 封送 | 单次元素数建议 ≤ 2k |
| JSON 消息 | C# ↔ WebView2 | UI 快照 / 命令 | 一次序列化 + 进程间拷贝 | 10Hz 节流、单向数据流 |
| 共享内存/共享纹理 | （进阶，未启用） | WebView2 合成到游戏画面 | 需 D3D 互操作 | 见 §6.3 |

### 5.2 零拷贝的具体写法

```cpp
// C++ 侧：只接受裸指针 + 显式长度，不碰 Godot 容器
void crowd_separation(const qy_vec2* pos, const qy_crowd_desc& d, float* dx, float* dy, int32_t* hits);
```

```csharp
// C# 侧：一次 fixed，把 Span 钉住后直接交给内核
fixed (QyVec2* p = pos) fixed (float* px = dx) fixed (float* py = dy) {
    api->CrowdSeparation(p, &desc, px, py, null);
}
```

**禁止**：`Godot.Collections.Array` / `Dictionary` 传大数组；每帧 `new` 临时数组；
在循环里逐个体 `Call("method")`。这三件事任何一件都会把收益吃干净。

### 5.3 线程规则（违反必崩，且崩得随机）

1. 场景树/节点/资源**只允许主线程**访问。
2. 内核可以开线程，但线程里只能碰 POD 和自己的缓冲区。
3. 内核要"回调游戏"时，只能：主线程轮询结果（双缓冲）或 `call_deferred` 发信号。
4. 每帧的跨界调用次数控制在个位数；一次传一批，而不是一批传很多次。

### 5.4 生命周期

- 传进内核的指针**只在本调用内有效**；内核不许存。
- 内核持有游戏对象时只能存 `ObjectID`（不是指针），用前判 `is_instance_valid`。
- DLL 卸载前必须清空内核里的注册表（`QyWebView` 在析构里 `Shutdown()`）。

---

## 6. WebView2 作为 UI 层

### 6.1 为什么值得引入

| 维度 | 收益 | 代价 |
|---|---|---|
| 迭代速度 | 改 CSS/HTML 立即生效，不用重编 C++/C#；可 `Vite dev server` 热更 | 多一套前端工具链 |
| 表现力 | CSS 动画/滤镜/图表/富文本排版，做商店、图鉴、设置页比手搓 Control 快一个量级 | 与游戏内 HUD 风格要人工对齐 |
| 维护 | UI 与引擎解耦，UI 可以独立打包/热更新；改版不动核心包 | 需要桥接协议与版本管理 |
| 分工 | 前端/美术可以直接改界面，不必懂 Godot | 需要约定"UI 不发状态" |
| 运行时 | Chromium 自带排版/输入法/无障碍/多语言 | ≈80~150MB 内存、首次加载 150~400ms |

**结论：模态/整屏界面（商店、背包、图鉴、设置、结算）用它；世界内 HUD（血条、小地图、伤害数字）继续用 Godot。**

### 6.2 嵌套机制：子窗口叠加（当前方案）

```
Godot 主窗口 HWND
├── 游戏画面（Godot 的 swapchain，画在主窗口客户区）
└── WebView2 子 HWND（由 ICoreWebView2Controller 创建，盖在最上层）
```

- 用 `DisplayServer.window_get_native_handle(WINDOW_HANDLE, 0)` 拿窗口句柄，交给 `CreateCoreWebView2EnvironmentWithOptions` → `CreateCoreWebView2Controller(hwnd, ...)`。
- 每帧（或窗口尺寸变化时）`controller->put_Bounds(RECT)` 同步到目标矩形；`put_IsVisible` 控制显隐。
- **它永远盖在游戏上面**，无法被精灵遮挡——这正是"只能做模态 UI"的技术原因。
- DPI：`ICoreWebView2Controller3::put_RasterizationScale` + `put_BoundsMode(USE_RASTERIZATION_SCALE)`；
  不做的话 125%/150% 缩放下会糊/错位。

### 6.3 进阶：真正合成进画面（成本高，默认不做）

想让它"像游戏里的一层"（可被 3D 遮挡、可做 3D 曲面 UI），需要：

1. `ICoreWebView2Environment3::CreateCoreWebView2CompositionController`；
2. 用 DirectComposition 把 WebView 视觉树挂到自己的 visual 上；
3. 把该 visual 渲染到 D3D11 共享纹理（`IDXGIResource1::CreateSharedHandle`）；
4. D3D11→D3D12 开放共享（fence 同步），包成 Godot 的 `Texture2DRD`。

工程量大、平台相关、调试困难，**除非要做"游戏内嵌网页/网页壁纸"这类玩法，否则不要碰**。

### 6.4 通信

```
Host(C#) --post_json--> QyWebView.post_json --> ICoreWebView2::PostWebMessageAsJson
UI(JS)   --JSON.stringify--> chrome.webview.postMessage(str)
         --> add_WebMessageReceived --> TryGetWebMessageAsString
         --> signal message_received --> C# WebUiBridge.HandleFromUi
```

- **必须发字符串**（`JSON.stringify`）：宿主用的是 `TryGetWebMessageAsString`。
  发对象会走 `get_WebMessageAsJson` 分支，宿主拿不到——这是最常见的"消息发出去没反应"。
- 协议见 `webui/src/bridge.js` 与 `game_cs/src/Bridge/WebUiBridge.cs`（两边必须同步改）。
- 单向数据流：Host 推 `snapshot`（10Hz、只在变化时推），UI 只回 `cmd`。

### 6.5 依赖与配置清单

| 项 | 说明 |
|---|---|
| WebView2 Runtime | Win11 自带；Win10 需装 Evergreen Runtime。用 `GetAvailableCoreWebView2BrowserVersionString` 探测，缺失就走 Godot 原生 UI 降级 |
| Native SDK | NuGet `Microsoft.Web.WebView2` 的 `build/native`（头文件 + `WebView2LoaderStatic.lib`） |
| 用户数据目录 | 必须可写：`OS.get_user_data_dir() + "/webview2"`。**不能**放 `res://`（打包后只读） |
| 开发期 URL | `http://localhost:5173/`（Vite），改样式即时生效 |
| 发布期 URL | `file:///<绝对路径>/webui/index.html`，或 `SetVirtualHostNameToFolderMapping("game.ui", dir, DENY_CORS)` 走虚拟域名（更安全） |
| 安全 | 发布版关掉 DevTools/右键菜单；不启用 `--disable-web-security`；UI 不直接读文件 |

### 6.6 已知坑

1. **z-order**：子窗口永远在最上层 → 面板之外的区域要么透明（`background: transparent` + 只给面板设底色），
   要么整块盖住（深色遮罩）。
2. **焦点/输入法**：焦点进 WebView 后 Godot 收不到键鼠；关闭面板要 `SetVisible(false)` 并把焦点还给游戏。
   中文输入靠 Chromium 自己处理，别在 Godot 侧再开 IME。
3. **内存/进程**：Chromium 是多进程，别在每局开头 `close()` 重新建；开机预热一次、之后只切显隐。
4. **首帧白闪**：初始化完成前不要 `SetVisible(true)`，等 `NavigationCompleted` 再显示。
5. **平台独占**：macOS 用 WKWebView、Linux 用 WebKitGTK，接口要抽象成 `IWebUiHost`；
   移动端没有等价物，直接走原生 UI。

---

## 7. 现有模块的迁移映射

| 现有文件 | 去处 | 理由 | 优先级 |
|---|---|---|---|
| `arpg/mob_system.gd` 的分离/索敌 | **C++ `crowd_kernel`** | 实测 1 万体 1.2s/次，纯数值 | P1（已写） |
| `arpg/flow_field.gd` | C++ `flow_field` | 纯网格 BFS，无引擎依赖 | P2 |
| `arpg/proj_system.gd` 步进/命中 | C++ `projectile_kernel` | 万弹时是热点 | P2 |
| `arpg/ai_controller.gd` | C# | 规则复杂、天天改，C++ 反而慢 | P2 |
| `arpg/hud.gd` 菜单/商店 | WebView2 | UI 迭代最频繁 | P1 |
| `arpg/dungeon_gen.gd` | **留在 GDScript** | 一次性生成，迁 C++ 收益低 | 不迁 |
| `arpg/main.gd` | C#（分阶段） | 流程编排，最终收口到 GameHost | P3 |

> 迁移原则：**只迁"每帧 × 大规模"的代码**。一次性/BOSS 逻辑迁到 C++ 只会增加构建与调试成本。

---

## 8. 关键约束（评审时逐条对照）

1. **C ABI 只增不改**；破坏性变更升版本号，老接口继续可用。
2. **内核不含引擎头**（`src/core` 不允许 `#include <godot_cpp/...>`），保证可单测、可复用。
3. 跨界调用**每帧 ≤ 10 次**，单次至少批量数百体；禁止逐个体回调。
4. 热路径禁止 `Variant` / `Dictionary` / `GodotObject` / 每帧 `new`。
5. C++ 线程**不碰场景树**；跨线程只传 POD，或走 deferred。
6. 所有跨界数据 **POD + 显式长度**；不要靠"约定好的固定大小"。
7. UI **单向数据流**：只发命令、只收快照；权威状态永在 C#/C++。
8. WebView2 只做**模态/整屏**，不做世界内 HUD。
9. **每层都要有降级路径**：native 缺失 → GDScript；WebView2 缺失 → Godot UI；
   C# 缺失（标准版引擎）→ 现有 GDScript 玩法照常跑。
10. **版本必须对齐**：godot-cpp 分支 = 引擎主版本；`Godot.NET.Sdk` = 引擎版本；WebView2 SDK 与运行时匹配。
11. 构建产物不入库；`.gdextension` 与源码入库存。
12. 性能门禁：万体分离 < 2ms/帧；UI 桥每帧分配 = 0；C# 侧 `GC.GetTotalAllocatedBytes` 稳态不涨。

---

## 9. 落地步骤

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0（本提交） | 目录、C ABI、crowd 内核、GDExtension 壳、C# 桥、Web UI、构建脚本 | `src/core` 通过编译；JS 通过语法检查；编辑器能加载 `QyNative` |
| M1 | 装 MSVC + CMake，编译出 DLL；GDScript 里跑 `QyNative.crowd_separation` | 与 GDScript 版结果误差 < 1e-3；1 万体耗时 < 2ms |
| M2 | 换 .NET 版引擎，`GameHost` 接管 mob 分离（保留开关做 A/B） | 万敌基准帧率提升且行为一致 |
| M3 | WebView2：店铺 + 背包两个面板 | 首帧 < 400ms；开关面板不掉帧；无输入法冲突 |
| M4 | 迁 flow_field / proj_system；GDScript 侧只留内容与工具 | 三层测试全绿 |

---

## 10. 本机现状（务必先看）

| 项 | 状态 | 影响 |
|---|---|---|
| 引擎 | `Godot_v4.7.2-stable_win64.exe`，**标准版**（无 .NET） | C# 代码现在不会被加载；需换 `mono` 版 |
| CMake | ❌ 未安装 | 无法配置/编译 GDExtension |
| MSVC | ❌ 未安装（只有 VS Installer） | Windows 上 GDExtension 官方只支持 MSVC |
| MinGW g++ 14.2 | ✅ | 只能编译 `src/core`（纯 C++），不能编 GDExtension |
| .NET SDK | ✅ 7.0.401 / 10.0.303，**缺 net8.0 targeting pack** | `Godot.NET.Sdk` 4.7 需要 net8.0 |
| WebView2 SDK | ❌ 未安装 | 需要 NuGet 还原 |
| Node.js | ✅ v22.22.2 | 前端开发/校验可用 |

**本次已验证**：`g++ -std=c++17 -Wall -Wextra -fsyntax-only` 通过（`crowd_kernel.cpp` + `api.cpp`）；
`node --check` 通过（`bridge.js` / `app.js`）；`QyGame.csproj` XML 合法。
**未验证**：GDExtension / WebView2 / C# 三者的实际编译与运行（缺上述工具链）。
