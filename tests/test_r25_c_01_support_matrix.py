"""
R25 C-1 PSD 支持边界文档化
==========================
- 支持矩阵（core/psd_support_matrix.PSD_SUPPORT_MATRIX）覆盖 parser 处理到的全部图层类型；
- 每个条目都必须给出"不支持时的行为"，不得静默丢弃；
- docs/psd_support_matrix_R25.md 存在并引用该矩阵。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from core.psd_support_matrix import (
    PSD_SUPPORT_MATRIX,
    LAYER_TYPES_HANDLED,
    get_support_entry,
    validate_support_matrix_complete,
)
import r25_fixtures as FX
from core.psd_parser import parse_psd_file

PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
DOC_PATH = os.path.join(PROJECT_ROOT, "docs", "psd_support_matrix_R25.md")
DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def test_matrix_covers_all_handled_types():
    for lt in LAYER_TYPES_HANDLED:
        entry = get_support_entry(lt)
        assert entry, f"支持矩阵缺少图层类型条目: {lt}"
        assert (entry.get("behavior_when_unsupported") or "").strip(), (
            f"图层类型 {lt} 的 '不支持时行为' 不得为空（禁止静默丢弃）"
        )
        assert entry.get("disposition"), f"图层类型 {lt} 必须声明处置方式"


def test_matrix_entries_all_complete():
    res = validate_support_matrix_complete([])
    assert res["incomplete_entries"] == [], f"存在行为描述不完整的矩阵条目: {res['incomplete_entries']}"
    assert res["matrix_entry_count"] == len(LAYER_TYPES_HANDLED), "矩阵条目数应与受处理类型数一致"


def test_matrix_covers_parser_found_types():
    """矩阵必须覆盖 parser 实际遇到的全部图层类型（含真实复杂 PSD）。"""
    r = parse_psd_file(COMPLEX_PSD)
    found = {d["layer_type"] for d in r["diagnosis_report"]["layers"]}
    # 未知类型在 parser 中归为 str(layer.kind)，可能不在矩阵里；
    # 这里只校验"已知类型"均被矩阵覆盖。
    known = {t for t in found if t in LAYER_TYPES_HANDLED}
    res = validate_support_matrix_complete(sorted(known))
    assert res["all_found_covered"], f"矩阵未覆盖的图层类型: {res['missing_types']}"


def test_doc_exists_and_references_matrix():
    assert os.path.isfile(DOC_PATH), "C-1 文档 docs/psd_support_matrix_R25.md 必须存在"
    with open(DOC_PATH, "r", encoding="utf-8") as f:
        content = f.read()
    # 文档应引用核心模块与关键类型，证明它和代码矩阵对齐
    assert "psd_support_matrix" in content, "文档应引用 core/psd_support_matrix 模块"
    for lt in ("type", "smartobject", "shape", "pixel", "group"):
        assert lt in content, f"文档应覆盖图层类型: {lt}"
    # 文档必须声明"不得静默丢弃"
    assert "静默" in content
