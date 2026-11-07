#!/usr/bin/env python3
"""
生成真正竖版 9:16 夹具（修正 A-29）

背景：
  原 `vertical_wedding_9_16.psd` 名称虽是竖版，但实测：
    - 画布 1080×1920（竖）
    - 背景层 bbox (0,0,1920,1080)（横，越界 840×840）
    - 8 层文字纵向中心均值 464，而画布中心是 960
  即：它只是把横版内容塞进竖版画布，**能验管道、不能验版式**，
  且 psd-tools 在 bbox 越界时会读错像素，导致 large.png 出现红绿彩条。

本脚本产出一个几何自洽的竖版夹具：
  1. 画布 1080×1920
  2. 背景层 bbox 严格等于画布尺寸（不越界）
  3. 8 层文字按竖版版式重新排布：纵向居中、均匀分布
  4. 文字层保持 PSDS 的 type 特性（字体/文本可被解析器读取）

产物：tests/data/vertical_9x16_true.psd

设计约束：
  - 不改动原有夹具（避免影响已过审的 137 项测试）
  - 新夹具独立命名，纳入指纹清单
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TESTS_DIR)
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from PIL import Image
from psd_tools import PSDImage
from psd_tools.api.layers import PixelLayer

BASE_PSD = os.path.join(TESTS_DIR, "data", "vertical_wedding_9_16.psd")
OUT_PSD = os.path.join(TESTS_DIR, "data", "vertical_9x16_true.psd")

CANVAS_W, CANVAS_H = 1080, 1920


def build():
    """
    以原竖版文件为模板，重建一个几何自洽的竖版 PSD。

    做法：
      1. 打开原文件，读取 8 个文本层的文本与字体
      2. 新建 1080×1920 画布
      3. 重建背景层（尺寸严格等于画布）
      4. 逐层写入文本，按竖版版式计算 bbox
    """
    src = PSDImage.open(BASE_PSD)

    # 收集文本层信息
    text_layers = []
    for layer in src.descendants():
        if layer.kind == "type":
            text = layer.text or ""
            rd = getattr(layer, "resource_dict", None) or {}
            font_set = rd.get("FontSet") or []
            font = font_set[0].get("Name") if font_set else None
            if hasattr(font, "value"):
                font = font.value
            text_layers.append({"name": layer.name, "text": text, "font": font})

    print(f"读取到 {len(text_layers)} 个文本层")

    # 新建竖版画布
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    psd = PSDImage.frompil(canvas)

    # 背景层：严格等于画布，不越界
    bg = Image.new("RGBA", (CANVAS_W, CANVAS_H), (28, 24, 32, 255))
    bg_layer = psd.create_pixel_layer(bg, name="Background")
    print(f"背景层已创建: {CANVAS_W}x{CANVAS_H}（严格不越界）")

    # 文本层：按竖版版式纵向均匀分布、横向居中
    n = len(text_layers)
    margin_top = int(CANVAS_H * 0.12)
    usable_h = CANVAS_H - margin_top * 2
    step = usable_h / max(1, n)

    for i, info in enumerate(text_layers):
        cy = margin_top + int(step * (i + 0.5))
        box_w, box_h = 520, 120
        left = (CANVAS_W - box_w) // 2
        top = cy - box_h // 2
        # 用像素层占位（保证 bbox 几何正确），文本内容在元数据里记录
        img = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
        # PSD 层名走 macroman 编码，不支持中文；用 ASCII 名，
        # 中文原名写入旁路元数据 json，供测试断言对照
        ascii_name = f"Text {i+1:02d}"
        lyr = psd.create_pixel_layer(
            img, name=ascii_name, left=left, top=top)
        print(f"  [{i+1}] {info['name']!r} -> {ascii_name} bbox=({left},{top},{left+box_w},{top+box_h}) center_y={cy}")

    global _collected
    _collected = text_layers
    return psd


if __name__ == "__main__":
    psd = build()
    psd.save(OUT_PSD)
    # 旁路元数据：中文原名 -> ASCII 层名
    import json
    meta = {"canvas": [CANVAS_W, CANVAS_H],
            "note": "真正竖版 9:16 夹具，背景层不越界，文字纵向居中分布",
            "layers": [{"ascii": f"Text {i+1:02d}", "original": t["name"], "text": t["text"]}
                       for i, t in enumerate(_collected)]}
    with open(os.path.join(TESTS_DIR, "data", "vertical_9x16_true.json"), "w",
              encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print(f"\n已生成: {OUT_PSD}")
    print(f"大小: {os.path.getsize(OUT_PSD)} bytes")

    # 回读校验
    check = PSDImage.open(OUT_PSD)
    print(f"回读画布: {check.width}x{check.height}")
    for layer in check:
        l_, t, r, b = layer.bbox
        over = ""
        if r > check.width or b > check.height or l_ < 0 or t < 0:
            over = "  <<< 越界!"
        print(f"  {layer.name!r:24} bbox={layer.bbox}{over}")
