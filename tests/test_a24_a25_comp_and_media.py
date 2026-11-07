"""
回归测试：第十三轮 P1 缺陷 A-24 / A-25

A-24 画布尺寸未写入（竖版 PSD 生成横版 comp）
  根因：motion_builder.build_moti 从不写 <sceneSettings>，
        模板沿用 reference_base.moti 硬编码的 1920×1080。
  影响：1080×1920 竖版 PSD 产出 1920×1080 横版 comp，
        文字按 PSD 坐标 1:1 放入后右侧留 829 单位空黑。

A-25 Media 层丢失（构建或打包环节丢层）
  要求：Media 层数 == fallback_png 层数，且 Media/ 目录 PNG 数一致。

断言（审核要求补 3 条）：
  1. comp 宽高 == PSD 宽高（竖版/横版/方形均验证）
  2. Media 层数 == fallback_png 层数
  3. Media/ 目录 PNG 数 == Media 层数
"""
import os
import sys
import glob
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder

DATA_DIR = os.path.join(TESTS_DIR, "data")

VERTICAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")   # 1080x1920
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")           # 1920x1080
DECOR_PSD = os.path.join(DATA_DIR, "wedding_with_decorations_23.psd")  # 含 2 个降级层
FOUR_STATE_PSD = os.path.join(DATA_DIR, "four_state.psd")


# ═══════════════════════════════════════════════════════════════
# A-24：comp 宽高必须等于 PSD 宽高
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("psd,label", [
    (VERTICAL_PSD, "竖版 1080x1920"),
    (COMPLEX_PSD, "横版 1920x1080"),
    (FOUR_STATE_PSD, "四态 1080x1920"),
])
def test_24_comp_size_equals_psd_size(psd, label):
    """A-24 核心：写入 sceneSettings 的宽高必须等于 PSD 真实宽高"""
    parsed = parse_psd_file(psd, extract_thumbnails=False)
    mb = MotionBuilder()
    out = tempfile.mktemp(suffix=".moti")
    try:
        mb.build_moti(parsed["layers"], out, "T",
                      canvas_size=(parsed["width"], parsed["height"]))
        root = ET.parse(out).getroot()
        settings = root.find(".//sceneSettings")
        assert settings is not None, f"{label} 未生成 sceneSettings"
        w = settings.findtext("width")
        h = settings.findtext("height")
        assert w == str(parsed["width"]), f"{label} comp 宽 {w} != PSD {parsed['width']}"
        assert h == str(parsed["height"]), f"{label} comp 高 {h} != PSD {parsed['height']}"
    finally:
        if os.path.exists(out):
            os.unlink(out)


def test_24_vertical_is_not_hardcoded_landscape():
    """
    A-24 反例守卫：竖版 PSD 不得产出 1920×1080。
    这条专门锁定"沿用基准模板硬编码"这个缺陷形态。
    """
    parsed = parse_psd_file(VERTICAL_PSD, extract_thumbnails=False)
    assert parsed["width"] == 1080 and parsed["height"] == 1920

    mb = MotionBuilder()
    out = tempfile.mktemp(suffix=".moti")
    try:
        mb.build_moti(parsed["layers"], out, "T",
                      canvas_size=(parsed["width"], parsed["height"]))
        root = ET.parse(out).getroot()
        s = root.find(".//sceneSettings")
        w, h = int(s.findtext("width")), int(s.findtext("height"))
        assert not (w == 1920 and h == 1080), "竖版仍被写成横版 comp（A-24 未修复）"
        assert w < h, "竖版 comp 应满足宽 < 高"
    finally:
        if os.path.exists(out):
            os.unlink(out)


def test_24_without_canvas_size_keeps_base_default():
    """
    兼容性：不传 canvas_size 时保持原行为（不写 sceneSettings），
    避免破坏既有调用方的隐式契约。
    """
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    out = tempfile.mktemp(suffix=".moti")
    try:
        mb.build_moti(parsed["layers"], out, "T")
        assert os.path.getsize(out) > 1024
    finally:
        if os.path.exists(out):
            os.unlink(out)


# ═══════════════════════════════════════════════════════════════
# A-25：Media 层数必须等于 fallback_png 层数
# ═══════════════════════════════════════════════════════════════
@pytest.fixture(scope="module")
def decor_build(tmp_path_factory):
    """构建含装饰层的模板，供多条断言复用"""
    parsed = parse_psd_file(
        DECOR_PSD,
        extract_fallback_pngs=True,
        png_output_dir=str(tmp_path_factory.mktemp("pngs")),
        extract_thumbnails=False,
    )
    out_dir = tmp_path_factory.mktemp("tpl") / "t23"
    mb = MotionBuilder()
    mb.build_template_atomic(
        parsed["layers"], str(out_dir), "t23",
        psd_path=DECOR_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )
    moti = glob.glob(os.path.join(str(out_dir), "*.moti"))[0]
    return {"parsed": parsed, "dir": str(out_dir), "moti": moti}


def test_25_media_layer_count_matches_fallback_layers(decor_build):
    """A-25 核心：Media 层数 == fallback_png 层数"""
    parsed = decor_build["parsed"]
    expected = sum(1 for l in parsed["layers"] if l.kind == "fallback_png")
    assert expected >= 2, "夹具应含至少 2 个降级层"

    root = ET.parse(decor_build["moti"]).getroot()
    layers = root.findall(".//layer")
    media = [l for l in layers if (l.attrib.get("name") or "").startswith("Media")]

    assert len(media) == expected, (
        f"Media 层 {len(media)} != fallback_png {expected}（丢层）"
    )


def test_25_media_png_files_match_media_layers(decor_build):
    """A-25：Media/ 目录 PNG 数 == Media 层数"""
    root = ET.parse(decor_build["moti"]).getroot()
    media = [l for l in root.findall(".//layer")
             if (l.attrib.get("name") or "").startswith("Media")]

    media_dir = os.path.join(decor_build["dir"], "Media")
    pngs = [f for f in os.listdir(media_dir) if f.lower().endswith(".png")] \
        if os.path.isdir(media_dir) else []

    assert len(pngs) == len(media), f"PNG {len(pngs)} != Media 层 {len(media)}"


def test_25_total_layer_count(decor_build):
    """A-25：模板总层数 == type 层数 + fallback 层数"""
    parsed = decor_build["parsed"]
    counts = Counter(l.kind for l in parsed["layers"])
    expected = counts.get("type", 0) + counts.get("fallback_png", 0)

    root = ET.parse(decor_build["moti"]).getroot()
    total = len(root.findall(".//layer"))
    assert total == expected, f"模板层数 {total} != 预期 {expected}"


def test_25_no_dropped_layer_names(decor_build):
    """
    A-25 细节：每个 fallback_png 图层名都应出现在某个 Media 层名中，
    确保不是"数量对但内容错"。
    """
    parsed = decor_build["parsed"]
    root = ET.parse(decor_build["moti"]).getroot()
    media_names = " | ".join(
        l.attrib.get("name") or ""
        for l in root.findall(".//layer")
        if (l.attrib.get("name") or "").startswith("Media")
    )
    for layer in parsed["layers"]:
        if layer.kind != "fallback_png":
            continue
        assert layer.name in media_names, (
            f"降级层 {layer.name!r} 未出现在 Media 层名中: {media_names}"
        )
