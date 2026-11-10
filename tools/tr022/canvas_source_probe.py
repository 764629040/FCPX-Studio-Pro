#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-022-2 证据：画布尺寸到底来自模板的哪个节点。

用户口径（TR-022-2）要求文案按真实来源分三档：
  ① 画布节点自带宽高          -> 「画布尺寸 WxH（模板里写明的）」
  ② 来自场景的画面设置        -> 「画布尺寸 WxH（按模板里的画面设置）」
  ③ 来自图层固定宽高          -> 「画布尺寸 WxH（按模板里的画面设置）」
  ④ 都没有                    -> 「这份模板没写尺寸，已按 1920×1080 处理」

本脚本只做一件事：把每个 .moti 的三类来源逐项打印出来，让文案有据可依。
不改文件、不写缓存，纯只读。

用法：
  python3 tools/tr022/canvas_source_probe.py <a.moti> [<b.moti> ...]
"""
import sys
import xml.etree.ElementTree as ET


def first_int(parent, names):
    for el in parent.iter():
        for n in names:
            v = el.get(n)
            if v is None:
                continue
            try:
                return int(float(v))
            except (TypeError, ValueError):
                continue
    return None


def size_of(node, wname="width", hname="height"):
    """宽高两种写法都认：属性写（<scene width="1920">）或子节点写（<width>1920</width>）。

    Swift 侧 resolveCanvasSize 两种都试，这里保持同样的口径，避免「探针说没有、实际有」。
    """
    def pick(attr, tag):
        v = node.get(attr)
        if v not in (None, ""):
            try:
                return int(float(v))
            except ValueError:
                pass
        el = node.find(tag)
        if el is not None and (el.text or "").strip():
            try:
                return int(float(el.text.strip()))
            except ValueError:
                pass
        return None

    return pick(wname, wname), pick(hname, hname)


def probe(path):
    print("=" * 74)
    print("文件:", path)
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        print("  XML 解析失败:", e)
        return
    root = tree.getroot()
    print("  根节点:", root.tag, "version=", root.get("version"))

    # ① 根下 canvas 节点是否自带宽高
    canvases = root.findall("canvas")
    print("  ① 根下 <canvas> 节点数:", len(canvases))
    for i, c in enumerate(canvases):
        w = c.get("width")
        h = c.get("height")
        print("     canvas[%d] width=%r height=%r 子节点=%s"
              % (i, w, h, [e.tag for e in list(c)][:6]))

    # ② scene/sceneSettings/width|height
    scenes = root.findall("scene")
    print("  ② <scene> 节点数:", len(scenes))
    for i, sc in enumerate(scenes):
        for j, st in enumerate(sc.findall("sceneSettings")):
            w, h = size_of(st)
            print("     scene[%d]/sceneSettings[%d] 解析结果 width=%r height=%r" % (i, j, w, h))
            inn = st.findall("width") + st.findall("height")
            for e in inn:
                print("       子节点 <%s> 文本=%r 属性=%s" % (e.tag, (e.text or "").strip(), e.attrib))
        if not sc.findall("sceneSettings"):
            print("     scene[%d] 无 sceneSettings" % i)

    # ③ 图层固定宽度(302)/固定高度(303)
    ids = {"302": 0, "303": 0}
    samples = []
    for el in root.iter():
        i = el.get("id")
        if i in ids:
            ids[i] += 1
            if len(samples) < 4:
                samples.append((i, el.tag, (el.text or "").strip(), el.attrib))
    print("  ③ 带 id=302(固定宽度) 的节点数: %d ; id=303(固定高度): %d" % (ids["302"], ids["303"]))
    for s in samples:
        print("     样本 id=%s tag=%s text=%r attr=%s" % s)

    # 结论（与 Swift resolveCanvasSize 同序）
    verdict = "④ 都没有 -> 这份模板没写尺寸，已按 1920×1080 处理"
    for c in canvases:
        w, h = size_of(c)
        if w and h:
            verdict = "① 画布节点自带宽高 -> 模板里写明的 (%d×%d)" % (w, h)
            break
    else:
        hit = False
        for sc in scenes:
            for st in sc.findall("sceneSettings"):
                w, h = size_of(st)
                if w and h:
                    verdict = "② sceneSettings -> 按模板里的画面设置 (%d×%d)" % (w, h)
                    hit = True
                    break
            if hit:
                break
        if not hit and ids["302"] and ids["303"]:
            verdict = "③ 图层固定宽高 -> 按模板里的画面设置（来自图层 302/303）"
    print("  => 本次文案档位:", verdict)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    for p in sys.argv[1:]:
        probe(p)
    print("=" * 74)
    return 0


if __name__ == "__main__":
    sys.exit(main())
