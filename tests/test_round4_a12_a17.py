"""
回归测试：第四轮审核退回项 A-12 / A-17

  A-12  预设下拉标签与真实画板矛盾（选竖版预设后点方向切换，
        下拉仍显示"竖版 1080×1920"，而画板已是 1920×1080）
  A-17  方向切换路径按钮丢失 (16:9)/(9:16) 后缀，与预设路径文案不一致

对应修复（gui/canvas_view.py）：
  - 新增 _apply_resolution()          唯一尺寸入口
  - 新增 _sync_preset_combo()         下拉框按真实宽高反向同步
  - 新增 _orientation_button_text()   方向按钮统一带画幅后缀
  - 新增 _aspect_suffix()             由真实宽高推导比例（约分）
  - 三条入口（预设 / 手输 / 方向切换）与外部 set_artboard_resolution 全部收口

根因：过去三条路径各自更新"自己那一部分控件"，从没有任何路径
反向同步预设下拉框，导致标签与画板脱节。
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

from gui.canvas_view import CanvasContainer, PRESET_RESOLUTIONS

app = QApplication.instance() or QApplication(sys.argv)


@pytest.fixture()
def container():
    c = CanvasContainer()
    c.resize(1400, 900)
    c.show()
    yield c
    c.close()


def _select_preset(c, keyword):
    for i in range(c.preset_combo.count()):
        if keyword in c.preset_combo.itemText(i):
            c.preset_combo.setCurrentIndex(i)
            return c.preset_combo.itemText(i)
    raise AssertionError(f"未找到预设: {keyword}")


def _current_size(c):
    return c.spin_w.value(), c.spin_h.value()


def _artboard(c):
    return c.left_canvas.artboard_w, c.left_canvas.artboard_h


# ═══════════════════════════════════════════════════════════════
# A-12  下拉标签必须与真实画板一致
# ═══════════════════════════════════════════════════════════════
def test_preset_combo_follows_orientation_toggle_vertical_to_horizontal(container):
    """
    A-12 核心（审核原复现路径）：
    选竖版预设 -> 点方向切换 -> 下拉框必须变为横版预设，而不是停留在竖版标签。
    """
    _select_preset(container, "竖版 1080P")
    assert _current_size(container) == (1080, 1920)
    assert _artboard(container) == (1080, 1920)

    container.orient_btn.click()

    assert _current_size(container) == (1920, 1080)
    assert _artboard(container) == (1920, 1080), "画板未交换"
    label = container.preset_combo.currentText()
    assert "竖版" not in label, f"下拉仍显示竖版标签: {label}"
    preset = PRESET_RESOLUTIONS.get(label)
    assert preset == (1920, 1080), f"下拉标签与画板不符: {label} -> {preset}"


def test_preset_combo_follows_orientation_toggle_horizontal_to_vertical(container):
    """反向：横版 -> 点切换 -> 下拉应为竖版预设"""
    _select_preset(container, "1080P 全高清")
    assert _current_size(container) == (1920, 1080)

    container.orient_btn.click()

    assert _current_size(container) == (1080, 1920)
    label = container.preset_combo.currentText()
    assert "竖版" in label
    assert PRESET_RESOLUTIONS.get(label) == (1080, 1920)


def test_toggle_is_reversible_keeping_label_in_sync(container):
    """连续切换两次应回到原状态，且标签始终跟随"""
    _select_preset(container, "竖版 1080P")
    container.orient_btn.click()
    container.orient_btn.click()

    assert _current_size(container) == (1080, 1920)
    assert PRESET_RESOLUTIONS.get(container.preset_combo.currentText()) == (1080, 1920)


def test_custom_size_falls_back_to_custom_option(container):
    """手输非预设尺寸时，下拉必须落到"自定义分辨率..."而非残留旧预设"""
    _select_preset(container, "1080P 全高清")
    container.spin_w.setValue(1234)
    container.spin_h.setValue(890)

    label = container.preset_combo.currentText()
    assert "自定义" in label, f"非预设尺寸应落到自定义项，实际: {label}"
    assert _artboard(container) == (1234, 890)


def test_external_set_resolution_syncs_all_controls(container):
    """外部调用 set_artboard_resolution 也必须同步下拉与按钮"""
    container.set_artboard_resolution(1080, 1920)

    assert _artboard(container) == (1080, 1920)
    assert PRESET_RESOLUTIONS.get(container.preset_combo.currentText()) == (1080, 1920)
    assert "竖版" in container.orient_btn.text()


def test_label_and_artboard_never_diverge_across_sequence(container):
    """
    A-12 不变量：任意操作序列后，"下拉标签所声明的尺寸"
    必须与"真实画板尺寸"一致。
    """
    _select_preset(container, "竖版 1080P")
    sequence = [
        ("toggle", None),
        ("toggle", None),
        ("custom", (2560, 1440)),
        ("toggle", None),
        ("preset", "方形"),
        ("toggle", None),
    ]

    for action, arg in sequence:
        if action == "toggle":
            container.orient_btn.click()
        elif action == "custom":
            container.spin_w.setValue(arg[0])
            container.spin_h.setValue(arg[1])
        else:
            _select_preset(container, arg)

        w, h = _current_size(container)
        assert _artboard(container) == (w, h), "画板与输入框不一致"

        label = container.preset_combo.currentText()
        preset = PRESET_RESOLUTIONS.get(label)
        if preset is not None:
            assert preset == (w, h), (
                f"操作 {action} 后下拉标签 {label} 与真实尺寸 {(w, h)} 不符"
            )
        else:
            assert "自定义" in label


# ═══════════════════════════════════════════════════════════════
# A-17  方向按钮后缀一致性
# ═══════════════════════════════════════════════════════════════
def test_orientation_button_has_suffix_on_preset_path(container):
    """预设路径：按钮必须带画幅后缀"""
    _select_preset(container, "1080P 全高清")
    assert "(16:9)" in container.orient_btn.text()

    _select_preset(container, "竖版 1080P")
    assert "(9:16)" in container.orient_btn.text()


def test_orientation_button_has_suffix_on_toggle_path(container):
    """
    A-17 核心：方向切换路径必须同样带后缀，不得只写"🔄 横版"。
    """
    _select_preset(container, "竖版 1080P")
    container.orient_btn.click()

    text = container.orient_btn.text()
    assert ":" in text, f"方向切换路径丢后缀: {text}"
    assert "(16:9)" in text, f"应为 16:9，实际: {text}"


def test_orientation_button_has_suffix_on_custom_path(container):
    """手输路径也必须带后缀（含非标准比例，按真实宽高约分）"""
    container.spin_w.setValue(2560)
    container.spin_h.setValue(1440)
    assert "(16:9)" in container.orient_btn.text()

    container.spin_w.setValue(1600)
    container.spin_h.setValue(900)
    assert "(16:9)" in container.orient_btn.text()


def test_orientation_button_text_consistent_between_paths(container):
    """
    A-17 一致性：同一组宽高，无论通过预设路径还是方向切换路径到达，
    按钮文案必须完全相同。
    """
    _select_preset(container, "1080P 全高清")
    text_via_preset = container.orient_btn.text()

    _select_preset(container, "竖版 1080P")
    container.orient_btn.click()          # 交换回 1920×1080
    text_via_toggle = container.orient_btn.text()

    assert text_via_preset == text_via_toggle, (
        f"两条路径文案不一致: 预设={text_via_preset!r} 切换={text_via_toggle!r}"
    )


def test_square_orientation_label(container):
    """方形画板：方向标签应为"方形"，比例 1:1"""
    _select_preset(container, "方形")
    text = container.orient_btn.text()
    assert "方形" in text
    assert "(1:1)" in text


def test_aspect_suffix_reduces_fraction():
    """比例后缀必须约分，不得输出 1920:1080 这类未约分形式"""
    assert CanvasContainer._aspect_suffix(1920, 1080) == "(16:9)"
    assert CanvasContainer._aspect_suffix(1080, 1920) == "(9:16)"
    assert CanvasContainer._aspect_suffix(3840, 2160) == "(16:9)"
    assert CanvasContainer._aspect_suffix(1080, 1080) == "(1:1)"
    assert CanvasContainer._aspect_suffix(0, 100) == ""


def test_no_recursion_or_signal_loop(container):
    """
    信号阻断验证：_apply_resolution 内部 setValue 不得触发
    _on_custom_size_changed 造成递归。
    """
    _select_preset(container, "1080P 全高清")
    depth = {"n": 0}
    original = container._on_custom_size_changed

    def counting():
        depth["n"] += 1
        assert depth["n"] < 10, "检测到递归调用"
        original()

    container._on_custom_size_changed = counting
    try:
        container.orient_btn.click()
    finally:
        container._on_custom_size_changed = original

    # 交换宽高会各自 setValue 一次，但 _apply_resolution 已阻断信号，
    # 因此不应通过 valueChanged 间接触发 handler
    assert depth["n"] == 0, f"信号未阻断，handler 被间接触发 {depth['n']} 次"
