#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# TR-002-D BUG-4D-3 取证构建脚本
#
# 交付包（FCPX Studio Pro R2.app）不带 -DTR002C_AUTOMATION 编译，
# 二进制里完全不存在 --edit-moti-auto-* / --edit-moti-{x,y,text,enabled,locked}
# 这批无人值守写盘开关，任何参数组合都无法跳过确认或自动写盘。
#
# 需要真机取证（自动写回 / 读回 / 回填判定）时，用本脚本构建取证二进制，
# 产物只落在 /tmp，不装包、不入库、不随交付物分发。
#
# 用法：
#   bash tools/tr002d/build_forensics.sh [输出目录，默认 /tmp/fcpx_auto]
# 产物：
#   <输出目录>/release/FCPXStudio
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${1:-/tmp/fcpx_auto}"

cd "$REPO_ROOT/FCPXStudioNative"
rm -rf "$OUT_DIR"
swift build -c release -Xswiftc -DTR002C_AUTOMATION \
    --build-path "$OUT_DIR" --disable-sandbox

BIN="$OUT_DIR/release/FCPXStudio"
echo "FORENSICS_BUILD=$BIN"
echo "FORENSICS_SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1) SIZE=$(stat -f%z "$BIN")"
