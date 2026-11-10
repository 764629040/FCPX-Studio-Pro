#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S3 / P1 图表生成器 —— 所有数字**只读** reports/verify_s3/results_summary.csv
与 results.csv，不产生、不推算、不编造任何数值。

输出 4 张 PNG：
  chart_dropped_frames.png   掉帧数（含 ±1 样本标准差误差棒）
  chart_frame_time.png       平均帧时 / p95 帧时
  chart_view_peak.png        视图实例峰值（log10 轴，柱顶标真实值）
  chart_resources.png        布局操作 / 缩略图生成 / 估算内存 三子图

每张图都带 "INDEPENDENT HARNESS - NOT APP MEASUREMENT" 水印，
防止被误读为真机 App 截图。
"""
import argparse
import csv
import math
import os

from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 660
BG = (250, 251, 253)
INK = (28, 34, 45)
MUTED = (108, 118, 134)
GRID = (222, 227, 235)
LEGACY = (214, 78, 66)     # 现状：红
S3 = (37, 132, 214)        # 新实现：蓝
ACCENT = (245, 166, 35)


def load_font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/Library/Fonts/Arial.ttf",
    ]
    for p in candidates:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def read_summary(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append({
                "dataset": int(r["dataset"]),
                "impl": r["impl"],
                "rounds": int(r["rounds"]),
                "frames": int(r["frames"]),
                "dropped": float(r["dropped_mean"]),
                "dropped_sd": float(r["dropped_sd"]),
                "avg": float(r["avg_frame_ms_mean"]),
                "avg_sd": float(r["avg_frame_ms_sd"]),
                "p95": float(r["p95_frame_ms"]),
                "views": float(r["peak_live_views"]),
                "gen": float(r["thumb_generations"]),
                "layout": float(r["layout_ops"]),
                "mem": float(r["est_peak_memory_bytes"]) / 1048576.0,
            })
    return rows


def lookup(rows):
    return {(r["dataset"], r["impl"]): r for r in rows}


def text(d, xy, s, size=16, color=INK, bold=False, anchor=None):
    d.text(xy, s, font=load_font(size, bold), fill=color, anchor=anchor)


def base(title, subtitle, out, name):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 6], fill=S3)
    text(d, (44, 30), title, 27, INK, True)
    text(d, (44, 70), subtitle, 16, MUTED)
    d.line([44, 104, W - 44, 104], fill=GRID, width=2)
    # 水印：明确不是真机截图
    text(d, (W - 44, 34), "INDEPENDENT HARNESS - NOT APP MEASUREMENT", 14, (178, 82, 72), True, anchor="ra")
    return img, d


def footer(d, note):
    d.line([44, H - 62, W - 44, H - 62], fill=GRID, width=1)
    text(d, (44, H - 50), note, 14, MUTED)
    text(d, (W - 44, H - 50), "source: results_summary.csv (measured, R=5)", 13, MUTED, anchor="ra")


def legend(d, x, y, items):
    for i, (label, color) in enumerate(items):
        xx = x + i * 210
        d.rectangle([xx, y, xx + 20, y + 14], fill=color)
        text(d, (xx + 28, y - 3), label, 15, INK)


def grouped_bars(d, groups, series, ymax, ylabel, fmt="{:.1f}", log_scale=False,
                 plot_top=150, plot_bottom=H - 100, y_ticks=None, error_key=None):
    """groups: [label]; series: [(name, color, [values]), ...]"""
    left, right = 110, W - 60
    d.line([left, plot_top, left, plot_bottom], fill=INK, width=2)
    d.line([left, plot_bottom, right, plot_bottom], fill=INK, width=2)

    def ypos(v):
        if log_scale:
            lv = math.log10(max(1.0, v + 1.0))
            lmax = math.log10(max(2.0, ymax + 1.0))
            return plot_bottom - (lv / lmax) * (plot_bottom - plot_top)
        return plot_bottom - (min(v, ymax) / ymax) * (plot_bottom - plot_top)

    if y_ticks is None:
        y_ticks = [0, ymax * 0.25, ymax * 0.5, ymax * 0.75, ymax]
    for t in y_ticks:
        yy = ypos(t)
        d.line([left, yy, right, yy], fill=GRID, width=1)
        text(d, (left - 12, yy - 9), fmt.format(t), 13, MUTED, anchor="ra")
    text(d, (right, plot_top - 34), ylabel, 15, INK, True, anchor="ra")

    gw = (right - left) / max(1, len(groups))
    bw = gw / (len(series) + 1.4)
    for gi, g in enumerate(groups):
        gx = left + gi * gw
        text(d, (gx + gw / 2, plot_bottom + 14), g, 15, INK, True, anchor="ma")
        for si, (name, color, values) in enumerate(series):
            v = values[gi]
            x0 = gx + gw / 2 - (len(series) * bw) / 2 + si * bw
            x1 = x0 + bw * 0.86
            y0 = ypos(v)
            d.rectangle([x0, y0, x1, plot_bottom], fill=color)
            d.rectangle([x0, y0, x1, y0 + 3], fill=(255, 255, 255))
            label = "{:.0f}".format(v) if v >= 10 else "{:.2f}".format(v)
            text(d, ((x0 + x1) / 2, y0 - 22), label, 15, color, True, anchor="ma")
            if error_key and error_key[si] is not None:
                sd = error_key[si][gi]
                if sd and sd > 0:
                    yerr = ypos(max(0.0, v - sd))
                    d.line([(x0 + x1) / 2, y0, (x0 + x1) / 2, yerr], fill=INK, width=2)
                    d.line([(x0 + x1) / 2 - 8, yerr, (x0 + x1) / 2 + 8, yerr], fill=INK, width=2)


def chart_dropped(rows, out):
    m = lookup(rows)
    img, d = base("DROPPED FRAMES  (lower is better)",
                  "Same dataset, same scroll track, same rounds | 60Hz vsync deadline from CVDisplayLink", out, "dropped")
    legend(d, 46, 116, [("LEGACY (before)", LEGACY), ("S3 (after)", S3)])
    groups = ["1000 items", "10000 items"]
    vals_l = [m[(1000, "legacy")]["dropped"], m[(10000, "legacy")]["dropped"]]
    vals_s = [m[(1000, "s3")]["dropped"], m[(10000, "s3")]["dropped"]]
    sd_l = [m[(1000, "legacy")]["dropped_sd"], m[(10000, "legacy")]["dropped_sd"]]
    sd_s = [m[(1000, "s3")]["dropped_sd"], m[(10000, "s3")]["dropped_sd"]]
    ymax = max(vals_l + vals_s) * 1.35 + 2
    grouped_bars(d, groups, [("L", LEGACY, vals_l), ("S", S3, vals_s)], ymax,
                 "dropped frames", fmt="{:.0f}", plot_top=165,
                 error_key=[sd_l, sd_s])
    footer(d, "dropped = sum of ceil(slip / vsync period) over frames where work exceeded the frame deadline; +/-1 sample SD")
    img.save(os.path.join(out, "chart_dropped_frames.png"))


def chart_frame_time(rows, out):
    m = lookup(rows)
    img, d = base("FRAME WORK TIME  (lower is better)",
                  "Per-frame main-thread CPU work measured with mach_absolute_time; p95 = 95th percentile", out, "frametime")
    legend(d, 46, 116, [("LEGACY avg", LEGACY), ("S3 avg", S3), ("LEGACY p95", (244, 176, 132)), ("S3 p95", (140, 196, 240))])
    groups = ["1000 items", "10000 items"]
    series = [
        ("L-avg", LEGACY, [m[(1000, "legacy")]["avg"], m[(10000, "legacy")]["avg"]]),
        ("S-avg", S3, [m[(1000, "s3")]["avg"], m[(10000, "s3")]["avg"]]),
        ("L-p95", (244, 176, 132), [m[(1000, "legacy")]["p95"], m[(10000, "legacy")]["p95"]]),
        ("S-p95", (140, 196, 240), [m[(1000, "s3")]["p95"], m[(10000, "s3")]["p95"]]),
    ]
    ymax = max(v for _, _, vs in series for v in vs) * 1.25 + 0.5
    grouped_bars(d, groups, series, ymax, "milliseconds", fmt="{:.1f}", plot_top=165)
    footer(d, "avg = mean of all frame work times; p95 = 95th percentile of the same frame samples")
    img.save(os.path.join(out, "chart_frame_time.png"))


def chart_views(rows, out):
    m = lookup(rows)
    img, d = base("PEAK LIVE CARD VIEW INSTANCES  (log scale)",
                  "Legacy keeps every created card resident; S3 recycles only visible + buffered rows", out, "views")
    legend(d, 46, 116, [("LEGACY (before)", LEGACY), ("S3 (after)", S3)])
    groups = ["1000 items", "10000 items"]
    vals_l = [m[(1000, "legacy")]["views"], m[(10000, "legacy")]["views"]]
    vals_s = [m[(1000, "s3")]["views"], m[(10000, "s3")]["views"]]
    grouped_bars(d, groups, [("L", LEGACY, vals_l), ("S", S3, vals_s)], 10000,
                 "view count (log10)", fmt="{:.0f}", log_scale=True, plot_top=165,
                 y_ticks=[0, 9, 99, 999, 9999])
    footer(d, "counted from SyntheticCard init/deinit (real Swift object lifetime), not an estimate")
    img.save(os.path.join(out, "chart_view_peak.png"))


def chart_resources(rows, out):
    m = lookup(rows)
    img, d = base("WORK & MEMORY FOOTPRINT  (log scale, lower is better)",
                  "Layout operations / thumbnail generations / estimated peak memory", out, "resources")
    legend(d, 46, 116, [("LEGACY (before)", LEGACY), ("S3 (after)", S3)])
    panels = [
        ("LAYOUT OPERATIONS (total)", "layout", "{:.0f}", 1e6),
        ("THUMBNAIL GENERATIONS (total)", "gen", "{:.0f}", 1e4),
        ("EST. PEAK MEMORY (MiB)", "mem", "{:.1f}", 4e2),
    ]
    left, right = 110, W - 60
    top, gap, ph = 150, 12, 148
    for pi, (title, key, fmt, scale) in enumerate(panels):
        t = top + pi * (ph + gap + 24)
        b = t + ph
        text(d, (44, t - 22), title, 16, INK, True)
        d.line([left, t, left, b], fill=INK, width=2)
        d.line([left, b, right, b], fill=INK, width=2)
        lmax = math.log10(scale + 1)
        for tick in [0, scale / 10000, scale / 100, scale / 10, scale]:
            yy = b - (math.log10(tick + 1) / lmax) * (b - t)
            d.line([left, yy, right, yy], fill=GRID, width=1)
            text(d, (left - 12, yy - 8), fmt.format(tick), 12, MUTED, anchor="ra")
        groups = ["1000 items", "10000 items"]
        gw = (right - left) / 2
        bw = gw / 3.4
        for gi, n in enumerate([1000, 10000]):
            gx = left + gi * gw
            text(d, (gx + gw / 2, b + 6), groups[gi], 14, INK, True, anchor="ma")
            for si, (impl, color) in enumerate([("legacy", LEGACY), ("s3", S3)]):
                v = m[(n, impl)][key]
                yy = b - (math.log10(max(0.0, v) + 1) / lmax) * (b - t)
                x0 = gx + gw / 2 - bw + si * bw
                x1 = x0 + bw * 0.86
                d.rectangle([x0, yy, x1, b], fill=color)
                label = fmt.format(v)
                text(d, ((x0 + x1) / 2, yy - 19), label, 13, color, True, anchor="ma")
    footer(d, "layout ops = per-frame frame-recompute count summed over all frames; memory is an ESTIMATE (see ACCEPTANCE.md)")
    img.save(os.path.join(out, "chart_resources.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", required=True)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rows = read_summary(a.summary)
    assert rows, "results_summary.csv empty"
    chart_dropped(rows, a.out)
    chart_frame_time(rows, a.out)
    chart_views(rows, a.out)
    chart_resources(rows, a.out)
    for f in ["chart_dropped_frames.png", "chart_frame_time.png", "chart_view_peak.png", "chart_resources.png"]:
        print("PNG %s (%d bytes)" % (f, os.path.getsize(os.path.join(a.out, f))))
    print("charts generated from %d summary rows" % len(rows))


if __name__ == "__main__":
    main()
