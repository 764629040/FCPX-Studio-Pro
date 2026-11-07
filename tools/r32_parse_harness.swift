// R32 / A-65 直证：PSDParserSocket 管道死锁修复的验收 harness
//
// 编译（产品同源码，非复制品）：
//   swiftc -O \
//     FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
//     FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
//     FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
//     tools/r32_parse_harness.swift -o docs/r32_evidence/r32_parse_harness
//
// 覆盖：小文件 / 真实大输出 / 1MB stdout + 512KB stderr 双管道 / 非零退出 /
//       坏 JSON / 缺 layers / 缺画幅 / 空图层 / 超时。

import Foundation

private var checks = 0
private var failures = 0

private func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    checks += 1
    if ok {
        print("PASS  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    } else {
        failures += 1
        print("FAIL  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }
}

private func writeScript(_ dir: String, _ name: String, _ body: String) -> String {
    let path = "\(dir)/\(name)"
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func elapsed(_ block: () -> Void) -> Double {
    let t0 = Date()
    block()
    return Date().timeIntervalSince(t0)
}

@main
struct R32ParseHarness {
    static func main() {
    let root = FileManager.default.currentDirectoryPath
    let python = "/opt/homebrew/bin/python3"
    let realBridge = "\(root)/core/cli_bridge.py"
    let fm = FileManager.default

    guard fm.fileExists(atPath: python), fm.fileExists(atPath: realBridge) else {
        print("FATAL: python 或 cli_bridge.py 不存在（cwd=\(root)）")
        exit(2)
    }

    let tmp = NSTemporaryDirectory() + "r32_parse_harness_\(getpid())"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)

    let socket = PSDParserSocket(pythonPath: python, bridgePath: realBridge, timeoutSeconds: 60)

    // ── 1. 小文件无回归 ─────────────────────────────────────────────
    var r = socket.parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(r.isValid, "four_state.psd 解析成功", r.failureReason ?? "valid")
    check(r.layers.count == 8, "four_state.psd 图层数 = 8", "实际 \(r.layers.count)")
    check(Int(r.width) == 1080 && Int(r.height) == 1920,
          "four_state.psd 真实画幅 1080×1920（非兜底 1920×1080）",
          "实际 \(Int(r.width))×\(Int(r.height))")
    let highlighted = r.layers.filter { $0.highlightMissingFont }.count
    check(highlighted == 4, "four_state.psd 仍有 4 层缺字高亮（A-51 无回归）", "实际 \(highlighted)")

    // ── 2. 真实文字/图片混合 PSD ─────────────────────────────────────
    r = socket.parsePSD(at: "\(root)/tests/data/wedding_with_decorations_23.psd")
    check(r.isValid, "wedding_with_decorations_23.psd 解析成功", r.failureReason ?? "valid")
    check(r.layers.count == 9, "wedding_with_decorations_23.psd 图层数 = 9", "实际 \(r.layers.count)")
    check(Int(r.width) == 1920 && Int(r.height) == 1080,
          "wedding_with_decorations_23.psd 真实画幅 1920×1080",
          "实际 \(Int(r.width))×\(Int(r.height))")

    // ── 3. 真实大输出（582 KB > 64 KB 管道缓冲）──────────────────────
    let stressPath = "\(root)/docs/r32_evidence/r32_stress_260_layers.psd"
    if fm.fileExists(atPath: stressPath) {
        var stress = PSDParseResult.failure("未执行")
        let dt = elapsed { stress = socket.parsePSD(at: stressPath) }
        check(stress.isValid, "大输出 PSD（260 层）解析成功，未死锁", String(format: "%.2fs", dt))
        check(stress.layers.count == 260, "大输出 PSD 图层数 = 260", "实际 \(stress.layers.count)")
        check(dt < 60, "大输出 PSD 在超时阈值内返回", String(format: "%.2fs", dt))
    } else {
        check(false, "大输出 PSD 样本缺失", stressPath)
    }

    // ── 4. 双管道压力：1 MB stdout + 512 KB stderr ──────────────────
    let bigJSON = """
    {"width":1234,"height":567,"aspect_ratio":"1234:567","resolution_spec":"567P",
     "layers":[{"index":1,"name":"Big","kind":"type","text":"x","font_name":"Helvetica"}],
     "diagnostics":{"warnings":[],"notes":["\(String(repeating: "N", count: 1_000_000))"]}}
    """
    let bigScript = writeScript(tmp, "big_both_pipes.py", """
    import sys
    sys.stdout.write('''\(bigJSON)''')
    sys.stdout.flush()
    sys.stderr.write('E' * 524288)
    sys.stderr.flush()
    """)
    let bigSocket = PSDParserSocket(pythonPath: python, bridgePath: bigScript, timeoutSeconds: 30)
    var big = PSDParseResult.failure("未执行")
    let bigDt = elapsed { big = bigSocket.parsePSD(at: "\(root)/tests/data/four_state.psd") }
    check(big.isValid, "1 MB stdout + 512 KB stderr 双管道不死锁", String(format: "%.2fs", bigDt))
    check(big.layers.count == 1 && Int(big.width) == 1234,
          "双管道压力后 JSON 完整", "layers=\(big.layers.count) w=\(Int(big.width))")

    // ── 5. 解析进程非零退出 → 显式失败（不许伪装成功）───────────────
    let failScript = writeScript(tmp, "fail.py", """
    import sys
    sys.stderr.write("Traceback: simulated parser failure\\n")
    sys.exit(2)
    """)
    let failSocket = PSDParserSocket(pythonPath: python, bridgePath: failScript, timeoutSeconds: 10)
    let failRes = failSocket.parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(!failRes.isValid, "非零退出 → isValid=false")
    check((failRes.failureReason ?? "").contains("exit code 2"),
          "失败原因含 exit code 2", failRes.failureReason ?? "nil")
    check(!failRes.warnings.isEmpty, "失败时 warnings 非空（不显示绿色成功）", "\(failRes.warnings.count) 条")

    // ── 6. 坏 JSON / 缺 layers / 缺画幅 → 都显式失败 ─────────────────
    let badJSON = writeScript(tmp, "bad_json.py", "print('this is not json')\n")
    let badJSONRes = PSDParserSocket(pythonPath: python, bridgePath: badJSON, timeoutSeconds: 10)
        .parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(!badJSONRes.isValid && (badJSONRes.failureReason ?? "").contains("JSON"),
          "坏 JSON → 显式失败", badJSONRes.failureReason ?? "nil")

    let noLayers = writeScript(tmp, "no_layers.py", "print('{\"width\":100,\"height\":100}')\n")
    let noLayersRes = PSDParserSocket(pythonPath: python, bridgePath: noLayers, timeoutSeconds: 10)
        .parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(!noLayersRes.isValid && (noLayersRes.failureReason ?? "").contains("layers"),
          "缺 layers 字段 → 显式失败", noLayersRes.failureReason ?? "nil")

    let noCanvas = writeScript(tmp, "no_canvas.py", "print('{\"layers\":[]}')\n")
    let noCanvasRes = PSDParserSocket(pythonPath: python, bridgePath: noCanvas, timeoutSeconds: 10)
        .parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(!noCanvasRes.isValid && (noCanvasRes.failureReason ?? "").contains("画幅"),
          "缺画幅字段 → 显式失败（拒绝 1920×1080 兜底）", noCanvasRes.failureReason ?? "nil")

    // ── 7. 合法但零图层 → 成功 + 明确警告 ───────────────────────────
    let emptyLayers = writeScript(tmp, "empty_layers.py", "print('{\"width\":200,\"height\":100,\"layers\":[]}')\n")
    let emptyRes = PSDParserSocket(pythonPath: python, bridgePath: emptyLayers, timeoutSeconds: 10)
        .parsePSD(at: "\(root)/tests/data/four_state.psd")
    check(emptyRes.isValid && emptyRes.layers.isEmpty, "零图层 → 解析成功但 layers=0")
    check(emptyRes.warnings.contains(where: { $0.contains("未识别到任何图层") }),
          "零图层 → 有明确警告", emptyRes.warnings.joined(separator: " | "))

    // ── 8. 超时保护 ─────────────────────────────────────────────────
    let sleepScript = writeScript(tmp, "sleep.py", """
    import time
    time.sleep(30)
    print('{"width":1,"height":1,"layers":[]}')
    """)
    let timeoutSocket = PSDParserSocket(pythonPath: python, bridgePath: sleepScript, timeoutSeconds: 2)
    var timeoutRes = PSDParseResult.failure("未执行")
    let timeoutDt = elapsed { timeoutRes = timeoutSocket.parsePSD(at: "\(root)/tests/data/four_state.psd") }
    check(!timeoutRes.isValid, "超时 → isValid=false")
    check((timeoutRes.failureReason ?? "").contains("超时"), "超时原因明确", timeoutRes.failureReason ?? "nil")
    check(timeoutDt >= 1.5 && timeoutDt < 10, "2s 阈值下按时返回（未永久挂起）", String(format: "%.2fs", timeoutDt))

    // ── 9. 真实损坏文件 + 文件不存在 → 显式失败 ────────────────────
    let corrupt = socket.parsePSD(at: "\(root)/tests/data/corrupted_file.psd")
    check(!corrupt.isValid, "真实损坏 PSD → isValid=false")
    check((corrupt.failureReason ?? "").count > 12, "损坏 PSD 的失败原因不是空话",
          corrupt.failureReason ?? "nil")

    let missing = socket.parsePSD(at: "\(root)/tests/data/__not_exist__.psd")
    check(!missing.isValid && (missing.failureReason ?? "").contains("文件不存在"),
          "文件不存在 → 显式失败", missing.failureReason ?? "nil")

    // ── 10. 诊断文案纯逻辑：失败绝不允许显示绿色「✓ 完整提取」──────
    let dFail = ParseDiagnosticsState.resolve(isValid: false, failureReason: "解析超时（超过 60 秒未返回）",
                                              warnings: ["解析超时（超过 60 秒未返回）"], width: 0, height: 0,
                                              aspectRatio: "—", layerCount: 0)
    check(dFail.tone == .red && dFail.text.contains("解析失败") && !dFail.text.contains("✓"),
          "失败态 → 红色 + 不出现 ✓", "tone=\(dFail.tone)")
    check(dFail.resolutionText.contains("未知"), "失败态画幅不显示 1920×1080 兜底", dFail.resolutionText)

    let dEmpty = ParseDiagnosticsState.resolve(isValid: true, failureReason: nil,
                                               warnings: ["解析成功，但未识别到任何图层（该 PSD 可能只有背景层或全部图层被隐藏）"],
                                               width: 200, height: 100, aspectRatio: "2:1", layerCount: 0)
    check(dEmpty.tone == .orange && !dEmpty.text.contains("✓"),
          "零图层 → 橙色警告，不冒充成功", "tone=\(dEmpty.tone)")

    let dWarn = ParseDiagnosticsState.resolve(isValid: true, failureReason: nil, warnings: ["字体无法验证"],
                                              width: 1080, height: 1920, aspectRatio: "9:16", layerCount: 8)
    check(dWarn.tone == .orange, "有警告 → 橙色", dWarn.text)

    let dOK = ParseDiagnosticsState.resolve(isValid: true, failureReason: nil, warnings: [],
                                            width: 1080, height: 1920, aspectRatio: "9:16", layerCount: 8)
    check(dOK.tone == .green && dOK.text.contains("✓"), "真正的成功 → 绿色", dOK.text)

    try? fm.removeItem(atPath: tmp)

    print("\nRESULT checks=\(checks) failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
    }
}
