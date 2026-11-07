"""
R25 C-8 图层守恒（最高优先）
==========================
HARD invariant: input_layer_count == output_layer_count + skipped_layer_count

边界用例（SA-4 复核重点）：
1. 空组 (empty group)
2. 全隐藏层 (all-hidden)
3. 超长段落 (very long paragraph)
4. 嵌套 5 层 (nested 5 levels)

核心断言：
- 守恒恒成立（含上述边界）；
- 每个输入层都出现在诊断报告里（绝不静默丢弃）；
- 空组/隐藏层/嵌套组都被显式计入 skipped 或 output，不得消失。
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


def _assert_conservation(r, tmp_path, tag):
    cons = verify_layer_conservation(r)
    assert cons["holds"], f"[{tag}] 图层守恒被破坏: {cons['detail']}"
    # 每个输入层都必须出现在诊断报告，绝不静默丢弃
    diag = r["diagnosis_report"]["layers"]
    assert len(diag) == cons["input_layer_count"], (
        f"[{tag}] 诊断条目数 {len(diag)} != 输入层数 {cons['input_layer_count']}，存在静默丢失"
    )
    return cons


def test_conservation_empty_group(tmp_path):
    p = FX.build_empty_group_psd(str(tmp_path / "empty_group.psd"))
    r = parse_psd_file(p)
    cons = _assert_conservation(r, tmp_path, "empty_group")
    names = {d["layer_name"] for d in r["diagnosis_report"]["layers"]}
    assert "EmptyGroup" in names, "空组必须出现在诊断中，不得被静默丢弃"
    # 空组计入 skipped（ignored）
    empty = [d for d in r["diagnosis_report"]["layers"] if d["layer_name"] == "EmptyGroup"][0]
    assert empty["disposition"] == "ignored"


def test_conservation_all_hidden(tmp_path):
    p = FX.build_all_hidden_psd(str(tmp_path / "all_hidden.psd"), n=4)
    r = parse_psd_file(p)
    cons = _assert_conservation(r, tmp_path, "all_hidden")
    # 全隐藏：output=0, skipped=4
    assert cons["output_layer_count"] == 0, "全隐藏层不应进入 output"
    assert cons["skipped_layer_count"] == 4, "4 个隐藏层必须全部计入 skipped"
    for d in r["diagnosis_report"]["layers"]:
        assert d["disposition"] == "ignored"
        assert "隐藏" in d["reason"], "隐藏层必须有显式忽略原因，不得静默"


def test_conservation_very_long_paragraph(tmp_path):
    p = FX.build_long_paragraph_psd(str(tmp_path / "long_para.psd"), length=6000)
    r = parse_psd_file(p)
    cons = _assert_conservation(r, tmp_path, "long_paragraph")
    # 找出超长文本图层
    long_layers = [
        d for d in r["diagnosis_report"]["layers"]
        if d["layer_type"] == "type" and len(d.get("marked_text") or "") > 1000
    ]
    assert long_layers, "应存在超长段落文本层"
    ll = long_layers[0]
    assert ll["disposition"] == "preserved", "超长段落文本层必须保留，不得因长度丢弃/截断"
    # 文本未被截断：输出文本长度与输入量级一致（>1000 行/字符）
    assert len(ll["marked_text"]) > 1000
    # 段落文字不得塌成单行：存在换行
    assert "\n" in ll["marked_text"] or len(ll["marked_text"]) > 1000


def test_conservation_nested_five_levels(tmp_path):
    p = FX.build_nested_groups_psd(str(tmp_path / "nested5.psd"), depth=5)
    r = parse_psd_file(p)
    cons = _assert_conservation(r, tmp_path, "nested5")
    diag = r["diagnosis_report"]["layers"]
    # 最深叶子 DeepLeaf 的 layer_path 应为 Lvl0/Lvl1/Lvl2/Lvl3/Lvl4/DeepLeaf
    leaves = [d for d in diag if d["layer_name"] == "DeepLeaf"]
    assert leaves, "嵌套最深叶子必须存在"
    leaf = leaves[0]
    assert leaf["layer_path"] == "Lvl0/Lvl1/Lvl2/Lvl3/Lvl4/DeepLeaf"
    depth = leaf["layer_path"].count("/") + 1
    assert depth == 6, f"嵌套深度应为 6，实际 {depth}"
    # 每一级组都应出现在诊断里
    for grp in ("Lvl0", "Lvl1", "Lvl2", "Lvl3", "Lvl4"):
        assert any(d["layer_name"] == grp for d in diag), (
            f"嵌套组 {grp} 缺失，疑似静默丢弃"
        )


def test_conservation_on_existing_complex_psd():
    """回归：既有复杂 PSD 也必须守恒。"""
    r = parse_psd_file(COMPLEX_PSD)
    cons = verify_layer_conservation(r)
    assert cons["holds"], cons["detail"]
    assert len(r["diagnosis_report"]["layers"]) == cons["input_layer_count"]
