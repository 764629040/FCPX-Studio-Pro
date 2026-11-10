#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-022-3：素材库 .moti 全量口径（可复算的分母）。

统计范围：~/Movies/Motion Templates.localized/Titles.localized 递归（rglob("*.moti")）。
输出：总数、XML 解析成功/失败数、失败文件名、含非 scene 父节点 layer 的文件数、最大层数文件。
并给出一行可复现命令，别人照抄即可得到同一分母。

用法：
  python3 tools/tr022/moti_inventory.py
  python3 tools/tr022/moti_inventory.py --json out.json
"""
import argparse
import json
import pathlib
import xml.etree.ElementTree as ET

TITLES = pathlib.Path.home() / "Movies/Motion Templates.localized/Titles.localized"


def nested_layer_files(files):
    """返回：(含非 scene 父节点 layer 的文件列表, 最大层数文件, 最大层数)。"""
    nested_files = []
    max_file, max_layers = None, 0
    for f in files:
        try:
            root = ET.parse(f).getroot()
        except Exception:
            continue
        total = 0
        has_non_scene_parent = False
        for parent in root.iter():
            for child in list(parent):
                if child.tag == "layer":
                    total += 1
                    if parent.tag != "scene":
                        has_non_scene_parent = True
        if has_non_scene_parent:
            nested_files.append(str(f))
        if total > max_layers:
            max_layers, max_file = total, str(f)
    return nested_files, max_file, max_layers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    files = sorted(TITLES.rglob("*.moti"))
    total = len(files)
    ok, fail = 0, []
    for f in files:
        try:
            ET.parse(f)
            ok += 1
        except Exception as e:
            fail.append({"file": f.name, "path": str(f), "error": type(e).__name__})

    nested, max_file, max_layers = nested_layer_files(files)

    print("=" * 72)
    print("TR-022-3  .moti 全量口径")
    print("=" * 72)
    print("统计范围：%s（rglob 递归）" % TITLES)
    print("可复现命令（照抄一行，得到分母）：")
    print('  python3 -c "import pathlib;'
          'print(len(list(pathlib.Path.home().joinpath('
          '\'Movies/Motion Templates.localized/Titles.localized\').rglob(\'*.moti\'))))"')
    print("-" * 72)
    print("总数 total           = %d" % total)
    print("XML 解析成功 ok      = %d" % ok)
    print("XML 解析失败 fail    = %d" % len(fail))
    for x in fail:
        print("    FAIL %s  (%s)" % (x["file"], x["error"]))
    print("含非 scene 父节点 layer 的文件 = %d" % len(nested))
    print("最大层数文件 = %s" % max_file)
    print("最大层数 = %d" % max_layers)
    print("-" * 72)
    print("一行命令（精确版）：")
    print('  python3 tools/tr022/moti_inventory.py')

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fp:
            json.dump({"total": total, "ok": ok, "fail": fail,
                       "nested_file_count": len(nested),
                       "max_file": max_file, "max_layers": max_layers},
                      fp, ensure_ascii=False, indent=2)
        print("WROTE", args.json)


if __name__ == "__main__":
    main()
