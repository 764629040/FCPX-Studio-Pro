#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-022 七条的文案 / 结构核对。

规矩（继承 TR-019-R）：
  · 中文一律用 open(path,'rb').read().count('中文'.encode('utf-8')) 计数。
    `strings` 只认 ASCII 可打印字符，对中文是假阴性，本脚本不用它。
  · 代码检索用 ripgrep；本脚本需要跟源码/产物逐条对，所以直接读字节计数。

用法：
  python3 tools/tr022/verify_tr022_text.py --bin "FCPX Studio Pro R2.app/Contents/MacOS/FCPXStudio"
"""
import argparse
import os
import sys

ROOT = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
SRC = ROOT + "/FCPXStudioNative/Sources/FCPXStudio"
PY = ROOT + "/tools/tr020"

# ---------------------------------------------------------------- TR-022-2
# 四档画布文案必须逐字存在（这是用户点验时要看到的原话）
SOURCE_2 = [
    ("画布尺寸 \\(width)×\\(height)（模板里写明的）。",
     SRC + "/Models/MotiDocumentParser.swift", "TR-022-2 档① 画布节点自带宽高"),
    ("画布尺寸 \\(width)×\\(height)（按模板里的画面设置）。",
     SRC + "/Models/MotiDocumentParser.swift", "TR-022-2 档② sceneSettings / 图层固定宽高"),
    ("这份模板没写尺寸，已按 1920×1080 处理",
     SRC + "/Models/MotiDocumentParser.swift", "TR-022-2 档④ 兜底"),
]
# 旧文案必须已经不存在（否则就是没改干净）
FORBIDDEN_2 = [
    ("按模板的场景设置", SRC + "/Models/MotiDocumentParser.swift", "TR-022-2 旧文案残留"),
    ("这份模板没写画布尺寸", SRC + "/Models/MotiDocumentParser.swift", "TR-022-2 旧兜底残留"),
]

# ---------------------------------------------------------------- TR-022-3
SOURCE_3 = [
    ("1247 个 .moti（XML 解析成功 1241）",
     SRC + "/Models/MotiDocumentParser.swift", "TR-022-3 头注释口径"),
]
FORBIDDEN_3 = [
    ("1226", SRC + "/Models/MotiDocumentParser.swift", "TR-022-3 旧分母残留"),
]

# ---------------------------------------------------------------- TR-022-7
SOURCE_7 = [
    ("removeTableColumn", SRC + "/Views/InspectorView.swift", "TR-022-7 只读态整列移除"),
    ("addTableColumn", SRC + "/Views/InspectorView.swift", "TR-022-7 退出只读态恢复"),
    ("publishColumn", SRC + "/Views/InspectorView.swift", "TR-022-7 列引用"),
]

# ---------------------------------------------------------------- TR-022-1
PY_1 = [
    ("psd_layer_name", PY + "/png_split.py", "TR-022-1 语义层名拼接函数"),
    ("psd_name", PY + "/png_split.py", "TR-022-1 层名随层条目走到写盘"),
    ("第 %d 层名称 = 标题·HEX", PY + "/png_split.py", "TR-022-1 回导校验项改名"),
]

# 二进制里必须按字节命中的中文（证明改动真的进了产物）
# 注意：这里不查「画布尺寸」四个字。Swift 对 <15 字节的插值字面量会走 small string
# 优化，把它拆成指令流里的立即数，字节不再连续，查了必然 0 命中（假阴性）。
# 真正能证明文案的是那两段后缀，长度够，落在 __TEXT,__cstring 里。
BINARY = [
    "（模板里写明的）",
    "（按模板里的画面设置）",
    "这份模板没写尺寸，已按 1920×1080 处理",
    "只读，不可编辑",
    "只读预览 · 共",
]


def count(path, text):
    if not os.path.isfile(path):
        return -1
    with open(path, "rb") as f:
        return f.read().count(text.encode("utf-8"))


def report(items, want_positive, label):
    ok = True
    print("— %s" % label)
    for text, path, desc in items:
        n = count(path, text)
        good = (n > 0) if want_positive else (n == 0)
        if not good:
            ok = False
        print("   %s %-46s 命中 %-3d  %s" % ("✅" if good else "❌",
                                             "「%s」" % text[:22], n, desc))
        print("      文件 %s" % os.path.relpath(path, ROOT))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=ROOT + "/FCPX Studio Pro R2.app/Contents/MacOS/FCPXStudio")
    args = ap.parse_args()

    print("TR-022 文案 / 结构核对（Python bytes.count，不用 strings）")
    print("=" * 78)
    ok = True
    ok &= report(SOURCE_2, True, "TR-022-2 三档文案必须逐字存在")
    ok &= report(FORBIDDEN_2, False, "TR-022-2 旧文案必须已清除")
    ok &= report(SOURCE_3, True, "TR-022-3 新口径")
    ok &= report(FORBIDDEN_3, False, "TR-022-3 旧分母必须已清除")
    ok &= report(SOURCE_7, True, "TR-022-7 只读态列移除接线")
    ok &= report(PY_1, True, "TR-022-1 PSD 语义层名")

    print("— 二进制逐串字节命中")
    if os.path.isfile(args.bin):
        print("  二进制 %s (%d B)" % (os.path.relpath(args.bin, ROOT), os.path.getsize(args.bin)))
        for text in BINARY:
            n = count(args.bin, text)
            good = n > 0
            if not good:
                ok = False
            print("   %s「%s」 命中 %-3d" % ("✅" if good else "❌", text, n))
    else:
        print("   ❌ 找不到二进制：%s" % args.bin)
        ok = False

    print("=" * 78)
    print("VERDICT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
