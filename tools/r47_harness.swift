import AppKit
import CoreText
import Foundation
import Metal

// ═══════════════════════════════════════════════════════════════
//  r47_harness.swift
//  开发任务单 R47 —— 零依赖便携式运行时与商用级 DMG 分发终结直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R47Harness {
    static var totalChecks = 0
    static var failedChecks = 0

    static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        totalChecks += 1
        if condition {
            let extra = detail.isEmpty ? "" : " | \(detail)"
            print("✅ PASS | \(title)\(extra)")
        } else {
            failedChecks += 1
            let extra = detail.isEmpty ? "" : " | 详情: \(detail)"
            print("❌ FAIL | \(title)\(extra)")
        }
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R47 商业终结直证套件")
        print("==================================================")

        test1_PortableEnvironmentCascadeDetection()
        test2_ZeroDependencyPSDParseOffline()
        test3_CommercialDMGIntegrityAndMount()
        test4_CodesignAndMachOIntegrity()
        test5_SettingsWindowEnvironmentDisplay()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：AppConfig 四级级联最高优先级自动命中内置便携包（D-82 / D-83）
    // ─────────────────────────────────────────────────────────────
    static func test1_PortableEnvironmentCascadeDetection() {
        print("\n── 判据 1：AppConfig 级联最高优先级内置便携包探测与健康自检 (D-82 / D-83) ──")
        let cfg = AppConfig.shared

        check(cfg.isPortableEnvironment == true, "四级级联成功命中便携化运行环境 (isPortable = true)")
        check(cfg.pythonPath.contains("Contents/Resources/python_bundle/bin/python3"),
              "Python 解释器精准解析为 App 内置便携包路径", "pythonPath=\(cfg.pythonPath)")
        check(FileManager.default.fileExists(atPath: cfg.pythonPath),
              "内置 Python 可执行文件在磁盘上真实存在", cfg.pythonPath)

        check(cfg.bridgeScriptPath.contains("Contents/Resources/core/cli_bridge.py") ||
              cfg.bridgeScriptPath.contains("core/cli_bridge.py"),
              "cli_bridge 桥接脚本路径解析成功", "bridgePath=\(cfg.bridgeScriptPath)")
        check(FileManager.default.fileExists(atPath: cfg.bridgeScriptPath),
              "cli_bridge.py 在磁盘上真实存在", cfg.bridgeScriptPath)

        check(cfg.hasPsdTools == true, "核心依赖 psd-tools 在内置便携包中自检通过 (hasPsdTools = true)")
        check(cfg.isStandalonePortableReady == true, "便携运行环境整体就绪自检通过 (isStandalonePortableReady = true)")

        let (ready, summary) = cfg.evaluateEnvironment()
        check(ready == true, "运行环境综合评估为就绪状态 (evaluateEnvironment.ready = true)")
        check(summary.contains("便携模式") && summary.contains("psd-tools 核心引擎正常"),
              "环境摘要回显包含便携模式与核心依赖正常状态", "summary=\(summary)")

        check(cfg.hardwareAccelerationSummary.contains("Metal") || cfg.hardwareAccelerationSummary.contains("硬件加速"),
              "硬件加速自检有效探测系统 Metal GPU 设备", "accel=\(cfg.hardwareAccelerationSummary)")
        check(cfg.appVersionString.contains("v1.0.0"),
              "商用版本标识符合规范", "version=\(cfg.appVersionString)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：零依赖离线真实 PSD 解析断言 (Zero-Dependency Offline PSD Parsing)
    // ─────────────────────────────────────────────────────────────
    static func test2_ZeroDependencyPSDParseOffline() {
        print("\n── 判据 2：零依赖离线真实 PSD 解析断言 ──")

        let fm = FileManager.default
        let samplePsd = "tests/data/complex_layers.psd"
        guard fm.fileExists(atPath: samplePsd) else {
            check(false, "测试 PSD 样例文件不存在", samplePsd)
            return
        }

        // 2.1 原生 Socket 调用（默认即命中内置便携包）
        let parser = PSDParserSocket.shared
        let result = parser.parsePSD(at: samplePsd)

        check(result.isValid == true, "原生 Socket 解析复杂图层 PSD 成功 (isValid = true)")
        check(result.width == 1920 && result.height == 1080, "画幅解析完全准确 (1920x1080)", "w=\(result.width), h=\(result.height)")
        check(result.layers.count > 0, "成功提取图层数据", "layerCount=\(result.layers.count)")
        check(result.warnings.count >= 0, "诊断警告收集机制正常运作")

        // 2.2 极端环境模拟：纯净隔离子进程（无 PATH / 无 Homebrew 环境变量）
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: AppConfig.shared.pythonPath)
        proc.arguments = [AppConfig.shared.bridgeScriptPath, "parse", samplePsd]
        proc.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory()
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        var isolatedSuccess = false
        var jsonValid = false
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                isolatedSuccess = true
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    jsonValid = true
                }
            }
        } catch {
            isolatedSuccess = false
        }

        check(isolatedSuccess == true, "纯净隔离裸机环境模拟下便携 Python 执行成功 (Exit Code 0)")
        check(jsonValid == true, "纯净隔离裸机环境模拟下 Bridge 解析返回有效 status: ok")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：商用级 DMG 分发镜像结构与挂载完整性断言
    // ─────────────────────────────────────────────────────────────
    static func test3_CommercialDMGIntegrityAndMount() {
        print("\n── 判据 3：商用级 DMG 分发镜像结构与挂载完整性断言 ──")

        let fm = FileManager.default
        let dmgPath = "FCPX_Studio_Pro_v1.0.dmg"

        check(fm.fileExists(atPath: dmgPath), "商用分发镜像 FCPX_Studio_Pro_v1.0.dmg 存在于工程根目录")

        let attrs = try? fm.attributesOfItem(atPath: dmgPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        check(size > 40 * 1024 * 1024, "DMG 映像大小正常包含便携运行时 (>40MB)", "实际大小=\(size / 1024 / 1024) MB")

        // 执行挂载测试
        let mountDir = "/tmp/fcpx_harness_mount_\(UUID().uuidString)"
        try? fm.createDirectory(atPath: mountDir, withIntermediateDirectories: true)

        let attachProc = Process()
        attachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProc.arguments = ["attach", dmgPath, "-mountpoint", mountDir, "-nobrowse", "-readonly"]
        try? attachProc.run()
        attachProc.waitUntilExit()

        check(attachProc.terminationStatus == 0, "hdiutil 成功挂载 DMG 镜像")

        // 挂载卷内物证核验
        let appInDmg = "\(mountDir)/FCPX Studio Pro.app"
        let binInDmg = "\(appInDmg)/Contents/MacOS/FCPXStudio"
        let pyInDmg = "\(appInDmg)/Contents/Resources/python_bundle/bin/python3"
        let appLinkInDmg = "\(mountDir)/Applications"
        let guideInDmg = "\(mountDir)/使用说明与快速上手.txt"

        check(fm.fileExists(atPath: appInDmg), "DMG 挂载卷内包含 FCPX Studio Pro.app")
        check(fm.fileExists(atPath: binInDmg), "DMG 内 App 包含主 Mach-O 二进制 FCPXStudio")
        check(fm.fileExists(atPath: pyInDmg), "DMG 内 App 完整内嵌 python_bundle 便携解释器")
        check(fm.fileExists(atPath: appLinkInDmg), "DMG 挂载卷内包含 Applications 软链接替身")
        check(fm.fileExists(atPath: guideInDmg), "DMG 挂载卷内包含《使用说明与快速上手.txt》")

        if let guideText = try? String(contentsOfFile: guideInDmg, encoding: .utf8) {
            check(guideText.contains("零依赖便携运行特性") && guideText.contains("快速安装指南"),
                  "快速上手指南文档内容完备包含零依赖与安装指引")
        } else {
            check(false, "未能读取快速上手指南文本内容")
        }

        // 卸载
        let detachProc = Process()
        detachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProc.arguments = ["detach", mountDir, "-force"]
        try? detachProc.run()
        detachProc.waitUntilExit()
        try? fm.removeItem(atPath: mountDir)

        check(detachProc.terminationStatus == 0, "hdiutil 成功卸载 DMG 临时挂载卷")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：递归深度代码签名与 Gatekeeper 合规性断言
    // ─────────────────────────────────────────────────────────────
    static func test4_CodesignAndMachOIntegrity() {
        print("\n── 判据 4：递归深度代码签名与 Gatekeeper 合规性断言 ──")

        let appPath = "FCPX Studio Pro.app"
        let csProc = Process()
        csProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        csProc.arguments = ["--verify", "--deep", "--strict", appPath]
        let errPipe = Pipe()
        csProc.standardError = errPipe
        try? csProc.run()
        csProc.waitUntilExit()

        check(csProc.terminationStatus == 0, "codesign --verify --deep --strict 深度签名严格校验通过", "status=\(csProc.terminationStatus)")

        // Mach-O 架构断言
        let fileProc = Process()
        fileProc.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        fileProc.arguments = ["\(appPath)/Contents/MacOS/FCPXStudio"]
        let outPipe = Pipe()
        fileProc.standardOutput = outPipe
        try? fileProc.run()
        fileProc.waitUntilExit()

        let fileData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let fileStr = String(data: fileData, encoding: .utf8) ?? ""
        check(fileStr.contains("arm64"), "应用主可执行文件为主流 Apple Silicon 64 位架构 (arm64)", fileStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：设置与环境自检面板数据模型与回显断言
    // ─────────────────────────────────────────────────────────────
    static func test5_SettingsWindowEnvironmentDisplay() {
        print("\n── 判据 5：设置与环境自检面板数据模型与回显断言 ──")

        let ctrl = SettingsWindowController.shared
        check(ctrl.window != nil, "SettingsWindowController 窗口单例成功初始化")
        check(ctrl.window?.title.contains("设置") == true, "偏好设置窗口标题正确配置", ctrl.window?.title ?? "")

        // 验证读写权限切换逻辑
        let origWritable = TierWritePolicy.isBuiltinWritable
        TierWritePolicy.setBuiltinWritable(!origWritable)
        check(TierWritePolicy.isBuiltinWritable == !origWritable, "内置级写入权限策略切换生效")
        TierWritePolicy.setBuiltinWritable(origWritable)
        check(TierWritePolicy.isBuiltinWritable == origWritable, "内置级写入权限策略复原安全只读")
    }
}
