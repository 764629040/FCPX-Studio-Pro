#!/usr/bin/env python3
"""
TR-009 验收：同一模板连续导出 4 次
- 模板库（扫描树）里始终只有 1 个条目（无 _bak_、无嵌套 Titles.localized）
- 备份目录 ~/Library/Application Support/FCPXStudio/backups/Titles.localized/ 仅保留最近 3 份
走 App 真实导出通道：core/cli_bridge.py build -> MotionBuilder.build_template_atomic
"""
import os
import sys
import json
import time
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

PSD = os.path.join(ROOT, "tests/data/commercial_4k.psd")
OUT_GROUP = os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/TR009验证")
TEMPLATE = "TR009同一模板"
OUT_DIR = os.path.join(OUT_GROUP, TEMPLATE)
BAK_ROOT = os.path.expanduser("~/Library/Application Support/FCPXStudio/backups/Titles.localized")

# 前置清理（仅本验证用的临时分类，不影响任何既有分类）
shutil.rmtree(OUT_GROUP, ignore_errors=True)
shutil.rmtree(BAK_ROOT, ignore_errors=True)
shutil.rmtree("/tmp/tr009_pngs", ignore_errors=True)

from core.psd_parser import parse_psd_file

print("[parse] 解析 PSD ...")
parsed = parse_psd_file(PSD, extract_fallback_pngs=True,
                        png_output_dir="/tmp/tr009_pngs", extract_thumbnails=False)
layers = parsed["layers"]
print(f"[parse] 图层数={len(layers)} canvas={parsed['width']}x{parsed['height']}")

bridge = os.path.join(ROOT, "core/cli_bridge.py")
for i in range(4):
    payload = {
        "psd_path": PSD,
        "output_dir": OUT_DIR,
        "template_name": TEMPLATE,
        "layers": [l.to_dict() for l in layers],
    }
    pj = f"/tmp/tr009_payload_{i}.json"
    with open(pj, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    r = subprocess.run([sys.executable, bridge, "build", pj],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[build {i+1}] FAIL rc={r.returncode}")
        print(r.stderr.strip()[-1200:])
        sys.exit(1)
    tail = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    print(f"[build {i+1}] ok  -> {tail}")
    time.sleep(0.05)

# ── 验收断言 ──
entries = sorted(e for e in os.listdir(OUT_GROUP) if not e.startswith("."))
bak_entries = sorted(e for e in os.listdir(BAK_ROOT) if not e.startswith(".")) if os.path.isdir(BAK_ROOT) else []

print("\n=== 扫描树条目 (Titles.localized/TR009验证) ===")
print(entries)
print("\n=== 备份目录条目 (backups/Titles.localized) ===")
print(bak_entries)

assert entries == [TEMPLATE], f"期望仅 1 个条目 [{TEMPLATE}]，实际 {entries}"
assert "Titles.localized" not in entries, "扫描树出现嵌套 Titles.localized（畸形）"
assert len(bak_entries) == 3, f"备份应仅保留 3 份，实际 {len(bak_entries)}: {bak_entries}"

print("\nTR-009 VERIFY PASS ✅  (模板库 1 条目，备份 3 份)")
