#!/usr/bin/env python3
"""
tools/tr024/compare_means.py
TR-024 验收 #2：导出图 vs 真机屏幕同色对比。

逻辑：
  · 屏幕侧：从真机窗口截图里自动定位画板（画芯色 #121418 的矩形），裁出该区域，
    再把「离画芯色足够远」的像素当墨色像素，取其中最深的一档（≥80% 最大色差）求均值 ——
    这样抗锯齿边缘不会把均值往背景方向拖。
  · 导出侧：读 /tmp/tr024_export/<mode>/Media/*.png，取 alpha==255 的像素求均值。
  · 另附 alpha 形状比对：源 PNG 的 alpha 与导出 PNG 的 alpha 差异像素数，证明「只改颜色、不改形状」。

用法： python3 tools/tr024/compare_means.py [截图目录] [导出根目录]
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SHOTS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tr024_shots"
EXPORT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/tr024_export"
SRC_PNG = "/tmp/tr024_src/black_text.png"
OUT_MONTAGE = os.path.join(SHOTS, "00_montage.png")

STEPS = [
    ("01_direct", "直接替换"),
    ("02_luminance", "明暗上色"),
    ("03_invert", "反相"),
    ("04_hueRotate", "色相旋转"),
]

def find_artboard(img_rgb):
    """自动定位画板矩形 + 画芯实际颜色。

    截图经过显示器色彩配置转换，画芯 #121418 落盘后不等于源码值（实测 23,26,32），
    所以不写死颜色：从出现频次最高的几种颜色里，挑「在自身 bbox 内填充率最高」的那块矩形。
    """
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
    """返回 (墨色均值, 墨色像素数, 墨色众数, 抗锯齿灰度级数)。

    画板里除了字还有 12% 白的虚线安全框、蓝色十字准星，它们比暗墨还「远离背景」，
    所以不能按「离背景最远」取墨色。改用：出现次数最多的非背景色 = 墨色本体，
    再取它 ±6 的邻域求均值（邻域 = 无抗锯齿的厚笔画像素）。
    """
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
    return core.mean(axis=0), int(near.sum()), tuple(int(x) for x in modal), int(d.max())


def export_stats(png_path):
    """导出 PNG：取 alpha≥250 的墨色像素，同样按「众数 ±6 邻域」求均值，和屏幕侧口径一致。"""
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
    panels = []
    for key, title in STEPS:
        shot_path = os.path.join(SHOTS, key + ".png")
        im = Image.open(shot_path).convert("RGB")
        arr = np.array(im)
        box, bg = find_artboard(arr)
        if box is None:
            print("!! %s 没定位到画板" % shot_path)
            return 1
        crop = arr[box[1]:box[3], box[0]:box[2]]
        s_mean, s_n, s_modal, dmax = ink_stats(crop, bg)

        media_dir = os.path.join(EXPORT, key, "Media")
        media = sorted(os.listdir(media_dir))
        media = [m for m in media if m.lower().endswith(".png")]
        if not media:
            print("!! %s 没有导出 PNG" % media_dir)
            return 1
        e_mean, e_n, e_modal, e_alpha = export_stats(os.path.join(media_dir, media[0]))

        diff = s_mean - e_mean
        alpha_diff = int((src_alpha != e_alpha).sum()) if src_alpha.shape == e_alpha.shape else -1
        rows.append(dict(mode=title, key=key, shot=shot_path, media=os.path.join(media_dir, media[0]),
                         artboard_box=box, screen_mean=[round(float(x), 2) for x in s_mean],
                         screen_n=s_n, screen_modal=s_modal, screen_maxdelta=dmax,
                         export_mean=[round(float(x), 2) for x in e_mean], export_n=e_n, export_modal=e_modal,
                         delta=[round(float(x), 2) for x in diff],
                         alpha_diff_pixels=alpha_diff, src_pixels=int(src_alpha.size)))
        panels.append((title, crop, s_mean, e_mean, diff))

    print("== 导出 vs 屏幕 均值对比（0–255）==")
    print("%-10s %-27s %-27s %-24s" % ("模式", "屏幕均值 R,G,B", "导出均值 R,G,B", "逐通道差值 (屏-导)"))
    for r in rows:
        print("%-10s %-27s %-27s %-24s" % (
            r["mode"], fmt(r["screen_mean"]), fmt(r["export_mean"]),
            "(%+.1f, %+.1f, %+.1f)" % tuple(r["delta"])))
    print()
    print("== 形状（alpha）保持 ==")
    for r in rows:
        print("%-10s alpha 差异像素 %d / %d" % (r["mode"], r["alpha_diff_pixels"], r["src_pixels"]))
    print()
    print("== 墨色众数（厚笔画像素，排除抗锯齿）==")
    for r in rows:
        print("%-10s 屏幕众数 %-18s 导出众数 %s" % (r["mode"], str(r["screen_modal"]), str(r["export_modal"])))

    # ── 补充：带明暗梯度的墨（黑→灰），direct / luminance 的差别在这里能数出来 ──
    grad = []
    for key, title in [("06_direct_gradient", "直接替换"), ("07_luminance_gradient", "明暗上色")]:
        shot = os.path.join(SHOTS, key + ".png")
        media_dir = os.path.join(EXPORT, key, "Media")
        if not (os.path.exists(shot) and os.path.isdir(media_dir)):
            continue
        ms = sorted(m for m in os.listdir(media_dir) if m.lower().endswith(".png"))
        if not ms:
            continue
        e_mean, e_n, e_modal, _ = export_stats(os.path.join(media_dir, ms[0]))
        arr = np.array(Image.open(os.path.join(media_dir, ms[0])).convert("RGBA"))
        opaque = arr[:, :, 3] >= 250
        px = arr[:, :, :3][opaque].astype(np.float64)
        grad.append(dict(mode=title, key=key, mean=[round(float(x), 2) for x in e_mean],
                         std=[round(float(x), 2) for x in px.std(axis=0)], modal=e_modal, n=e_n))

    if grad:
        print()
        print("== 补充：明暗梯度墨（黑→灰渐变），导出 PNG 的墨色标准差 ==")
        for g in grad:
            print("%-10s 均值 %-24s 标准差 %-22s 众数 %s" % (
                g["mode"], fmt(g["mean"]), "(%.2f, %.2f, %.2f)" % tuple(g["std"]), str(g["modal"])))

    # ── 2×2 并排对照图（面板全部来自真机截图，只做裁切+缩放+贴标签）──
    panel_w, panel_h = 640, 320
    label_h = 92
    W = panel_w * 2 + 30
    H = (panel_h + label_h) * 2 + 30
    mont = Image.new("RGB", (W, H), (14, 16, 20))
    draw = ImageDraw.Draw(mont)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 20)
        font_s = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 16)
    except Exception:
        font = ImageFont.load_default()
        font_s = font

    for i, (title, crop, s_mean, e_mean, diff) in enumerate(panels):
        im = Image.fromarray(crop)
        im.thumbnail((panel_w, panel_h))
        px = 10 + (i % 2) * (panel_w + 10)
        py = 10 + (i // 2) * (panel_h + label_h + 10)
        ox = px + (panel_w - im.width) // 2
        oy = py + (panel_h - im.height) // 2
        mont.paste(im, (ox, oy))
        draw.text((px + 4, py + panel_h + 6), "%s  (%s)" % (title, STEPS[i][0]), fill=(240, 240, 245), font=font)
        draw.text((px + 4, py + panel_h + 34),
                  "屏幕 %s   导出 %s" % (fmt(s_mean), fmt(e_mean)), fill=(150, 210, 240), font=font_s)
        draw.text((px + 4, py + panel_h + 58),
                  "差值 (%+.1f, %+.1f, %+.1f)" % tuple(diff), fill=(150, 235, 170), font=font_s)
    mont.save(OUT_MONTAGE)
    print()
    print("并排对照图: %s (%dx%d)" % (OUT_MONTAGE, W, H))

    with open(os.path.join(SHOTS, "means.json"), "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print("数值台账: %s" % os.path.join(SHOTS, "means.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
