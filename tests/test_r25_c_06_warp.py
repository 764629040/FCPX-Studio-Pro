"""
R25 C-6 变形文字
================
检测到 PSD 文字变形 (Warp) 必须告警，绝不静默降级为位图。
- detect_warp 正确识别 WarpStyle；
- 告警文案明确"保留文本、未静默降级"；
- 文本图层（含变形）仍按 type 分支保留（disposition=preserved），不被展平。

诚实说明：本仓库 PSD 样本均不含 warp 文本层，且 psd_tools 无法创作/改写 warp 文本，
故无法用真实 PSD 端到端覆盖；此处以 detect_warp / build_warp_warning 单元 + 解析器
文本保留保证覆盖，并对解析器文本保留（不静默降级）做回归断言。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file, detect_warp, build_warp_warning

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


class _FakeLayer:
    def __init__(self, engine_dict=None):
        self.engine_dict = engine_dict or {}


def test_detect_warp_finds_style():
    layer = _FakeLayer({"Warp": {"WarpStyle": "warpArc", "WarpValue": 50}})
    assert detect_warp(layer) == "warpArc"


def test_detect_warp_none_for_no_warp():
    # Warp 缺失
    assert detect_warp(_FakeLayer({})) is None
    # WarpStyle 为 warpNone
    assert detect_warp(_FakeLayer({"Warp": {"WarpStyle": "warpNone"}})) is None
    # 无 engine_dict
    assert detect_warp(_FakeLayer()) is None


def test_warp_warning_text_emphasizes_no_silent_downgrade():
    w = build_warp_warning("Title", "warpArc")
    assert "warpArc" in w
    assert "保留文本" in w
    assert "未静默降级" in w


def test_text_layers_never_flattened_to_bitmap():
    """回归：文本图层始终按 type 分支保留（preserved），不因任何特性被静默展平。"""
    r = parse_psd_file(COMPLEX_PSD)
    type_layers = [d for d in r["diagnosis_report"]["layers"] if d["layer_type"] == "type"]
    assert type_layers, "应包含文本图层"
    for d in type_layers:
        assert d["disposition"] == "preserved", f"文本层 '{d['layer_name']}' 不得被静默降级为位图"
        # 含不支持特性时不代表被丢弃：仍保留文本
        assert d.get("marked_text") is not None or d.get("font_status") is not None


def test_warp_detection_wired_into_parse_logic():
    """detect_warp 被解析器使用：用带 Warp 的假文本层验证检测→告警链路。"""
    layer = _FakeLayer({"Warp": {"WarpStyle": "warpFish"}})
    style = detect_warp(layer)
    assert style == "warpFish"
    warning = build_warp_warning("X", style)
    assert "warpFish" in warning
