#!/bin/zsh
# R46 批量导出异步调度器、多路径自适应与字体一键补全系统直证脚本
# 执行方式：zsh tools/run_r46_harness.sh
set -e
cd "$(dirname "$0")/.."

mkdir -p docs/r46_evidence

echo "== 1. 编译并运行 Swift 原生直证 harness =="
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
  tools/r46_harness.swift \
  -o docs/r46_evidence/r46_harness

./docs/r46_evidence/r46_harness | tee docs/r46_evidence/r46_harness.log

echo "\n== 2. 编译并运行离屏渲染物证生成器 =="
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
  tools/r46_render_evidence.swift \
  -o docs/r46_evidence/r46_render_evidence

./docs/r46_evidence/r46_render_evidence

echo "\n== 3. 编译并签名 Release 版 FCPX Studio Pro.app =="
cd FCPXStudioNative && swift build -c release --disable-sandbox
cd ..
cp FCPXStudioNative/.build/release/FCPXStudio "FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
codesign --force --sign - "FCPX Studio Pro.app"
codesign -vv "FCPX Studio Pro.app"

echo "\n== 4. 生成 R46 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r46

echo "\n== R46 直证流程圆满完成 =="
