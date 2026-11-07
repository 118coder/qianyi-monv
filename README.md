# 千亿魔女 · 地牢 ARPG（一小时 Demo）

露塞提娅式「店铺经营 + 地牢冒险」：打捞 → 还债 → 交租 → 变强，一条约 60 分钟的完整流程。

## 🎮 快速开始

双击 **`运行游戏.bat`**（或 Godot F5）：

1. 选职业出击（剑士 / 法师 / 弓手）——或点「**试玩手搭场景**」进示例手搭关卡
2. 序章对话后进入千渊地牢，跟着任务链走（右下任务菜单 / 屏幕横幅）
3. 每层清怪 → 开箱 → 深层有**血祭坛**（-30% 生命换全队攻击 +30%）和**神秘商人**（紫色晶体，E 进店）
4. 5 层击败「守窟者」巴洛尔（半血会**狂暴**：横幅警告 + 召唤小鬼 + 16 向弹幕）→ 传送门结算
5. 结算自动还债 + 交店租——**十天内还清 300G** 是这个 Demo 的终极目标

### 操作

| 键 | 动作 |
|---|---|
| WASD/方向键 | 移动 · **J/Z** 攻击 |
| **K / L / U** | 技能 1/2/3（大招 Lv7 解锁，HUD 有预告） |
| **Q** 喝药 · **E** 互动 · **C** 角色菜单 · **T** 队伍指令 |
| Tab | 切换主控 · **F1** 调试面板 · **F9/F10** 存/读档 |

## 🛠 开发

```bash
# 三层回归（改任何系统后必跑）
"D:/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe" --headless --path "E:/游戏制作" -s res://tests/smoke_arpg.gd
... -s res://tests/smoke.gd          # 战棋
... -- --autoplay                    # 机器人打通整局
... -- --stress=10000 --bench=15     # 万敌基准（≥50FPS）

# 手搭场景试玩（创作工坊画的图）
... -- --scene=scene001

# 数值热重载：改 data/balance.json 保存即生效；地图事件改完按 F3
```

- **数值/任务/怪物/技能** 全在 `data/balance.json`（保存即热重载，别写死代码）
- **剧情事件** 在 `data/maps/arpg_events.json`（楼层号=回合数；支持 dialogue/spawn/give_xp/spawn_friend/camera…13+ 命令）
- **手搭场景** 在 `data/scenes/`（`打开创作器.bat` → 场景页绘制保存）
- **交接文档**：新会话/新开发者从 `HANDOFF.md` 读起，接续点看 `docs/下一轮交接.md`

## 📐 架构速览

```
arpg/        主产品（main 流程编排 / mob_system SoA 敌群 / player / hud / 事件引擎接线 / economy 账本）
core/        事件引擎 / 存档 v2 / 音频 / 设置
creator/     创作工坊（RPG Maker 式，独立于 Godot 编辑器）
editor/      节点式事件/数值编辑器（与战棋共用 map JSON 管线）
tests/       smoke(149 断言) / autoplay / 压测 / 渲染走查脚本
docs/        设计文档 + 交接（HANDOFF.md 为主索引）
```

详见 `HANDOFF.md`（架构地图 §3 / 踩坑清单 §6 / 本轮记录 §22）。
