"""
R25 C-3 / C-4 图层样式：描边 / 投影 / 发光
=========================================
- PSD 描边 → 结构化提取 size/color/position，并产出 Motion 描边参数（写出就绪）；
- 投影 / 发光同理；
- 若 Motion 矢量规范不支持该样式，必须记入诊断（unsupported_features / layer_styles），
  绝不静默忽略。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file
from core.psd_layer_fallback import extract_layer_styles
from core.motion_param_writer import (
    format_stroke_for_motion,
    format_shadow_for_motion,
    format_glow_for_motion,
    build_layer_style_motion_entries,
)

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _fake_effect(cls_name, **attrs):
    """构造一个假 effect 对象，类名即 cls_name，便于 extract_layer_styles 分类。"""
    cls = type(cls_name, (), {"enabled": True})
    inst = cls()
    for k, v in attrs.items():
        setattr(inst, k, v)
    return inst


class _FakeColor:
    def __init__(self, rgb):
        self.value = tuple(rgb)


def test_real_stroke_style_extracted_and_recorded():
    """真实夹具：complex_layers 的 Image01 带描边，必须提取并记入诊断。"""
    r = parse_psd_file(COMPLEX_PSD)
    stroke_items = [
        d for d in r["diagnosis_report"]["layers"]
        if d.get("layer_styles", {}).get("styles", {}).get("描边")
    ]
    assert stroke_items, "应存在带描边的图层诊断条目"
    item = stroke_items[0]
    stroke = item["layer_styles"]["styles"]["描边"]
    assert stroke.get("size") is not None, "描边应提取出 size"
    assert stroke.get("color") is not None, "描边应提取出 color"
    # 描边须同时进入 unsupported_features（不被静默忽略）
    assert any("描边" in f for f in item["unsupported_features"])


def test_stroke_motion_param_ready():
    """C-3：描边结构化参数 → Motion 描边参数（写出就绪）。"""
    entry = format_stroke_for_motion({"size": 4.0, "color": [255, 0, 0], "position": "outF", "opacity": 100.0})
    assert entry["supported"] is True
    p = entry["params"]
    assert p["strokeEnabled"] is True
    assert p["strokeWidth"] == 4.0
    assert p["strokeColor"] == [255, 0, 0]
    assert p["strokePosition"] == "outF"


def test_shadow_and_glow_motion_param_ready():
    """C-4：投影 / 外发光结构化参数 → Motion 近似参数（写出就绪）。"""
    shadow = format_shadow_for_motion({"blur": 10.0, "distance": 5.0, "angle": 90.0, "color": [0, 0, 0], "opacity": 75.0})
    assert shadow["supported"] is True
    assert shadow["params"]["dropShadow"] is True
    assert shadow["params"]["blur"] == 10.0
    # angle=90° -> offsetX≈0, offsetY≈5
    assert abs(shadow["params"]["offsetY"] - 5.0) < 0.01

    glow = format_glow_for_motion({"blur": 8.0, "color": [255, 200, 0], "opacity": 60.0})
    assert glow["supported"] is True
    assert glow["params"]["glow"] is True
    assert glow["params"]["blur"] == 8.0


def test_layer_style_motion_entries_builds_all_types():
    """build_layer_style_motion_entries 对描边/投影/发光生成写出就绪条目。"""
    styles = extract_layer_styles(_fake_layer_with_effects())
    entries = build_layer_style_motion_entries(styles)
    assert "描边" in entries and entries["描边"]["supported"]
    assert "投影" in entries and entries["投影"]["supported"]
    assert "外发光" in entries and entries["外发光"]["supported"]
    # 不支持近似映射的样式仍显式标注 unsupported，不静默
    assert "斜面和浮雕" in entries and entries["斜面和浮雕"]["supported"] is False


def _fake_layer_with_effects():
    """构造带描边/投影/外发光/斜面和浮雕的假图层对象（无真实夹具时单元覆盖）。"""
    class _Layer:
        effects = [
            _fake_effect("Stroke", size=2.0, color=_FakeColor((255, 255, 255)), position="outF", opacity=100.0),
            _fake_effect("DropShadow", blur=10.0, distance=5.0, angle=90.0, color=_FakeColor((0, 0, 0)), opacity=75.0),
            _fake_effect("OuterGlow", blur=8.0, color=_FakeColor((255, 200, 0)), opacity=60.0),
            _fake_effect("BevelEmboss"),
        ]
    return _Layer()
