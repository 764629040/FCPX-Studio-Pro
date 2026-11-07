#!/usr/bin/env python3
"""R23 证据脚本：扫描 ~/Movies/.../PSD婚礼字幕 完整目录清单。

输出每目录：.moti 数 / sha256[:12] / mtime / Media 文件数 / 是否引用媒体。
用法：python3 docs/r23_evidence/scan_movies.py
"""
import os
import hashlib
import glob
import re
import time

BASE = os.path.expanduser(
    "~/Movies/Motion Templates.localized/Titles.localized/PSD婚礼字幕")


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def refs_media(moti):
    try:
        txt = open(moti, "r", encoding="utf-8", errors="ignore").read()
    except Exception:
        return "?"
    return "yes" if re.search(r"reference_base|Media/|<reference", txt) else "no"


def main():
    print("SCAN_ROOT =", BASE)
    print("EXISTS =", os.path.isdir(BASE))
    print()
    print("%-34s %-5s %-14s %-17s %-6s %-8s" %
          ("DIR", "moti#", "sha256[:12]", "mtime", "Media#", "refMedia"))
    print("-" * 95)
    rows = []
    for nm in sorted(os.listdir(BASE), key=lambda s: (len(s), s)):
        d = os.path.join(BASE, nm)
        if not os.path.isdir(d):
            continue
        motis = glob.glob(os.path.join(d, "*.moti"))
        mc = len(motis)
        sh = sha(motis[0])[:12] if motis else "-"
        mt = time.strftime("%Y-%m-%d %H:%M",
                           time.localtime(os.path.getmtime(d)))
        media = os.path.join(d, "Media")
        mcount = len([n for n in os.listdir(media)
                      if not n.startswith(".")]) if os.path.isdir(media) else 0
        rm = refs_media(motis[0]) if motis else "-"
        rows.append((nm, mc, sh, mt, mcount, rm))
        print("%-34s %-5s %-14s %-17s %-6s %-8s" % (nm, mc, sh, mt, mcount, rm))
    print()
    print("TOTAL_DIRS =", len(rows))
    mvp = [r for r in rows if r[0].startswith("T0")]
    lib = [r for r in rows if r[0].isdigit()]
    print("MVP模板(T0x) = %d : %s" % (len(mvp), [r[0] for r in mvp]))
    if lib:
        print("纯数字独立库 = %d : 区间 %s..%s (共%d个)" %
              (len(lib), lib[0][0], lib[-1][0], len(lib)))
    else:
        print("纯数字独立库 = 0")
    refyes = [r[0] for r in rows if r[5] == "yes"]
    print("含媒体引用(refMedia=yes) = %d : %s" % (len(refyes), refyes))
    normal_empty = sum(1 for r in rows if r[4] == 0 and r[5] == "no")
    print("空Media且refMedia=no = %d 个（纯文本标题，空Media属正常）" % normal_empty)


if __name__ == "__main__":
    main()
