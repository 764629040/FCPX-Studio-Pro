#!/bin/zsh
# ═══════════════════════════════════════════════════════════════
# tools/package_dmg.sh
# 商用级 DMG 分发镜像生成器
#
# 功能：
#   自动化构建标准 macOS 商用分发镜像 FCPX_Studio_Pro_v1.0.dmg。
#   内嵌经深度签名的 FCPX Studio Pro.app、/Applications 软链接快捷替身
#   以及《使用说明与快速上手.txt》，采用只读 UDZO 压缩格式压制。
# ═══════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_PATH="$PROJECT_ROOT/FCPX Studio Pro.app"
DMG_OUTPUT="$PROJECT_ROOT/FCPX_Studio_Pro_v1.0.dmg"
STAGING_DIR="$PROJECT_ROOT/build_staging/dmg_root"

echo "=================================================="
echo "  FCPX Studio Pro —— 商用级 DMG 镜像生成器"
echo "=================================================="

# 1. 前置条件检查
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 错误: 未找到 $APP_PATH，请先编译并构建 App"
    exit 1
fi

if [ ! -d "$APP_PATH/Contents/Resources/python_bundle" ]; then
    echo "⚠︎ 警告: 未在 App 中检测到 python_bundle，自动调用封装器补全..."
    zsh "$SCRIPT_DIR/bundle_standalone_runtime.sh"
fi

# 确保 App 已深度代码签名
echo "==> 验证并更新 App Bundle 递归深度签名..."
codesign --deep --force --verify --verbose --sign - "$APP_PATH"
codesign -vv "$APP_PATH"

# 2. 准备暂存分发目录
echo "==> 准备 DMG 打包暂存区: $STAGING_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "==> 复制应用包至暂存区..."
cp -R -p "$APP_PATH" "$STAGING_DIR/"

echo "==> 创建 /Applications 快捷安装软链接替身..."
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> 写入《使用说明与快速上手.txt》..."
cat << 'EOF' > "$STAGING_DIR/使用说明与快速上手.txt"
======================================================================
  FCPX Studio Pro v1.0 (Commercial Edition) 商业正式版
  Photoshop PSD 批量无损直转 Final Cut Pro 字幕与动效模板引擎
======================================================================

【快速安装指南】：
1. 将左侧的「FCPX Studio Pro.app」图标直接拖拽至右侧的「Applications」文件夹；
2. 在「启动台」或「应用程序」中双击启动「FCPX Studio Pro」即可立即使用。

【零依赖便携运行特性 (D-82 / D-83)】：
- 本软件已内置独立便携式解析引擎 (Standalone Embedded Runtime)，
  无需预装 Python、Homebrew 或额外安装任何命令行工具，纯净裸机开箱即用；
- 原生支持 Apple Silicon (M1/M2/M3/M4) 系列芯片硬件加速，毫秒级响应。

【首次打开安全提示 (Gatekeeper)】：
- 若首次双击弹出「无法打开，因为 Apple 无法检查其是否包含恶意软件」：
  请打开「系统设置」->「隐私与安全性」-> 点击「仍要打开」；
  或者在访达中「右键(按住 Control 点击) -> 打开」即可信任启动。

【核心功能亮点】：
1. PSD 智能解析：图层属性、文字排版、字体三元组自动对齐；
2. 批量渲染导出：多 PSD 任务队列异步调度，自动无缝对接 Final Cut Pro；
3. 外置存储自适应：支持随身 SSD 智能软链接，拔盘自动降级本地防阻断；
4. 幽灵插件医生：全盘扫描断链与破损模板，一键自愈修复；
5. 字体一键补全：智能拖拽安装缺失字体并即时注册 CoreText 系统字体库。

如需技术支持或商业授权，请访问官方发布渠道。
Copyright © 2026 FCPX Studio Pro Team. All Rights Reserved.
EOF

# 3. 使用 hdiutil 自动化压制 UDZO 压缩镜像
echo "==> 压制只读压缩磁盘映像: $DMG_OUTPUT"
rm -f "$DMG_OUTPUT"

hdiutil create \
    -volname "FCPX Studio Pro" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

# 4. 镜像完整性自检与挂载测试
echo "==> 校验生成的 DMG 映像完整性..."
hdiutil verify "$DMG_OUTPUT"

echo "==> 模拟挂载验证 DMG 结构..."
MOUNT_POINT=$(mktemp -d /tmp/fcpx_dmg_mount.XXXXXX)
hdiutil attach "$DMG_OUTPUT" -mountpoint "$MOUNT_POINT" -nobrowse -readonly

if [ ! -d "$MOUNT_POINT/FCPX Studio Pro.app" ]; then
    echo "❌ 镜像校验失败: 挂载卷内未找到 FCPX Studio Pro.app"
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$MOUNT_POINT"
    exit 1
fi

if [ ! -L "$MOUNT_POINT/Applications" ]; then
    echo "❌ 镜像校验失败: Applications 快捷替身缺失"
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$MOUNT_POINT"
    exit 1
fi

if [ ! -f "$MOUNT_POINT/使用说明与快速上手.txt" ]; then
    echo "❌ 镜像校验失败: 使用说明文件缺失"
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$MOUNT_POINT"
    exit 1
fi

echo "==> 卸载模拟挂载卷..."
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$MOUNT_POINT" "$STAGING_DIR"

DMG_SIZE=$(du -sh "$DMG_OUTPUT" | awk '{print $1}')
DMG_SHA=$(shasum -a 256 "$DMG_OUTPUT" | awk '{print $1}')

echo "=================================================="
echo "✅ 商用级 DMG 分发镜像生成成功！"
echo "   文件路径: $DMG_OUTPUT"
echo "   镜像大小: $DMG_SIZE"
echo "   SHA-256:  $DMG_SHA"
echo "=================================================="
