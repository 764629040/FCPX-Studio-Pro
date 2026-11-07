"""
R25 C-5 混合模式写入 Motion（写出就绪）
====================================
extract_layer_blend_mode 已读取混合模式；本项补齐"写出就绪"层：
- 把 PSD 混合模式中文名转为 Motion blendMode 参数；
- 序列化为可读 XML 片段，供 motion_builder 后续写入 .moti。

注意：最终写入 .moti 的集成钩子在 core/motion_builder.py（本次 R25 红线，未改动）。
本测试验证数据层与序列化正确，且已接入 parse 结果（diag / PSDLayerInfo）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file
from core.motion_param_writer import format_blend_mode_for_motion, serialize_motion_param_block

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def test_format_blend_mode_mapping():
    m = format_blend_mode_for_motion("混合模式: 正片叠底")
    assert m["supported"] is True
    assert m["param_name"] == "blendMode"
    assert m["motion_value"] == "multiply"

    m2 = format_blend_mode_for_motion("混合模式: 滤色")
    assert m2["motion_value"] == "screen"

    # 未知/不支持的混合模式：降级为 normal 并说明，不得伪通过
    m3 = format_blend_mode_for_motion("混合模式: 某种未知模式")
    assert m3["supported"] is False
    assert m3["motion_value"] == "normal"

    # 无混合模式（Normal / PassThrough）：不写
    m4 = format_blend_mode_for_motion(None)
    assert m4["supported"] is False
    assert m4["motion_value"] == "normal"


def test_serialize_motion_param_block():
    m = format_blend_mode_for_motion("混合模式: 叠加")
    xml = serialize_motion_param_block(m)
    assert xml.startswith("<motionParamBlock>")
    assert "blendMode" in xml
    assert "overlay" in xml
    assert xml.strip().endswith("</motionParamBlock>")


def test_blend_mode_wired_into_parse_result():
    """解析结果里每个图层都带有 motion_blend_mode 字段（param_name=blendMode）。"""
    r = parse_psd_file(COMPLEX_PSD)
    for d in r["diagnosis_report"]["layers"]:
        mb = d.get("motion_blend_mode")
        assert isinstance(mb, dict), "每个图层须带 motion_blend_mode 字段"
        assert mb.get("param_name") == "blendMode"
    # PSDLayerInfo 同样携带
    for li in r["layers"]:
        assert li.motion_blend_mode.get("param_name") == "blendMode"
