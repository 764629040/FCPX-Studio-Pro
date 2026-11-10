#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  S3 / P1 一键验证脚本（新增 tools/s3_*，不修改任何既有文件）
#
#  只做三件事：swiftc 直编自包含 harness 到 /tmp、跑前后对比、落证据到
#  reports/verify_s3/。不编译整个 FCPXStudio 源码树、不跑 SwiftPM build、
#  不覆盖 /tmp/fcpx_wd、不起 detach 后台进程、不写大数据到外置卷。
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
OUT="$ROOT/reports/verify_s3"
TMP="/tmp/s3_verify"
cd "$ROOT"
mkdir -p "$OUT" "$TMP/data" "$TMP/l2cache"

ROUNDS="${S3_ROUNDS:-5}"
FRAMES="${S3_FRAMES:-240}"
COUNTS="${S3_COUNTS:-1000,10000}"

# ── 1. 环境元数据 ──────────────────────────────────────────────
{
  echo "S3 / P1 verification run metadata"
  echo "UTC   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "LOCAL : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "--- sw_vers ---"; sw_vers
  echo "--- uname ---"; uname -a
  echo "--- swiftc ---"; swiftc --version
  echo "--- CPU ---"
  echo "brand : $(sysctl -n machdep.cpu.brand_string)"
  echo "model : $(sysctl -n hw.model)"
  echo "ncpu  : $(sysctl -n hw.ncpu)"
  echo "memsz : $(sysctl -n hw.memsize)"
  echo "--- disk ---"; df -h /tmp "$ROOT"
  echo "--- harness compile ---"
  echo "swiftc -O -swift-version 5 FCPXStudioNative/Performance/*.swift tools/s3_harness_models.swift tools/s3_harness.swift -o /tmp/s3_verify/s3_harness"
  echo "--- probe compile ---"
  echo "swiftc -O tools/s3_vsync_probe.swift -o /tmp/s3_verify/s3_vsync_probe"
  echo "--- rounds=$ROUNDS frames=$FRAMES counts=$COUNTS ---"
} > "$OUT/run_metadata.txt"

# ── 2. 固定 seed 生成同一份数据 + 同一段轨迹（只写 /tmp）────────
python3 tools/s3_dataset_gen.py > "$OUT/dataset_gen.txt" 2>&1
cp "$TMP/data/MANIFEST.sha256" "$OUT/dataset_manifest.txt"

# ── 3. CVDisplayLink 真实刷新周期探测（失败则回退 60Hz）─────────
PERIOD="16.666667"
if swiftc -O tools/s3_vsync_probe.swift -o "$TMP/s3_vsync_probe" \
      2> "$OUT/vsync_probe_compile.txt"; then
  if "$TMP/s3_vsync_probe" > "$OUT/vsync_probe.txt" 2>&1; then
    P="$(awk -F'nominalPeriodMs=' '/nominalPeriodMs=/{split($2,a," "); print a[1]}' "$OUT/vsync_probe.txt" | head -1)"
    if [[ -n "$P" ]] && awk -v p="$P" 'BEGIN{exit !(p>4 && p<40)}'; then
      PERIOD="$P"
    fi
  fi
else
  echo "probe compile failed, using 60Hz fallback" >> "$OUT/vsync_probe.txt"
fi
echo "vsync period (ms) = $PERIOD" | tee "$OUT/period.txt"

# ── 4. swiftc 直编（仅新增组件 + harness，不依赖现有 Sources 类）──
swiftc -O -swift-version 5 \
  FCPXStudioNative/Performance/*.swift \
  tools/s3_harness_models.swift \
  tools/s3_harness.swift \
  -o "$TMP/s3_harness" 2> "$OUT/harness_compile.txt"
echo "harness binary: $TMP/s3_harness ($(stat -f%z "$TMP/s3_harness") bytes)" \
  >> "$OUT/harness_compile.txt"

# ── 5. 全量前后对比（同一份数据 / 同一段轨迹 / 同样轮次）─────────
"$TMP/s3_harness" \
  --counts "$COUNTS" \
  --rounds "$ROUNDS" \
  --frames "$FRAMES" \
  --period-ms "$PERIOD" \
  --out "$OUT" 2>&1 | tee "$OUT/raw_console.txt"

# ── 6. 由实测 CSV 绘 PNG 图表（无第三方依赖）────────────────────
python3 tools/s3_make_chart.py \
  --summary "$OUT/results_summary.csv" \
  --csv "$OUT/results.csv" \
  --out "$OUT" 2>&1 | tee "$OUT/chart_gen.txt"

echo "S3 RUN DONE -> $OUT"
