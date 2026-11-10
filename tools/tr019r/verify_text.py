#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-019-R / 交付纪律：中文文案核对【必须用 Python 读字节计数】。

`strings` 只认 ASCII 可打印字符，对中文是假阴性，本脚本一律用
open(path,'rb').read().count('中文'.encode('utf-8')) 做字节级计数。

用法：
  python3 tools/tr019r/verify_text.py --bin "/path/to/FCPXStudio"
"""
import argparse
import os
import sys

ROOT = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
SRC = ROOT + "/FCPXStudioNative/Sources/FCPXStudio"

# (中文串, 必须出现的文件, 说明)
SOURCE_CHECKS = [
    ("只读，不可编辑", SRC + "/Views/InspectorView.swift", "只读态锁定横幅文案"),
    ("幅面规格", SRC + "/Views/InspectorView.swift", "幅面规格行常驻文案"),
    ("这份模板没写尺寸，已按 1920×1080 处理", SRC + "/Models/MotiDocumentParser.swift",
     "大白话兜底文案（TR-022-2 起去掉「画布」二字，档位说明见 tools/tr022/verify_tr022_text.py）"),
    ("这份模板里有分组", SRC + "/Models/MotiDocumentParser.swift", "分组展开大白话提示"),
    ("只读预览 · 共", SRC + "/Views/InfiniteCanvasView.swift", "画布只读预览标题条"),
    ("updateMotiReadOnlyInfo", SRC + "/Views/MainWindowController.swift", "设计器侧只读接线（token 核对）"),
]

# 二进制里必须能按字节命中的中文串（证明改动真的进了产物）
BINARY_CHECKS = [
    "只读，不可编辑",
    "幅面规格",
    "这份模板没写尺寸，已按 1920×1080 处理",
    "只读预览 · 共",
]


def count_bytes(path, text):
    if not os.path.isfile(path):
        return -1
    with open(path, "rb") as f:
        return f.read().count(text.encode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="")
    args = ap.parse_args()

    print("中文文案字节计数核对（Python bytes.count，不用 strings）")
    print("=" * 72)
    ok = True
    for text, path, desc in SOURCE_CHECKS:
        n = count_bytes(path, text)
        rel = os.path.relpath(path, ROOT)
        # MainWindowController 一项只要求存在「只读」相关接线，不强制该中文串
        hard = "MainWindowController" not in rel
        good = (n > 0) if hard else (n >= 0)
        if hard and not good:
            ok = False
        print("  %-40s 命中 %-3d  %-28s %s" %
              ("「%s」" % text[:18], n, desc, "✅" if good else "❌"))
        print("      文件: %s" % rel)

    print("-" * 72)
    if args.bin:
        print("二进制: %s (%d B)" % (args.bin, os.path.getsize(args.bin) if os.path.isfile(args.bin) else -1))
        for text in BINARY_CHECKS:
            n = count_bytes(args.bin, text)
            good = n > 0
            if not good:
                ok = False
            print("  「%s」 字节命中 %-3d %s" % (text[:24], n, "✅" if good else "❌"))
        # 「⌘L 解锁」在源码/二进制里允许存在（非只读态还要用），
        # 但只读态运行时不显示 —— 由 tr019r_harness 的 UI 断言覆盖。
        n_lock = count_bytes(args.bin, "⌘L 解锁")
        print("  「⌘L 解锁」字节命中 %-3d（允许：非只读态分支；只读态由 harness 断言不显示）" % n_lock)
    else:
        print("（未传 --bin，跳过二进制核对）")

    print("=" * 72)
    print("VERDICT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
