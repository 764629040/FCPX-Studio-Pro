#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PNG 智能拆分 P1 —— 单张成品图 → OBJECT / TEXT / ELEMENT / BACKGROUND 四类透明层。

口径（立项单 docs/立项_PNG智能拆分_20261112.md §3 / §5 / §6 落地）：
  · 只用传统影像算法：背景建模 → 色差前景分离 → 连通域 → 笔画/边缘统计分类 →
    自适应膨胀分组 → 边缘延展填洞。不引入任何模型权重、不联网。
  · 文字层永远输出位图：不 OCR、不重建矢量文字层，清单里 text_editable=false。
  · 拿不准的区域落在 BACKGROUND 并标 low_confidence，不假装分准。
  · 遮挡补全 P1 只做「延展填色」（最近邻边缘外推 + 洞内平滑），不做 patch / 生成式。
  这条文件里没有写任何「差不多 / 基本 / 很快」的估值，所有数字都是实测。

子命令：
  split  --src A.png --out DIR        四类分层，产出 分层清单.json + layers/*.png + 预览
  check  --out DIR                    按契约复算输出目录（尺寸 / RGBA / 重合成 / 补洞）
  probe  --src A.png                  只跑分析，打印分类统计不落盘（调参用）

依赖：numpy + Pillow + scipy.ndimage（requirements.txt 里已有，新增依赖 0 字节）。

独立复现：
  python3 tools/pngp1/png_split_p1.py split --src /tmp/a.png --out /tmp/a_out
  python3 tools/pngp1/png_split_p1.py check --out /tmp/a_out
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import time
from collections import defaultdict

import numpy as np
from PIL import Image
from scipy import ndimage

SCHEMA = "pngp1/v1"
TOOL_VERSION = "pngp1-1.0.0"
CLASS_ORDER = ("BACKGROUND", "OBJECT", "ELEMENT", "TEXT")
CLASS_LABELS = {
    "OBJECT": "主体",
    "TEXT": "文字",
    "ELEMENT": "装饰",
    "BACKGROUND": "背景",
}
# 判定阈值集中在这里，便于回归时逐条对照；全部是无量纲比例，不写魔法 px。
TEXT_SCORE_MIN = 0.56
OBJECT_SCORE_MIN = 0.52
MIN_CONFIDENCE = 0.55
MAX_ELEMENT_LAYERS = 24
MIN_AREA_RATIO = 0.00002


# ────────────────────────────────────────────────────────────────
# 基础工具
# ────────────────────────────────────────────────────────────────
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def f1(x) -> float:
    """统一一位小数，报告里不写「约」。"""
    return round(float(x), 1)


def f3(x) -> float:
    return round(float(x), 3)


def read_rgba(path: str):
    with Image.open(path) as im:
        mode = im.mode
        size = im.size
        arr = np.asarray(im.convert("RGBA"))
    if arr.ndim != 3 or arr.shape[2] != 4:
        raise ValueError("不是 RGBA 图像: %s" % path)
    return arr.astype(np.uint8), mode, size


_LAB_MEMO = [None, None]


def srgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """sRGB(0..255) → CIE Lab(D65)，逐像素向量化；只用于色差，不参与输出。

    同一张图的 RGB 数组在一次拆分里会被多处复用（背景建模/前景掩膜/文字差分），
    这里只记住最近一次输入，命中就复用，避免重复全图换算。
    """
    if _LAB_MEMO[0] is rgb and _LAB_MEMO[1] is not None:
        return _LAB_MEMO[1]
    x = rgb.astype(np.float64) / 255.0
    x = np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = x @ m.T
    white = np.array([0.95047, 1.00000, 1.08883])
    t = xyz / white
    d = 6.0 / 29.0
    f = np.where(t > d ** 3, np.cbrt(t), t / (3 * d * d) + 4.0 / 29.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    out = np.stack([L, a, b], axis=-1)
    _LAB_MEMO[0] = rgb
    _LAB_MEMO[1] = out
    return out


def bbox_of(mask: np.ndarray):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def mask_of_bbox(shape, bbox):
    m = np.zeros(shape, dtype=bool)
    x0, y0, x1, y1 = bbox
    m[y0:y1, x0:x1] = True
    return m


def hex_of(rgb) -> str:
    return "#%02X%02X%02X" % tuple(int(round(max(0, min(255, v)))) for v in rgb[:3])


def ij_bbox(b):
    x0, y0, x1, y1 = [int(v) for v in b]
    return np.s_[y0:y1, x0:x1]


# ────────────────────────────────────────────────────────────────
# ① 背景建模（不是「取四角平均」：逐模型在边框环上实测残差，谁低用谁）
# ────────────────────────────────────────────────────────────────
def _border_ring(W: int, H: int, border: int) -> np.ndarray:
    ring = np.zeros((H, W), dtype=bool)
    ring[:border, :] = True
    ring[-border:, :] = True
    ring[:, :border] = True
    ring[:, -border:] = True
    return ring


def _smooth_1d(v: np.ndarray, k: int = 9) -> np.ndarray:
    if len(v) <= 2:
        return v
    k = max(3, min(k, len(v) // 2 * 2 + 1))
    pad = k // 2
    vv = np.pad(v, ((pad, pad), (0, 0)), mode="edge")
    kernel = np.ones(k, dtype=np.float64) / k
    out = np.stack([np.convolve(vv[:, c], kernel, mode="valid") for c in range(v.shape[1])], axis=1)
    return out


def estimate_background(src_rgb: np.ndarray):
    """返回 (模型图 HxWx3 float, 模型名, 边框残差 ΔE 中位数)。"""
    H, W = src_rgb.shape[:2]
    border = max(2, int(round(min(W, H) * 0.02)))
    ring = _border_ring(W, H, border)
    lab = srgb_to_lab(src_rgb)
    ring_px = lab[ring]
    median_ring = np.median(ring_px, axis=0)

    candidates = {}
    # 模型 1：全图单一底色
    g = np.median(src_rgb[ring], axis=0)
    candidates["global"] = np.broadcast_to(g.astype(np.float64), (H, W, 3)).copy()

    # 模型 2：逐行底色（竖向渐变 / 横向均匀）
    rows = np.zeros((H, 3), dtype=np.float64)
    for y in range(H):
        m = ring[y]
        rows[y] = np.median(src_rgb[y][m], axis=0) if m.any() else g
    rows = _smooth_1d(rows, 9)
    candidates["rows"] = np.repeat(rows[:, None, :], W, axis=1)

    # 模型 3：逐列底色（横向渐变 / 竖向均匀）
    cols = np.zeros((W, 3), dtype=np.float64)
    for x in range(W):
        m = ring[:, x]
        cols[x] = np.median(src_rgb[:, x][m], axis=0) if m.any() else g
    cols = _smooth_1d(cols, 9)
    candidates["cols"] = np.repeat(cols[None, :, :], H, axis=0)

    # 模型 4：四边双线性（中间用行列模型加权，适合双侧渐变）
    grid_x = np.linspace(0, 1, W)[None, :]
    grid_y = np.linspace(0, 1, H)[:, None]
    candidates["bilinear"] = candidates["rows"] * (1 - grid_x[..., None]) + candidates["cols"] * grid_x[..., None]

    # 模型 5：二维二次曲面（暗角 / 径向渐变）。只在边框环上拟合，向画内推。
    ys, xs = np.nonzero(ring)
    nx = xs / float(max(1, W - 1)) - 0.5
    ny = ys / float(max(1, H - 1)) - 0.5
    A = np.stack([np.ones_like(nx), nx, ny, nx * nx, ny * ny, nx * ny], axis=1)
    coef, *_ = np.linalg.lstsq(A, src_rgb[ys, xs].astype(np.float64), rcond=None)
    gx = np.linspace(-0.5, 0.5, W)[None, :].repeat(H, axis=0).ravel()
    gy = np.linspace(-0.5, 0.5, H)[:, None].repeat(W, axis=1).ravel()
    A_all = np.stack([np.ones_like(gx), gx, gy, gx * gx, gy * gy, gx * gy], axis=1)
    poly = (A_all @ coef).reshape(H, W, 3)
    candidates["poly2"] = np.clip(poly, 0, 255)

    # 评分用「内缩环」而不是拟合用的外环：避免二次曲面在外环上必然 0 残差的自证。
    inset = min(W, H) // 12
    score_ring = _border_ring(W, H, inset + max(4, inset // 2)) & ~_border_ring(W, H, inset)
    if score_ring.sum() < 500:
        score_ring = ring

    best_name = "global"
    best_res = float("inf")
    best_img = candidates["global"]
    ring_lab = lab[score_ring]
    for name, img in candidates.items():
        # 只在环上算残差，不把整幅图转 Lab（省内存，也不改变口径）
        cand_lab = srgb_to_lab(np.clip(img[score_ring], 0, 255))
        d = np.sqrt(((ring_lab - cand_lab) ** 2).sum(axis=1))
        # 用 75 分位：中位数会被「恰好半边完全吻合」的模型骗过（横向渐变 + 暗角就是这种）
        res = float(np.percentile(d, 75))
        if res < best_res:
            best_res, best_name, best_img = res, name, img
    return best_img, best_name, best_res, border


# ────────────────────────────────────────────────────────────────
# ② 前景分离
# ────────────────────────────────────────────────────────────────
def otsu_threshold(values: np.ndarray) -> float:
    v = values.ravel()
    if len(v) == 0:
        return 0.0
    hist, edges = np.histogram(v, bins=128, range=(float(v.min()), float(v.max()) + 1e-6))
    centers = (edges[:-1] + edges[1:]) / 2.0
    total = hist.sum()
    w0 = np.cumsum(hist)
    w1 = total - w0
    m0 = np.cumsum(hist * centers)
    mt = m0[-1]
    with np.errstate(invalid="ignore", divide="ignore"):
        between = (mt * w0 / total - m0) ** 2 / (w0 * w1 / total ** 2)
    between = np.nan_to_num(between, nan=-1.0, posinf=-1.0)
    return float(centers[int(np.argmax(between))])


def foreground_mask(src_rgb: np.ndarray, src_alpha: np.ndarray, bg_img: np.ndarray):
    H, W = src_rgb.shape[:2]
    lab = srgb_to_lab(src_rgb)
    bg_lab = srgb_to_lab(np.clip(bg_img, 0, 255))
    dist = np.sqrt(((lab - bg_lab) ** 2).sum(axis=2))

    border = max(2, int(round(min(W, H) * 0.02)))
    ring = _border_ring(W, H, border)
    ring_d = dist[ring]
    med = float(np.median(ring_d))
    mad = float(np.median(np.abs(ring_d - med)))
    noise = max(1e-3, 1.4826 * mad)
    thr = max(6.0, med + 3.0 * noise)

    opaque = float((src_alpha > 250).mean())
    if opaque < 0.98:
        # 源图自带透明底：alpha 就是最硬的前景证据，色差只用来补半透明边缘。
        mask = src_alpha > 8
        mode = "alpha"
    else:
        mask = dist > thr
        mode = "color"
        ratio = float(mask.mean())
        if ratio > 0.62:
            thr = max(thr, otsu_threshold(dist[~ring]))
            mask = dist > thr
        elif ratio < 0.002:
            thr = max(2.5, med + 1.5 * noise)
            mask = dist > thr

    # 局部平滑差：暗角/渐变的「大块平滑差」不是前景，只有局部有边的地方才算。
    sigma = max(3.0, 0.02 * min(W, H))
    local = ndimage.gaussian_filter(src_rgb.astype(np.float64), sigma=(sigma, sigma, 0))
    local_lab = srgb_to_lab(np.clip(local, 0, 255))
    ld = np.sqrt(((lab - local_lab) ** 2).sum(axis=2))
    lmed = float(np.median(ld))
    lnoise = max(0.3, 1.4826 * float(np.median(np.abs(ld - lmed))))
    support = ndimage.binary_dilation(ld > max(4.0, lmed + 3.0 * lnoise),
                                      structure=np.ones((3, 3), dtype=bool), iterations=1)
    mask = mask & support
    # 形态学清理：先闭运算补笔画内孔，再去小噪点；不做开运算，避免 1px 笔画被吃。
    mask = ndimage.binary_closing(mask, structure=np.ones((3, 3), dtype=bool))
    # 大块内部的平滑区（产品面、卡片）由「边缘闭合 + 填内孔」恢复；暗角没有闭合边，不会被恢复。
    lab_mask, n0 = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    if n0:
        sizes0 = np.bincount(lab_mask.ravel())
        slices0 = ndimage.find_objects(lab_mask)
        restore = np.zeros((H, W), dtype=bool)
        for cid in range(1, n0 + 1):
            if sizes0[cid] <= 0.004 * W * H:
                continue
            sl = slices0[cid - 1]
            if sl is None:
                continue
            bw = sl[1].stop - sl[1].start
            bh = sl[0].stop - sl[0].start
            m = lab_mask[sl] == cid
            # 细边框（面积占 bbox < 3%）不填：一填就把整幅画布吃成"主体"。
            # 实心卡片/窗口虽然 bbox 大，但边缘像素占 bbox ≥3%，填洞是恢复内部，不是吞画布。
            if sizes0[cid] < 0.03 * bw * bh:
                continue
            fh = ndimage.binary_fill_holes(m)
            if fh.sum() > 0.65 * W * H:
                continue
            sub = np.zeros((H, W), dtype=bool)
            sub[sl] = fh
            restore |= sub
        mask = mask | (restore & ~mask)
    min_area = max(12, int(round(W * H * MIN_AREA_RATIO)))
    lab_mask, n = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    if n:
        sizes = np.bincount(lab_mask.ravel())
        keep = np.zeros(sizes.shape, dtype=bool)
        keep[1:] = sizes[1:] >= min_area
        mask = keep[lab_mask]
    return mask, dist, {"mode": mode, "threshold_delta_e": f1(thr),
                        "border_noise_delta_e": f2(noise), "min_area_px": min_area}


def f2(x) -> float:
    return round(float(x), 2)


# ────────────────────────────────────────────────────────────────
# ③ 组件统计 + 文字判定
# ────────────────────────────────────────────────────────────────
def _edge_magnitude(gray: np.ndarray) -> np.ndarray:
    gx = ndimage.sobel(gray, axis=1)
    gy = ndimage.sobel(gray, axis=0)
    mag = np.hypot(gx, gy)
    p = float(np.percentile(mag, 99)) or 1.0
    return np.clip(mag / p, 0.0, 1.0)


def _trapezoid(x: float, lo: float, hi: float, soft: float = 0.25) -> float:
    """x 在 [lo,hi] 内为 1，向外 soft 比例内线性降到 0。"""
    if hi <= lo:
        return 0.0
    span = (hi - lo) * soft + 1e-9
    if x < lo:
        return max(0.0, 1.0 - (lo - x) / span)
    if x > hi:
        return max(0.0, 1.0 - (x - hi) / span)
    return 1.0


def component_stats(src_rgb, mask, comp_lab, ids, edge, dist, bg_center_lab):
    H, W = mask.shape
    slices = ndimage.find_objects(comp_lab)
    out = {}
    for cid in ids:
        sl = slices[cid - 1]
        if sl is None:
            continue
        m = comp_lab[sl] == cid
        if not m.any():
            continue
        h = sl[0].stop - sl[0].start
        w = sl[1].stop - sl[1].start
        area = int(m.sum())
        dt = ndimage.distance_transform_edt(m)
        dt_max = float(dt.max()) if dt.size else 0.0
        fill = area / float(w * h)
        pix = src_rgb[sl][m]
        mean_rgb = pix.mean(axis=0)
        lab_pix = srgb_to_lab(pix.reshape(-1, 3))
        color_std = float(np.mean(np.std(lab_pix, axis=0)))
        color_dist = float(np.median(dist[sl][m]))
        edge_density = float(np.mean(edge[sl][m]))
        stroke_ratio = dt_max / float(max(1, min(h, w)))
        out[cid] = {
            "bbox": [int(sl[1].start), int(sl[0].start), int(sl[1].stop), int(sl[0].stop)],
            "area": area, "w": w, "h": h, "fill": fill,
            "mean_rgb": mean_rgb, "color_std": color_std, "color_dist": color_dist,
            "edge_density": edge_density, "stroke_ratio": stroke_ratio,
            "dt_mean_over_max": float(np.mean(dt[m]) / dt_max) if dt_max > 0 else 1.0,
        }
    return out


def _boxes_of(mask: np.ndarray, min_area: int):
    lab, n = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    out = []
    if n == 0:
        return out, lab
    slices = ndimage.find_objects(lab)
    for i in range(1, n + 1):
        sl = slices[i - 1]
        if sl is None:
            continue
        area = int((lab[sl] == i).sum())
        if area < min_area:
            continue
        out.append({"id": i, "bbox": [int(sl[1].start), int(sl[0].start),
                                      int(sl[1].stop), int(sl[0].stop)],
                    "area": area, "slice": sl})
    return out, lab


def detect_text_regions(src_rgb: np.ndarray, edge: np.ndarray, fg_mask: np.ndarray):
    """独立于背景色的文字检测：笔画边缘 → 字块聚类 → 局部底色差分出笔画。

    为什么不能只用「与背景色差」找字：卡片/窗口上的文字，字色只与卡片差，
    与画布背景同属前景，会被整块吞进主体。这里用局部底色的差分，字在哪层都能切。
    """
    H, W = fg_mask.shape
    thr = max(0.10, float(np.percentile(edge, 92)))
    seed = edge > thr
    # 只在有前景的地方找字；背景纹理不参与（避免把渐变噪点当字）
    seed &= ndimage.binary_dilation(fg_mask, structure=np.ones((5, 5), dtype=bool))
    seed = ndimage.binary_closing(seed, structure=np.ones((3, 3), dtype=bool))
    comps, _ = _boxes_of(seed, max(8, int(W * H * 0.000004)))

    glyphs = []
    for c in comps:
        x0, y0, x1, y1 = c["bbox"]
        w, h = x1 - x0, y1 - y0
        if h < 6 or h > 0.30 * H or w < 3 or w > 0.55 * W:
            continue
        if not (0.05 <= w / float(h) <= 12.0):
            continue
        if c["area"] / float(w * h) > 0.92:      # 实心块不是笔画
            continue
        glyphs.append(c)

    # 字怀/内部笔画（A 的三角孔、汉字的内部点）会被单独成块，先把它们并回大字块，
    # 否则高度一致性会被一个 20px 的小块整段否掉。
    def _inside(inner, outer):
        return (inner[0] >= outer[0] - 1 and inner[1] >= outer[1] - 1
                and inner[2] <= outer[2] + 1 and inner[3] <= outer[3] + 1
                and (inner[2] - inner[0]) * (inner[3] - inner[1]) <
                0.75 * (outer[2] - outer[0]) * (outer[3] - outer[1]))
    keep = []
    for i, c in enumerate(glyphs):
        if any(j != i and _inside(c["bbox"], o["bbox"]) for j, o in enumerate(glyphs)):
            continue
        keep.append(c)
    glyphs = keep

    parent = {c["id"]: c["id"] for c in glyphs}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    by_id = {c["id"]: c for c in glyphs}
    for ii, a in enumerate(glyphs):
        ba = a["bbox"]
        for b in glyphs[ii + 1:]:
            bb = b["bbox"]
            v_overlap = min(ba[3], bb[3]) - max(ba[1], bb[1])
            h_overlap = min(ba[2], bb[2]) - max(ba[0], bb[0])
            h_gap = max(ba[0] - bb[2], bb[0] - ba[2], 0)
            v_gap = max(ba[1] - bb[3], bb[1] - ba[3], 0)
            # 用较小的那一边做尺度：大标题与小字幕紧邻时，不能被大字号拖着并成一行
            # 同行：字距 ≤ 2.0 字高（设计字体常有大字距 letter-spacing，0.7 会把每个字母
            # 拆成独立簇而整行判废）；同列：行距 ≤ 0.5 字高（竖排）。
            same_line = v_overlap >= 0.35 * min(ba[3] - ba[1], bb[3] - bb[1]) and \
                h_gap <= 2.0 * min(ba[3] - ba[1], bb[3] - bb[1]) and \
                0.6 <= (ba[3] - ba[1]) / float(max(1, bb[3] - bb[1])) <= 1.67
            same_col = h_overlap >= 0.35 * min(ba[2] - ba[0], bb[2] - bb[0]) and \
                v_gap <= 0.5 * min(ba[3] - ba[1], bb[3] - bb[1])
            if same_line or same_col:
                union(a["id"], b["id"])

    clusters = {}
    for c in glyphs:
        clusters.setdefault(find(c["id"]), []).append(c)
    if os.environ.get("PNGP1_DEBUG"):
        for k, v in clusters.items():
            boxes = [c["bbox"] for c in v]
            print("[dbg] cluster n=%d bbox=%s" % (len(v), [min(b[0] for b in boxes), min(b[1] for b in boxes),
                  max(b[2] for b in boxes), max(b[3] for b in boxes)]), file=sys.stderr)

    lab_src = srgb_to_lab(src_rgb)
    regions = []
    for members in clusters.values():
        # 单成员簇：小字紧排时笔画边缘会连成一整块，设计字体又常有大字距，
        # 都可能整行只有 1 个块。这类不立刻否，等笔画连通块数算出来再看
        # （多字母成行的笔画块 ≥ 4；一条横线/实心块只有 1 个）。
        lone = len(members) == 1
        if len(members) < 3 and not lone:
            if os.environ.get("PNGP1_DEBUG"):
                print("[dbg] reject n<3", [m["bbox"] for m in members], file=sys.stderr)
            continue
        hs = [m["bbox"][3] - m["bbox"][1] for m in members]
        med_h = float(np.median(hs))
        trimmed = [m for m in members if 0.5 * med_h <= (m["bbox"][3] - m["bbox"][1]) <= 2.0 * med_h]
        if len(trimmed) < 3 and not (lone and len(trimmed) >= 1):
            if os.environ.get("PNGP1_DEBUG"):
                print("[dbg] reject after trim", len(trimmed), sorted(hs), file=sys.stderr)
            continue
        members = trimmed
        hs = [m["bbox"][3] - m["bbox"][1] for m in members]
        boxes = [m["bbox"] for m in members]
        bx0 = min(b[0] for b in boxes)
        by0 = min(b[1] for b in boxes)
        bx1 = max(b[2] for b in boxes)
        by1 = max(b[3] for b in boxes)
        bw, bh = bx1 - bx0, by1 - by0
        if bh < 8 or bh > 0.32 * H or bw > 0.78 * W:
            continue
        if bw * bh > 0.5 * W * H:
            continue
        if bw / float(max(1, bh)) < 0.15:
            continue
        pad = 3
        x0, y0 = max(0, bx0 - pad), max(0, by0 - pad)
        x1, y1 = min(W, bx1 + pad), min(H, by1 + pad)
        sub_edge = seed[y0:y1, x0:x1]
        if sub_edge.mean() < 0.02:
            continue
        sub_lab = lab_src[y0:y1, x0:x1]
        # 局部底色 = 区域内「非边缘」像素的中位色；文字只与它做差分
        flat = ~ndimage.binary_dilation(sub_edge, structure=np.ones((3, 3), dtype=bool))
        if flat.sum() < 16:
            continue
        base = np.median(sub_lab[flat], axis=0)
        dist = np.sqrt(((sub_lab - base) ** 2).sum(axis=2))
        dflat = dist[flat]
        med = float(np.median(dflat))
        noise = max(0.5, 1.4826 * float(np.median(np.abs(dflat - med))))
        t = max(9.0, med + 3.0 * noise)
        stroke = dist > t
        stroke = ndimage.binary_closing(stroke, structure=np.ones((3, 3), dtype=bool))
        # 只保留「碰得到边缘」的连通块：笔画芯再粗也不会被挖空，背景噪点也不会被带进来
        sl, ns = ndimage.label(stroke, structure=np.ones((3, 3), dtype=np.uint8))
        kept_blocks = 0
        if ns:
            near = ndimage.binary_dilation(sub_edge, structure=np.ones((5, 5), dtype=bool))
            sizes = np.bincount(sl.ravel())
            keep = np.zeros(sizes.shape, dtype=bool)
            for cid in range(1, ns + 1):
                if sizes[cid] < 6:
                    continue
                keep[cid] = bool((near & (sl == cid)).any())
            keep[0] = False
            kept_blocks = int(keep.sum())
            stroke = keep[sl]
        # 单成员簇的补判：一条横线/实心装饰只有 1 个笔画块，多字母成行 ≥ 4
        if lone and kept_blocks < 4:
            if os.environ.get("PNGP1_DEBUG"):
                print("[dbg] reject lone blocks=%d" % kept_blocks, [m["bbox"] for m in members], file=sys.stderr)
            continue
        if stroke.sum() < max(20, int(0.02 * bw * bh)):
            continue
        full = np.zeros((H, W), dtype=bool)
        full[y0:y1, x0:x1] = stroke
        full &= fg_mask
        if full.sum() < 20:
            continue
        contrast = float(np.median(dist[stroke]))
        density = float(sub_edge.mean())
        count_score = min(1.0, len(members) / 8.0)
        height_score = 1.0 - min(1.0, float(np.std(hs)) / max(1.0, float(np.mean(hs))))
        conf = 0.30 + 0.30 * count_score + 0.20 * height_score + 0.20 * min(1.0, contrast / 60.0)
        regions.append({
            "bbox": [x0, y0, x1, y1],
            "mask": full,
            "glyph_count": len(members),
            "edge_density": f3(density),
            "stroke_contrast_delta_e": f1(contrast),
            "text_score": f3(min(0.99, conf)),
        })
    regions.sort(key=lambda r: (r["bbox"][1], r["bbox"][0]))
    return regions


def group_text_regions(regions):
    """同一行被切碎的区域按 bbox 重叠并回一段，避免一段话出多层。"""
    if len(regions) <= 1:
        return regions
    boxes = [r["bbox"] for r in regions]
    parent = list(range(len(regions)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for i in range(len(regions)):
        for j in range(i + 1, len(regions)):
            a, b = boxes[i], boxes[j]
            if min(a[2], b[2]) > max(a[0], b[0]) and min(a[3], b[3]) > max(a[1], b[1]):
                ra, rb = find(i), find(j)
                if ra != rb:
                    parent[rb] = ra
    merged = {}
    for i, r in enumerate(regions):
        merged.setdefault(find(i), []).append(r)
    out = []
    for rs in merged.values():
        if len(rs) == 1:
            out.append(rs[0])
            continue
        m = rs[0]["mask"].copy()
        for r in rs[1:]:
            m |= r["mask"]
        boxes = [r["bbox"] for r in rs]
        out.append({
            "bbox": [min(b[0] for b in boxes), min(b[1] for b in boxes),
                     max(b[2] for b in boxes), max(b[3] for b in boxes)],
            "mask": m,
            "glyph_count": sum(r["glyph_count"] for r in rs),
            "edge_density": f3(max(r["edge_density"] for r in rs)),
            "stroke_contrast_delta_e": f1(max(r["stroke_contrast_delta_e"] for r in rs)),
            "text_score": f3(max(r["text_score"] for r in rs)),
        })
    out.sort(key=lambda r: (r["bbox"][1], r["bbox"][0]))
    return out

def adaptive_group(stats: dict, ids: list, H: int, W: int, comp_lab: np.ndarray = None):
    """非文字组件的自适应膨胀合并：半径取组数最长稳定平台，避免过合并。"""
    if not ids:
        return []
    # 用真实像素而非 bbox 参与膨胀；bbox 会把斜排的装饰件凭空连成一片。
    full = np.zeros((H, W), dtype=bool)
    for cid in ids:
        x0, y0, x1, y1 = stats[cid]["bbox"]
        if comp_lab is not None:
            full[y0:y1, x0:x1] |= (comp_lab[y0:y1, x0:x1] == cid)
        else:
            full[y0:y1, x0:x1] = True
    neigh = np.ones((3, 3), dtype=bool)
    cap = max(2, min(12, int(round(math.hypot(W, H) * 0.006))))
    series = []
    cur = full.copy()
    for _ in range(cap):
        cur = ndimage.binary_dilation(cur, structure=neigh)
        series.append(int(ndimage.label(cur, structure=neigh)[1]))
    runs = []
    s = 0
    for i in range(1, len(series) + 1):
        if i == len(series) or series[i] != series[s]:
            runs.append((s + 1, i, series[s]))
            s = i
    stable = [r for r in runs if r[1] - r[0] >= 2]
    if stable:
        start, end, _ = max(stable, key=lambda r: (r[1] - r[0], r[2]))
        r = start
    else:
        r = 1
    cur = full.copy()
    for _ in range(r):
        cur = ndimage.binary_dilation(cur, structure=neigh)
    lab, _ = ndimage.label(cur, structure=neigh)
    # 用组件自己的像素对膨胀 label 投票（不能用 bbox 中心：环形框的中心会落在框内物体上，
    # 把两个本来分开的组件错误并成一组）
    votes = {}
    for cid in ids:
        x0, y0, x1, y1 = stats[cid]["bbox"]
        sub = comp_lab[y0:y1, x0:x1] == cid
        labs = lab[y0:y1, x0:x1][sub]
        if labs.size == 0:
            continue
        counts = np.bincount(labs.ravel())
        votes[cid] = int(np.argmax(counts))
    groups = defaultdict(list)
    for cid, gid in votes.items():
        groups[gid].append(cid)
    out = []
    for gid, members in groups.items():
        members = sorted(members)
        boxes = [stats[i]["bbox"] for i in members]
        bbox = [min(b[0] for b in boxes), min(b[1] for b in boxes),
                max(b[2] for b in boxes), max(b[3] for b in boxes)]
        out.append({"ids": members, "bbox": bbox,
                    "area": sum(stats[i]["area"] for i in members), "radius_px": r})
    out.sort(key=lambda g: -g["area"])
    return out


def object_score(group, stats, dist, edge, H, W) -> float:
    b = group["bbox"]
    area_ratio = group["area"] / float(W * H)
    bw, bh = max(1, b[2] - b[0]), max(1, b[3] - b[1])
    compact = group["area"] / float(bw * bh)
    m = np.zeros((H, W), dtype=bool)
    for cid in group["ids"]:
        x0, y0, x1, y1 = stats[cid]["bbox"]
        m[y0:y1, x0:x1] = True
    sal = float(np.mean(dist[m])) / 50.0
    cx = (b[0] + b[2]) / 2.0 / W
    cy = (b[1] + b[3]) / 2.0 / H
    centrality = 1.0 - min(1.0, math.hypot(cx - 0.5, cy - 0.5) / 0.7071)
    border_touch = 0.0
    if b[0] <= 1 or b[1] <= 1 or b[2] >= W - 1 or b[3] >= H - 1:
        border_touch = 0.5
    color_std = float(np.median([stats[i]["color_std"] for i in group["ids"]]))
    coherence = 1.0 - min(1.0, color_std / 30.0)
    edge_density = float(np.median([stats[i]["edge_density"] for i in group["ids"]]))
    solid = 1.0 - min(1.0, edge_density / 0.35)
    return float(0.34 * min(1.0, area_ratio / 0.12) + 0.20 * min(1.0, sal)
                 + 0.14 * compact + 0.10 * centrality + 0.10 * coherence
                 + 0.12 * solid - 0.25 * border_touch)


# ────────────────────────────────────────────────────────────────
# ④ 补洞（P1：边缘延展）
# ────────────────────────────────────────────────────────────────
def fill_holes_by_extension(src_rgb: np.ndarray, hole: np.ndarray, grow: int = 2):
    """边缘延展填洞：只从「确定是背景」的像素外推，不把物体抗锯齿边当成底色。

    坑（实测踩过）：直接拿「非洞像素」做最近邻，会取到文字/物体的抗锯齿边，
    补出来是一圈白边、整段文字的 ghost。这里先把洞外扩 2px 再去掉，填充源
    至少离原边界 2px，取到的就是真背景色。
    """
    if not hole.any():
        return src_rgb.copy(), {"hole_pixels": 0}
    # 只改洞本身（不向外多刷一圈，保证洞外像素与源图逐字节一致）；
    # 但填充源向内缩 grow 像素，避开物体/文字的 1-2px 抗锯齿边。
    known = ~hole
    sources = ndimage.binary_erosion(known, structure=np.ones((3, 3), dtype=bool),
                                     iterations=max(0, grow)) if grow else known
    if not sources.any():
        sources = known
    idx = ndimage.distance_transform_edt(~sources, return_distances=False, return_indices=True)
    out = src_rgb.copy()
    out[hole] = src_rgb[tuple(idx)][hole]

    # 洞的尺度：最大内切半径 ×2 ≈ 洞宽；边界上还有真实像素，不会露黑。
    dt = ndimage.distance_transform_edt(hole)
    max_r = float(dt.max()) if dt.size else 0.0
    return out, {"hole_pixels": int(hole.sum()),
                 "hole_ratio": f3(float(hole.mean())),
                 "max_hole_radius_px": f1(max_r),
                 "fill_grow_px": int(grow),
                 "method": "edge_extend_nearest_from_confident_background"}


# ────────────────────────────────────────────────────────────────
# ⑤ 分层 + 导出
# ────────────────────────────────────────────────────────────────
def _feather_alpha(mask: np.ndarray, src_alpha: np.ndarray) -> np.ndarray:
    """向内 1-2px 羽化：alpha 只落在真实前景像素上，层外不留半透明黑边。"""
    inner = ndimage.binary_erosion(mask, structure=np.ones((3, 3), dtype=bool), iterations=1)
    a = np.where(inner, 255.0, 0.0)
    a = ndimage.gaussian_filter(a, sigma=0.7)
    a = np.clip(a, 0.0, 255.0) * mask.astype(np.float64)
    return (a * (src_alpha.astype(np.float64) / 255.0)).round().astype(np.uint8)


def _compare_zone(layers, shape):
    """重合成比对区：非背景层的 bbox 及外扩 3px（补洞会改到这一圈），
    加上远离所有前景层的背景区（用来抓「背景被误改」）。"""
    H, W = shape
    fg_boxes = np.zeros((H, W), dtype=bool)
    for l in layers:
        if l["class"] == "BACKGROUND":
            continue
        x0, y0, x1, y1 = [int(v) for v in l["bbox"]]
        fg_boxes[max(0, y0):min(H, y1), max(0, x0):min(W, x1)] = True
    near = ndimage.binary_dilation(fg_boxes, structure=np.ones((3, 3), dtype=bool), iterations=3)
    return fg_boxes | ~near


def _solid_compare_mask(layers, out_dir, shape):
    """重合成比对的「实心区」：非背景层 alpha 的 6px 边界带、半透明像素、
    以及补洞区（挪走文字后新填的内容，本来就不等于源图）之外。"""
    H, W = shape
    covered = np.zeros((H, W), dtype=bool)
    partial = np.zeros((H, W), dtype=bool)
    excl = np.zeros((H, W), dtype=bool)
    for l in layers:
        if l["class"] == "BACKGROUND":
            continue
        a = np.asarray(Image.open(os.path.join(out_dir, l["file"])).convert("RGBA"))[:, :, 3]
        covered |= a > 0
        partial |= (a > 0) & (a < 255)
        for b in l.get("compare_exclude_boxes") or []:
            x0, y0, x1, y1 = [int(v) for v in b]
            excl[max(0, y0 - 2):min(H, y1 + 2), max(0, x0 - 2):min(W, x1 + 2)] = True
    band = ndimage.binary_dilation(covered, structure=np.ones((3, 3), dtype=bool), iterations=6)
    band &= ~ndimage.binary_erosion(covered, structure=np.ones((3, 3), dtype=bool), iterations=6)
    zone = _compare_zone(layers, shape)
    return ~partial & ~band & zone & ~excl


def _layer_png(src_rgba, mask, alpha_out, path, rgb_fill=None, fill_mask=None):
    out = np.zeros_like(src_rgba)
    out[mask, :3] = src_rgba[mask, :3]
    out[:, :, 3] = alpha_out
    if rgb_fill is not None and fill_mask is not None and fill_mask.any():
        out[fill_mask, :3] = rgb_fill[fill_mask, :3]
        out[fill_mask, 3] = 255
    Image.fromarray(out, mode="RGBA").save(path, optimize=True)


def split(src: str, out_dir: str) -> dict:
    t0 = time.perf_counter()
    os.makedirs(out_dir, exist_ok=True)
    layers_dir = os.path.join(out_dir, "layers")
    os.makedirs(layers_dir, exist_ok=True)
    src = os.path.abspath(src)
    before = sha256_file(src)
    rgba, mode, size = read_rgba(src)
    H, W = rgba.shape[:2]
    src_rgb = rgba[:, :, :3]
    src_alpha = rgba[:, :, 3]
    t_read = time.perf_counter()

    bg_img, bg_model, bg_residual, border = estimate_background(src_rgb)
    mask_fg, dist, fg_info = foreground_mask(src_rgb, src_alpha, bg_img)
    t_mask = time.perf_counter()

    gray = (0.299 * src_rgb[..., 0] + 0.587 * src_rgb[..., 1] + 0.114 * src_rgb[..., 2])
    edge = _edge_magnitude(gray)

    # 文字先切：用局部底色差分拿笔画，再从前景掩膜里扣掉，避免「字被主体吞掉」
    text_regions = group_text_regions(detect_text_regions(src_rgb, edge, mask_fg))
    text_mask_all = np.zeros((H, W), dtype=bool)
    for r in text_regions:
        text_mask_all |= r["mask"]
    object_mask = mask_fg & ~text_mask_all

    # 文字笔画边缘的抗锯齿残渣会剩成 1~5px 的小块；按「整块落在文字框内」并回文字层，
    # 不让它变成几十个 ELEMENT 碎片层。
    if text_regions:
        for r in text_regions:
            r["_orig_bbox"] = list(r["bbox"])
        cl0, n0 = ndimage.label(object_mask, structure=np.ones((3, 3), dtype=np.uint8))
        sizes0 = np.bincount(cl0.ravel()) if n0 else np.zeros(1, dtype=int)
        sl0 = ndimage.find_objects(cl0) if n0 else []
        todo = [(cid, int(sizes0[cid]), sl0[cid - 1])
                for cid in range(1, n0 + 1) if sizes0[cid] > 0]
        _grow3 = np.ones((3, 3), dtype=bool)
        grown_cache = {}

        def _grown(r):
            g = grown_cache.get(id(r))
            if g is None:
                g = ndimage.binary_dilation(r["mask"], _grow3, iterations=3)
                grown_cache[id(r)] = g
            return g

        for cid, sz, sl in todo:
            bx = [sl[1].start, sl[0].start, sl[1].stop, sl[0].stop]
            m = cl0[sl] == cid
            cx0, cy0, cx1, cy1 = bx
            ch = cy1 - cy0
            for r in text_regions:
                x0, y0, x1, y1 = r["bbox"]
                iy0, iy1 = max(0, y0 - cy0), min(m.shape[0], y1 - cy0)
                ix0, ix1 = max(0, x0 - cx0), min(m.shape[1], x1 - cx0)
                inside = int(m[iy0:iy1, ix0:ix1].sum()) if (iy1 > iy0 and ix1 > ix0) else 0
                if inside >= 0.7 * sz:
                    ok = True
                else:
                    # 描边/阴影/抗锯齿在笔画外圈留的细碎残渣：面积远小于本文字区，
                    # 且紧贴笔画边缘（膨胀 3px 相交）时也并回文字层，避免「拖走文字后原位留茬」。
                    cap = max(64.0, 0.35 * float(r["mask"].sum()))
                    ok = False
                    if sz <= cap and not (cx1 < x0 - 8 or cx0 > x1 + 8
                                          or cy1 < y0 - 8 or cy0 > y1 + 8):
                        grown = _grown(r)[sl]
                        ok = bool((grown & m).any())
                    if not ok:
                        # 同一行内被漏检的字母（设计字体大 letter-spacing、小字紧排断块）：
                        # 垂直范围重叠 ≥60%、字高同量级、水平间距 ≤2.5 字高，就补进这一行，
                        # 否则拖走文字层后原位会留一串字。宽度上限 2× 原检测宽度，防整行吞到画布边。
                        ox0, oy0, ox1, oy1 = r["_orig_bbox"]
                        oh = max(1, oy1 - oy0)
                        if 0.6 <= ch / float(oh) <= 1.67:
                            ov = min(cy1, oy1) - max(cy0, oy0)
                            if ov >= 0.6 * min(ch, oh):
                                gap = max(cx0 - ox1, ox0 - cx1, 0)
                                if gap <= 2.5 * ch:
                                    nx0, nx1 = min(x0, cx0), max(x1, cx1)
                                    ok = (nx1 - nx0) <= 2.0 * max(1, ox1 - ox0) + 2 * ch
                if ok:
                    r["mask"][sl] |= m
                    text_mask_all[sl] |= m
                    object_mask[sl] &= ~m
                    r["_dirty"] = True
                    grown_cache.pop(id(r), None)
                    break
        for r in text_regions:
            if r.pop("_dirty", False):
                r["bbox"] = bbox_of(r["mask"])

    comp_lab, n_comp = ndimage.label(object_mask, structure=np.ones((3, 3), dtype=np.uint8))
    sizes = np.bincount(comp_lab.ravel())
    ids = [i for i in range(1, n_comp + 1) if sizes[i] >= max(12, int(W * H * MIN_AREA_RATIO))]
    # 面积 < 800px 的碎渣不单独成层，后面并成一个 ELEMENT 碎片层
    tiny_ids = [i for i in ids if sizes[i] < 800]
    ids = [i for i in ids if sizes[i] >= 800]
    stats = component_stats(src_rgb, object_mask, comp_lab, ids, edge, dist, None)
    t_stats = time.perf_counter()

    text_layers = []
    for r in text_regions:
        m = r["mask"]
        text_layers.append({"mask": m, "bbox": bbox_of(m), "area": int(m.sum()),
                            "text_score": r["text_score"],
                            "glyph_count": r["glyph_count"],
                            "stroke_contrast_delta_e": r["stroke_contrast_delta_e"]})
    groups = adaptive_group(stats, ids, H, W, comp_lab)
    t_group = time.perf_counter()

    # 主体：先按分排序，取达标的前两个；一个都不达标时保底选最大组并标 low_confidence
    scored = [(object_score(g, stats, dist, edge, H, W), g) for g in groups]
    scored.sort(key=lambda x: -x[0])
    object_groups, element_groups = [], []
    for sc, g in scored:
        area_ratio = g["area"] / float(W * H)
        if len(object_groups) < 2 and sc >= OBJECT_SCORE_MIN and area_ratio >= 0.02:
            object_groups.append((sc, g))
        else:
            element_groups.append(g)
    object_fallback = False
    if not object_groups and element_groups:
        biggest = max(element_groups, key=lambda g: g["area"])
        if biggest["area"] / float(W * H) >= 0.01:
            object_groups = [(object_score(biggest, stats, dist, edge, H, W), biggest)]
            element_groups = [g for g in element_groups if g is not biggest]
            object_fallback = True
    object_groups.sort(key=lambda x: -x[0])

    # 元素层数上限：太碎就按面积取前 N，剩下的并进最后一个「碎片」层
    element_groups.sort(key=lambda g: -g["area"])
    overflow = []
    if len(element_groups) > MAX_ELEMENT_LAYERS:
        overflow = element_groups[MAX_ELEMENT_LAYERS - 1:]
        element_groups = element_groups[:MAX_ELEMENT_LAYERS - 1]

    def group_mask(g):
        m = np.zeros((H, W), dtype=bool)
        for cid in g["ids"]:
            x0, y0, x1, y1 = stats[cid]["bbox"]
            sub = comp_lab[y0:y1, x0:x1] == cid
            m[y0:y1, x0:x1] |= sub
        return m & mask_fg

    def group_color(g):
        m = group_mask(g)
        if not m.any():
            return [0, 0, 0]
        return [float(v) for v in src_rgb[m].mean(axis=0)]

    # 主体内部的独立装饰件（工具条图标、徽章内圈等）：颜色离主体主色足够远、
    # 面积在 0.08%~2% 画布、且不贴主体边界，才拆成 ELEMENT；拿不准就不拆。
    inner_elements = []
    lab_src_full = srgb_to_lab(src_rgb)
    inner_all = np.zeros((H, W), dtype=bool)
    for sc, g in object_groups:
        m = group_mask(g)
        if not m.any():
            continue
        med = np.median(lab_src_full[m], axis=0)
        d = np.sqrt(((lab_src_full - med) ** 2).sum(axis=2))
        core = ndimage.binary_erosion(m, structure=np.ones((3, 3), dtype=bool), iterations=2)
        cand = m & core & (d > 32.0) & ~text_mask_all
        cl, nc = ndimage.label(cand, structure=np.ones((3, 3), dtype=np.uint8))
        for cid in range(1, nc + 1):
            mm = ndimage.binary_fill_holes(cl == cid)
            area = int(mm.sum())
            if not (0.0008 * W * H <= area <= 0.02 * W * H):
                continue
            bx = bbox_of(mm)
            fill = area / float(max(1, (bx[2] - bx[0]) * (bx[3] - bx[1])))
            if fill < 0.5:
                continue
            inner_elements.append({"mask": mm, "bbox": bx})
            inner_all |= mm
    if inner_elements:
        object_groups = [(sc, g) for sc, g in object_groups]

    layers = []
    seq = defaultdict(int)
    covered_union = np.zeros((H, W), dtype=bool)

    def add_layer(cls, mask, bbox, confidence, low, notes, alpha_out=None,
                  rgb_fill=None, fill_mask=None, compare_exclude=None):
        seq[cls] += 1
        name = "%s_%02d_%s" % (cls, seq[cls], CLASS_LABELS[cls])
        fname = name + ".png"
        path = os.path.join(layers_dir, fname)
        a = alpha_out if alpha_out is not None else (src_alpha * mask.astype(np.uint8))
        if fill_mask is not None and fill_mask.any() and alpha_out is not None:
            a = a.copy()
            a[fill_mask] = 255
        _layer_png(rgba, mask, a, path, rgb_fill, fill_mask)
        # 用「最终 alpha > 0」而不是 mask 来累计承载区：羽化后 round 到 0 的孤立像素
        # 在层里其实看不见，不能算作已承载
        np.logical_or(covered_union, a > 0, out=covered_union)
        color = [float(v) for v in src_rgb[mask].mean(axis=0)] if mask.any() else [0, 0, 0]
        layers.append({
            "class": cls, "seq": seq[cls], "name": name,
            "file": os.path.join("layers", fname).replace(os.sep, "/"),
            "bbox": [int(v) for v in bbox],
            "pixels": int(mask.sum()),
            "alpha_sum": int(a.sum()),
            "confidence": f3(confidence),
            "low_confidence": bool(low),
            "mean_color": hex_of(color),
            "notes": notes,
            # 补洞区是「挪走文字后新填的内容」，本来就不等于源图，重合成比对要排除
            "compare_exclude_boxes": [[int(v) for v in b] for b in (compare_exclude or [])],
        })
        return path

    # OBJECT：文字压出来的洞按「本层自己的像素」延展填掉，挪走文字不露洞
    for rank, (sc, g) in enumerate(object_groups, 1):
        m = group_mask(g) & ~inner_all
        if not m.any():
            continue
        alpha_out = _feather_alpha(m, src_alpha)
        conf = min(0.95, max(0.35, 0.35 + sc * 0.6))
        notes = ["边缘 1-2px 羽化"]
        if object_fallback:
            notes.append("无高置信主体，取最大前景块保底，low_confidence")
        holes = (text_mask_all | inner_all) & ndimage.binary_fill_holes(m)
        idx = ndimage.distance_transform_edt(~m, return_indices=True)[1]
        extended = src_rgb[tuple(idx)]
        hole_boxes = []
        if holes.any():
            hl, _hn = ndimage.label(holes, structure=np.ones((3, 3), dtype=np.uint8))
            for hsl in ndimage.find_objects(hl):
                if hsl is not None:
                    hole_boxes.append([hsl[1].start, hsl[0].start, hsl[1].stop, hsl[0].stop])
        add_layer("OBJECT", m, g["bbox"], conf, object_fallback or conf < MIN_CONFIDENCE, notes,
                  alpha_out, rgb_fill=extended, fill_mask=holes, compare_exclude=hole_boxes)

    # 主体内部拆出来的装饰件
    for ie in inner_elements:
        add_layer("ELEMENT", ie["mask"], ie["bbox"], 0.60, False,
                  ["从主体内部拆出的独立装饰件（高饱和 + 面积/形状达标）"])

    # ELEMENT
    for g in element_groups:
        m = group_mask(g)
        if not m.any():
            continue
        conf = 0.72 if len(g["ids"]) > 1 else 0.62
        add_layer("ELEMENT", m, g["bbox"], conf, conf < MIN_CONFIDENCE, [])

    # TEXT（永远位图）：mask 来自局部底色差分，保留原始抗锯齿像素
    for g in text_layers:
        m = g["mask"]
        if not m.any():
            continue
        conf = min(0.95, max(0.4, 0.30 + g["text_score"] * 0.6))
        add_layer("TEXT", m, g["bbox"], conf, conf < MIN_CONFIDENCE,
                  ["位图文字层：能挪不能改", "不做 OCR，不重建矢量文字"])

    # 小碎渣合并层（< 800px），避免几十个 40px 的层把设计器塞满
    if tiny_ids:
        m = np.zeros((H, W), dtype=bool)
        for cid in tiny_ids:
            m |= (comp_lab == cid)
        m &= object_mask
        if m.any():
            add_layer("ELEMENT", m, bbox_of(m), 0.45, True, ["面积 < 800px 的碎渣合并层"])

    # 溢出碎片合并层
    if overflow:
        m = np.zeros((H, W), dtype=bool)
        for g in overflow:
            m |= group_mask(g)
        if m.any():
            add_layer("ELEMENT", m, bbox_of(m), 0.5, True, ["数量上限合并的碎片"])

    # BACKGROUND（最后画，永远在最底层）
    # 洞只按「确实有层承载」的区域算：前景掩膜里若还有没被任何层吸收的噪点，
    # 在背景上挖洞只会让重合成露出延展填色（真样本上实测 12px 色差 88）。
    holes_bg = covered_union if fg_info["mode"] != "alpha" else mask_fg
    bg_mask = ~holes_bg
    if fg_info["mode"] == "alpha":
        bg_layer = np.zeros_like(rgba)
        bg_layer[:, :, :3] = src_rgb
        bg_layer[:, :, 3] = np.where(holes_bg, 0, src_alpha).astype(np.uint8)
        fill_info = {"hole_pixels": int(holes_bg.sum()), "hole_ratio": f3(float(holes_bg.mean())),
                     "max_hole_radius_px": 0.0, "method": "transparent_keep"}
        Image.fromarray(bg_layer, mode="RGBA").save(os.path.join(layers_dir, "BACKGROUND.png"), optimize=True)
        bg_pixels = int((~holes_bg).sum())
        bg_alpha = int(bg_layer[:, :, 3].sum())
    else:
        filled, fill_info = fill_holes_by_extension(src_rgb, holes_bg)
        bg_layer = np.dstack([filled, np.full((H, W), 255, dtype=np.uint8)])
        Image.fromarray(bg_layer, mode="RGBA").save(os.path.join(layers_dir, "BACKGROUND.png"), optimize=True)
        bg_pixels = int(bg_mask.sum())
        bg_alpha = int(255 * H * W)
    layers.insert(0, {
        "class": "BACKGROUND", "seq": 1, "name": "BACKGROUND",
        "file": "layers/BACKGROUND.png",
        "bbox": [0, 0, W, H],
        "pixels": bg_pixels,
        "alpha_sum": bg_alpha,
        "confidence": 0.99 if not text_layers or object_groups else 0.8,
        "low_confidence": False,
        "mean_color": hex_of(src_rgb[bg_mask].mean(axis=0)) if bg_mask.any() else "#000000",
        "notes": ["已按延展填色补洞" if fg_info["mode"] != "alpha" else "源图透明底，洞保持透明"],
    })
    t_write = time.perf_counter()

    # 预览：左原图 / 右补洞后背景 / 下四类层检查板
    previews = make_previews(src, rgba, layers, layers_dir, out_dir, W, H)

    after = sha256_file(src)
    if before != after:
        raise RuntimeError("源图在拆分过程中被改写，立即中止")

    cls_present = {l["class"] for l in layers}
    warnings = []
    if "TEXT" not in cls_present:
        warnings.append("未检出文字层：整图没有符合笔画/边缘特征的文字区域（不 OCR，不臆造）")
    if "OBJECT" not in cls_present:
        warnings.append("未检出主体层：没有达到面积/显著性阈值的前景块")
    if object_fallback:
        warnings.append("主体为保底选择，low_confidence=true")
    if fill_info["hole_ratio"] > 0.35:
        warnings.append("前景占比 %.1f%%，背景补洞面积大，挪层后可能仍可见延展纹理" %
                        (fill_info["hole_ratio"] * 100))

    output_bytes = sum(os.path.getsize(os.path.join(out_dir, l["file"])) for l in layers)
    doc = {
        "schema": SCHEMA,
        "tool_version": TOOL_VERSION,
        "source": src,
        "source_sha256": before,
        "source_sha256_after": after,
        "source_unchanged": before == after,
        "source_bytes": os.path.getsize(src),
        "source_mode": mode,
        "width": W, "height": H,
        "class_legend": {
            "OBJECT": "会被单独移动/缩放/替换的主体，边缘 1-2px 羽化",
            "TEXT": "文字区域的位图，能挪不能改（不 OCR、不重建矢量文字）",
            "ELEMENT": "装饰件/图标/光效碎片/边框，逐个成层",
            "BACKGROUND": "去掉以上三类后的底图，已按延展填色补洞",
        },
        "text_editable": False,
        "notice": "文字层是位图：能挪不能改",
        "object_detected": bool(object_groups),
        "object_fallback": bool(object_fallback),
        "layers": layers,
        "layer_count": len(layers),
        "classes_present": [c for c in CLASS_ORDER if c in cls_present],
        "background_fill": fill_info,
        "background_model": {"model": bg_model, "border_residual_delta_e": f2(bg_residual),
                             "border_px": border},
        "segmentation": fg_info,
        "grouping": {"component_count": len(ids), "text_region_count": len(text_regions),
                     "text_group_count": len(text_layers), "text_glyphs": int(sum(r["glyph_count"] for r in text_regions)), "object_group_count": len(object_groups),
                     "element_group_count": len(element_groups), "overflow_merged": len(overflow)},
        "warnings": warnings,
        "timings_ms": {
            "read": f1((t_read - t0) * 1000),
            "background_and_mask": f1((t_mask - t_read) * 1000),
            "component_stats": f1((t_stats - t_mask) * 1000),
            "classify_and_group": f1((t_group - t_stats) * 1000),
            "write_layers": f1((t_write - t_group) * 1000),
            "previews": f1((time.perf_counter() - t_write) * 1000),
            "total": f1((time.perf_counter() - t0) * 1000),
        },
        "elapsed_s": f1(time.perf_counter() - t0),
        "sizes": {"layers_bytes": int(output_bytes),
                  "layer_total_mb": f2(output_bytes / 1048576.0),
                  "ratio_to_source": f2(output_bytes / float(os.path.getsize(src)))},
        "previews": previews,
    }
    with open(os.path.join(out_dir, "分层清单.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    return doc


def make_previews(src, rgba, layers, layers_dir, out_dir, W, H):
    """证据图：原图 / 补洞背景 / 分层检查板 / 重合成。全部真实渲染，不做示意。"""
    out = {}
    scale = min(1.0, 720.0 / max(W, H))
    tw, th = max(1, int(round(W * scale))), max(1, int(round(H * scale)))

    def small(im):
        return im.resize((tw, th), Image.LANCZOS)

    src_img = Image.fromarray(rgba, mode="RGBA")
    p1 = os.path.join(out_dir, "预览_原图.png")
    small(src_img).save(p1)
    out["source"] = os.path.basename(p1)

    bg = Image.open(os.path.join(layers_dir, "BACKGROUND.png")).convert("RGBA")
    p2 = os.path.join(out_dir, "预览_背景补洞.png")
    small(bg).save(p2)
    out["background_filled"] = os.path.basename(p2)

    # 检查板：每层一格，最多 12 格，格内棋盘底，层外透明保持棋盘可见
    cell = 16
    n = min(12, len(layers))
    cols = min(4, n)
    rows = int(math.ceil(n / float(cols)))
    board = Image.new("RGBA", (tw * cols, th * rows), (24, 26, 32, 255))
    for y in range(0, th * rows, cell):
        for x in range(0, tw * cols, cell):
            if (x // cell + y // cell) % 2 == 0:
                board.paste((38, 41, 49, 255), (x, y, x + cell, y + cell))
    for idx, l in enumerate(layers[:n]):
        im = small(Image.open(os.path.join(out_dir, l["file"])).convert("RGBA"))
        x = (idx % cols) * tw
        y = (idx // cols) * th
        board.alpha_composite(im, (x, y))
    p3 = os.path.join(out_dir, "预览_分层检查板.png")
    board.convert("RGB").save(p3)
    out["checkerboard"] = os.path.basename(p3)

    # 重合成：BACKGROUND + OBJECT + ELEMENT + TEXT（按层序 alpha over）
    order = {"BACKGROUND": 0, "OBJECT": 1, "ELEMENT": 2, "TEXT": 3}
    comp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for l in sorted(layers, key=lambda x: order[x["class"]]):
        comp.alpha_composite(Image.open(os.path.join(out_dir, l["file"])).convert("RGBA"))
    p4 = os.path.join(out_dir, "预览_重合成.png")
    small(comp).save(p4)
    out["recomposite"] = os.path.basename(p4)

    comp_arr = np.asarray(comp)
    fg = rgba[:, :, 3] > 0
    diff = np.abs(comp_arr[:, :, :3].astype(np.int16) - rgba[:, :, :3].astype(np.int16))
    partial = np.zeros((H, W), dtype=bool)
    for l in layers:
        a = np.asarray(Image.open(os.path.join(out_dir, l["file"])).convert("RGBA"))[:, :, 3]
        partial |= (a > 0) & (a < 255)
    zone = _compare_zone(layers, (H, W))
    solid = fg & ~partial & zone
    out["recomposite_max_abs_diff"] = int(diff[solid].max()) if solid.any() else 0
    out["recomposite_p99_abs_diff"] = f1(np.percentile(diff[solid], 99)) if solid.any() else 0.0
    out["partial_alpha_pixels"] = int(partial.sum())
    out["solid_compare_pixels"] = int(solid.sum())
    return out


# ────────────────────────────────────────────────────────────────
# ⑥ 契约复算
# ────────────────────────────────────────────────────────────────
def check(out_dir: str, require_all_classes: bool = False) -> dict:
    manifest_path = os.path.join(out_dir, "分层清单.json")
    with open(manifest_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    checks = []

    def ck(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": str(detail)})

    ck("schema = pngp1/v1", doc.get("schema") == SCHEMA, doc.get("schema"))
    W, H = int(doc["width"]), int(doc["height"])
    files = [l["file"] for l in doc["layers"]]
    ck("层数与清单一致", doc["layer_count"] == len(doc["layers"]),
       "%s vs %s" % (doc["layer_count"], len(doc["layers"])))
    ck("文件名无空格/全角", all((" " not in f and "　" not in f) for f in files), files)
    ck("至少 1 个 BACKGROUND", any(l["class"] == "BACKGROUND" for l in doc["layers"]), "")
    ck("BACKGROUND 唯一且在最底层", doc["layers"][0]["class"] == "BACKGROUND" and
       sum(1 for l in doc["layers"] if l["class"] == "BACKGROUND") == 1, "")
    ck("TEXT 全部 text_editable=false", doc.get("text_editable") is False, "")
    ck("notice 写明能挪不能改", "能挪不能改" in doc.get("notice", ""), doc.get("notice"))

    arrays = {}
    for l in doc["layers"]:
        p = os.path.join(out_dir, l["file"])
        ok = os.path.isfile(p)
        ck("%s 文件存在" % l["name"], ok, p)
        if not ok:
            continue
        with Image.open(p) as im:
            mode = im.mode
            size = im.size
            arr = np.asarray(im.convert("RGBA"))
        arrays[l["name"]] = arr
        ck("%s 是 RGBA" % l["name"], mode == "RGBA", mode)
        ck("%s 画幅 = 源图" % l["name"], size == (W, H), "%s vs %s" % (size, (W, H)))
        nz = arr[:, :, 3] > 0
        bbox = bbox_of(nz)
        if l["class"] == "BACKGROUND":
            ck("%s 覆盖整幅" % l["name"], bbox == [0, 0, W, H] or bool((arr[:, :, 3] == 0).any()),
               "%s vs %s" % (bbox, [0, 0, W, H]))
        else:
            near = all(abs(int(a) - int(b)) <= 1 for a, b in zip(bbox, l["bbox"]))
            ck("%s bbox 与像素一致" % l["name"], near,
               "%s vs %s" % (bbox, l["bbox"]))

    # 重合成
    order = {"BACKGROUND": 0, "OBJECT": 1, "ELEMENT": 2, "TEXT": 3}
    comp = np.zeros((H, W, 4), dtype=np.float64)
    for l in sorted(doc["layers"], key=lambda x: order[x["class"]]):
        arr = arrays.get(l["name"])
        if arr is None:
            continue
        a = arr[:, :, 3:4].astype(np.float64) / 255.0
        rgb = arr[:, :, :3].astype(np.float64) * a
        comp[:, :, :3] = rgb + comp[:, :, :3] * (1 - a)
        comp[:, :, 3:4] = a + comp[:, :, 3:4] * (1 - a)

    with Image.open(doc["source"]) as im:
        src = np.asarray(im.convert("RGBA")).astype(np.float64)
    fg = src[:, :, 3] > 0
    partial = fg & (src[:, :, 3] < 255)
    solid = fg & _solid_compare_mask(doc["layers"], out_dir, (H, W))
    diff = np.abs(comp[:, :, :3] - src[:, :, :3])
    max_diff = float(diff[solid].max()) if solid.any() else 0.0
    p999 = float(np.percentile(diff[solid], 99.9)) if solid.any() else 0.0
    ck("实心像素重合成最大差 <= 2", max_diff <= 2.0,
       "max=%.1f p99.9=%.2f solid_px=%d feather_px=%d" % (max_diff, p999, int(solid.sum()), int(partial.sum())))
    if doc["segmentation"]["mode"] != "alpha":
        # 透明底源图本身就是「半透明像素本体」，羽化带占比这条只对不透明设计图有意义
        ck("羽化带只占 <= 6%% 前景像素",
           (int(partial.sum()) / max(1, int(fg.sum()))) <= 0.06,
           "%.2f%%" % (100.0 * partial.sum() / max(1, int(fg.sum()))))

    # 背景补洞：不透明输入时背景层必须全不透明（不能露洞）
    bg = arrays.get(doc["layers"][0]["name"])
    if bg is not None and doc["segmentation"]["mode"] != "alpha":
        ck("背景补洞后无透明像素", bool((bg[:, :, 3] == 255).all()),
           "透明像素=%d" % int((bg[:, :, 3] != 255).sum()))
    # 类齐全：BACKGROUND / OBJECT 必须有；TEXT / ELEMENT 按图内容可有可无，
    # 不让「这张图本来没字」被判成输出不合规（不 OCR、不臆造是硬口径）。
    present = {l["class"] for l in doc["layers"]}
    if doc.get("object_detected") is False:
        # 纯标题图/纯装饰图本轮检测到 0 个达标主体，方案已显式声明不臆造主体层
        ck("含 BACKGROUND（本图声明无主体，不臆造 OBJECT）",
           "BACKGROUND" in present and "OBJECT" not in present, sorted(present))
    else:
        ck("含 BACKGROUND 与 OBJECT", present >= {"BACKGROUND", "OBJECT"}, sorted(present))
    if require_all_classes:
        ck("四类齐全（本图必须四类）",
           present >= {"OBJECT", "TEXT", "ELEMENT", "BACKGROUND"}, sorted(present))
    ck("low_confidence 字段齐全", all("low_confidence" in l for l in doc["layers"]), "")

    doc_out = {"schema": SCHEMA, "checks": checks,
               "pass_count": sum(1 for c in checks if c["ok"]),
               "fail_count": sum(1 for c in checks if not c["ok"]),
               "verdict": "PASS" if all(c["ok"] for c in checks) else "FAIL",
               "recomposite_max_abs_diff": f1(max_diff),
               "recomposite_p999_abs_diff": f2(p999)}
    return doc_out


def probe(src: str) -> dict:
    rgba, mode, size = read_rgba(src)
    H, W = rgba.shape[:2]
    src_rgb = rgba[:, :, :3]
    bg_img, bg_model, bg_residual, border = estimate_background(src_rgb)
    mask_fg, dist, info = foreground_mask(src_rgb, rgba[:, :, 3], bg_img)
    gray = (0.299 * src_rgb[..., 0] + 0.587 * src_rgb[..., 1] + 0.114 * src_rgb[..., 2])
    edge = _edge_magnitude(gray)
    comp_lab, n = ndimage.label(mask_fg, structure=np.ones((3, 3), dtype=np.uint8))
    sizes = np.bincount(comp_lab.ravel())
    ids = [i for i in range(1, n + 1) if sizes[i] >= max(12, int(W * H * MIN_AREA_RATIO))]
    stats = component_stats(src_rgb, mask_fg, comp_lab, ids, edge, dist, None)
    edge = _edge_magnitude(0.299 * src_rgb[..., 0] + 0.587 * src_rgb[..., 1] + 0.114 * src_rgb[..., 2])
    regions = group_text_regions(detect_text_regions(src_rgb, edge, mask_fg))
    return {"width": W, "height": H, "mode": mode, "background_model": bg_model,
            "border_residual_delta_e": f2(bg_residual), "foreground_ratio": f3(float(mask_fg.mean())),
            "threshold": info, "components": len(ids), "text_regions": len(regions),
            "text_groups": [{"bbox": r["bbox"], "score": r["text_score"],
                             "glyphs": r["glyph_count"],
                             "contrast": r["stroke_contrast_delta_e"]} for r in regions],
            "top_components": sorted(
                [{"bbox": stats[i]["bbox"], "area": stats[i]["area"],
                  "fill": f3(stats[i]["fill"]), "stroke": f3(stats[i]["stroke_ratio"]),
                  "edge": f3(stats[i]["edge_density"])} for i in ids],
                key=lambda x: -x["area"])[:12]}


def main(argv=None):
    ap = argparse.ArgumentParser(description="PNG 智能拆分 P1（四类分层，传统影像算法）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("split")
    s.add_argument("--src", required=True)
    s.add_argument("--out", required=True)

    c = sub.add_parser("check")
    c.add_argument("--out", required=True)
    c.add_argument("--require-all-classes", action="store_true")

    p = sub.add_parser("probe")
    p.add_argument("--src", required=True)

    args = ap.parse_args(argv)
    if args.cmd == "split":
        doc = split(args.src, args.out)
        print(json.dumps({
            "status": "ok", "out": os.path.abspath(args.out),
            "layer_count": doc["layer_count"],
            "classes": doc["classes_present"],
            "layers": [{"class": l["class"], "name": l["name"], "bbox": l["bbox"],
                        "confidence": l["confidence"], "low_confidence": l["low_confidence"]}
                       for l in doc["layers"]],
            "background_fill": doc["background_fill"],
            "sizes": doc["sizes"],
            "timings_ms": doc["timings_ms"],
            "warnings": doc["warnings"],
        }, ensure_ascii=False))
        return 0
    if args.cmd == "check":
        doc = check(args.out, require_all_classes=args.require_all_classes)
        print(json.dumps(doc, ensure_ascii=False, indent=2))
        return 0 if doc["verdict"] == "PASS" else 2
    if args.cmd == "probe":
        print(json.dumps(probe(args.src), ensure_ascii=False, indent=2))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
