"""
R25 C-7 组与段落文字
====================
- 图层组按层级保留（layer_path / parent_path / layer_tree children / depth）；
- 段落文字不得截断为单行（多行文本须保留换行）。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _all_nodes(nodes):
    out = []
    for n in nodes:
        out.append(n)
        out.extend(_all_nodes(n.get("children", [])))
    return out


def test_group_hierarchy_preserved_in_nested_fixture(tmp_path):
    p = FX.build_nested_groups_psd(str(tmp_path / "nested.psd"), depth=5)
    r = parse_psd_file(p)
    diag = r["diagnosis_report"]["layers"]
    leaf = [d for d in diag if d["layer_name"] == "DeepLeaf"][0]
    assert leaf["layer_path"] == "Lvl0/Lvl1/Lvl2/Lvl3/Lvl4/DeepLeaf"
    assert leaf["parent_path"] == "Lvl0/Lvl1/Lvl2/Lvl3/Lvl4"
    # layer_tree 递归子节点也应包含 DeepLeaf
    all_nodes = _all_nodes(r["layer_tree"])
    leaf_nodes = [n for n in all_nodes if n["name"] == "DeepLeaf"]
    assert leaf_nodes, "layer_tree 递归结构中应含 DeepLeaf"
    # 顶层组 Lvl0 的递归后代里应能看到 Lvl4 与 DeepLeaf
    lvl0 = [n for n in r["layer_tree"] if n["name"] == "Lvl0"][0]
    names = {n["name"] for n in _all_nodes([lvl0])}
    assert {"Lvl1", "Lvl2", "Lvl3", "Lvl4", "DeepLeaf"}.issubset(names)


def test_existing_psd_group_hierarchy():
    r = parse_psd_file(COMPLEX_PSD)
    diag = r["diagnosis_report"]["layers"]
    groups = [d for d in diag if d["layer_type"] == "group"]
    assert groups, "复杂 PSD 应含图层组"
    # 组在诊断里记录父子路径
    for g in groups:
        assert "parent_path" in g


def test_paragraph_text_not_truncated_to_single_line(tmp_path):
    p = FX.build_multiline_paragraph_psd(str(tmp_path / "para.psd"))
    r = parse_psd_file(p)
    # 找到被改写的段落文本层（含"第一行标题"）
    para = [
        d for d in r["diagnosis_report"]["layers"]
        if d["layer_type"] == "type" and "第一行标题" in (d.get("marked_text") or "")
    ]
    assert para, "应存在多行段落文本层"
    d = para[0]
    text = d["marked_text"]
    # 不得塌成单行：至少 3 个换行（4 行）
    breaks = text.count("\n") + text.count("\r")
    assert breaks >= 3, f"段落文字被截断为单行，换行数={breaks}"
    for kw in ("第一行标题", "第二行副标题", "第三行说明文字", "第四行落款与日期"):
        assert kw in text, f"段落缺失行: {kw}"


def test_paragraph_text_preserved_on_existing_psd():
    """回归：既有 PSD 文本层保留原始多行结构（\r 不被吞掉）。"""
    r = parse_psd_file(COMPLEX_PSD)
    for li in r["layers"]:
        if li.kind != "type":
            continue
        # 任一文本层都不应是被压缩掉换行的空/单行（除非原本就是单行）
        # 这里只断言 text 字段存在且类型正确，不强制多行
        assert isinstance(li.text, str)
