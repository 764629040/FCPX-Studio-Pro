import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r41_doctor_harness.swift
//  开发任务单 R41 —— 幽灵插件智能体检自愈与运行环境便携化原生直证
// ═══════════════════════════════════════════════════════════════

@main
final class R41Harness {
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
        print("  FCPX Studio Pro —— R41 幽灵插件医生与便携环境直证")
        print("==================================================")

        test1_DanglingSymlinkAccurateDetection()
        test2_CorruptedXMLAccurateDetection()
        test3_MissingMediaAccurateDetection()
        test4_SelfHealingRelinkEngine()
        test5_SafeQuarantineAndRestore()
        test6_DoctorDashboardAndSidebarIntegration()
        test7_PortableEnvironmentCascadeDetection()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    static func waitOnMainRunLoop(timeout: TimeInterval = 4.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：悬空断链准确检出 (Dangling Symlink Detection 100%)
    // ─────────────────────────────────────────────────────────────
    static func test1_DanglingSymlinkAccurateDetection() {
        print("\n── 判据 1：悬空断链准确检出 (Dangling Symlink) ──")
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r41_dangling_test_\(UUID().uuidString)").path
        let categoryDir = (tempDir as NSString).appendingPathComponent("Titles.localized")
        try? fm.createDirectory(atPath: categoryDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 构造两个悬空断链
        let link1 = (categoryDir as NSString).appendingPathComponent("Ghost_Title_1")
        let link2 = (categoryDir as NSString).appendingPathComponent("Ghost_Title_2")
        let nonExistentTarget1 = "/Volumes/Unplugged_Thunderbolt_Disk_99/Motion/Titles/Ghost_Title_1"
        let nonExistentTarget2 = "/Volumes/Old_SSD/Templates/Ghost_Title_2"

        try? fm.createSymbolicLink(atPath: link1, withDestinationPath: nonExistentTarget1)
        try? fm.createSymbolicLink(atPath: link2, withDestinationPath: nonExistentTarget2)

        let doctor = GhostPluginDoctor()
        let report = doctor.scan(customRoots: [categoryDir])

        check(report.totalScanned >= 2, "成功扫描到目标符号链接", "scanned=\(report.totalScanned)")
        check(report.danglingCount == 2, "悬空断链 100% 检出", "danglingCount=\(report.danglingCount)")

        let danglingIssues = report.issues.filter { $0.symptom == .danglingSymlink }
        check(danglingIssues.count == 2, "病症类型准确标注为 danglingSymlink")
        check(danglingIssues.contains { $0.templateName == "Ghost_Title_1" }, "精准检出 Ghost_Title_1")
        check(danglingIssues.contains { $0.templateName == "Ghost_Title_2" }, "精准检出 Ghost_Title_2")
        check(report.healthScore < 100, "体检评分正常扣分告警", "score=\(report.healthScore) / 100")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：破损 XML 模板准确检出 (Corrupted XML Detection 100%)
    // ─────────────────────────────────────────────────────────────
    static func test2_CorruptedXMLAccurateDetection() {
        print("\n── 判据 2：破损 XML 模板准确检出 (0 字节 / 语法损坏) ──")
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r41_corrupted_test_\(UUID().uuidString)").path
        let categoryDir = (tempDir as NSString).appendingPathComponent("Effects.localized")
        try? fm.createDirectory(atPath: categoryDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 1. 0 字节损坏模板
        let zeroDir = (categoryDir as NSString).appendingPathComponent("Zero_Effect.moef")
        try? fm.createDirectory(atPath: zeroDir, withIntermediateDirectories: true)
        let zeroFile = (zeroDir as NSString).appendingPathComponent("Zero_Effect.moef")
        fm.createFile(atPath: zeroFile, contents: Data()) // 0 bytes

        // 2. 语法损坏模板（未闭合标签）
        let brokenDir = (categoryDir as NSString).appendingPathComponent("Broken_Effect.moef")
        try? fm.createDirectory(atPath: brokenDir, withIntermediateDirectories: true)
        let brokenFile = (brokenDir as NSString).appendingPathComponent("Broken_Effect.moef")
        let invalidXML = "<ozml version=\"5.13\"><header><unclosed_tag>corrupted content</header></ozml>"
        try? invalidXML.write(toFile: brokenFile, atomically: true, encoding: .utf8)

        // 3. 正常模板对比项
        let normalDir = (categoryDir as NSString).appendingPathComponent("Normal_Effect.moef")
        try? fm.createDirectory(atPath: normalDir, withIntermediateDirectories: true)
        let normalFile = (normalDir as NSString).appendingPathComponent("Normal_Effect.moef")
        let validXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ozml version=\"5.13\"><template><name>Normal</name></template></ozml>"
        try? validXML.write(toFile: normalFile, atomically: true, encoding: .utf8)

        let doctor = GhostPluginDoctor()
        let report = doctor.scan(customRoots: [categoryDir])

        check(report.corruptedXMLCount == 2, "破损 XML 100% 准确检出", "corruptedCount=\(report.corruptedXMLCount)")
        let cIssues = report.issues.filter { $0.symptom == .corruptedXML }
        check(cIssues.contains { $0.templateName == "Zero_Effect" }, "精准检出 0 字节破损模板")
        check(cIssues.contains { $0.templateName == "Broken_Effect" }, "精准检出 XML 语法損毁模板")
        check(!cIssues.contains { $0.templateName == "Normal_Effect" }, "正常模板无误报")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：贴图媒体缺失准确检出 (Missing Media Detection 100%)
    // ─────────────────────────────────────────────────────────────
    static func test3_MissingMediaAccurateDetection() {
        print("\n── 判据 3：贴图媒体缺失准确检出 (Missing Media) ──")
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r41_media_test_\(UUID().uuidString)").path
        let categoryDir = (tempDir as NSString).appendingPathComponent("Generators.localized")
        try? fm.createDirectory(atPath: categoryDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 模板内部引用不存在的贴图
        let genDir = (categoryDir as NSString).appendingPathComponent("MissingMedia_Gen.motn")
        try? fm.createDirectory(atPath: genDir, withIntermediateDirectories: true)
        let genFile = (genDir as NSString).appendingPathComponent("MissingMedia_Gen.motn")
        let xmlWithMissingMedia = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ozml version="5.13">
          <factory id="1" name="Footage" key="1000">
            <footage id="1" name="Texture_Alpha.png">
              <fileURL>Media/Texture_Alpha.png</fileURL>
            </footage>
          </factory>
        </ozml>
        """
        try? xmlWithMissingMedia.write(toFile: genFile, atomically: true, encoding: .utf8)

        let doctor = GhostPluginDoctor()
        let report = doctor.scan(customRoots: [categoryDir])

        check(report.missingMediaCount == 1, "贴图媒体缺失 100% 准确检出", "missingCount=\(report.missingMediaCount)")
        let mIssues = report.issues.filter { $0.symptom == .missingMedia }
        check(mIssues.first?.templateName == "MissingMedia_Gen", "精准识别出缺图模板 MissingMedia_Gen")
        check(mIssues.first?.detail.contains("Texture_Alpha.png") == true, "精准定位缺失媒体文件名 Texture_Alpha.png")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：智能重连自愈引擎 (Self-Healing Relink 100%)
    // ─────────────────────────────────────────────────────────────
    static func test4_SelfHealingRelinkEngine() {
        print("\n── 判据 4：智能重连自愈引擎 (Self-Healing Relink) ──")
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r41_relink_test_\(UUID().uuidString)").path

        let userTitles = (tempDir as NSString).appendingPathComponent("User/Motion Templates.localized/Titles.localized")
        let newDisk = (tempDir as NSString).appendingPathComponent("MountedVolume_NewSSD/Projects/Templates/Epic_Opener")

        try? fm.createDirectory(atPath: userTitles, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: newDisk, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 在新盘创建真实模板实体
        let realMoti = (newDisk as NSString).appendingPathComponent("Epic_Opener.moti")
        let validXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ozml version=\"5.13\"><template></template></ozml>"
        try? validXML.write(toFile: realMoti, atomically: true, encoding: .utf8)

        // 在用户级建立指向不存在旧盘的断链软链接
        let brokenLink = (userTitles as NSString).appendingPathComponent("Epic_Opener")
        let oldDiskTarget = "/Volumes/OldDisk_Unplugged/Projects/Templates/Epic_Opener"
        try? fm.createSymbolicLink(atPath: brokenLink, withDestinationPath: oldDiskTarget)

        let doctor = GhostPluginDoctor()
        doctor.additionalSearchRoots = [newDisk, (tempDir as NSString).appendingPathComponent("MountedVolume_NewSSD")]

        // 1. 扫描断链并自动探测新候选路径
        let report1 = doctor.scan(customRoots: [userTitles])
        check(report1.danglingCount == 1, "检出待自愈的悬空断链")
        guard let issue = report1.issues.first(where: { $0.templateName == "Epic_Opener" }) else {
            check(false, "未找到 Epic_Opener 故障项")
            return
        }

        check(issue.canAutoRelink, "智能自愈引擎成功探测到新有效路径")
        check(issue.relinkCandidatePath == newDisk, "候选路径精准命中新位置", "candidate=\(issue.relinkCandidatePath ?? "")")

        // 2. 触发一键自愈
        let relinkSuccess = (try? doctor.relink(issue: issue)) ?? false
        check(relinkSuccess, "触发自愈重连执行成功")

        // 3. 验证软链接已重构为有效链接
        var isDir: ObjCBool = false
        let linkExists = fm.fileExists(atPath: brokenLink, isDirectory: &isDir)
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: brokenLink)) ?? ""
        check(linkExists, "自愈后软链接重新恢复存在")
        check(resolved == newDisk, "软链接目标已精准更新为新路径", "dest=\(resolved)")

        // 4. 二次复检：断链病症归零
        let report2 = doctor.scan(customRoots: [userTitles])
        check(report2.danglingCount == 0, "二次体检：悬空断链已彻底清零达成 100% 自愈")
        check(report2.healthScore == 100, "自愈后健康评分恢复至 100 分满分")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：安全隔离区与一键还原 (Quarantine & Restore)
    // ─────────────────────────────────────────────────────────────
    static func test5_SafeQuarantineAndRestore() {
        print("\n── 判据 5：安全隔离区与一键还原 (Quarantine & Restore) ──")
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r41_quarantine_test_\(UUID().uuidString)").path
        let categoryDir = (tempDir as NSString).appendingPathComponent("Transitions.localized")
        let quarantineDir = (tempDir as NSString).appendingPathComponent("_Quarantine")

        try? fm.createDirectory(atPath: categoryDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: quarantineDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 创建一个无法修复的破损转场
        let brokenItemDir = (categoryDir as NSString).appendingPathComponent("Glitch_Corrupted.motr")
        try? fm.createDirectory(atPath: brokenItemDir, withIntermediateDirectories: true)
        let brokenFile = (brokenItemDir as NSString).appendingPathComponent("Glitch_Corrupted.motr")
        fm.createFile(atPath: brokenFile, contents: Data()) // 0 byte

        let doctor = GhostPluginDoctor()
        doctor.customQuarantineDir = quarantineDir

        let report1 = doctor.scan(customRoots: [categoryDir])
        check(report1.corruptedXMLCount == 1, "体检查出 1 项高危破损模板")
        guard let issue = report1.issues.first else {
            check(false, "未能提取破损 issue")
            return
        }

        // 1. 触发一键安全隔离
        let record = try? doctor.quarantine(issue: issue)
        check(record != nil, "成功生成隔离记录并完成迁移")
        check(!fm.fileExists(atPath: brokenFile), "原目录破损文件已彻底移出（杜绝 FCPX 红屏闪退）")
        check(fm.fileExists(atPath: record?.quarantinePath ?? ""), "破损文件安全存放在 _Quarantine 隔离区中")

        let ledger = doctor.loadQuarantineLedger()
        check(ledger.count == 1, "隔离账本成功持久化记录")
        check(ledger.first?.templateName == "Glitch_Corrupted", "账本记录包含完整模板标识与病症元数据")

        // 2. 隔离后复检：FCPX 扫描树中隐去
        let report2 = doctor.scan(customRoots: [categoryDir])
        check(report2.corruptedXMLCount == 0, "隔离后原分类目录体检破损数清零")

        // 3. 触发一键还原
        let restored = (try? doctor.restore(recordId: record!.id)) ?? false
        check(restored, "一键还原触发成功")
        check(fm.fileExists(atPath: record!.originalPath), "破损文件已原路复原至原始分类路径")
        check(!fm.fileExists(atPath: record!.quarantinePath), "隔离区临时文件已安全清理")

        let updatedLedger = doctor.loadQuarantineLedger()
        check(updatedLedger.isEmpty, "还原后隔离账本条目安全注销")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：医生控制台与侧边栏挂载
    // ─────────────────────────────────────────────────────────────
    static func test6_DoctorDashboardAndSidebarIntegration() {
        print("\n── 判据 6：医生控制台交互与侧边栏挂载 ──")
        let assetHub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))

        check(assetHub.sidebarView != nil, "左侧深色侧边栏存在")
        check(assetHub.sidebarButtons.count >= 8, "侧边栏按钮包含全部功能入口", "count=\(assetHub.sidebarButtons.count)")

        // 验证侧边栏包含 🩺 幽灵插件医生
        let doctorBtn = assetHub.sidebarButtons.first(where: { $0.title.contains("幽灵插件医生") })
        check(doctorBtn != nil, "侧边栏【系统工具】成功挂载【🩺 幽灵插件医生】入口")

        check(assetHub.doctorDashboardView != nil, "AssetHubView 内嵌 PluginDoctorDashboardView 控制台")
        check(assetHub.doctorContainerView != nil, "医生容器视图已就绪")

        // 切换至幽灵插件医生
        if let btn = doctorBtn {
            assetHub.selectSidebarItem(at: btn.tag)
            check(assetHub.currentSidebarIndex == btn.tag, "侧边栏激活选中幽灵插件医生")
            check(assetHub.doctorContainerView.isHidden == false, "医生控制台主容器无缝呈现")
            check(assetHub.templateContainerView.isHidden == true, "模板主容器自动隐藏")
        }

        // 验证仪表盘卡片与操作按钮
        let dash = assetHub.doctorDashboardView!
        check(dash.scoreCardValueLabel != nil, "健康体检评分仪表卡片存在")
        check(dash.danglingCardLabel != nil, "悬空断链指标卡片存在")
        check(dash.corruptedCardLabel != nil, "破损 XML 指标卡片存在")
        check(dash.mediaCardLabel != nil, "贴图缺失指标卡片存在")
        check(dash.scanButton != nil, "【🩺 全面体检】按钮就绪")
        check(dash.relinkAllButton != nil, "【⚡️ 一键智能自愈】按钮就绪")
        check(dash.quarantineAllButton != nil, "【🛡️ 一键隔离破损】按钮就绪")
        check(dash.restoreAllButton != nil, "【↩️ 一键还原隔离】按钮就绪")
        check(dash.issuesTableView != nil, "故障诊断列表 TableView 就绪")

        // 模拟注入体检报告并验证 UI 联动
        let mockIssues = [
            GhostIssue(templateName: "Test_Dangling", category: "Titles.localized", symptom: .danglingSymlink,
                       path: "/test/dangling", targetPath: "/unplugged", detail: "目标缺失", suggestedFix: "重连", canAutoRelink: true),
            GhostIssue(templateName: "Test_Corrupted", category: "Effects.localized", symptom: .corruptedXML,
                       path: "/test/corrupted", detail: "0字节", suggestedFix: "隔离")
        ]
        let mockReport = DoctorReport(totalScanned: 10, healthyCount: 8, issues: mockIssues)
        dash.applyReport(mockReport)

        check(dash.scoreCardValueLabel.stringValue == "\(mockReport.healthScore)", "仪表盘评分准确呈现", "score=\(dash.scoreCardValueLabel.stringValue)")
        check(dash.danglingCardLabel.stringValue == "1", "悬空断链卡片计数精准更新为 1")
        check(dash.corruptedCardLabel.stringValue == "1", "破损 XML 卡片计数精准更新为 1")
        check(dash.issues.count == 2, "故障列表数据源精准更新为 2 项")
        check(dash.emptyHintLabel.isHidden == true, "有病症时空白占位自动隐藏")

        // 验证多级内存缓存
        let cached = AssetCacheManager.shared.getDoctorReport()
        check(cached != nil, "DoctorReport 成功写入多级内存缓存秒级复用")
        check(cached?.healthScore == mockReport.healthScore, "缓存报告数据一致")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 7：便携环境级联探测与完整性自检 (D-82)
    // ─────────────────────────────────────────────────────────────
    static func test7_PortableEnvironmentCascadeDetection() {
        print("\n── 判据 7：便携环境级联探测与完整性自检 (D-82) ──")
        let cfg = AppConfig.shared

        check(!cfg.pythonPath.isEmpty, "Python 解释器路径探测成功", "path=\(cfg.pythonPath)")
        check(FileManager.default.fileExists(atPath: cfg.pythonPath), "探测到的 Python 解释器在磁盘真实存在")
        check(!cfg.bridgeScriptPath.isEmpty, "cli_bridge 路径探测成功", "bridge=\(cfg.bridgeScriptPath)")
        check(FileManager.default.fileExists(atPath: cfg.bridgeScriptPath), "探测到的 cli_bridge.py 在磁盘真实存在")
        check(cfg.hasPsdTools, "核心依赖 psd-tools 完整性自检通过")

        let (ready, summary) = cfg.evaluateEnvironment()
        check(ready, "运行环境综合评估为就绪状态 (isReady = true)")
        check(!summary.isEmpty, "运行环境摘要文案已生成", "summary=\(summary)")
    }
}
