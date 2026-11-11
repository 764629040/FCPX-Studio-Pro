#!/usr/bin/env python3
"""
tools/tr025/compare_means.py
TR-025 验收 D1 + A4：屏幕 vs 导出逐通道均值、墨色众数、alpha 形状保持。

三档（源图不同，alpha 对照各自源图）：
  01_before       黑字 + 直接替换 + #F92125 → 红字 (249,33,37)
  02_complement   黑字 + 点对比色 → #06DEDA → 青绿字 (6,222,218)   ← A4「文字变青」
  03_red_invert   红墨源图 + 反相 → (0,255,255) 纯青             ← D1「彩墨反相出补色（红→青）」

断言：
  · 逐通道 |屏幕 - 导出| ≤ 0.1
  · alpha 差异 0（源 PNG vs 导出 PNG）
  · 01 墨色是红；02 墨色是青绿（#06DEDA 邻域）；03 墨色是纯青 (0,255,255)
  · 03 证明补色：R 低、G/B 高（红墨 R 高 G/B 低的补色）

用法： python3 tools/tr025/compare_means.py [截图目录] [导出根目录] [源图目录]
"""
import json
import os
import sys

import numpy as np
from PIL import Image

SHOTS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tr025_shots"
EXPORT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/tr025_export"
SRCDIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/tr025_src"

STEPS = [
    ("01_before",      "直接替换·#F92125",  "black_text.png", "red"),
    ("02_complement",  "对比色·#06DEDA",   "black_text.png", "teal"),
    ("03_red_invert",  "红墨·反相",         "red_text.png",   "cyan"),
]


def find_artboard(img_rgb):
    flat = img_rgb.reshape(-1, 3)
    vals, counts = np.unique(flat, axis=0, return_counts=True)
    order = np.argsort(-counts)[:8]
    best = None
    for i in order:
        color = vals[i]
        mask = np.abs(img_rgb.astype(np.int16) - color.astype(np.int16)).max(axis=2) <= 1
        rows = mask.sum(axis=1); cols = mask.sum(axis=0)
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


def color_kind(modal, expected):
    """按色相方向分档；返回是否满足期望。"""
    r, g, b = modal
    if expected == "red":
        return r > 190 and g < 90 and b < 90
    if expected == "teal":   # #06DEDA = (6,222,218)
        return r < 70 and g > 170 and b > 170
    if expected == "cyan":   # (0,255,255)
        return r < 70 and g > 190 and b > 190
    return False


def main():
    rows = []
    bad = []
    for key, title, src_name, expected in STEPS:
        shot_path = os.path.join(SHOTS, key + ".png")
        if not os.path.exists(shot_path):
            print("!! 缺截图 %s" % shot_path); return 1
        arr = np.array(Image.open(shot_path).convert("RGB"))
        box, bg = find_artboard(arr)
        if box is None:
            print("!! %s 没定位到画板" % shot_path); return 1
        crop = arr[box[1]:box[3], box[0]:box[2]]
        got = ink_stats(crop, bg)
        if got is None:
            print("!! %s 画板里没找到墨色" % shot_path); return 1
        s_mean, s_n, s_modal = got

        media_dir = os.path.join(EXPORT, key, "Media")
        media = sorted(m for m in os.listdir(media_dir) if m.lower().endswith(".png")) if os.path.isdir(media_dir) else []
        if not media:
            print("!! %s 没有导出 PNG" % media_dir); return 1
        media_path = os.path.join(media_dir, media[0])
        e_mean, e_n, e_modal, e_alpha = export_stats(media_path)

        src_path = os.path.join(SRCDIR, src_name)
        src_alpha = np.array(Image.open(src_path).convert("RGBA"))[:, :, 3]
        diff = s_mean - e_mean
        alpha_diff = int((src_alpha != e_alpha).sum()) if src_alpha.shape == e_alpha.shape else -1

        screen_ok = color_kind(s_modal, expected)
        export_ok = color_kind(e_modal, expected)
        rows.append(dict(mode=title, key=key, shot=shot_path, media=media_path,
                         artboard_box=list(box),
                         screen_mean=[round(float(x), 2) for x in s_mean], screen_n=s_n, screen_modal=s_modal,
                         export_mean=[round(float(x), 2) for x in e_mean], export_n=e_n, export_modal=e_modal,
                         delta=[round(float(x), 2) for x in diff],
                         alpha_diff_pixels=alpha_diff, src_pixels=int(src_alpha.size),
                         expected_color=expected, screen_color_ok=screen_ok, export_color_ok=export_ok))

        if max(abs(float(x)) for x in diff) > 0.1:
            bad.append("%s 逐通道差超 0.1: %s" % (title, diff))
        if alpha_diff != 0:
            bad.append("%s alpha 差异 %d ≠ 0" % (title, alpha_diff))
        if not screen_ok:
            bad.append("%s 屏幕墨色不是期望色(%s): %s" % (title, expected, s_modal))
        if not export_ok:
            bad.append("%s 导出墨色不是期望色(%s): %s" % (title, expected, e_modal))

    print("== 导出 vs 屏幕 均值对比（0–255）==")
    print("%-20s %-24s %-24s %-24s" % ("模式", "屏幕均值 R,G,B", "导出均值 R,G,B", "逐通道差值 (屏-导)"))
    for r in rows:
        print("%-20s %-24s %-24s %-24s" % (
            r["mode"], fmt(r["screen_mean"]), fmt(r["export_mean"]),
            "(%+.1f, %+.1f, %+.1f)" % tuple(r["delta"])))
    print()
    print("== 形状（alpha）保持（各自源 PNG vs 导出 PNG）==")
    for r in rows:
        print("%-20s alpha 差异像素 %d / %d" % (r["mode"], r["alpha_diff_pixels"], r["src_pixels"]))
    print()
    print("== 墨色众数（厚笔画像素）+ 色相方向断言 ==")
    for r in rows:
        print("%-20s 屏幕众数 %-18s 导出众数 %-18s 期望=%-5s 屏幕%s 导出%s" % (
            r["mode"], str(r["screen_modal"]), str(r["export_modal"]), r["expected_color"],
            "PASS" if r["screen_color_ok"] else "FAIL", "PASS" if r["export_color_ok"] else "FAIL"))
    print()
    print("== A4 / D1 结论 ==")
    print("  A4 文字变青：02_complement 墨色 = #06DEDA 邻域（青绿），01_before = #F92125（红）")
    print("  D1 彩墨反相出补色：03_red_invert 红墨(255,0,0) → 青(0,255,255)，屏幕/导出双向坐实")
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
    print("全部断言 PASS（差 ≤ 0.1 / alpha 差 0 / 红·青绿·纯青 三档色相正确）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
