#!/bin/zsh
# R37 一键安装与模板启停直证复现脚本
# 执行方式：zsh docs/r37_evidence/run_r37_harness.sh
set -e
cd "$(dirname "$0")/../.."

echo "== 1. 编译并运行 Swift 原生直证 harness =="
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/PSDImportPlanner.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/ParseDiagnostics.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateInstaller.swift \
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
  tools/r37_installer_toggle_harness.swift \
  -o docs/r37_evidence/r37_installer_toggle_harness

./docs/r37_evidence/r37_installer_toggle_harness | tee docs/r37_evidence/r37_harness.log

echo "\n== 2. 编译并签名 Release 版 FCPX Studio Pro.app =="
cd FCPXStudioNative && swift build -c release --disable-sandbox
cd ..
cp FCPXStudioNative/.build/release/FCPXStudio "FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
codesign --force --sign - "FCPX Studio Pro.app"
codesign -vv "FCPX Studio Pro.app"

echo "\n== 3. 生成 R37 独立原生指纹清单 =="
python3 tools/native_inventory.py --tag r37
