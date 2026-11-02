class_name L10n
extends RefCounted
## 字符串表基建（需求 §6：为本地化打底）：
## · 新代码一律 L10n.tr("ui.start")；key 缺失时回退默认文案并告警（开发期可见）
## · 表来自 balance.strings（热重载）；未来多语言 = balance 换语言文件
## · 存量硬编码串在 R2 内容期逐步迁移，不一次性翻（避免巨 diff 无验证）

static var _missing := {}


static func text(key: String, fallback: String = "") -> String:
	var table: Dictionary = ArpgBalance.data.get("strings", {})
	if table.has(key):
		return str(table[key])
	if fallback != "":
		if not _missing.has(key):
			_missing[key] = true
			push_warning("[L10N] 缺失翻译键: " + key + "（已用兜底文案）")
		return fallback
	return key
