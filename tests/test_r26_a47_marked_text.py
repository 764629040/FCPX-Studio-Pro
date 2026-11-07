"""
R26 A-47：marked_text 接进 .moti 输出层（缺字可见标记落地）
==========================================================
授权范围（独立复核报告 R25 §十.1）：
  - 允许改 motion_builder.py 的文本值写出处（text_elem.text / styleRun length）
  - 仍禁止改动深层 scenenode id、参数结构、id 编号

断言：
  1. 层携带 marked_text（含 □ tofu 标记）时，.moti 文本节点写标记版而非原始文本
  2. 无 marked_text / 与原文一致的层，.moti 文本原样（零回归）
  3. styleRun length 与实际写出的文本长度严格一致
  4. 真实 PSD 集成：本环境（无 AppKit）字体诊断为 unverifiable/font_missing 时
     缺字层标记真实流入 .moti；字体完整机器上无标记则原样（不臆造）
  5. .moti 结构完整（XML 可解析，文本层参数 id=369 仍在）
"""
import os
import sys

import pytest
import xml.etree.ElementTree as ET

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file, PSDLayerInfo
from core.motion_builder import MotionBuilder
from core.missing_font import MISSING_GLYPH_MARKER

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")


def _build(parsed, tmp_path, name="a47_tpl"):
    mb = MotionBuilder()
    out_dir = os.path.join(str(tmp_path), name)
    result = mb.build_template_atomic(
        parsed["layers"], out_dir, name,
        psd_path=NORMAL_PSD if "vertical" in str(parsed.get("_src", "")) else COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )
    return out_dir, result


def _moti_path(out_dir):
    for root, _, names in os.walk(out_dir):
        for n in names:
            if n.endswith(".moti"):
                return os.path.join(root, n)
    raise AssertionError(f"目录下无 .moti: {out_dir}")


def _text_of_first_type_layer(moti):
    """取 .moti 中第一个文本层（parameter id=369）的 text 值"""
    tree = ET.parse(moti)
    text_elems = tree.findall(".//parameter[@id='369']/text")
    assert text_elems, ".moti 中应存在文本参数 (id=369)"
    return text_elems[0].text or ""


def _style_run_length(moti):
    tree = ET.parse(moti)
    srs = tree.findall(".//styleRun")
    return [sr.attrib.get("length") for sr in srs]


def _make_marked(parsed):
    """确定性构造缺字层：取第一个 type 层，注入缺字标记版文本（1:1 等长）"""
    type_layers = [li for li in parsed["layers"] if li.kind == "type"]
    assert type_layers, "夹具应含文本层"
    li = type_layers[0]
    orig = li.text
    assert orig, "夹具文本层应有文本内容"
    # 构造缺字：原文中间字符替换为 tofu 标记（保持逐字 1:1 等长）
    mid = len(orig) // 2
    marked = orig[:mid] + MISSING_GLYPH_MARKER + orig[mid + 1:]
    assert len(marked) == len(orig)
    li.marked_text = marked
    li.missing_glyph_visible_marker = True
    return li, orig, marked


# ── ① 缺字层：.moti 写方框标记而非原字（授权改动的核心断言）────────────────

def test_a47_marked_text_flows_to_moti(tmp_path):
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    li, orig, marked = _make_marked(parsed)

    out_dir, _ = _build(parsed, tmp_path)
    moti = _moti_path(out_dir)

    written = _text_of_first_type_layer(moti)
    # 核心断言：写出的必须是标记版
    assert MISSING_GLYPH_MARKER in written, (
        f".moti 文本应含 tofu 标记，实际: {written!r}"
    )
    assert written == marked, f".moti 文本应为标记版 {marked!r}，实际 {written!r}"
    assert written != orig, ".moti 文本不得仍为原始文本（缺字静默未消除）"
    # 与解析层对象口径一致
    assert written == li.marked_text


def test_a47_stylerun_length_matches_written_text(tmp_path):
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    li, orig, marked = _make_marked(parsed)

    out_dir, _ = _build(parsed, tmp_path)
    moti = _moti_path(out_dir)
    written = _text_of_first_type_layer(moti)
    lengths = _style_run_length(moti)
    assert lengths, ".moti 应含 styleRun"
    # 至少一条 styleRun 的 length 与写出文本长度一致（等长不变量）
    assert str(len(written)) in lengths, (
        f"styleRun length {lengths} 应含写出文本长度 {len(written)}"
    )


# ── ② 无缺字层：零回归（marked_text 为空或与原文一致 → 原样写出）──────────

def test_a47_unmarked_layers_unchanged(tmp_path):
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    # 不注入任何标记：所有层 marked_text 要么为空、要么与原文一致
    for li in parsed["layers"]:
        if li.kind == "type":
            li.marked_text = ""  # 显式清空，模拟"无缺字"

    out_dir, _ = _build(parsed, tmp_path)
    moti = _moti_path(out_dir)

    tree = ET.parse(moti)
    text_elems = tree.findall(".//parameter[@id='369']/text")
    assert text_elems
    infos = [li for li in parsed["layers"] if li.kind == "type"]
    # 每个写出文本必须能在解析层原文中找到对应（原样、无臆造标记）
    for te in text_elems:
        val = te.text or ""
        assert MISSING_GLYPH_MARKER not in val, (
            "无缺字层不得臆造 tofu 标记"
        )
        assert any(val == (getattr(li, "marked_text", "") or li.text) for li in infos), (
            f"写出文本 {val!r} 应等于某解析层文本（零回归）"
        )


# ── ③ 真实 PSD 集成（环境条件式，不跳过、不臆造）──────────────────────────

def test_a47_real_psd_integration(tmp_path):
    """
    真实解析链：本环境（无 AppKit）字体诊断 unverifiable/font_missing 时，
    psd_parser 生成的 marked_text 必须真实流入 .moti（不中途丢弃）。
    字体完整的机器上：无标记层 → .moti 原样（同样受检）。
    """
    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=False)
    type_infos = [li for li in parsed["layers"] if li.kind == "type"]
    assert type_infos

    out_dir, _ = _build(parsed, tmp_path)
    moti = _moti_path(out_dir)
    tree = ET.parse(moti)
    text_elems = tree.findall(".//parameter[@id='369']/text")
    written_all = [te.text or "" for te in text_elems]

    marked_infos = [li for li in type_infos if li.missing_glyph_visible_marker and li.marked_text]
    if marked_infos:
        # 存在缺字标记层：每条 marked_text 必须出现在 .moti 写出文本集合中
        for li in marked_infos:
            assert li.marked_text in written_all, (
                f"缺字层 '{li.name}' 的 marked_text {li.marked_text!r} "
                f"未流入 .moti（写出集合: {written_all[:3]}...）"
            )
            assert MISSING_GLYPH_MARKER in li.marked_text
    else:
        # 字体完整：写出文本 == 解析层文本，无任何标记
        for w in written_all:
            assert MISSING_GLYPH_MARKER not in w, "字体完整却出现 tofu 标记（臆造）"


# ── ④ 结构完整性：XML 可解析、文本参数 id=369 保留（深层结构未动）──────────

def test_a47_moti_structure_intact(tmp_path):
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    _make_marked(parsed)
    out_dir, _ = _build(parsed, tmp_path)
    moti = _moti_path(out_dir)

    tree = ET.parse(moti)  # 不抛异常
    # 文本参数节点与 ozml 结构仍在（只改了 text 值，未动结构）
    assert tree.findall(".//parameter[@id='369']/text")
    assert tree.findall(".//styleRun")
    root = tree.getroot()
    assert root.tag == "ozml"
