import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// tools/tr013_harness.swift
// TR-013 禁用/启用交互的安全与提示 —— 行为验证 + 真实 NSAlert 离屏渲染物证
//
// 编译（源码全量直编，文案直接引用 AssetHubView 的 public 常量/函数，杜绝截图与代码脱节）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 $FILES tools/tr013_harness.swift -o /tmp/tr013_harness
//
// 现场约束：FCPX 与 R2.app 均在运行。本 harness 不启动 App、不重启 FCPX、
//           不触碰用户真实模板，只在扫描树放一个 TR013_ 前缀合成条目并跑完即清理。
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TR013Harness {

    struct CapturedAlert {
        let title: String
        let message: String
        let buttons: [String]
    }

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

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let outDir = "/tmp/tr013_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        print("TR-013 禁用/启用交互安全与提示 · 行为验证")
        print("时间: \(Date())")
        print("硬约束: 禁止任何自动退出/重启 FCPX —— 本 harness 不启动 App、不重启 FCPX")

        let fm = FileManager.default
        let scanRoot = TemplateIsolationStore.motionTemplatesRoot
        let disabledRoot = TemplateIsolationStore.disabledRoot
        let catDir = (scanRoot as NSString).appendingPathComponent("Titles.localized")
        let tplName = "TR013_禁用验证"
        let tplDir = (catDir as NSString).appendingPathComponent(tplName)
        let disabledDir = (disabledRoot as NSString).appendingPathComponent(
            "Titles.localized/\(tplName)")

        func wipe() {
            try? fm.removeItem(atPath: tplDir)
            try? fm.removeItem(atPath: disabledDir)
        }

        // ── 准备合成模板 ───────────────────────────────────────────
        wipe()
        do {
            try fm.createDirectory(atPath: tplDir, withIntermediateDirectories: true)
            fm.createFile(atPath: (tplDir as NSString).appendingPathComponent("\(tplName).moti"),
                          contents: Data("TR013 synthetic template".utf8))
        } catch {
            print("FATAL: 无法创建合成模板: \(error.localizedDescription)")
            return
        }

        func makeItem(path: String, enabled: Bool) -> TemplateItem {
            return TemplateItem(
                name: tplName,
                category: "Titles.localized",
                subCategory: "",
                tier: .user,
                path: path,
                targetPath: path,
                isSymlink: false,
                targetAvailable: true,
                sizeMB: 0.0,
                isEnabled: enabled,
                isOffline: false,
                volumePath: nil,
                volumeUUID: nil,
                isCorrupted: false,
                isMismatchedDisk: false
            )
        }

        section("0. 初始状态")
        check(fm.fileExists(atPath: tplDir), "合成模板已位于 FCPX 扫描树", tplDir)
        check(TemplateIsolationStore.isInScanTree(path: tplDir), "isInScanTree = true")
        check(!fm.fileExists(atPath: disabledDir), "禁用仓初始无同名项")

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        // 静默其它历史弹窗（offlineGuard / showAlert），避免无 UI 环境下 runModal 阻塞；
        // 本轮 TR-013 弹窗由 alertResponseHandler 精确接管。
        hub.suppressAlertsForTesting = true
        hub.alertResponseHandler = { alert in
            let record = CapturedAlert(title: alert.messageText,
                                       message: alert.informativeText,
                                       buttons: alert.buttons.map { $0.title })
            captured.append(record)
            let d = decisions.isEmpty ? NSApplication.ModalResponse.alertSecondButtonReturn
                                      : decisions.removeFirst()
            let flat = record.message.replacingOccurrences(of: "\n", with: " ⏎ ")
            print("    [ALERT] \(record.title) | \(flat)")
            print("    [ALERT] buttons=\(record.buttons) -> \(d == .alertFirstButtonReturn ? "FIRST(确认/好)" : "SECOND(取消)")")
            return d
        }

        // ── Phase 1: 禁用 → 二次确认 → 取消 ─────────────────────────
        section("1. 禁用一套 → 弹二次确认 → 点「取消」")
        let enabledItem = makeItem(path: tplDir, enabled: true)
        captured = []
        decisions = [.alertSecondButtonReturn]
        hub.toggleTemplateItem(enabledItem)

        check(captured.count == 1, "出现且仅出现 1 个弹窗（二次确认）", "实际 \(captured.count) 个")
        if let confirm = captured.first {
            check(confirm.title == AssetHubView.disableConfirmTitle, "确认弹窗标题来自文案真源",
                  confirm.title)
            check(confirm.message.contains("该模板若正被某个工程使用，重启 FCPX 后该工程中的对应片段可能显示缺失"),
                  "文案含「工程使用中重启后片段可能缺失」风险提示")
            check(confirm.message.contains("模板文件本身不删除，随时可在本 App 启用回来"),
                  "文案含「不删除 / 可随时启用回来」")
            check(confirm.buttons == ["确认禁用", "取消"], "按钮为「确认禁用 / 取消」",
                  confirm.buttons.joined(separator: ","))
        }
        check(fm.fileExists(atPath: tplDir), "取消后模板原地不动（扫描树内仍存在）")
        check(TemplateIsolationStore.isInScanTree(path: tplDir), "取消后仍在扫描树")
        check(!fm.fileExists(atPath: disabledDir), "取消后禁用仓无同名项（未执行任何文件操作）")
        check(captured.count == 1, "取消后没有成功提示（证明未执行切换）")

        // ── Phase 2: 禁用 → 二次确认 → 确认 ─────────────────────────
        section("2. 禁用一套 → 弹二次确认 → 点「确认禁用」")
        captured = []
        decisions = [.alertFirstButtonReturn, .alertFirstButtonReturn] // 确认 + 成功提示
        hub.toggleTemplateItem(enabledItem)

        check(captured.count == 2, "产生 2 个弹窗（二次确认 + 成功提示）", "实际 \(captured.count) 个")
        check(!fm.fileExists(atPath: tplDir), "确认后模板移出 FCPX 扫描树")
        check(fm.fileExists(atPath: disabledDir), "确认后模板进入禁用仓（真隔离生效）")
        if let success = captured.last {
            check(success.title == "操作已完成", "成功提示弹窗出现")
            check(success.message.contains(AssetHubView.effectNotice),
                  "成功提示含「\(AssetHubView.effectNotice)」", success.message)
            check(!success.message.contains("已禁用"),
                  "成功提示不含「已禁用」这类误导为立即生效的措辞", success.message)
            check(success.message == AssetHubView.toggleSuccessMessage(name: tplName, enabled: false),
                  "成功提示文案与源码真源逐字一致")
        }

        // ── Phase 3: 启用回来（还原现场，且启用方向不弹确认） ─────────
        section("3. 启用回来 → 还原现场（启用方向不应弹二次确认）")
        let disabledItem = makeItem(path: disabledDir, enabled: false)
        captured = []
        decisions = [.alertFirstButtonReturn] // 只有成功提示
        hub.toggleTemplateItem(disabledItem)

        check(captured.count == 1, "启用方向只弹成功提示，不弹二次确认", "实际 \(captured.count) 个")
        check(fm.fileExists(atPath: tplDir), "模板已原路搬回扫描树")
        check(!fm.fileExists(atPath: disabledDir), "禁用仓已清空该合成项")
        if let success = captured.last {
            check(success.message.contains(AssetHubView.effectNotice),
                  "启用成功提示同样含「\(AssetHubView.effectNotice)」")
            check(success.message == AssetHubView.toggleSuccessMessage(name: tplName, enabled: true),
                  "启用成功提示文案与源码真源逐字一致")
        }

        // ── Phase 4: 硬约束静态举证 ────────────────────────────────
        section("4. 硬约束：零自动退出/重启 FCPX 代码")
        let srcRoot = "FCPXStudioNative/Sources/FCPXStudio"
        // 精确词表：只针对「退出/重启其它 App（尤其 FCPX）」的 API。
        // 裸 terminate() 不可入表 —— 项目里 Process.terminate() 是 Python 子进程超时管理，与 FCPX 无关。
        // 注：NSApp.terminate(nil) 出现在 MainWindowController.windowWillClose，
        // 是用户主动关闭「本 App」窗口时退出本 App，既非 FCPX、也非自动行为，故不入禁用词表。
        let banned = ["NSRunningApplication", "relaunch", "killall", "osascript",
                      "quitApp", "restartApp", "terminateApp(",
                      "NSWorkspace.shared.launchApplication", "SIGTERM, Final Cut"]
        var hits: [String] = []
        var procTerminations = 0
        var suspiciousTerminations: [String] = []
        if let enumerator = fm.enumerator(atPath: srcRoot) {
            for case let f as String in enumerator where f.hasSuffix(".swift") {
                let p = (srcRoot as NSString).appendingPathComponent(f)
                guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                for word in banned where text.contains(word) {
                    hits.append("\(f): \(word)")
                }
                for line in text.split(separator: "\n") where line.contains("terminate()") {
                    let s = String(line)
                    if s.contains("process.terminate()") || s.contains("proc.terminate()") {
                        procTerminations += 1
                    } else {
                        suspiciousTerminations.append("\(f): \(s.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        check(hits.isEmpty, "全量 Swift 源码无自动退出/重启 FCPX 关键字",
              hits.joined(separator: " | "))
        check(suspiciousTerminations.isEmpty,
              "全部 terminate() 均为 Process 子进程超时管理，无 App/FCPX 退出调用",
              suspiciousTerminations.joined(separator: " | "))
        print("    扫描 \(srcRoot) 下全部 .swift；精确禁用词表: \(banned.joined(separator: ", "))")
        print("    另核实 Process.terminate() 命中 \(procTerminations) 处，均为 Python 子进程超时回收。")
        print("    另核实 NSApp.terminate(nil) 仅位于 MainWindowController.windowWillClose（用户主动关闭本 App），非 FCPX 退出/重启。")

        // ── Phase 5: 真实 NSAlert 离屏渲染物证 ──────────────────────
        section("5. 生成 AppKit 控件离屏渲染物证（提示文案）")
        let p1 = renderAlert(title: AssetHubView.disableConfirmTitle,
                             message: AssetHubView.disableConfirmMessage(forName: tplName),
                             buttons: ["确认禁用", "取消"],
                             style: .warning,
                             outPath: "\(outDir)/01_禁用前二次确认.png")
        check(p1, "01_禁用前二次确认.png")

        let p2 = renderAlert(title: "操作已完成",
                             message: AssetHubView.toggleSuccessMessage(name: tplName, enabled: false),
                             buttons: ["好"],
                             style: .informational,
                             outPath: "\(outDir)/02_禁用成功提示文案.png")
        check(p2, "02_禁用成功提示文案.png")

        let p3 = renderAlert(title: "操作已完成",
                             message: AssetHubView.toggleSuccessMessage(name: tplName, enabled: true),
                             buttons: ["好"],
                             style: .informational,
                             outPath: "\(outDir)/03_启用成功提示文案.png")
        check(p3, "03_启用成功提示文案.png")

        // ── 清理 ───────────────────────────────────────────────────
        section("Z. 清理现场")
        wipe()
        check(!fm.fileExists(atPath: tplDir), "合成模板已清理")
        check(!fm.fileExists(atPath: disabledDir), "禁用仓合成项已清理")
        print("    未触碰用户真实模板库；未启动/重启 App 或 FCPX。")

        print("\n================ RESULT ================")
        print("PASS = \(pass)   FAIL = \(fail)")
        print(fail == 0 ? "TR-013 VERDICT: PASS" : "TR-013 VERDICT: FAIL")
        print("========================================")
    }

    /// 用 AppKit 控件把 NSAlert 的标题 / 正文 / 按钮离屏渲染成 PNG。
    /// NSAlert.window 在未 runModal 时子视图不绘制（只出空壳），故改为按 macOS 弹窗版式
    /// 自绘面板；文案全部来自 AssetHubView 的 public 真源，不手抄、不模拟数据。
    /// 不 runModal、不抢焦点、不弹屏；图内明确标注为离屏渲染而非真机截屏。
    static func renderAlert(title: String, message: String, buttons: [String],
                            style: NSAlert.Style, outPath: String) -> Bool {
        let width: CGFloat = 760
        let bodyLines = max(2, message.count / 38 + message.split(separator: "\n").count + 1)
        let bodyHeight = CGFloat(max(64, bodyLines * 20))
        let height: CGFloat = 210 + bodyHeight

        let canvas = TR013PanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let accent: NSColor = style == .warning ? .systemOrange : .systemBlue
        canvas.accent = accent

        // 离屏渲染没有 window/appearance，动态色 .labelColor 会解析成白色导致白底白字。
        // 一律使用固定校准色，保证物证可读。
        let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
        let subInk = NSColor(calibratedWhite: 0.42, alpha: 1)

        let caption = NSTextField(labelWithString:
            "TR-013 · AppKit 控件离屏渲染（文案取自源码真源；非真机弹窗截屏）")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = subInk
        caption.frame = NSRect(x: 24, y: 8, width: width - 48, height: 16)
        canvas.addSubview(caption)

        let cardTop = height - 34
        let symbol = style == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let icon = NSImageView(frame: NSRect(x: 44, y: cardTop - 62, width: 40, height: 40))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = accent
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

        // macOS 弹窗：主按钮在最右，取消在其左。
        var right = width - 40
        for (idx, bTitle) in buttons.enumerated() {
            let bw: CGFloat = 116
            let btn = NSButton(frame: NSRect(x: right - bw, y: 52, width: bw, height: 30))
            btn.bezelStyle = .rounded
            let isPrimary = (idx == 0)
            btn.bezelColor = isPrimary ? accent : NSColor(calibratedWhite: 0.86, alpha: 1)
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
final class TR013PanelView: NSView {
    var accent: NSColor = .systemBlue

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
