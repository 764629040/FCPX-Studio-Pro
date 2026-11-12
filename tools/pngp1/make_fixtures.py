#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P1 测试图夹具：10 张可控真值图 + 3 张真样本登记。

可控图不是「画个色块」凑数：每张都按验收要判的四类摆位——
渐变/纯色/暗角/纹理背景、实心主体（带高光与 1px 描边）、成段文字（含竖排）、
独立装饰件（星形/细线/圆环/边框）。真值只在生成时写一次，评估脚本读它算 IoU，
不在算法里偷看。

用法：
  python3 tools/pngp1/make_fixtures.py --out reports/verify_pngp1/fixtures
"""
from __future__ import annotations

import argparse
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1920


def font(size: int, bold: bool = True, cjk: bool = False):
    if cjk:
        paths = ["/System/Library/Fonts/PingFang.ttc",
                 "/System/Library/Fonts/STHeiti Medium.ttc"]
    else:
        paths = [
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def gradient(w, h, top, bottom, horizontal=False):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for i in range(h if not horizontal else w):
        t = i / float((h if not horizontal else w) - 1)
        c = tuple(int(round(top[k] + (bottom[k] - top[k]) * t)) for k in range(3))
        if horizontal:
            d.line([(i, 0), (i, h)], fill=c)
        else:
            d.line([(0, i), (w, i)], fill=c)
    return im


def vignette(im, strength=0.55):
    w, h = im.size
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([-w * 0.25, -h * 0.15, w * 1.25, h * 1.15], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=max(8, w // 30)))
    dark = Image.new("RGB", (w, h), (0, 0, 0))
    return Image.composite(im, Image.blend(im, dark, strength), mask)


def draw_text_block(d, xy, text, fnt, fill, stroke=0, stroke_fill=None, vertical=False):
    x, y = xy
    boxes = []
    if vertical:
        for ch in text:
            d.text((x, y), ch, font=fnt, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)
            b = d.textbbox((x, y), ch, font=fnt, stroke_width=stroke)
            boxes.append(b)
            y += int(fnt.size * 1.12)
    else:
        d.text((x, y), text, font=fnt, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)
        boxes.append(d.textbbox((x, y), text, font=fnt, stroke_width=stroke))
    if not boxes:
        return [0, 0, 0, 0]
    return [min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes)]


def star(d, cx, cy, r, fill):
    pts = []
    for i in range(10):
        rr = r if i % 2 == 0 else r * 0.45
        a = -math.pi / 2 + i * math.pi / 5
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=fill)


def make_a():
    im = gradient(W, H, (18, 28, 64), (86, 32, 120))
    d = ImageDraw.Draw(im)
    # 装饰：星
    star(d, 150, 320, 52, (255, 206, 84))
    star(d, 940, 420, 34, (255, 206, 84))
    star(d, 120, 1520, 28, (255, 230, 140))
    # 装饰：细线
    d.rectangle([90, 1420, 990, 1426], fill=(240, 220, 160))
    # 主体：椭圆产品 + 高光 + 描边
    d.ellipse([300, 760, 780, 1380], fill=(238, 92, 76), outline=(255, 220, 210), width=3)
    d.ellipse([360, 820, 520, 980], fill=(255, 160, 150))
    # 文字
    f1 = font(150)
    b1 = draw_text_block(d, (120, 260), "SALE", f1, (255, 255, 255), stroke=4, stroke_fill=(40, 20, 60))
    f2 = font(64, bold=False)
    b2 = draw_text_block(d, (140, 480), "2026 AUTUMN", f2, (255, 226, 140))
    return im, {"text_bboxes": [b1, b2], "object_bboxes": [[300, 760, 780, 1380]],
                "element_count": 4, "bg": "gradient"}


def make_b():
    im = Image.new("RGB", (W, H), (246, 240, 228))
    d = ImageDraw.Draw(im)
    # 主体：产品盒
    d.rectangle([260, 900, 820, 1500], fill=(38, 52, 74))
    d.rectangle([300, 940, 780, 1120], fill=(58, 78, 108))
    # 装饰：边框 + 圆点
    d.rectangle([60, 60, W - 60, H - 60], outline=(196, 160, 96), width=6)
    for i in range(5):
        d.ellipse([480 + i * 30, 1620, 500 + i * 30, 1640], fill=(196, 160, 96))
    f1 = font(120)
    b1 = draw_text_block(d, (90, 230), "NEW", f1, (30, 40, 60))
    f2 = font(54, bold=False)
    b2 = draw_text_block(d, (95, 400), "PRODUCT 02", f2, (90, 96, 110))
    return im, {"text_bboxes": [b1, b2], "object_bboxes": [[260, 900, 820, 1500]],
                "element_count": 2, "bg": "flat"}


def make_c():
    im = gradient(W, H, (10, 12, 18), (34, 20, 26), horizontal=True)
    im = vignette(im, 0.65)
    d = ImageDraw.Draw(im)
    # 主体：圆形徽章
    d.ellipse([330, 820, 750, 1240], fill=(212, 175, 55), outline=(255, 236, 170), width=3)
    d.ellipse([390, 880, 690, 1180], fill=(28, 30, 40))
    # 装饰：四角小三角
    for (x, y) in [(90, 90), (W - 90, 90), (90, H - 90), (W - 90, H - 90)]:
        d.polygon([(x, y - 22), (x + 22, y), (x, y + 22), (x - 22, y)], fill=(255, 236, 170))
    f1 = font(170)
    b1 = draw_text_block(d, (90, 300), "GOLD", f1, (255, 228, 150), stroke=2, stroke_fill=(20, 16, 8))
    f2 = font(58, bold=False)
    b2 = draw_text_block(d, (95, 520), "LIMITED EDITION", f2, (226, 226, 232))
    return im, {"text_bboxes": [b1, b2], "object_bboxes": [[330, 820, 750, 1240]],
                "element_count": 4, "bg": "vignette"}


def make_d():
    im = gradient(W, H, (232, 214, 196), (206, 182, 158))
    d = ImageDraw.Draw(im)
    # 主体：挂牌
    d.rounded_rectangle([220, 720, 860, 1500], radius=36, fill=(252, 250, 246),
                        outline=(150, 120, 92), width=4)
    d.ellipse([420, 800, 660, 1040], fill=(120, 148, 172))
    # 装饰：挂绳 + 底部横线
    d.line([(330, 120), (540, 720)], fill=(120, 96, 76), width=10)
    d.line([(750, 120), (540, 720)], fill=(120, 96, 76), width=10)
    d.rectangle([330, 1600, 750, 1606], fill=(120, 96, 76))
    f1 = font(96)
    b1 = draw_text_block(d, (300, 1120), "NAME", f1, (60, 56, 52))
    f2 = font(52, bold=False)
    b2 = draw_text_block(d, (330, 1260), "STAFF 007", f2, (110, 104, 96))
    return im, {"text_bboxes": [b1, b2], "object_bboxes": [[220, 720, 860, 1500]],
                "element_count": 3, "bg": "gradient"}


def make_e():
    """伪 UI 截图：窗口 + 工具条图标 + 多行文字（真实产品里最常见的单图输入）。"""
    im = gradient(W, H, (28, 34, 46), (16, 18, 24))
    d = ImageDraw.Draw(im)
    # 主体窗口
    d.rounded_rectangle([80, 360, 1000, 1600], radius=18, fill=(244, 246, 250),
                        outline=(90, 100, 116), width=2)
    # 装饰：工具条图标
    for i in range(5):
        x = 120 + i * 74
        d.rounded_rectangle([x, 400, x + 48, 448], radius=8, fill=(70, 110, 200) if i % 2 == 0 else (200, 90, 90))
    # 装饰：分隔线
    d.rectangle([110, 480, 970, 482], fill=(200, 206, 216))
    texts = []
    f1 = font(76)
    texts.append(draw_text_block(d, (130, 540), "PROJECT", f1, (26, 32, 44)))
    f2 = font(40, bold=False)
    for i, line in enumerate(["Line one of the layout", "Line two of the layout", "Line three is longer"]):
        texts.append(draw_text_block(d, (132, 680 + i * 62), line, f2, (70, 78, 92)))
    f3 = font(34, bold=False)
    texts.append(draw_text_block(d, (132, 1500), "v1.0 / 2026-11-12", f3, (120, 126, 138)))
    return im, {"text_bboxes": texts, "object_bboxes": [[80, 360, 1000, 1600]],
                "element_count": 6, "bg": "gradient"}


def make_f():
    """低对比：浅灰底 + 浅灰字 + 白主体（考「不假色、不硬切」）。"""
    im = Image.new("RGB", (W, H), (208, 210, 214))
    d = ImageDraw.Draw(im)
    d.ellipse([300, 800, 780, 1400], fill=(246, 246, 248))
    star(d, 880, 300, 46, (188, 190, 196))
    f = font(120)
    b = draw_text_block(d, (120, 300), "SOFT", f, (150, 152, 158))
    return im, {"text_bboxes": [b], "object_bboxes": [[300, 800, 780, 1400]],
                "element_count": 2, "bg": "flat"}


def make_g():
    """竖排文字 + 横向主体。"""
    im = gradient(W, H, (40, 16, 24), (90, 30, 40), horizontal=True)
    d = ImageDraw.Draw(im)
    d.rectangle([420, 700, 820, 1300], fill=(240, 232, 214), outline=(120, 90, 60), width=3)
    f = font(86, cjk=True)
    b = draw_text_block(d, (120, 200), "竖向标题", f, (255, 226, 170), vertical=True)
    star(d, 900, 900, 40, (255, 226, 170))
    d.rectangle([760, 1500, 1000, 1506], fill=(255, 226, 170))
    return im, {"text_bboxes": [b], "object_bboxes": [[420, 700, 820, 1300]],
                "element_count": 2, "bg": "gradient"}


def make_h():
    im = Image.new("RGB", (W, H), (18, 80, 78))
    d = ImageDraw.Draw(im)
    # 主体：两只并排产品
    d.rounded_rectangle([120, 820, 460, 1420], radius=24, fill=(244, 226, 180))
    d.rounded_rectangle([560, 820, 940, 1420], radius=24, fill=(210, 120, 96))
    # 装饰：圆环
    d.ellipse([460, 300, 620, 460], outline=(244, 226, 180), width=8)
    f = font(110)
    b = draw_text_block(d, (120, 300), "PAIR", f, (244, 226, 180))
    return im, {"text_bboxes": [b], "object_bboxes": [[120, 820, 460, 1420], [560, 820, 940, 1420]],
                "element_count": 1, "bg": "flat"}


def make_i():
    """无文字：只有主体 + 装饰（验证「不臆造文字层」）。"""
    im = gradient(W, H, (240, 236, 228), (214, 206, 192))
    d = ImageDraw.Draw(im)
    d.ellipse([340, 760, 740, 1160], fill=(64, 88, 120))
    for i in range(3):
        d.rectangle([200 + i * 260, 1500, 240 + i * 260, 1540], fill=(150, 128, 96))
    return im, {"text_bboxes": [], "object_bboxes": [[340, 760, 740, 1160]],
                "element_count": 3, "bg": "gradient"}


def make_j():
    """小主体 + 大段文字（考文字/主体不互相吞）。"""
    im = gradient(W, H, (250, 248, 244), (232, 228, 220))
    d = ImageDraw.Draw(im)
    d.ellipse([760, 1500, 980, 1720], fill=(190, 60, 60))
    f1 = font(92)
    lines = ["THE QUICK", "BROWN FOX", "JUMPS OVER"]
    boxes = [draw_text_block(d, (90, 280 + i * 112), s, f1, (34, 36, 40)) for i, s in enumerate(lines)]
    d.rectangle([90, 240, 990, 244], fill=(34, 36, 40))
    return im, {"text_bboxes": boxes, "object_bboxes": [[760, 1500, 980, 1720]],
                "element_count": 1, "bg": "gradient"}


def make_k():
    """透明底海报：中间圆角卡片 + 卡内主体圆 + 卡内文字 + 卡外星形，四周全透明。

    覆盖 alpha 分支：源图自带透明底（不透明像素远低于 98%），
    洞必须保持透明、不做延展填色。
    """
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # 卡片：不透明底，撑住主体和文字
    d.rounded_rectangle([90, 420, 990, 1500], radius=36, fill=(28, 34, 50, 255))
    d.ellipse([390, 760, 690, 1060], fill=(228, 96, 72, 255))
    f1 = font(78)
    box = draw_text_block(d, (150, 520), "AUTUMN SALE", f1, (255, 255, 255, 255))
    f2 = font(58)
    box2 = draw_text_block(d, (150, 1180), "2026 COLLECTION", f2, (198, 206, 224, 255))
    # 卡片外悬浮装饰：星（下方透明区里）
    star(d, 540, 1680, 62, (255, 206, 84, 255))
    return im, {"text_bboxes": [box, box2], "object_bboxes": [[390, 760, 690, 1060]],
                "element_count": 1, "bg": "transparent"}


def make_l():
    """透明底纯文字条：只有两行字 + 一条分隔线，无主体（验证不臆造 OBJECT）。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f1 = font(96)
    box = draw_text_block(d, (120, 900), "TITLE ONLY", f1, (250, 250, 250, 255))
    f2 = font(64)
    box2 = draw_text_block(d, (120, 1030), "subtitle line", f2, (206, 210, 220, 255))
    d.rectangle([120, 880, 960, 884], fill=(250, 250, 250, 255))
    return im, {"text_bboxes": [box, box2], "object_bboxes": [], "element_count": 1,
                "bg": "transparent"}


MAKERS = {
    "A_gradient_text_object_decor": make_a,
    "B_flat_product_title": make_b,
    "C_vignette_badge": make_c,
    "D_card_portrait": make_d,
    "E_ui_screenshot": make_e,
    "F_low_contrast": make_f,
    "G_vertical_text": make_g,
    "H_two_objects": make_h,
    "I_no_text": make_i,
    "J_text_heavy": make_j,
    "K_transparent_poster": make_k,
    "L_transparent_text_only": make_l,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="reports/verify_pngp1/fixtures")
    ap.add_argument("--force", action="store_true",
                    help="覆盖已存在的夹具图（默认跳过，避免重跑打乱既有基线）")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    # 生成结果不是逐字节确定的（字体渲染/Pillow 编码会变），已入库的图必须保住：
    # 默认只补缺失的，要重做才加 --force。真值也按已存在条目增量合并，不整体重写。
    truth_path = os.path.join(out, "ground_truth.json")
    truth = {}
    if os.path.isfile(truth_path):
        with open(truth_path, encoding="utf-8") as f:
            truth = json.load(f)
    skipped = []
    for name, fn in MAKERS.items():
        p = os.path.join(out, name + ".png")
        if os.path.isfile(p) and not args.force:
            skipped.append(name)
            continue
        im, gt = fn()
        # 轻微整体模糊 0.4px，模拟真实成品图的抗锯齿，避免算法被「纯硬边」宠坏
        im = im.filter(ImageFilter.GaussianBlur(radius=0.4))
        im.save(p, optimize=True)
        gt["file"] = os.path.basename(p)
        gt["size"] = [W, H]
        truth[name] = gt
    with open(truth_path, "w", encoding="utf-8") as f:
        json.dump(truth, f, ensure_ascii=False, indent=2)
    print(json.dumps({"status": "ok", "count": len(truth), "written": sorted(set(MAKERS) - set(skipped)),
                      "skipped": sorted(skipped), "out": out}, ensure_ascii=False))


if __name__ == "__main__":
    main()
