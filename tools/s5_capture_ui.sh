#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  S5 / TR-012 + TR-014 真机截图取证（装包完成并启动 R2.app 之后才跑）
#
#  用途：证明「统计条」与「操作反馈条」在真机 App 界面上用户真能看见。
#        S1 代理交的 14 张图全是 AppKit 离屏渲染，真机目视这一层一直缺。
#
#  硬约束：
#    * 本脚本【不启动、不退出、不重启、不激活】任何 App，不抢 FCPX 焦点。
#      App 的启动由用户/集成方在 S5 装包完成后自行执行。
#    * 不触碰真实模板库、FCPX 缓存、任何 .app 包内容（纯截图）。
#    * 截图全部落内盘，不写外置卷（卷只剩 ~249 MiB）。
#
#  用法：
#    tools/s5_capture_ui.sh                       # 输出到默认内盘目录
#    tools/s5_capture_ui.sh /path/to/out         # 自定义输出目录
#
#  依赖：screencapture（系统自带）、swift（CoreGraphics 枚举窗口）。
#        Terminal 的 AppleScript 自动化在本机会被系统权限挡（-10004），不用它。
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

OUT_DIR="${1:-$HOME/Desktop/TR012_TR014_真机验收}"
mkdir -p "$OUT_DIR"

STAMP="$(date '+%Y%m%d_%H%M%S')"
FULL_PNG="$OUT_DIR/${STAMP}_01_全屏.png"
WIN_PNG="$OUT_DIR/${STAMP}_02_App窗口.png"
LIST_TXT="$OUT_DIR/${STAMP}_窗口枚举.txt"

echo "S5 / TR-012 + TR-014 真机截图取证  $(date '+%Y-%m-%d %H:%M:%S')"
echo "输出目录: $OUT_DIR"
echo ""

# ── 1. 枚举窗口（只读，不改任何 App 状态） ──────────────────────────────────
SWIFT_TMP="$(mktemp /tmp/s5_winlist.XXXXXX.swift)"
trap 'rm -f "$SWIFT_TMP"' EXIT
cat > "$SWIFT_TMP" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name  = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let num   = w[kCGWindowNumber as String] as? Int ?? 0
    let b     = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let h     = (b["Height"] as? Int) ?? 0
    let wd    = (b["Width"] as? Int) ?? 0
    guard layer == 0, h > 200, wd > 400 else { continue }
    if owner.contains("FCPXStudio") || owner.contains("FCPX Studio")
        || name.contains("FCPX Studio") || name.contains("资源库") {
        print("\(num)|\(owner)|\(name)|\(b["X"] as? Int ?? 0),\(b["Y"] as? Int ?? 0),\(wd),\(h)")
    }
}
SWIFT

swift "$SWIFT_TMP" 2>/dev/null | tee "$LIST_TXT" || true
echo ""

# ── 2. 全屏截图（保底证据，一定能拿到） ─────────────────────────────────────
echo "[1/2] 全屏截图"
if screencapture -x "$FULL_PNG" 2>/dev/null; then
    echo "  OK: $FULL_PNG ($(stat -f%z "$FULL_PNG") B)"
else
    echo "  ❌ 全屏截图失败（检查 屏幕录制 权限）" >&2
    exit 2
fi

# ── 3. 按窗口 ID 裁 App 窗口（窗口不在当前 Space 时可能失败，回退全屏） ──────
WID="$(head -1 "$LIST_TXT" 2>/dev/null | cut -d'|' -f1)"
echo "[2/2] App 窗口截图"
if [ -n "$WID" ] && [ "$WID" -gt 0 ] 2>/dev/null; then
    if screencapture -x -o -l "$WID" "$WIN_PNG" 2>/dev/null; then
        echo "  OK: $WIN_PNG (windowID=$WID, $(stat -f%z "$WIN_PNG") B)"
    else
        echo "  ⚠️  窗口 $WID 截图失败（可能不在当前 Space），仅保留全屏图" >&2
        cp "$FULL_PNG" "$WIN_PNG"
    fi
else
    echo "  ⚠️  未枚举到 App 窗口（App 是否已启动并在当前 Space？），仅保留全屏图" >&2
    cp "$FULL_PNG" "$WIN_PNG"
fi

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "取证完成。验收时需人工在图里确认两处："
echo "  ① 统计条「共 280 套（已启用 279 / 已休眠 1）」或「280 / 0」——TR-012"
echo "  ② 统计条下方独立一行的操作反馈文字（actionFeedbackLabel）——TR-014"
echo "本脚本不代替人工判读，不修改任何 App 状态。"
echo "真机未启动时本脚本只会拿到桌面全屏图，不能算 TR-012/014 闭环证据。"
