"""把 P1 每层单独叠到棋盘格上出图（验收 §7.2：无黑边/白边/半透明毛边）。

输出
  <out>/逐层_<样本>.png   每层一格的大图（每格都是该层按原画幅居中缩放）
  <out>/层边缘指标.tsv    客观数字：层数、半透明像素占比、层外 1px 残留、边缘色偏

不做任何美化或补边 —— 棋盘格直接透出真实 alpha，黑边白边一眼能看见。
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def checker(w: int, h: int, cell: int = 16) -> Image.Image:
    """标准灰白棋盘格（Photoshop 观感）。"""
    a = np.zeros((h, w, 3), dtype=np.uint8)
    yy, xx = np.mgrid[0:h, 0:w]
    a[...] = np.where(((yy // cell + xx // cell) % 2 == 0)[..., None], 205, 165)
    return Image.fromarray(a, "RGB")


def edge_metrics(arr: np.ndarray) -> dict:
    """层边缘客观指标（全在原始像素上算，不缩放）。"""
    from scipy import ndimage

    alpha = arr[:, :, 3]
    visible = alpha > 0
    if not visible.any():
        return {"visible_px": 0, "partial_ratio": 0.0, "outside_1px_residue": 0, "rim_delta": 0.0}

    # 半透明像素占比：毛边的直接度量
    partial = int(((alpha > 0) & (alpha < 255)).sum())
    visible_px = int(visible.sum())

    # 层外 1px 残留：alpha==0 但与可见区相邻的像素，RGB 若不为全 0 就是「层外染色」
    near = ndimage.binary_dilation(visible, np.ones((3, 3), dtype=bool)) & ~visible
    outside_rgb = arr[:, :, :3][near]
    residue = int((outside_rgb.max(axis=1) > 0).sum()) if len(outside_rgb) else 0

    # 边缘色偏：不透明边缘一圈的 RGB 与层内 2px 的差；黑边/白边会把这个值拉高
    solid = alpha >= 250
    edge_ring = ndimage.binary_erosion(solid, np.ones((3, 3), dtype=bool), iterations=1) & solid
    inner = ndimage.binary_erosion(solid, np.ones((3, 3), dtype=bool), iterations=3)
    ring_px = arr[:, :, :3][edge_ring]
    inner_px = arr[:, :, :3][inner]
    if len(ring_px) and len(inner_px):
        rim = float(np.abs(ring_px.astype(np.float64).mean(axis=0)
                           - inner_px.astype(np.float64).mean(axis=0)).max())
    else:
        rim = 0.0

    return {
        "visible_px": visible_px,
        "partial_ratio": round(partial / float(max(1, visible_px)), 4),
        "outside_1px_residue": residue,
        "rim_delta": round(rim, 2),
    }


def build(split_dir: str, out_png: str, cell: int = 6, tile: int = 300) -> list:
    with open(os.path.join(split_dir, "分层清单.json"), encoding="utf-8") as f:
        doc = json.load(f)
    W, H = int(doc["width"]), int(doc["height"])
    tw = tile
    th = max(1, int(round(tile * H / float(W))))
    label_h = 26
    cols = min(4, max(1, len(doc["layers"])))
    rows = (len(doc["layers"]) + cols - 1) // cols
    pad = 10
    sheet = Image.new("RGB", (cols * (tw + pad) + pad, rows * (th + label_h + pad) + pad), (24, 24, 28))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/PingFang.ttc", 13)
    except Exception:
        font = ImageFont.load_default()

    metrics = []
    for i, layer in enumerate(doc["layers"]):
        p = os.path.join(split_dir, layer["file"])
        with Image.open(p) as im:
            arr = np.asarray(im.convert("RGBA"))
        m = edge_metrics(arr)
        m["name"] = layer["name"]
        m["class"] = layer["class"]
        m["confidence"] = layer.get("confidence")
        m["low_confidence"] = bool(layer.get("low_confidence"))
        metrics.append(m)

        rgb = Image.fromarray(arr[:, :, :3], "RGB")
        alpha = Image.fromarray(arr[:, :, 3], "L")
        bg = checker(tw, th, cell)
        fg = rgb.resize((tw, th), Image.LANCZOS)
        a = alpha.resize((tw, th), Image.LANCZOS)
        bg.paste(fg, (0, 0), a)
        cx = pad + (i % cols) * (tw + pad)
        cy = pad + (i // cols) * (th + label_h + pad)
        sheet.paste(bg, (cx, cy + label_h))
        draw.text((cx + 2, cy + 5), "%s" % m["name"][:34], fill=(230, 230, 235), font=font)
        draw.rectangle([cx - 1, cy + label_h - 1, cx + tw, cy + label_h + th], outline=(70, 72, 82))
    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    sheet.save(out_png, optimize=True)
    return metrics


def main() -> int:
    ap = argparse.ArgumentParser(description="P1 逐层棋盘格出图 + 层边缘指标")
    ap.add_argument("--outputs", required=True, help="包含多个 <样本>/ 拆分输出目录的根目录")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    root = os.path.abspath(args.outputs)
    os.makedirs(os.path.abspath(args.out), exist_ok=True)
    rows = []
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isfile(os.path.join(d, "分层清单.json")):
            continue
        png = os.path.join(os.path.abspath(args.out), "逐层_%s.png" % name)
        ms = build(d, png)
        rows.extend([dict(sample=name, **m) for m in ms])
        print("ok %-32s %d 层 -> %s" % (name, len(ms), os.path.basename(png)))
    tsv = os.path.join(os.path.abspath(args.out), "层边缘指标.tsv")
    with open(tsv, "w", encoding="utf-8") as f:
        f.write("sample\tlayer\tclass\tvisible_px\tpartial_ratio\toutside_1px_residue\trim_delta\tconfidence\tlow_confidence\n"
                .replace("\\r", "\r"))
        for r in rows:
            f.write("%s\t%s\t%s\t%d\t%.4f\t%d\t%.2f\t%s\t%s\n" % (
                r["sample"], r["name"], r["class"], r["visible_px"], r["partial_ratio"],
                r["outside_1px_residue"], r["rim_delta"], r["confidence"], r["low_confidence"]))
    bad = [r for r in rows if r["outside_1px_residue"] > 0]
    print("\n层数合计 %d；层外 1px 染色 %d 层；半透明占比最大 %.4f；边缘色偏最大 %.2f"
          % (len(rows), len(bad),
             max((r["partial_ratio"] for r in rows), default=0.0),
             max((r["rim_delta"] for r in rows), default=0.0)))
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
