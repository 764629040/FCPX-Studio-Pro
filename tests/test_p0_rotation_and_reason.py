"""
回归测试：独立审核 P0 退回项
  A-1 旋转文本方向丢失（core/psd_parser.py 曾把 rotation 硬编码为 0.0）
  A-2 诊断“具体处理原因”未按字体四态分化（四态共用同一句文案）

对应修复：
  core/psd_parser.py  — 新增 detect_layer_rotation()，从 layer.transform 还原
                        旋转角并接入文本/降级两个构造点；处置原因按
                        complete / partial_missing / font_missing / unverifiable
                        四态分别生成。
  gui/canvas_view.py  — update_geometry_from_info() 真正应用 rotation，
                        并按原稿 bbox 校正旋转后矩形，避免越出画板。

夹具：tests/data/complex_layers.psd 中的 Text01 / Title 两个 90° 竖排文本层。
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

from core.psd_parser import parse_psd_file, detect_layer_rotation, PSDLayerInfo
from gui.canvas_view import CanvasContainer

app = QApplication.instance() or QApplication(sys.argv)

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")

ROTATED_LAYER_NAMES = ("Text01", "Title")


# ═══════════════════════════════════════════════════════════════
# A-1  旋转文本方向
# ═══════════════════════════════════════════════════════════════
class _FakeLayer:
    """最小 transform 载体，用于单测 detect_layer_rotation 的角度换算"""
    def __init__(self, transform):
        self.transform = transform


@pytest.mark.parametrize("transform,expected", [
    ((1.0, 0.0, 0.0, 1.0, 10.0, 20.0), 0.0),      # 横排
    ((0.0, 1.0, -1.0, 0.0, 10.0, 20.0), 90.0),     # 竖排 90°
    ((-1.0, 0.0, 0.0, -1.0, 10.0, 20.0), 180.0),   # 180°
    ((0.0, -1.0, 1.0, 0.0, 10.0, 20.0), 270.0),    # 270°
])
def test_detect_layer_rotation_cardinal_angles(transform, expected):
    """0/90/180/270 正交角度必须被准确还原"""
    assert detect_layer_rotation(_FakeLayer(transform)) == expected


@pytest.mark.parametrize("transform", [
    None,
    (),
    (0.0, 0.0, 0.0, 0.0, 5.0, 5.0),
    ("bad", "data", 0, 1, 0, 0),
])
def test_detect_layer_rotation_degrades_safely(transform):
    """transform 缺失或退化时必须安全返回 0.0，绝不抛异常"""
    assert detect_layer_rotation(_FakeLayer(transform)) == 0.0


def test_detect_layer_rotation_tolerance_snap():
    """±2° 内吸附到正交角度；超出容差保留精确角度"""
    import math
    near_90 = _FakeLayer((math.cos(math.radians(89.0)), math.sin(math.radians(89.0)),
                          -math.sin(math.radians(89.0)), math.cos(math.radians(89.0)), 0, 0))
    assert detect_layer_rotation(near_90) == 90.0

    tilted = _FakeLayer((math.cos(math.radians(37.0)), math.sin(math.radians(37.0)),
                         -math.sin(math.radians(37.0)), math.cos(math.radians(37.0)), 0, 0))
    assert abs(detect_layer_rotation(tilted) - 37.0) < 0.01


def test_vertical_text_layers_keep_rotation_and_thin_bbox():
    """
    A-1 核心断言：
    complex_layers.psd 的 Text01 / Title 在 PSD 中为 90° 竖排。
    解析结果必须 rotation != 0，且 bbox 呈细高竖条（宽 < 高）。
    """
    assert os.path.isfile(COMPLEX_PSD), f"夹具缺失: {COMPLEX_PSD}"
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)

    by_name = {l.name: l for l in parsed["layers"]}
    for name in ROTATED_LAYER_NAMES:
        assert name in by_name, f"夹具中缺少图层 {name}"
        layer = by_name[name]
        left, top, right, bottom = layer.psd_bbox
        width, height = right - left, bottom - top

        assert layer.rotation != 0.0, f"{name} 旋转角被丢弃（仍为 0.0）"
        assert layer.rotation == 90.0, f"{name} 旋转角应为 90°，实际 {layer.rotation}"
        assert width < height, f"{name} bbox 应为细高竖条，实际 {width}x{height}"


def test_rotated_layer_geometry_stays_inside_artboard():
    """
    A-1 渲染断言：旋转必须真正应用到图元，且旋转后外接框不越出画板。
    """
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    canvas_w, canvas_h = parsed["width"], parsed["height"]

    container = CanvasContainer()
    container.resize(1400, 900)
    container.show()
    container.load_layers(parsed["layers"])
    container.set_artboard_resolution(canvas_w, canvas_h)

    by_name = {l.name: l for l in parsed["layers"]}
    for name in ROTATED_LAYER_NAMES:
        item = container.right_canvas.items_map[by_name[name].index]
        assert item.rotation() == 90.0, f"{name} 图元未应用 90° 旋转"

        bbox = item.sceneBoundingRect()
        # 竖排文本：视觉高度应显著大于视觉宽度
        assert bbox.height() > bbox.width(), f"{name} 渲染后仍为横排形态"
        assert bbox.left() >= -canvas_w / 2 - 1, f"{name} 越出画板左边"
        assert bbox.right() <= canvas_w / 2 + 1, f"{name} 越出画板右边"
        assert bbox.top() >= -canvas_h / 2 - 1, f"{name} 越出画板上边"
        assert bbox.bottom() <= canvas_h / 2 + 1, f"{name} 越出画板下边"


def test_rotation_matches_bbox_aspect_and_transform():
    """
    旋转角必须与 PSD 原始 transform 和 bbox 形态三者自洽，不得凭空产生。

    注意：本夹具（竖版海报）中中西文混合，西文层本身就是 90° 竖排，
    因此不能假设"未旋转"= 全部 0°。真正的判定依据是 transform 线性部分：
      - 线性部分为 [[1,0],[0,1]] -> rotation 必须为 0
      - 线性部分为 [[0,1],[-1,0]] -> rotation 必须为 90
    """
    import math
    from psd_tools import PSDImage

    psd = PSDImage.open(NORMAL_PSD)
    raw = {}
    for l in psd.descendants():
        if l.kind == "type":
            raw[l.name] = l.transform

    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=False)
    checked = 0
    for layer in parsed["layers"]:
        t = raw.get(layer.name)
        if not t:
            continue
        checked += 1
        expected = round(math.degrees(math.atan2(t[1], t[0])) % 360.0, 4)
        expected = 0.0 if abs(expected - 360.0) < 2.0 else expected
        assert layer.rotation == expected, (
            f"{layer.name} 旋转角 {layer.rotation} 与 transform 推导值 {expected} 不符"
        )
        # 竖排（90/270）图层 bbox 必须是细高竖条；横排则宽大于高或接近
        l_, t_, r_, b_ = layer.psd_bbox
        w, h = r_ - l_, b_ - t_
        if layer.rotation in (90.0, 270.0):
            assert w < h, f"{layer.name} 标称竖排但 bbox 为 {w}x{h}"
    assert checked >= 8, f"应至少核对 8 个文本层，实际 {checked}"


# ═══════════════════════════════════════════════════════════════
# A-2  处置原因四态分化
# ═══════════════════════════════════════════════════════════════
def _reason_for_status(status: str) -> str:
    """直接调用被测实现生成文案，避免测试侧复制业务逻辑"""
    from core.psd_parser import build_preserved_reason

    samples = {
        "complete": [],
        "partial_missing": ["领", "衔"],
        "font_missing": ["领", "衔", "呈", "现"],
        "unverifiable": [],
    }
    return build_preserved_reason(status, samples[status], "PingFangSC-Regular")


def test_disposition_reasons_are_four_distinct_strings():
    """四态原因文案必须两两不同"""
    reasons = [_reason_for_status(s) for s in
               ("complete", "partial_missing", "font_missing", "unverifiable")]
    assert len(set(reasons)) == 4, f"四态原因未分化: {reasons}"


def test_font_missing_reason_must_not_claim_metadata_complete():
    """
    A-2 核心断言：font_missing 行严禁出现“元数据完整”，
    且必须携带缺字数量与回退字体信息。
    """
    reason = _reason_for_status("font_missing")
    assert "元数据完整" not in reason
    assert "未安装" in reason
    assert "缺" in reason
    assert "回退字体" in reason


def test_real_psd_reason_matches_font_status():
    """
    真实 PSD：处置原因必须与 font_status 自洽——
    缺字态不得出现"完整"，complete 态不得出现"缺"。
    """
    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=False)
    for item in parsed["diagnosis_report"]["layers"]:
        if item["disposition"] != "preserved":
            continue
        status = item["font_status"]
        reason = item["reason"]

        if status == "complete":
            assert "完整" in reason
            assert "缺" not in reason
        elif status in ("partial_missing", "font_missing"):
            assert "元数据完整" not in reason, f"{status} 行仍写“元数据完整”: {reason}"
            assert "缺" in reason, f"{status} 行未说明缺字: {reason}"
        elif status == "unverifiable":
            assert "无法枚举" in reason or "无法确定" in reason
            assert "元数据完整" not in reason
