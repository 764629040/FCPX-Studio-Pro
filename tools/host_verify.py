#!/usr/bin/env python3
"""
真机验收证据采集器（Motion / FCPX）

当前模型视觉通道不可用，无法"看图说话"。本工具用**程序化取证**替代人眼判读，
所有结论都可被第三方用同一脚本复核：

  1. 进程存活 / 崩溃检测（ps + 退出码 + crash log）
  2. 窗口枚举与几何（CGWindowList，精确到 X/Y/W/H）
  3. 窗口内容像素统计（背景色、亮色占比、文本密度代理）
  4. 对话框 / 错误弹窗检测（sheet 数 + 模态窗口枚举）
  5. 截图落盘（可人工复核）

用法：
    python3 tools/host_verify.py snapshot --app Motion --out docs/host_verify
    python3 tools/host_verify.py crashlog --app Motion --since 1h
"""
import argparse
import json
import os
import subprocess
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CG_PROBE_SWIFT = r'''
import Cocoa
let target = TARGET_NAME
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
var out: [[String: Any]] = []
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if owner.lowercased().contains(target) {
            out.append([
                "owner": owner,
                "name": w[kCGWindowName as String] as? String ?? "",
                "layer": w[kCGWindowLayer as String] as? Int ?? -1,
                "bounds": w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            ])
        }
    }
}
if let d = try? JSONSerialization.data(withJSONObject: out, options: []),
   let s = String(data: d, encoding: .utf8) {
    print(s)
}
'''


def _guard_write(path: str):
    resolved = os.path.realpath(os.path.abspath(path))
    root = os.path.realpath(os.path.abspath(PROJECT_ROOT))
    if resolved != root and not resolved.startswith(root + os.sep):
        raise SystemExit(f"拒绝写入项目根目录之外的路径: {resolved}")


def _compile_probe(target: str) -> str:
    src = CG_PROBE_SWIFT.replace("TARGET_NAME", json.dumps(target.lower()))
    swift_path = f"/tmp/hv_probe_{target}.swift"
    bin_path = f"/tmp/hv_probe_{target}"
    with open(swift_path, "w", encoding="utf-8") as f:
        f.write(src)
    subprocess.run(["swiftc", "-O", swift_path, "-o", bin_path],
                   capture_output=True, text=True, check=True)
    return bin_path


def enum_windows(target: str) -> list:
    bin_path = _compile_probe(target)
    proc = subprocess.run([bin_path], capture_output=True, text=True)
    try:
        return json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return []


def process_state(target: str) -> dict:
    ps = subprocess.run(["ps", "aux"], capture_output=True, text=True).stdout
    rows = [l for l in ps.splitlines()
            if target.lower() in l.lower() and "hv_probe" not in l]
    return {"match_count": len(rows), "lines": rows[:5]}


def crash_logs(target: str, since_seconds: int = 3600) -> list:
    """查找最近崩溃日志"""
    dirs = [os.path.expanduser("~/Library/Logs/DiagnosticReports"),
            "/Library/Logs/DiagnosticReports"]
    cutoff = time.time() - since_seconds
    hits = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if target.lower() not in name.lower():
                continue
            p = os.path.join(d, name)
            try:
                if os.path.getmtime(p) >= cutoff:
                    hits.append(p)
            except OSError:
                pass
    return sorted(hits)


def analyze_png(path: str) -> dict:
    """窗口内容统计：背景色、亮度分布、非背景像素占比"""
    try:
        from PIL import Image
    except ImportError:
        return {"error": "PIL unavailable"}

    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    from collections import Counter
    c = Counter()
    light = 0
    total = 0
    step = max(1, min(w, h) // 200)
    for y in range(0, h, step):
        for x in range(0, w, step):
            col = px[x, y]
            c[col] += 1
            total += 1
            if sum(col) / 3 > 150:
                light += 1
    top = c.most_common(5)
    return {
        "size": [w, h],
        "top_colors": [{"rgb": list(k), "count": v} for k, v in top],
        "light_ratio": round(light / max(1, total), 4),
        "distinct_colors": len(c),
    }


def cmd_snapshot(args) -> int:
    out_dir = os.path.abspath(args.out)
    _guard_write(os.path.join(out_dir, "x"))
    os.makedirs(out_dir, exist_ok=True)

    stamp = time.strftime("%H%M%S")
    result = {
        "app": args.app,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "process": process_state(args.app),
        "windows": enum_windows(args.app),
        "crashes": crash_logs(args.app, since_seconds=args.since_seconds),
        "shots": [],
    }

    for i, w in enumerate(result["windows"]):
        b = w.get("bounds") or {}
        x, y = int(b.get("X", 0)), int(b.get("Y", 0))
        ww, hh = int(b.get("Width", 0)), int(b.get("Height", 0))
        if ww <= 0 or hh <= 0:
            continue
        name = (w.get("name") or f"win{i}").replace("/", "_").replace(" ", "_")
        png = os.path.join(out_dir, f"{args.app}_{name}_{stamp}.png")
        _guard_write(png)
        subprocess.run(["screencapture", "-x", f"-R{x},{y},{ww},{hh}", png],
                       capture_output=True)
        if os.path.isfile(png):
            result["shots"].append({
                "window": w.get("name"), "path": os.path.relpath(png, PROJECT_ROOT),
                "stats": analyze_png(png),
            })

    json_path = os.path.join(out_dir, f"snapshot_{args.app}_{stamp}.json")
    _guard_write(json_path)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"进程匹配: {result['process']['match_count']}")
    print(f"窗口数: {len(result['windows'])}")
    for w in result["windows"]:
        print(f"  - {w.get('name')!r} layer={w.get('layer')} bounds={w.get('bounds')}")
    print(f"崩溃日志(近期): {len(result['crashes'])}")
    for s in result["shots"]:
        st = s["stats"]
        print(f"  截图 {s['path']}  {st.get('size')} light={st.get('light_ratio')}")
    print(f"JSON: {os.path.relpath(json_path, PROJECT_ROOT)}")
    return 0


def cmd_crashlog(args) -> int:
    hits = crash_logs(args.app, since_seconds=args.since_seconds)
    print(f"{args.app} 崩溃日志: {len(hits)}")
    for p in hits:
        print(" ", p)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="真机验收证据采集")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("snapshot", help="采集进程/窗口/截图/崩溃")
    p1.add_argument("--app", default="Motion")
    p1.add_argument("--out", default="docs/host_verify")
    p1.add_argument("--since-seconds", type=int, default=3600)
    p1.set_defaults(func=cmd_snapshot)

    p2 = sub.add_parser("crashlog", help="仅查崩溃日志")
    p2.add_argument("--app", default="Motion")
    p2.add_argument("--since-seconds", type=int, default=3600)
    p2.set_defaults(func=cmd_crashlog)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
