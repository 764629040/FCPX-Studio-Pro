#!/usr/bin/env python3
"""
tools/tr024b/compare_means.py
TR-024-2 验收 #8：导出图 vs 真机屏幕逐通道均值对比 + alpha 形状保持。

与 tools/tr024/compare_means.py 同一套口径（画板自动定位、墨色众数 ±6 邻域求均值），
区别只在覆盖范围：只比 直接替换 / 反相 / 反相+没设色 三档，并对反相额外断言「墨色必须是亮白」。

用法： python3 tools/tr024b/compare_means.py [截图目录] [导出根目录]
"""
import json
import os
import sys

import numpy as np
from PIL import Image

SHOTS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tr024b_shots"
EXPORT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/tr024b_export"
SRC_PNG = "/tmp/tr024b_src/black_text.png"

STEPS = [
    ("01_direct", "直接替换"),
    ("02_invert", "反相"),
    ("03_invert_nocolor", "反相·未设色"),
]


def find_artboard(img_rgb):
    """自动定位画板矩形 + 画芯实际颜色（截图经色彩管理后不等于源码值，所以不写死）。"""
    flat = img_rgb.reshape(-1, 3)
    vals, counts = np.unique(flat, axis=0, return_counts=True)
    order = np.argsort(-counts)[:8]
    best = None
    for i in order:
        color = vals[i]
        mask = np.abs(img_rgb.astype(np.int16) - color.astype(np.int16)).max(axis=2) <= 1
        rows = mask.sum(axis=1)
        cols = mask.sum(axis=0)
        if rows.max() < 50 or cols.max() < 50:
            continue
        ry = np.where(rows > rows.max() * 0.5)[0]
        cx = np.where(cols > cols.max() * 0.5)[0]
        box = (int(cx.min()), int(ry.min()), int(cx.max()) + 1, int(ry.max()) + 1)
        area = (box[2] - box[0]) * (box[3] - box[1])
        if area < 300000:
            continue
        fill = mask[box[1]:box[3], box[0]:box[2]].mean()
        if best is None or fill > best[0]:
            best = (fill, box, color)
    if best is None:
        return None, None
    return best[1], best[2]


def ink_stats(crop_rgb, bg):
    """墨色均值 / 像素数 / 众数。众数 ±6 邻域求均值，避抗锯齿把均值往背景拖。"""
    d = np.abs(crop_rgb.astype(np.int16) - bg.astype(np.int16)).max(axis=2)
    ink = d > 20
    if ink.sum() == 0:
        return None
    px = crop_rgb[ink]
    packed = (px[:, 0].astype(np.uint32) << 16) | (px[:, 1].astype(np.uint32) << 8) | px[:, 2].astype(np.uint32)
    vals, counts = np.unique(packed, return_counts=True)
    m = int(vals[counts.argmax()])
    modal = np.array([(m >> 16) & 0xFF, (m >> 8) & 0xFF, m & 0xFF], dtype=np.int16)
    near = np.abs(px.astype(np.int16) - modal).max(axis=1) <= 6
    core = px[near].astype(np.float64)
    return core.mean(axis=0), int(near.sum()), tuple(int(x) for x in modal)


def export_stats(png_path):
    im = Image.open(png_path).convert("RGBA")
    a = np.array(im)
    opaque = a[:, :, 3] >= 250
    px = a[:, :, :3][opaque]
    packed = (px[:, 0].astype(np.uint32) << 16) | (px[:, 1].astype(np.uint32) << 8) | px[:, 2].astype(np.uint32)
    vals, counts = np.unique(packed, return_counts=True)
    m = int(vals[counts.argmax()])
    modal = np.array([(m >> 16) & 0xFF, (m >> 8) & 0xFF, m & 0xFF], dtype=np.int16)
    near = np.abs(px.astype(np.int16) - modal).max(axis=1) <= 6
    mean = px[near].astype(np.float64).mean(axis=0)
    return mean, int(near.sum()), tuple(int(x) for x in modal), a[:, :, 3]


def fmt(v):
    return "(%6.1f, %6.1f, %6.1f)" % (v[0], v[1], v[2])


def main():
    src_alpha = np.array(Image.open(SRC_PNG).convert("RGBA"))[:, :, 3]

    rows = []
    bad = []
    for key, title in STEPS:
        shot_path = os.path.join(SHOTS, key + ".png")
        if not os.path.exists(shot_path):
            print("!! 缺截图 %s" % shot_path)
            return 1
        arr = np.array(Image.open(shot_path).convert("RGB"))
        box, bg = find_artboard(arr)
        if box is None:
            print("!! %s 没定位到画板" % shot_path)
            return 1
        crop = arr[box[1]:box[3], box[0]:box[2]]
        got = ink_stats(crop, bg)
        if got is None:
            print("!! %s 画板里没找到墨色" % shot_path)
            return 1
        s_mean, s_n, s_modal = got

        media_dir = os.path.join(EXPORT, key, "Media")
        if not os.path.isdir(media_dir):
            print("!! 缺导出目录 %s" % media_dir)
            return 1
        media = sorted(m for m in os.listdir(media_dir) if m.lower().endswith(".png"))
        if not media:
            print("!! %s 没有导出 PNG" % media_dir)
            return 1
        e_mean, e_n, e_modal, e_alpha = export_stats(os.path.join(media_dir, media[0]))

        diff = s_mean - e_mean
        alpha_diff = int((src_alpha != e_alpha).sum()) if src_alpha.shape == e_alpha.shape else -1

        rows.append(dict(mode=title, key=key,
                         shot=shot_path, media=os.path.join(media_dir, media[0]),
                         artboard_box=list(box),
                         screen_mean=[round(float(x), 2) for x in s_mean], screen_n=s_n, screen_modal=s_modal,
                         export_mean=[round(float(x), 2) for x in e_mean], export_n=e_n, export_modal=e_modal,
                         delta=[round(float(x), 2) for x in diff],
                         alpha_diff_pixels=alpha_diff, src_pixels=int(src_alpha.size)))

        # 断言 1：逐通道差 ≤ 0.1
        if max(abs(float(x)) for x in diff) > 0.1:
            bad.append("%s 逐通道差超 0.1: %s" % (title, diff))
        # 断言 2：alpha 差异必须 0
        if alpha_diff != 0:
            bad.append("%s alpha 差异 %d ≠ 0" % (title, alpha_diff))
        # 断言 3：反相必须是亮墨（RGB 全部 ≥ 200），不许再是暗绿
        if key.startswith(("02", "03")):
            if min(s_modal) < 200:
                bad.append("%s 反相墨色不亮: 屏幕众数 %s" % (title, s_modal))
            if min(e_modal) < 200:
                bad.append("%s 反相导出墨色不亮: %s" % (title, e_modal))

    print("== 导出 vs 屏幕 均值对比（0–255）==")
    print("%-14s %-27s %-27s %-24s" % ("模式", "屏幕均值 R,G,B", "导出均值 R,G,B", "逐通道差值 (屏-导)"))
    for r in rows:
        print("%-14s %-27s %-27s %-24s" % (
            r["mode"], fmt(r["screen_mean"]), fmt(r["export_mean"]),
            "(%+.1f, %+.1f, %+.1f)" % tuple(r["delta"])))
    print()
    print("== 形状（alpha）保持（源 PNG vs 导出 PNG）==")
    for r in rows:
        print("%-14s alpha 差异像素 %d / %d" % (r["mode"], r["alpha_diff_pixels"], r["src_pixels"]))
    print()
    print("== 墨色众数（厚笔画像素）==")
    for r in rows:
        print("%-14s 屏幕众数 %-18s 导出众数 %s" % (r["mode"], str(r["screen_modal"]), str(r["export_modal"])))
    print()
    print("== 反相亮字断言 ==")
    for r in rows:
        if r["key"].startswith(("02", "03")):
            ok = min(r["screen_modal"]) >= 200 and min(r["export_modal"]) >= 200
            print("%-14s 屏幕 %s 导出 %s -> %s" % (
                r["mode"], r["screen_modal"], r["export_modal"], "亮字 PASS" if ok else "不是亮字 FAIL"))
    print()

    with open(os.path.join(SHOTS, "means.json"), "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print("数值台账: %s" % os.path.join(SHOTS, "means.json"))

    if bad:
        print()
        print("!! 断言失败：")
        for b in bad:
            print("   - " + b)
        return 1
    print("全部断言 PASS（差 ≤ 0.1 / alpha 差 0 / 反相为亮字）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
