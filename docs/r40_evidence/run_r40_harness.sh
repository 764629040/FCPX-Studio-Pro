#!/bin/zsh
# R40 彻底根除卡顿性能重构与嘉星UI视觉深度复刻直证复现脚本
# 执行方式：zsh docs/r40_evidence/run_r40_harness.sh
set -e
cd "$(dirname "$0")/../.."

mkdir -p docs/r40_evidence

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
  FCPXStudioNative/Sources/FCPXStudio/Sockets/MotionBuilderSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/SymlinkSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/LUTCompareView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AudioWaveformView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/CleanerDashboardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/DropAcceptingView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/ResourceCardView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/SettingsWindow.swift \
  tools/r40_perf_ui_harness.swift \
  -o docs/r40_evidence/r40_perf_ui_harness

./docs/r40_evidence/r40_perf_ui_harness | tee docs/r40_evidence/r40_harness.log

echo "\n== 2. 编译并签名 Release 版 FCPX Studio Pro.app =="
cd FCPXStudioNative && swift build -c release --disable-sandbox
cd ..
cp FCPXStudioNative/.build/release/FCPXStudio "FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
codesign --force --sign - "FCPX Studio Pro.app"
codesign -vv "FCPX Studio Pro.app"

echo "\n== 3. 生成 R40 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r40

echo "\n== R40 直证流程圆满完成 =="
