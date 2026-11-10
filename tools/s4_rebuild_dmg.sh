#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# tools/s4_rebuild_dmg.sh  ——  S4.3 重建分发镜像
#
# 【本脚本由 S4 交付代理准备，落盘但绝不执行】
#   现场硬阻塞：R2.app (PID 96268) 与 Final Cut Pro (PID 97387) 都在运行。
#   S4.3 与 S4.1 一样，要求用户【主动退出 R2.app 后】才可执行。
#   本脚本不重启 / 不退出任何 App，不动 FCPX 库，不含自动重启 FCPX 类功能。
#
# 【现有镜像已过期，不能对外发】
#   FCPX_Studio_Pro_v1.0.dmg = 69899130 B (≈66.7 MiB)，mtime 2026-11-08 02:05，
#   内容与当前源码/当前 R2.app 不一致（TR-009/010/011/013 等修复都不在里面），
#   谁拿它安装装到的就是旧版本。必须重建。
#
# 【外置卷只剩 ~255 MiB（df: 255Mi / 100%），临时文件绝不写外置卷】
#   R2.app 本体 146M，压缩 dmg 约 67M。所有中间产物（stage 目录、
#   临时 dmg、挂载点、旧 dmg 备份）一律写 /tmp（系统卷可用 ~14 Gi）。
#   默认行为：构建中间产物在 /tmp，校验通过后【并列拷贝到内盘固定目录】，
#   绝不写项目根 / 外置卷。--publish 指向外置卷一律拒绝；--replace 已禁用
#   （等用户定完「唯一可用包」后再重建，不许覆盖已过期的 v1.0.dmg）。
#
# 流程：
#   0. 前置只读闸门：R2.app 已退出(pgrep) / 目标 .app 校验 / /tmp 空间 / 旧 dmg 记账
#   1. 在 /tmp 建 stage 目录，cp -R 当前 R2.app 进去（不写外置卷）
#   2. hdiutil create -srcfolder stage -format UDZO  → 输出到 /tmp 的新版本号 dmg
#   3. 校验体积 + 挂载校验内容（可执行文件存在/与源一致/严格验签）
#   4. 默认「并列新版本号」：产物固定落在内盘 DIST_DIR；
#      --publish <dir> 可另指定内盘目录；--replace 已禁用（等用户定唯一包）
#
# 用法：
#   tools/s4_rebuild_dmg.sh --dry-run
#   tools/s4_rebuild_dmg.sh --version v1.1
#   tools/s4_rebuild_dmg.sh --version v1.1 --publish /path/to/dist
#   （--replace 已禁用：等用户定完唯一可用包再重建）
#   tools/s4_rebuild_dmg.sh --help
#
# 参数：
#   --app <path>        源 .app；缺省 $PROJECT_ROOT/"FCPX Studio Pro R2.app"
#   --version <ver>     新版本号；缺省 v1.1（绝不覆盖 v1.0）
#   --publish <dir>     另指定输出目录；【仅内盘】，指向外置卷直接报错
#   --replace           【已禁用】等用户定完唯一可用包，本脚本不再覆盖旧镜像
#   --force             允许覆盖已存在的输出 dmg（默认拒绝，幂等保护）
#   --dry-run           只跑只读闸门 + 打印命令序列，不写任何文件、不挂载
#   -h, --help          显示帮助
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP=""
VERSION="v1.1"
PUBLISH_DIR=""
FORCE=0
DRY_RUN=0
OLD_DMG="$PROJECT_ROOT/FCPX_Studio_Pro_v1.0.dmg"
# S4-残留：dmg 最终产物固定落在内盘（系统卷），绝不写项目根 / 外置卷。
# 可用环境变量 S4_DIST_DIR 覆盖；等用户定完「唯一可用包」后才执行重建。
DIST_DIR="${S4_DIST_DIR:-$HOME/Desktop/FCPX_Studio_Pro_Dist}"

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "▶ $*"; }
warn() { echo "⚠️  $*" >&2; }

usage() {
    cat <<'USAGE'
用法： tools/s4_rebuild_dmg.sh [--version <ver>] [--publish <dir>] [--force]
                              [--force] [--dry-run]

  --app <path>       源 .app，缺省为项目根下的 "FCPX Studio Pro R2.app"。
  --version <ver>    新版本号，缺省 v1.1。现有 v1.0.dmg 已过期，绝不覆盖它。
  --publish <dir>    另指定输出目录【仅内盘】；指向外置卷直接报错。
  --replace          【已禁用】等用户定完唯一可用包，不再覆盖旧镜像。
  --force            允许覆盖已存在的输出 dmg（默认拒绝）。
  --dry-run          只跑只读闸门 + 打印命令序列，不写文件、不挂载、不签名。
  -h, --help         显示本帮助。

⚠️  执行前置条件：用户必须【主动退出】R2.app（pgrep 检查，进程在就报错退出）。
⚠️  现有 FCPX_Studio_Pro_v1.0.dmg（69899130 B / 2026-11-08 02:05）已过期，不能对外发。
⚠️  外置卷只剩 ~249 MiB：stage / 临时 dmg / 挂载点全部写 /tmp，
    校验通过后产物【并列拷贝到内盘】$HOME/Desktop/FCPX_Studio_Pro_Dist，
    不往外置卷写任何大文件；--publish 指向外置卷会被硬拒。
USAGE
}

while (( $# )); do
    case "$1" in
        --app)        shift; (( $# )) || die "--app 缺少路径参数"; APP="$1" ;;
        --app=*)      APP="${1#--app=}" ;;
        --version)    shift; (( $# )) || die "--version 缺少参数"; VERSION="$1" ;;
        --version=*)  VERSION="${1#--version=}" ;;
        --publish)    shift; (( $# )) || die "--publish 缺少目录参数"; PUBLISH_DIR="$1" ;;
        --publish=*)  PUBLISH_DIR="${1#--publish=}" ;;
        --replace)    die "--replace 已禁用：等用户定完唯一可用包再重建；产物固定内盘 ${DIST_DIR}，不覆盖外置卷上的旧 dmg" ;;
        --force)      FORCE=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "未知参数 '$1'（用 --help 查看用法）" ;;
    esac
    shift
done

[ -n "$APP" ] || APP="$PROJECT_ROOT/FCPX Studio Pro R2.app"
[ -n "$VERSION" ] || die "--version 不能为空"
case "$VERSION" in
    *[!A-Za-z0-9._-]*) die "版本号含非法字符: $VERSION" ;;
esac
[ "$VERSION" != "v1.0" ] || die "禁止用 --version v1.0 覆盖已过期的旧镜像版本号，请换一个新版本号"

NEW_DMG_NAME="FCPX_Studio_Pro_${VERSION}.dmg"
TMP_OUT_DIR="/tmp/s4_dmg_out"
NEW_DMG="$TMP_OUT_DIR/$NEW_DMG_NAME"

# S4-残留：输出目录必须在内盘（与项目根不同设备号），拒绝任何外置卷落地。
assert_internal_disk() {
    local p="$1" label="$2"
    case "$p" in
        /Volumes/*) die "$label 指向外置卷，禁止写入: ${p}（本脚本输出固定内盘）" ;;
    esac
    [ "$p" != "$PROJECT_ROOT" ] || die "$label 指向项目根（外置卷），禁止写入: $p"
    local probe="$p"
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
    local dev root_dev
    dev="$(stat -f %d "$probe" 2>/dev/null || echo unknown)"
    root_dev="$(stat -f %d "$PROJECT_ROOT" 2>/dev/null || echo unknown)"
    if [ "$dev" != "unknown" ] && [ "$root_dev" != "unknown" ] && [ "$dev" = "$root_dev" ]; then
        die "$label 与项目根同一外置卷，禁止写入: $p"
    fi
}

# ── 0. 前置只读闸门（--dry-run 同样执行）──────────────────────────────────────
info "[闸门 0] 目标 App / 进程 / 空间 / 旧镜像记账（只读）"

# 0.0 输出目录必须是内盘（dry-run 同样校验）
assert_internal_disk "$DIST_DIR" "DIST_DIR"
[ -z "$PUBLISH_DIR" ] || assert_internal_disk "$PUBLISH_DIR" "--publish"
info "  输出目录（内盘）: ${PUBLISH_DIR:-$DIST_DIR}"

# 0.1 目标 .app
[ -d "$APP" ] || die "源 .app 不是已存在的目录: $APP"
APP_ABS="$(cd "$APP" && pwd -P)"
APP_BASE="$(basename "$APP_ABS")"
case "$APP_BASE" in
    *.app|*.APP) ;;
    *) die "源必须是 .app 目录（当前: ${APP_BASE}）" ;;
esac
APP_BASE_L="$(printf '%s' "$APP_BASE" | tr '[:upper:]' '[:lower:]')"
[ "$APP_BASE_L" != "fcpx studio pro.app" ] \
    || die "禁止用用户旧包 'FCPX Studio Pro.app' 作为 dmg 源（TR-009/010/011 全都没有）"
[ -f "$APP_ABS/Contents/MacOS/FCPXStudio" ] || die "源包内缺可执行文件: $APP_ABS/Contents/MacOS/FCPXStudio"
APP_SIZE_KB=$(du -sk "$APP_ABS" | awk '{print $1}')
info "  源包: $APP_ABS (${APP_SIZE_KB} KiB)"

# 0.2 【硬闸门】R2.app 已退出
PROC_PATTERN="$APP_ABS/Contents/MacOS/FCPXStudio"
RUNNING="$(pgrep -fl "$PROC_PATTERN" 2>/dev/null | grep -v "^$$ " | grep -v "^$PPID " || true)"
if [ -n "$RUNNING" ]; then
    echo "❌ R2.app 仍在运行，禁止在 App 运行态重建分发镜像" >&2
    printf '%s\n' "$RUNNING" | sed 's/^/     /' >&2
    echo "   请由用户【主动退出】R2.app 后重试；本脚本不会替你退出任何 App。" >&2
    exit 5
fi
info "  pgrep 检查通过：$APP_BASE 未在运行"

# 0.3 /tmp 空间：stage(≈包体) + dmg(≈0.5×包体) 至少留 2×包体 + 余量
TMP_AVAIL_KB=$(df -k /tmp | awk 'NR==2 {print $4}')
NEED_KB=$(( APP_SIZE_KB * 2 + 102400 ))
[ "${TMP_AVAIL_KB:-0}" -ge "$NEED_KB" ] \
    || die "/tmp 可用空间不足：需要 ≥ ${NEED_KB} KiB，当前 ${TMP_AVAIL_KB:-unknown} KiB。外置卷只剩 ~255 MiB，禁止把临时文件写到外置卷"
info "  /tmp 可用 ${TMP_AVAIL_KB} KiB（需 ≥ ${NEED_KB} KiB）"

# 0.4 旧 dmg 记账（只读；明确标注过期）
if [ -f "$OLD_DMG" ]; then
    OLD_SIZE=$(stat -f %z "$OLD_DMG")
    OLD_MTIME=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$OLD_DMG")
    warn "检测到过期镜像: $OLD_DMG (${OLD_SIZE} B / ${OLD_MTIME}) —— 内容与当前源码不一致，不能对外发"
else
    warn "未找到旧镜像 ${OLD_DMG}（可能已移走），--replace 将无旧文件可备份"
fi

# 0.5 幂等 / 输出冲突
if [ -e "$NEW_DMG" ] && [ "$FORCE" -eq 0 ]; then
    die "输出已存在: ${NEW_DMG}（幂等保护）。加 --force 才允许覆盖，或换 --version"
fi
if [ -n "$PUBLISH_DIR" ]; then
    [ -d "$PUBLISH_DIR" ] || die "--publish 目录不存在: $PUBLISH_DIR"
    [ "$PUBLISH_DIR" != "$PROJECT_ROOT" ] || warn "--publish 指向项目根（外置卷，仅剩 ~255 MiB）；将做空间检查，建议先只留 /tmp 产物"
fi
# TR-015：删除残留的 $DO_REPLACE 判断块。--replace 已在参数解析处（:94）直接 die，
# 执行流永远到不了这里；且 DO_REPLACE 全脚本无赋值，set -u 下必然 unbound variable。
# 旧镜像仅作只读记账（0.4 段），不再参与任何写入决策。

# ── --dry-run：只打印命令序列，不写文件 / 不挂载 / 不签名 ─────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "──────────────────────────────────────────────────────────────"
    echo "[--dry-run] 前置闸门全部通过。以下为将执行的命令序列（本次一条都不执行）："
    echo
    echo "# 1. 在 /tmp 建 stage（临时文件绝不写外置卷）"
    echo "STAGE_DIR=\$(mktemp -d /tmp/s4_dmg_stage.XXXXXX)"
    echo "mkdir -p \"\$STAGE_DIR\""
    echo "cp -R \"$APP_ABS\" \"\$STAGE_DIR/\""
    echo "find \"\$STAGE_DIR\" \\( -name \"*.cstemp\" -o -name \"._*\" -o -name \".DS_Store\" \\) -delete"
    echo
    echo "# 2. 从 stage 生成 dmg，输出到 /tmp"
    echo "mkdir -p \"$TMP_OUT_DIR\""
    echo "hdiutil create -volname \"FCPX Studio Pro $VERSION\" \\"
    echo "    -srcfolder \"\$STAGE_DIR\" -format UDZO -ov \"$NEW_DMG\""
    echo
    echo "# 3. 校验体积 + 挂载校验内容"
    echo "stat -f %z \"$NEW_DMG\"                       # 体积下限/上限断言"
    echo "hdiutil imageinfo \"$NEW_DMG\"                # 镜像元数据可读"
    echo "MNT=\$(mktemp -d /tmp/s4_dmg_mnt.XXXXXX)"
    echo "hdiutil attach \"$NEW_DMG\" -readonly -nobrowse -mountpoint \"\$MNT\""
    echo "cmp -s \"$APP_ABS/Contents/MacOS/FCPXStudio\" \"\$MNT/$APP_BASE/Contents/MacOS/FCPXStudio\""
    echo "codesign --verify --deep --strict \"\$MNT/$APP_BASE\"   # 期望零输出"
    echo "hdiutil detach \"\$MNT\""
    echo
    echo "# 4. 落地策略（固定内盘，绝不写外置卷）"
    echo "mkdir -p \"${PUBLISH_DIR:-$DIST_DIR}\""
    echo "cp \"$NEW_DMG\" \"${PUBLISH_DIR:-$DIST_DIR}/$NEW_DMG_NAME\"   # 并列新版本号（不删旧 dmg）"
    echo "#   --replace 已禁用；过期镜像 $OLD_DMG 保持不动"
    echo
    echo "[--dry-run] 未创建 stage、未生成 dmg、未挂载、未发布、未替换。"
    echo "[--dry-run] 过期镜像 $OLD_DMG 未被改动，Exit 0。"
    exit 0
fi

# ── 幂等 / 并发保护 ──────────────────────────────────────────────────────────
LOCK_DIR="/tmp/s4_rebuild_dmg.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "另一个 s4_rebuild_dmg 实例正在运行（锁: ${LOCK_DIR}）。若为残留锁请人工确认后删除该目录"
fi
STAGE_DIR=""
MNT=""
cleanup() {
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        rmdir "$MNT" 2>/dev/null || true
    fi
    [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"
    rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

echo "=================================================="
echo "  S4.3 重建分发镜像"
echo "  源 App:  $APP_ABS"
echo "  新镜像:  $NEW_DMG"
echo "  版本:    ${VERSION}（旧 v1.0.dmg 已过期，不对外发）"
echo "=================================================="

# 1. /tmp stage
info "[1/4] 在 /tmp 建 stage 并复制当前 R2.app（不写外置卷）"
STAGE_DIR="$(mktemp -d /tmp/s4_dmg_stage.XXXXXX)"
cp -R "$APP_ABS" "$STAGE_DIR/"
find "$STAGE_DIR" \( -name "*.cstemp" -o -name "._*" -o -name ".DS_Store" \) -delete
[ -f "$STAGE_DIR/$APP_BASE/Contents/MacOS/FCPXStudio" ] \
    || die "stage 内缺可执行文件，已中止（$STAGE_DIR/${APP_BASE}）"

# 2. hdiutil create → /tmp
info "[2/4] hdiutil create → $NEW_DMG"
mkdir -p "$TMP_OUT_DIR"
CREATE_ARGS=(create -volname "FCPX Studio Pro $VERSION" -srcfolder "$STAGE_DIR" -format UDZO)
[ "$FORCE" -eq 1 ] && CREATE_ARGS+=(-ov)
hdiutil "${CREATE_ARGS[@]}" "$NEW_DMG"
[ -f "$NEW_DMG" ] || die "hdiutil 未产出镜像: $NEW_DMG"

# 3. 校验体积 + 内容
info "[3/4] 校验体积 / 镜像元数据 / 挂载内容 / 严格验签"
DMG_SIZE=$(stat -f %z "$NEW_DMG")
[ "$DMG_SIZE" -ge 10485760 ]  || die "新镜像体积异常偏小: ${DMG_SIZE} B（< 10 MiB）"
[ "$DMG_SIZE" -le 536870912 ] || die "新镜像体积异常偏大: ${DMG_SIZE} B（> 512 MiB），请检查 stage 是否混入无关文件"
hdiutil imageinfo "$NEW_DMG" >/dev/null || die "hdiutil imageinfo 失败，镜像不可读"
info "  体积: ${DMG_SIZE} B"

MNT="$(mktemp -d /tmp/s4_dmg_mnt.XXXXXX)"
hdiutil attach "$NEW_DMG" -readonly -nobrowse -mountpoint "$MNT" >/dev/null \
    || die "hdiutil attach 失败（挂载点 ${MNT}）"
APP_IN_DMG="$MNT/$APP_BASE"
[ -f "$APP_IN_DMG/Contents/MacOS/FCPXStudio" ] || die "dmg 内缺可执行文件: $APP_IN_DMG/Contents/MacOS/FCPXStudio"
cmp -s "$APP_ABS/Contents/MacOS/FCPXStudio" "$APP_IN_DMG/Contents/MacOS/FCPXStudio" \
    || die "dmg 内二进制与当前 R2.app 不一致，镜像内容不可信"
VERIFY_OUT="$(codesign --verify --deep --strict "$APP_IN_DMG" 2>&1)" \
    || { printf '%s\n' "$VERIFY_OUT" | sed 's/^/     /' >&2; die "dmg 内 App 严格验签失败"; }
[ -z "$VERIFY_OUT" ] || warn "dmg 内 App 严格验签 exit 0 但有输出（期望零输出）: $VERIFY_OUT"
hdiutil detach "$MNT" >/dev/null || die "hdiutil detach 失败，请手动卸载 $MNT"
MNT=""
info "  内容校验通过（二进制逐字节一致 + strict 验签 exit 0）"

# 4. 落地策略：固定并列拷贝到内盘，绝不写外置卷；--replace 已禁用
info "[4/4] 落地到内盘（默认 DIST_DIR；--publish 可另指定内盘目录）"
DEST_DIR="${PUBLISH_DIR:-$DIST_DIR}"
assert_internal_disk "$DEST_DIR" "输出目录"

mkdir -p "$DEST_DIR"
DEST_AVAIL_KB=$(df -k "$DEST_DIR" | awk 'NR==2 {print $4}')
DEST_NEED_KB=$(( DMG_SIZE / 1024 + 51200 ))
[ "${DEST_AVAIL_KB:-0}" -ge "$DEST_NEED_KB" ] \
    || die "内盘可用空间不足（需 ≥ ${DEST_NEED_KB} KiB，当前 ${DEST_AVAIL_KB:-unknown} KiB）；新镜像仍安全留在 $NEW_DMG"
DST="$DEST_DIR/$NEW_DMG_NAME"
if [ -e "$DST" ] && [ "$FORCE" -eq 0 ]; then
    die "目标已存在: ${DST}（幂等保护）。加 --force 才允许覆盖"
fi
cp "$NEW_DMG" "$DST"
info "  已并列发布到内盘: $DST"
info "  过期镜像 ${OLD_DMG} 未被改动（--replace 已禁用，等用户定完唯一可用包）"

echo "=================================================="
echo "✅ 镜像重建完成"
echo "   /tmp 产物:   $NEW_DMG ($DMG_SIZE B)"
echo "   源 App:      $APP_ABS"
echo "   版本:        $VERSION"
echo "   旧 v1.0.dmg: 已过期，未给 --replace 时保持原样，不得对外发"
echo "=================================================="
