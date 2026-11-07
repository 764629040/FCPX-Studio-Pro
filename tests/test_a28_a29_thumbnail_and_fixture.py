"""
回归测试：第十四轮 A-28 / A-29

A-28 缩略图硬编码 640×360，竖版被拉伸 3.16 倍
  根因：core/thumbnail.py 对任意画幅都 resize((640,360)) / ((192,108))
  修复：新增 fit_thumbnail_size()，按长边等比缩放，保持源画幅

A-29 所谓"竖版"夹具实为横版只改画布
  现象：vertical_wedding_9_16.psd 画布 1080×1920，但背景层 bbox=(0,0,1920,1080)
        越界 840×840；8 层文字纵向中心均值 464，画布中心 960
        后果：psd-tools bbox 越界时读错像素，large.png 出现红绿彩条
  修复：新增 tests/make_vertical_true_fixture.py 生成 vertical_9x16_true.psd
        画布 1080×1920 + 背景层严格 (0,0,1080,1920) + 8 层文字纵向均匀分布
"""
import os
import sys
import glob
import tempfile
import collections

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from PIL import Image
from psd_tools import PSDImage

from core.thumbnail import (
    fit_thumbnail_size,
    generate_thumbnails_from_psd,
    THUMB_LONG_EDGE_LARGE,
    THUMB_LONG_EDGE_SMALL,
)

DATA_DIR = os.path.join(TESTS_DIR, "data")
TRUE_VERTICAL = os.path.join(DATA_DIR, "vertical_9x16_true.psd")
TRUE_VERTICAL_META = os.path.join(DATA_DIR, "vertical_9x16_true.json")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
LEGACY_VERTICAL = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")


# ═══════════════════════════════════════════════════════════════
# A-28：缩略图必须保持源画幅
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("w,h,expect_large,expect_small", [
    (1920, 1080, (640, 360), (192, 108)),    # 16:9
    (1080, 1920, (360, 640), (108, 192)),    # 9:16
    (1080, 1080, (640, 640), (192, 192)),    # 1:1
    (3840, 2160, (640, 360), (192, 108)),    # 4K 16:9
    (2160, 3840, (360, 640), (108, 192)),    # 4K 竖版
])
def test_28_fit_thumbnail_size_preserves_aspect(w, h, expect_large, expect_small):
    """A-28 核心：按长边等比缩放，不得拉伸短边"""
    assert fit_thumbnail_size(w, h, THUMB_LONG_EDGE_LARGE) == expect_large
    assert fit_thumbnail_size(w, h, THUMB_LONG_EDGE_SMALL) == expect_small


def test_28_aspect_ratio_deviation_is_zero():
    """A-28：缩放前后宽高比偏差应接近 0"""
    for w, h in [(1920, 1080), (1080, 1920), (1080, 1080), (2160, 3840)]:
        src = w / h
        tw, th = fit_thumbnail_size(w, h, THUMB_LONG_EDGE_LARGE)
        got = tw / th
        dev = abs(got - src) / src
        assert dev < 0.01, f"{w}x{h} 比例偏差 {dev*100:.2f}%"


def test_28_vertical_thumbnail_not_stretched():
    """
    A-28 反例守卫：竖版不得再产出 640×360。
    原实现会横向拉伸 3.16 倍（640/1920 * 1080/360 的分量）。
    """
    w, h = fit_thumbnail_size(1080, 1920, THUMB_LONG_EDGE_LARGE)
    assert (w, h) != (640, 360), "竖版仍被拉伸成横版缩略图（A-28 未修复）"
    assert h > w, "竖版缩略图应满足高 > 宽"


def test_28_generated_thumbnails_match_source_ratio(tmp_path):
    """A-28：真实生成的文件，其宽高比必须等于源 PSD"""
    if not os.path.isfile(TRUE_VERTICAL):
        pytest.skip("真竖版夹具未生成")

    psd = PSDImage.open(TRUE_VERTICAL)
    large_p, small_p = generate_thumbnails_from_psd(psd, str(tmp_path))

    src_ratio = psd.width / psd.height
    for path in (large_p, small_p):
        im = Image.open(path)
        got = im.width / im.height
        dev = abs(got - src_ratio) / src_ratio
        assert dev < 0.01, f"{os.path.basename(path)} 比例偏差 {dev*100:.2f}%"


def test_28_end_to_end_vertical_not_640x360(tmp_path):
    """
    A-28 端到端守卫：必须走真实生成路径（generate_thumbnails_from_psd），
    不能只测 fit_thumbnail_size 纯函数——否则回滚调用点后测试仍会通过。
    """
    if not os.path.isfile(TRUE_VERTICAL):
        pytest.skip("真竖版夹具未生成")

    psd = PSDImage.open(TRUE_VERTICAL)
    large_p, small_p = generate_thumbnails_from_psd(psd, str(tmp_path))

    li = Image.open(large_p)
    si = Image.open(small_p)

    assert (li.width, li.height) != (640, 360), (
        f"竖版 large.png 仍为 {li.size}，说明调用点未使用等比缩放"
    )
    assert li.height > li.width, f"竖版 large.png 应高>宽，实际 {li.size}"
    assert si.height > si.width, f"竖版 small.png 应高>宽，实际 {si.size}"


def test_28_landscape_behavior_unchanged():
    """兼容性：16:9 源仍产出 640×360 / 192×108，与旧行为一致"""
    assert fit_thumbnail_size(1920, 1080, 640) == (640, 360)
    assert fit_thumbnail_size(1920, 1080, 192) == (192, 108)


# ═══════════════════════════════════════════════════════════════
# A-29：真竖版夹具的几何自洽性
# ═══════════════════════════════════════════════════════════════
def test_29_true_vertical_fixture_exists():
    """A-29：新夹具必须真实存在且可解析"""
    assert os.path.isfile(TRUE_VERTICAL), f"真竖版夹具缺失: {TRUE_VERTICAL}"
    psd = PSDImage.open(TRUE_VERTICAL)
    assert (psd.width, psd.height) == (1080, 1920)


def test_29_background_layer_not_out_of_bounds():
    """
    A-29 核心：背景层 bbox 必须严格等于画布，不得越界。
    旧夹具背景层 (0,0,1920,1080) 在 1080×1920 画布上越界 840×840。
    """
    psd = PSDImage.open(TRUE_VERTICAL)
    offenders = []
    for layer in psd:
        l_, t, r, b = layer.bbox
        if r > psd.width or b > psd.height or l_ < 0 or t < 0:
            offenders.append((layer.name, layer.bbox))
    assert not offenders, f"存在越界图层（旧夹具的问题形态）: {offenders}"


def test_29_text_layers_vertically_centered():
    """
    A-29：8 层文字的纵向中心应分布在画布中部区域，
    而不是像旧夹具那样全部挤在上半部（均值 464 vs 画布中心 960）。
    """
    psd = PSDImage.open(TRUE_VERTICAL)
    centers = []
    for layer in psd:
        if layer.name.lower().startswith("text"):
            l_, t, r, b = layer.bbox
            centers.append((t + b) / 2.0)

    assert len(centers) >= 8, f"文本层不足 8：{len(centers)}"
    canvas_center = psd.height / 2.0
    mean_center = sum(centers) / len(centers)
    # 均值应接近画布中心（允许 15% 偏差）
    assert abs(mean_center - canvas_center) < psd.height * 0.15, (
        f"文字纵向中心均值 {mean_center:.0f} 偏离画布中心 {canvas_center:.0f} 过远"
    )
    # 应跨越画布中部：既有在中线之上也有之下
    assert min(centers) < canvas_center < max(centers), "文字未跨越画布中线"


def test_29_composite_has_no_color_noise():
    """
    A-29 核心：合成图不得出现红绿彩条乱码。
    旧夹具实测纯红 84 像素 + 纯绿 40 像素（bbox 越界读取错误）。
    """
    psd = PSDImage.open(TRUE_VERTICAL)
    im = psd.composite().convert("RGB")
    c = collections.Counter()
    for y in range(0, im.height, 20):
        for x in range(0, im.width, 20):
            c[im.getpixel((x, y))] += 1

    red = sum(n for (r, g, b), n in c.items() if r > 200 and g < 80 and b < 80)
    green = sum(n for (r, g, b), n in c.items() if g > 200 and r < 80 and b < 80)
    assert red == 0, f"合成图出现 {red} 个纯红像素（彩条乱码）"
    assert green == 0, f"合成图出现 {green} 个纯绿像素（彩条乱码）"


def test_29_legacy_fixture_known_defect_documented():
    """
    A-29 记录：旧夹具的缺陷应可被复现（证明我们不是凭空断言）。
    该断言锁定"旧夹具确实是横版只改画布"这一事实，
    防止将来有人误把它当作竖版版式基准。
    """
    if not os.path.isfile(LEGACY_VERTICAL):
        pytest.skip("旧夹具不存在")
    psd = PSDImage.open(LEGACY_VERTICAL)
    assert psd.width == 1080 and psd.height == 1920

    # 背景层越界 → 证明它是横版内容
    bg = [l for l in psd if l.name == "图层 0"]
    if bg:
        l_, t, r, b = bg[0].bbox
        assert r > psd.width, "旧夹具背景层应越界（即横版内容塞进竖版画布）"


def test_29_fixture_metadata_available():
    """A-29：中文原名应记录在旁路元数据中（PSD 层名走 macroman 不支持中文）"""
    if not os.path.isfile(TRUE_VERTICAL_META):
        pytest.skip("元数据未生成")
    import json
    with open(TRUE_VERTICAL_META, encoding="utf-8") as f:
        meta = json.load(f)
    assert meta["canvas"] == [1080, 1920]
    assert len(meta["layers"]) >= 8
