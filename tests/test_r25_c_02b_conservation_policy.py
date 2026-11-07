"""
R25 C-2b 智能对象策略 × 可见性 × 守恒（SA-2b 修复 SA-4 问题 1）
================================================================
SA-4 独立复查发现：可见智能对象 + smart_object_policy='skip' 时，
被"显式跳过"的层仍被 append 进 layers_info（双重计数），
input != output + skipped（实测 input=12 output=7 skipped=7，差 -2）。

本文件锁定修复后的契约：
- 守恒式 input == output + skipped 对所有 smart_object_policy × 可见性组合恒成立；
- skip 策略下智能对象【不出现】在输出层列表（layers_info / r["layers"]），
  但【必须出现】在诊断中：disposition='ignored' 且 reason 含"跳过"；
- flatten 策略下可见智能对象降级为位图（disposition='degraded'），
  PNG 无法合成时按 SA-4 问题 2 规则大声记录（见 test_r25_c_11）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file, verify_layer_conservation


def _so_diag_items(r):
    return [d for d in r["diagnosis_report"]["layers"] if d["layer_type"] == "smartobject"]


def _so_names_in_output(r):
    return {l.name for l in r["layers"] if l.layer_type == "smartobject"}


def test_visible_smartobject_skip_policy_conservation(tmp_path):
    """可见智能对象 × skip：守恒成立；SO 不进输出层列表；诊断有 ignored+跳过 条目。"""
    p = FX.build_visible_smartobject_psd(str(tmp_path / "vis_so_skip.psd"))
    r = parse_psd_file(p, smart_object_policy="skip")

    cons = verify_layer_conservation(r)
    assert cons["holds"], f"守恒被破坏: {cons['detail']}"

    sos = _so_diag_items(r)
    assert sos, "应存在智能对象诊断条目"
    for so in sos:
        assert so["disposition"] == "ignored", "skip 策略下智能对象应为 ignored"
        assert "跳过" in so["reason"], "诊断原因必须含'跳过'"
        assert "智能对象" in so["reason"], "原因须指明是智能对象"
        assert so["layer_name"] not in _so_names_in_output(r), (
            f"skip 策略下智能对象 '{so['layer_name']}' 不得出现在输出层列表（skip 语义）"
        )
    # 输出层列表中不允许存在任何 smartobject
    assert _so_names_in_output(r) == set(), "skip 策略下 layers_info 中智能对象数应为 0"
    # 双重计数回归：output + skipped 必须逐层数得清
    assert cons["input_layer_count"] == cons["output_layer_count"] + cons["skipped_layer_count"]


def test_hidden_smartobject_skip_policy_conservation(tmp_path):
    """隐藏智能对象 × skip：守恒成立；同样不进输出；诊断显式记录跳过（非静默）。"""
    p = FX.copy_complex_psd(str(tmp_path / "hidden_so_skip.psd"))
    r = parse_psd_file(p, smart_object_policy="skip")

    cons = verify_layer_conservation(r)
    assert cons["holds"], f"守恒被破坏: {cons['detail']}"

    sos = _so_diag_items(r)
    assert sos, "应存在智能对象诊断条目"
    for so in sos:
        assert so["disposition"] == "ignored"
        assert "跳过" in so["reason"] or "skip" in so["reason"]
    assert _so_names_in_output(r) == set(), "隐藏+skip 的智能对象不得进入输出层列表"


def test_visible_smartobject_flatten_policy_conservation(tmp_path):
    """可见智能对象 × flatten（默认）：降级为位图计入 output，守恒成立。"""
    p = FX.build_visible_smartobject_psd(str(tmp_path / "vis_so_flatten.psd"))
    r = parse_psd_file(p)

    cons = verify_layer_conservation(r)
    assert cons["holds"], f"守恒被破坏: {cons['detail']}"

    sos = _so_diag_items(r)
    assert sos, "应存在智能对象诊断条目"
    for so in sos:
        assert so["disposition"] == "degraded", "可见智能对象在 flatten 策略下应降级为位图"
        assert so["layer_name"] in _so_names_in_output(r), (
            f"降级智能对象 '{so['layer_name']}' 应计入输出层（绝不静默丢弃）"
        )
    assert cons["output_layer_count"] >= len(sos)


def test_policy_matrix_conservation_all_combinations(tmp_path):
    """策略矩阵全组合（skip/flatten × 复杂 PSD/全可见 SO PSD）守恒无一例外。"""
    cases = []
    so_vis = FX.build_visible_smartobject_psd(str(tmp_path / "matrix_vis.psd"))
    so_hid = FX.copy_complex_psd(str(tmp_path / "matrix_hid.psd"))
    for psd in (so_vis, so_hid):
        for policy in ("skip", "flatten"):
            cases.append((psd, policy))
    for psd, policy in cases:
        r = parse_psd_file(psd, smart_object_policy=policy)
        cons = verify_layer_conservation(r)
        assert cons["holds"], (
            f"policy={policy} psd={os.path.basename(psd)} 守恒被破坏: {cons['detail']}"
        )
        # 诊断条目数 == 输入层数（每层必入诊断，绝不静默消失）
        assert len(r["diagnosis_report"]["layers"]) == cons["input_layer_count"]
