#!/usr/bin/env python3
"""
A-60：Swift / .app 独立指纹清单
================================
现有 `tools/round.py` 的 110 项 CONTROLLED 清单不覆盖 Swift 源码与 .app 二进制，
导致「改了哪一版 Swift」无法跨轮证明。本工具生成**独立**清单，
**不修改** round.py 的 CONTROLLED 范围（红线第 5 条）。

输出：docs/audit_inventory_native_<tag>.json
结构尽量与 audit_inventory_*.json 同构（generated_at / root / phase / count / files），
另有 native 段记录二进制架构、签名、构建时间与工具链。

用法：
    python3 tools/native_inventory.py --tag r31
"""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NATIVE_DIR = os.path.join(PROJECT_ROOT, "FCPXStudioNative")
APP_BINARY = os.path.join(PROJECT_ROOT, "FCPX Studio Pro.app", "Contents", "MacOS", "FCPXStudio")
APP_PLIST = os.path.join(PROJECT_ROOT, "FCPX Studio Pro.app", "Contents", "Info.plist")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return (p.returncode, (p.stdout or "") + (p.stderr or ""))
    except Exception as e:  # 工具缺失/超时都不应让清单生成失败
        return (-1, f"<error: {e}>")


def count_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return sum(1 for _ in f)
    except Exception:
        return None


def collect_files():
    files = {}
    missing = []
    optional_absent = []

    # 1. Swift 源码（全部 FCPXStudioNative/**/*.swift）
    for dirpath, dirnames, filenames in os.walk(NATIVE_DIR):
        dirnames[:] = sorted(d for d in dirnames if d not in (".build", "Tests"))
        for fn in sorted(filenames):
            if not fn.endswith(".swift"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, PROJECT_ROOT)
            files[rel] = {
                "sha256": sha256_file(full),
                "size": os.path.getsize(full),
                "lines": count_lines(full),
                "module_type": "swift",
            }

    # 2. SwiftPM 清单与锁定（Package.resolved 仅在有依赖时由 SwiftPM 生成，
    #    本工程零依赖 → 缺失是正常状态，不计 missing，只记 optional_absent）
    optional_absent = []
    for name, mtype in (("Package.swift", "package"), ("Package.resolved", "package-lock")):
        full = os.path.join(NATIVE_DIR, name)
        if os.path.exists(full):
            rel = os.path.relpath(full, PROJECT_ROOT)
            files[rel] = {
                "sha256": sha256_file(full),
                "size": os.path.getsize(full),
                "lines": count_lines(full),
                "module_type": mtype,
            }
        elif name == "Package.resolved":
            optional_absent.append(os.path.join("FCPXStudioNative", name))
        else:
            missing.append(os.path.join("FCPXStudioNative", name))

    # 3. 交付二进制与 Info.plist
    for full, mtype in ((APP_BINARY, "bundle-binary"), (APP_PLIST, "bundle-plist")):
        if os.path.exists(full):
            rel = os.path.relpath(full, PROJECT_ROOT)
            entry = {
                "sha256": sha256_file(full),
                "size": os.path.getsize(full),
                "mtime": datetime.fromtimestamp(os.path.getmtime(full)).strftime("%Y-%m-%d %H:%M:%S"),
                "module_type": mtype,
            }
            if mtype == "bundle-binary":
                rc, out = run(["file", "-b", full])
                entry["file"] = out.strip() if rc == 0 else None
                rc2, out2 = run(["lipo", "-archs", full])
                entry["arch"] = out2.strip() if rc2 == 0 else None
            files[rel] = entry
        else:
            missing.append(os.path.relpath(full, PROJECT_ROOT))

    return files, missing, optional_absent


def signing_info():
    if not os.path.exists(APP_BINARY):
        return {"available": False, "reason": "binary missing"}
    rc_dv, dv = run(["codesign", "-dv", "--verbose=2", APP_BINARY])
    rc_v, v = run(["codesign", "-v", APP_BINARY])
    summary = {}
    for line in dv.splitlines():
        for key in ("Identifier", "Format", "CodeDirectory", "Signature", "TeamIdentifier", "Authority"):
            if line.startswith(key + "="):
                summary[key] = line.split("=", 1)[1].strip()
    return {
        "available": True,
        "valid": rc_v == 0,
        "verify_output": v.strip().splitlines()[-1] if v.strip() else "",
        "summary": summary,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="轮次标签，如 r31")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    files, missing, optional_absent = collect_files()
    rc_swift, swift_out = run(["swift", "--version"])
    swift_version = swift_out.strip().splitlines()[0] if rc_swift == 0 and swift_out.strip() else None

    doc = {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "root": PROJECT_ROOT,
        "phase": args.tag,
        "canonical_path": PROJECT_ROOT,
        "note": "独立原生清单；与 tools/round.py 的 110 项 CONTROLLED 清单分开，不混合、不改其范围",
        "count": len(files),
        "missing": missing,
        "optional_absent": optional_absent,
        "files": files,
        "native": {
            "swift_version": swift_version,
            "swift_version_raw": swift_out.strip() if rc_swift == 0 else None,
            "macos": platform.mac_ver()[0],
            "app_bundle": "FCPX Studio Pro.app",
            "app_binary": os.path.relpath(APP_BINARY, PROJECT_ROOT),
            "build_time": files.get(os.path.relpath(APP_BINARY, PROJECT_ROOT), {}).get("mtime"),
            "signing": signing_info(),
        },
    }

    out = args.out or os.path.join(PROJECT_ROOT, "docs", f"audit_inventory_native_{args.tag}.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print(f"wrote {out} ({len(files)} files, missing={len(missing)})")
    if missing:
        print("missing:", ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
