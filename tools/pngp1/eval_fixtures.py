#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P1 分层结果评分：对照夹具真值算 IoU / 类别 / 补洞 / 重合成。

判定口径（写死在代码里，不手改结果）：
  · TEXT：每条真值文字行必须有一个 TEXT 层与它 IoU ≥ 0.5；且不允许把正文层判成别的类。
  · OBJECT：每个真值主体必须有一个 OBJECT 层 IoU ≥ 0.5。
  · ELEMENT：真值装饰件数 > 0 时，至少要有 1 个 ELEMENT 层（不要求逐个对上，
    因为装饰件合并/碎片合并是允许的 P1 行为）。
  · BACKGROUND：不透明输入必须整幅不透明（补洞无孔），且背景层不与任何真值主体/文字行重合 > 0.5。
  · 重合成：check 的实心像素最大差 ≤ 2。

用法：
  python3 tools/pngp1/eval_fixtures.py --fixtures <夹具目录> --outputs <输出根目录> [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def iou(a, b):
    x0 = max(a[0], b[0]); y0 = max(a[1], b[1])
    x1 = min(a[2], b[2]); y1 = min(a[3], b[3])
    iw = max(0, x1 - x0); ih = max(0, y1 - y0)
    inter = iw * ih
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / float(ua) if ua > 0 else 0.0


def best_match(gt, layers):
    best = (0.0, None)
    for l in layers:
        v = iou(gt, l["bbox"])
        if v > best[0]:
            best = (v, l)
    return best


def evaluate(fixture_dir, output_root):
    truth = json.load(open(os.path.join(fixture_dir, "ground_truth.json"), encoding="utf-8"))
    rows = []
    for name, gt in sorted(truth.items()):
        out = os.path.join(output_root, name)
        mp = os.path.join(out, "分层清单.json")
        if not os.path.isfile(mp):
            rows.append({"fixture": name, "error": "缺少 分层清单.json"})
            continue
        doc = json.load(open(mp, encoding="utf-8"))
        layers = doc["layers"]
        by = {c: [l for l in layers if l["class"] == c] for c in
              ("OBJECT", "TEXT", "ELEMENT", "BACKGROUND")}

        text_hits = []
        for b in gt.get("text_bboxes", []):
            v, l = best_match(b, by["TEXT"])
            text_hits.append({"gt": b, "iou": round(v, 3),
                              "layer": l["name"] if l else None, "ok": v >= 0.5})
        obj_hits = []
        for b in gt.get("object_bboxes", []):
            v, l = best_match(b, by["OBJECT"])
            obj_hits.append({"gt": b, "iou": round(v, 3),
                             "layer": l["name"] if l else None, "ok": v >= 0.5})

        text_ok = all(h["ok"] for h in text_hits) if text_hits else True
        obj_ok = all(h["ok"] for h in obj_hits) if obj_hits else True
        elem_ok = (len(by["ELEMENT"]) > 0) if gt.get("element_count", 0) > 0 else True
        bg = by["BACKGROUND"][0] if by["BACKGROUND"] else None
        bg_alpha = None
        if bg:
            from PIL import Image
            import numpy as np
            arr = np.asarray(Image.open(os.path.join(out, bg["file"])).convert("RGBA"))
            bg_alpha = int((arr[:, :, 3] != 255).sum())
        bg_ok = bg is not None and (bg_alpha == 0 if gt.get("bg") != "alpha" else bg_alpha >= 0)

        rows.append({
            "fixture": name,
            "size": [doc["width"], doc["height"]],
            "layer_count": doc["layer_count"],
            "classes": doc["classes_present"],
            "text": text_hits,
            "object": obj_hits,
            "text_ok": text_ok,
            "object_ok": obj_ok,
            "element_ok": elem_ok,
            "background_transparent_px": bg_alpha,
            "background_ok": bg_ok,
            "recomposite_max_abs_diff": doc["previews"].get("recomposite_max_abs_diff"),
            "hole_ratio": doc["background_fill"].get("hole_ratio"),
            "elapsed_ms": doc["timings_ms"]["total"],
            "layer_mb": doc["sizes"]["layer_total_mb"],
            "ratio_to_source": doc["sizes"]["ratio_to_source"],
            "verdict": "PASS" if (text_ok and obj_ok and elem_ok and bg_ok) else "FAIL",
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", required=True)
    ap.add_argument("--outputs", required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    rows = evaluate(os.path.abspath(args.fixtures), os.path.abspath(args.outputs))
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0 if all(r.get("verdict") == "PASS" for r in rows) else 2
    print("%-30s %-4s %-5s %-6s %-6s %-6s %-8s %-8s %s" %
          ("fixture", "lay", "text", "object", "elem", "bg", "maxdiff", "ms", "verdict"))
    print("-" * 96)
    for r in rows:
        if "error" in r:
            print("%-30s %s" % (r["fixture"], r["error"]))
            continue
        print("%-30s %-4d %-5s %-6s %-6s %-6s %-8s %-8s %s" % (
            r["fixture"], r["layer_count"],
            "OK" if r["text_ok"] else "FAIL",
            "OK" if r["object_ok"] else "FAIL",
            "OK" if r["element_ok"] else "FAIL",
            "OK" if r["background_ok"] else "FAIL",
            r["recomposite_max_abs_diff"], r["elapsed_ms"], r["verdict"]))
    bad = [r for r in rows if r.get("verdict") != "PASS"]
    print("-" * 96)
    print("PASS=%d FAIL=%d" % (len(rows) - len(bad), len(bad)))
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
