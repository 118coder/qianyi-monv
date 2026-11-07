# 千亿魔女 · 交接文档（HANDOFF）

> 最后更新：与本文档同一提交。**新会话/新开发者从这里开始读完即可接手。**
> **下一轮先看 `docs/下一轮交接.md`** —— 那里是「未验证清单 + 待办优先级 + 硬约束」，本文是历史与架构。
> 项目根：`E:\游戏制作` · Godot 4.7.2 · 单机商业游戏方向：露塞提娅式「店铺经营 + 地牢 ARPG」

---

## 1. 一页现状

- **两条产品线一个仓库**：`arpg/`（主产品：地牢 ARPG，露塞提娅式）+ `srpg/`+`editor/`（战棋原型与地图编辑器，已可复用其地图管线）。战棋已完整可玩、测试全绿；**主产品是 ARPG**。
- **已完成并实机验证（早期基线）**：地牢 ARPG 战斗闭环（3 职业/6 敌+Boss/随机地牢5层/宝箱陷阱/背包/升级/商店/任务/装备/存档v2/角色菜单）、AI 队友+主控切换+APC 框架、敌我 AI 寻路/索敌（§9）、万敌压测（10000 敌 95~135FPS）、手柄+震动、热重载（balance.json 保存即生效）、节点式事件编辑器+AI状态机可视化+系统数值面板、**事件引擎已接线**（§2）。
- **已完成但只有静态验证（2026-11-03 五轮，全部未经实机）**：多目标取景镜头 + 队友 AI 重做（§10）、镜头双层的调度器（§11）、BSP 地牢 v2（§12）、金币/宝石掉落（§13）、小地图 + 战争迷雾（§14）、创作工坊双宿主（§17）、pixelfx 12 特效（§18）、图块场景编辑器（§19）、网格与图块解耦 + 大角色 footprint（§20）。
  ⚠️ 这批只跑过 `--check-only` 与 `--headless --import`，**三层测试自 §2 之后没再重跑过**。逐项验证办法见 `docs/下一轮交接.md` §4。
- **测试基线**：`smoke_arpg` 现 116 处 `_check`（旧记录里的 119/102 均已过期）、战旗 29 项、自动驾驶整局 PASS、万敌基准 ≥50FPS。这些数字是 §2 时代的，**下一轮必须重跑确认**。
- 编辑器本体 exe 不在仓库（见 §7）；启动用根目录的 4 个 .bat，其中 `打开创作器.bat` 是可视化工作台（不依赖 Godot 编辑器）。

---

## 2. ✅ P0 事件引擎接线（2026-11-03 已恢复）

**接线现状**（与本文档旧版恢复方案有三处有意差异，原因见各条）：

- `arpg/main.gd`：`events`/`map_events`/`ui`/`events_silent` 成员 + `over` 只读属性（事件引擎读 `main.over` 判局终）；`_ready` 末尾实例化 `SrpgEventSystem`；`start_run` 前 `_load_map_events()`（读 `SrpgMapLoader.load_file` 的 events 段）
- **回合 → 楼层映射**：ARPG 没有回合，`build_floor()` 末尾的 `_intro()` 以 `floor_no` 当事件引擎的 turn（横幅"地下 N 层"→ `events.on_phase_start("player", floor_no)`）。地图事件 1（turn 1）= 开局对话；事件 2（turn 3）= 地下 3 层增援
- `arpg/hud.gd`：新增 `show_banner`（淡入停留淡出）/ `show_dialogue`（逐行、空格/点击推进、**期间暂停世界**、头像查 `ArpgBalance.CHARS`，战棋讲者 id 经 `SPEAKER_ALIAS`（sword→fencer）映射）/ `update_turn`（save_system 读档回调）
- `arpg/player.gd`：补 `faction := "player"` 与 `cell` 计算属性（事件引擎 zone 触发读取）
- `spawn_units` 落点：地图事件格子对不上随机地牢地板时**就近改刷**在玩家所在房间（旧方案静默跳过会导致增援凭空消失）
- **`events_silent` 闸门**：headless / `--autoplay` 下不触发事件对话（无真实键鼠输入，模态对话会挂死 CI）；`tests/visual_ui.gd` 里显式置真
- 触发钩子：`_process` 玩家跨格 → `on_unit_moved(player)`（zone 事件，引擎内矩形过滤）；旧方案里 `_settle` 开头调 `events.on_reach_floor` 是**不存在的 API**（会编译失败），楼层事件由 `_intro` 的 `on_phase_start` 覆盖，无需恢复
- 回归测试：`tests/smoke_arpg.gd` 第 12 节覆盖真实触发链路（on_phase_start/zone → give_gold/spawn 落点）

**同批顺带修复的预存缺陷**（此前被"测试没跑全"掩盖）：
1. `editor/advanced_tabs.gd` 解析错误（`_node_at`/`_btn` 旧名 + `:=` 推断坑）→ 编辑器整个类加载失败，连带 ARPG 冒烟第 11 节崩溃
2. `editor/editor.gd` 解析错误（`EventCanvas`→`EditorEventCanvas`、`_rebuild_event_form`→`EditorAdvancedTabs.build_event_props`）→ 战旗冒烟崩溃挂起
3. `_ready` 里压测自动开局早于 rpg/save_sys/audio 基座创建 → `--stress/--bench` 直接崩溃（自动开局移到 `_ready` 末尾）
4. `proj_system.gd:95` `world.party` 拼写错误（应为 `world.main.party`）→ 敌方弹幕在场时每帧报错
5. `hud.game` 从未赋值 → 独立商店页 Nil 崩溃（现 `_ready` 里 `hud.game = self`）

### 验证（全绿基线：ARPG 102 / 战旗 29 / 自动驾驶 PASS / 万敌 119FPS）
- 冒烟第 11 节（命令执行）+ 第 12 节（接线链路）均过
- 手动：F5 开局约 1 秒后弹横幅 + 开场对话（witch 有头像，"sword" 经映射也是剑士头像）；对话期间世界暂停；地下 3 层触发增援事件

---

## 3. 架构地图（文件 → 职责）

```
arpg/                      主产品（地牢 ARPG）
├── main.gd                主控：输入/流程/楼层/商店钩子/压测/热重载监视 ⚠️最大文件
├── camera_rig.gd          取景算法层（pan-first + zoom-to-fit + 迟滞 + 临界阻尼）
├── camera_director.gd     镜头调度层（镜头栈 / 硬超时 / 焦点兜底 / 震屏前视）
├── player.gd              玩家：移动加速度/普攻/技能v2(use_skill)/装备派生(eff_atk/eff_def)
├── friend_unit.gd         AI 队友+APC 基类（软分离/跟随/战斗/贴墙切向/卡住恢复）
├── mob_system.gd          数据导向敌群：SoA+空间哈希+多线程+LOD+批次渲染（万敌 70FPS）
├── proj_system.gd         投射物数据系统（箭/法弹/弹幕，哈希命中）
├── pickup_system.gd       物品掉落数据系统（稳定 ID，供仲裁）
├── drop_system.gd         金币/宝石爆量掉落（散开→待吸→吸附→结算）
├── minimap.gd             小地图（灰阶迷宫轮廓 + 逐格战争迷雾）
├── world.gd               世界门面：地块渲染/墙碰撞/特效池(上限64)/楼梯传送门
├── dungeon_gen.gd         随机地牢 v2（BSP 分区 + 图连通 + A* 走廊 / Boss层 / 斗兽场）
├── data.gd                地形常量 + 旧数据表（已迁 balance，仅留常量）
├── balance.gd             数据中枢：balance.json 装载/深合并/校验/保存/热重载
├── hud.gd                 全部 UI（HUD/选人/菜单五页签/商店/结算/暂停/调试面板）⚠️第二大文件
├── party_manager.gd       队伍：容量N/编队/共享A*/稳定uid/序列化
├── possession_manager.gd  主控切换（冷却/限制/清输入缓冲）
├── pickup_arbiter.gd      拾取仲裁（玩家优先/防重复）
├── ai_controller.gd       AI 大脑（三指令→行为；队友与被切玩家共用）
├── command_queue.gd       指令队列
├── autopilot.gd           全自动测试驾驶（--autoplay）
├── chest.gd               宝箱（陷阱箱）
├── pxfx.gd                pixelfx 序列帧特效（读 fx_atlas.json，Sprite2D + hframes）
├── scene_layer.gd         Node2D 容器脚本（_validate_property 隐藏无意义内置属性）
├── ui_layer.gd            CanvasLayer 容器脚本（同上）
├── editor_preview.gd      @tool 编辑器预览层（生成地牢并 _draw，运行时自毁）
└── main.tscn              唯一场景（预置「世界/队伍/镜头/界面」容器）
creator/                   可视化创作工坊（RPG Maker 式，独立于 Godot 编辑器）
├── creator.gd             独立版外壳（窗口 + 起进程试玩）
├── creator.tscn           独立版场景
└── core/                  两宿主共享内核
    ├── ui_kit.gd          控件工厂 / 主题 / 字段名中文化 / 等宽数字
    ├── data_store.gd      原子写 + 3 份备份 + 写前校验 + 写完回读
    ├── workspace.gd       六模块外壳（总览/数值/数据库/事件/关卡/场景）+ 脏标记
    ├── event_editor.gd    事件编辑（触发器 + 命令链 + 分支，字段对齐 event_system）
    ├── dungeon_view.gd    程序生成地牢预览
    ├── tile_scene.gd      多图层图块数据 + JSON（tile_size / grid_size 分离）
    ├── tile_canvas.gd     只画可见格的画布（缩放/平移/擦除/吸管）
    └── tile_editor.gd     调色板 + 工具条 + 图层 + 撤销 + 图块集导入
addons/
├── qy_creator/            把创作工坊注册为编辑器主屏页；可隐藏 3D/资产库
└── arpg_zh_editor/        检查器术语中文化（注入 godot.properties 域）
tools/
├── gh_pr.py               推分支 → 建 PR → 合并（复用 GitHub Desktop 凭据）
├── build_pixelfx_fx.py    pixelfx 序列帧缩放 + 合并 atlas
└── build_native.ps1       多语言骨架构建（缺工具链，未验证）
native/ game_cs/ webui/    多语言骨架（C++ GDExtension / C# / WebView2，见 §15）
vendor/pixelfx/            第三方特效库（MIT，266 个 JS 特效，含 .gdignore）
core/                      与玩法无关的基座
├── events/event_system.gd 事件运行时 v2（嵌套IF/camera/wait/fx/music/give/win/lose）
├── settings/settings.gd   设置（user://settings.cfg，音量走总线）
├── audio/audio_manager.gd 总线(Master/Music/SFX)+BGM交叉淡入+音效池
├── save/save_system.gd    存档 v2（3 槽位 + 元信息）
└── l10n/strings.gd        字符串表（L10n.text(key, fallback)）
editor/                    地图/事件/AI/数值 编辑器（节点式事件图）
srpg/                      战棋原型（完整可玩，与编辑器共用 map JSON 管线）
docs/                      系统设计 + 蓝图 + 各子系统设计 + 下一轮交接
tests/                     smoke(战旗29/ARPG87) + 自动驾驶 + 渲染验证脚本 + gen_balance
assets/                    RPG Maker 素材（tiles/chars/fx/se/bgm）⚠️许可见 §7
data/                      balance.json（37 段全部数值）+ maps/map001.json（地图+事件）
                           scenes/（场景编辑器输出，行优先 int 数组，-1 为空）
assets/fx/pxfx/            pixelfx 序列帧 + fx_atlas.json（12 个特效）
```

---

## 4. 系统速查（跨系统调用关系）

| 要做什么 | 调用 |
|---|---|
| 改数值/加敌人/加技能 | 改 `data/balance.json`（保存即热重载）或编辑器「系统数值」页 |
| 改地图/事件 | 编辑器「事件」节点图 或直接改 `data/maps/map001.json`（F3 热载） |
| 事件新命令 | `core/events/event_system.gd` 的 `_run_commands` 加 match 分支 + 编辑器调色盘加按钮 |
| 玩家属性加成 | `player.eff_atk/eff_def`（读 `rpg.equip_bonus`） |
| 掉落→背包→任务 | `pickup_system` → `main.try_pickup*` → `rpg.inventory.add` + `quests.on_pickup` |
| 金币 | `rpg.gold`（怪物掉落在 on_mob_dead；商店买卖；事件 give_gold） |
| 胜负 | 凯旋=Boss死→传送门→`_settle(true)`；团灭→`on_player_dead`→`_settle(false)`；事件 win/lose→`_game_over`（✅已接线 §2） |
| 存档 | `save_sys.save_game(slot)/load_game(slot)/slot_meta(slot)` |
| 设置 | `settings.set_value(key, v)`（音量/震屏/震动即时生效） |
| BGM | `audio.play_music("title/dungeon/town/boss")` |

**平衡开关位置**（都在 balance.json）：陷阱率 45%、精英率 12%、卖价 60%、经验曲线、仇恨半径 185、传送召回 2.5s、队伍容量 8、切换冷却 1.5s。

---

## 5. 工作流

- **运行**：`运行游戏.bat`（或 F5）；**Godot 编辑器**：`打开编辑器.bat`（= exe 加 `-e`）
- **创作器**：`打开创作器.bat` —— RPG Maker 式工作台，改数值/数据库/事件/关卡参数/手搭场景，不依赖 Godot 编辑器
  （Godot 编辑器里也有同名主屏页，两套宿主共用 `creator/core/`）
- **测试**（全绿基线：ARPG 102 / 战旗 29 / 自动驾驶 PASS / 万敌基准 ≥50FPS）：
  ```
  "D:/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe" --headless --path "E:/游戏制作" -s res://tests/smoke_arpg.gd
  ... -s res://tests/smoke.gd
  ... --headless --path "E:/游戏制作" -- --autoplay            # 机器人打通整局
  ... --path "E:/游戏制作" -- --stress=10000 --bench=15         # 万敌基准(≥50FPS 退出码0)
  ```
- **渲染验证 UI**：`--write-movie "<目录>\\x.png" --fixed-fps 10 --quit-after N -s res://tests/visual_ui.gd`（注意：movie 模式 HUD 的 FPS 数字是磁盘 IO 假象）
- **热重载**：改 balance.json 保存即生效；地图改完按 F3；脚本按 F4 重开（或编辑器 F5 调试热替换）
- **提交**：`python tools/gh_pr.py pr --title "..." --body "..." --merge`（推分支 → 建 PR → 合并，一条命令）；
  git 通道不通时 `python tools/gh_pr.py put --path ... --message ...` 走 Contents API。
  凭据复用 GitHub Desktop（`git credential fill`），不落盘不回显。详见 `docs/提交与发布流程.md`

## 6. 踩坑清单（新会话必读）

1. **GDScript 撞名静默坑（已踩 5 次）**：成员/静态函数名撞 Object 内置（`reload/get/tr/alive`）→ 编译器只报"无法解析外部成员"甚至完全不报。命名前先想 `Object/Node` 内置；报错排查先 grep 类内是否重名。
2. **`:=` 推断坑**：无类型字典/数组元素参与表达式时 `var x := ...` 会解析失败。凡来自 `Dictionary`/`Array` 的值一律显式 `var x: Type =`。
3. **bash heredoc 长度限制**：>12KB 的内联脚本会被截断。大补丁一律用 Write 工具写 .py 再执行。
4. **PowerShell 内联中文**：UTF-8 无 BOM 会被当 GBK。脚本文件先加 BOM（`sed -i '1s/^/\\xef\\xbb\\xbf/'`）或用 python。
5. **事件命令的调用者**：`SrpgEventSystem` 是战旗+ARPG 共用；新增命令若引用 ARPG 专属成员（main.rpg 等），战旗事件不要使用该命令即可（动态分发，编译无碍）。
6. **RPG Maker 素材许可**：assets/ 全部来自用户已购的 RM 素材与示例工程；**仓库保持私有**，公开/商用前需替换。
7. **movie 模式**：HUD 的 FPS 是写盘 IO 假象；真实帧率用 `--bench` 模式测。
8. **按节拍调用的函数别拿 `delta` 当计时器**：`ai.think()` 每 0.15s 才跑一次，传进来的是某一帧的
   帧时长（≈16ms）。用它累加计时会慢约 9 倍（旧卡住判定就是这么废掉的）。要计时就用墙钟
   （`_tick_delta()` 取「距上次 think 的真实时长」）。
9. **新脚本的 `class_name` 不在 `global_script_class_cache.cfg` 里**时，其它脚本直接引用类型会解析失败。
   跨脚本引用新类优先用 `const X := preload("res://...")`（`main.gd` 引 `camera_rig.gd` 即此做法）。
10. **`.tscn` 的裸标识符是 ASCII-only**（`VariantParser` 用 `is_ascii_alphabet_char`）。中文 `@export` 变量名
    一旦随场景保存就再也读不回（场景直接坏掉）。中文只能出现在**带引号的字符串**里（节点名 `"世界"` 可以），
    变量必须是 ASCII，中文标签靠翻译域补。**踩过一次，写坏了 `main.gd`。**
11. **检查器的属性名走独立翻译域**：`TranslationServer.add_translation()` 只写主域，
    属性名在 `godot.properties`、编辑器 UI 在 `godot.editor`，必须 `get_or_add_domain()` 显式注入。
12. **Container 会每帧重写子节点的 position**。入场动效只能动 `opacity`，动 `position` 会被立刻打回原位。
13. **内部类不能引用外层脚本的 `class_name`**（加载阶段解析不到，报 Identifier not found）。
    内部类需要外层数据时，把数据从外面传进去。
14. **`EditorPlugin` 没有 `has_tool_menu_item()`**；`remove_tool_menu_item` 重复调用会报错，用标志位记录。
    隐藏编辑器页签要按**文案**匹配而非下标，且必须**等两帧**（按钮文案是翻译后写入的，太早匹配不到）。
15. **`--no-actor` 是 pixelfx 渲染的必加参数**，否则演示小人会被画进每一帧。
16. **`vendor/pixelfx/.gdignore` 不能删**，否则编辑器会扫描几千个 JS 卡住。
17. **`var x := scene.get_cell(...)` 这种无类型返回值推断会失败**，要显式 `var x: int =`。
    凡是来自 Dictionary / 无类型对象的值，一律显式标注类型。

## 7. 路线图（详见 docs/商业架构蓝图.md）

- **R1（进行中）**：~~P0 事件接线恢复~~（✅ §2）→ ~~创作工具链~~（✅ §17~§19）→
  **⚠️ 回归验证（下一轮第一优先，见 `docs/下一轮交接.md` §4）** → main.gd/hud.gd 拆分 → 仓库分离决策（srpg/ 去留）
- **R2 玩法期**：经营主循环（天/租金/还债 + 店铺营业 MVP）→ 伤害管线（暴击/元素/状态效果）→ 内容校验扩展
- **R3 内容期**：任务链/叙事/多地牢主题/成就/本地化执行
- **R4 发布期**：Steam/无障碍/Demo
- **待拍板**：手搭场景以什么形态进游戏（整层替换 / 预制房间 / 独立模式）｜队友背包独立 or 共享｜死亡惩罚强度｜srpg 去留｜付费形态

## 8. 关键决策记录

- 队伍/AI/事件/数值全部**配置化**（balance.json + party 段），无硬编码 8
- 敌群走 SoA 数据层（非节点），上限 12000；队友/AI 走节点（少量富行为）
- UI 全代码构建（可无头测试），token 层 + 控件工厂在 hud.gd 顶部
- 测试即回归：改任何系统后跑三层测试（smoke/autoplay/bench）是硬性流程

## 9. 敌我 AI 寻路/索敌系统（2026-11-03）

### 解决什么问题
- **敌人**：原来纯直线追击 + 撞墙只挡轴不清速度 → 墙后怪贴墙抖动、同目标怪叠成"怪柱"、窄门互堵、隔墙也能索敌
- **队友**：分离只算友方不算敌人；卡墙传送落点 `(34,0)` 不校验可走 → 把队友传进墙里反复卡死；A* 路径不拉直 → 切角蹭墙频繁触发瞬移；编队点落在墙内

### 方案（成熟做法：SupCom2 式「共享粗路径 + 局部转向」）
| 层 | 做法 | 文件 |
|---|---|---|
| 共享寻路 | **流程场**（BFS 集成场 + 8 向方向场，斜向防穿角），锚点=主控单位，4Hz 重建 | `arpg/flow_field.gd`（新） |
| 敌人追击 | 有直线视野走直线（天然捷径）；隔墙走流程场绕行；无场则回退直线 | `mob_system.gd` `_chase_dir` |
| 局部避让 | **分离力**（平方距离弹簧，免 sqrt），上限 6 邻居，进 `_try_move` 步长 | `mob_system.gd` `_accumulate_separation` |
| 防卡死 | 想走但位移 <25% 累计 0.45s → 切向脱困 0.5s | `mob_system.gd` `_try_move` |
| 索敌智能 | **LOS 仇恨**（网格 DDA，隔墙不索敌，按「怪格+目标格」缓存）；**包抄弧**（每怪认领 8 方位槽，怪群成弧围攻） | `mob_system.gd` |
| 远程走位 | keep 距离带内横向风筝；后退被挡混入切向分量，贴墙不抖 | `_ranged_move` |
| 队友 | 分离含最近敌人；A* 路径**拉直**（string pulling）；编队点 `is_floor` 校验；传送落点吸附最近可走格 + 按队伍序号环形错开 | `party_manager.gd` / `friend_unit.gd` / `ai_controller.gd` |

### 性能护栏（关键，别删）
- **品质模式开关**：`_sep_quality = count < 500`。正常战斗（真实地牢 5~30 怪）开启分离/LOS/包抄；**万敌压测自动降级为原行为**——这是 10k 基准能保持 95~135FPS 的原因（不加此闸门会掉到 1~3FPS，实测分离全量 = 1.2s/次）
- 流程场：`dungeon.w*dungeon.h > 6000` 直接跳过（斗兽场 20400 格 BFS 要 70ms，且开阔地无墙可绕）
- 所有 AI 参数在 `balance.json` 的 `ai` 段，保存即热重载：`separation.{radius_pad,strength,max_neighbors}` / `stuck.{after,nudge_time,nudge_speed}` / `arc_blend` / `strafe_ratio` / `flow_recalc_interval`

### 质量指标（可观测）
`mob_system.stuck_ratio / stack_ratio`：压测模式每 5s 打印 `[AI] 卡住率 x% · 堆叠率 y%`；HUD 调试面板（F1）多一行；autopilot 每 5s 打印。
实测（密集战斗 23~33 怪）：**卡住率 0% · 堆叠率 0~7%**。

### 顺带修的预存 bug
`_build_hash()` 只清 `_used_keys` 里的 bucket，但字典里残留的旧 key 永远不清 → 分离查询到幽灵邻居（修：遍历 `_hash` 全量清空）

---

## 10. 多目标取景镜头 + 队友 AI 行为重做（2026-11-03）

### 10.1 镜头：为什么"队友在屏幕边缘就丢"

旧实现只有一句话：`camera.position = possession.current_unit.position`（`main._process`）。
单目标跟随在单人游戏够用，但只要画面里还有"应该被看见的第二个人"就必然出问题：

- 视口 1152×648、zoom 1.7 → 可见世界约 678×381，半屏只有 339×190。
  队友站在玩家侧后 200~400px 就压在画面边缘；玩家一动，镜头只跟玩家，队友直接被切出画面。
- 内置 `position_smoothing_enabled` 与每帧硬写 position 混用 → 平滑被反复重置，快速转向时有抽搐；
  主控切换时是"整个镜头瞬移到另一个人身上"（靠 8.0 的平滑硬拖）。
- `build_floor()` 每次都 `new Camera2D()` 且从不释放 → 每下一层多一个相机节点，全是 current 候选。
- 前视偏移固定读 `player.facing`，切到队友主控后前视方向还是玩家（剑士）的。

### 10.2 镜头方案（`arpg/camera_rig.gd`，商业做法：pan-first + zoom-to-fit）

| 步骤 | 做法 | 解决的观感问题 |
|---|---|---|
| 跟踪集合 | 焦点（主控）+ 存活队友；进入半径 `半屏对角线 × track_ratio(1.3)`、退出 `× track_release(1.3)` 双阈值迟滞；远处隔墙（不同房间）的队友不参与 | 边缘反复进出不再让镜头抽搐 |
| 先平移 | 取景中心向包围盒中心拉 `pan_weight(0.42)`，且**硬约束**焦点必须在 `中心 ± safe_frac(0.34)×半屏` 内 | 保证"玩家永远在合理视野内" |
| 再缩放 | 平移压不住包围盒才缩放：`zoom = 视口 / 需要尺寸 × fit_bias`，夹 `[min_zoom 1.12, base_zoom 1.7]`，两轮交替求解 | 队友走远时自动放宽视野而不是丢人 |
| 稳定性 | 缩放死区 0.06 + 反向冷却 0.35s + 拉远快(3.0)/拉近慢(1.5) 非对称速率 | 不会来回拉风箱 |
| 平滑 | 临界阻尼弹簧（SmoothDamp，帧率无关）+ 追焦限速 2400px/s + 4px 死区 + 像素对齐 | 急停不甩头、慢走不飘 |
| 限位一致 | 自己按 limit 再夹一次 `_center`（与 Camera2D 同口径） | 修"引擎夹 position、_center 继续外走"造成的细碎抖动 |
| 外部接管 | 事件镜头 tween 过 position 后，装置检测到 `position != _center` 就接管当前位置继续平滑 | 事件结束时镜头不"跳回" |

`camera_rig.gd` 关键接口：`setup(main, dungeon)` / `reset(pos)` / `follow(delta, focus, friends, event_lock)` /
`focus_look_dir(focus)` / `debug_info()`。全部参数在 `balance.json` 的 `camera` 段。

### 10.3 队友 AI：根因与重做

**感知 / 决策层的 6 个根因**

1. 跟随模式只在 `main.player_in_combat()` 为真时索敌，且索敌圆心是**玩家**：
   怪贴在队友身上（玩家没挨打）→ 队友站着不动；怪在 260~300 的环带 → 谁都不管。
2. 无目标粘性：每次 think 重取 `nearest`，站两只怪中间会左右横跳，看起来"发呆"。
3. **目标下标会失效**：`mob_system._handle_deaths()` 每帧 swap 压缩数组，缓存的下标可能变成另一只怪。
4. 攻击不判视野：隔墙挥空。
5. 卡住判定用"位移 < 2px"：贴墙滑动位移很大但零进展 → 永不触发，只能干等 2.5s 传送；
   而且 `think` 传进来的 `delta` 只是单帧时长（16ms），当计时器用会让所有计时慢约 9 倍。
6. A* 无解（目标格在墙里 / 不可达）时直接直线顶墙；侧移脱困点也不校验可走。

**执行层的 4 个根因**

7. 击杀/死亡后 `atk_timer` 写死 0.42，角色攻速差异（0.34/0.40/0.50）完全体现不出来。
8. 走到路点靠递归 `_ai_dir()`，切角蹭墙；到达不减速 → 冲过头再回头，看着像"抖"。
9. 撞墙后下一拍仍然朝墙推，Godot 的 slide 每帧被重新覆盖 → 原地磨墙。
10. 编队点按"存活人数"均分角度：有人倒下 → 全队换位；点落墙里只吸附最近格；
    开局/复活落点是随机 ±50 偏移，可能直接落进墙里。

**现在的结构（`ai_controller.gd` 全量重写）**

```
感知 → 候选池 = 自身贴脸半径(150) ∪ 队长周边(300 战斗 / 200 非战斗) ∪ 主动进攻搜索半径
      评分   = 距离(2.4) + 对队长威胁(1.7) + 残血收尾(0.35) + 精英/Boss(0.2) - 隔墙(0.9) + 粘性(0.6)
      去抖   = 换目标需超过 1.25 倍；用「模板+位置」校验身份，规避数组压缩错位
决策 → 待机 / 跟随 / 接敌 / 风筝 / 撤退 / 拾取 / 归队，全部双阈值迟滞
执行 → 只写 unit.ai_* ；寻路失败退回流程场；四级卡住处置；贴墙切向偏置
```

- **跟随也还手**：贴脸 150 内的怪一律接战；玩家/队长被贴 200 内主动清理；
  队长挨打则半径放宽到 300 协战。这就是"跟随模式下玩家身边有怪不进攻"的直接修复。
- **粘性 + 拉黑**：同一目标追 6s 还打不到 → 拉黑 5s 换目标，不再对着不可达目标顶墙。
- **远程风筝**：`武器 ≠ melee` 时维持 `[125, 225]` 距离带，太近沿切向后撤（可边退边射），
  被墙挡住自动换边。
- **技能不再掷 3% 骰子**：身边 ≥2 只 / 目标是精英或 Boss 才交，治疗技按血量 55% 触发。
- **卡住四级处置**（按真实墙钟）：0.3s 重寻路 → 0.75s 切向侧移 → 2s 目标距离无改善则换就近可达点
  → 2.5s 传送归队（落点校验可走 + 挑怪物最少的角度）。
- **执行层**：迭代推进路点 + 提前跳点（可直视下一点就跳过）+ 末段减速 + 撞墙切向偏置；
  攻速走模板；`_separation` 站定时减半（治待机互推）。

**编队（`party_manager.gd`）**：队长 = 当前主控单位（不是永远跟剑士）；槽位按 uid 固定分配
（有人倒下不重排）；站位是"队长背后 ±31°/60°/89° 的扇面"，落点不可走时在同半径左右试探。

### 10.4 同批修掉的预存缺陷

1. `main.open_chest()` 陷阱箱分支调用 `world.spawn_enemy()` / `world.enemies`（都不存在）→ 每层必崩。
   已改为 `world.spawn_mob()` + `mobs.aggro[i] = 1`。
2. `build_floor()` 每层 `new Camera2D()` 不释放 → 相机节点随层数累积（见 10.1）。
3. `party.build_nav()` 只比"楼层号 + 尺寸"：同层重开/读档/F3 重载会沿用旧墙位 → 队友往新墙里走。
   已加 `dungeon.get_instance_id()` 判定。
4. 开局/复活落点不校验可走（见 10.3-10）。
5. 前视偏移固定读 `player.facing`，被主控的队友不生效。
6. `ai_controller._pick_target` 里 `mobs.aggro` 类索引的越界读保护。

### 10.5 参数与调参入口（都已进 `data/balance.json`，保存即热重载）

- `camera.{base_zoom,min_zoom,pan_weight,safe_frac,fit_bias,track_ratio,track_release,margin,smooth_time,max_speed,zoom_out_rate,zoom_in_rate,zoom_deadband}`
- `party.ai.{self_defense_radius,assist_radius,assist_idle_radius,los_penalty,stick_bonus,switch_margin,reach_timeout,blacklist_time,ranged_engage,ranged_keep_min,ranged_keep_max,arrive_radius,resume_radius,pickup_threat_radius,skill_min_enemies,stuck_repath,stuck_sidestep,stuck_regroup,stuck_teleport,hold_leash}`
- 旧的 `party.stuck_teleport_after` 已删除（与新 `party.ai.stuck_teleport` 重复且单位混乱）。

### 10.6 已知取舍

- 队友仍走节点（富行为），敌群仍是 SoA；镜头取景只读 `party.friends`，不介入 mob 数据层。
- 跟踪集合上限是"半屏对角线 ×1.3"，超出该距离的队友交给 AI 的归队/传送兜底（
  不可能又保证全屏可见又不让镜头一直拉到最远）。
- `--stress` 万敌场景下 `_pick_target` 候选评分有 96 只上限，正常战斗（5~30 怪）不受影响。
---

## 11. 镜头调度重构 + 队友弹道瞄准修复（2026-11-03 第二轮）

### 11.1 「进入地下二层后异常、镜头再次失效」的根因

`build_floor()` 每层都会 `world.queue_free()` 后 `world.spawn_player()` 重建玩家节点，但主控管理器只在
**为空**时重绑：

```gdscript
if possession == null:
    possession = ArpgPossessionManager.new()
elif possession.current_unit == null:      # ← 换层后它不是 null，是"已释放对象"
    possession.current_unit = player
```

`possession.current_unit` 指向的是**上一层的玩家节点**，它随旧 world 一起被释放。于是下一层同时炸三处：

1. `possession.is_possessed(新玩家)` 恒为 false → 新玩家被当成 AI 单位：**键盘/鼠标全部失效**；
2. `main` 取不到有效焦点 → 镜头停止跟随（上一轮加的 `is_instance_valid` 守卫让它"静默不动"而不是报错）；
3. HUD / 队友 LOD 每帧读 `current_unit.position` → 持续报错（`--stress` 之外的正常流程里表现为卡顿与日志刷屏）。

修法（三处，互为纵深）：

- `build_floor()` 先留 `prev_player`，再按「为空 **或 无效** **或 已被换掉**」重绑；
  主控是队友时保持不动（队友不随层销毁）。
- `ArpgPossessionManager.is_possessed()`：`current_unit` 无效时退回 `u == main.player`，
  这样即使外部再犯同样的错，输入也不会整层失效。
- 焦点读取统一收敛到 `main._camera_focus()`：主控 → 玩家 → 无，只有一条判定路径。

### 11.2 镜头：拆成「算法层 + 调度层」，并把"状态泄漏"变成不可能

上一轮的 `camera_rig` 只有一种运行方式（跟随），过场靠 `main.event_camera_lock` 布尔量 + tween 临时改
`position`。这种写法的问题是：**任何一条忘了复位的路径都会让镜头永久停在某个状态**——换层、
事件被中断、读档、切回标题，都可能触发；而且这套逻辑写死在 `main` 里，换场景无法复用。

现在按 Cinemachine 的两层结构拆开（Brain + 虚拟相机优先级）但保持轻量：

| 层 | 文件 | 职责 |
|---|---|---|
| 取景算法 | `arpg/camera_rig.gd` | 只回答"画面怎么摆"：跟踪集合、平移、缩放、限位、平滑、`drive_to` 定点 |
| 调度 | `arpg/camera_director.gd` | 只回答"这一帧谁在说话"：镜头栈、过渡、到期弹栈、焦点兜底、震屏/前视后处理 |

调度器的四条硬规则（就是"可稳定复用"的来源）：

1. **栈式镜头**：`FOLLOW` 永远在栈底；`FOCUS_POINT` / `FOCUS_NODE` / `EXTERNAL` 压栈生效，
   `_drop_top_of_kind` 保证同类镜头不叠栈。
2. **硬超时**：所有临时镜头都有 `dur`，没给就用 `camera.max_shot_time`（6s）兜底。
   `update()` 每帧先弹过期镜头——**忘了 pop 也只会多停 6 秒，不会永久锁死**。
3. **焦点兜底**：`bind()` 的焦点失效时走 `focus_fallback`（main 传 `_camera_focus`），
   再不行就停在最后有效位置（`_last_pos`），绝不崩、绝不跳到世界原点。
4. **单一写入出口**：`position/zoom/offset/rotation` 全由 director 写；震屏和前视也挪进来了
   （`main.add_shake` 只做设置缩放后转发），不再出现"两处抢写同一个相机"。

复用方式（换场景只改三行）：

```gdscript
var cam := ArpgCameraDirector.new()
add_child(cam)
cam.focus_fallback = Callable(self, "_camera_focus")
cam.setup(self, dungeon)       # 每层/每场景重设边界
cam.bind(focus, friends) ; cam.update(delta)   # 每帧
cam.play_focus_point(pos, 2.0)                 # 过场：自动回到跟随
```

事件 `camera` 命令改为 `cam.play_focus_point(pos, dur)`，`event_camera_focus()` 只负责 await 同样时长，
不再是"布尔锁 + tween"。

### 11.3 队友弹幕打不中：三个叠加的根因

1. **方向被拍扁成四向**（决定性）：`friend_unit.try_attack()` 用 `_face_vec()` 发射，而它是
   `Vector2.LEFT/RIGHT/UP/DOWN` 四选一。目标只要不在正上下左右，弹道就是歪的——
   这正是"不在同一直线就打不中"。近战弧斩也用同一个角，白白损失命中。
2. **没有弹道提前量**：目标在弹丸飞行时间里继续移动，瞄"现在的位置"必然落后。
3. **命中判定是点判定**：`proj_system` 每帧只用弹丸当前坐标查一次圆。
   430px/s 在 60fps 下 7px/帧、掉帧时 14px+，目标圆直径约 20px，极端情况会整帧穿过去。

修法：

- `try_attack()`：弹道/挥砍角度一律用连续方向 `aim = normalize(target - pos)`，`facing_name`
  只负责贴图选行；枪口前移 12px，若落在墙里就退回自身位置（避免弹丸生在墙内立刻消失）。
- `ai_controller._aim_point()`：**交会解算**（先按静止求 t0，再用 t 推目标未来位置重算 t，迭代两次，
  GDC "Predictive Aim Mathematics" 的标准做法），提前量上限 `party.ai.aim_max_lead`（0.55s）；
  预测点被墙挡住时退回当前点。
- `proj_system`：改为**扫掠判定**——每帧用「上一位置 → 当前位置」的线段判定，
  敌方弹对玩家/队友用线段-圆距离，我方弹用空间哈希取候选再取沿路径最先命中的怪。
- `world.mobs_in_arc()`：角度差改用 `wrapf(±π)`。旧写法在朝左/左上挥砍时
  （一个角度在 +π 附近、一个在 -π 附近）差出 2π → 正对着也会判挥空。

### 11.4 新增/调整的配置（`data/balance.json`）

- `camera.max_shot_time` 6.0：临时镜头硬超时；`camera.focus_rate` 12.0：过场推镜速度；
  `camera.look_ahead` 34.0：跟随前视偏移（原来写死在 main）。
- `party.ai.aim_max_lead` 0.55：弹道提前量上限（秒）。

### 11.5 遗留与取舍

- `EXTERNAL` 镜头保留给"外部自己 tween 相机"的旧式用法，但同样受硬超时保护；
  新代码优先用 `FOCUS_POINT` / `FOCUS_NODE`。
- 队友仍然不做"预判走位射击"（移动中侧身开火），只在站位上开火；当前地牢空间下够用。
- `--stress` 下镜头仍按普通逻辑运行（取景只读 `party.friends`，与敌群数据层无关）。
### 11.6 同批修掉的「换层 / 读档」数据问题

- **换层掉级**：玩家是节点，`level/xp/atk/max_hp/equip_hp` 都只活在节点上。`build_floor()` 重建玩家后
  没有搬运 → 下到第 2 层直接变回 1 级（技能解锁、上限、攻击全回退）。现在先快照 `level/xp`，
  重建后 `player.apply_level_stats()` 按「模板基础 + 每级成长 ×(等级-1) + 装备加成」重算。
- **读档等级白升**：`save_system.load_game()` 原来只回填 `level/xp`，不重算 `max_hp/atk`。
  现在同样走 `apply_level_stats()`，再把存档血量 clamp 回上限。
- 新增 `player.apply_level_stats()` / `player.refresh_bars()`：等级 → 派生属性、血条刷新各只有一个入口。
---

## 12. 随机地牢生成 v2：BSP + 图连通 + A* 走廊（2026-11-03）

### 12.1 旧算法的问题

`generate()` 是「随机撒 8 个矩形 → 按 x 排序 → 相邻两个用 L 形走廊连起来」：

- **一条链**：房间顺序 = x 坐标顺序，整层就是一条从左到右的主干道，**没有任何环路**，
  探索永远是"走到头再原路返回"，也做不出"绕后/包抄"的战斗空间；
- 房间数写死 8、尺寸 5~9 × 4~7，每层长得几乎一样；
- 走廊是中心到中心的 L 形，常出现一条长直道横穿整张图，节奏死板；
- 没有房间分级（宝箱、楼梯都是随手挑房间）。

### 12.2 新算法（业界两种主流做法的混合）

参考：BSP 分区（暗黑/传统地牢风）与「散点房间 + Delaunay/MST + 补环路」（TinyKeep 流派）。
BSP 的优点是无重叠、分布均匀、连通性天然保证；缺点是纯 BSP 只连兄弟节点，仍是一棵树。
所以这里用 **BSP 决定"房间摆哪"，用图论决定"怎么连"**：

| 步骤 | 做法 | 解决的问题 |
|---|---|---|
| ① BSP 分区 | 递归二分地图矩形，优先切长边，切点 38%~62%；叶子最小 10 格 | 房间均匀铺满、互不重叠 |
| ② 摆房间 | 每片叶子留 1 格墙，房间尺寸/偏移都带抖动（5~8 × 4~8） | 大小位置有变化，不呆板 |
| ③ 建图 | 每个房间连最近 3 个邻居 → Kruskal 求 MST（保证全连通）→ 再补 30% 次短边成环路 | 一条链 → 网状，少走回头路 |
| ④ 走廊 | `AStarGrid2D` 在代价网格上找路：穿过已有房间 ×2.4、贴墙 ×1.6、贴地图边 ×9；2 格宽 | 走廊自然绕行、不贴边、不堵 8 人小队 |
| ⑤ 分级 | 从起点 BFS 距离场；房间按距离升序；叶节点房间（只连 1 条走廊）标为宝箱房 | 楼梯必在最深处，宝箱在尽头 |

尺寸也随深度微调（44×32 → 47×33，Boss 层仍 36×26 单间），走深一点空间更舒展。

### 12.3 兼容性（旧调用方零改动）

`w/h/grid/rooms/start_cell/boss_floor/is_floor/random_cell_in/floor_cells/_center` 语义全部保留：

- `rooms` **按距起点距离升序** → `rooms[0]` 仍是出发房间（Boss 层/`_near_room` 依赖），
  `rooms[-1]` 就是最远房间，与 `main` 里"楼梯放最后一个房间"的写法天然一致；
- `grid[x][y]` 仍是列优先的二维数组，`flow_field.gd` 直接读它的热路径不受影响。

新增 API：`room_kind`（START/NORMAL/TREASURE/STAIRS）、`loot_room(rng)`（宝箱优先叶节点房间、
游标轮转避免两个箱子挤一间）、`debug_stats()`（房间数/地板占比/可达率，已接到 F1 调试面板）。

### 12.4 参数

`arpg/dungeon_gen.gd` 顶部常量：`MIN_LEAF`(10) / `MIN_ROOM`(5×4) / `MAX_ROOM`(10×8) /
`CORRIDOR_EXTRA`(0.30 环路比例) / `KNN`(3) / `BORDER_COST`(9) / `ROOM_COST`(2.4)。
房间数 = `clamp(7 + floor, 8, 12)`。

### 12.5 已知取舍

- 走廊 2 格宽是"小队跟随不堵门"的下限；墙体会因此偏厚实，不做 1 格窄迷宫。
- 不做"门/钥匙/任务链"这类**结构化**生成（那是 §7 R3 的事）；本层只保证连通、有环路、有分级。
- 没有做 WFC/元胞自动机：本项目美术是标准地牢砖墙，洞穴型边界需要额外贴图集，收益不匹配。
---

## 13. 击杀掉落：金币/宝石爆量 + 吸附收集（2026-11-03）

### 13.1 之前的状态

`on_mob_dead()` **完全不发钱**：金币只来自任务奖励和卖店（`gold_drop_min/max` 这两个参数一直是死配置）。
击杀只有 60% 概率掉一件物品，没有"打怪=进账"的正反馈。

### 13.2 现在的行为（`arpg/drop_system.gd`）

一只怪死亡 → 在尸体位置爆出 N 颗金币（精英 ×2、Boss ×6，且 Boss 必带 4 颗宝石、精英必带 1 颗），
每颗走三段状态机：

| 阶段 | 表现 | 参数 |
|---|---|---|
| 散开 SCATTER | 随机方向 + 随机初速 + 轻微上抛，指数阻尼减速；撞墙按轴反弹（不会弹进墙里消失） | `scatter_speed_min/max` `scatter_time` `friction` `bounce` |
| 待吸 IDLE | 原地上下浮动；进入吸附半径且过了延迟才开始吸 | `attract_radius` `attract_delay` |
| 吸附 ATTRACT | 锁定主控单位、朝其上半身（`position + (0,-8)`）飞；速度按 `attract_time` 做 **ease-in** 加速，同时缩小 + 拉出拖尾线 | `attract_speed_start/end` `attract_time` `arrive_dist` `scale_start/end` |

结算：到达 `arrive_dist` 才 `rpg.gold += value`（`settle_mode = "arrive"`；改成 `"attract_start"` 就是
一开始吸就入账）。同一帧捡到多颗只弹一次 HUD 高亮，避免 9 颗 = 9 个补间。

超时（`lifetime` 14s）：还在 3× 吸附半径内就强制吸回来（不吞收益），太远则直接消失，避免"看不见的进账"。

### 13.3 经济口径（重要）

单只怪的**总价值没变**：仍然是 `gold_drop_min ~ gold_drop_max`（2~6），只是从"直接给钱"变成"拆成几颗飞过来"。
精英/Boss 的倍增在 `drops.elite_mult / boss_mult`。宝石按 `drops.gem.value`（8G）计入总价后从金币里扣除，
所以掉落表现更热闹，但不会通胀。

### 13.4 性能

SoA + 单批次 `_draw`（上限 400 颗，池满时先把最老的结算掉再复用槽位），每帧一次 `queue_redraw`；
爆点金尘复用 `world.burst` 的 64 个特效池。万敌压测下大量同时死亡也不会堆节点。

### 13.5 参数一览（`data/balance.json` 的 `drops` 段，保存即热重载）

`enabled` / `settle_mode` / `elite_mult` / `boss_mult` /
`common.{scatter_time, friction, bounce, scatter_speed_min, scatter_speed_max, attract_radius,
attract_delay, attract_speed_start, attract_speed_end, attract_time, arrive_dist, lifetime,
scale_start, scale_end}` / `gold.{count_min, count_max}` / `gem.{chance, value, scatter_speed_max}`

### 13.6 已知取舍

- 只吸向**当前主控单位**（队友走过不抢钱），保证"钱一定飞向你看的那个人"，视觉不跑偏。
- 换层时未捡的掉落随 `world` 销毁（不做跨层保留）。
- 宝石目前等价于"面值更高的金币"，没有做成独立道具（背包只有 20 格，塞宝石会挤掉战利品）。
---

## 14. 小地图 + 战争迷雾（2026-11-03）

### 14.1 表现

右下角 184×132 面板（`hud.play_hud` 的子控件）：

- **纯灰阶**：地板浅灰 `(0.83,0.85,0.88)`、墙体中灰 `(0.33,0.35,0.38)`、底板深灰 `(0.075,0.082,0.092)`，
  未探索区域**完全不画**（露出底板）——迷宫轮廓靠明暗对比读出来；
- **迷雾按格记忆**：`_seen` 位图（w×h），换层/换图（dungeon 实例 id 变化）自动重置；
- **探索扩散用限半径 BFS**：只穿过地板扩散、不穿墙，所以"隔墙不会点亮"，但绕过拐角会把拐角后
  那一段记下来——这正是"已探索"的语义，比圆形半径自然；
- **实时**：0.12s 一次点灯；光点跟随主控，队友光点/楼梯/传送门按 10Hz 刷新；
- 只有主控（以及已探索区域内的队友）显示光点，未探索区域的单位不显示。

### 14.2 两个实现细节（踩过才知道）

1. **BFS 判重不能用 `_seen`**：玩家沿走廊走一段后，前方新格与已探索格相邻，用 `_seen` 当 visited
   会在旧区域边缘立刻停住，表现为"进新房间只亮门口一格"。现在用独立的 `_visit` 时间戳数组。
2. **逐行合并同类格**：一行里连续的地板/墙合并成一个 `draw_rect`，一行最多十几笔，
   而不是 1500 个格子逐格画——静止时几乎零开销。

### 14.3 参数（`data/balance.json` 的 `minimap` 段）

`enabled`（关掉直接隐藏）/ `width` `height`（面板尺寸）/ `reveal_radius`（探索半径，格）/
`reveal_interval`（点灯间隔，秒）。`ArpgMinimap.explored_ratio()` 供调试，F1 面板会显示"已探 x%"。

### 14.4 已知取舍

- 没有做"擦除式淡入"动画（新点亮的格子是硬切）：格子太小，动画收益低于重绘成本。
- 不做缩放/拖动：地牢最大 47×33，单屏塞得下。
- 迷雾只跟主控走，不跟队友（避免队友探图导致"我没去过却全亮"）。
---

## 15. 多语言架构骨架（C++ / C# / WebView2，2026-11-03）

> 详细设计见 `docs/多语言架构_CSharp_CPP_WebView2.md`。**现有 GDScript 玩法完全不受影响**，
> 本骨架是并行存在的工程结构，按阶段迁移。

- **分工**：C++ 只做"每帧 × 大规模"的数值（空间哈希/分离/流程场/弹道宽相/哈希/WebView2 宿主）；
  C# 做规则与编排；WebView2(JS) 只做模态/整屏 UI；GDScript 保留现有玩法与编辑器工具。
- **边界**：只允许向下调用（JS→C#、C#→C++、GDScript→C++）；C++ 不含引擎头、不回调上层。
- **双出口**：同一个 DLL 既有 GDExtension 入口（`qy_library_init`，给 GDScript/编辑器），
  也有 C ABI（`qy_get_api`，给 C# P/Invoke 零封送）。C ABI 用函数指针表 + 版本号，只增不改。
- **数据交换**：C# ↔ C++ 走 POD 缓冲 + `Span<T>`/`fixed`；C# ↔ UI 走 JSON（10Hz 快照 + 命令）。
- **WebView2**：子窗口叠加式嵌套（盖在游戏上），已定协议、DPI/焦点/降级策略；只做模态 UI。
- **降级链**：native 缺失 → GDScript 实现；WebView2 缺失 → Godot 原生 UI；引擎非 .NET 版 → 现状照跑。

新增目录：`native/`（CMake + C ABI + crowd 内核 + GDExtension 壳 + WebView2 宿主）、
`game_cs/`（Godot.NET.Sdk 工程 + NativeApi/WebUiBridge/GameHost）、`webui/`（HTML/CSS/JS + 消息桥）、
`tools/build_native.ps1`。

**本机前置条件（重要）**：引擎是**标准版**（跑不了 C#，需换 mono 版）；缺 CMake / MSVC / WebView2 SDK；
.NET SDK 缺 net8.0 targeting pack。已验证：`src/core` 通过 `g++ -fsyntax-only`、webui 通过 `node --check`、
构建脚本通过语法解析；GDExtension/C#/WebView2 尚未实际编译。
---

## 16. 编辑器可视化与中文化（2026-11-03）

详见 `docs/编辑器可视化与中文化.md`。两个症状、四个层次，全部是**增量**，不改任何玩法逻辑。

### 16.1 根因

- **2D 视图空白**：`main.tscn` 只有一个空 `Node2D` 根节点，地牢/敌群/玩家/HUD 全在
  `main.gd._ready()` 里用代码 new。全项目**没有任何 `@tool`**，所以编辑器不执行 `_ready()`，
  视口自然什么也没有；`main.gd` 也没有一个 `@export`，检查器同样没东西可调。
- **检查器英文**：Godot 界面文本走 `TTR()`（tool 翻译域），官方 zh_CN 覆盖了菜单/面板，
  但**属性名与分组标题**（Position / Rotation / Scale / Transform / Visibility / Ordering…）
  长期没翻，翻不到就显示原文。与项目代码无关。

### 16.2 四层改造

| 层 | 文件 | 内容 |
|---|---|---|
| 预览 | `arpg/editor_preview.gd`（新） | `@tool Node2D`，编辑器里用固定种子生成地牢并 `_draw()`：深灰墙打底、浅灰地板（逐行合并 1408 格→几十条指令）、房间按类型描边+序号、起点/楼梯/宝箱标记、顶部信息条。运行时 `_ready` 直接 `queue_free()`，零开销 |
| 配置 | `arpg/main.gd` | `@export_group("开局"/"地牢")`：起始层、开局队友数、地牢种子。默认值与原行为一致；优先级 `--friends=N` > 检查器 > `balance.json` |
| 结构 | `arpg/main.tscn` | 预置「世界 / 队伍 / 镜头 / 界面」四个容器；`main.gd` 用 `_slot(name)` 优先复用，取不到退回 `self`（headless / 直接 new 的场景仍可跑，不构成运行依赖） |
| 中文 | `addons/arpg_zh_editor/`（新） | EditorPlugin 构造 `Translation` 注入 `TranslationServer`，补 50+ 条检查器属性名/分组名；仅在 `locale` 为 zh* 时启用，`_exit_tree` 可完整还原 |

`project.godot` 新增 `[editor_plugins] enabled=PackedStringArray("res://addons/arpg_zh_editor/plugin.cfg")`。

### 16.3 能力边界

- 中文化只能覆盖词表里的术语。引擎内部的专业术语（着色器/导入器/调试器内部项）编译在
  二进制里，不重编译引擎换不掉——目标是「写玩法时不被英文属性挡住」，不是「翻译整个引擎」。
- 预览层是**只读**的：只读 `balance.json` 与生成器，不写任何游戏状态，删掉游戏照跑。
- 容器节点只是组织手段：`_slot()` 取不到就退回 `self`，不影响 headless 测试与命令行流程。

### 16.4 操作

打开 `arpg/main.tscn` → 选中「编辑器预览」按 **F** 框住整张地图 → 检查器改「层号/种子/换一张图」即时重绘。
根节点 `ArpgMain` 的检查器顶部即「开局/地牢」中文参数，改完 F5 生效。

### 16.5 第二版修正（用户实机反馈后）

**① 预览画成「一间大房」**：第一版 `_rebuild()` 用 `ArpgBalance.MAX_FLOOR` 夹层号，但编辑器里
静态变量初始化时序不稳、可能读到 0；而生成器判据是 `boss_floor = floor >= MAX_FLOOR`，
**0 会让任何层都命中 Boss 分支**（该分支只 `_add_room(Rect2i(5,4,26,18))` 后 return），
于是预览只有一块大房间 + 一个起点圆。修：`reload_data()` + `MAX_FLOOR < 2 时强制改 5` +
生成后二次校验（`boss_floor and lv != max_floor` 就按普通层重生成）三道保险。
信息条现在会写明「普通层 / Boss 层 · 第 N 层 · 尺寸 · 种子 · 与游戏一致 / 示意」。

**② 翻译完全没生效**：`TranslationServer.add_translation()` **只写主域**，而编辑器属性名走的是
独立域 **`godot.properties`**（另有 `godot.editor` 管 UI 文本）。必须
`get_or_add_domain("godot.properties").add_translation(...)`。现在三域齐发，并加
`has_method` 保护（`TranslationDomain` 是 4.4+ API）。插件加载时输出面板会打印注入条数与域数。

**③ 选中容器节点满屏英文**：用户截图中选的是「世界」——纯 `Node2D`、无脚本属性，于是
position/rotation/visibility/ordering/texture/material/process 全暴露。现在容器挂
`scene_layer.gd` / `ui_layer.gd`（`@tool`），用 `_validate_property` 把这些内置属性从检查器
隐藏（只去 EDITOR usage，运行不受影响）。调试需要时把脚本里 `const SHOW_RAW := true`。

**④ 一个自己引入的严重隐患（已修）**：`@export var 说明` 这类中文变量名一旦随场景保存，
`.tscn` 就再也读不回来——`VariantParser` 的裸标识符判定是 `is_ascii_alphabet_char`，
**ASCII-only**（节点名走带引号字符串，不受限）。所有导出变量已改回 ASCII，中文标签靠翻译域补；
容器节点干脆不定义任何 `@export`。

**⑤ 属性名比较**：`property.name` 是 `StringName`，与字符串数组做 `in` 比较可能不命中，
统一改 `str(property.name) in [...]`。
---

## 17. 创作工坊：EditorPlugin 扩展 + 独立工具（2026-11-03）

详细设计见 `docs/创作工坊架构.md`。

### 17.1 结构

```
creator/core/       共享内核：ui_kit / data_store / event_editor / dungeon_view / workspace
creator/creator.gd  独立版外壳（120 行）
addons/qy_creator/  编辑器扩展：plugin.gd（注册主屏/精简页签/菜单）+ main_screen.gd（40 行）
```

两套宿主共用一个 `workspace.gd`，差异只有两处：试玩方式、窗口外壳。

### 17.2 职责硬边界

- `core/*` 只编辑与保存，不创建窗口、不碰 `EditorInterface`；
- 独立外壳：`OS.create_process()` 起新进程试玩；
- 插件外壳：`EditorInterface.play_main_scene()`，复用编辑器运行配置。

### 17.3 编辑器扩展只用官方扩展点

`_has_main_screen()` / `_make_visible()` / `_get_plugin_name()` / `_get_plugin_icon()`，
主屏容器挂 `EditorInterface.get_editor_main_screen()`，`_exit_tree` 完整还原。**不改引擎一行代码。**

页签精简（隐藏 3D / 资产库）三条注意：按文案匹配而非下标、等两帧再执行（否则匹配不到翻译后的 text）、
只 `visible=false` 不删节点且提供「恢复编辑器默认页签」菜单项。

### 17.4 视觉定调

工业实用：暖近黑 `#0E0D0C` + 暖白 `#F5F1EA` + 单一铜橙 `#E8873A`（只给保存/选中/主操作）；
五个模块各一条 3px 分类色带；所有数字/坐标/种子用等宽 Consolas；小圆角 + 发丝线；
切模块时内容错峰淡入 0.26s（**只动 opacity**，Container 会重写子节点 position，位移会被打回）。

### 17.5 验证

全部脚本 `--check-only` 通过；无残留旧路径。实机验证清单见文档 §6 的 9 项。

---

## 18. pixelfx 特效接入（2026-11-03）

详见 `docs/pixelfx特效接入.md`。

- **引入方式**：`vendor/pixelfx`（MIT，266 个特效，JS 源码）。原库是 **JavaScript**，
  Godot 跑不了，所以走离线渲染：`node tools/render.mjs <id> --sheet --no-actor` 出 PNG，
  `tools/build_pixelfx_fx.py` 缩放 + 合并成 `assets/fx/pxfx/fx_atlas.json`。
  **`--no-actor` 必须加**，否则演示小人会被画进每一帧。
- **运行时**：`arpg/pxfx.gd`（`ArpgPxfx`）读 atlas，`Player` 是 Sprite2D 内部类，
  用 `hframes/vframes` 切网格。关键换算：`offset = 帧尺寸/2 - pivot`，否则特效作用点不在 position 上。
- **入口**：`world.spawn_pxfx(name, pos, opts)`，opts 支持 scale/rot/tint/speed/once/flip/additive/z。
- **已接 12 个**：slash / hit / burst / heal / coin / gem / dissolve / portal / frost / zap / arrow / mana。
  四个旧函数（spawn_slash/nova/hit_spark/death_poof）签名不变、内部换实现并保留粒子叠加。
- **删掉的旧贴图**：Slash1 / ShockWave1 / ShockWaveRing1 / Ring / LightRing / Fog（含 .import）。
  **保留** Particle100（pixelfx 不提供单张粒子图，burst 仍在用）、Circle / Arrow（弹道，不是特效）。
- **顺带修**：`EventEditor.setup()` 在 add_child 之前刷新导致三处 `get_children()` 打在 null 上。

---

## 19. 图块场景编辑器（2026-11-03，创作工坊第六模块）

详见 `docs/场景编辑器.md`。**只存不改游戏**：场景存成 `data/scenes/scene001.json`，`ArpgWorld` 目前不加载它
（接法有玩法决策，见 `docs/下一轮交接.md` §6 的 P1-1）。

- **与「关卡」页的分工**：关卡页调程序生成地牢的**参数**（层号/种子/房间数），场景页**手工摆图块**。两者不重叠。
- **图块集导入绕开 Godot 导入系统**：用 `Image.load()` 直接解码成 `ImageTexture`，
  PNG 丢进 `assets/tiles/` 点「刷新」即可用，不必等 `.import` 生成或重启编辑器。
- **画布只画可见格**：按 `off/zoom` 反算可见行列，200×150 的图也最多画一屏；`_draw` 事件驱动，静止零开销。
  滚轮以鼠标为锚缩放、中键平移、右键擦、`Alt`+左键吸管。
- **多图层**：增删/显隐/独立数据，绘制只作用于当前层；撤销按「一笔」记快照（一次拖动算一步），最多 40 步。
- **数据格式刻意最朴素**：`width/height/tile_size/grid_size` + 每层一个行优先 `int` 数组，`-1` 为空。
  将来游戏侧读它不需要任何转换层，序号直接反算 `region_rect`。
- 交互打磨（PR #3）：工具按钮改用引用数组（原先靠 `get_parent().get_child(0)`，布局一改就废）；
  切到本页时 `call_deferred("reset_view")`（`_ready` 阶段容器尺寸还是 0，`fit_view` 会被保护逻辑跳过）。

---

## 20. 网格与图块解耦 + 大角色 footprint（2026-11-03）

详见 `docs/网格与图块方案.md`。起因是「32×32 网格不够用」，但真正的毛病不是数字小，
而是**逻辑网格 / 美术图块 / 实体尺度被绑成了同一个常量**。

### 20.1 三层坐标系

```
世界坐标 (px)   ← 渲染、碰撞、特效、镜头
    ↑ ÷ grid
逻辑网格 (grid)  ← 寻路、房间、走廊、小地图        【固定 32】
    ↑ 仅渲染换算
美术图块 (tile)  ← 图块集切分与绘制              【16/24/32/48/64 自由】
```

`ArpgData` 拆成 `GRID`（逻辑）+ `TILE_ART`（美术）+ `TILE := GRID` 别名，
**53 处旧引用零改动**。新增 `ArpgData.src_rect(col, row, size)`，换图块尺寸不必再手写 `Rect2`。

### 20.2 关键决策：网格不动

网格缩一半 = A\* 节点 ×4（44×32 的图从 1408 变 5632），直接冲击万敌压测。
而**放大角色根本不需要改网格** —— 让它占 2×2 格即可。所以 `GRID` 固定 32，尺寸需求由 footprint 消化。
若将来真需要更粗的宏观网格，正确做法是加一层「区块」（若干格合并成房间单元），而不是把 A\* 粒度调粗。

### 20.3 大角色四条规则

| 规则 | 解决什么 | 实现 |
|---|---|---|
| 脚底锚点 | 对齐：16px 小怪与 96px Boss 站同一格时脚对脚 | sprite origin 在脚底中心 |
| 半径独立 | 尺寸：`radius = 9 × scale`，与网格无关 | 已有 |
| footprint 派生 | 通行：寻路时据此膨胀障碍 | `ceil(直径/32)` |
| 走廊下限 | 生成：不出现「进不去的图」 | `generate(floor, seed, corridor)`，`main` 传 `maxi(2, max_footprint())` |

分界点（`ceil(直径/32)`）：≤32 → 1×1；32~64 → 2×2（`scale ≥ 1.78`）；64~96 → 3×3（`scale ≥ 3.56`）。

**零回归**：现有实体最大直径 27px（Boss 1.5），footprint 恒为 1，走廊仍 2 格。

### 20.4 刻意没做

**A\* clearance map 没接** —— 全 1×1 时是纯开销。方案已写进文档（换层时算一次 `byte[]`，几十 KB），
等真有 2×2 实体再开。这不是遗漏。

---

## 21. 提交与发布路径（2026-11-03）

详见 `docs/提交与发布流程.md`。**下一轮改完代码照这个走，不要再手敲 git 命令。**

```bash
python tools/gh_pr.py pr --title "feat: xxx" --body "..." --merge   # 推分支 → 建 PR → 合并
python tools/gh_pr.py put --path docs/x.md --message "docs: 更新"    # git 不通时走 Contents API
python tools/gh_pr.py status                                        # 查凭据身份 / 开放 PR
```

- **凭据**：复用 GitHub Desktop 登录留下的 Windows 凭据（`git credential fill`），不需要 PAT、不落盘、不回显。
- **实测结论**：`git push` 通道本身可用（之前遇到的 502 是 `codeload.github.com` 与 `api.github.com`，
  与 git 传输无关）。所以最优路径是 **git push 推分支 + API 建/合并 PR**，比逐文件 Contents API 快得多。
- **网络抖动**：本轮 `api.github.com` 多次 502，脚本已自带「复用已有 PR」逻辑，退避重试即可，不会撞「PR 已存在」。
- **`.gitignore` 要点**：`.workbuddy/`（本地记忆）、`native/build/`、`vendor/pixelfx/{docs,gallery,records}/`、
  `game_cs/{bin,obj}/`、`webui/node_modules/`。

---

## 22. 一小时 Demo 主线编排：任务链 + 剧情事件（2026-11-07）

> 蓝图：`docs/一小时Demo蓝图.md`。目标是一条约 60 分钟的完整流程（章节推进/任务链/剧情节点/关卡编排），
> 原则是**不加新大系统**，全部用事件引擎 + 任务管理器 + balance.json 编排。

### 22.1 回归基线（本轮开场重跑，全部实机命令验证）

| 测试 | 结果 |
|---|---|
| smoke_arpg | PASS（含本轮新增断言，见 22.4） |
| smoke（战棋 29 项） | PASS |
| smoke_creator（23 项） | PASS |
| --autoplay | PASS |
| --stress=10000 --bench=15 | 127 FPS（基线 ≥50，exit 0） |

### 22.2 ✅ 修掉 autoplay 的 just_pressed 全链路失效（重要，影响所有模拟输入）

- **现象**：机器人反复打印「重伤喝药」但 HP 一路掉到 2、药瓶数不减；interact/技能同样可疑。
- **根因**：`autopilot._tap()` 用 `Input.action_press()`，本节点 `_process` 与 `main._process` 的执行顺序
  导致 `is_action_just_pressed` 记录的帧号永远错开——**所有单帧类输入（药水/交互/技能）从未生效**。
  持续按住类（移动/攻击，`is_action_pressed`）不受影响，所以机器人此前仍能勉强打通但战力残废。
- **修法**：`_tap` 与其释放改走 `Input.parse_input_event(InputEventAction)`（真实输入管线，帧首分发）。
- **修复后质变**：autoplay 从「42s 结算 · 击杀 6 · Lv1 卡 1 层」→「打穿到地下 4 层 · 击杀 27 · Lv5」。

### 22.3 任务链（requires 前置解锁）

- `rpg_state.gd`：新增 `quest_unlocked(qid)`（前置任务 state ∈ {done, claimed} 才解锁）；
  `quest_progress()` 跳过未解锁任务（杀怪不会偷跑下游任务进度）。
- `quest_manager.gd`：`rows()` 过滤未解锁（任务页只见当前章节）；`_check_done()` 加 `notified` 旗标
  **修掉重复弹 toast 的预存 bug**（done 未领奖期间每次杀怪都重弹「任务完成」）+ 解锁下游任务时弹「新任务解锁」；
  `claim()` 里 xp 奖励**真正入账**（`player.gain_xp`；此前只拼文本，`rpg_state.gd:92-93` 的 xp 从未生效）。
- `main.on_mob_dead()` 补 `quests.on_kill(tpl_name[i], boss)`——**kill 类任务此前无人接线，永不完成**。
- `balance.json.quests` 重构为 5 章任务链：`q_intro(reach 1) → q_hunt(kill 8) → q_ore(collect 5, 奖 sword_iron) → q_depth(reach 4) → q_boss(kill boss)`，总奖励 590G + 装备/药水。

### 22.4 ARPG 剧情事件（与战棋地图 JSON 解耦）

- **新文件 `data/maps/arpg_events.json`**：6 条事件，楼层号 = 事件引擎回合数（`_intro` 已有机制）。
  T1 序章·债主通牒 / T2 深处低吼+震屏 / T3 增援（spawn 落点就近改刷）/ T4 前人笔记+give_xp / T5 Boss 战前对话+heal_full / **unit_death boss** 终章对话。
- `main._load_map_events()` 改读 `ARPG_EVENTS_PATH`（不再共用战棋 `map001.json`——战棋的伊伊开场对话不会在 ARPG 念出来）。
- `event_system.gd`：新增 `on_unit_dead_tpl(uid, tpl)`（mob 是 SoA 数据槽没有 uid/tpl_id 属性的适配入口）
  和 `give_xp` 命令（match 分支）；Boss 死亡在 `on_mob_dead` 里触发终章事件（**不 win**，保留传送门结算流程）。
- 编辑器同步：`editor/advanced_tabs.gd` 与 `creator/core/event_editor.gd` 的调色盘/默认参数/属性表单/节点摘要四处都加了 `give_xp`。
- zone 触发器在随机地牢**不可靠**（rect 可能落墙里），Demo 剧情全用 turn_start + unit_death；zone 留给手搭场景（P1-1）。

### 22.5 测试增量（smoke_arpg 新断言）

- 第 9 节：任务链 6 断言（锁定不推进 / 前置完成解锁 / 领奖 / 金币 / xp 文本）。
- 第 12 节：事件数 == 6；`unit_death → give_xp` 真实触发链路 + 非 boss 死亡不误触。
- ⚠️ 踩坑记录：任务链断言不能比对裸 `player.xp`（领奖 +20 后立即升级会扣 `xp_need`，净变化为负）；
  楼层测试会让 q_intro 开局即完成（reach_floor 1），链路断言要先手动还原锁定态。

### 22.6 伤害管线 v2：暴击 + 全怪伤害数字（同轮第二提交）

- `world.damage_mob()`（玩家→怪的**唯一**伤害入口：近战/技能/冲刺/弹道全走这里）注入：
  - **暴击**：`balance.json` 新 `combat` 段 `{crit_chance: 0.12, crit_mult: 1.8}`，热重载；
  - **暴击读感三件套**：金色 26 号伤害数字（普通白色 15 号）+ 金色火花 + 加重顿帧/震屏/手柄震动，击退 ×1.35；
  - **全怪受击伤害数字**：此前打怪只有火花没有数字（玩家受击反而有），现已补齐。
- `spawn_popup()` 加 `size` 参数（默认 17，旧行为不变）。
- smoke 断言：combat 段载入 + damage_mob 暴击/斩杀路径无崩溃。

### 22.7 数值校时（对齐 55~70 分钟目标）

- 实测口径：改动前每层仅 7~13 怪，autoplay 40s/层、真人估 3~5 分钟/层，全流程 20~30 分钟，**远不足一小时**。
- 调整（`balance.json` 热重载）：`floor_enemy_count_base 5→8`、`per 2→3`（1 层 11 只 → 4 层 20 只），
  `floor_pools` 全 5 层重排（1 层混入 wolf，3 层起 fox 主力，4 层 knight ×4 压轴）。
- 等级节奏验算：怪 xp 62 只 ×均 8 + boss 90 + 任务 xp 120 + 事件 30 ≈ 736，xp 曲线累计到 Lv7 需 402 →
  终章约 Lv7~8，witch 的 meteor（Lv6）在 Boss 战前解锁，节奏成立。
- 金币口径：任务链 590G + 击杀掉落 ~250G + 宝箱 ≈ 900G，结算还债 600G 后仍有盈余（Demo 留悬念）。
- autopilot 的 `retreat_at=100s` 撤退机制不受怪数影响（仍 PASS，结算数字变小）。

### 22.8 ✅ 视觉走查闭环（新工作法，本轮建立）

**movie 渲染 + 视觉子代理审图**（替代"必须人开窗口看"的部分场景）：
- `tests/visual_mainline.gd`（新）：选人 → 序章对话（自动推进）→ 挂 autopilot 战斗 → 任务菜单；
  配合 `--write-movie "<dir>/x.png" --fixed-fps 10 --quit-after 235 -s res://tests/visual_mainline.gd`
  出 189 帧 PNG（输出到 `.shots/`，已 gitignore）。
- 手动挂载 autopilot 必须 `ap.main = main`（CLI 模式由 main.gd 的 --autoplay 分支赋值，绕过即 Nil）。
- 双轮审图修掉：战斗日志无底板压地砖、对话「继续」提示过暗、伤害数字糊在浅色地砖上（描边 4→6）、
  对话框与日志层级冲突（对话期间收起日志）。
- ** movie 模式 FPS 显示 9~11 是写盘 IO 假象（踩坑 #7），性能以 --bench 为准。
- 审图遗留（实机确认）：HUD 左上血/蓝条层叠错位疑似、队友与怪同皮肤无血条区分（像素素材限制）。

### 22.9 提交与合并（✅ 已完成）

- 网络中断期间 3 个提交安全保留在本地分支，恢复后 `git push` 直接成功；
- **PR #6 已合并**（`1a32f00`），main 已同步。
- ⚠️ 新踩坑：**代理环境下 python 的 SSL 证书链失败**（`CERTIFICATE_VERIFY_FAILED`）而 git 正常——
  gh_pr.py 前加 `SSL_CERT_FILE="C:/Program Files/Git/mingw64/etc/ssl/certs/ca-bundle.crt"` 即可走通 API。

### 22.10 ✅ 四大扩散系统（同日第二轮，未开 PR 先记档）

> 用户指令：发挥扩散性思维让游戏更精彩。按「醒来就能玩到精彩一场」选了四个高杠杆点。

| 系统 | 实现 | 配置（热重载） |
|---|---|---|
| **精英词缀** | 4 词缀数据驱动（`balance.affixes`）：迅捷 spd×1.45 / 坚韧 hp×2.2 / 嗜血命中回血 50% / 临终爆炸死后 6 向弹幕+火环；精英 70% roll（`affix_chance`）；SoA 加 `affix/affix_seen` 两个 byte 数组，倍率 spawn 时一次算进面板，**热路径零分支**；LOS 首次发现头顶弹紫色词缀名 + 日志「XX的YY出现了！」 | `affixes` 段 + `affix_chance: 0.7` |
| **债务系统** | `rpg.debt/debt_paid`（初始 300G 对齐开场剧情）；结算 `_settle` 时金币尽力还债；HUD 顶栏「债务 300G」清零变金色；结算屏债务行/清零金色大字；存档兼容（`d.get("debt", 300)`） | `debt.initial: 300` |
| **连杀播报** | 3 秒窗口（`combo.window`），3/5/8 杀玩家头顶弹「N 连杀！」金色 22 号；结算屏最高连杀 | `combo.window: 3.0` |
| **神秘商人** | 紫色悬浮晶体（复用 chest 交互链 + `merchant` 标志），普通层 25%（`merchant_chance`）出现在宝箱房；E 键进店，**期间暂停世界**，关闭/ESC 恢复；不消耗晶体可反复逛 | `merchant_chance: 0.25` |

**顺带修掉 3 个走查发现的 UI bug**：任务奖励原始 JSON 外泄（→`_rewards_text` 中文格式化）、
日志底框空置常显（→无日志隐藏+对话同步）、顶栏背包永远 0/20（`main.bag` 是遗留死数据，改读 `rpg.inventory.used()/count()`）。

**验证**：smoke_arpg **135 断言**全绿（+13）；战棋/创作器 PASS；autoplay **击杀 48 · 4 层 · Lv6** PASS（新曲线+词缀加成）。
渲染黄金帧：伤害数字描边、「5 连杀！」+ LEVEL UP + 词缀播报日志同框确认。

**Boss 战现状备注**（评估过不必做）：Boss 已有狂暴（40% 血 spd×1.35）+ 周期 10 向弹幕 + 震屏，终章压迫感足够。

### 22.12 ✅ E 批：地牢互动三件套（同日第三轮）

| 系统 | 实现 | 配置 |
|---|---|---|
| **E1 血祭坛** | 暗红石台（AltarNode 脉动红光）20% 概率刷在普通房；E 键献祭：主控扣 30% 生命（保底 1 不死）→ `main.altar_atk_mult = 1.3`（damage_mob 全局乘区，玩家+队友全吃）→ 本层有效，换层重置 | `altar_chance: 0.2` |
| **E2 队友台词** | 击杀后 15% 概率随机存活队友头顶白色小字台词（职业各自 4 条，`battle_quotes` 段）；8 秒冷却防刷屏 | `quote_chance: 0.15` |
| **E3 小地图标记** | 未开的宝箱=金点、神秘商人=紫点（只画已探索区域），找路不再瞎逛 | 无参数 |

**验证**：smoke_arpg **139 断言**全绿；战棋/创作器 PASS；渲染确认祭坛实体/伤害数字/小地图紫点。
autoplay 回归在跑（后台），结果记入提交信息。

### 22.13 ✅ F 批：剧情入队 + 还债结局反馈（PR #9/#10 已合并）

- **事件命令 `spawn_friend {tpl}`**（ARPG 专属，战棋侧 `has_method` 跳过）：`main.spawn_friend_at()`
  主控身边就近可走格 `recruit_char` + 绿色 nova + 音效。**二层剧情编排弓手凯入队**——
  三职业在中层集齐，队伍从 2 人成长到 3 人（叙事+养成双重节点）。双编辑器调色盘已同步。
- **还债结局反馈**：结算时债务清零 → 标题变金色「债务清零！」+ 专属 flavor；部分偿还 → flavor 加
  「这一趟还了 XG——离自由又近了一天」。露塞提娅循环的正反馈时刻。

### 22.14 本轮（2026-11-07 扩散日）全部合并记录

| PR | 内容 |
|---|---|
| #6 | 主线编排：任务链/剧情事件/暴击/视觉走查首轮 |
| #7 | 四大扩散：词缀/债务/连杀/神秘商人 |
| #8 | E 批：血祭坛/队友台词/小地图标记 |
| #9 | F 批：剧情入队/还债结局反馈（含 E 批合流） |
| #10 | spawn_friend 双编辑器同步 + 断言 |

**最终回归**：smoke_arpg **140 断言全绿** · 战棋/创作器 PASS · autoplay PASS（最高 48 杀 4 层 Lv6）· 万敌 114FPS。
smoke_arpg 断言数从 116 → **140**（本轮 +24）。

### 22.15 玩家完整体验动线（醒来直接开玩）

选人 → 序章对话（债主通牒）→ 1 层（任务链启动/连杀播报/暴击数字/词缀精英遭遇播报）→
2 层（深处低吼 + **弓手凯剧情入队**）→ 3 层（增援围猎）→ 4 层（前人笔记 + 血祭坛抉择 + 神秘商人）→
5 层（Boss 战前对话 + heal_full → 狂暴弹幕 Boss 战）→ Boss 死（终章对话）→ 传送门 →
结算（战利品盘点 → **自动还债** → 债务清零金色标题）。

### 22.17 ✅ G/H/I 批（扩散日深夜轮）

| 批 | 内容 | PR |
|---|---|---|
| G | **三职业大招**（无双乱舞/末日审判/万箭穿心，Lv7，volley 支持 count/spread_deg 配置）；HUD 技能栏显示全槽位+**未解锁大招等级预告**（成长钩子）；击杀里程碑（每 25 杀赏金 40G）；商店打磨（金币不足置灰+页签选中态+打捞提示）；对话文本宽度修复；toast 队列轮播（修前缀叠加）；小地图 Boss 红点 | #11 ✅ |
| H | **Boss 专属掉落「魔王徽记」**（商店不卖，Boss 死直接入包）；**拆除 autopilot 商人卡死定时炸弹**——商人晶体交互后商店打开+世界暂停，机器人无人关店必 watchdog 死（此前多轮 PASS 纯属 25% 概率没 roll 中；实测当轮 roll 中、闭环 PASS） | 本地待推 |
| I | **跨局成就统计**：lifetime_kills/best_floor/best_combo（结算更新+存档往返+结算屏展示「历史：累计击杀 X · 最深 Y 层」） | 本地待推 |

- ⚠️ `Coin1.ogg` 不存在（SFX 表曾引用）——里程碑音效改用 `Magic1.ogg`。加音效先 `ls assets/se/`。
- ⚠️ 商人晶体与宝箱同在 `world.chests`，宝箱数量断言要用区间（25% 概率 +1）。
- **最终回归**：smoke_arpg **142 断言**（本轮累计 +26）· autoplay 商人闭环实测 PASS。

### 22.19 ✅ J 批：P1-1 手搭场景接入（方案 C 独立试玩模式）

**定案**：场景编辑器的 JSON（`data/scenes/xxx.json`）通过**转换层**变成 ArpgDungeon——碰撞/寻路/
怪物/宝箱/小地图/镜头全部现有管线零改动复用。

- **`arpg/scene_loader.gd`（新）**：`load_dungeon(path) -> ArpgDungeon`
  - 约定：第一个可见图层里**画了图块的格 = FLOOR，空（-1）= WALL**——手搭布局决定走位；
  - `grid_size != 32` 按比例换算（1 图块 → grid_size/32 格）；
  - rooms = 地板连通块包围盒（flood fill，面积降序，滤 <3×3 碎块）；
  - **楼梯 = BFS 距离场最远地板格**（手搭场景常是单个大连通块，房间结构法会让楼梯与起点重叠）；
  - 方案 C 边界：图块索引不参与渲染（视觉仍是默认地砖），图块视觉接入需 tileset 渲染管线（后续）。
- **`main.gd`**：`--scene=scene001` 命令行（user args）→ `build_floor` 生成分支换 loader；加载失败回退随机。
- **`data/scenes/scene001.json`**：示例场景「千渊前厅」（8 房间 40×30 全连通 434 格）——醒来可直接
  `运行游戏.bat` 之外用 `--scene=scene001` 试手搭关卡。
- **验证**：smoke_arpg **146 断言**全绿（场景加载/包围盒/起点/楼梯/地板数/缺失回退 6 条新断言）；
  渲染确认手搭布局+怪 10 只+宝箱+序章剧情正常；场景模式 autopilot 回归在跑。
- ⚠️ 踩坑：Python 生成走廊时 `grid[9][y]`（行9）vs `grid[y][9]`（列9）行列颠倒导致 4 个孤岛——
  手搭数据先用连通块探测脚本（/tmp/probe2.gd 思路）验证再入库。

### 22.21 ✅ K/L 批（定时轮 1~2）：经营循环 MVP + 图块视觉接入

| 批 | 内容 | 验证 |
|---|---|---|
| **K 经营循环 MVP** | `rpg.day` 跨局天数；**日租 20G**（`rent.daily`）——付得起抵债、付不起**欠额滚进债务**（雪球压力）；超 `rent.ten_days`（10）天未清 → 结算 flavor 压力叙事（不硬失败）；结算屏「第 N 天」 | 实测生效：结算后 320G·第2天（机器人付不起租滚债）；149 断言 |
| **L 图块视觉接入** | `ArpgDungeon` 加 `tile_ids/tileset_tex/tileset_cols/tile_px`（scene_loader 填）；`world._draw` 有场景图块时**优先绘制玩家所选图块集**（索引→行列→region），墙/无图块回退默认砖；tileset 用 `Image.load` 解码（绕过导入系统，同场景编辑器做法） | 渲染确认：画面从洞穴砖变 TileA2 草地/土路/树混铺——手搭美术完全数据驱动 |

- ⚠️ 示例场景原指向不存在的 `tileset1.png`，已改 `TileA2.png`（16×12 图块）。加 tileset 前 `ls assets/tiles/`。
- ⚠️ smoke 断言「初始债务 300」移到开局后（第 5 节结算会收租改变 debt 时序）。
- **当前基线**：smoke_arpg **149 断言**全绿。
- ⚠️ **网络状态**：J/K/L 三批（`9a85ac8`→`74b6263`）在本地 main，后台循环重试推送中。恢复后 `git push origin main` 即可。

### 22.23 ✅ M 批（定时轮 3）：Boss 二阶段——战斗域终章强化

- **狂暴强化（40% 血触发）**：红色横幅「魔王狂暴了！」+ **召唤 2 imp 护主**（`phase2_summon/tpl` 可配）+ 弹幕 10→**16 向**、弹速 215→275（`phase2_nova/phase2_bullet_spd`）、弹色转深红——阶段切换读感质变。
- 实现：`mob_system` enrage 分支发 `EV_ENRAGE` 事件 → 主线程消费（横幅/召唤/nova/顿帧）；`EV_SPECIAL` 按 `enraged` 分支读 boss 段参数。全部热重载。
- 验证：smoke_arpg **151 断言**全绿（参数载入 + enrage 召唤链路 2 条新断言）；渲染黄金帧确认横幅+弹幕+召唤同框。

### 22.25 ✅ N 批（定时轮 4）：P1-2 拆分第一步——经济结算独立

- **`arpg/economy.gd`（新）**：`ArpgEconomy.settle()` 三段账目（还债 → 跨局统计 → 日租/欠租滚债）
  + `flavor_after()` 结算叙事。露塞提娅「账本」从 main._settle 拆出（main.gd 1240 → 1215 行）。
- **行为零变化**：151 断言原样全绿；autoplay PASS（52 杀 · 4 层 · **Lv7**——机器人终章前解锁大招实锤）。
- 后续拆分候选（保持小步+断言保护）：输入分发 / 楼层构建 / 压测钩子。

### 22.27 ✅ O 批（定时轮 5）：场景试玩 UI 入口 + README

- **选人画面每职业卡加「试玩手搭场景」按钮**（`hud.scene_mode` 通路 → `start_run` 进场景模式；
  命令行 `--scene` 已设则沿用其名，否则默认 `scene001`）——玩家从此点得到手搭关卡，不再依赖命令行。
- **`README.md`（新，仓库根）**：玩法动线（还债目标）/操作表/回归命令/架构速览——用户醒来第一文档。
- smoke 全绿。仓库推送断网中，后台循环重试（`feat/ui-scene-entry-readme` 分支）。

### 22.29 ✅ P 批（定时轮 6）：方案 B 最小版——Boss 层手搭圣所

- **`data/scenes/boss001.json`**：圆形圣所（半径 9.5 大圆 + 石板圈边 + 四角柱 + 南入口通道，350 地板格）。
- `build_floor` Boss 分支：`boss001.json` 存在即用（loader 后恢复 `boss_floor=true`——试玩语义与 Boss 层语义分离）；
  无文件回退随机 Boss 房。**方案 B 的嵌入思路已验证**：特殊房间 = 场景 JSON → ArpgDungeon 替换。
- ⚠️ **Boss 落点防卡墙**：rooms[0] 是大包围盒，右缘公式在圆形场景会把 Boss 放墙里——
  改用 `stair_cell`（loader 的 BFS 最远可走格），随机 Boss 房保持原公式（tile_ids 空时区分）。
- 验证：smoke_arpg **153 断言**全绿（圣所落点/地板格 2 条新断言）；渲染确认「地下 5 层★BOSS」血条+圆形布局。
- 推送断网，后台循环重试（`feat/boss-floor-scene`）。

### 22.31 ✅ Q 批（定时轮 7）：狼扑击——敌人动作多样性

- **wolf 扑击**（`balance.enemies.wolf.pounce_*` 全配置）：追击带 90~280px 且冷却好 →
  `lunge 620` 突进约 150px + 头顶红色「!」+ 低吼；伤害走贴脸后正常咬人（扑击=位移技能）。
- 模板层 `tpl_pounce/tpl_pounce_range/tpl_pounce_speed`——任何 melee 怪加 `pounce: true` 即获得扑击（扩展性）。
- ⚠️ **新踩坑**：`_melee_move` 里引用 think 的局部变量 `ev` → **mob_system 整类解析失败**（下游 count Nil 连环 162 条错误）。
  函数作用域内不可见外层局部量；且 mob_system 的 `_physics_process` 本在主线程，popup/音效直接调即可，不必走事件队列。
- 验证：smoke 全绿 · autoplay PASS（50 杀 · Lv6）。

### 22.33 ✅ R 批（定时轮 8）：章节卡仪式感 + 敌人受击挤压

- **R1 主线域**：「新任务解锁」升级**章节卡**（22 号大金字 + 暗底横条，普通完成保持 16 号小字）——
  toast 队列支持双形态样式分支（`is_chapter` 判前缀），章节推进有仪式感。渲染确认。
- **R2 美术域**：敌人受击 **squash & stretch**（flash 前半段横宽纵扁 1.18/0.82，SoA 渲染层纯变换）——
  命中瞬间的形体反馈，与白闪/击退/数字/顿帧叠加成完整打击链。
- 验证：smoke 151 断言全绿。**Q 批（狼扑击 PR#16）+ R 批（PR#17）均已合并**，main `1e314aa` 零积压。

### 22.35 ✅ S 批（定时轮 9）：P1-2 拆分第二步——输入路由独立

- **`arpg/input_router.gd`（新）**：`ArpgInputRouter.setup()`（InputMap 全部键位/手柄配置 85 行）
  + `unhandled(main, event)`（PLAY 态快捷键分发 + 暂停切换）。`main._unhandled_input` 收敛为薄转发层。
- main.gd **1234 → 1118 行**（P1-2 累计 **-116**：economy.gd + input_router.gd 两步）。
- 行为零变化（151 断言原样全绿）；autoplay 回归后台中。
- 后续拆分候选：楼层构建（build_floor 区 ~150 行）→ floor_builder.gd。

### 22.37 ✅ T 批（定时轮 10）：扑击家族——模板层扩展性实证

- **骑士盾冲**（500 速/5s cd/120-300px 重而远）+ **imp 急窜**（700 速/2.5s cd/80-200px 快而短）——
  同一 `tpl_pounce` 模板层**各一行配置**即得个性位移，框架「高度可扩展」主张实证。
- ⚠️ 修 bug：`pounce_cd` 写死从 wolf 模板读（骑士/imp 配了也用错值）→ 改按 `tpl_name[ti]` 自身模板读取。
- 验证：smoke PASS · autoplay PASS（50 杀 · 4 层 · Lv7）。
- S 批（input-router）后台推送中；两批合流后 main 即含 P1-2 两步拆分 + 扑击家族。

### 22.39 ✅ U 批（定时轮 11）：P1-2 第三步——楼层组装独立

- **`arpg/floor_builder.gd`（新）**：`ArpgFloorBuilder.build(main)` 三静态段（build：地牢来源决策+world 重建+
  成长搬运+重绑 / _populate：怪·箱·商人·祭坛·楼梯铺排 / _finish：PLAY 收尾）。main.build_floor 收敛为一行转调。
- main.gd **1118 → 963 行**（P1-2 三步累计 **-271 行**：economy / input_router / floor_builder）。
- ⚠️ 踩坑 #5 复现：`CameraDirector` 是 main 的 preload 常量非全局类——floor_builder 顶部 preload 修复
  （新拆分文件引用 main 的 preload 常量必须同样 preload）。
- 验证：151 断言全绿 · autoplay **PASS（48 杀 · 打穿 5 层 Boss · Lv8）**。
- **PR #19（扑击家族）+ #20（楼层拆分）均已合并**，main `d5853a4` 零积压。

### 22.41 ✅ V 批（定时轮 12）：装备强化（铁砧）——成长与经济双域

- **`balance.forge`**：`cost_base 30 × cost_mult 1.6` 递增定价 / 上限 +3 / 每级 +2 攻（全热重载）。
- **`rpg_state`**：`forge_level`（随存档往返）/ `forge_cost()` 递增定价 / `forge_item()` 校验链（非装备/上限/金币不足）。
- **`equip_bonus`**：已穿装备按 `+N × atk_per` 追加攻击——`eff_atk()` 动态反映，穿/脱立即生效。
- **商店第三页签「强化」**：背包+已穿装备的铁砧行（`+N` 显示/下一级费用/金币不足置灰/上限拦截）。
- **玩法意义**：金币的第二消耗出口——**「攒钱强化装备」vs「还债免利息」的露塞提娅式抉择**成立。
- ⚠️ **smoke 看门狗 40→120s**（断言累计增长后 40s 会误砍正常流程，曾误判为挂起）；强化断言曾撞名队友变量 f0（`int - 对象` 运行时错挂起后续）。
- 验证：smoke **157 断言**全绿（强化 4 条）。**PR #21 已合并**（main `63e12d0`）。

### 22.43 ✅ W 批（定时轮 13）：结算屏「继续经营」——日循环闭环

- 结算屏 primary 按钮「**继续经营 ▸ 下一局**」：金币/装备/强化等级/天数/债务跨局保留（rpg_state），
  点击直接 `start_run(同职业)` 开启下一天打捞——**露塞提娅日循环的闭环按钮**：
  打捞 → 结算（还债+租金）→ 强化/购物 → 继续经营 → ……十天还清 300G 的压力线完整成立。
- ⚠️ `_build_settle` 在 `_ready` 期早于 `rpg.setup`——按钮文本带 `game.rpg.day` 会 Nil 求值
  （报错不崩但脏），改静态文本，天数由开场日志呈现。
- 验证：smoke **157 断言**全绿。推送断网，后台循环重试（`feat/settle-continue-loop`）。

### 22.45 ✅ X 批（定时轮 14）：hud 按屏拆分第一步——结算屏独立

- **`arpg/hud_settle.gd`（新）**：`ArpgHudSettle` **屏组件模式**（持有 hud 引用：root 挂载点/`_label` 等工厂/
  `back_to_title` 信号/game）——settle 7 控件成员全部移入屏类，`hud.show_settle` 收敛为转调（main 调用点不变）。
- hud.gd **1750 → 1267 行**（-483）；`_menu_load_slot` 侧 settle_root 引用同步改 `hud.settle_screen.settle_root`。
- 验证：151 断言全绿 · autoplay PASS（结算屏路径实测：击杀 38 · 4 层）。**PR #23 已合并**（main `4a4ddbd`）。
- **按屏拆分模板确立**：后续商店/菜单/暂停屏照此模式（屏组件持有 hud 引用，控件成员归屏类）。

### 22.47 ✅ Y 批（定时轮 15）：hud 按屏拆分第二步——商店屏独立

- **`arpg/hud_shop.gd`（新）**：`ArpgHudShop` 屏组件——build/show/close/refresh/_forge_row/_refresh_tabs
  六方法 + 6 控件成员（买入/卖出/强化三页签 + 地牢商人暂停开关）。
- hud.gd **1267 → 1128 行**（X+Y 两步 **-622**）。
- ⚠️ **autopilot 引用连坐**：`main.hud.shop_root` → `hud.shop_screen.shop_root`（漏修则 326 条 Nil 连环，
  机器人商店检查卡死 → autoplay FAIL 击杀 0）。**拆屏后 grep 全项目旧成员引用是必做步骤**。
- ⚠️ **手术教训**：python 块切割用「注释标题」做边界会误伤（toast 区被复制出双份）——
  **必须按 `func` 边界正则切割**（cut_func 模式），切完 grep 全部函数名查重复。
- 验证：smoke **157 断言**全绿 · autoplay PASS（25 杀 · 商店闭环实测）。**PR #24 已合并**（main `f1244d0`）。

### 22.49 ✅ Z 批（定时轮 16）：hud 按屏拆分第三步——菜单屏独立

- **`arpg/hud_menu.gd`（新）**：`ArpgHudMenu` 屏组件——build/show/hide/refresh/_switch_menu_tab +
  状态/背包/技能/任务/系统五页签页面方法 + `_menu_use/_menu_claim/_rewards_text`。
- hud.gd **1128 → 870 行**（三步拆分 **1750 → 870，累计 -880**）。
- **自动化搬迁三坑**（正则批量前缀化的教训，全写入本节备查）：
  1. 函数定义 `func _page_xxx(` 被前缀化成正则误伤 → 定义与调用要分两轮处理；
  2. 本类互调被误加 `hud.` 前缀 → 互调还原轮；
  3. `var x := hud._label(...)` 经动态 Node 取值 `:=` 推断失败（踩坑 #2 变体）→ 显式类型轮。
- ⚠️ `_unhandled_input` 被误搬（切割范围覆盖到它）——剪回 hud 并修内部引用（menu_root→menu_screen.menu_root）。
- 验证：smoke **157 断言**全绿 · autoplay PASS（36 杀）。推送断网后台重试中。

### 22.51 ✅ AA 批（定时轮 17）：暂停屏独立——hud 按屏拆分收官

- **`arpg/hud_pause.gd`（新）**：`ArpgHudPause`（继续探索/撤退结算二选一）——四屏组件模式完整：
  **hud_settle / hud_shop / hud_menu / hud_pause**。
- hud.gd 手术后 1100 行（AA 基于 main 时 Z 批尚在分支——Z 合并后 hud 约 840 行）。
- 验证：smoke 157 断言全绿 · autoplay PASS（暂停路径实测）。
- ⚠️ **合并顺序**：`refactor/hud-menu-screen`（Z）先合、`refactor/hud-pause-screen`（AA）后合——
  两批动 hud.gd 不同函数区（菜单区 vs 暂停区），git 自动合并无冲突。
- 推送断网，后台循环重试中（两分支）。

### 22.53 ✅ BB 批（定时轮 18）：死亡焦痕 + 拆分连坐修复

- **美术域**：怪死留**暗色焦痕**（2.4s 淡出 + 缓慢扩大，`spawn_death_mark`）+ dissolve 粒子叠加——战场记忆感。
- **修 Z 批拆分连坐三处**：`_menu_ctx`（屏间共享上下文）恢复 hud；`_menu_row`（跨屏公共工厂）归位 hud
  （菜单屏/商店屏经 `hud._menu_row` 调用）；hud.gd 内部 `hud.` 前缀清理。
- **拆分公共方法归属原则**（新增）：**跨屏共用的工厂/上下文留 hud 基类，屏私有才进屏组件**。
- 验证：smoke 全绿（0 脚本错误）· autoplay PASS（42 杀）。BB 批后台重试推送中。

### 22.55 ✅ CC 批（定时轮 19）：铁砧火花 + 日循环开场叙事

- **美术域**：强化成功补**铁砧火花**（hit pxfx 金色 + 音效升级）——铁砧交互的形体反馈闭环。
- **主线域**：第 2 天起开场 toast「**第 N 天 · 债务 XG · 店租 20G/日**」——天数压迫感可视化（与结算屏记分簿首尾呼应）。
- 验证：smoke 全绿。CC 批后台重试推送中。

### 22.57 ✅ DD 批（定时轮 20）：日常委托——第 2 天起的稳定收入线

- **`balance.quests` 加 q_d1/q_d2**（`daily: true`）：每日 10 杀 35G / 每日 3 矿 25G+药——
  requires 挂在任务链上（一章后解锁日常）。
- **`economy.settle`**：日推进时 daily 任务重置（done/claimed → active，progress/notified 清零）——
  十天还债压力线的**收入侧补全**：任务链 590G（一次性）+ 日常 60G/日（可持续）。
- 验证：smoke **159 断言**全绿（载入+次日刷新 2 条）。**PR #29 已合并**（main `004d779`）。

### 22.59 ✅ EE 批（定时轮 21）：十天还债调平——蒙特卡洛验证

- **设计发现**：旧参数（债 300 + 任务链 590）经 `tests/sim_economy.gd`（新，1000 生涯蒙特卡洛）
  模拟——**全部第 1 天还清**，十天压力线形同虚设。
- **调平**：债 **1200** / 租 **30/日** / 任务链金币 **590→220**（Boss 大头转 xp 120 保值奖励感）；
  剧情文案同步「三百枚→一千二百枚」（arpg_events + economy.flavor）。
- **验证**：模拟器复跑——**100% 还清 · 中位第 5 天 · 分布 3~7 · 零失败**（目标区间 4~7 命中）；
  smoke 断言同步 1200 全绿 · autoplay PASS。
- **方法论入库**：经济调平用蒙特卡洛模拟器（tests/sim_economy.gd）扫参，不靠拍脑袋。

### 22.61 ✅ FF 批（定时轮 22）：宝箱房手搭贴片——方案 B 扩展

- **`data/scenes/patch_treasure.json`**：12×9 贴片（中央石坛 + 四 L 短墙 + 四角宝箱龛）。
- **`scene_loader.load_patch`**：轻量贴片接口（0=保留 / 1=强制地板 / 2=障碍变墙）——不走 ArpgDungeon 全量转换。
- **`floor_builder`**：宝箱房居中转印（**不印房间边缘**保走廊连通；贴片小于房间 -2 才启用）。
- 玩家感知：宝箱房有掩体地形 vs 普通矩形房——手搭内容直接改变战斗地形。
- 验证：smoke 全绿 · autoplay PASS（55 杀——掩体地形下机器人照常打穿）。**PR #30 已合并**（main `81ff8c6`）。

### 22.63 ✅ GG 批（定时轮 23）：全量视觉总检 + 三项修复

- **总检方法**：visual_mainline 全量渲染 + 视觉子代理审 5 帧（对话/战斗/商店/菜单）。
- **修复三项**：①拾取日志 `friend_2` → `unit_name` 显示名；②仲裁拒绝日志改控制台（内部调试图不进玩家 HUD）；
  ③**商店面板 660×500 恢复**（Y 批搬迁把固定 offset 改 anchors 后塌缩，货架不可见——渲染确认修复）。
- **渲染脚本帧位确定化**：商店/菜单段定时快照（不再依赖机器人进度漂移，漏拍问题根治）。
- **总检结论**：像素风/深蓝圆角/金色体系一致；审查误报澄清（队友蓝血条=配色语言、narrator 无头像=设计）。
- 验证：smoke 全绿 · 渲染确认。**PR #31 已合并**（main `60166d3`）。

### 22.65 HH 批（定时轮 24）：店铺被动营业——「开店」本质落地

- balance.shop_day：每日 65% 概率随机售出最多 4 件库存 goods（按标价全额收账）。
- economy.settle：库存 shuffle + 每件 75% 成交率 → 金币入账 + 售出日志。
- 风险收益差成型：摆着等顾客（标价全额，随机慢）vs 主动甩卖（0.6 折价，立即）——经营抉择第一层。
- 经营循环主体第一块拼图：打捞 → 上架 → 被动销售 → 金币 → 还债/强化。
- 验证：smoke 160 断言全绿（营业链路断言）。推送断网，后台循环重试中。

### 22.67 II 批（定时轮 25）：顾客偏好 + 残留变体

- 经济：shop_day.preferences 品类成交率乘数（药水 1.2 好卖 / 矿石 0.8 / 宝石 0.5 难卖）——
  **上架什么有讲究**，经营策略深度第一层（同一批货不同卖法）。
- 美术：死亡残留分级——普通暗痕 / 精英金痕 / Boss 紫大痕（战场记忆的等级语言）。
- 验证：smoke 全绿。推送断网后台重试中（feat/shop-preference-marks）。

### 22.69 JJ 批（定时轮 26）：今日行情提示——经营策略信息层

- 商店卖出页签顶部：「**今日行情：回复药水 最好卖 · 宝石 无人问津（上架有讲究）**」——
  偏好加权（II 批机制）+ 行情提示（本批信息）= 玩家可感知可决策的经营闭环。
- 验证：smoke 全绿。II/JJ 两批推送断网后台重试中（两分支）。

### 22.71 KK 批（定时轮 27）：行情每日波动——动态读盘

- `rpg.market_mod`：每品类今日乘数（静态偏好 ±0.25 扰动，clamp 0.3~1.4，随存档往返）。
- economy：日推进生成今日行情；成交判定读动态值（无行情回落静态偏好）。
- hud_shop：行情提示切动态值——玩家每天重新读行情，策略从「记公式」变「看盘」。
- 验证：smoke **160 断言**全绿。**PR #35 已合并**（II 批 PR #34 亦合并）。

### 22.73 LL 批（定时轮 28）：贴片池 + 开场行情提示

- **`patch_story.json`**：前人书房贴片（4 层专属——书台十字障碍+书架列，剧情发生地地形化）。
- **贴片池**：floor_builder 按 patch 的 `min_floor` 字段数据驱动选择（深层 story / 浅层 treasure）——
  **新贴片只加一个 JSON 文件**即生效，扩展成本降到数据级。
- **开场行情 toast**：day>1 时追加「今日行情：XX 最好卖（N 倍）」——KK 动态行情的玩家侧入口
  （地牢里就能规划今日上架策略，不必进店看）。
- 验证：smoke 全绿。推送断网后台重试中（feat/patch-pool-market-toast）。

### 22.75 MM 批（定时轮 29）：营业日报——结算屏聚合

- economy.settle 收集 shop_lines（笔数/金额/品名）；main._settle 明细并入结算屏商品清单——
  一屏看全「打捞战利品 + 店铺营业」双线收入（经营感知聚合）。
- 验证：smoke 160 断言全绿。推送断网后台重试中（feat/shop-daily-report）。

### 22.77 ✅ NN 批（定时轮 30）：三十轮里程碑——全量总验收

**四层回归全绿**：smoke_arpg **160 断言** / 战棋 29 / creator / autoplay（30 杀 · 3 层 · Lv5）/
万敌 **126.6 FPS**（基线 ≥50）。

**PR #6~#37 全部合并**（main `686ab17` 零积压）。三十批改动一览：

| 域 | 交付 |
|---|---|
| 主线 | 5 章任务链（requires）/ 6 剧情节点（arpg_events 独立文件）/ Boss 三段对话+二阶段狂暴 / 手搭场景三层（整层/圣所/贴片池）/ 章节卡 |
| 战斗 | 暴击管线 / 全怪伤害数字 / 词缀精英（4 词缀）/ 狼·骑士·imp 扑击家族 / Boss 召唤+16 向弹幕 / 焦痕残留+受击挤压 |
| 成长 | 债务 1200+租金 30（蒙特卡洛调平中位第 5 天还清）/ 日常委托（日刷新）/ 铁砧强化（+3/递增价）/ 魔王徽记 / 跨局成就 / 顾客偏好+行情波动 |
| 美术 | 图块视觉接入 / 12 pixelfx / 章节卡 / 焦痕分级 / toast 双形态 / 日志底板 / 商店三页签 / 视觉总检双轮 |
| 框架 | economy/input_router/floor_builder 三拆分 + hud 四屏组件（main+hud **-616 行**）/ 蒙特卡洛模拟器 / gh_pr SSL 通道修复 |

**playtest 记录**：autoplay 多轮 PASS（最高 55 杀 · 4 层 · Lv8）· 喝药/商人/祭坛/入队全链路实测。

### 22.79 OO 批（定时轮 31）：冰霜词缀——第六词缀

- `affixes.frost`（slow 1.5s）：EV_BITE 命中玩家 → `player.slow_t`（移速 ×0.6 冻僵观感）+ 蓝字「冻结！」popup。
- player 状态机加 slow_t（衰减/移速乘区）——**状态效果管线的第一个状态**（易伤/燃烧可照此扩展）。
- 验证：smoke **160 断言**全绿（词缀断言同步 5 词缀）。**PR #38 已合并**（main `9d4fcde`）。

### 22.80 下一轮接续点（最新）

1. 状态效果扩展：易伤（hurt_amp）/燃烧（DoT）照 slow_t 模式。
2. 店铺营业深化：顾客到访动画；行情每日波动已上线（KK 批）。
3. 美术域：扑击蹲伏帧；冻结变蓝（modulate 冷色）。
4. **实机走查**：冰霜冻结体感 + 全系统。



1. **实机走查**（人工手感）：菜单五页签/强化/祭坛/商人/行情/焦痕——自动化覆盖不了的观感与手感。
2. 玩法内容继续：店铺顾客到访动画；剧情房贴片；更多词缀（吸血/易伤）。
3. R2 方向：经营深化（店铺摆设/顾客偏好成长）、多地牢主题、伤害管线元素属性。
4. 技术债：main.gd 963 行（可继续拆）；srpg/ 去留决策。



1. MM 批推送合并（后台重试中）。
2. 店铺营业深化：顾客到访动画；剧情房贴片。
3. 美术域：扑击蹲伏帧；残留粒子化。
4. 实机走查：营业日报观感 + 全系统手感。



1. LL 批推送合并（后台重试中）。
2. 店铺营业深化：顾客到访动画/营业日报（结算屏聚合当日售出明细）。
3. 美术域：扑击蹲伏帧；残留粒子化。
4. 实机走查：贴片地形体感 + 行情提示节奏。



1. 店铺营业深化：热门商品 HUD 常显（非进店才看）；剧情房贴片。
2. 美术域：扑击蹲伏帧；死亡残留粒子化。
3. **实机走查**：行情波动体感 + 全系统手感。



1. II/JJ 批推送合并（后台重试中）。
2. 店铺营业深化：行情每日波动（±0.2 随机扰动存 rpg）；剧情房贴片。
3. 美术域：扑击蹲伏帧；死亡残留粒子化。
4. 实机走查：行情提示 + 偏好策略体感。



1. II 批推送合并（后台重试中）。
2. 店铺营业深化：热门商品提示（HUD 显示本日顾客偏好）；剧情房贴片。
3. 美术域：扑击蹲伏帧；死亡残留粒子化（Sprite→粒子更柔和）。
4. 实机走查：偏好策略体感 + 各系统手感。



1. HH 批推送合并（后台重试中）。
2. 方案 B 扩展：剧情房贴片；店铺营业深化（顾客偏好/热门商品加权成交率）。
3. 美术域：死亡残留变体（精英金痕/Boss 大痕）。
4. 实机走查：被动营业日志节奏 + 继续经营循环 + 各屏。



1. CC 批推送合并（后台重试中）。
2. 方案 B 扩展：宝箱房/剧情房手搭贴片；店铺营业日（顾客/卖货）。
3. 美术域：死亡残留；强化铁砧火花。
4. **实机走查**：菜单五页签 + 继续经营循环 + 强化页签 + 各系统手感。
5. P1-2 框架成熟度已达 Demo 期目标——**下一阶段重心回玩法内容**（经营深化/更多手搭关卡）。
