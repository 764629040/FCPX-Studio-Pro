#!/bin/zsh
# ═══════════════════════════════════════════════════════════════
# tools/bundle_standalone_runtime.sh
# 零依赖便携运行时封装工具（落实 D-82 / D-83）
#
# 功能：
#   将当前运行环境中的核心 Python 运行时、动态库、psd-tools 与核心
#   依赖完整精简封装至 <--target 指定的 .app>/Contents/Resources/python_bundle，
#   并将 core 源码封装至 Contents/Resources/core。
#   对所有 Mach-O 动态库执行 install_name_tool 相对路径重定向与深度签名，
#   确保在未安装 Python / Homebrew 的纯净裸机 Mac 上双击即用。
#
# ── S4 交付代理保护性修改（2026-11-10）──────────────────────────
#   1. 移除写死的 APP_PATH="$PROJECT_ROOT/FCPX Studio Pro.app"；
#      必须显式 --target <path>，无参数直接报错退出并给用法提示。
#   2. 拒绝任何「解析后」指向用户旧包 FCPX Studio Pro.app 的目标：
#      绝对路径 / 相对路径 / 大小写变体 / 尾斜杠 / .. 绕路 / 符号链接 一律判。
#      理由：该旧包是用户手上的旧产物（TR-009/010/011 全都没有），
#      就地封装会毁掉它，必须显式改指新包。
#   3. 目标必须是已存在的 .app 目录。
#   4. --dry-run 只打印将写入的路径，不实际写任何文件。
#   5. --help 打印用法。
#   注：tools/generate_license.py 与本脚本无关，本次未改动。
# ═══════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

usage() {
    cat <<'USAGE'
用法： tools/bundle_standalone_runtime.sh --target <path-to-.app> [--dry-run]

  --target <path>   【必填】目标 .app 目录，必须已存在。
                    相对路径按项目根目录解析（脚本会 cd 到项目根）。
                    禁止指向用户旧包 "FCPX Studio Pro.app" 或其任意子路径。
  --target=<path>   同上，等号形式。
  --dry-run         只打印将写入的路径，不实际写任何文件（不执行任何写操作）。
  -h, --help        显示本帮助并退出（Exit 0）。

示例：
  tools/bundle_standalone_runtime.sh --target "FCPX Studio Pro R2.app" --dry-run
  tools/bundle_standalone_runtime.sh --target "/path/to/NewBuild.app"

⚠️  禁止覆盖用户旧包：FCPX Studio Pro.app（TR-009/010/011 全都没有的旧产物）。
    绝对路径 / 相对路径 / 大小写变体 / 尾斜杠 / .. 绕路 / 符号链接 均会被拒绝。
USAGE
}

TARGET_ARG=""
DRY_RUN=0
while (( $# )); do
    case "$1" in
        --target)
            shift
            if (( $# == 0 )) || [[ "$1" == --* ]]; then
                echo "❌ 错误: --target 缺少路径参数" >&2
                echo "   用法: tools/bundle_standalone_runtime.sh --target <path-to-.app> [--dry-run]" >&2
                exit 2
            fi
            TARGET_ARG="$1"
            ;;
        --target=*)
            TARGET_ARG="${1#--target=}"
            if [[ -z "$TARGET_ARG" ]]; then
                echo "❌ 错误: --target= 不能为空" >&2
                echo "   用法: tools/bundle_standalone_runtime.sh --target <path-to-.app> [--dry-run]" >&2
                exit 2
            fi
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ 错误: 未知参数 '$1'" >&2
            echo "   用法: tools/bundle_standalone_runtime.sh --target <path-to-.app> [--dry-run]" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -z "$TARGET_ARG" ]]; then
    echo "❌ 错误: 必须显式指定 --target <path-to-.app>（已移除写死的旧包路径）" >&2
    echo >&2
    usage >&2
    exit 2
fi

# ── 归一化目标路径：去尾斜杠 → 绝对化 → 词法归一化 + 符号链接解析 ──
# ${var:A} 为 zsh 修饰符：转绝对路径、折叠 . / ..、解析已存在部分的符号链接。
NORM="$TARGET_ARG"
while [[ "$NORM" == */ && "$NORM" != "/" ]]; do NORM="${NORM%/}"; done
if [[ "$NORM" == /* ]]; then
    ABS="$NORM"
else
    ABS="$PWD/$NORM"
fi
ABS="${ABS:A}"

# 旧包基准路径，同样归一化
OLD_APP_ABS="${PROJECT_ROOT}/FCPX Studio Pro.app"
OLD_APP_ABS="${OLD_APP_ABS:A}"

# 大小写折叠比较：macOS 默认大小写不敏感，大小写变体同样指向旧包
ABS_L="${(L)ABS}"
OLD_L="${(L)OLD_APP_ABS}"
if [[ "$ABS_L" == "$OLD_L" ]] || [[ "$ABS_L" == "$OLD_L/"* ]]; then
    echo "❌ 禁止覆盖用户旧包: 目标解析后指向 'FCPX Studio Pro.app'" >&2
    echo "   输入:   $TARGET_ARG" >&2
    echo "   解析后: $ABS" >&2
    echo "   该包是用户手上的旧产物（TR-009/010/011 全都没有），就地封装会毁掉它。" >&2
    echo "   请改用 --target 指向新包，例如: --target 'FCPX Studio Pro R2.app'" >&2
    exit 3
fi

# 目标必须是已存在的 .app 目录
if [[ ! -d "$ABS" ]]; then
    echo "❌ 错误: 目标不是已存在的目录: $ABS" >&2
    echo "   （由 --target '$TARGET_ARG' 解析而来）" >&2
    exit 4
fi
if [[ "$ABS_L" != *.app ]]; then
    echo "❌ 错误: 目标必须是 .app 目录（当前: $ABS）" >&2
    exit 4
fi

APP_PATH="$ABS"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
BUNDLE_DIR="$RESOURCES_DIR/python_bundle"
CORE_DEST_DIR="$RESOURCES_DIR/core"

echo "=================================================="
echo "  FCPX Studio Pro —— 零依赖便携运行时封装器"
echo "=================================================="
echo "目标 App 路径: $APP_PATH"
echo "便携包路径:   $BUNDLE_DIR"
echo "core 目标:    $CORE_DEST_DIR"

# ── --dry-run：只打印将写入的路径，绝不执行任何写操作 ──
if (( DRY_RUN )); then
    echo "--------------------------------------------------"
    echo "[--dry-run] 以下路径将被写入 / 重建（本次不实际写任何文件）："
    echo "  [清空重建] $BUNDLE_DIR"
    echo "  [清空重建] $CORE_DEST_DIR"
    echo "  [创建目录] $BUNDLE_DIR/bin"
    echo "  [创建目录] $BUNDLE_DIR/lib/python<VER>"
    echo "  [创建目录] $BUNDLE_DIR/lib/python<VER>/site-packages"
    echo "  [创建目录] $BUNDLE_DIR/lib/dylibs"
    echo "  [写入文件] $BUNDLE_DIR/bin/python3 (+ 2 个符号链接 python / python<VER>)"
    echo "  [写入文件] $BUNDLE_DIR/Python"
    echo "  [写入目录] $BUNDLE_DIR/lib/python<VER>/  (标准库 rsync)"
    echo "  [写入目录] $BUNDLE_DIR/lib/dylibs/       (Homebrew dylibs)"
    echo "  [写入目录] $BUNDLE_DIR/lib/python<VER>/site-packages/ (三方依赖)"
    echo "  [写入目录] $CORE_DEST_DIR/               (cp -R $PROJECT_ROOT/core)"
    echo "  [删除清理] 上述目录内 __pycache__ / *.pyc / *.pyo / *.dSYM / tests"
    echo "  [就地改写] $BUNDLE_DIR 下 Mach-O 的 install_name_tool rpath/-id"
    echo "  [代码签名] $BUNDLE_DIR 下所有 *.dylib / *.so / python3 / Python"
    echo "  [只读自检] env -i 纯净环境 import + cli_bridge.py parse（不写任何文件）"
    echo "[--dry-run] 未执行任何 rm / mkdir / cp / ln / rsync / chmod / install_name_tool / codesign。"
    echo "[--dry-run] 目标 App 未被改动，Exit 0。"
    exit 0
fi

# 1. 探测主机环境中的 Python 3.14 及其 framework
HOST_PY=$(which python3)
if [ -z "$HOST_PY" ]; then
    echo "❌ 错误: 未在 PATH 中找到 python3"
    exit 1
fi

PY_VER=$($HOST_PY -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "当前主机 Python 版本: $PY_VER ($HOST_PY)"

# 校验 psd-tools 是否存在
if ! $HOST_PY -c "import psd_tools" 2>/dev/null; then
    echo "❌ 错误: 当前 Python 环境缺少 psd-tools"
    exit 1
fi

# 探测 Python.framework 路径
FRAMEWORK_DIR="/opt/homebrew/Cellar/python@$PY_VER/$($HOST_PY -c 'import platform; print(platform.python_version())')/Frameworks/Python.framework/Versions/$PY_VER"
if [ ! -d "$FRAMEWORK_DIR" ]; then
    FRAMEWORK_DIR=$($HOST_PY -c "import sys; print(sys.prefix)")
fi

if [ ! -f "$FRAMEWORK_DIR/Python" ] && [ -f "$FRAMEWORK_DIR/../../Python" ]; then
    FRAMEWORK_DIR="$(cd "$FRAMEWORK_DIR/../.." && pwd)"
fi

echo "Python Framework 根路径: $FRAMEWORK_DIR"

# 2. 清理并初始化目标目录结构
echo "正在创建便携运行时目录结构..."
rm -rf "$BUNDLE_DIR" "$CORE_DEST_DIR"
mkdir -p "$BUNDLE_DIR/bin"
mkdir -p "$BUNDLE_DIR/lib/python$PY_VER"
mkdir -p "$BUNDLE_DIR/lib/dylibs"

# 3. 复制 Python 核心可执行文件与动态库
echo "正在提取 Python 解释器与 Framework 核心动态库..."
PYTHON_EXECUTABLE="$FRAMEWORK_DIR/Resources/Python.app/Contents/MacOS/Python"
if [ ! -f "$PYTHON_EXECUTABLE" ]; then
    PYTHON_EXECUTABLE="$FRAMEWORK_DIR/bin/python$PY_VER"
fi

cp "$PYTHON_EXECUTABLE" "$BUNDLE_DIR/bin/python3"
chmod 755 "$BUNDLE_DIR/bin/python3"
ln -sf python3 "$BUNDLE_DIR/bin/python"
ln -sf python3 "$BUNDLE_DIR/bin/python$PY_VER"

cp "$FRAMEWORK_DIR/Python" "$BUNDLE_DIR/Python"
chmod 755 "$BUNDLE_DIR/Python"

# 4. 调整可执行文件与动态库的 rpath 与链接依赖
echo "正在配置 Mach-O 动态链接相对寻址 (@loader_path)..."
ORIG_LIB_ID=$(otool -D "$BUNDLE_DIR/Python" | tail -n 1)
install_name_tool -id "@loader_path/Python" "$BUNDLE_DIR/Python" 2>/dev/null || true
install_name_tool -change "$ORIG_LIB_ID" "@loader_path/../Python" "$BUNDLE_DIR/bin/python3" 2>/dev/null || true
install_name_tool -change "$FRAMEWORK_DIR/Python" "@loader_path/../Python" "$BUNDLE_DIR/bin/python3" 2>/dev/null || true

# 5. 复制标准库并裁剪无用组件
echo "正在封装 Python 标准库..."
rsync -a \
    --exclude "site-packages" \
    --exclude "test" \
    --exclude "idlelib" \
    --exclude "tkinter" \
    --exclude "turtledemo" \
    --exclude "ensurepip" \
    "$FRAMEWORK_DIR/lib/python$PY_VER/" "$BUNDLE_DIR/lib/python$PY_VER/"

mkdir -p "$BUNDLE_DIR/lib/python$PY_VER/site-packages"

# 6. 处理 lib-dynload 及其三方 Homebrew dylib 依赖
echo "正在重定向 lib-dynload C-扩展库至独立内嵌 dylibs..."
HOMEBREW_DYLIBS=(
    "/opt/homebrew/opt/mpdecimal/lib/libmpdec.4.dylib"
    "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
    "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
    "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"
    "/opt/homebrew/opt/xz/lib/liblzma.5.dylib"
    "/opt/homebrew/opt/zstd/lib/libzstd.1.dylib"
)

for dylib in "${HOMEBREW_DYLIBS[@]}"; do
    if [ -f "$dylib" ]; then
        cp -L "$dylib" "$BUNDLE_DIR/lib/dylibs/"
    fi
done
chmod -R u+w "$BUNDLE_DIR/lib/dylibs"

for f in "$BUNDLE_DIR/lib/dylibs"/*.dylib; do
    [ -f "$f" ] || continue
    install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
    for old_ref in $(otool -L "$f" 2>/dev/null | grep "/opt/homebrew" | awk '{print $1}'); do
        base_ref=$(basename "$old_ref")
        install_name_tool -change "$old_ref" "@loader_path/$base_ref" "$f" 2>/dev/null || true
    done
done

for so in "$BUNDLE_DIR/lib/python$PY_VER/lib-dynload"/*.so; do
    [ -f "$so" ] || continue
    for old_ref in $(otool -L "$so" 2>/dev/null | grep "/opt/homebrew" | awk '{print $1}'); do
        base_ref=$(basename "$old_ref")
        install_name_tool -change "$old_ref" "@loader_path/../../dylibs/$base_ref" "$so" 2>/dev/null || true
    done
done

# 7. 复制纯 Python 核心依赖及第三方库
echo "正在精炼打包 site-packages (psd-tools, Pillow, numpy, attrs, objc 等)..."
SITE_PKG=$($HOST_PY -c "import psd_tools, os; print(os.path.dirname(os.path.dirname(psd_tools.__file__)))")

PKGS_TO_COPY=(
    "psd_tools"
    "PIL"
    "numpy"
    "attrs"
    "attr"
    "scipy"
    "objc"
    "Cocoa"
    "AppKit"
)

for pkg in "${PKGS_TO_COPY[@]}"; do
    if [ -d "$SITE_PKG/$pkg" ]; then
        cp -R "$SITE_PKG/$pkg" "$BUNDLE_DIR/lib/python$PY_VER/site-packages/"
    fi
done

if [ -f "$SITE_PKG/typing_extensions.py" ]; then
    cp "$SITE_PKG/typing_extensions.py" "$BUNDLE_DIR/lib/python$PY_VER/site-packages/"
fi
if [ -d "$SITE_PKG/typing_inspection" ]; then
    cp -R "$SITE_PKG/typing_inspection" "$BUNDLE_DIR/lib/python$PY_VER/site-packages/"
fi

# 8. 封装 core 核心桥接与解析脚本
echo "正在封装 core 解析套件至 Resources/core..."
cp -R "$PROJECT_ROOT/core" "$CORE_DEST_DIR"

# 9. 剥离缓存与无用文件
echo "正在清理 .pyc 缓存与测试用例..."
find "$BUNDLE_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true
find "$BUNDLE_DIR" -type d -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$CORE_DEST_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$CORE_DEST_DIR" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true

# 10. 递归深度代码签名
echo "正在为便携包内所有 Mach-O 二进制执行代码签名..."
find "$BUNDLE_DIR" -type f \( -name "*.dylib" -o -name "*.so" -o -name "python3" -o -name "Python" \) -exec codesign --force --sign - {} + 2>/dev/null || true

# 11. 纯净环境验证（完全不带 PATH/Homebrew）
echo "正在执行纯净隔离环境自检..."
TEST_OUTPUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME" "$BUNDLE_DIR/bin/python3" -c "import psd_tools, PIL, numpy, objc; print('STANDALONE_READY')" 2>&1)
if [[ "$TEST_OUTPUT" != *"STANDALONE_READY"* ]]; then
    echo "❌ 隔离自检失败: $TEST_OUTPUT"
    exit 1
fi

PARSE_TEST=$(env -i PATH=/usr/bin:/bin HOME="$HOME" "$BUNDLE_DIR/bin/python3" "$CORE_DEST_DIR/cli_bridge.py" parse "$PROJECT_ROOT/tests/data/complex_layers.psd" 2>&1)
if [[ "$PARSE_TEST" != *'"status": "ok"'* ]]; then
    echo "❌ 隔离 CLI Bridge 解析测试失败: $PARSE_TEST"
    exit 1
fi

TOTAL_SIZE=$(du -sh "$BUNDLE_DIR" | awk '{print $1}')
echo "=================================================="
echo "✅ 零依赖便携式 Python 运行时封装成功！"
echo "   总包体大小: $TOTAL_SIZE"
echo "   自检状态:   STANDALONE_READY (纯净环境 100% 通过)"
echo "=================================================="
