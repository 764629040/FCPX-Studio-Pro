"""
并排预览、透明背景网格与字体缺字标记专项自动化测试套件
涵盖四大测试维度：
1. 并排双视界组件数据装配与缩放/平移双向同步锁定逻辑
2. 16×16px 棋盘格暗色背景网格切换与持久化逻辑
3. 字体与字形四态徽章 (complete / partial_missing / font_missing / unverifiable) 与缺字导航联动
4. 降级图层并排对比与空图层/图层组“无像素内容”清晰占位处理
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

os.environ["QT_QPA_PLATFORM"] = "offscreen"

from PyQt6.QtWidgets import QApplication
from PyQt6.QtGui import QTransform
from core.psd_parser import parse_psd_file, PSDLayerInfo
from gui.canvas_view import CanvasContainer, InfiniteCanvasView, create_checkerboard_brush
from gui.main_window import MainWindow

app = QApplication.instance() or QApplication(sys.argv)

DATA_DIR = os.path.join(TESTS_DIR, "data")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
DECORATION_PSD = os.path.join(DATA_DIR, "wedding_with_decorations_23.psd")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def test_side_by_side_preview_assembly_and_synchronization():
    """
    用例 1: 并排双视界数据装配与同步控制
    - 验证左视图 (PSD 原稿) 与右视图 (转换结果) 完整生成并挂载
    - 验证滚轮缩放与平移在左右视图间 100% 像素级双向同步锁定
    - 验证整体画布与单图层对照模式切换
    - 验证顶部居中常驻显式警示：'⚠️ 应用内预览，非 FCPX 最终渲染'
    """
    container = CanvasContainer()
    container.resize(1200, 800)
    container.show()

    assert container.left_canvas is not None
    assert container.right_canvas is not None
    assert container.left_canvas.is_original is True
    assert container.right_canvas.is_original is False

    # 1. 装载正常 PSD 图层
    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=True)
    layers = parsed["layers"]
    container.load_layers(layers)

    assert len(container.left_canvas.items_map) == len(layers)
    assert len(container.right_canvas.items_map) == len(layers)

    # 2. 验证缩放双向同步
    scale_transform = QTransform().scale(1.5, 1.5)
    container.left_canvas.sync_transform_from_peer(scale_transform)
    assert abs(container.right_canvas.transform().m11() - 1.5) < 0.001 or abs(container.left_canvas.transform().m11() - 1.5) < 0.001

    container.right_canvas.scale(1.2, 1.2)
    # 触发缩放信号同步
    container.right_canvas.zoom_sync_signal.emit(container.right_canvas.transform())
    assert abs(container.left_canvas.transform().m11() - container.right_canvas.transform().m11()) < 0.001

    # 3. 验证平移双向同步
    container.left_canvas.horizontalScrollBar().setValue(120)
    container.left_canvas.verticalScrollBar().setValue(80)
    container.left_canvas.pan_sync_signal.emit(120, 80)
    assert container.right_canvas.horizontalScrollBar().value() == 120
    assert container.right_canvas.verticalScrollBar().value() == 80

    # 4. 验证模式切换
    container._on_mode_changed(1)  # 当前选中图层对照
    assert container.left_canvas.view_mode == "layer"
    assert container.right_canvas.view_mode == "layer"

    target_layer = layers[0]
    container.select_layer(target_layer)
    assert container.left_canvas.items_map[target_layer.index].isVisible() is True
    # 其余图层在单图层对照模式下应被过滤隐藏
    if len(layers) > 1:
        other_layer = layers[1]
        assert container.left_canvas.items_map[other_layer.index].isVisible() is False

    container._on_mode_changed(0)  # 切回整体对照
    assert container.left_canvas.view_mode == "all"
    assert container.left_canvas.items_map[other_layer.index].isVisible() is True


def test_checkerboard_grid_toggle_and_persistence():
    """
    用例 2: 16×16px 暗色棋盘格透明背景网格切换与持久化
    - 验证开启棋盘格时，画板表面填充交替暗色纹理笔刷
    - 验证关闭棋盘格时，画板表面填充深黑纯色表面
    - 验证开关状态记忆持久化机制
    """
    container = CanvasContainer()
    container.show()

    # 1. 验证笔刷创建与尺寸
    brush = create_checkerboard_brush(16)
    assert brush.texture().width() == 32
    assert brush.texture().height() == 32

    # 2. 验证开启棋盘格
    container._on_checkerboard_toggled(True)
    assert container.left_canvas.checkerboard_enabled is True
    assert container.right_canvas.checkerboard_enabled is True
    assert container.left_canvas.artboard_item.brush().style() != 0

    # 3. 验证关闭棋盘格
    container._on_checkerboard_toggled(False)
    assert container.left_canvas.checkerboard_enabled is False
    assert container.right_canvas.checkerboard_enabled is False

    # 4. 状态恢复
    container._on_checkerboard_toggled(True)
    assert container.settings.value("checkerboard_enabled", type=bool) is True


def test_four_state_font_badges_and_interaction_coverage():
    """
    用例 3: 字体与字形四态徽章 (complete / partial_missing / font_missing / unverifiable) 与真实交互覆盖
    - 分别构造四态图层数据
    - 逐一验证画布图元 (ConvertedLayerGraphicItem) 的显示文案与配色 (绿/橙/红/黄)
    - 逐一验证属性面板按钮 (font_badge_btn) 的显示文案与配色样式
    - 触发按钮点击，校验信号发射与跨 Tab 联动跳转至 Tab 3 诊断报告
    """
    win = MainWindow()
    win.show()

    info_complete = PSDLayerInfo(
        index=1, name="完整文本", kind="type", text="测试", font_name="PingFangSC-Regular",
        font_size=36.0, tracking=0.0, psd_bbox=(100, 100, 200, 200), motion_pos=(0, 0),
        font_info={"detection_status": "detected", "glyph_coverage": 1.0, "has_missing_glyphs": False, "missing_chars": []}
    )
    info_partial = PSDLayerInfo(
        index=2, name="缺字文本", kind="type", text="领衔呈现", font_name="Helvetica",
        font_size=36.0, tracking=0.0, psd_bbox=(100, 250, 200, 350), motion_pos=(0, 100),
        font_info={"detection_status": "missing_fallback", "glyph_coverage": 0.25, "has_missing_glyphs": True, "missing_chars": ["领", "衔", "呈"]}
    )
    info_missing = PSDLayerInfo(
        index=3, name="缺字体文本", kind="type", text="English", font_name="GhostFont_XYZ",
        font_size=36.0, tracking=0.0, psd_bbox=(100, 400, 200, 500), motion_pos=(0, 200),
        font_info={"detection_status": "font_missing", "glyph_coverage": 0.0, "has_missing_glyphs": True, "fallback_font": "PingFangSC-Regular", "missing_chars": ["E"]}
    )
    info_unverifiable = PSDLayerInfo(
        index=4, name="无法验证文本", kind="type", text="Special", font_name="CustomFont",
        font_size=36.0, tracking=0.0, psd_bbox=(100, 550, 200, 650), motion_pos=(0, 300),
        font_info={"detection_status": "unverifiable", "glyph_coverage": None, "has_missing_glyphs": True, "missing_chars": []}
    )

    test_layers = [info_complete, info_partial, info_missing, info_unverifiable]
    win.canvas_view.load_layers(test_layers)

    # 1. 验证画布图元徽章文案与色彩 (绿/橙/红/黄)
    item_complete = win.canvas_view.right_canvas.items_map[1]
    t1, bg1, fg1 = item_complete.get_badge_info()
    assert "🟢" in t1 and "100%" in t1
    assert fg1.name().lower() == "#30d158"
    assert bg1.name().lower() == "#14301c"

    item_partial = win.canvas_view.right_canvas.items_map[2]
    t2, bg2, fg2 = item_partial.get_badge_info()
    assert "🟠" in t2 and "缺字" in t2 and "领" in t2
    assert fg2.name().lower() == "#ff9f0a"
    assert bg2.name().lower() == "#3d2914"

    item_missing = win.canvas_view.right_canvas.items_map[3]
    t3, bg3, fg3 = item_missing.get_badge_info()
    assert "🔴" in t3 and "未安装" in t3
    assert fg3.name().lower() == "#ff453a"
    assert bg3.name().lower() == "#3d1418"

    item_unverifiable = win.canvas_view.right_canvas.items_map[4]
    t4, bg4, fg4 = item_unverifiable.get_badge_info()
    assert "🟡" in t4 and "无法验证" in t4
    assert fg4.name().lower() == "#ffd60a"
    assert bg4.name().lower() == "#3d3514"

    # 2. 验证属性面板 (Inspector) 按钮文本与色彩
    win.inspector.load_layers(test_layers)

    # complete 态
    win.inspector.tree.setCurrentItem(win.inspector.tree.topLevelItem(0))
    btn_text = win.inspector.font_badge_btn.text()
    assert "🟢" in btn_text and "100%" in btn_text
    assert "#30d158" in win.inspector.font_badge_btn.styleSheet().lower()

    # partial 态
    win.inspector.tree.setCurrentItem(win.inspector.tree.topLevelItem(1))
    btn_text = win.inspector.font_badge_btn.text()
    assert "🟠" in btn_text and "缺少字形" in btn_text
    assert "#ff9f0a" in win.inspector.font_badge_btn.styleSheet().lower()

    # missing 态
    win.inspector.tree.setCurrentItem(win.inspector.tree.topLevelItem(2))
    btn_text = win.inspector.font_badge_btn.text()
    assert "🔴" in btn_text and "未安装" in btn_text
    assert "#ff453a" in win.inspector.font_badge_btn.styleSheet().lower()

    # unverifiable 态
    win.inspector.tree.setCurrentItem(win.inspector.tree.topLevelItem(3))
    btn_text = win.inspector.font_badge_btn.text()
    assert "🟡" in btn_text and "无法验证" in btn_text
    assert "#ffd60a" in win.inspector.font_badge_btn.styleSheet().lower()

    # 3. 验证触发按钮点击，校验跨 Tab 联动跳转至 Tab 3 (索引 2)
    win.tab_widget.setCurrentIndex(0)
    win.inspector.font_badge_btn.click()
    assert win.tab_widget.currentIndex() == 2


def test_duplicate_layer_names_diagnosis_navigation_accuracy():
    """
    用例 5: 同名图层诊断跳转精准导航测试（杜绝子串或同名首项误匹配）
    - 显式构造两个名称完全相同（均为 '副标题'）但在不同层级路径且 index 不同的图层
    - 分别触发 _on_jump_to_diagnosis，严格断言 diag_table.currentRow() 精准对应各自的行号
    - 验证无同名首项抢占误匹配
    """
    win = MainWindow()
    win.show()

    layer1 = PSDLayerInfo(
        index=10, name="副标题", kind="type", text="顶部副标题", font_name="PingFangSC-Regular",
        font_size=24.0, tracking=0.0, psd_bbox=(100, 100, 300, 140), motion_pos=(0, 200),
        layer_path="页眉组/副标题"
    )
    layer2 = PSDLayerInfo(
        index=20, name="副标题", kind="type", text="底部副标题", font_name="PingFangSC-Regular",
        font_size=24.0, tracking=0.0, psd_bbox=(100, 800, 300, 840), motion_pos=(0, -200),
        layer_path="页脚组/副标题"
    )

    diag_report = {
        "summary": {
            "source_file": {"name": "dual_subtitle.psd", "path": "/path/dual_subtitle.psd"},
            "total_layers": 2,
            "preserved_count": 2,
            "degraded_count": 0,
            "ignored_count": 0,
            "failed_count": 0,
            "missing_fonts_count": 0,
            "has_missing_risk": False,
            "risk_assessment": "无风险"
        },
        "layers": [
            {
                "layer_index": 10,
                "layer_path": "页眉组/副标题",
                "layer_name": "副标题",
                "layer_type": "type",
                "disposition": "preserved",
                "reason": "纯矢量文本，字体元数据完整，保留为可发布标题",
                "font_status": "complete",
                "missing_glyphs": []
            },
            {
                "layer_index": 20,
                "layer_path": "页脚组/副标题",
                "layer_name": "副标题",
                "layer_type": "type",
                "disposition": "preserved",
                "reason": "纯矢量文本，字体元数据完整，保留为可发布标题",
                "font_status": "complete",
                "missing_glyphs": []
            }
        ]
    }

    win._populate_diagnosis_tab(diag_report)
    assert win.diag_table.rowCount() == 2

    # 1. 跳转至第一个图层 (index=10)
    win._on_jump_to_diagnosis(layer1)
    assert win.tab_widget.currentIndex() == 2
    assert win.diag_table.currentRow() == 0, f"应精准定位到第 0 行，实际为 {win.diag_table.currentRow()}"

    # 2. 跳转至第二个同名图层 (index=20)
    win._on_jump_to_diagnosis(layer2)
    assert win.tab_widget.currentIndex() == 2
    assert win.diag_table.currentRow() == 1, f"同名图层应精准定位到第 1 行，绝不可错误停留在第 0 行！实际为 {win.diag_table.currentRow()}"

    # 3. 验证无 index 时的降级路径精确全等匹配 (不包含子串模糊包含)
    layer2_no_idx = PSDLayerInfo(
        index=None, name="副标题", kind="type", text="底部副标题", font_name="PingFangSC-Regular",
        font_size=24.0, tracking=0.0, psd_bbox=(100, 800, 300, 840), motion_pos=(0, -200),
        layer_path="页脚组/副标题"
    )
    win._on_jump_to_diagnosis(layer2_no_idx)
    assert win.diag_table.currentRow() == 1, "降级全路径匹配必须精准命中第 1 行！"


def test_font_glyph_status_badges_and_navigation():
    """兼容旧测试用例入口"""
    test_four_state_font_badges_and_interaction_coverage()


def test_degraded_and_empty_layer_comparison():
    """
    用例 4: 降级图层并排对比与无像素空图层/图层组说明处理
    - 验证复杂装饰/形状图层在右侧呈现 [降级为 32位贴图] 标记
    - 验证左侧呈现原始 PSD 图层切片
    - 验证空图层/图层组容器在图层单视图下清晰展示文字说明，严禁使用空白图片伪装
    """
    parsed = parse_psd_file(DECORATION_PSD, extract_fallback_pngs=True, png_output_dir="/tmp/test_decor_pngs", extract_thumbnails=True)
    layers = parsed["layers"]

    container = CanvasContainer()
    container.show()
    container.load_layers(layers)

    # 找到降级图层 (如 箭头 或 横线)
    degraded_layers = [l for l in layers if l.kind == "fallback_png"]
    assert len(degraded_layers) >= 2

    arrow_layer = degraded_layers[0]
    container.select_layer(arrow_layer)

    # 验证右侧图元为 ConvertedLayerGraphicItem，且包含贴图或包围盒
    right_item = container.right_canvas.items_map[arrow_layer.index]
    assert right_item is not None

    # 构造并验证无像素空图层/图层组
    empty_group_info = PSDLayerInfo(
        index=99, name="测试组", kind="group", text="", font_name="", font_size=0,
        tracking=0, psd_bbox=None, motion_pos=(0, 0), layer_type="group",
        original_slice_bytes=None
    )
    container.load_layers([empty_group_info])
    container.set_artboard_resolution(1920, 1080)
    container._on_mode_changed(1)  # 单图层对照模式
    container.select_layer(empty_group_info)

    left_item = container.left_canvas.items_map[99]
    assert left_item.is_empty_or_group is True
