#!/bin/zsh
# ═══════════════════════════════════════════════════════════════
# tools/run_r52_harness.sh
# R52 机器唯一码与商用授权分级体系、中栏整行高亮、无滚动条自适应卡片流与全局磨砂质感跃迁
# 执行方式：zsh tools/run_r52_harness.sh
# ═══════════════════════════════════════════════════════════════
set -e
cd "$(dirname "$0")/.."

mkdir -p docs/r52_evidence

echo "== 0. 确认并刷新 macOS HIG 标准高清 AppIcon.icns 与 LaunchServices =="
if [ ! -f "FCPX Studio Pro.app/Contents/Resources/AppIcon.icns" ]; then
  swift tools/generate_app_icon.swift
  iconutil -c icns build_staging/AppIcon.iconset -o "FCPX Studio Pro.app/Contents/Resources/AppIcon.icns"
fi

echo "强制更新 LaunchServices 数据库，确保 Dock 图标即刻点亮..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "FCPX Studio Pro.app"

echo "\n== 1. 编译并打包 Release 版 FCPX Studio Pro.app =="
cd FCPXStudioNative && swift build -c release --disable-sandbox
cd ..
cp FCPXStudioNative/.build/release/FCPXStudio "FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
codesign --deep --force --sign - "FCPX Studio Pro.app"
codesign -vv "FCPX Studio Pro.app"

echo "\n== 2. 编译并运行 Swift 原生直证 harness =="
swiftc -O -j 8 \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/PSDImportPlanner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/ParseDiagnostics.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateInstaller.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateMigrator.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateTier.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LUTManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AudioManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LibraryCleaner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateRenameManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AssetCacheManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/GhostPluginDoctor.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/WorkspaceProfileManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TeamP2PSyncManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/EnvironmentCloner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/FontInstaller.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LicenseManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/MotionBuilderSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/SymlinkSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/LUTCompareView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AudioWaveformView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/CleanerDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/PluginDoctorDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/StorageMigrationDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/WorkspaceProfileDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/TeamSyncDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/DropAcceptingView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/BatchExportProgressSheet.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/ResourceCardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/SettingsWindow.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/MainWindowController.swift \
  tools/r52_harness.swift \
  -o docs/r52_evidence/r52_harness

./docs/r52_evidence/r52_harness | tee docs/r52_evidence/r52_harness.log

echo "\n== 3. 编译并运行离屏渲染物证生成器 =="
swiftc -O -j 8 \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/PSDImportPlanner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/ParseDiagnostics.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateInstaller.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateMigrator.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateTier.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LUTManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AudioManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LibraryCleaner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateRenameManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AssetCacheManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/GhostPluginDoctor.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/WorkspaceProfileManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TeamP2PSyncManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/EnvironmentCloner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/FontInstaller.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LicenseManager.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/MotionBuilderSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/SymlinkSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/LUTCompareView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AudioWaveformView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/CleanerDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/PluginDoctorDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/StorageMigrationDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/WorkspaceProfileDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/TeamSyncDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/DropAcceptingView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/BatchExportProgressSheet.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/ResourceCardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/SettingsWindow.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/MainWindowController.swift \
  tools/r52_render_evidence.swift \
  -o docs/r52_evidence/r52_render_evidence

./docs/r52_evidence/r52_render_evidence

echo "\n== 4. 重新压制并更新商用分发 DMG =="
zsh tools/package_dmg.sh

echo "\n== 5. 最终验证 App 与 DMG 状态 =="
ls -lh "FCPX_Studio_Pro_v1.0.dmg"
echo "✅ R52 全部构建、全套验证与分发包压制 100% 成功！"
