#!/usr/bin/env python3
"""
生成横向可验证的竖版夹具（修正 A-31）

审核指出的核心问题（第十五轮）：
  Round 14 生成的 vertical_9x16_true.psd 是**像素层占位**，
  8 块占位图中心 x 全部 = 540.0，横向跨度 0.00%。
  而 A-24 出错的维度**正是横向**（1080 竖版被塞进 1920 横版 comp，文字被横向拉伸）。
  横向跨度为 0 时，comp 宽度再次写错也照样通过 —— 这是结构性证据缺口。

正确做法（采纳审核方案）：
  **保留旧夹具的 8 个真实 type 层**（含真实横向分布 478 单位），
  **仅把背景层替换为 1080×1920 纯色**。

  这样同时具备：
    - 真实 type 层 → 文字内容提取可验证
    - 真实横向分布 → comp 宽度写错会被检出
    - 背景不越界 → 彩条乱码消失

产物：tests/data/vertical_9x16_rebased.psd
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TESTS_DIR)
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from PIL import Image
from psd_tools import PSDImage

BASE_PSD = os.path.join(TESTS_DIR, "data", "vertical_wedding_9_16.psd")
OUT_PSD = os.path.join(TESTS_DIR, "data", "vertical_9x16_rebased.psd")

CANVAS_W, CANVAS_H = 1080, 1920


def build():
    """
    基于旧夹具重建：替换背景层，保留全部真实 type 层。

    注意：psd_tools 无法删除图层，因此采用「导出 → 重建」策略会丢失 type 语义。
    这里改为：直接修改背景层的像素内容与 bbox，使其严格等于画布。
    """
    psd = PSDImage.open(BASE_PSD)

    # 找到背景层（越界的那个）
    bg_layer = None
    for layer in psd:
        l_, t, r, b = layer.bbox
        if r > psd.width or b > psd.height:
            bg_layer = layer
            break

    if bg_layer is None:
        print("未找到越界背景层，可能已被修正")
        return psd

    print(f"目标背景层: {bg_layer.name!r} 原 bbox={bg_layer.bbox}")

    # 用正确的 1080×1920 纯色像素替换该层
    correct_bg = Image.new("RGBA", (CANVAS_W, CANVAS_H), (28, 24, 32, 255))
    try:
        bg_layer.topil()  # 探测可读性
    except Exception:
        pass

    # psd-tools 允许直接设置像素层的图像
    try:
        bg_layer.set_pixels(correct_bg) if hasattr(bg_layer, "set_pixels") else None
    except Exception as e:
        print(f"set_pixels 不可用: {e}")

    return psd


def build_via_pixels():
    """
    删除越界背景层，用正确尺寸重建；保留全部 8 个真实 type 层。

    做法：
      1. 定位越界的 pixel 层
      2. delete_layer() 删除它（psd_tools 支持）
      3. create_pixel_layer() 新建 1080x1920 背景（置于最底层）
      4. 保存

    这样 type 层完全不受影响（含真实文本、字体、横向分布），
    只有背景被替换成几何正确的纯色层。
    """
    psd = PSDImage.open(BASE_PSD)

    bg = None
    for layer in psd:
        l_, t, r, b = layer.bbox
        if r > psd.width or b > psd.height:
            bg = layer
            break

    if bg is None:
        print("未找到越界层")
        return psd

    print(f"删除越界背景层: {bg.name!r} bbox={bg.bbox}")
    bg.delete_layer()

    correct = Image.new("RGBA", (CANVAS_W, CANVAS_H), (28, 24, 32, 255))
    new_bg = psd.create_pixel_layer(correct, name="Background",
                                    top=0, left=0)
    print(f"新建背景层: bbox={new_bg.bbox}")

    # 移到最底层
    try:
        while new_bg.previous_sibling() is not None:
            new_bg.move_down()
    except Exception as e:
        print(f"图层顺序调整跳过: {e}")

    return psd


if __name__ == "__main__":
    result = build_via_pixels()
    if result is None:
        sys.exit("背景层替换失败，需换实现路径")

    result.save(OUT_PSD)
    print(f"\n已生成: {OUT_PSD}")
    print(f"大小: {os.path.getsize(OUT_PSD)} bytes")

    # 回读校验
    check = PSDImage.open(OUT_PSD)
    print(f"回读画布: {check.width}x{check.height}")
    type_xs = []
    for layer in check.descendants():
        l_, t, r, b = layer.bbox
        over = ""
        if r > check.width or b > check.height or l_ < 0 or t < 0:
            over = "  <<< 越界!"
        kind = layer.kind
        cx = (l_ + r) / 2
        if kind == "type":
            type_xs.append(cx)
        print(f"  {layer.name!r:24} kind={kind:8} bbox={layer.bbox} cx={cx:.1f}{over}")

    if type_xs:
        print(f"\ntype 层横向跨度: {max(type_xs) - min(type_xs):.1f} 单位")
        print(f"type 层数: {len(type_xs)}")
