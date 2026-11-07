#!/bin/zsh
# R31 原生逻辑直证 harness 复现脚本
# 用产品同一批 Swift 源码（TemplateTier / TemplateMigrator / PSDImportPlanner）
# 编译独立可执行 harness，在临时目录里真实跑 A-61 / A-63 / A-64 判据。
set -e
cd "$(dirname "$0")/../.."
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateTier.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/TemplateMigrator.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/PSDImportPlanner.swift \
  tools/r31_native_harness.swift \
  -o docs/r31_evidence/r31_native_harness
./docs/r31_evidence/r31_native_harness | tee docs/r31_evidence/a61_a63_a64_native_harness.log
echo "HARNESS_EXIT=$?"
