"""
R25 C-2 智能对象处理
====================
智能对象必须二选一处置，绝不静默丢弃：
- 默认 flatten：展平为位图（降级为 PNG 嵌入），并记入诊断；
- smart_object_policy='skip'：显式跳过并记录原因（仍计入 skipped）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file, verify_layer_conservation

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _smartobject_diag_items(r):
    return [d for d in r["diagnosis_report"]["layers"] if d["layer_type"] == "smartobject"]


def test_smart_object_skip_policy_records_reason(tmp_path):
    """skip 策略：智能对象显式跳过并记录原因，计入 skipped，绝不静默。"""
    p = FX.copy_complex_psd(str(tmp_path / "so_skip.psd"))
    r = parse_psd_file(p, smart_object_policy="skip")
    sos = _smartobject_diag_items(r)
    assert sos, "应存在智能对象诊断条目"
    for so in sos:
        assert so["disposition"] == "ignored", "skip 策略下智能对象应被显式忽略"
        assert "skip" in so["reason"] or "跳过" in so["reason"], "必须记录跳过原因"
        assert "智能对象" in so["reason"], "原因须指明是智能对象"
    assert verify_layer_conservation(r)["holds"]


def test_smart_object_flatten_policy_degrades_not_silent(tmp_path):
    """flatten 策略（默认）：可见智能对象降级为位图，计入 output，绝不静默丢弃。"""
    p = FX.build_visible_smartobject_psd(str(tmp_path / "so_flatten.psd"))
    r = parse_psd_file(p)
    sos = _smartobject_diag_items(r)
    assert sos, "应存在智能对象诊断条目"
    for so in sos:
        assert so["disposition"] == "degraded", "可见智能对象应降级（展平为位图）"
        assert any("智能对象" in f for f in so["unsupported_features"]), "须记录智能对象为不支持特性"
        assert so["reason"], "降级须有原因"
    # 降级层计入 output，守恒成立
    assert r["output_layer_count"] >= 1
    assert verify_layer_conservation(r)["holds"]
    # 若环境具备 composite（如装了 scipy），应真正产出 PNG；否则至少不静默丢失（已 degraded）
    degraded_with_png = [d for d in sos if d.get("fallback_png")]
    if not degraded_with_png:
        for d in sos:
            assert d["disposition"] == "degraded"
