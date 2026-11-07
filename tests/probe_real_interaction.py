"""
真实交互探针 (独立于既有测试，不修改任何断言)
目的：用真实 Qt 事件 (QWheelEvent / QMouseEvent) 与新建实例，验证
  1. 左右画布滚轮缩放是否真实同步
  2. 左右画布 Shift+左键拖拽平移是否真实同步
  3. 新建 CanvasContainer 实例后棋盘格开关能否恢复
  4. 同名图层诊断跳转是否精准 (layer_index 优先 / 全路径全等回退)、是否存在名称包含误匹配
输出 JSON 证据到 tests/reports/probe_real_interaction.json
"""
import os
import sys
import json

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

os.environ["QT_QPA_PLATFORM"] = "offscreen"

from PyQt6.QtCore import Qt, QPoint, QPointF, QSettings
from PyQt6.QtGui import QWheelEvent, QMouseEvent
from PyQt6.QtWidgets import QApplication

from core.psd_parser import parse_psd_file, PSDLayerInfo
from gui.canvas_view import CanvasContainer
from gui.main_window import MainWindow

app = QApplication.instance() or QApplication(sys.argv)

REPORTS_DIR = os.path.join(TESTS_DIR, "reports")
os.makedirs(REPORTS_DIR, exist_ok=True)
DATA_DIR = os.path.join(TESTS_DIR, "data")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")

evidence = {}


def _wheel(view, delta_y, pos=None):
    """构造并投递真实滚轮事件"""
    pos = pos or QPointF(view.viewport().rect().center())
    ev = QWheelEvent(
        pos,
        QPointF(view.viewport().mapToGlobal(pos.toPoint())),
        QPoint(0, 0),
        QPoint(0, delta_y),
        Qt.MouseButton.NoButton,
        Qt.KeyboardModifier.NoModifier,
        Qt.ScrollPhase.NoScrollPhase,
        False,
    )
    QApplication.sendEvent(view.viewport(), ev)


def probe_zoom_sync():
    container = CanvasContainer()
    container.resize(1200, 800)
    container.show()
    container.load_layers(parse_psd_file(NORMAL_PSD, extract_thumbnails=False)["layers"])

    left, right = container.left_canvas, container.right_canvas
    before = (left.transform().m11(), right.transform().m11())

    _wheel(left, 120)  # 左画布滚轮放大
    after_left_drive = (left.transform().m11(), right.transform().m11())

    _wheel(right, -120)  # 右画布滚轮缩小
    after_right_drive = (left.transform().m11(), right.transform().m11())

    return {
        "before": before,
        "after_left_wheel": after_left_drive,
        "after_right_wheel": after_right_drive,
        "zoom_changed_by_left_wheel": after_left_drive[0] != before[0],
        "zoom_synced_left_to_right": abs(after_left_drive[0] - after_left_drive[1]) < 1e-9,
        "zoom_synced_right_to_left": abs(after_right_drive[0] - after_right_drive[1]) < 1e-9,
    }


def probe_pan_drag_sync():
    container = CanvasContainer()
    container.resize(1200, 800)
    container.show()
    container.load_layers(parse_psd_file(NORMAL_PSD, extract_thumbnails=False)["layers"])

    left, right = container.left_canvas, container.right_canvas
    # 先放大，确保存在可滚动范围
    for _ in range(4):
        _wheel(left, 120)

    h_before = (left.horizontalScrollBar().value(), right.horizontalScrollBar().value())

    start = left.viewport().rect().center()
    press = QMouseEvent(
        QMouseEvent.Type.MouseButtonPress, QPointF(start), QPointF(left.viewport().mapToGlobal(start)),
        Qt.MouseButton.LeftButton, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.ShiftModifier,
    )
    QApplication.sendEvent(left.viewport(), press)

    moved = start - QPoint(90, 60)
    move = QMouseEvent(
        QMouseEvent.Type.MouseMove, QPointF(moved), QPointF(left.viewport().mapToGlobal(moved)),
        Qt.MouseButton.NoButton, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.ShiftModifier,
    )
    QApplication.sendEvent(left.viewport(), move)

    release = QMouseEvent(
        QMouseEvent.Type.MouseButtonRelease, QPointF(moved), QPointF(left.viewport().mapToGlobal(moved)),
        Qt.MouseButton.LeftButton, Qt.MouseButton.NoButton, Qt.KeyboardModifier.ShiftModifier,
    )
    QApplication.sendEvent(left.viewport(), release)

    h_after = (left.horizontalScrollBar().value(), right.horizontalScrollBar().value())
    v_after = (left.verticalScrollBar().value(), right.verticalScrollBar().value())

    return {
        "scroll_before": h_before,
        "h_scroll_after_drag": h_after,
        "v_scroll_after_drag": v_after,
        "drag_moved_left_canvas": h_after[0] != h_before[0],
        "pan_synced_to_right": h_after[0] == h_after[1] and v_after[0] == v_after[1],
        "is_panning_reset": left._is_panning is False,
    }


def probe_checkerboard_restore():
    """真实持久化恢复：写入 QSettings -> 新建实例 -> 读取"""
    settings = QSettings("FCPXStudioPro", "FCPXStudioPro")
    original = settings.value("checkerboard_enabled", None, type=bool)

    settings.setValue("checkerboard_enabled", False)
    settings.sync()
    c_off = CanvasContainer()
    c_off.show()
    off_state = (c_off.left_canvas.checkerboard_enabled, c_off.right_canvas.checkerboard_enabled)

    settings.setValue("checkerboard_enabled", True)
    settings.sync()
    c_on = CanvasContainer()
    c_on.show()
    on_state = (c_on.left_canvas.checkerboard_enabled, c_on.right_canvas.checkerboard_enabled)

    # 还原现场
    if original is None:
        settings.remove("checkerboard_enabled")
    else:
        settings.setValue("checkerboard_enabled", original)
    settings.sync()

    return {
        "new_instance_reads_false": off_state,
        "new_instance_reads_true": on_state,
        "restore_off_ok": off_state == (False, False),
        "restore_on_ok": on_state == (True, True),
        "settings_key_written": True,
    }


def probe_duplicate_layer_nav():
    win = MainWindow()
    win.show()

    layer1 = PSDLayerInfo(index=10, name="副标题", kind="type", text="A", font_name="PingFangSC-Regular",
                          font_size=24.0, tracking=0.0, psd_bbox=(0, 0, 100, 40), motion_pos=(0, 200),
                          layer_path="页眉组/副标题")
    layer2 = PSDLayerInfo(index=20, name="副标题", kind="type", text="B", font_name="PingFangSC-Regular",
                          font_size=24.0, tracking=0.0, psd_bbox=(0, 700, 100, 740), motion_pos=(0, -200),
                          layer_path="页脚组/副标题")

    report = {
        "summary": {"source_file": {"name": "d.psd", "path": "/d.psd"}, "total_layers": 2,
                    "preserved_count": 2, "degraded_count": 0, "ignored_count": 0,
                    "failed_count": 0, "missing_fonts_count": 0,
                    "has_missing_risk": False, "risk_assessment": "无风险"},
        "layers": [
            {"layer_index": 10, "layer_path": "页眉组/副标题", "layer_name": "副标题", "layer_type": "type",
             "disposition": "preserved", "reason": "纯矢量文本，字体元数据完整，保留为可发布标题",
             "font_status": "complete", "missing_glyphs": []},
            {"layer_index": 20, "layer_path": "页脚组/副标题", "layer_name": "副标题", "layer_type": "type",
             "disposition": "preserved", "reason": "纯矢量文本，字体元数据完整，保留为可发布标题",
             "font_status": "complete", "missing_glyphs": []},
        ],
    }
    win._populate_diagnosis_tab(report)

    win._on_jump_to_diagnosis(layer1)
    row1 = win.diag_table.currentRow()
    win._on_jump_to_diagnosis(layer2)
    row2 = win.diag_table.currentRow()

    # 回退路径：index 置空，仅靠 layer_path 全等
    l1_no_idx = PSDLayerInfo(index=None, name="副标题", kind="type", text="A", font_name="PingFangSC-Regular",
                             font_size=24.0, tracking=0.0, psd_bbox=(0, 0, 100, 40), motion_pos=(0, 200),
                             layer_path="页脚组/副标题")
    win._on_jump_to_diagnosis(l1_no_idx)
    row_fallback = win.diag_table.currentRow()

    # 子串陷阱：路径是 "页" 或 "页脚组" 时不得命中任何行
    trap = PSDLayerInfo(index=None, name="页", kind="type", text="C", font_name="PingFangSC-Regular",
                        font_size=24.0, tracking=0.0, psd_bbox=(0, 0, 10, 10), motion_pos=(0, 0),
                        layer_path="页脚组")
    # 代码在无命中时不改变既有选择，因此必须用"跳转前/后"对比判定是否误命中
    win.diag_table.selectRow(-1)
    row_before_trap = win.diag_table.currentRow()
    win._on_jump_to_diagnosis(trap)
    row_substring_trap = win.diag_table.currentRow()
    row_trap_changed = row_substring_trap != row_before_trap

    return {
        "idx10_row": row1,
        "idx20_row": row2,
        "fallback_path_row": row_fallback,
        "substring_trap_row": row_substring_trap,
        "duplicate_names_distinct": row1 == 0 and row2 == 1,
        "fallback_exact_path_ok": row_fallback == 1,
        "row_before_trap": row_before_trap,
        "no_substring_match": row_trap_changed is False,
    }


def probe_four_state_badges():
    win = MainWindow()
    win.show()
    win.awin = None
    cases = [
        ("complete", {"detection_status": "detected", "glyph_coverage": 1.0,
                      "has_missing_glyphs": False, "missing_chars": []}),
        ("partial_missing", {"detection_status": "missing_fallback", "glyph_coverage": 0.25,
                             "has_missing_glyphs": True, "missing_chars": ["领", "衔"]}),
        ("font_missing", {"detection_status": "font_missing", "glyph_coverage": 0.0,
                          "has_missing_glyphs": True, "fallback_font": "PingFangSC-Regular",
                          "missing_chars": ["E"]}),
        ("unverifiable", {"detection_status": "unverifiable", "glyph_coverage": None,
                          "has_missing_glyphs": True, "missing_chars": []}),
    ]
    layers = []
    for i, (_, fi) in enumerate(cases, start=1):
        layers.append(PSDLayerInfo(index=i, name=f"L{i}", kind="type", text="测试", font_name="PingFangSC-Regular",
                                   font_size=36.0, tracking=0.0, psd_bbox=(0, i * 100, 100, i * 100 + 90),
                                   motion_pos=(0, 0), font_info=fi))
    win.canvas_view.load_layers(layers)

    out = {}
    for i, (state, _) in enumerate(cases, start=1):
        text, bg, fg = win.canvas_view.right_canvas.items_map[i].get_badge_info()
        out[state] = {"text": text, "bg": bg.name(), "fg": fg.name()}

    # 点击徽章后是否精确跳转
    win._populate_diagnosis_tab({
        "summary": {"source_file": {"name": "x.psd", "path": "/x.psd"}, "total_layers": 4,
                    "preserved_count": 4, "degraded_count": 0, "ignored_count": 0,
                    "failed_count": 0, "missing_fonts_count": 2,
                    "has_missing_risk": True, "risk_assessment": "中风险"},
        "layers": [
            {"layer_index": i, "layer_path": f"L{i}", "layer_name": f"L{i}", "layer_type": "type",
             "disposition": "preserved", "reason": "纯矢量文本，字体元数据完整，保留为可发布标题",
             "font_status": cases[i - 1][0], "missing_glyphs": cases[i - 1][1].get("missing_chars", [])}
            for i in range(1, 5)
        ],
    })
    nav = {}
    for i in range(1, 5):
        win._on_jump_to_diagnosis(layers[i - 1])
        nav[f"L{i}"] = win.diag_table.currentRow()
    return {"badges": out, "click_nav_rows": nav}


if __name__ == "__main__":
    evidence["zoom"] = probe_zoom_sync()
    evidence["pan"] = probe_pan_drag_sync()
    evidence["checkerboard"] = probe_checkerboard_restore()
    evidence["duplicate_layer_nav"] = probe_duplicate_layer_nav()
    evidence["four_state_badges"] = probe_four_state_badges()

    out_path = os.path.join(REPORTS_DIR, "probe_real_interaction.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=2)
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
    print("\nSAVED:", out_path)
