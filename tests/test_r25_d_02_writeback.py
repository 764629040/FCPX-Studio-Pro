"""
R25-D2 画布拖拽写回 .moti 单测（纯逻辑，无 PyQt6）
====================================================

被测对象：
  * core/moti_layer_io.py  — .moti 图层位置读写（D-2 落盘的真相源）
  * core/alignment_snap.py — 对齐参考线 + 吸附的纯几何计算

验证策略（SA-4 可独立重跑）：
  1. 用 core.psd_parser.parse_psd_file + core.motion_builder.MotionBuilder
     .build_template_atomic 构造**真实** .moti（与 GUI 保存路径同源，非手写 XML）。
  2. 调 write_layer_position 修改某层坐标后**重新解析**该 .moti，
     断言 XML 中的位置参数真的变了，且其它层不受影响。
  3. 对齐参考线：边对边、中心对中心、阈值内外行为、threshold=0 关闭。
  4. 原子写：目标层不存在时不落盘（原文件字节级不变、无 tmp 残留）；
     os.replace 失败时原文件不变（无半写文件）。

依赖：psd_tools / PIL（与 test_r21_t2_conflict.py 相同）。
"""
import glob
import hashlib
import os
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder
from core.moti_layer_io import list_layers, write_layer_position
from core.alignment_snap import (
    compute_alignment_guides,
    compute_snap_offset,
    snapped_rect,
    Guide,
)

COMPLEX_PSD = os.path.join(TESTS_DIR, "data", "complex_layers.psd")


# ──────────────────────────────────────────────
#  夹具：构建一个真实 .moti（与 GUI「保存模板」同一条代码路径）
# ──────────────────────────────────────────────
@pytest.fixture(scope="module")
def built_moti():
    # 自管临时目录（tempfile.mkdtemp）：本机 pytest tmp_path 走沙箱 shim 时
    # 二次运行会触发 EEXIST，改用 mkdtemp 保证 SA-4 任意次重跑都稳定。
    out_dir = tempfile.mkdtemp(prefix="d02_tpl_")
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    assert parsed["layers"], "complex_layers.psd 应解析出至少一个图层"
    mb = MotionBuilder()
    res = mb.build_template_atomic(
        parsed["layers"], out_dir, "d02case",
        psd_path=COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )
    assert res["status"] == "ok"
    moti = os.path.join(out_dir, "d02case.moti")
    assert os.path.isfile(moti) and os.path.getsize(moti) > 1024
    yield moti, parsed
    shutil.rmtree(out_dir, ignore_errors=True)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ──────────────────────────────────────────────
#  D-2 核心：拖拽坐标写回 .moti 后重新解析，位置真的变了
# ──────────────────────────────────────────────
def test_position_writeback_by_index(built_moti):
    moti, parsed = built_moti
    states_before = {s.index: s for s in list_layers(moti)}
    target_idx = 4  # Text 04
    assert states_before[target_idx].x != -500.25

    write_layer_position(moti, target_idx, -500.25, 300.75)

    states_after = {s.index: s for s in list_layers(moti)}
    assert states_after[target_idx].x == pytest.approx(-500.25)
    assert states_after[target_idx].y == pytest.approx(300.75)
    # 其它层不受影响
    for i, s in states_after.items():
        if i != target_idx:
            assert s.x == pytest.approx(states_before[i].x)
            assert s.y == pytest.approx(states_before[i].y)


def test_position_writeback_by_name(built_moti):
    moti, _ = built_moti
    name = "Text 04"
    write_layer_position(moti, name, 111.5, -222.5)
    st = {s.name: s for s in list_layers(moti)}[name]
    assert st.x == pytest.approx(111.5)
    assert st.y == pytest.approx(-222.5)


def test_position_writeback_by_id(built_moti):
    moti, _ = built_moti
    # build_moti 生成的 layer id 形如 3000<i>00
    lay_id = "3000500"
    write_layer_position(moti, lay_id, 12.0, 34.0)
    st = {s.id: s for s in list_layers(moti)}[lay_id]
    assert st.x == pytest.approx(12.0)
    assert st.y == pytest.approx(34.0)


def test_position_writeback_updates_real_xml_param_tree(built_moti):
    """不只信快照函数——直接读 Motion 原生参数树里的 value 属性。"""
    moti, _ = built_moti
    write_layer_position(moti, "Text 05", -77.5, 88.5)
    root = ET.parse(moti).getroot()
    layer = [l for l in root.find("scene").findall("layer")
             if l.get("name") == "Text 05"][0]
    # 位置参数树：属性(id=1) -> 变换(id=100) -> 位置(id=101) -> X/Y
    x_elem = layer.find(".//parameter[@id='101']/parameter[@id='1']")
    y_elem = layer.find(".//parameter[@id='101']/parameter[@id='2']")
    assert x_elem is not None and y_elem is not None
    assert float(x_elem.get("value")) == pytest.approx(-77.5)
    assert float(y_elem.get("value")) == pytest.approx(88.5)


def test_position_writeback_keeps_xml_structurally_valid(built_moti):
    """写回后 .moti 仍可被独立解析、根节点与 scene 完整。"""
    moti, _ = built_moti
    write_layer_position(moti, 1, 5.0, 6.0)
    tree = ET.parse(moti)  # 解析失败会抛异常
    root = tree.getroot()
    assert root.tag == "ozml"
    assert root.find("scene") is not None
    assert len(root.find("scene").findall("layer")) >= 5


# ──────────────────────────────────────────────
#  D-2 原子性：失败绝不产生半写文件
# ──────────────────────────────────────────────
def test_atomic_no_partial_file_when_layer_missing(built_moti):
    moti, _ = built_moti
    before_sha = _sha256(moti)
    with pytest.raises((IndexError, KeyError)):
        write_layer_position(moti, 999, 0.0, 0.0)
    assert _sha256(moti) == before_sha, "失败调用不得改动原文件"
    # 不得留下任何 tmp 残留
    assert glob.glob(moti + ".tmp*") == []
    # 原文件仍可完整解析
    assert ET.parse(moti).getroot().tag == "ozml"


def test_atomic_no_partial_file_when_replace_fails(built_moti, monkeypatch):
    """模拟 os.replace 在落盘最后一刻失败：原文件字节不变。"""
    moti, _ = built_moti
    before_sha = _sha256(moti)

    import core.moti_layer_io as mio

    def _boom(src, dst):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(mio.os, "replace", _boom)
    with pytest.raises(OSError):
        write_layer_position(moti, 2, 1.0, 2.0)
    monkeypatch.undo()

    assert _sha256(moti) == before_sha, "replace 失败时原文件不得被破坏"
    # 清掉可能遗留的 tmp（遗留的是完整临时文件，不是半写）
    for t in glob.glob(moti + ".tmp*"):
        os.remove(t)
    assert ET.parse(moti).getroot().tag == "ozml"


# ──────────────────────────────────────────────
#  D-2 对齐参考线：纯几何
# ──────────────────────────────────────────────
def test_guides_edge_to_edge_vertical():
    # 被拖拽矩形左边缘 (-40) 与目标矩形右边缘 (-41) 差 1 < 8 → 垂直参考线
    dragged = (-40.0, 0.0, 60.0, 100.0)
    others = [(-200.0, 0.0, -41.0, 100.0)]
    guides = compute_alignment_guides(dragged, others, threshold=8.0)
    v_lines = [g for g in guides if g.axis == "v"]
    assert any(g.pos == pytest.approx(-41.0) for g in v_lines)


def test_guides_center_to_center_horizontal():
    # 两矩形水平中心差 2 < 8 → 水平参考线
    dragged = (0.0, 10.0, 100.0, 60.0)      # cy = 35
    others = [(500.0, 13.0, 700.0, 59.0)]    # cy = 36
    guides = compute_alignment_guides(dragged, others, threshold=8.0)
    h_lines = [g for g in guides if g.axis == "h"]
    assert any(g.pos == pytest.approx(36.0) for g in h_lines)


def test_guides_beyond_threshold_empty():
    dragged = (0.0, 0.0, 100.0, 100.0)
    others = [(200.0, 300.0, 300.0, 400.0)]  # 所有边/中心距均 > 8
    assert compute_alignment_guides(dragged, others, threshold=8.0) == []


def test_guides_threshold_zero_disables():
    dragged = (0.0, 0.0, 100.0, 100.0)
    others = [(100.0, 0.0, 200.0, 100.0)]  # 完全贴边
    assert compute_alignment_guides(dragged, others, threshold=0.0) == []
    assert compute_snap_offset(dragged, others, threshold=0.0) == (0.0, 0.0)


def test_guides_no_others_empty():
    dragged = (0.0, 0.0, 100.0, 100.0)
    assert compute_alignment_guides(dragged, [], threshold=8.0) == []


def test_snap_offset_pulls_to_nearest_target():
    # 左边缘 4.0 → 目标右边缘 2.0：dx = -2（把矩形往左拉 2 单位）
    dragged = (4.0, 0.0, 104.0, 100.0)
    others = [(-96.0, 0.0, 2.0, 100.0)]
    dx, dy = compute_snap_offset(dragged, others, threshold=8.0)
    assert dx == pytest.approx(-2.0)
    assert dy == 0.0


def test_snap_offset_out_of_threshold_is_zero():
    dragged = (30.0, 0.0, 130.0, 100.0)
    others = [(-200.0, 0.0, -50.0, 100.0)]  # 最近差 80 > 8
    assert compute_snap_offset(dragged, others, threshold=8.0) == (0.0, 0.0)


def test_snapped_rect_translates_both_axes():
    dragged = (4.0, 14.0, 104.0, 64.0)
    others = [(-96.0, -86.0, 2.0, 12.0)]  # x 差 -2, y 差 -2
    s = snapped_rect(dragged, others, threshold=8.0)
    assert s[0] == pytest.approx(2.0)
    assert s[1] == pytest.approx(12.0)
    assert s[2] == pytest.approx(102.0)
    assert s[3] == pytest.approx(62.0)


def test_guide_as_line_format():
    g = Guide(axis="v", pos=10.0, start=-5.0, end=5.0)
    assert g.as_line() == (10.0, -5.0, 10.0, 5.0)
    h = Guide(axis="h", pos=3.0, start=0.0, end=9.0)
    assert h.as_line() == (0.0, 3.0, 9.0, 3.0)


# ──────────────────────────────────────────────
#  D-2 GUI 接线静态断言（不 import PyQt6，仅检查源码文本）
# ──────────────────────────────────────────────
def test_canvas_wires_writeback_and_moti_path():
    """canvas_view.py 必须存在 moti 路径下发 + 写回调用 + 对齐参考线接线。"""
    src = open(
        os.path.join(PROJECT_ROOT, "gui", "canvas_view.py"), encoding="utf-8"
    ).read()
    assert "set_moti_path" in src
    assert "write_layer_position" in src
    assert "compute_alignment_guides" in src
    assert "on_committed_callback" in src


def test_main_window_publishes_moti_path():
    src = open(
        os.path.join(PROJECT_ROOT, "gui", "main_window.py"), encoding="utf-8"
    ).read()
    assert "self.canvas_view.set_moti_path(" in src
    assert "self.inspector.set_moti_path(" in src
