#!/bin/zsh
# ═══════════════════════════════════════════════════════════════════════════
# TR-019-R 一键验收：编译 probe / harness → 逐文件层数对照表 → UI harness
# 用法（cwd 任意）： zsh tools/tr019r/verify_layers.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
cd "$ROOT"
OUT="$ROOT/reports/verify_tr019r"
TMP="/tmp/tr019r"
mkdir -p "$OUT" "$TMP"

FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
echo "源文件数: $(printf '%s\n' "$FILES" | wc -l | tr -d ' ')"

echo "=== 1/5 编译 Swift probe（真调 parser） ==="
swiftc -O -j 8 ${=FILES} tools/tr019r/parse_probe.swift -o "$TMP/parse_probe" 2>&1 \
  | tee "$OUT/probe编译输出.txt"

echo "=== 2/5 编译 TR-019-R harness ==="
swiftc -O -j 8 ${=FILES} tools/tr019r/tr019r_harness.swift -o "$TMP/tr019r_harness" 2>&1 \
  | tee "$OUT/harness编译输出.txt"

echo "=== 3/5 挑选样本文件 ==="
python3 tools/tr019r/layer_count_table.py pick > "$TMP/filelist.txt"
echo "样本数: $(wc -l < "$TMP/filelist.txt" | tr -d ' ')"

echo "=== 4/5 逐文件跑 probe（逐个调用，避免 ARG_MAX） ==="
: > "$TMP/probe_out.tsv"
while IFS= read -r p; do
  "$TMP/parse_probe" "$p" >> "$TMP/probe_out.tsv"
done < "$TMP/filelist.txt"
cp "$TMP/probe_out.tsv" "$OUT/parse_probe原始输出.tsv"

echo "=== 5/5 生成逐文件对照表 + 跑 UI harness ==="
python3 tools/tr019r/layer_count_table.py report \
  --probe "$TMP/probe_out.tsv" \
  --out "$OUT/层数对照表.md" | tee "$OUT/对照表输出.txt"

"$TMP/tr019r_harness" 2>&1 | tee "$OUT/harness输出.txt"

echo "TR-019-R VERIFY DONE"
