#!/bin/zsh
# ═══════════════════════════════════════════════════════════════
# tools/run_r48_harness.sh
# R48 顶栏避让解耦、侧栏 SF 矢量图标与真实模板缩略图穿透直证执行脚本
# 执行方式：zsh tools/run_r48_harness.sh
# ═══════════════════════════════════════════════════════════════
set -e
cd "$(dirname "$0")/.."

mkdir -p docs/r48_evidence

echo "== 1. 编译并打包 Release 版 FCPX Studio Pro.app =="
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
  tools/r48_harness.swift \
  -o docs/r48_evidence/r48_harness

./docs/r48_evidence/r48_harness | tee docs/r48_evidence/r48_harness.log

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
  tools/r48_render_evidence.swift \
  -o docs/r48_evidence/r48_render_evidence

./docs/r48_evidence/r48_render_evidence

echo "\n== 4. 重新压制并更新分发 DMG =="
zsh tools/package_dmg.sh

echo "\n✅ R48 全部验证、物证渲染与 DMG 打包圆满完成！"
