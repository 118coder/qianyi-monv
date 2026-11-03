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

	# 队友 AI 行为参数（S/A 评审：目标选择、风筝、卡住处置、到位迟滞）
	# 正式数值在 data/balance.json 的 party.ai 段，这里只做 JSON 缺键兜底
	"ai": {
		"self_defense_radius": 150.0,   # 被怪贴到这个距离必还手
		"assist_radius": 300.0,         # 玩家参战时的协战半径
		"assist_idle_radius": 200.0,    # 玩家未参战时仍会清理的"贴近玩家"半径
		"los_penalty": 0.9,             # 隔墙目标评分扣分
		"stick_bonus": 0.6,             # 当前目标粘性
		"switch_margin": 1.25,          # 换目标需要的分数倍数
		"reach_timeout": 6.0,           # 追同一目标超时打不到 → 拉黑
		"blacklist_time": 5.0,
		"ranged_engage": 265.0,         # 远程接敌距离
		"ranged_keep_min": 125.0,       # 远程后撤线
		"ranged_keep_max": 225.0,       # 远程前压线
		"arrive_radius": 28.0,          # 跟随到点判定
		"resume_radius": 48.0,          # 跟随重新起步判定（迟滞）
		"pickup_threat_radius": 220.0,  # 附近有怪时不捡东西
		"skill_min_enemies": 2,
		"aim_max_lead": 0.55,           # 弹道提前量上限（秒）：目标速度 × 该时间
		"stuck_repath": 0.30,           # 卡住分级处置时间轴
		"stuck_sidestep": 0.75,
		"stuck_regroup": 1.50,
		"stuck_teleport": 2.50,
		"hold_leash": 1.6,              # 待机自卫的最大脱离半径（×defense_radius）
	},

	"possession_cooldown": 1.5,     # 主控切换冷却（防卡 CD / 取消惩罚滥用）
	"friend_potion_use": false,     # AI 是否自动喝药（默认保守：不喝，低血撤退）
	"friend_sp_regen": 3.0,         # 队友 SP 每秒回复
	"xp_share_ratio": 1.0,          # 队友经验分享比例
	"revive_on_floor_change": true, # 换层复活死亡队友
	"revive_ratio": 0.5,            # 复活时血量比例
	"low_hp_retreat_ratio": 0.25,   # 全局低血撤退线（指令里未单独配置时用）

	# 决策节拍与寻路节流（卡住处置相关时间轴在下方 "ai" 段）
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
