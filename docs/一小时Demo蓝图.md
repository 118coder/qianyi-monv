# 一小时 Demo 蓝图（2026-11-07）

> 目标：一条约 60 分钟的完整可玩流程，验证「章节推进 / 任务链 / 剧情节点 / 关卡编排」四大主线系统能力。
> 原则：**不加新大系统**，全部用现有事件引擎（13 命令）+ 任务管理器 + balance.json 编排。

## 1. 叙事框架（贴露塞提娅式经营主循环）

玩家是欠下巨债的「打捞人」，进入**千渊地牢**打捞遗物还债。
债主期限、地牢深处的低吼、前人留下的笔记，三段线索把 5 层地牢串成起承转合。

## 2. 章节结构 = 任务链（requires 前置）

| 章节 | 任务 | 类型 | 前置 | 奖励 | 剧情节点 |
|---|---|---|---|---|---|
| 序章 | q_intro「进入千渊」 | reach_floor 1 | — | 50G | T1 债主通牒（开场对话） |
| 一章 | q_hunt「清剿鼠群」 | kill any ×8 | q_intro | 60G+药×2 | T1 区zone·前人遗骸 |
| 二章 | q_ore「矿脉打捞」 | collect ore ×5 | q_hunt | 80G+装备 | T2 低吼事件 |
| 三章 | q_depth「深入四层」 | reach_floor 4 | q_ore | 100G | T3 增援（已有）/ T4 前人笔记 |
| 终章 | q_boss「讨伐守窟者」 | kill boss | q_depth | 300G | T5 Boss 战前对话；Boss 死→结局对话→win |

- 完成任务自动解锁下一个（HUD 任务页只显示已解锁+已完成）。
- Boss 死亡用事件引擎 `unit_death` 触发器接结局剧情（已支持该触发器，从未用过——Demo 首用）。

## 3. 引擎改动清单（预计 <80 行）

1. **kill 任务接线**：`main.on_mob_dead()` 补 `quests.on_kill(target_id)`（quest_manager.gd:13 定义了但全项目无人调用）。
2. **任务 xp 入账**：`rpg_state.quest_claim()` 现在只把 xp 拼进文本（rpg_state.gd:92-93），补 `gain_xp` 调用。
3. **任务链 requires**：`quest_manager` 加 `is_unlocked(qid)`（前置 done 才可见/激活）；`balance.json.quests` 加 `requires` 字段（无则为空）。
4. **事件命令 `give_xp`**：event_system.gd 加一个 match 分支（给剧情奖励经验），编辑器调色盘同步。
5. **存档**：quests 状态已在 `rpg.quests` 段随存档走（to_dict/from_dict 已有），`requires` 无需额外迁移。

## 4. 关卡编排（data/maps/map001.json events 段）

| turn(=楼层) | 触发器 | 内容 |
|---|---|---|
| 1 | turn_start | 序章对话：债主通牒（3~5 行） |
| 1 | zone | 「前人遗骸」小剧情 + give_item 药水 |
| 2 | turn_start | 低吼过场（1 行横幅 + 对话）+ music 切换 |
| 3 | turn_start | 增援事件（已有，保留） |
| 4 | turn_start | 前人笔记：Boss 弱点提示 + give_xp |
| 5 | turn_start | Boss 战前对话（警告 + heal_full 商量） |
| 5 | unit_death boss | 结局对话 → win |

## 5. 数值时长校准（目标 55~70 分钟）

- 每层 10~12 分钟：普通层怪数 12→16→20→24 递增，Boss 层 1+2。
- 等级节奏：1 层出 Lv2 / 2 层 Lv3 / 3 层 Lv4~5 / 4 层 Lv5~6 / Boss 战 Lv6~7（witch 的 meteor Lv6 解锁，终章能用到）。
- 金币：任务链总奖励 ~590G + 掉落 ≈ 结算时还债 20~30%（Demo 留悬念，正式版继续还）。

## 6. 验收口径

1. `smoke_arpg` 全绿（新增：kill 任务推进、requires 解锁、give_xp 命令各至少 1 断言）。
2. `--autoplay` PASS（机器人打完整链路）。
3. 手动：新档 → 序章对话 → 任务页只见 q_intro → 完成后 q_hunt 自动出现 → 杀怪推进 → Boss 死触发结局对话 → 结算屏。

## 7. 本蓝图不改的

- 经营主循环（天/租金）——R2 再做，本 Demo 结算屏即「还债节点」雏形。
- 伤害管线（暴击/元素）——另一个 PR，不与主线混。
- 地图 JSON 的 rows/placements（战棋共用管线，别动）。
