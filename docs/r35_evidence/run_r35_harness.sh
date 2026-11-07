#!/bin/zsh
# R35 智能对齐吸附与遗留台账直证复现脚本
# 执行方式：zsh docs/r35_evidence/run_r35_harness.sh
set -e
cd "$(dirname "$0")/../.."

echo "== 1. 编译并运行 Swift 原生直证 harness =="
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/PSDImportPlanner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/ParseDiagnostics.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateMigrator.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateTier.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/MotionBuilderSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/SymlinkSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/DropAcceptingView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/SettingsWindow.swift \
  tools/r35_snap_harness.swift \
  -o docs/r35_evidence/r35_snap_harness

./docs/r35_evidence/r35_snap_harness | tee docs/r35_evidence/r35_harness.log

echo "\n== 2. 生成 R35 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r35
