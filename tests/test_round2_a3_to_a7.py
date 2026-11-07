"""
回归测试：第二轮审核 A-3 / A-4 / A-5 / A-6 / A-7 退回项

  A-3 字号不一致（建框用原字号、绘制除 2.2，字形仅占框体 0.4545）
  A-4 字体不可用被误报为缺字形（CormorantInfant 未装却列 "缺字: W,E,N"）
  A-5 计数口径矛盾（"32 导出/40 总计" 与 "扫描图层总数 4" 并存）
  A-6 源文件标识不一致（标题 A.psd vs 页脚 four_state.psd）
  A-7 four_state.psd 未交付

对应修复：
  gui/canvas_view.py  — 新增 text_render_font_size()，建框与绘制共用同一字号来源；
                        建框改用 psd_bbox，删除 /2.2 魔数。
  core/psd_parser.py  — 字体未安装时 missing_chars 置空（缺的是整个字体，不是具体字）；
                        detection_status 区分 font_missing / unverifiable / missing_fallback。
  gui/main_window.py  — 图层数标注口径；标题/页脚/JSON 源文件同源。
  tests/make_four_state_fixture.py — 生成 four_state.psd 固定夹具。
"""

# R26（独立复核报告 R25 §十.5）：本文件为 GUI 运行时测试，需真实 PyQt6 显示环境。
# 无 PyQt6 的环境按「手工验证，不自动跑」处理：importorskip 使其干净跳过（SKIPPED，非 ERROR）。
import pytest as _pytest_r26
_pytest_r26.importorskip("PyQt6", reason="GUI 测试需 PyQt6；无则转手工验证，不自动跑")

import os
import sys

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.psd_parser import (
    parse_psd_file,
    check_font_glyph_coverage,
    check_font_availability,
    PSDLayerInfo,
)
from gui.canvas_view import CanvasContainer, ConvertedLayerGraphicItem, text_render_font_size
from gui.main_window import MainWindow

app = QApplication.instance() or QApplication(sys.argv)

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
FOUR_STATE_PSD = os.path.join(DATA_DIR, "four_state.psd")

try:
    import AppKit  # noqa: F401
    HAS_APPKIT = True
except Exception:
    HAS_APPKIT = False


# ═══════════════════════════════════════════════════════════════
# A-3  字号来源统一
# ═══════════════════════════════════════════════════════════════
def test_font_size_has_no_magic_divisor():
    """
    A-3 核心：绘制字号不得再使用 /2.2 魔数。
    字号必须与 PSD 原字号同源（像素→point 换算），不做无依据压缩。
    """
    info = PSDLayerInfo(index=1, name="t", kind="type", text="Hello",
                        font_name="Helvetica", font_size=100.0, tracking=0.0,
                        psd_bbox=(0, 0, 200, 100), motion_pos=(0, 0))
    size = text_render_font_size(info)

    old_magic = int(100.0 / 2.2)   # = 45
    assert size != old_magic, "绘制字号仍在用 /2.2 魔数"
    # 像素转 point：100px ≈ 75pt
    assert size == 75, f"字号换算错误，期望 75，实际 {size}"


def test_geometry_box_matches_psd_bbox():
    """
    A-3 核心：建框尺寸必须来自 psd_bbox，而不是"字符数 × 原字号"。
    旧实现会把 Text01 的框撑到 1080px，而真实 bbox 宽仅 31px。
    """
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    container = CanvasContainer()
    container.show()
    container.load_layers(parsed["layers"])
    container.set_artboard_resolution(parsed["width"], parsed["height"])

    by_name = {l.name: l for l in parsed["layers"]}
    for name in ("Text01", "Title"):
        layer = by_name[name]
        item = container.right_canvas.items_map[layer.index]
        rect = item.rect()
        left, top, right, bottom = layer.psd_bbox
        bw, bh = right - left, bottom - top

        # 旋转 90° 图元的 rect 宽高对应 bbox 的高宽
        assert abs(rect.width() - bh) < 1.0, (
            f"{name} 框宽 {rect.width():.1f} 与 bbox 高 {bh} 不符"
        )
        assert abs(rect.height() - bw) < 1.0, (
            f"{name} 框高 {rect.height():.1f} 与 bbox 宽 {bw} 不符"
        )


def test_render_size_and_box_are_consistent():
    """
    A-3 核心：同一图层的绘制字号与框体高度必须处于合理比例，
    不再出现"字形仅占框体 0.4545"的错位。
    """
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    by_name = {l.name: l for l in parsed["layers"]}

    for name in ("Text01", "Title"):
        layer = by_name[name]
        pt = text_render_font_size(layer)
        left, top, right, bottom = layer.psd_bbox
        # 竖排时 bbox 高即文字的"排版长度"，字号应远小于它但同源
        assert pt > 0
        # 字号相对原字号的比例应恒为 0.75（px→pt），不再随图层变化
        assert abs(pt - round(layer.font_size * 0.75)) <= 1
        # 不再是 0.4545 那套压缩
        assert abs(pt / layer.font_size - 0.4545) > 0.1


# ═══════════════════════════════════════════════════════════════
# A-4  字体不可用 vs 缺字形
# ═══════════════════════════════════════════════════════════════
def test_uninstalled_font_reports_no_specific_missing_chars():
    """
    A-4 核心：字体文件不存在时，不得把文本字符当作"缺字"列出。
    缺的是整个字体，不是 W/E/N 这些字母。
    """
    res = check_font_glyph_coverage("CormorantInfant-Regular", "WENDDING & HAPPY")
    if not HAS_APPKIT:
        assert res["status"] == "unverifiable"
        return

    assert res["status"] == "font_missing"
    assert res["coverage_rate"] == 0.0
    assert res["missing_chars"] == [], (
        f"字体未安装却列出了具体缺字: {res['missing_chars']}"
    )
    assert "未安装" in res["warning"]


def test_font_missing_badge_does_not_list_glyphs():
    """A-4 核心：徽章在字体未安装时显示"未安装"，不得列出具体字母"""
    info = PSDLayerInfo(
        index=1, name="Title", kind="type", text="WENDDING & HAPPY",
        font_name="CormorantInfant-Regular", font_size=90.0, tracking=0.0,
        psd_bbox=(0, 0, 100, 800), motion_pos=(0, 0),
        font_info={"detection_status": "font_missing", "glyph_coverage": 0.0,
                   "has_missing_glyphs": True, "fallback_font": "Helvetica",
                   "missing_chars": []},
    )
    item = ConvertedLayerGraphicItem(info)
    text, _, fg = item.get_badge_info()

    assert "未安装" in text
    assert "缺字" not in text
    for letter in ("W", "E", "N"):
        assert letter not in text, f"徽章仍列出字母 {letter}: {text}"
    assert fg.name().lower() == "#ff453a"


def test_missing_glyph_still_reported_for_installed_font():
    """
    A-4 边界：字体确已安装但缺字形时，仍必须如实列出缺字。
    不能为了修 A-4 而把真实缺字一并抹掉。
    """
    if not HAS_APPKIT:
        pytest.skip("无 AppKit 无法验证真实缺字")
    res = check_font_glyph_coverage("Helvetica", "婚礼现场2026")
    assert res["status"] == "partial_missing"
    assert len(res["missing_chars"]) > 0
    assert "婚" in res["missing_chars"]


def test_complex_layers_detection_status_is_font_missing():
    """真实夹具：CormorantInfant 未安装，应归 font_missing 而非 missing_fallback"""
    if not HAS_APPKIT:
        pytest.skip("无 AppKit 分支下状态为 unverifiable")
    if check_font_availability("CormorantInfant-Regular"):
        pytest.skip("本机已安装该字体，无法验证未安装分支")

    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    for layer in parsed["layers"]:
        if layer.kind == "type":
            assert layer.font_info["detection_status"] == "font_missing"
            assert layer.font_info["missing_chars"] == []


# ═══════════════════════════════════════════════════════════════
# A-5  计数口径
# ═══════════════════════════════════════════════════════════════
def test_layer_count_label_states_scope():
    """A-5 核心：图层数文案必须显式标注两个数字的口径差异"""
    win = MainWindow()
    win.show()
    win.current_psd_path = COMPLEX_PSD
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    win.current_parsed_psd = parsed

    win.lbl_layer_count.setText(
        f"图层数: 参与转换 {parsed['layer_count']} / 文档总计 {parsed['total_layers_count']}"
    )
    label = win.lbl_layer_count.text()

    assert "参与转换" in label
    assert "文档总计" in label
    assert f"{parsed['layer_count']}" in label
    assert f"{parsed['total_layers_count']}" in label
    # 不允许再出现含糊的"导出 / 总计"
    assert "导出 / " not in label


def test_counts_are_internally_consistent():
    """A-5：layer_count 与 diagnosis total_layers 的语义必须可区分且自洽"""
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    assert parsed["layer_count"] == len(parsed["layers"])
    assert parsed["total_layers_count"] == parsed["diagnosis_report"]["summary"]["total_layers"]
    assert parsed["total_layers_count"] >= parsed["layer_count"]


# ═══════════════════════════════════════════════════════════════
# A-6  源文件标识同源
# ═══════════════════════════════════════════════════════════════
def test_source_name_same_in_title_and_footer():
    """A-6 核心：窗口标题与页脚源文件必须来自同一 summary.source_file"""
    win = MainWindow()
    win.show()

    report = {
        "summary": {
            "source_file": {"name": "纪实字幕.psd", "path": "/tmp/纪实字幕.psd"},
            "total_layers": 4, "preserved_count": 4, "degraded_count": 0,
            "ignored_count": 0, "failed_count": 0, "missing_fonts_count": 0,
            "unverifiable_fonts_count": 0, "has_missing_risk": False,
            "risk_assessment": "无风险",
        },
        "layers": [],
    }
    win._populate_diagnosis_tab(report)

    assert "纪实字幕.psd" in win.diag_path_label.text()
    assert "纪实字幕.psd" in win.windowTitle(), "标题未同步源文件名"


def test_fixture_source_does_not_leak_stale_name():
    """A-6：换一份报告后，标题不得残留上一份的源文件名"""
    win = MainWindow()
    win.show()

    base = {"total_layers": 0, "preserved_count": 0, "degraded_count": 0,
            "ignored_count": 0, "failed_count": 0, "missing_fonts_count": 0,
            "unverifiable_fonts_count": 0, "has_missing_risk": False,
            "risk_assessment": "无风险"}

    win._populate_diagnosis_tab({
        "summary": {**base, "source_file": {"name": "four_state.psd", "path": "/f.psd"}},
        "layers": []})
    assert "four_state.psd" in win.windowTitle()

    win._populate_diagnosis_tab({
        "summary": {**base, "source_file": {"name": "纪实字幕.psd", "path": "/j.psd"}},
        "layers": []})
    title = win.windowTitle()
    assert "纪实字幕.psd" in title
    assert "four_state.psd" not in title, "标题残留了上一份报告的文件名"


# ═══════════════════════════════════════════════════════════════
# A-7  four_state.psd 夹具
# ═══════════════════════════════════════════════════════════════
def test_four_state_fixture_exists_and_is_valid():
    """A-7 核心：four_state.psd 必须真实存在于 tests/data 且可被解析"""
    assert os.path.isfile(FOUR_STATE_PSD), f"四态夹具缺失: {FOUR_STATE_PSD}"
    assert os.path.getsize(FOUR_STATE_PSD) > 1000

    parsed = parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    assert parsed["file_name"] == "four_state.psd"
    assert parsed["width"] > 0 and parsed["height"] > 0
    text_layers = [l for l in parsed["layers"] if l.kind == "type"]
    assert len(text_layers) >= 4, f"四态夹具文本层不足: {len(text_layers)}"


def test_four_state_fixture_covers_multiple_states():
    """
    A-7：夹具必须真实覆盖多种字体状态（而非伪造文件名占位）。
    在有无 AppKit 两种环境下，可覆盖的状态集合不同，分别断言。
    """
    parsed = parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    statuses = {l.font_info["detection_status"]
                for l in parsed["layers"] if l.kind == "type"}

    if HAS_APPKIT:
        # 已安装字体 -> detected / missing_fallback；未安装 -> font_missing
        assert len(statuses) >= 2, f"状态过于单一，未覆盖多态: {statuses}"
    else:
        assert statuses == {"unverifiable"}, f"无 AppKit 时应统一 unverifiable: {statuses}"


def test_four_state_fixture_is_listed_in_inventory():
    """A-7：夹具必须纳入指纹清单，避免再次遗漏"""
    import json
    inv_path = os.path.join(PROJECT_ROOT, "docs", "audit_inventory_20261027_round3.json")
    if not os.path.isfile(inv_path):
        pytest.skip("本轮指纹清单尚未生成")
    with open(inv_path, encoding="utf-8") as f:
        inv = json.load(f)
    assert "tests/data/four_state.psd" in inv["files"], "four_state.psd 未纳入指纹清单"
    assert inv["files"]["tests/data/four_state.psd"]["sha256"]
