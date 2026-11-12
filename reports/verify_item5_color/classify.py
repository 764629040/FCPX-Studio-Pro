#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「有文字但层内取不到色」的层按层内 style 的形状分桶，判断哪些是真缺口。"""
import json
import os
import xml.etree.ElementTree as ET
from collections import Counter

R = json.load(open("/tmp/moti_scan/scan2.json", encoding="utf-8"))
ok = [r for r in R if r.get("ok")]


def pname(el):
    n = el.get("name")
    if n is None:
        for c in list(el):
            if c.tag == "name":
                n = (c.text or "").strip()
    return n


def child_param(parent, names):
    if parent is None:
        return None
    for c in list(parent):
        if c.tag == "parameter" and pname(c) in names:
            return c
    return None


def has_children(p):
    return p is not None and any(c.tag == "parameter" for c in list(p))


buckets = Counter()
examples = {}
per_file = {}

for r in ok:
    tl = [l for l in r["per_layer"] if l["text"] and not l["color"]]
    if not tl:
        continue
    kinds = set()
    for l in tl:
        kinds.add("HAS_TEXT_NO_COLOR")
    per_file[r["path"]] = len(tl)

for path in per_file:
    root = ET.parse(path).getroot()
    layer_map = {el.get("id"): el for el in root.iter("layer")}
    r = next(x for x in ok if x["path"] == path)
    for l in r["per_layer"]:
        if not (l["text"] and not l["color"]):
            continue
        el = layer_map.get(l["id"])
        if el is None:
            buckets["LAYER_MISSING"] += 1
            continue
        styles = [s for s in el.iter("style")]
        face = child_param(styles[0], ["面", "Surface", "Face"]) if styles else None
        face_color = child_param(face, ["颜色", "Color"]) if face is not None else None
        grad = child_param(face, ["渐变", "Gradient"]) if face is not None else None
        sub = child_param(styles[0], ["表面"]) if styles else None
        top_grad = child_param(styles[0], ["渐变", "Gradient"]) if styles else None
        if not styles:
            kind = "NO_STYLE_AT_ALL"
        elif face is None:
            kind = "NO_FACE_PARAM"
        elif face_color is not None:
            kind = "FACE_HAS_COLOR(should_resolve!)"
        elif grad is not None:
            kind = "FACE_GRADIENT_UNSUPPORTED"
        elif has_children(face):
            kind = "FACE_TEXTURE_ONLY"
        else:
            kind = "FACE_EMPTY"
        buckets[kind] += 1
        examples.setdefault(kind, []).append((path.replace(os.path.expanduser("~"), "~"), l["id"], l["text"][:20]))

print("文字层取不到色的层总数 =", sum(buckets.values()))
for k, v in buckets.most_common():
    print("%-32s %4d" % (k, v))
    for e in examples[k][:4]:
        print("      ", e[0].split("/")[-1], "L-id=%s" % e[1], repr(e[2]))

print("\n─── FACE_GRADIENT_UNSUPPORTED 全部文件 ───")
seen = []
for p, lid, t in examples.get("FACE_GRADIENT_UNSUPPORTED", []):
    if p not in seen:
        seen.append(p)
for p in seen:
    print("  ", p)
print("unique_files=%d" % len(seen))
