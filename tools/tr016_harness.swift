import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// tools/tr016_harness.swift
// TR-016 单条隔离二次确认 —— 行为验证 + AppKit 控件离屏渲染物证
//
// 机制复用 tools/tr013_harness.swift：
//   · CapturedAlert 结构 + alertResponseHandler 决策注入闭包 + decisions 队列
//   · check / section / PASS-FAIL-VERDICT 输出骨架
//   · renderAlert 自绘面板（未 runModal 的 NSAlert 子视图不绘制；文字一律固定校准色）
//
// 编译（zsh 强制拆分）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr016_harness.swift -o /tmp/tr016_harness
//
// 现场约束：FCPX 与 R2.app 都已退出且本轮禁止启动/激活/前置任何 App。
//   本 harness 自身 setActivationPolicy(.prohibited)，不 open、不 launchApplication、
//   不 screencapture、不抢焦点；不碰真实模板库 / 任何 .app 包 / 外置卷用户数据。
//   所有合成模板与隔离区都在 /tmp，startScan 由 startScanOverride 计数并阻止真实全盘扫描。
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TR016Harness {

    struct CapturedAlert {
        let title: String
        let message: String
        let buttons: [String]
    }

    // MARK: – 四个字符串（逐字，与需求一字不差）
    static let kTitle   = "确认隔离该插件?"
    static let kMessage = "会将该插件文件移入隔离区，正在使用它的工程可能报缺失；可用『还原隔离』恢复"
    static let kCancel  = "取消"
    static let kConfirm = "确认隔离"
    static var kButtons: [String] { [kCancel, kConfirm] }

    // 单条按钮顺序：取消(第 1 个) / 确认隔离(第 2 个)
    static let singleCancelDecision  = NSApplication.ModalResponse.alertFirstButtonReturn
    static let singleConfirmDecision = NSApplication.ModalResponse.alertSecondButtonReturn
    // 批量按钮顺序：执行隔离(第 1 个) / 取消(第 2 个)
    static let batchCancelDecision   = NSApplication.ModalResponse.alertSecondButtonReturn

    static var pass = 0
    static var fail = 0
    static var captured: [CapturedAlert] = []
    static var decisions: [NSApplication.ModalResponse] = []

    static func check(_ cond: Bool, _ label: String, _ detail: String = "") {
        if cond {
            pass += 1
            print("  ✅ \(label)")
        } else {
            fail += 1
            print("  ❌ \(label)   \(detail)")
        }
    }

    static func section(_ title: String) {
        print("\n=== \(title) ===")
    }

    /// 从源码中切出某个 handler 的函数体，用于静态举证。
    static func bodySlice(_ text: String, from: String, to: String? = nil) -> String {
        guard let a = text.range(of: from) else { return "" }
        let tail = text[a.lowerBound...]
        if let end = to, let b = tail.range(of: end) {
            return String(tail[..<b.lowerBound])
        }
        return String(tail)
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    static func main() {
        // 本进程自身不激活、不进 Dock、不抢焦点；绝不启动 FCPX / R2.app / 任何 App。
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let fm = FileManager.default
        let projectRoot = fm.fileExists(atPath: "FCPXStudioNative")
            ? fm.currentDirectoryPath
            : "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
        let evidenceDir = (projectRoot as NSString).appendingPathComponent("reports/verify_tr016")
        try? fm.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        print("TR-016 单条隔离二次确认 · 行为验证")
        print("时间: \(Date())")
        print("项目根: \(projectRoot)")
        print("硬约束: 不启动/激活/前置任何 App；不跑真机；不 open / 不 screencapture / 不抢焦点")
        print("隔离现场: 合成模板与隔离区全部位于 /tmp；真实模板库 ~/Movies/Motion Templates.localized 零读写")

        // ── 0. 现场 ───────────────────────────────────────────────
        section("0. 现场准备（全 /tmp 合成，不碰真实模板库）")

        let sandbox   = "/tmp/tr016_sandbox"
        let tplCatDir = (sandbox as NSString).appendingPathComponent("Templates/Titles.localized")
        let tplName   = "TR016_合成模板"
        let tplDir    = (tplCatDir as NSString).appendingPathComponent(tplName)
        let motiPath  = (tplDir as NSString).appendingPathComponent("\(tplName).moti")
        let qDir      = (sandbox as NSString).appendingPathComponent("Quarantine")
        let ledgerPath = (qDir as NSString).appendingPathComponent("quarantine_ledger.json")

        func wipeSandbox() { try? fm.removeItem(atPath: sandbox) }
        func qItems() -> [String] { (try? fm.contentsOfDirectory(atPath: qDir)) ?? [] }

        wipeSandbox()
        do {
            try fm.createDirectory(atPath: tplDir, withIntermediateDirectories: true)
            try Data("<?xml version=\"1.0\"?><motion/> <!-- TR016 synthetic -->".utf8)
                .write(to: URL(fileURLWithPath: motiPath))
        } catch {
            print("FATAL: 无法创建 /tmp 合成模板: \(error.localizedDescription)")
            return
        }

        let doctor = GhostPluginDoctor.shared
        doctor.customQuarantineDir = qDir

        check(fm.fileExists(atPath: motiPath), "合成模板已在 /tmp 就位", motiPath)
        check(doctor.quarantineBaseDirectory == qDir, "隔离区已重定向到 /tmp", doctor.quarantineBaseDirectory)
        check(!qDir.hasPrefix("/Users") && qDir.hasPrefix("/tmp/"), "隔离区不在用户目录/外置卷", qDir)
        check(qItems().isEmpty, "隔离区初始无条目")
        check(!fm.fileExists(atPath: ledgerPath), "ledger 初始不存在")
        check(doctor.loadQuarantineLedger().isEmpty, "ledger 初始 0 条记录")

        // 合成 GhostIssue（构造签名见 GhostPluginDoctor.swift:60-80）
        let issue = GhostIssue(
            id: "TR016-ISSUE-0001",
            templateName: tplName,
            category: "Titles.localized",
            symptom: .corruptedXML,
            path: motiPath,
            targetPath: nil,
            detail: "TR016 合成破损 XML，仅用于 harness",
            suggestedFix: "一键安全隔离至 _Quarantine",
            canAutoRelink: false
        )
        let report = DoctorReport(totalScanned: 1, healthyCount: 0,
                                  issues: [issue], quarantineRecords: [])

        let view = PluginDoctorDashboardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        // issues 是 public private(set)：走项目既有注入口 applyReport(_:)，不改访问级别。
        view.applyReport(report)
        check(view.issues.count == 1, "经既有注入口 applyReport 预置 issues = 1", "\(view.issues.count)")
        check(view.currentReport?.issues.count == 1, "currentReport 同步预置（批量入口的 guard 可通过）")
        check(AssetCacheManager.shared.getDoctorReport() != nil,
              "applyReport 设置了 doctor 内存缓存（作为 invalidateAll 观察基线）")

        let statusBefore = view.statusSummaryLabel?.stringValue ?? ""

        var startScanCalls = 0
        view.startScanOverride = { startScanCalls += 1 }
        view.alertResponseHandler = { alert in
            let rec = CapturedAlert(title: alert.messageText,
                                    message: alert.informativeText,
                                    buttons: alert.buttons.map { $0.title })
            captured.append(rec)
            let d = decisions.isEmpty ? singleCancelDecision : decisions.removeFirst()
            let flat = rec.message.replacingOccurrences(of: "\n", with: " ⏎ ")
            print("    [ALERT] \(rec.title) | \(flat)")
            print("    [ALERT] buttons=\(rec.buttons) -> response=\(d.rawValue)")
            return d
        }
        check(view.alertResponseHandler != nil && view.startScanOverride != nil,
              "TR-013 风格注入点已挂上（生产恒 nil，不弱化确认）")

        // ── 1. 源码静态证据 ─────────────────────────────────────────
        section("1. 源码静态证据（grep 单条 / 批量 handler）")
        let relSrc = "FCPXStudioNative/Sources/FCPXStudio/Views/PluginDoctorDashboardView.swift"
        let absSrc = (projectRoot as NSString).appendingPathComponent(relSrc)
        let srcPath = fm.fileExists(atPath: relSrc) ? relSrc : absSrc
        guard let src = try? String(contentsOfFile: srcPath, encoding: .utf8) else {
            print("FATAL: 读不到源码 \(srcPath)")
            return
        }
        let singleBody = bodySlice(src, from: "func onSingleQuarantineClicked", to: nil)
        let batchBody  = bodySlice(src, from: "func onQuarantineAllClicked",
                                   to: "func onRestoreAllClicked")
        check(!singleBody.isEmpty && !batchBody.isEmpty, "成功切出两个 handler 函数体")

        check(singleBody.contains("NSAlert()"), "单条 handler 内含 NSAlert")
        check(occurrences("NSAlert()", in: singleBody) == 1, "单条 handler 只有 1 个 NSAlert（不重复弹框）")
        check(singleBody.contains(kTitle), "单条 handler 含标题「\(kTitle)」")
        check(singleBody.contains(kMessage), "单条 handler 含正文「\(kMessage)」")
        check(singleBody.contains("addButton(withTitle: \"\(kCancel)\")"), "单条 handler 含按钮「\(kCancel)」")
        check(singleBody.contains("addButton(withTitle: \"\(kConfirm)\")"), "单条 handler 含按钮「\(kConfirm)」")
        check(singleBody.contains("quarantine(issue: issue)"), "确认后才执行原有 quarantine 逻辑")
        if let p = singleBody.range(of: "presentConfirmation"),
           let q = singleBody.range(of: "quarantine(issue: issue)") {
            check(p.lowerBound < q.lowerBound, "确认判定位于 quarantine 调用之前")
        } else {
            check(false, "确认判定位于 quarantine 调用之前")
        }

        check(batchBody.contains("NSAlert()"), "批量 handler 保留自己原有的 NSAlert 确认")
        check(occurrences("NSAlert()", in: batchBody) == 1, "批量 handler 只弹 1 个框")
        check(batchBody.contains("quarantineAll(issues: report.issues)"), "批量 handler 保留原有 quarantineAll 逻辑")
        check(!batchBody.contains(kTitle), "批量 handler 不含单条确认标题")
        check(!batchBody.contains(kMessage), "批量 handler 不含单条确认正文")
        check(!batchBody.contains("\"\(kConfirm)\""), "批量 handler 不含「\(kConfirm)」按钮")
        check(!batchBody.contains("onSingleQuarantineClicked"), "批量 handler 不调用单条 handler（不循环）")
        print("    源码: \(srcPath)")

        // ── 2. 取消路径 ─────────────────────────────────────────────
        section("2. 单条入口 → 「取消」：零文件操作")
        captured = []
        decisions = [singleCancelDecision]
        let btn = NSButton()
        btn.tag = 0
        _ = view.perform(NSSelectorFromString("onSingleQuarantineClicked:"), with: btn)

        check(captured.count == 1, "出现且仅出现 1 个确认弹窗", "实际 \(captured.count) 个")
        var singleSnapshot: CapturedAlert? = nil
        if let a = captured.first {
            singleSnapshot = a
            check(a.title == kTitle, "标题逐字相等「\(kTitle)」", "实际: \(a.title)")
            check(a.message == kMessage, "正文逐字相等「\(kMessage)」", "实际: \(a.message)")
            check(a.buttons == kButtons, "两个按钮逐字且顺序相等 \(kButtons)", "实际: \(a.buttons)")
            check(a.buttons.count == 2, "按钮数量 = 2", "\(a.buttons.count)")
            check(a.buttons[0] == kCancel, "第 1 个按钮 = 取消", a.buttons[0])
            check(a.buttons[1] == kConfirm, "第 2 个按钮 = 确认隔离", a.buttons[1])
        }
        check(fm.fileExists(atPath: tplDir), "取消后合成模板目录仍在原位")
        check(fm.fileExists(atPath: motiPath), "取消后 .moti 源文件仍在原位")
        check(qItems().isEmpty, "取消后 /tmp 隔离区无新增项", qItems().joined(separator: ","))
        check(!fm.fileExists(atPath: ledgerPath), "取消后未生成 ledger 文件")
        check(doctor.loadQuarantineLedger().isEmpty, "取消后 ledger 无新增记录")
        check(startScanCalls == 0, "取消后 startScan 调用 0 次", "\(startScanCalls)")
        check(AssetCacheManager.shared.getDoctorReport() != nil,
              "取消后 doctor 缓存未被 invalidateAll 清掉（0 次失效）")
        check((view.statusSummaryLabel?.stringValue ?? "") == statusBefore,
              "取消后状态栏文本未变（无 startScan / 成功提示副作用）",
              view.statusSummaryLabel?.stringValue ?? "")
        print("    取消 = 未调用 quarantine、未写 ledger、未 invalidateAll、未 startScan")

        // ── 3. 确认路径 ─────────────────────────────────────────────
        section("3. 单条入口 → 「确认隔离」：执行原有 quarantine 逻辑")
        captured = []
        decisions = [singleConfirmDecision]
        _ = view.perform(NSSelectorFromString("onSingleQuarantineClicked:"), with: btn)

        check(captured.count == 1, "确认路径同样只弹 1 个确认框", "实际 \(captured.count) 个")
        if let a = captured.first {
            check(a.title == kTitle, "确认路径标题逐字相等")
            check(a.message == kMessage, "确认路径正文逐字相等")
            check(a.buttons == kButtons, "确认路径按钮逐字相等")
        }
        check(!fm.fileExists(atPath: tplDir), "确认后合成模板目录已移出原位")
        check(!fm.fileExists(atPath: motiPath), "确认后 .moti 源文件不在原位")
        let qItemsAfter = qItems()
        let movedDirs = qItemsAfter.filter { $0.hasPrefix("Titles.localized_\(tplName)_") }
        check(!movedDirs.isEmpty, "确认后 /tmp 隔离区出现被搬入的模板目录", qItemsAfter.joined(separator: ","))
        if let moved = movedDirs.first {
            let movedMoti = ((qDir as NSString).appendingPathComponent(moved) as NSString)
                .appendingPathComponent("\(tplName).moti")
            check(fm.fileExists(atPath: movedMoti), "被搬入的目录内含原 .moti 文件", movedMoti)
        }
        check(fm.fileExists(atPath: ledgerPath), "确认后生成 quarantine_ledger.json")
        let ledgerAfter = doctor.loadQuarantineLedger()
        check(ledgerAfter.count == 1, "ledger 新增 1 条记录", "实际 \(ledgerAfter.count) 条")
        if let rec = ledgerAfter.first {
            check(rec.templateName == tplName, "ledger 记录 templateName 对应合成模板", rec.templateName)
            check(rec.originalPath == tplDir, "ledger 记录 originalPath 对应 /tmp 原位", rec.originalPath)
            check(fm.fileExists(atPath: rec.quarantinePath), "ledger 记录 quarantinePath 实际存在", rec.quarantinePath)
            print("    [LEDGER] \(rec.templateName) | \(rec.originalPath) -> \(rec.quarantinePath)")
        }
        check(startScanCalls == 1, "确认后 startScan 调用 1 次（原有刷新逻辑执行）", "\(startScanCalls)")
        check(AssetCacheManager.shared.getDoctorReport() == nil,
              "确认后 doctor 缓存被 invalidateAll 清掉（原有失效逻辑执行）")
        let monthlyLedger = qItemsAfter.filter { $0.hasPrefix("quarantine_ledger_") && $0.hasSuffix(".json") }
        check(!monthlyLedger.isEmpty, "ledger 按月归档文件已写出（quarantine 原有逻辑完整）",
              qItemsAfter.joined(separator: ","))
        check(view.statusSummaryLabel?.stringValue == "已移入安全隔离区: \(tplName)",
              "确认后状态栏为原有成功文案", view.statusSummaryLabel?.stringValue ?? "")

        // ── 4. 批量路径不重复弹框 ───────────────────────────────────
        section("4. 批量 onQuarantineAllClicked：单条确认框出现 0 次")
        // 重建合成模板，让批量入口的 guard 与文件状态与第 2 阶段可比。
        try? fm.createDirectory(atPath: tplDir, withIntermediateDirectories: true)
        try? Data("<?xml version=\"1.0\"?><motion/> <!-- TR016 synthetic batch -->".utf8)
            .write(to: URL(fileURLWithPath: motiPath))
        let ledgerCountBeforeBatch = doctor.loadQuarantineLedger().count
        let startScanBeforeBatch = startScanCalls

        captured = []
        decisions = [batchCancelDecision]   // 批量框「取消」，避免执行 quarantineAll
        view.onQuarantineAllClicked()

        check(captured.count == 1, "批量入口只弹 1 个框（不重复弹两个）", "实际 \(captured.count) 个")
        if let b = captured.first {
            check(b.title == "确认一键隔离破损模板？", "弹的是 FCPX-055 批量确认框，不是单条框", b.title)
            check(b.buttons == ["执行隔离", "取消"], "批量按钮保持原有文案", b.buttons.joined(separator: ","))
        }
        let singleTitleHits = captured.filter { $0.title == kTitle }.count
        let singleMessageHits = captured.filter { $0.message == kMessage }.count
        let singleButtonsHits = captured.filter { $0.buttons == kButtons }.count
        check(singleTitleHits == 0, "单条确认标题出现 0 次", "\(singleTitleHits)")
        check(singleMessageHits == 0, "单条确认正文出现 0 次", "\(singleMessageHits)")
        check(singleButtonsHits == 0, "单条按钮组合出现 0 次", "\(singleButtonsHits)")
        check(startScanCalls == startScanBeforeBatch, "批量取消未触发 startScan 副作用")
        check(doctor.loadQuarantineLedger().count == ledgerCountBeforeBatch, "批量取消未写 ledger")
        check(fm.fileExists(atPath: tplDir), "批量取消未搬动 /tmp 合成模板")
        print("    批量 handler 静态已证：不含单条确认文案、不调用 onSingleQuarantineClicked")

        // ── 5. 离屏渲染物证 ─────────────────────────────────────────
        section("5. AppKit 控件离屏渲染 PNG（非真机截屏）")
        var pngOK = false
        if let snap = singleSnapshot {
            // 视觉版式：主按钮在最右；源码 addButton 顺序为 [取消, 确认隔离]，故 reversed。
            let visualButtons = Array(snap.buttons.reversed())
            let pngPath = (evidenceDir as NSString).appendingPathComponent("01_单条隔离二次确认.png")
            pngOK = renderAlert(title: snap.title, message: snap.message,
                                buttons: visualButtons, style: .warning, outPath: pngPath)
            check(pngOK, "01_单条隔离二次确认.png 已写出", pngPath)
            if let attrs = try? fm.attributesOfItem(atPath: pngPath),
               let sz = attrs[.size] as? UInt64 {
                check(sz > 10_000, "PNG 非空且体积合理（\(sz) B）", "\(sz)")
            } else {
                check(false, "PNG 非空且体积合理")
            }
        } else {
            check(false, "捕获到单条确认弹窗用于渲染")
        }

        // ── 6. 硬约束静态复核 ───────────────────────────────────────
        section("6. 硬约束复核（零自动退出/重启 FCPX）")
        let srcRoot = "FCPXStudioNative/Sources/FCPXStudio"
        let banned = ["NSRunningApplication", "relaunch", "killall", "osascript",
                      "quitApp", "restartApp", "terminateApp(",
                      "NSWorkspace.shared.launchApplication"]
        var hits: [String] = []
        if let enumerator = fm.enumerator(atPath: srcRoot) {
            for case let f as String in enumerator where f.hasSuffix(".swift") {
                let p = (srcRoot as NSString).appendingPathComponent(f)
                guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                for word in banned where text.contains(word) { hits.append("\(f): \(word)") }
            }
        }
        check(hits.isEmpty, "全量 Swift 源码无自动退出/重启 FCPX 关键字", hits.joined(separator: " | "))
        print("    本 harness 未调用 open / launchApplication / activate / screencapture；NSApp 策略 = prohibited")
        print("    未读写 ~/Movies/Motion Templates.localized；未读写任何 .app 包；未写外置卷用户数据")

        // ── Z. 清理 ─────────────────────────────────────────────────
        section("Z. 清理 /tmp 现场")
        doctor.customQuarantineDir = nil
        wipeSandbox()
        check(!fm.fileExists(atPath: sandbox), "/tmp 合成现场已清理")
        check(fm.fileExists(atPath: evidenceDir), "reports/verify_tr016 证据目录保留")

        print("\n================ RESULT ================")
        print("PASS = \(pass)   FAIL = \(fail)")
        print(fail == 0 ? "TR-016 VERDICT: PASS" : "TR-016 VERDICT: FAIL")
        print("========================================")
    }

    /// 用 AppKit 控件把捕获到的 NSAlert 标题 / 正文 / 按钮离屏渲染成 PNG。
    /// 复用 TR-013 的做法：未 runModal 的 NSAlert.window 子视图不绘制，故自绘面板；
    /// 文字一律固定校准色（绝不用 .labelColor / .secondaryLabelColor，离屏无 appearance 会白底白字）。
    /// 不 runModal、不抢焦点、不弹屏；图内明确标注为离屏渲染而非真机截屏。
    static func renderAlert(title: String, message: String, buttons: [String],
                            style: NSAlert.Style, outPath: String) -> Bool {
        let width: CGFloat = 780
        let bodyLines = max(2, message.count / 30 + 2)
        let bodyHeight = CGFloat(max(72, bodyLines * 22))
        let height: CGFloat = 214 + bodyHeight

        let canvas = TR016PanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.accent = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)

        let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
        let subInk = NSColor(calibratedWhite: 0.42, alpha: 1)

        let caption = NSTextField(labelWithString:
            "TR-016 · AppKit 离屏渲染，非真机弹窗截屏（文案 = 运行时捕获的真实 NSAlert）")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = subInk
        caption.frame = NSRect(x: 24, y: 8, width: width - 48, height: 16)
        canvas.addSubview(caption)

        let cardTop = height - 34
        let symbol = style == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let icon = NSImageView(frame: NSRect(x: 44, y: cardTop - 62, width: 40, height: 40))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = canvas.accent
        canvas.addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = ink
        titleField.frame = NSRect(x: 100, y: cardTop - 56, width: width - 140, height: 26)
        canvas.addSubview(titleField)

        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = ink
        body.frame = NSRect(x: 100, y: cardTop - 62 - bodyHeight, width: width - 140, height: bodyHeight)
        body.lineBreakMode = .byWordWrapping
        canvas.addSubview(body)

        // macOS 弹窗：主按钮在最右，其余向左排。
        var right = width - 40
        for (idx, bTitle) in buttons.enumerated() {
            let bw: CGFloat = 124
            let btn = NSButton(frame: NSRect(x: right - bw, y: 52, width: bw, height: 30))
            btn.bezelStyle = .rounded
            let isPrimary = (idx == 0)
            btn.bezelColor = isPrimary ? canvas.accent : NSColor(calibratedWhite: 0.86, alpha: 1)
            btn.attributedTitle = NSAttributedString(string: bTitle, attributes: [
                .foregroundColor: isPrimary ? NSColor.white : ink,
                .font: NSFont.systemFont(ofSize: 12, weight: isPrimary ? .semibold : .regular)
            ])
            canvas.addSubview(btn)
            right -= bw + 12
        }

        canvas.layoutSubtreeIfNeeded()
        let bounds = canvas.bounds
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        canvas.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("    wrote \(outPath)  (\(Int(bounds.width))x\(Int(bounds.height)))")
            return true
        } catch {
            print("    write failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// 离屏画布：浅灰底 + 白色圆角弹窗卡片，模拟 macOS NSAlert 版式。
final class TR016PanelView: NSView {
    var accent: NSColor = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        bounds.fill()
        let card = NSRect(x: 20, y: 34, width: bounds.width - 40, height: bounds.height - 54)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor.white.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
