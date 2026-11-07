"""
R31 / A-59：has_missing_glyphs 语义拆分
=====================================
旧行为：`has_missing_glyphs` 直取 `has_missing_risk`，于是 unverifiable 时出现
「has_missing_glyphs=True 但 missing_chars=[]」的自相矛盾。

新口径（向后兼容）：
  · has_confirmed_missing_glyphs —— 确证缺字：missing_chars 非空
  · has_glyph_risk               —— 任何风险，含环境不可验证
  · has_missing_glyphs           —— DEPRECATED，等同 has_glyph_risk，保留兼容
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

import pytest

from core.psd_parser import parse_psd_file, PSDLayerInfo
from core.missing_font import missing_glyph_layer_state

FOUR_STATE_PSD = os.path.join(TESTS_DIR, "data", "four_state.psd")


class _FakeInfo:
    def __init__(self, font_info):
        self.font_info = font_info
        self.missing_glyph_visible_marker = False
        self.highlight_missing_font = False
        self.marked_text = ""


def test_font_info_splits_risk_and_confirmed():
    """解析真实夹具：每个文本层的两个新字段必须自洽。"""
    parsed = parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    types = [l for l in parsed["layers"] if l.kind == "type"]
    assert types, "夹具应包含文本层"

    for layer in types:
        fi = layer.font_info
        assert "has_confirmed_missing_glyphs" in fi, f"{layer.name} 缺确证缺字字段"
        assert "has_glyph_risk" in fi, f"{layer.name} 缺风险字段"
        # 向后兼容：旧字段仍在，且与 has_glyph_risk 同值
        assert "has_missing_glyphs" in fi
        assert fi["has_missing_glyphs"] == fi["has_glyph_risk"]
        # 确证缺字必须由 missing_chars 决定
        assert fi["has_confirmed_missing_glyphs"] == bool(fi["missing_chars"])
        # 无检测能力时不得声称"确证缺字"
        if fi["detection_status"] == "unverifiable":
            assert fi["has_confirmed_missing_glyphs"] is False


def test_unverifiable_is_risk_not_confirmed():
    """unverifiable + 空 missing_chars：风险为真，但确证缺字必须为假。"""
    info = _FakeInfo({
        "detection_status": "unverifiable",
        "has_glyph_risk": True,
        "has_confirmed_missing_glyphs": False,
        "has_missing_glyphs": True,   # 旧字段（兼容）
        "missing_chars": [],
    })
    state = missing_glyph_layer_state(info)
    assert state["highlight"] is True, "unverifiable 仍应高亮提示风险"
    assert state["confirmed_missing"] is False, "缺字清单为空时不得说确证缺字"
    assert state["missing_chars"] == []


def test_legacy_field_still_consumed_when_new_fields_missing():
    """旧数据没有新字段时，判定逻辑必须回退到 has_missing_glyphs（不 KeyError）。"""
    info = _FakeInfo({
        "detection_status": "missing_fallback",
        "has_missing_glyphs": True,
        "missing_chars": ["囍"],
    })
    state = missing_glyph_layer_state(info)
    assert state["highlight"] is True
    assert state["confirmed_missing"] is True


def test_default_font_info_has_new_fields():
    layer = PSDLayerInfo(
        index=0, name="t", kind="type", text="测试",
        font_name="Helvetica", font_size=24, tracking=0,
        psd_bbox=(0, 0, 10, 10), motion_pos=(0, 0),
    )
    fi = layer.font_info
    assert fi["has_glyph_risk"] is False
    assert fi["has_confirmed_missing_glyphs"] is False
    assert fi["has_missing_glyphs"] is False


def test_diagnosis_report_declares_field_semantics():
    parsed = parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    schema = parsed["diagnosis_report"].get("schema", {})
    fields = schema.get("font_info_fields", {})
    assert "has_confirmed_missing_glyphs" in fields
    assert "has_glyph_risk" in fields
    assert "DEPRECATED" in fields.get("has_missing_glyphs", "").upper()
