"""
R25-D3 图层隐藏/锁定持久化到 .moti 单测（纯逻辑，无 PyQt6）
==============================================================

被测对象：core/moti_layer_io.py 的 set_layer_enabled / set_layer_locked。

验证策略（SA-4 可独立重跑）：
  1. 与 D-2 相同：用真实 build_template_atomic 构造 .moti。
  2. set_layer_enabled(False) 后重新解析，断言：
     - <layer enabled="false">
     - Motion 原生 flags 位 = 8589938688（隐藏）
     - list_layers 快照 enabled=False
  3. set_layer_enabled(True) 恢复：flags="0"、baseFlags="524304"、enabled=True。
  4. set_layer_locked(True/False)：locked 属性持久化，is_draggable() 语义正确。
  5. 状态切换往返（隐藏→显示→隐藏）幂等不破坏结构。
  6. 失败路径（层不存在）不落盘。
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
from core.moti_layer_io import (
    LAYER_HIDDEN_FLAGS,
    LAYER_VISIBLE_FLAGS,
    LAYER_VISIBLE_BASEFLAGS,
    list_layers,
    set_layer_enabled,
    set_layer_locked,
)

COMPLEX_PSD = os.path.join(TESTS_DIR, "data", "complex_layers.psd")


@pytest.fixture(scope="module")
def built_moti():
    # 自管临时目录（tempfile.mkdtemp）：本机 pytest tmp_path 走沙箱 shim 时
    # 二次运行会触发 EEXIST，改用 mkdtemp 保证 SA-4 任意次重跑都稳定。
    out_dir = tempfile.mkdtemp(prefix="d03_tpl_")
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    res = mb.build_template_atomic(
        parsed["layers"], out_dir, "d03case",
        psd_path=COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )
    assert res["status"] == "ok"
    moti = os.path.join(out_dir, "d03case.moti")
    assert os.path.isfile(moti)
    yield moti
    shutil.rmtree(out_dir, ignore_errors=True)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _layer_elem(moti, name):
    root = ET.parse(moti).getroot()
    for lay in root.find("scene").findall("layer"):
        if lay.get("name") == name:
            return lay
    raise KeyError(name)


# ──────────────────────────────────────────────
#  D-3 可见性持久化
# ──────────────────────────────────────────────
def test_hide_layer_persists_enabled_false_and_flags(built_moti):
    moti = built_moti
    set_layer_enabled(moti, "Text 04", False)

    # 快照视角
    st = {s.name: s for s in list_layers(moti)}["Text 04"]
    assert st.enabled is False

    # 原生 XML 视角（Motion 隐藏位）
    lay = _layer_elem(moti, "Text 04")
    assert lay.get("enabled") == "false"
    assert lay.findtext("flags") == LAYER_HIDDEN_FLAGS
    assert lay.findtext("baseFlags") == LAYER_HIDDEN_FLAGS


def test_show_layer_restores_visible_flags(built_moti):
    moti = built_moti
    set_layer_enabled(moti, "Text 04", True)

    st = {s.name: s for s in list_layers(moti)}["Text 04"]
    assert st.enabled is True

    lay = _layer_elem(moti, "Text 04")
    assert lay.get("enabled") == "true"
    assert lay.findtext("flags") == LAYER_VISIBLE_FLAGS
    assert lay.findtext("baseFlags") == LAYER_VISIBLE_BASEFLAGS


def test_hide_by_index_matches_gui_layer_index(built_moti):
    """GUI 用 info.index（1-based）定位图层——必须与 .moti 层序一致。"""
    moti = built_moti
    set_layer_enabled(moti, 2, False)
    states = list_layers(moti)
    assert states[1].enabled is False          # index=2 隐藏
    assert states[0].enabled is True           # 其它层不受影响
    assert states[2].enabled is True
    # 恢复
    set_layer_enabled(moti, 2, True)
    assert list_layers(moti)[1].enabled is True


def test_visibility_roundtrip_keeps_structure_valid(built_moti):
    moti = built_moti
    for _ in range(2):
        set_layer_enabled(moti, 5, False)
        set_layer_enabled(moti, 5, True)
    root = ET.parse(moti).getroot()
    assert root.tag == "ozml"
    assert len(root.find("scene").findall("layer")) >= 5


# ──────────────────────────────────────────────
#  D-3 锁定持久化
# ──────────────────────────────────────────────
def test_lock_layer_persists_locked_true(built_moti):
    moti = built_moti
    set_layer_locked(moti, "Media 03 (Image02)", True)
    st = {s.name: s for s in list_layers(moti)}["Media 03 (Image02)"]
    assert st.locked is True
    lay = _layer_elem(moti, "Media 03 (Image02)")
    assert lay.get("locked") == "true"


def test_unlock_layer_persists_locked_false(built_moti):
    moti = built_moti
    set_layer_locked(moti, "Media 03 (Image02)", False)
    st = {s.name: s for s in list_layers(moti)}["Media 03 (Image02)"]
    assert st.locked is False
    lay = _layer_elem(moti, "Media 03 (Image02)")
    assert lay.get("locked") == "false"


def test_locked_layer_is_not_draggable(built_moti):
    """语义：锁定层不可拖拽；隐藏层也不可拖拽。"""
    moti = built_moti
    set_layer_locked(moti, 1, True)
    set_layer_enabled(moti, 1, False)
    st = list_layers(moti)[0]
    assert st.is_draggable() is False
    # 只锁定、不隐藏 → 仍不可拖
    set_layer_enabled(moti, 1, True)
    st = list_layers(moti)[0]
    assert st.locked is True and st.enabled is True
    assert st.is_draggable() is False
    # 解锁 → 可拖
    set_layer_locked(moti, 1, False)
    assert list_layers(moti)[0].is_draggable() is True


def test_lock_does_not_touch_position(built_moti):
    moti = built_moti
    before = {s.index: (s.x, s.y) for s in list_layers(moti)}
    set_layer_locked(moti, 3, True)
    after = {s.index: (s.x, s.y) for s in list_layers(moti)}
    assert before == after, "锁定写回不得改动坐标"


# ──────────────────────────────────────────────
#  失败路径
# ──────────────────────────────────────────────
def test_bad_layer_ref_leaves_file_untouched(built_moti):
    moti = built_moti
    before_sha = _sha256(moti)
    with pytest.raises(KeyError):
        set_layer_locked(moti, "不存在的图层名", True)
    with pytest.raises(IndexError):
        set_layer_enabled(moti, 999, False)
    assert _sha256(moti) == before_sha
    assert glob.glob(moti + ".tmp*") == []
    assert ET.parse(moti).getroot().tag == "ozml"


def test_malformed_moti_raises_clearly():
    """缺 <scene> 的坏文件必须显式报错，而不是静默成功。"""
    bad_dir = tempfile.mkdtemp(prefix="d03_bad_")
    bad = os.path.join(bad_dir, "bad.moti")
    try:
        with open(bad, "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<!DOCTYPE ozxmlscene>\n<ozml></ozml>')
        with pytest.raises(ValueError):
            set_layer_locked(bad, 1, True)
        with pytest.raises(ValueError):
            set_layer_enabled(bad, 1, False)
        with pytest.raises(ValueError):
            write_position_on_bad(bad)
    finally:
        shutil.rmtree(bad_dir, ignore_errors=True)


def write_position_on_bad(path):
    from core.moti_layer_io import write_layer_position
    return write_layer_position(path, 1, 0.0, 0.0)


# ──────────────────────────────────────────────
#  D-3 GUI 接线静态断言（不 import PyQt6）
# ──────────────────────────────────────────────
def test_inspector_wires_enabled_and_locked_writeback():
    src = open(
        os.path.join(PROJECT_ROOT, "gui", "inspector_panel.py"), encoding="utf-8"
    ).read()
    assert "set_layer_enabled" in src
    assert "set_layer_locked" in src
    assert "set_moti_path" in src


def test_canvas_blocks_drag_when_locked():
    src = open(
        os.path.join(PROJECT_ROOT, "gui", "canvas_view.py"), encoding="utf-8"
    ).read()
    assert "locked" in src
    # 锁定层禁止进入拖拽流程（mousePressEvent 中按 locked 摘除 Movable 标志）
    assert "ItemIsMovable" in src
