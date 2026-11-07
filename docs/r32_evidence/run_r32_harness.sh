#!/bin/zsh
# R32 证据复现脚本 —— 在项目根目录执行：zsh docs/r32_evidence/run_r32_harness.sh
set -e
cd "$(dirname "$0")/../.."

echo "== 1. A-65 逻辑 harness（31 项断言）=="
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/ParseDiagnostics.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  tools/r32_parse_harness.swift -o docs/r32_evidence/r32_parse_harness
./docs/r32_evidence/r32_parse_harness

echo "== 2. A-65 红灯对照（R31 旧实现 + 同一输入）=="
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  docs/r32_evidence/legacy_PSDParserSocket_r31.swift \
  docs/r32_evidence/legacy_harness_main.swift \
  -o docs/r32_evidence/legacy_r31_socket_harness
echo "--- 小文件（应正常出 8 层）---"
timeout 30 ./docs/r32_evidence/legacy_r31_socket_harness tests/data/four_state.psd; echo "RC=$?"
echo "--- 大文件 582KB 输出（旧实现应 RC=124 挂死）---"
timeout 30 ./docs/r32_evidence/legacy_r31_socket_harness docs/r32_evidence/r32_stress_260_layers.psd; echo "RC=$? (124=死锁实锤)"

echo "== 3. A-66 UI 离屏渲染（列宽断言 + PNG）=="
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
  FCPXStudioNative/Sources/FCPXStudio/Views/MainWindowController.swift \
  tools/r32_ui_harness.swift -o docs/r32_evidence/r32_ui_harness
./docs/r32_evidence/r32_ui_harness

echo "== 4. 大样本再生成（如需）=="
# python3 tools/make_r32_stress_psd.py docs/r32_evidence/r32_stress_260_layers.psd 260
# python3 core/cli_bridge.py parse docs/r32_evidence/r32_stress_260_layers.psd | wc -c   # 应为 582702

echo "== 5. 真机 UI 截图（需解锁的图形会话）=="
# "$PWD/FCPX Studio Pro.app/Contents/MacOS/FCPXStudio" --engine2 &      # 引擎二（A-66）
# sleep 8; screencapture -x docs/r32_evidence/a66_engine2_tiers.png
# "$PWD/FCPX Studio Pro.app/Contents/MacOS/FCPXStudio" --open "$PWD/docs/r32_evidence/r32_stress_260_layers.psd" &  # A-62 单文件
# sleep 20; screencapture -x docs/r32_evidence/a62_open_stress.png
# "$PWD/FCPX Studio Pro.app/Contents/MacOS/FCPXStudio" --open "$PWD/tests/data/corrupted_file.psd" &  # A-65 失败红字
# sleep 15; screencapture -x docs/r32_evidence/a65_failure_red.png
