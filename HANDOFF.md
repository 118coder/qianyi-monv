# 千亿魔女 · 交接文档（HANDOFF）

> 最后更新：与本文档同一提交。**新会话/新开发者从这里开始读完即可接手。**
> 项目根：`E:\游戏制作` · Godot 4.7.2 · 单机商业游戏方向：露塞提娅式「店铺经营 + 地牢 ARPG」

---

## 1. 一页现状

- **两条产品线一个仓库**：`arpg/`（主产品：地牢 ARPG，露塞提娅式）+ `srpg/`+`editor/`（战棋原型与地图编辑器，已可复用其地图管线）。战棋已完整可玩、测试全绿；**主产品是 ARPG**。
- **已完成并验证**：地牢 ARPG 战斗闭环（3 职业/6 敌+Boss/随机地牢5层/宝箱陷阱/背包/升级/商店/任务/装备/存档v2/角色菜单）、AI 队友+主控切换+APC 框架、**敌我 AI 寻路/索敌系统升级**（✅ 2026-11-03，见 §9）、万敌压测（10000 敌 95~135FPS）、手柄+震动、热重载（balance.json 保存即生效）、节点式事件编辑器+AI状态机可视化+系统数值面板、**事件引擎已接线**（✅ 2026-11-03 恢复，见 §2）、自动化测试（ARPG 冒烟 119 项 / 战旗 29 项 / 自动驾驶整局 PASS / 万敌基准 ≥50FPS）。
- 编辑器本体 exe 不在仓库（见 §7）；启动用根目录的 4 个 .bat。

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
├── player.gd              玩家：移动加速度/普攻/技能v2(use_skill)/装备派生(eff_atk/eff_def)
├── friend_unit.gd         AI 队友+APC 基类（软分离/跟随/战斗/卡住传送）
├── mob_system.gd          数据导向敌群：SoA+空间哈希+多线程+LOD+批次渲染（万敌 70FPS）
├── proj_system.gd         投射物数据系统（箭/法弹/弹幕，哈希命中）
├── pickup_system.gd       掉落数据系统（稳定 ID，供仲裁）
├── world.gd               世界门面：地块渲染/墙碰撞/特效池(上限64)/楼梯传送门
├── dungeon_gen.gd         随机地牢生成（房间走廊/Boss层/斗兽场）
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
└── main.tscn              唯一场景（其余全代码构建）
core/                      与玩法无关的基座
├── events/event_system.gd 事件运行时 v2（嵌套IF/camera/wait/fx/music/give/win/lose）
├── settings/settings.gd   设置（user://settings.cfg，音量走总线）
├── audio/audio_manager.gd 总线(Master/Music/SFX)+BGM交叉淡入+音效池
├── save/save_system.gd    存档 v2（3 槽位 + 元信息）
└── l10n/strings.gd        字符串表（L10n.text(key, fallback)）
editor/                    地图/事件/AI/数值 编辑器（节点式事件图）
srpg/                      战棋原型（完整可玩，与编辑器共用 map JSON 管线）
docs/                      系统设计 + 本蓝图 + 交接文档
tests/                     smoke(战旗29/ARPG87) + 自动驾驶 + 渲染验证脚本 + gen_balance
assets/                    RPG Maker 素材（tiles/chars/fx/se/bgm）⚠️许可见 §7
data/                      balance.json（全部数值）+ maps/map001.json（地图+事件）
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

- **运行**：`运行游戏.bat`（或 F5）；**编辑器**：`打开编辑器.bat`（= exe 加 `-e`）
- **测试**（全绿基线：ARPG 102 / 战旗 29 / 自动驾驶 PASS / 万敌基准 ≥50FPS）：
  ```
  "D:/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe" --headless --path "E:/游戏制作" -s res://tests/smoke_arpg.gd
  ... -s res://tests/smoke.gd
  ... --headless --path "E:/游戏制作" -- --autoplay            # 机器人打通整局
  ... --path "E:/游戏制作" -- --stress=10000 --bench=15         # 万敌基准(≥50FPS 退出码0)
  ```
- **渲染验证 UI**：`--write-movie "<目录>\\x.png" --fixed-fps 10 --quit-after N -s res://tests/visual_ui.gd`（注意：movie 模式 HUD 的 FPS 数字是磁盘 IO 假象）
- **热重载**：改 balance.json 保存即生效；地图改完按 F3；脚本按 F4 重开（或编辑器 F5 调试热替换）
- **提交**：git 已初始化（远端 github.com/118coder/qianyi-monv 私有），`.godot/` 与 exe 已忽略

## 6. 踩坑清单（新会话必读）

1. **GDScript 撞名静默坑（已踩 5 次）**：成员/静态函数名撞 Object 内置（`reload/get/tr/alive`）→ 编译器只报"无法解析外部成员"甚至完全不报。命名前先想 `Object/Node` 内置；报错排查先 grep 类内是否重名。
2. **`:=` 推断坑**：无类型字典/数组元素参与表达式时 `var x := ...` 会解析失败。凡来自 `Dictionary`/`Array` 的值一律显式 `var x: Type =`。
3. **bash heredoc 长度限制**：>12KB 的内联脚本会被截断。大补丁一律用 Write 工具写 .py 再执行。
4. **PowerShell 内联中文**：UTF-8 无 BOM 会被当 GBK。脚本文件先加 BOM（`sed -i '1s/^/\\xef\\xbb\\xbf/'`）或用 python。
5. **事件命令的调用者**：`SrpgEventSystem` 是战旗+ARPG 共用；新增命令若引用 ARPG 专属成员（main.rpg 等），战旗事件不要使用该命令即可（动态分发，编译无碍）。
6. **RPG Maker 素材许可**：assets/ 全部来自用户已购的 RM 素材与示例工程；**仓库保持私有**，公开/商用前需替换。
7. **movie 模式**：HUD 的 FPS 是写盘 IO 假象；真实帧率用 `--bench` 模式测。

## 7. 路线图（详见 docs/商业架构蓝图.md）

- **R1（下一批）**：~~P0 事件接线恢复~~（✅ 2026-11-03 完成，见 §2）→ **main.gd/hud.gd 拆分（流程状态机 + 每屏一脚本）** → 仓库分离决策（srpg/ 去留）
- **R2 玩法期**：经营主循环（天/租金/还债 + 店铺营业 MVP）→ 伤害管线（暴击/元素/状态效果）→ 内容校验扩展
- **R3 内容期**：任务链/叙事/多地牢主题/成就/本地化执行
- **R4 发布期**：Steam/无障碍/Demo
- **待拍板**：队友背包独立 or 共享｜死亡惩罚强度｜srpg 去留｜付费形态

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
