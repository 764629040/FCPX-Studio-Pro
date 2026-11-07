"""core/moti_layer_io.py — 纯函数 .moti 图层参数读写（无 PyQt6 依赖）

本模块是「画布拖拽写回坐标」(D-2) 与「图层隐藏/锁定持久化」(D-3) 的唯一真相源。
它只依赖标准库 ``xml.etree.ElementTree``，因此可以在没有 PyQt6、没有 GUI 运行
环境的情况下被单元测试直接驱动——这正是独立复核员 (SA-4) 验证「拖拽/锁定后 .moti
参数真的变了」的机制。

图层身份 ``layer_ref`` 支持三种解析方式：
  * int  ->  <scene><layer> 下的 1-based 序号（与 GUI 中 info.index 对应）
  * str  ->  匹配 <layer> 的 ``id`` 属性或 ``name`` 属性

位置 (position) 在 Motion .moti 中的真实路径为：
  layer/scenenode/parameter[@name='属性' id='1']
            /parameter[@name='变换' id='100']
            /parameter[@name='位置' id='101']
            /parameter[@name='X' id='1']  (value 属性)
            /parameter[@name='Y' id='2']  (value 属性)

可见性 (enabled) 同时写入：
  * <layer enabled='true|false'>  —— 供复核直接读取的显式属性
  * <layer><flags>/<baseFlags>     —— 镜像 Motion 原生隐藏位
    (隐藏="8589938688"，显示: flags="0" / baseFlags="524304"，
     与 core/motion_builder.build_moti 的行为保持一致)

锁定 (locked) 写入：
  * <layer locked='true|false'>    —— Motion 无原生锁定概念，以属性表达，
                                      画布据此禁止拖拽。
"""

from __future__ import annotations

import os
import shutil
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Dict, List, Optional, Union

# ── Motion 原生可见性位（与 core/motion_builder.build_moti 对齐） ──
LAYER_HIDDEN_FLAGS = "8589938688"
LAYER_VISIBLE_FLAGS = "0"
LAYER_VISIBLE_BASEFLAGS = "524304"


@dataclass
class LayerState:
    """单个图层在 .moti 中的可读状态快照。"""

    index: int
    id: str
    name: str
    x: float
    y: float
    enabled: bool
    locked: bool

    def is_draggable(self) -> bool:
        """锁定的图层不可拖拽；隐藏的图层也视为不可拖拽。"""
        return self.enabled and not self.locked


# ──────────────────────────────────────────────────────────────
#  内部工具
# ──────────────────────────────────────────────────────────────
def _parse_float(text, default: float = 0.0) -> float:
    try:
        return float(text)
    except (TypeError, ValueError):
        return default


def _find_first(elem: ET.Element, *xpath_preds: str):
    """按顺序尝试多个 find 谓词，返回第一个非 None 的元素。

    不用 `a or b`：Element 的真值取决于子元素个数，会触发 DeprecationWarning
    且语义错误（childless 元素会被当成 False）。
    """
    for pred in xpath_preds:
        found = elem.find(pred)
        if found is not None:
            return found
    return None


def _layer_position_elems(layer_elem: ET.Element):
    """返回某 <layer> 的 (X 参数元素, Y 参数元素)，找不到返回 (None, None)。"""
    sn = layer_elem.find("scenenode")
    if sn is None:
        return None, None
    # 属性 (id=1) -> 变换 (id=100) -> 位置 (id=101) -> X(id=1) / Y(id=2)
    attr = _find_first(sn, "parameter[@name='属性']", "parameter[@id='1']")
    if attr is None:
        return None, None
    trans = _find_first(attr, "parameter[@name='变换']", "parameter[@id='100']")
    if trans is None:
        return None, None
    pos = _find_first(trans, "parameter[@name='位置']", "parameter[@id='101']")
    if pos is None:
        return None, None
    x = _find_first(pos, "parameter[@name='X']", "parameter[@id='1']")
    y = _find_first(pos, "parameter[@name='Y']", "parameter[@id='2']")
    return x, y


def _resolve_layer(root: ET.Element, layer_ref: Union[int, str]) -> ET.Element:
    scene = root.find("scene")
    if scene is None:
        raise ValueError("malformed .moti: missing <scene>")
    layers = scene.findall("layer")
    if not layers:
        raise ValueError("malformed .moti: no <layer> elements under <scene>")
    if isinstance(layer_ref, int):
        if not (1 <= layer_ref <= len(layers)):
            raise IndexError(
                f"layer index {layer_ref} out of range (1..{len(layers)})"
            )
        return layers[layer_ref - 1]
    ref = str(layer_ref)
    for lay in layers:
        if lay.get("id") == ref or lay.get("name") == ref:
            return lay
    raise KeyError(f"no <layer> with id or name == {ref!r}")


def _write_tree(tree: ET.ElementTree, moti_path: str) -> None:
    xml_decl = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE ozxmlscene>\n'
    raw = ET.tostring(tree.getroot(), encoding="utf-8").decode("utf-8")
    tmp = f"{moti_path}.tmp_moti_io_{os.getpid()}_{int(time.time() * 1000)}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(xml_decl + raw)
    os.replace(tmp, moti_path)


def _maybe_backup(moti_path: str, backup: bool) -> None:
    if backup:
        shutil.copy2(moti_path, moti_path + ".bak")


# ──────────────────────────────────────────────────────────────
#  公开 API
# ──────────────────────────────────────────────────────────────
def list_layers(moti_path: str) -> List[LayerState]:
    """解析 .moti，返回所有图层的当前状态快照（只读）。"""
    tree = ET.parse(moti_path)
    root = tree.getroot()
    scene = root.find("scene")
    layers = scene.findall("layer") if scene is not None else []
    out: List[LayerState] = []
    for i, lay in enumerate(layers, start=1):
        x_elem, y_elem = _layer_position_elems(lay)
        x = _parse_float(x_elem.get("value")) if x_elem is not None else 0.0
        y = _parse_float(y_elem.get("value")) if y_elem is not None else 0.0
        flags = lay.findtext("flags")
        enabled = flags != LAYER_HIDDEN_FLAGS
        locked = (lay.get("locked", "false").lower() == "true")
        out.append(
            LayerState(
                index=i,
                id=lay.get("id", ""),
                name=lay.get("name", ""),
                x=x,
                y=y,
                enabled=enabled,
                locked=locked,
            )
        )
    return out


def write_layer_position(
    moti_path: str,
    layer_ref: Union[int, str],
    x: float,
    y: float,
    *,
    backup: bool = True,
) -> Dict[str, object]:
    """把 (x, y) 写入图层 Motion 位置参数并落盘。返回变更摘要。"""
    _maybe_backup(moti_path, backup)
    tree = ET.parse(moti_path)
    lay = _resolve_layer(tree.getroot(), layer_ref)
    x_elem, y_elem = _layer_position_elems(lay)
    if x_elem is None or y_elem is None:
        raise ValueError(f"layer {layer_ref!r} has no position parameter tree")
    x_elem.set("value", f"{float(x):.2f}")
    y_elem.set("value", f"{float(y):.2f}")
    _write_tree(tree, moti_path)
    return {"layer_ref": layer_ref, "x": float(x), "y": float(y)}


def set_layer_enabled(
    moti_path: str,
    layer_ref: Union[int, str],
    enabled: bool,
    *,
    backup: bool = True,
) -> Dict[str, object]:
    """设置图层可见性，持久化到 enabled 属性 + Motion 原生 flags 位。"""
    _maybe_backup(moti_path, backup)
    tree = ET.parse(moti_path)
    lay = _resolve_layer(tree.getroot(), layer_ref)
    if enabled:
        flags = lay.find("flags")
        if flags is not None:
            flags.text = LAYER_VISIBLE_FLAGS
        base = lay.find("baseFlags")
        if base is not None:
            base.text = LAYER_VISIBLE_BASEFLAGS
    else:
        for tag in ("flags", "baseFlags"):
            node = lay.find(tag)
            if node is not None:
                node.text = LAYER_HIDDEN_FLAGS
    lay.set("enabled", "true" if enabled else "false")
    _write_tree(tree, moti_path)
    return {"layer_ref": layer_ref, "enabled": bool(enabled)}


def set_layer_locked(
    moti_path: str,
    layer_ref: Union[int, str],
    locked: bool,
    *,
    backup: bool = True,
) -> Dict[str, object]:
    """设置图层锁定状态，持久化到 locked 属性。"""
    _maybe_backup(moti_path, backup)
    tree = ET.parse(moti_path)
    lay = _resolve_layer(tree.getroot(), layer_ref)
    lay.set("locked", "true" if locked else "false")
    _write_tree(tree, moti_path)
    return {"layer_ref": layer_ref, "locked": bool(locked)}
