#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# tools/s4_install_and_sign.sh  ——  S4.1 装包 + 一次性重签
#
# 【本脚本由 S4 交付代理准备，落盘但绝不执行】
#   现场硬阻塞：R2.app (PID 96268) 与 Final Cut Pro (PID 97387) 都在运行，
#   覆盖运行中的 Mach-O 会让 App 崩。必须等用户主动退出 R2.app 后才能执行。
#   本脚本不重启 / 不退出任何 App，不动 FCPX 库，不含任何自动重启 FCPX 类功能
#   （用户 2026-11-10 已明确否决自动重启 FCPX，见 docs/项目终审报告_20261110.md 四-6）。
#
# 【装包前必须重编，不能沿用 3381096 B 的旧产物，否则 TR-012/014 修复不进包】
#   /tmp/fcpx_wd/release/FCPXStudio (3381096 B, sha256 a1f2cfd790a2d193…)
#   是 TR-013 的验收产物，只含 TR-013 的改动。S1 代理正在改 UI 源码修
#   TR-012 / TR-014，集成阶段必须重编，再把这个新产物通过 --bin 或
#   环境变量 $BUILD_BIN 传给本脚本。脚本会硬拒 3381096 B 的旧产物。
#   重编命令（参考 reports/verify_tr013/TR-013_验收证据.md）：
#     cd FCPXStudioNative && swift build -c release --build-path /tmp/fcpx_wd --disable-sandbox
#
# 【签完绝不再签；这块外置卷上 codesign 会把 FCPXStudio.cstemp 扫进
#   CodeResources 再删掉，二次签必报 a sealed resource is missing or invalid】
#   所以流程里 codesign --force --deep --sign - 只出现一次，且放在
#   find 清理 + xattr -cr 之后；后面只允许做 --verify，禁止再签。
#
# 流程（严格顺序，不可调换）：
#   0. 前置只读闸门：目标 .app 校验 / 拒绝旧包 / pgrep 检查 R2.app 已退出 /
#      二进制来源校验 / /tmp 空间校验
#   1. 备份旧二进制到 /tmp（唯一时间戳目录，不覆盖历史备份）
#   2. cp 新二进制进 Contents/MacOS/（+ chmod 755 保持可执行位）
#   3. find "$APP" \( -name "*.cstemp" -o -name "._*" -o -name ".DS_Store" \) -delete
#   4. xattr -cr "$APP"
#   5. codesign --force --deep --sign - "$APP"        ← 只签这一次
#   6. codesign --verify --deep --strict "$APP"       ← 期望 exit 0 且零输出
#
# 用法：
#   BUILD_BIN=/path/to/newly_built/FCPXStudio tools/s4_install_and_sign.sh
#   tools/s4_install_and_sign.sh --bin /path/to/newly_built/FCPXStudio
#   tools/s4_install_and_sign.sh --bin ... --dry-run
#   tools/s4_install_and_sign.sh --help
#
# 参数：
#   --bin <path>          新二进制路径；缺省取环境变量 $BUILD_BIN（必填其一）
#   --app <path>          目标 .app；缺省 $PROJECT_ROOT/"FCPX Studio Pro R2.app"
#   --dry-run             只跑只读闸门并打印将执行的命令，不写任何文件
#   --allow-tr013-bin     显式豁免 3381096 B 旧产物检查（不推荐，自担后果）
#   -h, --help            显示帮助
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 二进制来源：可传参变量，默认只读环境变量 $BUILD_BIN，绝不写死旧产物路径
BUILD_BIN="${BUILD_BIN:-}"
APP=""
DRY_RUN=0
ALLOW_TR013_BIN=0
TR013_OLD_SIZE=3381096

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "▶ $*"; }
warn() { echo "⚠️  $*" >&2; }

usage() {
    cat <<'USAGE'
用法： tools/s4_install_and_sign.sh --bin <path> [--app <path>] [--dry-run]

  --bin <path>        必填（或设环境变量 $BUILD_BIN）。必须是【本次重编】的新二进制，
                      不能沿用 /tmp/fcpx_wd/release/FCPXStudio (3381096 B) 的 TR-013 旧产物。
  --app <path>        目标 App，缺省为项目根下的 "FCPX Studio Pro R2.app"。
                      拒绝指向用户旧包 "FCPX Studio Pro.app"。
  --dry-run           只跑只读闸门 + 打印将执行的命令序列，不写任何文件。
  --allow-tr013-bin   显式豁免 3381096 B 旧产物拦截（不推荐）。
  -h, --help          显示本帮助。

⚠️  执行前置条件：用户必须【主动退出】R2.app。脚本用 pgrep 检查，进程在就直接报错退出。
⚠️  装包前必须重编，不能沿用 3381096 B 的旧产物，否则 TR-012/014 修复不进包。
⚠️  签完绝不再签；这块外置卷上 codesign 会把 FCPXStudio.cstemp 扫进
    CodeResources 再删掉，二次签必报 a sealed resource is missing or invalid。
USAGE
}

while (( $# )); do
    case "$1" in
        --bin)            shift; (( $# )) || die "--bin 缺少路径参数"; BUILD_BIN="$1" ;;
        --bin=*)          BUILD_BIN="${1#--bin=}" ;;
        --app)            shift; (( $# )) || die "--app 缺少路径参数"; APP="$1" ;;
        --app=*)          APP="${1#--app=}" ;;
        --dry-run)        DRY_RUN=1 ;;
        --allow-tr013-bin) ALLOW_TR013_BIN=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "未知参数 '$1'（用 --help 查看用法）" ;;
    esac
    shift
done

[ -n "$APP" ] || APP="$PROJECT_ROOT/FCPX Studio Pro R2.app"

# ── 0. 前置只读闸门（--dry-run 同样执行；任何一项失败都清晰报错退出）─────────
info "[闸门 0] 目标 App 与进程校验（只读）"

# 0.1 目标必须是已存在的 .app 目录
[ -d "$APP" ] || die "目标 .app 不是已存在的目录: $APP"
APP_ABS="$(cd "$APP" && pwd -P)"
APP_BASE="$(basename "$APP_ABS")"
case "$APP_BASE" in
    *.app|*.APP) ;;
    *) die "目标必须是 .app 目录（当前: $APP_BASE）" ;;
esac
APP_BASE_L="$(printf '%s' "$APP_BASE" | tr '[:upper:]' '[:lower:]')"
[ "$APP_BASE_L" != "fcpx studio pro.app" ] \
    || die "禁止覆盖用户旧包 'FCPX Studio Pro.app'（TR-009/010/011 全都没有），请改用 R2.app"

# 0.2 包结构
[ -f "$APP_ABS/Contents/Info.plist" ] || die "目标缺少 Contents/Info.plist: $APP_ABS"
[ -d "$APP_ABS/Contents/MacOS" ]      || die "目标缺少 Contents/MacOS: $APP_ABS"
EXEC_NAME="$(defaults read "$APP_ABS/Contents/Info" CFBundleExecutable 2>/dev/null || echo FCPXStudio)"
OLD_BIN="$APP_ABS/Contents/MacOS/$EXEC_NAME"
[ -f "$OLD_BIN" ] || die "目标内找不到可执行文件: $OLD_BIN"

# 0.3 【硬闸门】确认 R2.app 已退出（pgrep 检查，进程在就退出报错）
PROC_PATTERN="$APP_ABS/Contents/MacOS/$EXEC_NAME"
RUNNING="$(pgrep -fl "$PROC_PATTERN" 2>/dev/null | grep -v "^$$ " | grep -v "^$PPID " || true)"
if [ -n "$RUNNING" ]; then
    echo "❌ R2.app 仍在运行，禁止覆盖运行中的 Mach-O（会让 App 崩溃）" >&2
    echo "   匹配进程（$PROC_PATTERN）：" >&2
    printf '%s\n' "$RUNNING" | sed 's/^/     /' >&2
    echo "   请由用户【主动退出】R2.app 后重试；本脚本不会替你退出任何 App。" >&2
    exit 5
fi
info "  pgrep 检查通过：$APP_BASE 未在运行"

# 0.4 二进制来源（必填 + 合理性）
[ -n "$BUILD_BIN" ] || die "必须提供 --bin <path> 或设置环境变量 \$BUILD_BIN（装包前必须重编，不能沿用 3381096 B 的旧产物，否则 TR-012/014 修复不进包）"
[ -f "$BUILD_BIN" ] || die "源二进制不存在: $BUILD_BIN"
[ -r "$BUILD_BIN" ] || die "源二进制不可读: $BUILD_BIN"
SRC_SIZE=$(stat -f %z "$BUILD_BIN")
[ "$SRC_SIZE" -gt 0 ] || die "源二进制为空: $BUILD_BIN"
file -b "$BUILD_BIN" | grep -q "Mach-O" || die "源二进制不是 Mach-O: $BUILD_BIN ($(file -b "$BUILD_BIN"))"
case "$BUILD_BIN" in
    *.app/*) die "源二进制位于某个 .app 包内部，拒绝拿运行中/既有的包当源: $BUILD_BIN" ;;
esac

# 0.5 【重要修正】硬拒 TR-013 的 3381096 B 旧产物
if [ "$SRC_SIZE" -eq "$TR013_OLD_SIZE" ] && [ "$ALLOW_TR013_BIN" -eq 0 ]; then
    echo "❌ 拒绝装包：源二进制为 $TR013_OLD_SIZE B，正是 TR-013 的旧产物" >&2
    echo "   /tmp/fcpx_wd/release/FCPXStudio（TR-013 验收产物）不含 S1 代理正在修的" >&2
    echo "   TR-012 / TR-014 改动。装包前必须重编，不能沿用 3381096 B 的旧产物，" >&2
    echo "   否则 TR-012/014 修复不进包。" >&2
    echo "   重编：cd FCPXStudioNative && swift build -c release --build-path /tmp/fcpx_wd --disable-sandbox" >&2
    echo "   然后：--bin /tmp/fcpx_wd/release/FCPXStudio（新产物）。确需沿用请显式 --allow-tr013-bin。" >&2
    exit 6
fi
if [ "$SRC_SIZE" -eq "$TR013_OLD_SIZE" ] && [ "$ALLOW_TR013_BIN" -eq 1 ]; then
    warn "已用 --allow-tr013-bin 豁免：源二进制仍是 3381096 B 的 TR-013 旧产物，TR-012/014 修复可能不进包"
fi
info "  源二进制: $BUILD_BIN ($SRC_SIZE B)"

# 0.6 /tmp 空间（备份落 /tmp，绝不写外置卷）
TMP_AVAIL_KB=$(df -k /tmp | awk 'NR==2 {print $4}')
[ "${TMP_AVAIL_KB:-0}" -ge 51200 ] || die "/tmp 可用空间不足 50 MiB（当前 ${TMP_AVAIL_KB:-unknown} KiB），拒绝执行"
info "  /tmp 可用 ${TMP_AVAIL_KB} KiB（备份只写 /tmp，不写外置卷）"

# ── --dry-run：只打印将执行的命令，不写任何文件 ──────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "──────────────────────────────────────────────────────────────"
    echo "[--dry-run] 前置闸门全部通过。以下为将执行的命令序列（本次一条都不执行）："
    echo
    echo "# 1. 备份旧二进制到 /tmp（唯一时间戳目录，不覆盖历史备份）"
    echo "BACKUP_DIR=\$(mktemp -d /tmp/s4_install_backup.XXXXXX)"
    echo "cp -p \"$OLD_BIN\" \"\$BACKUP_DIR/${EXEC_NAME}.before_\$(date +%Y%m%d_%H%M%S)\""
    echo "#    并校验备份字节数 == 原二进制字节数"
    echo
    echo "# 2. cp 新二进制进 Contents/MacOS/ + 保持可执行位"
    echo "cp \"$BUILD_BIN\" \"$OLD_BIN\""
    echo "chmod 755 \"$OLD_BIN\""
    echo "#    并校验目标字节数 == 源字节数 ($SRC_SIZE B)，不符则从备份恢复"
    echo
    echo "# 3. 清理 codesign 临时残留 / AppleDouble / .DS_Store"
    echo "find \"$APP_ABS\" \\( -name \"*.cstemp\" -o -name \"._*\" -o -name \".DS_Store\" \\) -delete"
    echo
    echo "# 4. 清除扩展属性（否则 adhoc 签可能带上隔离属性）"
    echo "xattr -cr \"$APP_ABS\""
    echo
    echo "# 5. 只签这一次"
    echo "codesign --force --deep --sign - \"$APP_ABS\""
    echo "#    签完绝不再签；这块外置卷上 codesign 会把 FCPXStudio.cstemp 扫进"
    echo "#    CodeResources 再删掉，二次签必报 a sealed resource is missing or invalid"
    echo
    echo "# 6. 严格验签，期望 exit 0 且零输出"
    echo "codesign --verify --deep --strict \"$APP_ABS\""
    echo
    echo "[--dry-run] 未创建备份、未覆盖二进制、未删文件、未清 xattr、未签名。"
    echo "[--dry-run] 目标 App 未被改动，Exit 0。"
    exit 0
fi

# ── 幂等 / 并发保护：/tmp 原子锁，重复执行不会并发写同一个包 ────────────────
LOCK_DIR="/tmp/s4_install_and_sign.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "另一个 s4_install_and_sign 实例正在运行（锁: $LOCK_DIR）。若为残留锁请人工确认后删除该目录"
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

echo "=================================================="
echo "  S4.1 装包 + 一次性重签"
echo "  目标: $APP_ABS"
echo "  源:   $BUILD_BIN ($SRC_SIZE B)"
echo "=================================================="

# 1. 备份旧二进制到 /tmp
info "[1/6] 备份旧二进制到 /tmp"
BACKUP_DIR="$(mktemp -d /tmp/s4_install_backup.XXXXXX)"
BACKUP_FILE="$BACKUP_DIR/${EXEC_NAME}.before_$(date +%Y%m%d_%H%M%S)"
OLD_SIZE=$(stat -f %z "$OLD_BIN")
cp -p "$OLD_BIN" "$BACKUP_FILE"
BACKUP_SIZE=$(stat -f %z "$BACKUP_FILE")
[ "$BACKUP_SIZE" -eq "$OLD_SIZE" ] || die "备份校验失败（$BACKUP_SIZE != $OLD_SIZE），已中止，目标未被修改"
info "  备份完成: $BACKUP_FILE ($BACKUP_SIZE B)"

# 2. cp 新二进制进 Contents/MacOS/
info "[2/6] 换入新二进制"
cp "$BUILD_BIN" "$OLD_BIN"
chmod 755 "$OLD_BIN"
NEW_SIZE=$(stat -f %z "$OLD_BIN")
if [ "$NEW_SIZE" -ne "$SRC_SIZE" ]; then
    cp -p "$BACKUP_FILE" "$OLD_BIN"
    chmod 755 "$OLD_BIN"
    die "新二进制落盘后大小不符（$NEW_SIZE != $SRC_SIZE），已从备份恢复，未继续签名"
fi
info "  已换入: $OLD_BIN ($NEW_SIZE B)"

# 3. 清理 cstemp / ._* / .DS_Store
info "[3/6] 清理 *.cstemp / ._* / .DS_Store"
find "$APP_ABS" \( -name "*.cstemp" -o -name "._*" -o -name ".DS_Store" \) -delete

# 4. 清扩展属性
info "[4/6] xattr -cr"
xattr -cr "$APP_ABS"

# 5. 只签这一次
#    签完绝不再签；这块外置卷上 codesign 会把 FCPXStudio.cstemp 扫进
#    CodeResources 再删掉，二次签必报 a sealed resource is missing or invalid
info "[5/6] codesign --force --deep --sign - （全脚本唯一一次签名）"
codesign --force --deep --sign - "$APP_ABS"

# 6. 严格验签：期望 exit 0 且零输出
info "[6/6] codesign --verify --deep --strict （期望零输出）"
VERIFY_OUT="$(codesign --verify --deep --strict "$APP_ABS" 2>&1)" || {
    echo "❌ 严格验签失败，输出：" >&2
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/     /' >&2
    echo "   备份仍在: $BACKUP_FILE" >&2
    echo "   ⚠️ 不要二次签名（二次签必报 a sealed resource is missing or invalid），请排查后人工决策" >&2
    exit 7
}
if [ -n "$VERIFY_OUT" ]; then
    warn "严格验签 exit 0 但有输出（期望零输出）："
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/     /' >&2
fi

echo "=================================================="
echo "✅ 装包 + 一次性重签完成"
echo "   目标:       $APP_ABS"
echo "   新二进制:   $OLD_BIN ($NEW_SIZE B)"
echo "   旧二进制备份: $BACKUP_FILE"
echo "   strict 验签: exit 0 / 输出=$( [ -z "$VERIFY_OUT" ] && echo '零输出 ✅' || echo '非空 ⚠️' )"
echo "   ⚠️ 签完绝不再签。下一步由 S4.3 重建 dmg（同样要求 R2.app 已退出）。"
echo "=================================================="
