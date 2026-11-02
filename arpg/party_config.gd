class_name ArpgPartyConfig
extends RefCounted
## 队伍 / AI 队友 / 主控切换 / APC 全部配置（需求书 §4：配置化优先，禁止硬编码 8）。
## 改这里即可调平衡，不改逻辑代码。

static var CONFIG := {
	"max_party_size": 8,            # 队伍容量（不含玩家），支持任意 N
	"start_friends": 2,             # P0：开局默认招募的 AI 队友数

	"command": {
		"active": {                 # 【主动进攻】
			"search_radius": 340.0,     # 主动索敌半径（以自身为圆心）
			"leash_radius": 320.0,      # 脱离半径：离锚点超过此距离放弃目标返回
			"pickup": true,             # 是否拾取
			"protect_player": true,     # 玩家被攻击时优先救场
			"low_hp_retreat": 0.25,     # 血量低于该比例撤向锚点
			"no_enemy": "follow",       # 无敌时行为：follow=跟随玩家 / anchor=守锚点
		},
		"follow": {                 # 【跟随玩家】
			"follow_distance": 110.0,   # 编队跟随距离
			"spread": 52.0,             # 队友间散开间距（避免挤门拥堵）
			"pickup": true,             # 是否拾取
			"engage_with_player": true, # 玩家进入战斗/被攻击后参战
			"engage_radius": 300.0,     # 参战索敌半径（以玩家为圆心）
		},
		"hold": {                   # 【待机】
			"self_defense": true,       # 被攻击是否自卫反击
			"defense_radius": 70.0,     # 自卫索敌半径
			"pickup": false,            # 默认不拾取
		},
	},

	"possession_cooldown": 1.5,     # 主控切换冷却（防卡 CD / 取消惩罚滥用）
	"friend_potion_use": false,     # AI 是否自动喝药（默认保守：不喝，低血撤退）
	"friend_sp_regen": 3.0,         # 队友 SP 每秒回复
	"xp_share_ratio": 1.0,          # 队友经验分享比例
	"revive_on_floor_change": true, # 换层复活死亡队友
	"revive_ratio": 0.5,            # 复活时血量比例
	"low_hp_retreat_ratio": 0.25,   # 全局低血撤退线（指令里未单独配置时用）

	# 卡住恢复：先绕行，超时传送到玩家身边并提示
	"stuck_teleport_after": 2.5,
	"think_interval": 0.15,         # AI 决策间隔（队友间自动错相）
	"nav_repath_interval": 0.8,     # 寻路重算间隔
	"far_unit_distance": 1200.0,    # 距玩家超过此距离降低决策频率
	"far_think_multiplier": 3.0,

	# APC 能力标签（需求书 §5.6）：共享 FriendUnit，靠标签区分
	"apc_tags": {
		"mercenary": {"can_command": true, "can_possess": false, "counts_to_cap": false, "temporary": true},
	},
}


## 读取顺序：data/balance.json（可热重载）→ 内置 CONFIG 兜底
static func cfg(key: String, fallback: Variant = null) -> Variant:
	var party: Dictionary = ArpgBalance.data.get("party", {})
	if party.has(key):
		return party[key]
	return CONFIG.get(key, fallback)


static func cmd_cfg(command: String, key: String, fallback: Variant = null) -> Variant:
	var c: Dictionary = cfg(command, {})
	return c.get(key, fallback)
