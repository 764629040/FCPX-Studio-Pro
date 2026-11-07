#!/usr/bin/env python3
"""
R24 / A-45 修复版：macOS .ips 崩溃日志扫描器

修复点（相对 R23 旧版）：
  - .ips 实际是「第 1 行 header JSON」+「第 2 行起 body JSON」两段，
    旧版对整个文本 json.loads 直接失败 → PROC/TIME/EXC/SIGNAL 全输出 '?'。
  - body 寄存器值含 NaN/Infinity（标准 json 拒绝），需先清洗再解析。
  - 异常信息在 exception.{type,signal}（无 exceptionType 键），旧版取错键。

输出：每个 .ips 的 PROC / TIME / EXC / SIGNAL / faulting 线程栈顶帧，
以及 faulting 线程是否落在「FCP 装载 Motion 模板文档」路径（OZScene/OZDocument/
FFMotionEffect/TXText/OZChannel），并 grep 原始文本查本项目模板路径标记。

用法：python3 docs/r23_evidence/scan_crashlogs.py
"""
import json
import os
import re
import glob

BASE = os.path.expanduser("~/Library/Logs/DiagnosticReports")
PROJECT_MARKERS = [
    "Motion Templates", "PSD婚礼字幕", "T01_领衔呈现", "T23_含装饰",
    "14fa354d", "领衔呈现", "含装饰",
]
TEMPLATE_LOAD_MARKERS = [
    "OZScene", "OZDocument", "FFMotionEffect", "TXTextLayout", "OZChannel",
    "OZElement", "OZSceneNode", "PCSerializerReadStream", "PCXMLReadStream",
    "FxPlug", "MVEffect",
]


def _clean(body: str) -> str:
    # macOS .ips 寄存器值可能含 NaN / Infinity，标准 json 拒绝
    return re.sub(r'\bNaN\b', 'null', re.sub(r'\b-?Infinity\b', 'null', body))


def parse_ips(path: str):
    raw = open(path, encoding='utf-8', errors='ignore').read()
    lines = raw.split('\n', 1)
    header = json.loads(lines[0])
    body = _clean(lines[1]) if len(lines) > 1 else '{}'
    try:
        b = json.loads(body)
    except Exception as e:
        return {
            "file": os.path.basename(path), "error": f"body parse fail: {e}",
            "PROC": "?", "TIME": "?", "EXC": "?", "SIGNAL": "?",
            "faulting_thread": None, "frames": [], "in_template_load": False,
            "marker_hits": [],
        }
    exc = b.get("exception", {})
    ft = b.get("faultingThread")
    threads = b.get("threads", [])
    frames = []
    if ft is not None and ft < len(threads):
        for fr in threads[ft].get("frames", []):
            frames.append(fr.get("symbol") or fr.get("name") or "??")
    markers = sorted({m for m in PROJECT_MARKERS
                     if m in raw})
    in_load = any(any(mk in f for mk in TEMPLATE_LOAD_MARKERS) for f in frames[:40])
    return {
        "file": os.path.basename(path),
        "PROC": header.get("app_name") or b.get("procName") or "?",
        "TIME": header.get("timestamp") or b.get("captureTime") or "?",
        "EXC": exc.get("type") or "?",
        "SIGNAL": exc.get("signal") or "?",
        "pid": b.get("pid"),
        "faulting_thread": ft,
        "frames": frames,
        "in_template_load": in_load,
        "marker_hits": markers,
    }


def main():
    files = sorted(glob.glob(BASE + "/Retired/Final Cut Pro-*.ips") +
                   glob.glob(BASE + "/Final Cut Pro-*.ips"))
    print(f"SCAN_ROOT = {BASE}")
    print(f"FOUND .ips = {len(files)}")
    print("=" * 100)
    for f in files:
        r = parse_ips(f)
        print(f"\n### {r['file']}")
        for k in ("PROC", "TIME", "EXC", "SIGNAL", "pid", "faulting_thread"):
            print(f"  {k:16}: {r.get(k)}")
        print(f"  in_template_load: {r['in_template_load']}")
        print(f"  project_markers : {r['marker_hits'] or 'NONE'}")
        print(f"  --- faulting thread top 18 frames ---")
        for i, fr in enumerate(r["frames"][:18]):
            tag = " <== template-load" if any(mk in fr for mk in TEMPLATE_LOAD_MARKERS) else ""
            print(f"    #{i:2d} {fr}{tag}")


if __name__ == "__main__":
    main()
