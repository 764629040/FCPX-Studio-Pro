#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-020 | PNG 多元素智能拆图层：预切 + 人工确认 + 双路导出。

三条硬约束（代码级保证，别跟我扯淡）：
  1. 原 PNG 只读，一次 open，绝不写回；commit 前后各算一次 sha256 并断言一致。
  2. 层数不由程序决定：analyze 只产出候选项；approved.json 必须由人（UI 或显式
     approve 子命令）签字，commit 严格按 approved.blocks 的条目数输出，不补不删。
  3. 透明不是白色：全程 RGBA，透明区 RGB 不参与任何均值；主色一律 alpha 加权。

子命令：
  analyze  --src P --out D           预切，产出 candidates.json + 缩略图 + 框选预览
  approve  --out D [--names ...]     把当前候选项显式写成 approved.json（人工确认记录的
                                    CLI 形式；真机证据用设计器 UI 写出的同名文件）
  commit   --src P --out D [--approved F] [--psd F]
                                     按已批准条目切块 / 写多层 PSD / 出逐层报告
  verify   --src P --psd F --approved F [--out D]
                                     回读 PSD + 走 cli_bridge.py parse 回导核对

依赖：R2.app 内置 python_bundle（PIL / numpy / scipy.ndimage / psd_tools）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import struct
import subprocess
import sys
import time
from collections import Counter, defaultdict

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

# 前景口径：alpha > 0 全部保留（实测样本 74520 px，含 alpha 1~8 的抗锯齿弱边缘）。
# 绝不把透明区当白，也绝不丢弱边缘；主色只用 alpha 加权，透明 RGB 不参与。
ALPHA_THRESHOLD = 0
SCHEMA = "tr020/v1"


# ────────────────────────────────────────────────────────────────
# 基础工具
# ────────────────────────────────────────────────────────────────
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def f1(x: float) -> float:
    """统一一位小数（实测值，不写『约』）。"""
    return round(float(x), 1)


def hex_of(rgb) -> str:
    return "#%02X%02X%02X" % tuple(int(round(v)) for v in rgb[:3])


def psd_layer_name(name: str, hex_value: str) -> str:
    """TR-022-1：PSD 层名 = 确认卡标题 + ' · #HEX'。

    · 若标题里已含该 HEX（UI 默认标题就是「图层 NN · #HEX」），原样返回，不重复拼；
    · 若标题是语义名（用户在确认窗填的「邀请函蓝」等），拼成「邀请函蓝 · #3C78FF」。
    这样设计器/psd_tools 回读时既能认人话，也带颜色定位。
    """
    n = (name or "").strip()
    if hex_value and hex_value.upper() not in n.upper():
        return f"{n} · {hex_value}" if n else hex_value
    return n if n else hex_value


def read_rgba(path: str):
    """保留 alpha。convert('RGBA') 对 RGBA 输入保留原始 RGB，绝不合成白底。"""
    with Image.open(path) as im:
        mode = im.mode
        size = im.size
        arr = np.asarray(im.convert("RGBA"))
    if arr.ndim != 3 or arr.shape[2] != 4:
        raise ValueError("不是 RGBA 图像: %s" % path)
    return arr, mode, size


def alpha_weighted_rgb(rgb: np.ndarray, alpha: np.ndarray) -> list:
    """主色：sum(RGB * a) / sum(a)。透明像素的 RGB 垃圾完全不参与。"""
    w = alpha.astype(np.float64)
    denom = w.sum()
    if denom <= 0:
        return [0.0, 0.0, 0.0]
    v = (rgb.astype(np.float64) * w[:, None]).sum(axis=0) / denom
    return [f1(x) for x in v]


def bbox_of(mask: np.ndarray) -> list:
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return [0, 0, 0, 0]
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def gap_between(a, b) -> float:
    """两个 bbox 的欧氏间隙（重叠为 0）。"""
    dx = max(0, max(a[0] - b[2], b[0] - a[2]))
    dy = max(0, max(a[1] - b[3], b[1] - a[3]))
    return math.hypot(dx, dy)


# ────────────────────────────────────────────────────────────────
# 预切
# ────────────────────────────────────────────────────────────────
def adaptive_grouping(mask, raw_lab, keep_ids, boxes, W: int, H: int, force_radius=None):
    """自适应膨胀分组：半径上限来自画布，半径取值来自「组数稳定平台」。

    为什么不按间隙聚类硬切：同一汉字的偏旁 bbox 会重叠（gap=0），相对跳变会失真。
    改为逐 r 扫描：
      - cap = clamp(round(0.02*hypot(W,H)), 4, 64) —— 画布尺度决定搜索上限；
      - 对每个 r 做 (2r+1)² 方形膨胀 + 8 邻域 label，统计覆盖原始前景像素的组数 N(r)；
      - 组内断笔画在 r 小时陆续合并，跨元素间距大时 N(r) 会出现长平台；
      - 取最长稳定平台的最小 r 作为最终半径（最小够用半径，最不容易过合并）；
      - 最终候选组之间的最小 bbox 间隙实测出来，用于过合并告警。
    force_radius 只用于「过合并告警有效性」的注入测试，不参与正常预切。
    """
    diag = math.hypot(W, H)
    shorts = sorted(min(b[2] - b[0], b[3] - b[1]) for b in boxes)
    stroke = float(np.median(shorts)) if shorts else 1.0
    cap = max(4, min(64, int(round(diag * 0.02))))
    neigh = np.ones((3, 3), dtype=bool)
    # 迭代 r 次 3×3 dilation == 一次 (2r+1)² 方形 dilation（Minkowski 和），
    # 但每步只碰 3×3 邻域，实测比逐 r 重建大核快两个数量级。
    series = []
    cur = mask.copy()
    for _ in range(1, cap + 1):
        cur = ndimage.binary_dilation(cur, structure=neigh)
        series.append(int(ndimage.label(cur, structure=neigh)[1]))

    # 最长连续平台（N 相同且长度 >= 2）；并列时取层数更多的平台（更保守）
    runs = []
    s = 0
    for i in range(1, len(series) + 1):
        if i == len(series) or series[i] != series[s]:
            runs.append((s + 1, i, series[s]))     # (r_start, r_end_exclusive, N)
            s = i
    stable = [x for x in runs if x[1] - x[0] >= 2]
    if stable:
        start, end, n = max(stable, key=lambda x: (x[1] - x[0], x[2]))
    else:
        start, end, n = (1, 2, series[0])
    r = int(force_radius) if force_radius is not None else start

    # 重放到选定半径（一遍 3×3 迭代，内存 O(一张 mask)）
    cur = mask.copy()
    for _ in range(r):
        cur = ndimage.binary_dilation(cur, structure=neigh)
    merged_lab, _ = ndimage.label(cur, structure=neigh)
    ys, xs = np.nonzero(mask)
    cid = raw_lab[ys, xs]
    gid = merged_lab[ys, xs]
    votes = defaultdict(Counter)
    for c, g in zip(cid.tolist(), gid.tolist()):
        votes[int(c)][int(g)] += 1
    comp_group = {c: counter.most_common(1)[0][0] for c, counter in votes.items()}
    keep = set(keep_ids)
    groups = defaultdict(list)
    for c, g in comp_group.items():
        if c in keep:
            groups[g].append(c)

    by_box = {i: b for i, b in zip(keep_ids, boxes)}
    group_boxes = []
    for _, ids in groups.items():
        bs = [by_box[i] for i in ids]
        group_boxes.append([min(b[0] for b in bs), min(b[1] for b in bs),
                            max(b[2] for b in bs), max(b[3] for b in bs)])
    min_between = None
    if len(group_boxes) > 1:
        min_between = min(gap_between(group_boxes[i], group_boxes[j])
                          for i in range(len(group_boxes))
                          for j in range(i + 1, len(group_boxes)))

    ad = {
        "canvas_diagonal_px": f1(diag),
        "stroke_scale_px": f1(stroke),
        "radius_search_cap_px": cap,
        "radius_series": series,
        "plateau_start_px": start,
        "plateau_end_px": end - 1,
        "plateau_length": end - start,
        "plateau_group_count": n,
        "min_gap_between_final_groups_px": (f1(min_between) if min_between is not None else None),
        "radius_px": r,
        "kernel_px": 2 * r + 1,
        "forced_radius": force_radius is not None,
        "formula": "cap=clamp(round(0.02*hypot(W,H)),4,64); "
                   "N(r)=count(label(binary_dilation(mask,(2r+1)^2)) covering mask); "
                   "r=min r of the longest stable N(r) plateau (element-gap driven, not hardcoded)",
    }
    return ad, merged_lab, groups


def make_thumb(rgba: np.ndarray, mask: np.ndarray, bbox, out_path: str, max_h: int = 96):
    x0, y0, x1, y1 = bbox
    crop = rgba[y0:y1, x0:x1].copy()
    crop[~mask[y0:y1, x0:x1]] = (0, 0, 0, 0)
    im = Image.fromarray(crop)
    if im.height > max_h:
        w = max(1, int(round(im.width * max_h / im.height)))
        im = im.resize((w, max_h), Image.LANCZOS)
    im.save(out_path)


def make_boxed_preview(rgba: np.ndarray, candidates, out_path: str):
    """带框候选总览：透明区画棋盘，每块彩色框 + 索引 + 主色，供证据核对。"""
    H, W = rgba.shape[:2]
    base = Image.new("RGBA", (W, H), (26, 28, 34, 255))
    cell = 24
    d = ImageDraw.Draw(base)
    for y in range(0, H, cell):
        for x in range(0, W, cell):
            if (x // cell + y // cell) % 2 == 0:
                d.rectangle((x, y, min(x + cell, W), min(y + cell, H)), fill=(38, 41, 49, 255))
    base.alpha_composite(Image.fromarray(rgba))
    d = ImageDraw.Draw(base)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 26)
    except OSError:
        font = ImageFont.load_default()
    for c in candidates:
        x0, y0, x1, y1 = c["bbox"]
        col = tuple(int(round(v)) for v in c["rgb"][:3])
        d.rectangle((x0 - 6, y0 - 6, x1 + 6, y1 + 6), outline=col + (255,), width=5)
        label = "#%d %s" % (c["id"], c["hex"])
        d.rectangle((x0 - 6, y0 - 44, x0 - 6 + 20 * len(label), y0 - 8), fill=(18, 18, 22, 230))
        d.text((x0, y0 - 42), label, fill=col + (255,), font=font)
    base.convert("RGB").save(out_path)


def analyze(src: str, out: str, force_radius=None) -> dict:
    t0 = time.perf_counter()
    os.makedirs(out, exist_ok=True)
    src = os.path.abspath(src)
    before = sha256_file(src)
    rgba, mode, size = read_rgba(src)
    H, W = rgba.shape[:2]
    alpha = rgba[:, :, 3]
    rgb = rgba[:, :, :3]
    mask = alpha > ALPHA_THRESHOLD
    t_read = time.perf_counter()

    # 颜色口径对比：alpha 加权 vs 朴素均值（后者被透明 RGB 垃圾污染）
    w = alpha.astype(np.float64)
    nonzero = alpha > 0
    stats = {
        "rgb_mean_alpha_weighted": alpha_weighted_rgb(rgb[mask].reshape(-1, 3),
                                                      alpha[mask].reshape(-1)),
        "rgb_mean_naive_all_pixels": [f1(x) for x in rgb.reshape(-1, 3).mean(axis=0)],
        "rgb_mean_naive_nonzero_only": [f1(x) for x in rgb[nonzero].reshape(-1, 3).mean(axis=0)],
        "transparent_rgb_mean": [f1(x) for x in rgb[~nonzero].reshape(-1, 3).mean(axis=0)]
                                  if (~nonzero).any() else None,
    }

    # ① 8 邻域连通块
    raw_lab, n_raw = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    sizes = np.bincount(raw_lab.ravel())
    noise_floor = max(16, int(round(W * H * 0.000005)))   # 1600×900 → 16，纯尺度自适应
    keep_ids = [i for i in range(1, n_raw + 1) if sizes[i] >= noise_floor]
    dropped = [i for i in range(1, n_raw + 1) if sizes[i] < noise_floor]
    slices = ndimage.find_objects(raw_lab)
    components = []
    for i in keep_ids:
        sl = slices[i - 1]
        m = (raw_lab[sl] == i) & mask[sl]
        c = alpha_weighted_rgb(rgb[sl][m].reshape(-1, 3), alpha[sl][m].reshape(-1))
        components.append({
            "id": int(i),
            "bbox": [int(sl[1].start), int(sl[0].start), int(sl[1].stop), int(sl[0].stop)],
            "pixels": int(sizes[i]),
            "rgb": c,
            "hex": hex_of(c),
        })
    t_cc = time.perf_counter()

    # ② 自适应膨胀分组（膨胀只用于分组，输出像素仍取原始 alpha mask）
    boxes = [c["bbox"] for c in components]
    ad, merged_lab, groups = adaptive_grouping(mask, raw_lab, keep_ids, boxes, W, H,
                                                force_radius=force_radius)
    r = ad["radius_px"]
    t_dil = time.perf_counter()

    # ③ 候选块：像素、颜色、bbox、缩略图、过合并告警
    by_id = {c["id"]: c for c in components}
    candidates = []
    warnings = []
    min_between = ad["min_gap_between_final_groups_px"]
    for idx, (_, comp_ids) in enumerate(sorted(groups.items(),
                                                key=lambda kv: (min(by_id[c]["bbox"][1] for c in kv[1]),
                                                                min(by_id[c]["bbox"][0] for c in kv[1]))), 1):
        comp_ids = sorted(comp_ids)
        m = np.isin(raw_lab, comp_ids) & mask
        bbox = bbox_of(m)
        c = alpha_weighted_rgb(rgb[m].reshape(-1, 3), alpha[m].reshape(-1))
        cw = []
        cols = [by_id[i]["rgb"] for i in comp_ids]
        if cols:
            spread = max(max(abs(a - b) for a, b in zip(cols[0], x)) for x in cols[1:]) if len(cols) > 1 else 0.0
            if spread > 60.0:
                cw.append("块内混入颜色差 %.1f 的笔画，疑似过度合并" % f1(spread))
        if bbox[2] - bbox[0] > W * 0.6 or bbox[3] - bbox[1] > H * 0.6:
            cw.append("候选框超过画幅 60%%，疑似过度合并")
        if min_between is not None and (2 * r) >= 0.5 * min_between:
            cw.append("膨胀直径 %d px 已接近跨组最小间距 %.1f px" % (2 * r, min_between))
        thumb = os.path.join(out, "thumb_%02d.png" % idx)
        make_thumb(rgba, m, bbox, thumb)
        candidates.append({
            "id": idx,
            "component_ids": comp_ids,
            "bbox": bbox,
            "pixels": int(m.sum()),
            "rgb": c,
            "hex": hex_of(c),
            "thumb": os.path.basename(thumb),
            "warnings": cw,
        })
    if 2 * r >= 0.5 * (min_between or float("inf")):
        warnings.append("全局：膨胀直径偏大，请把候选框与 UI 缩略图逐个核对")
    if ad["plateau_length"] < 3:
        warnings.append("全局：组数平台长度仅 %d，分组不稳定，疑似过合并或欠合并" %
                        ad["plateau_length"])
    if len(candidates) < 2 and len(components) > 1:
        warnings.append("全局：合并后只剩 1 个候选块，明显过度合并")
    t_cand = time.perf_counter()

    preview = os.path.join(out, "candidates_preview.png")
    make_boxed_preview(rgba, candidates, preview)

    after = sha256_file(src)
    if before != after:
        raise RuntimeError("原 PNG 被改写，立即中止")

    doc = {
        "schema": SCHEMA,
        "source": src,
        "source_sha256": before,
        "source_sha256_after_analyze": after,
        "source_unchanged": before == after,
        "source_bytes": os.path.getsize(src),
        "source_mode": mode,
        "width": W, "height": H,
        "alpha_threshold": ALPHA_THRESHOLD,
        "noise_floor_px": noise_floor,
        "foreground_pixels": int(mask.sum()),
        "transparent_pixels": int((~nonzero).sum()),
        "color_stats": stats,
        "raw_component_count": int(n_raw),
        "dropped_noise_component_count": len(dropped),
        "kept_component_count": len(components),
        "adaptive": ad,
        "warnings": warnings,
        "components": components,
        "candidates": candidates,
        "candidate_count": len(candidates),
        "elapsed_ms": {
            "read": f1((t_read - t0) * 1000),
            "connected_components": f1((t_cc - t_read) * 1000),
            "dilation_grouping": f1((t_dil - t_cc) * 1000),
            "candidates_export": f1((t_cand - t_dil) * 1000),
            "total": f1((time.perf_counter() - t0) * 1000),
        },
        "elapsed_s": f1(time.perf_counter() - t0),
    }
    with open(os.path.join(out, "candidates.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    return doc


# ────────────────────────────────────────────────────────────────
# 人工确认记录
# ────────────────────────────────────────────────────────────────
def approve(out: str, names=None, source="cli") -> dict:
    with open(os.path.join(out, "candidates.json"), "r", encoding="utf-8") as f:
        cand = json.load(f)
    blocks = []
    for i, c in enumerate(cand["candidates"], 1):
        nm = names[i - 1] if names and i - 1 < len(names) else "图层 %02d · %s" % (i, c["hex"])
        blocks.append({
            "name": nm,
            "component_ids": c["component_ids"],
            "hex": c["hex"],
            "rgb": c["rgb"],
            "bbox": c["bbox"],
        })
    doc = {
        "schema": SCHEMA,
        "source": cand["source"],
        "source_sha256": cand["source_sha256"],
        "approved_layer_count": len(blocks),
        "blocks": blocks,
        "operator_actions": [{"action": "approve", "source": source,
                              "note": "按预切候选项逐块确认，未自动增减层数"}],
        "confirmed_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "approval_source": source,
    }
    with open(os.path.join(out, "approved.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    return doc


# ────────────────────────────────────────────────────────────────
# 切块 + 双路导出
# ────────────────────────────────────────────────────────────────
def cut_blocks(rgba: np.ndarray, alpha: np.ndarray, mask: np.ndarray,
               raw_lab: np.ndarray, approved: dict, out: str):
    """严格按人工批准的 component_ids 切块，保留原始 alpha（含半透明边缘）。"""
    layers = []
    rgb = rgba[:, :, :3]
    for i, b in enumerate(approved["blocks"], 1):
        ids = [int(x) for x in b["component_ids"]]
        if not ids:
            raise ValueError("第 %d 个批准块没有 component_ids" % i)
        m = np.isin(raw_lab, ids) & mask
        bbox = bbox_of(m)
        x0, y0, x1, y1 = bbox
        cut = rgba[y0:y1, x0:x1].copy()
        cut[~m[y0:y1, x0:x1]] = (0, 0, 0, 0)
        png = os.path.join(out, "layer_%02d.png" % i)
        Image.fromarray(cut).save(png)
        c = alpha_weighted_rgb(rgb[m].reshape(-1, 3), alpha[m].reshape(-1))
        hv = hex_of(c)
        layers.append({
            "index": i,
            "name": b["name"],                       # 确认卡标题（用户可填语义名）
            "psd_name": psd_layer_name(b["name"], hv),  # 真正写进 PSD 的层名
            "component_ids": ids,
            "bbox": bbox,
            "pixels": int(m.sum()),
            "alpha_pixels": int(alpha[m].sum()),
            "rgb": c,
            "hex": hv,
            "png": os.path.basename(png),
            "png_bytes": os.path.getsize(png),
            "png_kb": f1(os.path.getsize(png) / 1024.0),
            "opacity": 255,
            "_cut": cut,
            "_mask": m,
        })
    return layers


def write_psd(base_rgba: np.ndarray, W: int, H: int, layers: list, psd_path: str):
    """复合多层 PSD：psd_tools 真写，中文层名走 luni Unicode tagged block。"""
    from psd_tools import PSDImage
    from psd_tools.constants import Compression
    base = Image.fromarray(np.zeros((H, W, 4), dtype=np.uint8))
    psd = PSDImage.frompil(base, compression=Compression.RLE)
    for l in layers:
        x0, y0, x1, y1 = l["bbox"]
        px = psd.create_pixel_layer(Image.fromarray(l["_cut"]),
                                    name="placeholder", top=y0, left=x0,
                                    compression=Compression.RLE, opacity=255)
        # TR-022-1：写「标题 · #HEX」，语义名进入 PSD，psd_tools 回读含中文
        px.name = l.get("psd_name") or psd_layer_name(l["name"], l["hex"])
    psd.save(psd_path)
    return psd


def commit(src: str, out: str, approved_path: str = "", psd_path: str = "") -> dict:
    # 【TR-022-4 测量口径】所有 elapsed_ms 为单次运行的墙钟时间，不取平均；
    # 分段边界：read=读盘+连通块重算；cut=按批准 ids 切块+写 layer PNG；
    # psd_write=psd_tools 建层+保存。f1() 统一保留一位小数，不写「约/基本」。
    # psd.bytes 含 PSD 头 + 合并图像数据 + 层记录；PSD 内无时间戳，同输入同实现下逐字节稳定，
    # 不同 psd_tools 版本 / 压缩参数会变动 ±0.1 KB 量级。
    t0 = time.perf_counter()
    src = os.path.abspath(src)
    os.makedirs(out, exist_ok=True)
    with open(approved_path or os.path.join(out, "approved.json"), "r", encoding="utf-8") as f:
        approved = json.load(f)
    psd_path = os.path.abspath(psd_path or os.path.join(out, "split_5layers.psd"))

    before = sha256_file(src)
    rgba, _, size = read_rgba(src)
    H, W = rgba.shape[:2]
    alpha = rgba[:, :, 3]
    mask = alpha > ALPHA_THRESHOLD
    raw_lab, _ = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    t_read = time.perf_counter()

    layers = cut_blocks(rgba, alpha, mask, raw_lab, approved, out)
    t_cut = time.perf_counter()
    write_psd(rgba, W, H, layers, psd_path)
    t_psd = time.perf_counter()

    after = sha256_file(src)
    if before != after:
        raise RuntimeError("原 PNG 被改写，立即中止")
    if before != approved.get("source_sha256", before):
        raise RuntimeError("approved.json 的源文件 sha256 与当前不符，拒绝导出")

    psd_bytes = os.path.getsize(psd_path)
    doc = {
        "schema": SCHEMA,
        "source": src,
        "source_sha256_before": before,
        "source_sha256_after": after,
        "source_unchanged": True,
        "approved_layer_count": approved["approved_layer_count"],
        "exported_layer_count": len(layers),
        "approval_source": approved.get("approval_source", "unknown"),
        "operator_actions": approved.get("operator_actions", []),
        "canvas": [W, H],
        "psd": {"path": psd_path, "bytes": psd_bytes, "mb": f1(psd_bytes / 1048576.0)},
        "layers": [{k: v for k, v in l.items() if not k.startswith("_")} for l in layers],
        "elapsed_ms": {
            "read": f1((t_read - t0) * 1000),
            "cut": f1((t_cut - t_read) * 1000),
            "psd_write": f1((t_psd - t_cut) * 1000),
            "total": f1((time.perf_counter() - t0) * 1000),
        },
        "elapsed_s": f1(time.perf_counter() - t0),
    }
    with open(os.path.join(out, "commit_report.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    return doc


# ────────────────────────────────────────────────────────────────
# 回导验证
# ────────────────────────────────────────────────────────────────
def verify(src: str, psd_path: str, approved_path: str, out: str = "") -> dict:
    from psd_tools import PSDImage
    src = os.path.abspath(src)
    psd_path = os.path.abspath(psd_path)
    with open(approved_path, "r", encoding="utf-8") as f:
        approved = json.load(f)
    before = sha256_file(src)
    rgba, _, _ = read_rgba(src)
    H, W = rgba.shape[:2]
    alpha = rgba[:, :, 3]
    mask = alpha > ALPHA_THRESHOLD
    raw_lab, _ = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))

    psd = PSDImage.open(psd_path)
    psd_layers = list(psd)
    checks = []

    def ck(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": str(detail)})

    ck("PSD 层数 = 人工批准层数", len(psd_layers) == approved["approved_layer_count"],
       "psd=%d approved=%d" % (len(psd_layers), approved["approved_layer_count"]))
    ck("PSD 画幅 = 源 PNG", tuple(psd.size) == (W, H), "%s vs (%d,%d)" % (psd.size, W, H))
    ck("源 PNG sha256 未变", before == approved.get("source_sha256"), before)

    # 逐层位置 / 不透明度 / 名称 / alpha 像素
    for i, b in enumerate(approved["blocks"]):
        if i >= len(psd_layers):
            ck("第 %d 层存在" % (i + 1), False, "PSD 层不足")
            continue
        pl = psd_layers[i]
        ids = [int(x) for x in b["component_ids"]]
        m = np.isin(raw_lab, ids) & mask
        bbox = bbox_of(m)
        got = tuple(int(v) for v in pl.bbox)
        ck("第 %d 层 bbox 对齐" % (i + 1), got == tuple(bbox), "psd=%s src=%s" % (got, bbox))
        ck("第 %d 层 opacity=255" % (i + 1), int(pl.opacity) == 255, pl.opacity)
        expect_name = psd_layer_name(b["name"], b.get("hex", ""))
        ck("第 %d 层名称 = 标题·HEX" % (i + 1), pl.name == expect_name,
           "%r vs %r" % (pl.name, expect_name))
        topil = pl.topil()
        if topil is None:
            ck("第 %d 层像素可读" % (i + 1), False, "topil=None")
            continue
        got_arr = np.asarray(topil.convert("RGBA"))
        x0, y0, x1, y1 = bbox
        expect = rgba[y0:y1, x0:x1].copy()
        expect[~m[y0:y1, x0:x1]] = (0, 0, 0, 0)
        same_alpha = bool(np.array_equal(got_arr[:, :, 3], expect[:, :, 3]))
        opaque = expect[:, :, 3] > 0
        same_rgb = bool(np.array_equal(got_arr[:, :, :3][opaque], expect[:, :, :3][opaque]))
        ck("第 %d 层 alpha 逐像素一致" % (i + 1), same_alpha, "shape=%s" % (got_arr.shape,))
        ck("第 %d 层前景 RGB 逐像素一致" % (i + 1), same_rgb, "opaque_px=%d" % int(opaque.sum()))

    # 叠回去应等于源图（各块互不重叠，逐像素复制）
    rebuilt = np.zeros_like(rgba)
    for pl in psd_layers:
        x0, y0, x1, y1 = [int(v) for v in pl.bbox]
        arr = np.asarray(pl.topil().convert("RGBA"))
        sub = rebuilt[y0:y1, x0:x1]
        opaque = arr[:, :, 3] > 0
        sub[opaque] = arr[opaque]
        rebuilt[y0:y1, x0:x1] = sub
    fg = alpha > 0
    composite_same = bool(np.array_equal(rebuilt[fg], rgba[fg]))
    ck("5 层叠回 = 源图前景逐像素", composite_same,
       "fg_px=%d" % int(fg.sum()))

    # 走真实设计器解析链（cli_bridge.py parse），验证回导后的层信息
    bridge = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                          "core", "cli_bridge.py")
    bridge_out = ""
    parsed_layers = -1
    parsed_ok = False
    if os.path.isfile(bridge):
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.dirname(os.path.dirname(bridge))
        try:
            p = subprocess.run([sys.executable, bridge, "parse", psd_path],
                               capture_output=True, text=True, timeout=120, env=env)
            bridge_out = p.stdout.strip()
            data = json.loads(bridge_out)
            parsed_layers = int(data.get("layer_count", -1))
            parsed_ok = data.get("status") == "ok" and parsed_layers == approved["approved_layer_count"]
        except Exception as e:
            bridge_out = "bridge error: %r" % (e,)
    ck("设计器 cli_bridge 回导层数一致", parsed_ok,
       "layer_count=%s status_ok=%s" % (parsed_layers, parsed_ok))

    doc = {
        "schema": SCHEMA,
        "psd": psd_path,
        "psd_bytes": os.path.getsize(psd_path),
        "psd_mb": f1(os.path.getsize(psd_path) / 1048576.0),
        "approved_layer_count": approved["approved_layer_count"],
        "psd_layer_count": len(psd_layers),
        "psd_layers": [{"name": l.name, "bbox": list(l.bbox), "opacity": int(l.opacity),
                        "visible": bool(l.visible)} for l in psd_layers],
        "bridge_layer_count": parsed_layers,
        "bridge_stdout": bridge_out[:4000],
        "checks": checks,
        "pass_count": sum(1 for c in checks if c["ok"]),
        "fail_count": sum(1 for c in checks if not c["ok"]),
        "verdict": "PASS" if all(c["ok"] for c in checks) else "FAIL",
    }
    if out:
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "verify.json"), "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
        with open(os.path.join(out, "回导验证.txt"), "w", encoding="utf-8") as f:
            f.write("TR-020 PSD 回导验证  VERDICT: %s  PASS=%d FAIL=%d\n" %
                    (doc["verdict"], doc["pass_count"], doc["fail_count"]))
            f.write("=" * 72 + "\n")
            for c in checks:
                f.write("  %s %-42s %s\n" % ("✅" if c["ok"] else "❌", c["check"], c["detail"]))
            f.write("\nPSD: %s (%d B, %s MB)\n" % (psd_path, doc["psd_bytes"], doc["psd_mb"]))
            for l in doc["psd_layers"]:
                f.write("  %-24s bbox=%-28s opacity=%d visible=%s\n" %
                        (l["name"], l["bbox"], l["opacity"], l["visible"]))
            f.write("\ncli_bridge layer_count=%s\n" % parsed_layers)
    return doc


def main():
    ap = argparse.ArgumentParser(description="TR-020 PNG 多元素智能拆图层")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("analyze")
    a.add_argument("--src", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--radius", type=int, default=None,
                   help="仅供过合并告警注入测试；正常预切不传，半径由平台搜索决定")

    b = sub.add_parser("approve")
    b.add_argument("--out", required=True)
    b.add_argument("--names", nargs="*", default=[])
    b.add_argument("--source", default="cli")

    c = sub.add_parser("commit")
    c.add_argument("--src", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--approved", default="")
    c.add_argument("--psd", default="")

    v = sub.add_parser("verify")
    v.add_argument("--src", required=True)
    v.add_argument("--psd", required=True)
    v.add_argument("--approved", required=True)
    v.add_argument("--out", default="")

    args = ap.parse_args()
    if args.cmd == "analyze":
        doc = analyze(args.src, args.out, force_radius=args.radius)
        print(json.dumps({"status": "ok", "candidate_count": doc["candidate_count"],
                          "raw_component_count": doc["raw_component_count"],
                          "radius_px": doc["adaptive"]["radius_px"],
                          "warnings": doc["warnings"],
                          "elapsed_ms": doc["elapsed_ms"]}, ensure_ascii=False))
    elif args.cmd == "approve":
        doc = approve(args.out, args.names, args.source)
        print(json.dumps({"status": "ok", "approved_layer_count": doc["approved_layer_count"]},
                         ensure_ascii=False))
    elif args.cmd == "commit":
        doc = commit(args.src, args.out, args.approved, args.psd)
        print(json.dumps({"status": "ok",
                          "exported_layer_count": doc["exported_layer_count"],
                          "psd": doc["psd"],
                          "elapsed_ms": doc["elapsed_ms"]}, ensure_ascii=False))
    elif args.cmd == "verify":
        doc = verify(args.src, args.psd, args.approved, args.out)
        print(json.dumps({"status": "ok" if doc["verdict"] == "PASS" else "fail",
                          "verdict": doc["verdict"], "pass": doc["pass_count"],
                          "fail": doc["fail_count"]}, ensure_ascii=False))
        return 0 if doc["verdict"] == "PASS" else 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
