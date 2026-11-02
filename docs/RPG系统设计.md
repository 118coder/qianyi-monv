# 千亿魔女 · RPG 核心系统设计 v1.0

> 本文档对应 `arpg/` 内已实现的八大系统。所有数值走 `data/balance.json` 热重载；
> 所有玩家可见状态走 HUD/菜单；所有持久化走 `ArpgSaveSystem`（user://save.json v2）。

## 0. 总览与数据流

```
ArpgBalance(balance.json, 热重载)
        │ 数值/模板/任务/商店货架
        ▼
ArpgRpgState ──► ArpgInventory ──► 装备槽 ──► 属性加成(eff_atk/eff_def/HP)
   │  gold                │
   │                      ▼
   │             PickupArbiter（谁捡）
   ▼                      ▼
ArpgQuestManager ◄── 事件钩子(kill/collect/reach_floor)
   │ 奖励
   ▼
ArpgShop（金币↔物品） ──► HUD 菜单/商店界面
        ▼
ArpgSaveSystem（F9/F10 全量往返）
```

## 1. 背包系统（`inventory.gd` / `ArpgInventory`）

**用途**：统一承载消耗品、商品、装备的持有；是拾取、商店、任务奖励、使用/装备的唯一数据源。

**核心功能**：堆叠添加（同类一格，上限99）、按数量原子移除（不足整体失败）、容量校验、UI 行生成。

**关键数据结构**：`slots: Array[{id, count}]` + `cap`（容量来自 balance.bag_cap，默认 20 格）。

**界面交互**：角色菜单-背包页（使用/装备/丢弃按钮）；队伍与玩家共享背包（拾取仲裁分配）；背包满时拾取留地并节流提示。

**关联**：拾取仲裁（写入）、商店（买=加/卖=删）、任务 collect 目标、药水快捷键 Q、装备穿戴来源、存档 v2 序列化。

## 2. 升级系统（`player.gd / friend_unit.gd` + balance.xp_*）

**用途**：地牢内成长与续航（策划案核心爽点：升级完全回满）。

**核心功能**：经验入账 → 曲线 `xp_need = xp_base + level*xp_per_level` → 升级加成（per-char growth）→ HP/SP 全满 → 技能解锁检测并弹出提示。

**关键数据结构**：单位 `level/xp`；balance：`xp_base/xp_per_level/growth{hp,atk}/skills.unlock_level`。

**界面交互**：升级时 world 内 "LEVEL UP!"/解锁技能飘字 + 金色 nova + 震动；角色菜单-状态页显示经验进度。

**关联**：任务奖励 xp、商店无直接关联、技能系统按等级解锁、存档记录 level/xp。

## 3. 装备系统（`rpg_state.gd` + balance.equipment）

**用途**：地牢外Build（店铺购买→下地穿装），数值成长之外的第二轴。

**核心功能**：三槽位（weapon/armor/trinket）；穿戴（背包→槽，旧装回包，容量满原子回滚）；卸下；加成计算 `equip_bonus(atk/def/hp/sp)`；玩家派生属性 `eff_atk/eff_def/recalc_equipment`；受击减伤 `max(1, dmg - eff_def)`。

**关键数据结构**：balance.equipment `{id: {name, slot, atk/def/hp/sp, price, tier}}`；`equipped: {slot: item_id}`；装备本体存于背包（穿戴=从背包移入槽）。

**界面交互**：角色菜单-状态页（槽位+卸下按钮）、背包页（装备按钮）；商店买入装备类直接入包。

**关联**：背包（来源）、商店（购买）、战斗结算（攻防）、存档。MVP 仅玩家可穿（队友预留）。

## 4. 技能系统 v2（`player.gd.use_skill` + balance.skills/char_skills）

**用途**：角色差异化与操作上限；数据驱动后新技能=JSON 加一条。

**核心功能**：per 职业技能表（char_skills）+ 等级解锁（unlock_level）；行为种类 kind：`dash / volley / nova / heal`（新增技能=新 kind + 新行为分支）；消耗 SP、独立 CD、伤害倍率 dmg_mult。

**关键数据结构**：balance.skills `{id: {name, kind, unlock_level, sp, cd, dmg_mult, heal, desc}}`；char_skills `{char_id: [skill_id,...]}`。

**界面交互**：K=技能1、L=技能2（手柄 X·LT）；SP 不足飘字；角色菜单-技能页列出全部（未解锁灰字+解锁等级）。

**关联**：升级系统（解锁）、装备（eff_atk 加成）、SP/冷却、队友 AI（同表取第一个解锁技能，消耗品保守策略同理）。

## 5. 任务系统（`quest_manager.gd` + balance.quests）

**用途**：给地牢循环提供短期目标与额外奖励；事件驱动零侵入。

**核心功能**：目标类型 `kill`（target=模板id/boss/any）、`collect`（物品id）、`reach_floor`；状态机 active→done→claimed；奖励 gold/xp/item；完成 toast + 日志。

**关键数据结构**：balance.quests `{qid: {name, desc, type, target, count, rewards}}`；运行态 `quests[qid] = {state, progress}`。

**界面交互**：完成时顶部 toast + 日志；角色菜单-任务页（进度/奖励/领取按钮）。

**关联**：击杀结算、拾取、楼层推进三类事件钩子；奖励走背包/金币/经验；存档。

## 6. 商店系统（`shop.gd`）

**用途**：经营循环的地面端——战利品变现金、现金变补给，形成「进货风险投资」闭环。

**核心功能**：卖出（goods 按 value×sell_ratio、装备按 price×sell_ratio，支持一键卖全部）；买入（固定货架 always+tier2/tier3，金币校验、容量校验，含错误文案）；价格 `price_of`（商品=value×2，装备=price）。

**关键数据结构**：balance.`shop_stock{always/tier2/tier3}`、`sell_ratio`；交易即时改 gold/inventory。

**界面交互**：结算屏「进入店铺」/标题「店铺（试营业）」；买/卖两页签+金币+滚动列表+离开；「一键卖出战利品」快捷键在结算屏。

**关联**：背包（双向）、金币、装备（买入即可能穿戴）、任务 collect（买也算收集——设计上允许，杜绝卡任务）。

## 7. 存档系统 v2（`save_system.gd`）

**用途**：跨会话持久化全部 RPG 进度（需求 §9：读档后队伍/指令/任务一致）。

**核心功能**：user://save.json，version=2；保存 RPG 全量+玩家属性+队伍（稳定 uid）+楼层/击杀+主控；读档按序重建楼层→灌状态→恢复主控；版本过新/损坏有明确文案。

**关键数据结构**：`{version, char_id, floor, kills, rpg{gold,inventory,equipped,quests}, player{...}, party{...}, possessed_uid}`。

**界面交互**：F9/F10 + 系统页按钮；日志反馈成败。

**关联**：聚合所有系统（背包/装备/任务/金币/队伍/楼层）。

## 8. 角色菜单界面（`hud.gd` 菜单/商店 UI）

**用途**：所有 RPG 系统的统一操作入口；暂停游戏保证操作安全。

**核心功能**：五页签（状态/背包/技能/任务/系统）；所有按钮直接驱动上述系统并即时刷新；C/Esc 关闭；打开时 `get_tree().paused`。

**关联**：引用全部系统（menu_snapshot 注入 rpg/player/party/quests/shop/save_sys）。

## 实现顺序与整合方案（已按此执行）

1. **背包**（一切的数据地基）→ 2. **金币+升级扩展**（经济与成长闭环）→ 3. **装备**（背包的消费出口）→ 4. **技能 v2**（数据驱动化）→ 5. **任务**（事件钩子最薄的一层）→ 6. **商店**（金币↔物品兑换）→ 7. **存档 v2**（聚合所有状态）→ 8. **菜单 UI**（把 1-7 装进界面）。

整合原则：**所有系统只读 ArpgBalance（热重载）+ 读写 ArpgRpgState（单一事实源）**；系统间不直接互相引用数据结构，统一经由 rpg_state 的 API；UI 层只调用系统 API 不持有关卡引用。
