#!/bin/zsh
# R36 图层锁定与隐藏交互闭环直证复现脚本
# 执行方式：zsh docs/r36_evidence/run_r36_harness.sh
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
  tools/r36_lock_harness.swift \
  -o docs/r36_evidence/r36_lock_harness

./docs/r36_evidence/r36_lock_harness | tee docs/r36_evidence/r36_harness.log

echo "\n== 2. 生成 R36 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r36
