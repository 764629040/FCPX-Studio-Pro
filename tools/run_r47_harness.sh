#!/bin/zsh
# ═══════════════════════════════════════════════════════════════
# tools/run_r47_harness.sh
# R47 零依赖便携式运行时与商用级 DMG 分发终结直证执行脚本
# 执行方式：zsh tools/run_r47_harness.sh
# ═══════════════════════════════════════════════════════════════
set -e
cd "$(dirname "$0")/.."

mkdir -p docs/r47_evidence

echo "== 1. 确保便携式 Python 运行时封装就绪 =="
if [ ! -d "FCPX Studio Pro.app/Contents/Resources/python_bundle" ]; then
    zsh tools/bundle_standalone_runtime.sh
fi

echo "\n== 2. 编译并打包 Release 版 FCPX Studio Pro.app =="
cd FCPXStudioNative && swift build -c release --disable-sandbox
cd ..
cp FCPXStudioNative/.build/release/FCPXStudio "FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
codesign --deep --force --sign - "FCPX Studio Pro.app"
codesign -vv "FCPX Studio Pro.app"

echo "\n== 3. 压制与生成商用级 DMG 分发镜像 =="
zsh tools/package_dmg.sh

echo "\n== 4. 编译并运行 Swift 原生直证 harness =="
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
  tools/r47_harness.swift \
  -o docs/r47_evidence/r47_harness

./docs/r47_evidence/r47_harness | tee docs/r47_evidence/r47_harness.log

echo "\n== 5. 编译并运行离屏渲染物证生成器 =="
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
  tools/r47_render_evidence.swift \
  -o docs/r47_evidence/r47_render_evidence

./docs/r47_evidence/r47_render_evidence

echo "\n== 6. 生成 R47 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r47

echo "\n== R47 直证流程圆满完成 =="
