extends SceneTree
## 经济模拟（蒙特卡洛）：验证「十天还清 300G 债务 + 日租」的可达成性。
## 收益模型取自 autoplay 实测分布（击杀 25~50/局、掉落 2~6G、任务链/日常/售卖）。
## 运行：godot --headless --path . -s res://tests/sim_economy.gd

func _initialize() -> void:
	_run()

func _run() -> void:
	var N := 1000            # 模拟局数（每局 = 玩家的 10 天完整生涯）
	var days := 10
	var debt0 := 1200
	var rent := 30
	var cleared := 0         # 十天内还清的局数
	var best_day := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]   # 还清发生在第几天的分布
	var worst_debt := 0.0    # 最差情况最终债务
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for trial in N:
		var debt: int = debt0
		var gold: int = 0
		var cleared_day := 0
		for day in range(1, days + 1):
			# —— 打捞收入（单局）——
			var kills := rng.randi_range(25, 50)                 # autoplay 实测分布
			var drop: float = kills * rng.randf_range(2.0, 6.0)  # 每杀 2~6G
			var loot: float = rng.randf_range(10.0, 60.0)        # 宝箱/售卖杂项
			gold += int(drop + loot)
			# 任务链（首局一次性 590G）+ 日常（每天 60G，需完成度 60%~100%）
			if day == 1:
				gold += 220
			gold += int(60 * rng.randf_range(0.6, 1.0))
			# —— 结算：还债 → 收租（不足滚债）——
			var paid: int = mini(gold, debt)
			gold -= paid
			debt -= paid
			if debt <= 0 and cleared_day == 0:
				cleared_day = day
			gold -= rent
			if gold < 0:
				debt += -gold
				gold = 0
		if cleared_day > 0:
			cleared += 1
			best_day[cleared_day] += 1
		else:
			worst_debt = maxf(worst_debt, float(debt))
	print("════ 十天还债可达成性模拟（%d 次生涯）════" % N)
	print("还清率：%d%%（%d/%d）" % [cleared * 100 / N, cleared, N])
	for d in range(1, days + 1):
		if best_day[d] > 0:
			print("  第 %d 天还清：%d 局" % [d, best_day[d]])
	if worst_debt > 0:
		print("未还清者最差终债：%.0fG" % worst_debt)
	quit(0)
