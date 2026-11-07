"""
回归测试：第十五轮 A-30 / A-31

A-30 合成路径缺少 bbox 越界防护
  问题：Round 14 只换了干净样本，`thumbnail.py` 没有防护，
        任何真实畸形 PSD 仍会产出红绿彩条乱码预览。根因未修。
  修复：新增 crop_composite_to_canvas() + has_out_of_bounds_layers()，
        合成图与画布尺寸不符时裁剪回收，并把越界情况写入旁路告警。

A-31 横向零覆盖导致证据缺口
  问题：Round 14 的 vertical_9x16_true.psd 是像素层占位，
        8 块中心 x 全部 = 540.0，横向跨度 0.00%；
        而 A-24 出错的维度正是横向 —— comp 宽度再次写错也照样通过。
  修复：新增 tests/make_vertical_rebased_fixture.py，
        保留旧夹具 8 个真实 type 层（横向跨度 478.0），仅替换背景层 bbox。
        新增横向断言：中心 x 跨度 > 0 且等于源 PSD 跨度 ±0.5 单位。
"""
import os
import sys
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
    generate_thumbnails_from_psd,
    crop_composite_to_canvas,
    has_out_of_bounds_layers,
)
from core.psd_parser import parse_psd_file

DATA_DIR = os.path.join(TESTS_DIR, "data")
REBASED_PSD = os.path.join(DATA_DIR, "vertical_9x16_rebased.psd")
LEGACY_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
PLACEHOLDER_PSD = os.path.join(DATA_DIR, "vertical_9x16_true.psd")


def _type_centers(psd):
    return [((layer.bbox[0] + layer.bbox[2]) / 2.0)
            for layer in psd.descendants() if layer.kind == "type"]


# ═══════════════════════════════════════════════════════════════
# A-30：bbox 越界防护
# ═══════════════════════════════════════════════════════════════
def test_30_detector_flags_legacy_out_of_bounds():
    """A-30：越界检测必须能识别旧夹具（证明检测器真的工作）"""
    psd = PSDImage.open(LEGACY_PSD)
    assert has_out_of_bounds_layers(psd) is True, "未检出旧夹具的越界层"


def test_30_detector_passes_clean_fixture():
    """A-30：干净夹具不得误报"""
    psd = PSDImage.open(REBASED_PSD)
    assert has_out_of_bounds_layers(psd) is False, "干净夹具被误判为越界"


def test_30_crop_helper_collapses_oversized_composite():
    """A-30：合成图大于画布时应收敛到画布尺寸"""
    img = Image.new("RGBA", (1920, 1080), (255, 0, 0, 255))
    out, adjusted = crop_composite_to_canvas(img, 1080, 1920)
    assert adjusted is True
    assert out.width <= 1080 and out.height <= 1920


def test_30_crop_helper_passthrough_when_matching():
    """A-30：尺寸已匹配时零开销直接返回"""
    img = Image.new("RGBA", (1080, 1920), (0, 0, 0, 255))
    out, adjusted = crop_composite_to_canvas(img, 1080, 1920)
    assert adjusted is False
    assert out.size == (1080, 1920)


def test_30_perlayer_composite_eliminates_color_noise(tmp_path):
    """
    A-30 口径 C 验收（第十六轮审核裁定）：合成方式改逐层贴图后，
    旧夹具彩条必须为 0/0，非透明率 >= 99%。

    历史记录（如实保留）：
      - Round 14 交付时用 composite()+crop，旧夹具缩略图仍有 119/48 彩条；
        我曾错误声称"已消除"，实为 step=10 采样漏检。
      - Round 15 因 crop 不触发而判定"代码层做不到"——该结论已被证伪：
        审核用逐层贴图原型实测旧夹具 0/0，证明路径可行。
      - Round 16 改为逐层贴图后，实测 0/0 且非透明率 100%。
    """
    psd = PSDImage.open(LEGACY_PSD)
    large_p, _ = generate_thumbnails_from_psd(psd, str(tmp_path))

    im = Image.open(large_p).convert("RGBA")
    px = im.load()
    red = green = 0
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if r > 200 and g < 80 and b < 80:
                red += 1
            elif g > 200 and r < 80 and b < 80:
                green += 1

    assert red == 0, f"旧夹具缩略图仍有 {red} 个纯红像素"
    assert green == 0, f"旧夹具缩略图仍有 {green} 个纯绿像素"

    alpha = im.split()[3]
    opaque = sum(1 for v in alpha.getdata() if v > 0)
    ratio = opaque / (im.width * im.height)
    assert ratio >= 0.99, f"非透明率 {ratio*100:.2f}% < 99%"

    # 越界检测仍应能识别该夹具（检测能力保留）
    assert has_out_of_bounds_layers(psd) is True


def test_30_detector_is_the_real_value():
    """
    A-30 的真正价值：**检测器**能识别畸形 PSD，
    crop 只是尺寸兜底（本夹具上不触发）。

    检测能力才是"真实畸形 PSD 不再静默流出"的关键。
    """
    assert has_out_of_bounds_layers(PSDImage.open(LEGACY_PSD)) is True
    assert has_out_of_bounds_layers(PSDImage.open(REBASED_PSD)) is False


# ═══════════════════════════════════════════════════════════════
# A-31：横向分布必须可验证
# ═══════════════════════════════════════════════════════════════
def test_31_rebased_fixture_exists():
    """A-31：新夹具必须存在且可解析"""
    assert os.path.isfile(REBASED_PSD), f"缺少 {REBASED_PSD}"
    psd = PSDImage.open(REBASED_PSD)
    assert (psd.width, psd.height) == (1080, 1920)


def test_31_horizontal_span_matches_source():
    """
    A-31 核心：中心 x 跨度 > 0，且等于源 PSD 跨度 ±0.5 单位。
    Round 14 的占位夹具跨度为 0.00%，此断言专门锁定该缺口。
    """
    src = PSDImage.open(LEGACY_PSD)
    rebased = PSDImage.open(REBASED_PSD)

    src_xs = _type_centers(src)
    new_xs = _type_centers(rebased)

    assert len(src_xs) == 8 and len(new_xs) == 8, "应各含 8 个 type 层"

    src_span = max(src_xs) - min(src_xs)
    new_span = max(new_xs) - min(new_xs)

    assert new_span > 0, f"横向跨度仍为 0（A-31 未修复）"
    assert abs(new_span - src_span) <= 0.5, (
        f"横向跨度 {new_span:.1f} 与源 {src_span:.1f} 相差超过 0.5 单位"
    )


def test_31_horizontal_span_is_not_zero_guard():
    """
    A-31 反例守卫：横向跨度不得为 0。
    专门防止退回"8 块中心全在 540"的占位形态。
    """
    psd = PSDImage.open(REBASED_PSD)
    xs = _type_centers(psd)
    span = max(xs) - min(xs)
    assert span > 1.0, f"横向跨度过小 {span:.2f}，可能是占位夹具"
    assert len(set(round(x, 1) for x in xs)) > 1, "所有中心 x 相同，横向无区分度"


def test_31_real_type_layers_preserved():
    """A-31：必须是真实 type 层，不是像素占位"""
    parsed = parse_psd_file(REBASED_PSD, extract_thumbnails=False)
    type_layers = [l for l in parsed["layers"] if l.kind == "type"]
    assert len(type_layers) == 8, f"type 层应为 8，实际 {len(type_layers)}"

    texts = [l.text for l in type_layers if l.text]
    assert texts, "未能提取到任何文本内容"
    assert any("领" in t for t in texts), "未提取到预期中文内容"


def test_31_background_not_out_of_bounds():
    """A-31：背景层 bbox 必须严格等于画布"""
    psd = PSDImage.open(REBASED_PSD)
    for layer in psd:
        if layer.kind == "pixel":
            l_, t, r, b = layer.bbox
            assert (l_, t, r, b) == (0, 0, 1080, 1920), (
                f"背景层 bbox {layer.bbox} 不等于画布"
            )


def test_31_composite_clean():
    """A-31：合成图无彩条乱码"""
    psd = PSDImage.open(REBASED_PSD)
    im = psd.composite().convert("RGB")
    c = collections.Counter()
    for y in range(0, im.height, 20):
        for x in range(0, im.width, 20):
            c[im.getpixel((x, y))] += 1
    red = sum(n for (r, g, b), n in c.items() if r > 200 and g < 80 and b < 80)
    green = sum(n for (r, g, b), n in c.items() if g > 200 and r < 80 and b < 80)
    assert red == 0 and green == 0, f"合成图有彩条: 红{red} 绿{green}"


def test_31_placeholder_fixture_documented_as_insufficient():
    """
    A-31 记录：Round 14 的占位夹具横向跨度为 0，
    证明它只能验纵向、不能验横向。此断言锁定该事实，
    防止将来有人误把它当版式基准。
    """
    if not os.path.isfile(PLACEHOLDER_PSD):
        pytest.skip("占位夹具不存在")
    psd = PSDImage.open(PLACEHOLDER_PSD)
    xs = [((l.bbox[0] + l.bbox[2]) / 2.0)
          for l in psd.descendants()
          if l.name.lower().startswith("text")]
    assert len(xs) >= 8
    assert max(xs) - min(xs) == 0.0, "占位夹具横向跨度应为 0（可验纵向、不可验横向）"
