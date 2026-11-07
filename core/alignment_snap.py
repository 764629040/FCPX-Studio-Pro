"""core/alignment_snap.py — 画布对齐参考线 + 吸附的纯函数（无 PyQt6 依赖）

D-2 要求：拖拽图层时显示对齐参考线。这里把「计算参考线」与「计算吸附偏移」
抽成纯函数，输入/输出都是普通的坐标元组，方便在单元测试中验证，
而不需要启动 PyQt6 / 真实画布。

坐标约定：矩形统一表示为 (x0, y0, x1, y1) 的 scene 坐标元组。
（注意 QRectF.getRect() 返回的是 (x, y, w, h)，调用方需先归一化为 x1=x+w, y1=y+h。）
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Tuple

Rect = Tuple[float, float, float, float]

# 垂直参考线 (axis="v", pos=x) 或 水平参考线 (axis="h", pos=y)
# start/end 为参考线在另一轴上的起止坐标（scene 坐标）。
GUIDE_V = "v"
GUIDE_H = "h"


@dataclass
class Guide:
    axis: str  # "v" 或 "h"
    pos: float  # 垂直线为 x，水平线为 y
    start: float
    end: float

    def as_line(self) -> Tuple[float, float, float, float]:
        if self.axis == GUIDE_V:
            return (self.pos, self.start, self.pos, self.end)
        return (self.start, self.pos, self.end, self.pos)


def _edges(r: Rect) -> dict:
    x0, y0, x1, y1 = r
    return {
        "left": min(x0, x1),
        "right": max(x0, x1),
        "cx": (x0 + x1) / 2.0,
        "top": min(y0, y1),
        "bottom": max(y0, y1),
        "cy": (y0 + y1) / 2.0,
    }


# (被拖拽边, 目标边) 的所有组合
_VERTICAL_PAIRS = [
    ("left", "left"), ("left", "cx"), ("left", "right"),
    ("cx", "left"), ("cx", "cx"), ("cx", "right"),
    ("right", "left"), ("right", "cx"), ("right", "right"),
]
_HORIZONTAL_PAIRS = [
    ("top", "top"), ("top", "cy"), ("top", "bottom"),
    ("cy", "top"), ("cy", "cy"), ("cy", "bottom"),
    ("bottom", "top"), ("bottom", "cy"), ("bottom", "bottom"),
]


def compute_alignment_guides(
    dragged: Rect, others: List[Rect], threshold: float = 8.0
) -> List[Guide]:
    """根据被拖拽矩形与「其它矩形」的边/中心距离，返回需要对齐的参考线列表。

    threshold <= 0 时返回空列表（关闭吸附/参考线）。
    """
    guides: List[Guide] = []
    if threshold <= 0 or not others:
        return guides
    d = _edges(dragged)
    for o in others:
        e = _edges(o)
        for dk, ok in _VERTICAL_PAIRS:
            if abs(d[dk] - e[ok]) <= threshold:
                x = e[ok]
                guides.append(
                    Guide(GUIDE_V, x, min(d["top"], e["top"]), max(d["bottom"], e["bottom"]))
                )
        for dk, ok in _HORIZONTAL_PAIRS:
            if abs(d[dk] - e[ok]) <= threshold:
                y = e[ok]
                guides.append(
                    Guide(GUIDE_H, y, min(d["left"], e["left"]), max(d["right"], e["right"]))
                )
    return guides


def compute_snap_offset(
    dragged: Rect, others: List[Rect], threshold: float = 8.0
) -> Tuple[float, float]:
    """返回 (dx, dy)，把被拖拽矩形的边/中心吸附到最近的参考目标。

    若没有在阈值内的目标，则对应轴偏移为 0。
    """
    dx, dy = 0.0, 0.0
    best_x = threshold + 1.0
    best_y = threshold + 1.0
    d = _edges(dragged)
    for o in others:
        e = _edges(o)
        for dk, ok in _VERTICAL_PAIRS:
            diff = e[ok] - d[dk]
            if abs(diff) <= best_x:
                best_x = abs(diff)
                dx = diff
        for dk, ok in _HORIZONTAL_PAIRS:
            diff = e[ok] - d[dk]
            if abs(diff) <= best_y:
                best_y = abs(diff)
                dy = diff
    if best_x > threshold:
        dx = 0.0
    if best_y > threshold:
        dy = 0.0
    return dx, dy


def snapped_rect(
    dragged: Rect, others: List[Rect], threshold: float = 8.0
) -> Rect:
    """返回吸附后的矩形 (x0', y0', x1', y1')。"""
    dx, dy = compute_snap_offset(dragged, others, threshold)
    x0, y0, x1, y1 = dragged
    return (x0 + dx, y0 + dy, x1 + dx, y1 + dy)
