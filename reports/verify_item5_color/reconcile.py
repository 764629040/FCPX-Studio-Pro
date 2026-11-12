#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对账：层内是否存在「带值的颜色叶子」，以及官方 resolveTextColor 能否走到它。"""
import json
import os
import xml.etree.ElementTree as ET
from collections import Counter

R = json.load(open("/tmp/moti_scan/scan3.json", encoding="utf-8"))
ok = [r for r in R if r.get("ok")]

RED = {"红", "红色", "Red"}
GREEN = {"绿", "绿色", "Green"}
BLUE = {"蓝", "蓝色", "Blue"}


def pname(el):
    n = el.get("name")
    if n is None:
        for c in list(el):
            if c.tag == "name":
                n = (c.text or "").strip()
    return n


def params(parent):
    return [c for c in list(parent) if c.tag == "parameter"]


def numbered(el):
    if el is None:
        return None
    v = el.get("value")
    if v is not None and v.strip():
        return v.strip()
    for c in list(el):
        if c.tag == "curve":
            cv = c.get("value")
            if cv is not None and cv.strip():
                return cv.strip()
            break
    d = el.get("default")
    if d is not None and d.strip():
        return d.strip()
    return None


def color_leaves(style):
    """返回 [(ancestor_path, hex, has_value_channels)]，遍历 style 子树所有叫 颜色/Color 的 param"""
    out = []

    def walk(el, path):
        for c in params(el):
            nm = pname(c)
            npath = path + [nm]
            if nm in ("颜色", "Color"):
                ch = {pname(k): k for k in params(c)}
                r = next((ch[k] for k in ch if k in RED), None)
                g = next((ch[k] for k in ch if k in GREEN), None)
                b = next((ch[k] for k in ch if k in BLUE), None)
                vals = [numbered(x) if x is not None else None for x in (r, g, b)]
                if any(v is not None for v in vals):
                    hexv = "#%02X%02X%02X" % tuple(
                        int(round(max(0.0, min(1.0, float(v))) * 255)) if v is not None else 255
                        for v in vals)
                    out.append(("/".join(npath), hexv))
                else:
                    out.append(("/".join(npath), None))
            walk(c, npath)

    walk(style, [])
    return out


buckets = Counter()
gap_files = {}
for r in ok:
    tl = [l for l in r["per_layer"] if l["text"] and not l["color"]]
    if not tl:
        continue
    root = ET.parse(r["path"]).getroot()
    idmap = {}
    for el in root.iter("layer"):
        idmap[el.get("id")] = el
    for l in tl:
        el = idmap.get(l["id"])
        if el is None:
            continue
        styles = list(el.iter("style"))
        leaves = []
        for s in styles:
            leaves.extend(color_leaves(s))
        valued = [x for x in leaves if x[1]]
        if valued:
            path = valued[0][0]
            buckets["HAS_VALUED_COLOR_LEAF:" + path] += 1
            gap_files.setdefault(tuple(sorted(set(x[0] for x in valued))), []).append(
                (r["path"].replace(os.path.expanduser("~"), "~"), l["id"], l["text"][:18], valued[0][1]))
        else:
            buckets["NO_VALUED_COLOR_LEAF_IN_LAYER"] += 1

for k, v in buckets.most_common(20):
    print("%-64s %4d" % (k, v))

print("\n=== 层内有带值颜色叶子、但官方解析不到的文件 ===")
seen = set()
for paths, items in gap_files.items():
    for p, lid, t, hexv in items:
        if p in seen:
            continue
        seen.add(p)
        print("  %-72s L%-10s %-18r %s  路径=%s" % (p.split("Motion Templates.localized/")[-1], lid, t, hexv, "|".join(paths)))
print("unique_files=%d" % len(seen))
