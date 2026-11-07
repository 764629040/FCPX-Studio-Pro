"""
R26 A-47②：GUI 诊断面板高亮缺字层 —— 纯判定逻辑单测
====================================================
GUI 呈现层（QTreeWidgetItem 前景色/徽标/tooltip）本环境无 PyQt6 无法 headless 验证，
按项目惯例（SA-3 D-2/D-3 同法）：判定逻辑下沉 core/missing_font.py（无 Qt 依赖），
本测试守护判定口径；GUI 呈现为纯委托 + py_compile 静态校验，交互视觉归人工真机验收。

另含：GUI 接线静态断言（inspector_panel 源码必须调用 _apply_missing_glyph_highlight，
两处调用点 = 树模式 + 扁平模式；且预览列消费 marked_text）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.missing_font import missing_glyph_layer_state, MISSING_GLYPH_MARKER
from core.psd_parser import parse_psd_file

DATA_DIR = os.path.join(TESTS_DIR, "data")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")


class _FakeInfo:
    """鸭子类型图层信息（模拟 PSDLayerInfo 的相关字段）"""

    def __init__(self, *, marker=False, has_missing=False, flagged=False,
                 marked="", missing_chars=None, kind="type"):
        self.kind = kind
        self.missing_glyph_visible_marker = marker
        self.highlight_missing_font = flagged
        self.marked_text = marked
        self.font_info = {
            "has_missing_glyphs": has_missing,
            "missing_chars": missing_chars or [],
        }


def test_highlight_on_visible_marker():
    s = missing_glyph_layer_state(_FakeInfo(marker=True, marked="A□B",
                                            missing_chars=["你"]))
    assert s["highlight"] is True
    assert s["marked_text"] == "A□B"
    assert s["missing_chars"] == ["你"]
    assert "缺字形" in s["reason"]


def test_highlight_on_font_info_has_missing():
    s = missing_glyph_layer_state(_FakeInfo(has_missing=True, missing_chars=["龘"]))
    assert s["highlight"] is True
    assert s["missing_chars"] == ["龘"]
    assert "缺字形" in s["reason"]


def test_highlight_on_flagged():
    s = missing_glyph_layer_state(_FakeInfo(flagged=True))
    assert s["highlight"] is True
    assert "字体风险" in s["reason"]


def test_no_highlight_when_clean():
    s = missing_glyph_layer_state(_FakeInfo(kind="pixel"))
    assert s["highlight"] is False
    assert s["reason"] == "缺字风险"  # 无风险时 reason 为默认串但不影响 highlight=False
    assert s["marked_text"] == ""


def test_reason_combines_both():
    s = missing_glyph_layer_state(_FakeInfo(marker=True, flagged=True))
    assert "缺字形" in s["reason"] and "字体风险" in s["reason"]


def test_real_psd_consistency_with_counter():
    """真实解析链：判定 highlight 的层数与 missing_glyph_layers 计数器口径一致。"""
    r = parse_psd_file(NORMAL_PSD)
    states = [missing_glyph_layer_state(li) for li in r["layers"] if li.kind == "type"]
    highlighted = sum(1 for s in states if s["highlight"])
    # 计数器只统计"应用了可见标记"的层（missing_glyph_visible_marker），
    # highlight 口径 ⊇ 计数器口径（highlight 还包含字体风险层），不得少报
    assert highlighted >= r["missing_glyph_layers"], (
        f"GUI 高亮层数 {highlighted} 不得少于标记计数 {r['missing_glyph_layers']}"
    )
    # 每个带标记的层，marked_text 必须含 □（GUI 预览列直接展示它）
    for li in r["layers"]:
        if li.kind == "type" and li.missing_glyph_visible_marker:
            assert MISSING_GLYPH_MARKER in li.marked_text


# ── GUI 接线静态断言（呈现层为纯委托 + 两处调用点）────────────────────────

GUI_FILE = os.path.join(PROJECT_ROOT, "gui", "inspector_panel.py")


def test_gui_wiring_static():
    src = open(GUI_FILE, encoding="utf-8").read()
    # 1. 存在高亮方法，且判定委托 core.missing_font（单一口径）
    assert "_apply_missing_glyph_highlight" in src
    assert "missing_glyph_layer_state" in src, "判定逻辑必须委托 core（口径单一）"
    # 2. 树模式 + 扁平模式两处调用（出现次数 >= 2）
    assert src.count("self._apply_missing_glyph_highlight(item, info)") >= 2, (
        "树模式与扁平后备模式都必须调用高亮"
    )
    # 3. 预览列消费 marked_text（□ 直接可见，非仅 tooltip）
    assert 'state["marked_text"]' in src
    # 4. 缺字层不臆造：无标记层不触发（判定在 core 测试守护）
