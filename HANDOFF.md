# 千亿魔女 · 交接文档（HANDOFF）

> 最后更新：与本文档同一提交。**新会话/新开发者从这里开始读完即可接手。**
> 项目根：`E:\游戏制作` · Godot 4.7.2 · 单机商业游戏方向：露塞提娅式「店铺经营 + 地牢 ARPG」

---

## 1. 一页现状

- **两条产品线一个仓库**：`arpg/`（主产品：地牢 ARPG，露塞提娅式）+ `srpg/`+`editor/`（战棋原型与地图编辑器，已可复用其地图管线）。战棋已完整可玩、测试全绿；**主产品是 ARPG**。
- **已完成并验证**：地牢 ARPG 战斗闭环（3 职业/6 敌+Boss/随机地牢5层/宝箱陷阱/背包/升级/商店/任务/装备/存档v2/角色菜单）、AI 队友+主控切换+APC 框架、万敌压测（10000 敌 70FPS）、手柄+震动、热重载（balance.json 保存即生效）、节点式事件编辑器+AI状态机可视化+系统数值面板、自动化测试（ARPG 冒烟 87 项 / 战旗 29 项 / 自动驾驶整局 PASS）。
- **🔴 唯一 P0 缺口**：`arpg/main.gd` 缺少**事件引擎接线**的 6 小段代码（约 60 行，详见 §3，恢复代码已写好可直接粘贴）。缺它的后果：balance.json 里写的**事件**（开场对话/增援/镜头演出）在游戏里不触发；编辑器做的事件无法试玩。**其余一切功能正常**（自动测试全绿不覆盖事件触发，所以此前未被发现）。
- 编辑器本体 exe 不在仓库（见 §7）；启动用根目录的 4 个 .bat。

---

## 2. 🔴 P0：事件引擎接线恢复（10 分钟）

### 症状
事件系统运行时（`core/events/event_system.gd`，类 `SrpgEventSystem`）完整且编译通过，但 `arpg/main.gd` 从未实例化它，也没有触发钩子。地图 JSON 里配置的事件不会在游戏中出现。

### 恢复步骤（4 处改动）

**① `arpg/main.gd` 类成员区（`var player_combat_t := 0.0` 附近）加：**
```gdscript
var events: SrpgEventSystem
```

**② `arpg/main.gd` `_ready()` 中（`save_sys.setup(self)` 之后）加：**
```gdscript
	events = SrpgEventSystem.new(self)
```

**③ `arpg/main.gd` 加两个函数（事件入口 + 事件胜利/失败；放在 `_settle` 附近）：**
```gdscript
## 开局横幅后触发"回合开始"事件（开场对话等）
func _intro() -> void:
	await get_tree().create_timer(0.3).timeout
	await ui.show_banner("第 %d 回合 · 玩家行动" % turn, Color(0.16, 0.32, 0.65))
	await events.on_phase_start("player", turn)


## 事件命令 win/lose 的落点
func _game_over(win: bool) -> void:
	_settle(win, "凯旋而归！" if win else "倒在了地牢里……",
		"带着战利品返回了地面。" if win else "商品在逃亡中散失了一半。")


## 事件命令 spawn 的落点（与压测刷怪共用世界）
func spawn_units(tpl_id: String, cells: Array) -> void:
	var tpl: Dictionary = ArpgBalance.ITEMS.get(tpl_id, {})
	if ArpgBalance.ENEMIES.has(tpl_id):
		for c in cells:
			var cell := Vector2i(int(c[0]), int(c[1]))
			if dungeon.is_floor(cell) and world != null:
				world.spawn_mob(tpl_id, cell, false, false)
				world.spawn_nova(ArpgDungeon.cell_to_pos(cell), Color(0.65, 0.9, 1.0))
```
**④ 触发钩子**（2 处）：
- `_settle()` 开头加：`if events != null: events.on_reach_floor(floor_no)`（reach_floor 类事件的兜底；正常推进已由 build_floor 内 `quests.on_reach_floor` 覆盖任务侧）
- 玩家格子变化时（`_process` 里缓存玩家 cell，变化即调）：
```gdscript
	if events != null and player != null and player.cell != _last_player_cell:
		_last_player_cell = player.cell
		events.on_unit_moved(player)
```
（成员 `var _last_player_cell := Vector2i(-99, -99)`；`on_unit_moved` 内部有 zone 矩形过滤，重复调用安全）

### 验证
- 冒烟已含：嵌套 IF/镜头调度/等待/给金币 均通过（见 tests/smoke_arpg.gd 第 11 节）
- 手动：F5 开局应弹出开场对话（map001.json 事件 1）；把事件 1 的 turn 改成 2 可验证回合触发
- 注意：`map001.json` 事件 2（第 3 回合增援）使用 `spawn`，走 §3 恢复代码里的 `spawn_units`

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
| 胜负 | 凯旋=Boss死→传送门→`_settle(true)`；团灭→`on_player_dead`→`_settle(false)`；事件 win/lose→`_game_over`（待恢复 §2） |
| 存档 | `save_sys.save_game(slot)/load_game(slot)/slot_meta(slot)` |
| 设置 | `settings.set_value(key, v)`（音量/震屏/震动即时生效） |
| BGM | `audio.play_music("title/dungeon/town/boss")` |

**平衡开关位置**（都在 balance.json）：陷阱率 45%、精英率 12%、卖价 60%、经验曲线、仇恨半径 185、传送召回 2.5s、队伍容量 8、切换冷却 1.5s。

---

## 5. 工作流

- **运行**：`运行游戏.bat`（或 F5）；**编辑器**：`打开编辑器.bat`（= exe 加 `-e`）
- **测试**（全绿基线：ARPG 87 / 战旗 29 / 自动驾驶 PASS）：
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

- **R1（下一批）**：P0 事件接线恢复（§2）→ main.gd/hud.gd 拆分（流程状态机 + 每屏一脚本）→ 仓库分离决策（srpg/ 去留）
- **R2 玩法期**：经营主循环（天/租金/还债 + 店铺营业 MVP）→ 伤害管线（暴击/元素/状态效果）→ 内容校验扩展
- **R3 内容期**：任务链/叙事/多地牢主题/成就/本地化执行
- **R4 发布期**：Steam/无障碍/Demo
- **待拍板**：队友背包独立 or 共享｜死亡惩罚强度｜srpg 去留｜付费形态

## 8. 关键决策记录

- 队伍/AI/事件/数值全部**配置化**（balance.json + party 段），无硬编码 8
- 敌群走 SoA 数据层（非节点），上限 12000；队友/AI 走节点（少量富行为）
- UI 全代码构建（可无头测试），token 层 + 控件工厂在 hud.gd 顶部
- 测试即回归：改任何系统后跑三层测试（smoke/autoplay/bench）是硬性流程
