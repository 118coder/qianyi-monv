# 附录：交接期间发现的历史遗留问题清单（供下一会话优先排查）

> 本文件由交接会话生成。以下问题全部**不影响自动化测试通过**（测试没覆盖到），但会影响真实玩家体验或代码健康。按优先级排列。

---

## A1.「丢失代码」误报的澄清（重要！）

交接会话早期曾误判 `arpg/main.gd` 丢失了大量玩法函数（`_click/_select/_attack/_kill/_end_player_turn` 等）。**经核查这些函数属于战棋原型（srpg/main.gd，完好无损）**，ARPG 的 main.gd 本来就没有它们——ARPG 的输入是实时键盘/手柄，不是点击寻路。

ARPG main.gd **真正缺失**的只有：事件引擎接线（`events` 成员、`_intro`、`spawn_units`、`_game_over`、`on_unit_dead/on_unit_moved` 钩子），恢复代码见 HANDOFF.md §2（约 60 行，已写好可直接粘贴）。

---

## A2. 已确认但未修的问题

| # | 问题 | 现象 | 建议修法 |
|---|---|---|---|
| A2-1 | **mouse-play 从未被真实鼠标验证过** | 自动驾驶/渲染验证都不点鼠标；`main._unhandled_input` 的鼠标分支（理论上有）从未被真正走到 | 交接后第一件事：真人工玩 10 分钟，把不顺手的记下来 |
| A2-2 | **party_root 绘制层级**（z=5） | 队友永远画在敌人之上，走位重叠时可能遮挡敌人 | 长期方案：把队友也并进 MobSystem 批次渲染；短期可接受 |
| A2-3 | **队友无碰撞体积互推玩家** | 已加软分离力，但仍可能有推挤边缘情况 | 已有 separation 参数（balance.party），可调 |
| A2-4 | **hud.gd 仍是大文件**（~950 行） | 加 UI 功能时容易踩彼此 | R1 拆分（每屏一脚本） |
| A2-5 | **技能栏 SP 显示**：use_skill 后 SP 变化未即时刷新 hp_bar | 技能/喝药后 SP 条延迟更新 | drink_potion/use_skill 里补 `hp_bar.update_values(...)` |
| A2-6 | **事件 give_item 不触发 quest collect**？ | 已触发（`quests.on_pickup`），但**买的不算**（商店 buy 不调 quests） | 如果任务设计要求"购买也算"，在 shop.buy 里补 `quests.on_pickup` |

## A3. 已踩过的 GDScript 坑（新会话写代码前先看）

| 坑 | 症状 | 规则 |
|---|---|---|
| 撞名 Object 内置方法 | "Could not resolve external class member" / "Cannot call non-static" / 返回值类型诡异 | 避免用 `get/reload/tr/alive/owner/name` 等内置名做成员/函数名 |
| `:=` 类型推断失败 | "Cannot infer the type of X" | 凡是来自 `Dictionary`/`Array`/无类型 `var` 的值，显式写 `var x: Type =` |
| const 字典嵌套赋值 | "Cannot assign a new value to a constant" | 需要"可变默认值"时用 `static var` 而非 `const` |
| bash heredoc 长度 | >12KB 脚本被截断（静默失败） | 大补丁用 Write 工具写文件再 `python` 执行 |
| PowerShell UTF-8 中文 | 中文变乱码 | 脚本文件先加 UTF-8 BOM |
| GDScript4 无反斜杠续行 | "Expected closing" | 表达式换行用括号包裹 |

---

## A4. 交接自检清单

- [ ] 跑 `自动测试-无头全套.bat` → 应全绿（ARPG 87 / 战旗 29 / autoplay PASS）
- [ ] 跑 `打开编辑器.bat` → 检查事件节点图是否正常显示（§2 的 P0 恢复后，试玩事件才会触发）
- [ ] 按 HANDOFF §2 恢复事件接线（4 处改动，约 60 行）
- [ ] 恢复后跑 `--autoplay` + 手动玩 10 分钟（第一次真实鼠标验证）
- [ ] 阅读 `docs/商业架构蓝图.md` 确认 R1/R2 优先级
- [ ] 如需推送：`git push`（远端已配好，凭据走 GitHub Desktop）
