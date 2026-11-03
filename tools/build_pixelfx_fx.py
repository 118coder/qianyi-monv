#!/usr/bin/env python3
"""把 pixelfx 渲染出来的 sprite sheet 接入 Godot：缩放 + 合并元数据。

为什么需要这一步：
  · pixelfx 的原始单帧尺寸偏大（frost-nova 单帧 288×256），直接进引擎显存吃不消；
  · 每个特效自带一个 TexturePacker 格式 json，Godot 侧读十几个文件很啰嗦。

所以这里做两件事：
  1. 单帧最大边 > 200 的，按整数 2 倍缩小（NEAREST，保持像素硬边）；
  2. 把所有特效的 frames/cols/rows/fps/loop/pivot 合并成一个 fx_atlas.json，
     Godot 只读这一个文件。

用法（在项目根目录）：
    python tools/build_pixelfx_fx.py

输入：vendor/pixelfx/records/<category>/<name>/{<name>.png,<name>.json}
输出：assets/fx/pxfx/*.png + assets/fx/pxfx/fx_atlas.json
"""

import json
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECORDS = os.path.join(ROOT, "vendor", "pixelfx", "records")
OUT_DIR = os.path.join(ROOT, "assets", "fx", "pxfx")

# (pixelfx id, 输出名, 用途说明)
PICKS = [
    ("melee/sword-slash", "slash", "近战斩击：玩家与队友普攻"),
    ("impacts/hit-spark", "hit", "命中火花：任何伤害命中"),
    ("explosions/cartoon-pow", "burst", "小爆炸：技能命中、陷阱箱"),
    ("holy/heal", "heal", "治疗光环：喝药与回血技能"),
    ("pickups/coin-spin", "coin", "金币：掉落与拾取"),
    ("pickups/gem-spin", "gem", "宝石：掉落物"),
    ("spawn/dissolve-burn", "dissolve", "燃尽消散：怪物死亡"),
    ("arcane/portal", "portal", "传送门：楼梯与上下层"),
    ("ice/frost-nova", "frost", "冰霜新星：范围技"),
    ("lightning/zap-hit", "zap", "闪电命中：雷系技能"),
    ("projectiles/arrow", "arrow", "箭矢：弓手弹道"),
    ("arcane/mana-burst", "mana", "魔力爆发：法术起手"),
]

MAX_EDGE_KEEP = 200      # 单帧最大边不超过这个值就保持原尺寸


def load_sheet(pid):
    """读一个 pixelfx 产物，返回 (Image, meta)"""
    cat, name = pid.split("/", 1)
    d = os.path.join(RECORDS, cat, name)
    png = os.path.join(d, name + ".png")
    js = os.path.join(d, name + ".json")
    if not (os.path.exists(png) and os.path.exists(js)):
        return None, None
    with open(js, encoding="utf-8") as f:
        meta = json.load(f)
    return Image.open(png).convert("RGBA"), meta


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    atlas = {"version": 1, "source": "pixelfx (MIT) https://github.com/patch-gg/pixelfx", "effects": {}}
    missing = []

    for pid, out_name, use in PICKS:
        img, meta = load_sheet(pid)
        if img is None:
            missing.append(pid)
            continue
        px = meta["meta"]["pixelfx"]
        n, cols, fps, loop = px["frames"], px["columns"], px["fps"], bool(px.get("loop"))
        fw, fh = px["frameSize"]
        pivot = px.get("pivot", [fw // 2, fh // 2])
        rows = (n + cols - 1) // cols

        # 整数倍缩小：只在单帧确实过大时做，避免无谓地损失像素
        k = 1
        if max(fw, fh) > MAX_EDGE_KEEP:
            k = 2
        if k > 1:
            if fw % k or fh % k:
                print(f"  ! {pid} 帧尺寸 {fw}x{fh} 不能被 {k} 整除，保持原尺寸")
                k = 1
            else:
                img = img.resize((img.width // k, img.height // k), Image.NEAREST)
                fw, fh = fw // k, fh // k
                pivot = [pivot[0] // k, pivot[1] // k]

        out_png = os.path.join(OUT_DIR, out_name + ".png")
        img.save(out_png, "PNG", optimize=True)

        atlas["effects"][out_name] = {
            "file": f"res://assets/fx/pxfx/{out_name}.png",
            "frames": n,
            "cols": cols,
            "rows": rows,
            "frame_w": fw,
            "frame_h": fh,
            "fps": fps,
            "loop": loop,
            "pivot": pivot,
            "src": pid,
            "use": use,
        }
        print(f"  {out_name:10} <- {pid:28} {n:3}帧 {cols}x{rows} 单帧 {fw}x{fh} 缩放 1/{k}")

    with open(os.path.join(OUT_DIR, "fx_atlas.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(atlas, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\n输出 {len(atlas['effects'])} 个特效 -> {OUT_DIR}")
    if missing:
        print("缺少产物（先跑 node tools/render.mjs ... --sheet --no-actor）：")
        for m in missing:
            print("  " + m)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
