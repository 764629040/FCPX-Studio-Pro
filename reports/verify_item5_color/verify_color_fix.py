#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""取色补「面/渐变」前后的全库对账（自证用，不动源码，口径与 MotiDocumentParser 逐行对齐）。

判定三件事：
 1. 缺口清单 `缺口清单_39层.tsv` 里的 39 层：新口径取到的色值必须与清单「面渐变首色标」一致
 2. 原本「正当空态」的层（层内没有带值填充色，或只有 轮廓/拖放阴影/外框）：新口径仍必须取不到
 3. 除这 39 层以外，全库其它文字层新旧口径结果必须逐层相同（不串色、不误命中）

用法：
  python3 verify_color_fix.py            # 打印汇总 + 39 层逐行对照
  python3 verify_color_fix.py --json out.json
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan_color as S  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
GAP_TSV = os.path.join(HERE, "缺口清单_39层.tsv")


def resolve_old(style):
    """改动前的四条路径（Face/Color → 面/颜色 → 表面/颜色 → 渐变首色标[无 面/渐变]）。"""
    face = S.child_parameter(style, ["Face"])
    if face is not None:
        h = S.rgb_hex(S.child_parameter(face, ["Color"]), ["Red"], ["Green"], ["Blue"])
        if h:
            return h, "Face/Color"
    face = S.child_parameter(style, ["面"])
    if face is not None:
        h = S.rgb_hex(S.child_parameter(face, ["颜色"]), ["红"], ["绿"], ["蓝"])
        if h:
            return h, "面/颜色"
    surface = S.child_parameter(style, ["表面"])
    if surface is not None:
        h = S.rgb_hex(S.child_parameter(surface, ["颜色"]), ["红色", "红"], ["绿色", "绿"], ["蓝色", "蓝"])
        if h:
            return h, "表面/颜色"
    hosts = [
        (S.child_parameter(style, ["表面"]), ["渐变"], ["颜色"]),
        (S.child_parameter(style, ["Face"]), ["Gradient"], ["Color"]),
        (style, ["渐变", "Gradient"], ["颜色", "Color"]),
    ]
    for host, gnames, cnames in hosts:
        grad = S.child_parameter(host, gnames)
        if grad is None:
            continue
        rgb = S.child_parameter(grad, ["RGB"])
        if rgb is None:
            continue
        stop = S.child_parameter(rgb, ["RGB1"])
        if stop is None:
            continue
        h = S.rgb_hex(S.child_parameter(stop, cnames),
                      ["红色", "Red"], ["绿色", "Green"], ["蓝色", "Blue"])
        if h:
            return h, "渐变首色标"
    return None, None


def load_gap():
    rows = {}
    with open(GAP_TSV, encoding="utf-8") as f:
        head = f.readline()
        assert head.startswith("path"), head
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4:
                continue
            path, lid, text, want = parts[0], parts[1], parts[2], parts[3]
            rows[(os.path.basename(path), str(lid))] = {"path": path, "text": text, "want": want}
    return rows


def short(path):
    p = path.replace(os.path.expanduser("~/Movies/Motion Templates.localized") + "/", "")
    return p


def main():
    gap = load_gap()
    files = []
    for r in S.ROOTS:
        for dirpath, _d, names in os.walk(r):
            for n in names:
                if n.endswith(".moti"):
                    files.append(os.path.join(dirpath, n))
    files.sort()

    hits, changed_other, still_none_gap, bad_value = [], [], [], []
    layers_scanned = 0
    layers_none_old = 0

    for fp in files:
        try:
            root = S.ET.parse(fp).getroot()
        except Exception:
            continue
        scene = root.find("scene")
        if scene is None:
            continue
        for lay, _depth, _chain in S.collect_layers(scene):
            styles = S.descendants_named(lay, "style")
            if not styles:
                continue
            layers_scanned += 1
            best_old = best_new = None
            for st in styles:
                if best_old is None:
                    best_old = resolve_old(st)
                if best_new is None:
                    best_new = S.resolve_color(st)
                if best_old and best_new:
                    break
            if best_old is None or best_old[0] is None:
                layers_none_old += 1
            key = (os.path.basename(fp), str(lay.get("id")))
            txt = S.layer_text(lay) or ""
            if key in gap:
                want = gap[key]["want"]
                if best_new[0] is None:
                    still_none_gap.append({"file": short(fp), "layer": key[1],
                                           "text": gap[key]["text"], "want": want})
                elif best_new[0].upper() == want.upper():
                    hits.append({"file": short(fp), "layer": key[1], "text": gap[key]["text"],
                                 "want": want, "got": best_new[0], "source": best_new[1]})
                else:
                    bad_value.append({"file": short(fp), "layer": key[1], "text": gap[key]["text"],
                                      "want": want, "got": best_new[0], "source": best_new[1]})
            else:
                if (best_old is None) != (best_new is None) or (
                        best_old and best_new and best_old[0] != best_new[0]):
                    changed_other.append({"file": short(fp), "layer": key[1], "text": txt[:20],
                                          "old": best_old, "new": best_new})

    print("=" * 100)
    print("全库文字层扫描：%d 层（改动前取不到色：%d 层）" % (layers_scanned, layers_none_old))
    print("缺口清单层数：%d" % len(gap))
    print("  39 层中，新口径取到且与清单一致：%d" % len(hits))
    print("  39 层中，新口径取到的值不符：%d" % len(bad_value))
    print("  39 层中，新口径仍取不到：%d" % len(still_none_gap))
    print("除这 39 层外，结果发生变化的层：%d  ← 必须为 0（不串色、不误命中）" % len(changed_other))
    print("=" * 100)
    if bad_value:
        print("\n[值不符]")
        for r in bad_value:
            print("  %-60s L%s want=%-8s got=%-8s (%s)" % (r["file"], r["layer"], r["want"], r["got"], r["source"]))
    if still_none_gap:
        print("\n[仍取不到]")
        for r in still_none_gap:
            print("  %-60s L%s want=%-8s %s" % (r["file"], r["layer"], r["want"], r["text"][:20]))
    if changed_other:
        print("\n[不该变的变了]")
        for r in changed_other[:30]:
            print("  %-60s L%s %s -> %s" % (r["file"], r["layer"], r["old"], r["new"]))
    print("\n[39 层逐条]")
    for r in hits:
        print("  OK  %-58s L%-12s %-8s %-8s %s" % (r["file"], r["layer"], r["want"], r["got"], r["source"]))

    if "--json" in sys.argv:
        i = sys.argv.index("--json")
        out = sys.argv[i + 1]
        json.dump({"layers_scanned": layers_scanned, "layers_none_before": layers_none_old,
                   "gap_total": len(gap), "hits": hits, "bad_value": bad_value,
                   "still_none": still_none_gap, "changed_other": changed_other},
                  open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print("\n-> %s" % out)

    return 0 if (not bad_value and not still_none_gap and not changed_other) else 2


if __name__ == "__main__":
    sys.exit(main())
