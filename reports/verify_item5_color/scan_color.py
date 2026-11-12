#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全库 .moti 文字取色可解析性扫描（镜像 MotiDocumentParser 的取色/取层口径）

口径与源码一一对应：
  collectLayers         : scene 起深度优先，前序，任意深度（MotiDocumentParser.swift:252）
  allStyleElements      : 只在 layer 子树里找 <style>（:385-396）
  resolveTextColor      : Face/Color → 面/颜色 → 表面/颜色 → 渐变首色标（:486-528）
  rgbHex                : 三通道任一有值即可，缺省取同级 parameter 的 default（:440-457）
"""
import json
import os
import sys
import xml.etree.ElementTree as ET

ROOTS = [
    os.path.expanduser("~/Movies/Motion Templates.localized"),
    "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/build_staging",
]


def text(el):
    return (el.text or "").strip()


def attr(el, name):
    return el.get(name)


def children_named(el, name):
    return [c for c in list(el) if c.tag == name]


def descendants_named(el, name):
    return [d for d in el.iter() if d.tag == name]


def child_parameter(parent, names):
    """直接子 parameter 里按名字取第一个（name 属性或 <name> 子元素两种写法都认）"""
    if parent is None:
        return None
    for c in list(parent):
        if c.tag != "parameter":
            continue
        n = c.get("name")
        if n is None:
            sub = children_named(c, "name")
            if sub:
                n = text(sub[0])
        if n is not None and n in names:
            return c
    return None


def declared_value(el):
    """镜像 explicitValue + declaredValue：
       1) parameter 的 value 属性
       2) 子节点 <curve value="...">
       3) parameter 的 default 属性
    """
    if el is None:
        return None
    v = el.get("value")
    if v is not None and v.strip():
        try:
            return float(v.strip())
        except ValueError:
            pass
    for c in list(el):
        if c.tag == "curve":
            cv = c.get("value")
            if cv is not None and cv.strip():
                try:
                    return float(cv.strip())
                except ValueError:
                    pass
            break
    d = el.get("default")
    if d is not None and d.strip():
        try:
            return float(d.strip())
        except ValueError:
            pass
    return None


def rgb_hex(parent, red, green, blue):
    if parent is None:
        return None
    nodes = [child_parameter(parent, red), child_parameter(parent, green), child_parameter(parent, blue)]
    values = [declared_value(n) for n in nodes]
    if all(v is None for v in values):
        return None
    sibling_default = 1.0
    for p in list(parent):
        if p.tag != "parameter":
            continue
        d = p.get("default")
        if d is not None:
            try:
                sibling_default = float(d.strip())
                break
            except ValueError:
                continue
    resolved = [v if v is not None else sibling_default for v in values]

    def ch(raw):
        return int(round(max(0.0, min(1.0, raw)) * 255.0))

    return "#%02X%02X%02X" % (ch(resolved[0]), ch(resolved[1]), ch(resolved[2]))


def resolve_color(style):
    face = child_parameter(style, ["Face"])
    if face is not None:
        color = child_parameter(face, ["Color"])
        h = rgb_hex(color, ["Red"], ["Green"], ["Blue"])
        if h:
            return h, "Face/Color"
    face = child_parameter(style, ["面"])
    if face is not None:
        color = child_parameter(face, ["颜色"])
        h = rgb_hex(color, ["红"], ["绿"], ["蓝"])
        if h:
            return h, "面/颜色"
    surface = child_parameter(style, ["表面"])
    if surface is not None:
        color = child_parameter(surface, ["颜色"])
        h = rgb_hex(color, ["红色", "红"], ["绿色", "绿"], ["蓝色", "蓝"])
        if h:
            return h, "表面/颜色"
    hosts = [
        # 补「面/渐变」：全库 39 层缺口全是这条链（面(14)/渐变(17)/RGB/RGB1/颜色）。
        # 放在「表面/渐变」之前 —— 面 是 Motion 中文原生填充容器，表面 是 Surface 的译名；
        # 两者同时存在的层按「面」取，与 resolveTextColor 的新优先级一致。
        (child_parameter(style, ["面"]), ["渐变"], ["颜色"]),
        (child_parameter(style, ["表面"]), ["渐变"], ["颜色"]),
        (child_parameter(style, ["Face"]), ["Gradient"], ["Color"]),
        (style, ["渐变", "Gradient"], ["颜色", "Color"]),
    ]
    for host, gnames, cnames in hosts:
        grad = child_parameter(host, gnames)
        if grad is None:
            continue
        rgb = child_parameter(grad, ["RGB"])
        if rgb is None:
            continue
        stop = child_parameter(rgb, ["RGB1"])
        if stop is None:
            continue
        color = child_parameter(stop, cnames)
        # 通道名要同时认单字与双字：`面/渐变/.../颜色` 下是 红/绿/蓝，
        # `表面/渐变/.../颜色` 与 `Face/Gradient/.../Color` 下是 红色/Red。
        h = rgb_hex(color, ["红", "红色", "Red"], ["绿", "绿色", "Green"], ["蓝", "蓝色", "Blue"])
        if h:
            return h, "渐变首色标"
    return None, None


def collect_layers(scene):
    """前序、任意深度，返回 [(layer_el, depth, ancestor_ids)]"""
    out = []

    def walk(el, depth, chain):
        for c in list(el):
            is_layer = c.tag == "layer"
            cid = c.get("id") or ""
            cchain = chain + [("layer:" + cid)] if is_layer else chain
            if is_layer:
                out.append((c, depth, list(chain)))
            walk(c, depth + 1 if is_layer else depth, cchain)

    walk(scene, 0, [])
    return out


def param_name(el):
    n = el.get("name")
    if n is None:
        sub = children_named(el, "name")
        if sub:
            n = text(sub[0])
    return n


def descend(nodes, name, pid=None):
    """镜像 descend(roots, name:id:)：任意深度，name 命中（给了 id 则同时校验 id）"""
    out = []
    stack = list(nodes)
    while stack:
        el = stack.pop(0)
        for c in list(el):
            if c.tag == "parameter":
                if param_name(c) == name and (pid is None or c.get("id") == pid):
                    out.append(c)
            stack.append(c)
    return out


def text_content(el):
    """<text> 的文本内容，换行原样保留"""
    return "".join(el.itertext())


def layer_text(layer):
    """parseLayer 真实口径：对象(2) -> 文本(369) -> <text> 文本子节点"""
    roots = children_named(layer, "scenenode") + [layer]
    objects = descend(roots, "对象", "2")
    params = descend(objects, "文本", "369")
    for p in params:
        sub = children_named(p, "text")
        if sub:
            return text_content(sub[0]).strip()
    return ""


def has_ancestor_layer(el, parent_map):
    cur = parent_map.get(el)
    while cur is not None:
        if cur.tag == "layer":
            return True
        cur = parent_map.get(cur)
    return False


def scan(path):
    rec = {"path": path, "ok": False}
    try:
        tree = ET.parse(path)
    except Exception as e:
        rec["error"] = "XML:%s" % e
        return rec
    root = tree.getroot()
    rec["root"] = root.tag
    if root.tag != "ozml":
        rec["error"] = "root!=ozml"
        return rec
    scenes = children_named(root, "scene")
    if not scenes:
        rec["error"] = "no-scene"
        return rec

    parent_map = {c: p for p in root.iter() for c in list(p)}

    layers = []
    for sc in scenes:
        layers.extend(collect_layers(sc))

    all_styles = descendants_named(root, "style")
    outside = [s for s in all_styles if not has_ancestor_layer(s, parent_map)]
    outside_hits = []
    for s in outside:
        h, src = resolve_color(s)
        if h:
            outside_hits.append({"hex": h, "source": src})

    per_layer = []
    for idx, (el, depth, chain) in enumerate(layers):
        styles = descendants_named(el, "style")
        hit = None
        src = None
        for s in styles:
            h, so = resolve_color(s)
            if h:
                hit, src = h, so
                break
        txt = layer_text(el)
        pid = el.get("id") or ""
        per_layer.append({
            "i": idx,
            "id": pid,
            "depth": depth,
            "text": txt[:40],
            "styles": len(styles),
            "color": hit,
            "source": src,
        })

    rec.update({
        "ok": True,
        "layers": len(layers),
        "styles_total": len(all_styles),
        "styles_outside_layers": len(outside),
        "outside_color_hits": outside_hits,
        "per_layer": per_layer,
    })
    return rec


def main():
    files = []
    for r in ROOTS:
        for dirpath, _dirnames, names in os.walk(r):
            for n in names:
                if n.endswith(".moti"):
                    files.append(os.path.join(dirpath, n))
    files.sort()
    results = []
    for i, f in enumerate(files, 1):
        results.append(scan(f))
        if i % 200 == 0:
            print("  ...%d/%d" % (i, len(files)), file=sys.stderr)
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/moti_color_scan.json"
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(results, fh, ensure_ascii=False, indent=1)
    print("scanned=%d -> %s" % (len(results), out))


if __name__ == "__main__":
    main()
