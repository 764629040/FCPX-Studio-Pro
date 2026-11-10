#!/bin/zsh
# ═══════════════════════════════════════════════════════════════════════════
# TR-021 复现：ULP 量级实测 + full/slim 的 ndimage.rotate 端到端对比。
#
# 用法: tools/tr021/run_probes.sh [full_python_bundle] [out_dir]
#   默认 full_python_bundle = /tmp/tr018/full/python_bundle
#   默认 out_dir            = <repo>/reports/verify_tr021
#
# 产物: ULP实测输出.txt / ulp_stats.json / rotate对比输出.txt /
#       rotate_full.json / rotate_slim.json / rot_{full,slim}_*.npy
# 不做: 不改 .app、不重签、不写回任何文件。
# ═══════════════════════════════════════════════════════════════════════════
set -eu
set -o pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h}
FULL_BUNDLE=${1:-/tmp/tr018/full/python_bundle}
OUT=${2:-$ROOT/reports/verify_tr021}
APP="$ROOT/FCPX Studio Pro R2.app"
APP_PY="$APP/Contents/Resources/python_bundle/bin/python3"
FULL_PY="$FULL_BUNDLE/bin/python3"

[ -x "$FULL_PY" ] || { echo "FATAL: 找不到完整 bundle 的 python3: $FULL_PY" >&2; exit 2; }
[ -x "$APP_PY" ]  || { echo "FATAL: 找不到落地包 python3: $APP_PY" >&2; exit 2; }
mkdir -p "$OUT"

echo "=== 1. ULP 量级实测（完整 scipy 侧） ==="
"$FULL_PY" "$HERE/ulp_probe.py" "$OUT" 2>&1 | tee "$OUT/ULP实测输出.txt"

echo "=== 2. rotate 探针：full / slim 各跑一遍 ==="
"$FULL_PY" "$HERE/rotate_probe.py" "$OUT" full > "$OUT/rotate_full原始输出.txt"
"$APP_PY"  "$HERE/rotate_probe.py" "$OUT" slim > "$OUT/rotate_slim原始输出.txt"
echo "  full / slim JSON 已生成"

echo "=== 3. 跨 runtime 比对 ==="
"$FULL_PY" - "$OUT" <<'PY' | tee "$OUT/rotate对比输出.txt"
import json, os, sys
import numpy as np
out = sys.argv[1]
f = json.load(open(os.path.join(out, "rotate_full.json")))
s = json.load(open(os.path.join(out, "rotate_slim.json")))
print("special_importable  full=%s  slim=%s" % (f["special_importable"], s["special_importable"]))
print("slim special_error :", s.get("special_error"))
print("rotate_usable      full=%s  slim=%s" % (f["rotate_usable"], s["rotate_usable"]))
print()
for k in sorted(f["rotate"], key=float):
    a, b = f["rotate"][k], s["rotate"][k]
    print("angle %-6s  full_sha=%s  slim_sha=%s  sha_same=%s  sumΔ=%.6e" %
          (k, a["sha256"][:12], b["sha256"][:12], a["sha256"] == b["sha256"],
           b["sum"] - a["sum"]))
    tag = k.replace(".", "_")
    fa = np.load(os.path.join(out, "rot_full_%s.npy" % tag))
    fb = np.load(os.path.join(out, "rot_slim_%s.npy" % tag))
    d = np.abs(fa - fb)
    zf = int((fa[:, 0] == 0.0).sum())
    zs = int((fb[:, 0] == 0.0).sum())
    print("            不同像素 %d / %d  最大差 %.9f  平均差 %.9f  首列填0 full=%d/64 slim=%d/64" %
          (int((d != 0).sum()), d.size, float(d.max()), float(d.mean()), zf, zs))
PY

echo "=== DONE: $OUT ==="
