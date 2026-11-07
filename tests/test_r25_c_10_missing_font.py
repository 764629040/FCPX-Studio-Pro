"""
R25 C-10 缺字可见 + 不可降级告警
===============================
- 缺字用可见标记（tofu □）替代，不得留下空白/乱码；
- 诊断面板必须高亮缺字/缺字体风险（highlight_missing_font）；
- 绝不静默用默认字体顶替原始字体：输出 font_name 保持原始字体，
  fallback_font 仅作为"推荐回退"留痕（font_substituted 显式标记）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from core.missing_font import apply_missing_glyph_markers, should_highlight_missing_font, MISSING_GLYPH_MARKER
import r25_fixtures as FX
from core.psd_parser import parse_psd_file

DATA_DIR = os.path.join(TESTS_DIR, "data")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")


def test_missing_glyph_marker_replaces_with_visible_box():
    """单元：缺字字符被替换为可见 tofu 标记；无缺字时原样返回。"""
    assert MISSING_GLYPH_MARKER == "□"
    out = apply_missing_glyph_markers("A你B他C", ["你", "他"])
    assert out == f"A{MISSING_GLYPH_MARKER}B{MISSING_GLYPH_MARKER}C"
    # 不变量：缺字标记必须逐字 1:1 替换（每个缺失字形恰好换成 1 个 tofu 标记），
    # 因此输出长度 == 源文本长度（"A你B他C" 5 字符 → "A□B□C" 5 字符），
    # 便于下游按偏移定位缺失位置。
    assert len(out) == len("A你B他C") == 5
    # 空缺字清单不臆造
    assert apply_missing_glyph_markers("ABC", []) == "ABC"


def test_highlight_decision_logic():
    assert should_highlight_missing_font("partial_missing", True) is True
    assert should_highlight_missing_font("font_missing", True) is True
    assert should_highlight_missing_font("unverifiable", True) is True
    # 完整 / 无风险不触发高亮
    assert should_highlight_missing_font("complete", False) is False
    assert should_highlight_missing_font("complete", True) is False


def test_diagnosis_highlights_missing_font_and_no_silent_substitution():
    """
    集成：解析真实文本 PSD，断言
    1) 存在缺字/缺字体风险的图层被诊断高亮（highlight_missing_font=True）；
    2) 输出字体保持原始字体，绝不静默替换默认字体；
    3) fallback_font 仅作推荐留痕，font_substituted 显式标记。
    """
    r = parse_psd_file(NORMAL_PSD)
    type_layers = [d for d in r["diagnosis_report"]["layers"] if d["layer_type"] == "type"]
    assert type_layers, "应包含文本图层"

    highlighted = [d for d in type_layers if d.get("highlight_missing_font")]
    # 本环境（无 AppKit 或字体未安装）下字体状态为 unverifiable / font_missing，
    # 必然存在高亮项；即便在字体完整环境，也应至少不出现"有风险却未高亮"。
    if any(d.get("font_status") in ("unverifiable", "font_missing", "partial_missing") for d in type_layers):
        assert highlighted, "存在缺字/缺字体风险的文本层必须被诊断高亮"

    for d in type_layers:
        # 取对应 PSDLayerInfo
        li = next(l for l in r["layers"] if l.name == d["layer_name"] and l.kind == "type")
        original = li.font_info.get("original_font")
        # 输出字体必须等于原始字体：绝不静默替换默认字体
        assert li.font_name == original, (
            f"图层 '{li.name}' 输出字体被静默替换: {li.font_name} != {original}"
        )
        # 若发生了默认字体替换，必须显式标记（不得静默）
        if li.font_info.get("font_substituted"):
            assert li.font_info.get("fallback_font") not in (None, ""), "替换必须同时记录推荐回退字体"
            # 高亮或告警应存在，证明不是静默发生
            assert d.get("highlight_missing_font") or d.get("warp_detected") or li.font_info.get("has_missing_glyphs")


def test_marked_text_present_and_not_blank():
    """缺字层必须给出 marked_text（可见标记版），不得为空或静默丢弃。"""
    r = parse_psd_file(NORMAL_PSD)
    for li in r["layers"]:
        if li.kind != "type":
            continue
        if li.font_info.get("has_missing_glyphs") or li.font_info.get("font_substituted"):
            assert li.marked_text, "存在缺字/替换时 marked_text 不得为空"


def test_missing_glyph_counter_and_first_class_marked_text():
    """
    R25 SA-2b（SA-4 问题 3 修复）：缺字标记下沉为图层信息一等字段 + 机器可核查计数器。

    - 每个文本层信息对象必须携带 marked_text 一等属性（str），
      缺字形时与原文 1:1 等长且含 □ 标记；
    - 诊断 summary 与解析结果顶层必须携带 missing_glyph_layers 计数器，
      且与"应用了可见缺字标记的文本层数"严格相等；
    - GUI 侧徽章/悬浮提示的接线归 SA-3 的 gui/ 域（本轮只闭合数据层，见
      docs/psd_support_matrix_R25.md 的披露）。
    """
    r = parse_psd_file(NORMAL_PSD)
    summary = r["diagnosis_report"]["summary"]
    diag = r["diagnosis_report"]["layers"]

    # 计数器存在且为 int，顶层与 summary 同源
    assert "missing_glyph_layers" in summary, "summary 必须携带 missing_glyph_layers 计数器"
    assert isinstance(summary["missing_glyph_layers"], int)
    assert r["missing_glyph_layers"] == summary["missing_glyph_layers"]
    # 计数器与逐层标记严格一致（机器可核查）
    expected = sum(1 for d in diag if d.get("missing_glyph_visible_marker"))
    assert summary["missing_glyph_layers"] == expected

    # 一等字段：每个文本层信息对象都有 marked_text 属性
    type_infos = [li for li in r["layers"] if li.kind == "type"]
    assert type_infos, "应包含文本图层"
    for li in type_infos:
        assert hasattr(li, "marked_text"), "文本层信息必须携带 marked_text 一等字段"
        assert isinstance(li.marked_text, str)
        if li.missing_glyph_visible_marker:
            # 缺字形：marked_text 含 □、与原文逐字 1:1（等长）、确有差异
            assert MISSING_GLYPH_MARKER in li.marked_text
            assert li.marked_text != li.text
            assert len(li.marked_text) == len(li.text), "缺字标记必须逐字 1:1 替换"
        else:
            # 无缺字形：marked_text 与原文一致（不臆造标记）
            assert li.marked_text == li.text
    # 一致性：有标记的层数 > 0 时计数器必须 > 0
    if any(li.missing_glyph_visible_marker for li in type_infos):
        assert summary["missing_glyph_layers"] > 0
