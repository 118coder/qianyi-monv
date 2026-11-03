# 千亿魔女 · 交接文档（HANDOFF）

> 最后更新：与本文档同一提交。**新会话/新开发者从这里开始读完即可接手。**
> 项目根：`E:\游戏制作` · Godot 4.7.2 · 单机商业游戏方向：露塞提娅式「店铺经营 + 地牢 ARPG」

---

## 1. 一页现状

- **两条产品线一个仓库**：`arpg/`（主产品：地牢 ARPG，露塞提娅式）+ `srpg/`+`editor/`（战棋原型与地图编辑器，已可复用其地图管线）。战棋已完整可玩、测试全绿；**主产品是 ARPG**。
- **已完成并验证**：地牢 ARPG 战斗闭环（3 职业/6 敌+Boss/随机地牢5层/宝箱陷阱/背包/升级/商店/任务/装备/存档v2/角色菜单）、AI 队友+主控切换+APC 框架、**敌我 AI 寻路/索敌系统升级**（✅ 2026-11-03，见 §9）、**多目标取景镜头 + 队友 AI 行为重做**（✅ 2026-11-03，见 §10）、万敌压测（10000 敌 95~135FPS）、手柄+震动、热重载（balance.json 保存即生效）、节点式事件编辑器+AI状态机可视化+系统数值面板、**事件引擎已接线**（✅ 2026-11-03 恢复，见 §2）、自动化测试（ARPG 冒烟 119 项 / 战旗 29 项 / 自动驾驶整局 PASS / 万敌基准 ≥50FPS）。
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
8. **按节拍调用的函数别拿 `delta` 当计时器**：`ai.think()` 每 0.15s 才跑一次，传进来的是某一帧的
   帧时长（≈16ms）。用它累加计时会慢约 9 倍（旧卡住判定就是这么废掉的）。要计时就用墙钟
   （`_tick_delta()` 取「距上次 think 的真实时长」）。
9. **新脚本的 `class_name` 不在 `global_script_class_cache.cfg` 里**时，其它脚本直接引用类型会解析失败。
   跨脚本引用新类优先用 `const X := preload("res://...")`（`main.gd` 引 `camera_rig.gd` 即此做法）。

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
