# pixelfx 特效接入

来源：[patch-gg/pixelfx](https://github.com/patch-gg/pixelfx)（MIT，代码与特效可商用；`NOTICE.md` 里另有 Hugo Duprez 与 Hollow Crown 的 MIT 授权，唯一例外是 `gallery/fonts` 里的 Patch 字体，本项目没用到）。

---

## 一、为什么不能直接用，必须走离线渲染

pixelfx 的 244 个特效**全是 JavaScript 函数**，每帧往 color buffer + light buffer 里画像素。
它是给 canvas/WebGL 游戏用的，Godot 里跑不了 JS。

所以走「离线渲染成 sprite sheet」这条路：用它的 `tools/render.mjs` 出 PNG，Godot 只负责播放。

```
vendor/pixelfx（源码，266 个特效）
        │  node tools/render.mjs <id> --sheet --no-actor
        ▼
records/<分类>/<名>/{<名>.png, <名>.json}     ← 原始 sprite sheet + TexturePacker 元数据
        │  python tools/build_pixelfx_fx.py     ← 缩放 + 合并元数据
        ▼
assets/fx/pxfx/{12 个 .png, fx_atlas.json}    ← 运行时只读这一份 atlas
```

**`--no-actor` 是必须的**：不加这个参数，pixelfx 会把它的演示小人一起画进每一帧。

---

## 二、已接入的 12 个特效

| atlas 名 | pixelfx 源 | 帧数 | 用途 |
|---|---|---|---|
| `slash` | melee/sword-slash | 24 | 近战斩击（玩家与队友普攻） |
| `hit` | impacts/hit-spark | 16 | 命中火花 |
| `burst` | explosions/cartoon-pow | 33 | 技能命中、开宝箱、冲击环 |
| `heal` | holy/heal | 58 | 喝药、治疗技能 |
| `coin` | pickups/coin-spin | 48 | 金币拾取闪光 |
| `gem` | pickups/gem-spin | 72 | 宝石拾取闪光 |
| `dissolve` | spawn/dissolve-burn | 109 | 怪物死亡消散 |
| `portal` | arcane/portal | 72 | 换层落地的传送门 |
| `frost` | ice/frost-nova | 103 | 冰霜范围（备用于后续技能） |
| `zap` | lightning/zap-hit | 28 | 雷系命中（备用） |
| `arrow` | projectiles/arrow | 18 | 箭矢（备用，弹道仍在用旧贴图） |
| `mana` | arcane/mana-burst | 55 | 范围技起手 |

**缩放**：单帧最大边 > 200 的自动按整数 2 倍缩小（`frost` 288×192→144×96，`mana` 208×150→104×75），
其余保持像素原尺寸，在 Godot 里用 `scale` 调到合适大小。

---

## 三、代码怎么接

### 3.1 库：`arpg/pxfx.gd`

- `ArpgPxfx.meta(name)` 读 atlas；
- `ArpgPxfx.make(name)` 造一个 `Player`（内部类，`extends Sprite2D`）；
- `Player` 用 `hframes/vframes` 切帧（pixelfx 的 sheet 是**均匀网格**，`meta.pixelfx.columns` 给了列数），
  按 atlas 的 `fps` 推进，非循环特效播完自毁。

**一个必须注意的换算**：pixelfx 的 `pivot` 是特效的「作用点」（斩击的挥砍原点），不一定在图片中心。
`Sprite2D.centered = true` 会把**帧中心**对到节点原点，所以要补
`offset = 帧尺寸/2 - pivot`，才能让作用点落在 `position` 上。

### 3.2 入口：`world.spawn_pxfx(name, pos, opts)`

```gdscript
world.spawn_pxfx("slash", pos, {"rot": angle, "scale": 0.55, "tint": col})
```

| opts | 含义 |
|---|---|
| `scale` / `rot` / `tint` | 缩放、旋转、调制色 |
| `speed` | 播放倍速（把长序列压到合适时长） |
| `once` | 强制把循环特效当一次性播 |
| `flip` | 水平翻转 |
| `additive` | 加法混合（默认开，光效更亮） |
| `z` | 层级 |

所有特效都挂在 `fx_root`（z_index=40）下，复用原有的 64 个节点上限保护。

### 3.3 改了哪些调用点

- `world.spawn_slash` / `spawn_nova` / `spawn_hit_spark` / `spawn_death_poof` 四个函数**签名不变**，
  内部换成 pixelfx 序列帧 + 保留原来的粒子喷溅做叠加（序列帧负责形体，粒子负责碎屑感）；
- `main.drink_potion` 加 `heal`；
- `main._do_interact` 的换层分支加 `portal`（在新层的出生点播，因为换层会整层重建）；
- `main.open_chest` 开箱改用 `burst`；
- `drop_system._collect` 按 `K_COIN`/`K_GEM` 播 `coin`/`gem`；
- `player.use_skill` 的 `heal` 分支加 `heal`、范围分支加 `mana`。

---

## 四、删掉的旧贴图

| 文件 | 原用途 | 去向 |
|---|---|---|
| `Slash1.png` | 近战斩击 | → `slash` |
| `ShockWave1.png` | 命中火花 | → `hit` |
| `ShockWaveRing1.png` | 冲击环 | → `burst` |
| `Ring.png` | 冲击环内圈 | → `burst` |
| `LightRing.png` | 开箱光环 | → `burst` |
| `Fog.png` | 死亡烟尘 | → `dissolve` |

连同 `.import` 一起删除，`.godot/imported` 里的缓存由第二次 `--import` 清理。

### 保留下来的三张，以及理由

| 文件 | 为什么留 |
|---|---|
| `Particle100.png` | pixelfx 全是序列帧，**不提供**「一颗小粒子」这种素材；`burst()` 粒子喷溅仍在用它 |
| `Circle.png` | 弹道系统的自绘圆点，不是特效动画 |
| `Arrow.png` | 弹道箭矢的飞行贴图（单帧旋转），换成 18 帧序列反而更重 |

---

## 五、验证

**已做（静态）**

- `arpg/*.gd`、`creator/*.gd`、`addons/*/*.gd` 全部 `--check-only` 通过；
- 12 个贴图的 `import` 全部生成，atlas 里 `cols×frame_w / rows×frame_h` 与实际 PNG 尺寸逐一核对一致；
- `godot --headless --import` 跑两遍，第二次零错误；
- 旧贴图的引用已清零（`world.gd` / `main.gd` 里的 7 处全部替换）。

**需要你实机确认**

| # | 验证点 | 期望 |
|---|---|---|
| 1 | 平砍一刀 | 出现蓝白色弧形斩击序列帧，方向跟随挥砍角度 |
| 2 | 打怪 | 命中处爆出火花序列帧 + 碎屑粒子 |
| 3 | 杀怪 | 尸体位置燃尽消散（约 1.2 秒） |
| 4 | 捡金币/宝石 | 拾取点闪一下金色/彩色光 |
| 5 | 喝药 | 角色身上浮起治疗光环 |
| 6 | 下楼梯 | 新一层出生点开一道传送门 |
| 7 | 开宝箱 | 箱子处爆开金色光效 |
| 8 | 性能 | 万敌压测（`--stress=10000 --bench=15`）帧率不低于改动前 |

---

## 六、以后加新特效

```bash
cd vendor/pixelfx
node tools/list.mjs 关键词                       # 先找现成的
node tools/render.mjs 分类/名字 --sheet --no-actor
cd ../.. && python tools/build_pixelfx_fx.py     # 要先把新 id 加进 PICKS
```

`build_pixelfx_fx.py` 顶部的 `PICKS` 是唯一清单，加一行就多一个特效。
换配色不必改代码：`node tools/render.mjs fire/torch --opts '{"palette":["#102","#215","#43a","#8cf","#fff"]}'`。

---

## 七、已知取舍

- **`tests/fx_gallery.gd` 仍引用已删除的贴图**。这个文件在本轮改动**之前就已经语法错误**
  （`ArpgTex.tex(ArpgTex.tex(...)_RING_PATH)` 那一行是坏的），不属于测试链路。
  按项目约定我不改动测试目录，建议你直接删掉它，或告诉我改成读 `fx_atlas.json`。
- `coin` / `gem` / `portal` / `arrow` 在 pixelfx 里是**循环**特效，拾取类用 `once: true` 强制单次；
  `coin` 播一遍约 1 秒，若嫌长把 `speed` 提到 2.5~3。
- `frost` / `zap` / `arrow` 已经渲染好但**尚未接到具体技能**，留给后续调整。
- 加法混合在亮背景上会偏白；若某些特效在浅色地板前糊成一片，单独给它 `additive: false`。
