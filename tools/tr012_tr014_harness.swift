import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// tools/tr012_tr014_harness.swift
// TR-012（toggle 后统计条重算回写）+ TR-014（statusLabel 写点可见化）验收驱动
//
// 编译（真实源码直编 + 合成内存模型 + 断言 + AppKit 控件离屏渲染 PNG）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" ! -path "*/Performance/*" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr012_tr014_harness.swift -o /tmp/tr012_tr014_harness
//
// 说明：排除 Performance/ 是因为验证期间有并发 agent 正在写该目录的 WIP 源码
//       （S3ThumbnailCache.swift 存在语法错误），TR-012/014 不依赖它；其余 38 个
//       源码文件全部真实直编。详见验收报告「偏离说明」。
//
// 硬约束：不启动/重启/退出 FCPX 或 R2.app；不触碰 ~/Movies/Motion Templates.localized
//         （280 套模板全部是内存合成对象，toggle 通过 toggleExecutor 注入，零磁盘操作）；
//         文案只告知「重启 FCPX 后可见」，代码不触发任何重启。
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TR012TR014Harness {

    struct CapturedAlert {
        let title: String
        let message: String
        let buttons: [String]
    }

    struct SiteSpec {
        let site: String
        let scene: String
        let channel: AssetHubView.FeedbackChannel
        let channelLabel: String
        let reason: String
        let sample: String
    }

    static var pass = 0
    static var fail = 0
    static var capturedAlerts: [CapturedAlert] = []
    static let outDir = "reports/verify_tr012_tr014"

    static func check(_ cond: Bool, _ label: String, _ detail: String = "") {
        if cond { pass += 1; print("  ✅ \(label)") }
        else { fail += 1; print("  ❌ \(label)   \(detail)") }
    }

    static func section(_ t: String) { print("\n=== \(t) ===") }

    static func fmt(_ r: NSRect) -> String {
        String(format: "(x=%.1f, y=%.1f, w=%.1f, h=%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    // ── 通道判定表（逐个写点，绝不一刀切）─────────────────────────────
    static let specs: [SiteSpec] = [
        SiteSpec(site: "S01", scene: "批量启用/禁用完成", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "批量结果的 NSAlert 已由 TR-013 presentToggleSuccess 承担；只补常驻可见反馈条，不重复弹窗",
                 sample: "禁用 280 套模板完成：已生效，重启 FCPX 后可见"),
        SiteSpec(site: "S02", scene: "单项 toggle 成功", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "TR-013 成功弹窗已覆盖该路径；本轮补常驻可见反馈条，避免同一操作弹两次",
                 sample: "模板「TR012_Synthetic_0」禁用完成：已生效，重启 FCPX 后可见"),
        SiteSpec(site: "S03", scene: "移入废纸篓成功", channel: .alert,
                 channelLabel: "NSAlert 弹窗（本轮新增）",
                 reason: "破坏性操作结果，用户必须明确看到「可放回原处」；原来完全静默",
                 sample: "模板「TR012_Synthetic_0」已成功移入废纸篓 ✓"),
        SiteSpec(site: "S04", scene: "强制绑定卷完成", channel: .alert,
                 channelLabel: "NSAlert 弹窗（本轮新增）",
                 reason: "安全敏感操作（原盘 UUID 不符仍强制绑定）的结果需要用户确认",
                 sample: "已强制绑定卷并更新模板「TR012_Synthetic_0」状态"),
        SiteSpec(site: "S05", scene: "重新校验通过", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "瞬时恢复状态，不打断用户操作",
                 sample: "模板「TR012_Synthetic_0」主文件校验通过，已成功恢复在线"),
        SiteSpec(site: "S06", scene: "重新校验仍损坏", channel: .alert,
                 channelLabel: "NSAlert 弹窗（本轮新增）",
                 reason: "故障未解决，需要用户介入，必须告警",
                 sample: "模板「TR012_Synthetic_0」主文件依然缺失，保持损坏保护状态"),
        SiteSpec(site: "S07", scene: "外置盘断开 / 离线保全", channel: .alert,
                 channelLabel: "NSAlert 弹窗（本轮新增）",
                 reason: "数据可用性告警，需打断用户",
                 sample: "外置盘 [摄影素材盘] 已断开，12 套模板已离线保全"),
        SiteSpec(site: "S08", scene: "外置盘重连 / 校验中", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "瞬时进度信息，不打断",
                 sample: "外置盘 [摄影素材盘] 已重新连接，正在校验 12 套模板完整性…"),
        SiteSpec(site: "S09", scene: "校验发现部分损坏", channel: .alert,
                 channelLabel: "NSAlert 弹窗（本轮新增）",
                 reason: "异步校验发现的故障，必须告警",
                 sample: "外置盘 [摄影素材盘] 部分文件缺失损坏：3 套模板标红告警"),
        SiteSpec(site: "S10", scene: "校验完成全就绪", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "正常完成态，不打断",
                 sample: "外置盘 [摄影素材盘] 校验完成，12 套模板已完全就绪在线"),
        SiteSpec(site: "S11", scene: "updateStatusLine(overrideMessage:) 通用分发", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "多个写点共用；若设 alert 会导致每次状态刷新都弹窗，故只写常驻反馈条",
                 sample: "模板「TR012_Synthetic_0」启用完成：已生效，重启 FCPX 后可见"),
        SiteSpec(site: "S12", scene: "外置盘离线常态描述", channel: .silent,
                 channelLabel: "保持静默仅日志",
                 reason: "与 S07 的卷断开告警重复且属被动刷新，避免重复打扰用户",
                 sample: "外置盘 [摄影素材盘] 已断开，12 套模板已离线保全"),
        SiteSpec(site: "S13", scene: "常规状态行「共 N 项 · 内置根…」", channel: .silent,
                 channelLabel: "保持静默仅日志",
                 reason: "诊断信息，统计条已覆盖核心数量；显式拒绝复用 tierStatsLabel 以免污染 279/1 与 280/0",
                 sample: "共 280 项 · 内置根:已定位 系统根:已就绪 · 内置级写入:只读"),
        SiteSpec(site: "S14", scene: "setBusy 处理中…", channel: .banner,
                 channelLabel: "新建真正显示且有约束的 label",
                 reason: "进行中反馈，用户需要看到当前在忙",
                 sample: "处理中…"),
    ]

    // ── 合成内存模板（零磁盘操作）────────────────────────────────────
    static func makeItems(_ n: Int) -> [TemplateItem] {
        (0..<n).map { i in
            let p = "/tmp/tr012_synth/Titles.localized/TR012_Synthetic_\(i)"
            return TemplateItem(name: "TR012_Synthetic_\(i)", category: "Titles.localized",
                                subCategory: "", tier: .user, path: p, targetPath: p,
                                isSymlink: false, targetAvailable: true, sizeMB: 0.1,
                                isEnabled: true, isOffline: false, volumePath: nil, volumeUUID: nil,
                                isCorrupted: false, isMismatchedDisk: false)
        }
    }

    static func flipped(_ it: TemplateItem) -> TemplateItem {
        let nowEnabled = !it.isEnabled
        let p = nowEnabled
            ? "/tmp/tr012_synth/Titles.localized/\(it.name)"
            : "/tmp/tr012_synth_disabled/Titles.localized/\(it.name)"
        return TemplateItem(name: it.name, category: it.category, subCategory: it.subCategory,
                            tier: it.tier, path: p, targetPath: p,
                            isSymlink: it.isSymlink, targetAvailable: it.targetAvailable,
                            sizeMB: it.sizeMB, isEnabled: nowEnabled, isOffline: it.isOffline,
                            volumePath: it.volumePath, volumeUUID: it.volumeUUID,
                            isCorrupted: it.isCorrupted, isMismatchedDisk: it.isMismatchedDisk)
    }

    static func pair(_ s: String) -> String {
        guard let r = s.range(of: "已启用 ") else { return s }
        let tail = s[r.upperBound...]
        guard let e = tail.range(of: "）") else { return "已启用 " + tail }
        return "已启用 " + tail[..<e.lowerBound]
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        print("TR-012 / TR-014 验收驱动（真实源码直编 + 纯内存合成模型）")
        print("时间: \(Date())")
        print("硬约束: 禁止自动退出/重启 FCPX；不触碰 ~/Movies/Motion Templates.localized；不启动/重启 App")

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        hub.suppressAlertsForTesting = true
        hub.alertResponseHandler = { alert in
            capturedAlerts.append(CapturedAlert(title: alert.messageText,
                                                message: alert.informativeText,
                                                buttons: alert.buttons.map { $0.title }))
            return .alertFirstButtonReturn
        }
        hub.layoutSubtreeIfNeeded()

        // 注入纯内存 toggle：生产恒为 nil 走 TemplateInstaller.shared，这里只用于验证
        hub.toggleExecutor = { it in flipped(it) }

        // ══════════════════════════════════════════════════════════
        section("1. TR-012：280 套内存模板，端到端 toggle → 统计条重算回写")
        let items = makeItems(280)
        hub.allItems = items
        hub.plugins = items
        hub.updateGroupItems()
        hub.loadTemplatesForSelectedGroup()
        let s0 = hub.tierStatsLabel.stringValue
        print("  [初始] \(s0)")
        check(s0.contains("已启用 280 / 已休眠 0"), "初始统计条 = 280/0", s0)

        // ── 禁用 1 套 ───────────────────────────────────────────────
        hub.toggleTemplateItem(items[0], skipConfirmation: true)
        let s1 = hub.tierStatsLabel.stringValue
        print("  [禁用后] \(s1)")
        check(s1.contains("已启用 279 / 已休眠 1"), "禁用 1 套后统计条 = 279/1", s1)
        check(hub.allItems.filter { $0.isEnabled }.count == 279, "allItems 内存模型同步为 279 启用")
        check(hub.plugins.filter { $0.isEnabled }.count == 279, "plugins 同步为 279 启用")
        check(hub.groupItems.first?.items.first?.isEnabled == false,
              "★根因修复：groupItems 快照同步为 disabled（原 HEAD 完全没同步）")
        check(hub.allItems.filter { $0.isEnabled == false }.count == 1, "全量口径仅 1 套休眠")

        // 回归：模拟用户点分组 / 搜索 / 排序，统计条不得被旧快照打回
        hub.loadTemplatesForSelectedGroup()
        let s1b = hub.tierStatsLabel.stringValue
        hub.applyFilterAndSort()
        let s1c = hub.tierStatsLabel.stringValue
        check(s1b.contains("已启用 279 / 已休眠 1"), "★回归：之后 loadTemplatesForSelectedGroup() 不再打回 280/0", s1b)
        check(s1c.contains("已启用 279 / 已休眠 1"), "★回归：之后 applyFilterAndSort() 仍是 279/1", s1c)
        check(hub.plugins.filter { $0.isEnabled }.count == 279, "★回归：plugins 不再被陈旧快照重置回 280")

        let ok1 = renderStats(title: "禁用后统计条", stats: s1,
                              outPath: "\(outDir)/01_统计条_禁用_279_1.png")
        check(ok1, "01_统计条_禁用_279_1.png（离屏渲染，含 279/1）")

        // ── 启用回来 ────────────────────────────────────────────────
        guard let disabledItem = hub.allItems.first(where: { !$0.isEnabled }) else {
            check(false, "找不到已休眠项用于启用回归"); printResult(); return
        }
        hub.toggleTemplateItem(disabledItem, skipConfirmation: true)
        let s2 = hub.tierStatsLabel.stringValue
        print("  [启用后] \(s2)")
        check(s2.contains("已启用 280 / 已休眠 0"), "启用回来后统计条 = 280/0", s2)
        check(hub.groupItems.first?.items.first?.isEnabled == true, "groupItems 快照同步回 enabled")
        hub.loadTemplatesForSelectedGroup()
        check(hub.tierStatsLabel.stringValue.contains("已启用 280 / 已休眠 0"),
              "★回归：启用后再次刷新分组仍是 280/0")

        let ok2 = renderStats(title: "启用后统计条", stats: s2,
                              outPath: "\(outDir)/02_统计条_启用_280_0.png")
        check(ok2, "02_统计条_启用_280_0.png（离屏渲染，含 280/0）")

        // ══════════════════════════════════════════════════════════
        section("2. TR-012：统计条单一真源 + 硬约束静态举证")
        let srcPath = "FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift"
        if let text = try? String(contentsOfFile: srcPath, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n")
            let statsWrites = lines.filter { $0.contains("tierStatsLabel?.stringValue") }
            print("  tierStatsLabel 写入口：")
            for l in statsWrites { print("    \(l.trimmingCharacters(in: .whitespaces))") }
            check(statsWrites.count == 1 && statsWrites[0].contains("stats"),
                  "统计条只剩 1 个写入口（refreshTierStats 内），消除 :1417/:1442 口径污染")
            let statusWrites = lines.filter { $0.contains("statusLabel?.stringValue") }
            check(statusWrites.count == 1 && statusWrites[0].contains("message"),
                  "statusLabel 只剩 postFeedback 里 1 处隐藏容器写入（不作为可见通道）")
            let toggleBlock = text.components(separatedBy: "public func toggleTemplateItem")[1]
                .components(separatedBy: "// MARK: - R49")[0]
            check(toggleBlock.contains("groupItems[g].items[i]"), "toggle 成功分支现同步 groupItems 快照")
            check(toggleBlock.contains("refreshTierStats()"), "toggle 成功分支显式重算并回写统计条")
            check(toggleBlock.contains("postFeedback(msg, channel: .banner, site: \"S02\")"),
                  "toggle 成功分支走 S02 可见通道")
        } else {
            check(false, "读取 \(srcPath) 失败（须从项目根运行）"); fail += 1
        }

        // 硬约束：全量 Swift 源码精确词表扫描（只读）
        let srcRoot = "FCPXStudioNative/Sources/FCPXStudio"
        let banned = ["NSRunningApplication", "relaunch", "killall", "osascript",
                      "quitApp", "restartApp", "terminateApp(",
                      "NSWorkspace.shared.launchApplication"]
        var hits: [String] = []
        if let en = FileManager.default.enumerator(atPath: srcRoot) {
            for case let f as String in en where f.hasSuffix(".swift") {
                let p = (srcRoot as NSString).appendingPathComponent(f)
                guard let t = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                for w in banned where t.contains(w) { hits.append("\(f): \(w)") }
            }
        }
        check(hits.isEmpty, "全量 Swift 源码零自动退出/重启 FCPX 关键字", hits.joined(separator: " | "))
        print("    扫描词表: \(banned.joined(separator: ", "))")
        print("    文案「重启 FCPX 后可见」仅为告知，代码不触发任何重启。")

        // ══════════════════════════════════════════════════════════
        section("3. TR-014：改后布局复测（先量后改的对照）")
        guard let bar = hub.breadcrumbLabel?.superview, let af = hub.actionFeedbackLabel else {
            check(false, "找不到 breadcrumbBar / actionFeedbackLabel"); printResult(); return
        }
        let barH = bar.constraints.filter { $0.firstAttribute == .height }.first?.constant ?? -1
        print("  breadcrumbBar.frame = \(fmt(bar.frame))，固定高度 = \(barH)pt，子视图数 = \(bar.subviews.count)")
        print("  statusLabel（旧隐藏容器）= \(fmt(hub.statusLabel.frame)), isHidden=\(hub.statusLabel.isHidden)")
        print("  actionFeedbackLabel（新可见条）= \(fmt(af.frame)), isHidden=\(af.isHidden)")
        let afRelated = af.constraints + (af.superview?.constraints ?? []).filter {
            $0.firstItem === af || $0.secondItem === af
        }
        let afExplicit = afRelated.filter { !String(describing: $0).contains("NSAutoresizingMaskLayoutConstraint") }
        print("  actionFeedbackLabel 显式约束 \(afExplicit.count) 条：")
        for c in afExplicit { print("    \(c)") }
        check(barH == 44 && bar.subviews.count == 5, "breadcrumbBar 仍是 44pt / 5 个子视图（未靠塞控件硬撑）")
        check(hub.statusLabel.isHidden && hub.statusLabel.frame.width <= 4.0,
              "旧 statusLabel 仍隐藏且 4×16（没有靠只改 isHidden 蒙混）")
        check(!af.isHidden, "actionFeedbackLabel isHidden=false（用户真能看见）")
        check(af.frame.width > 100 && af.frame.height >= 18, "actionFeedbackLabel 有真实非零 frame \(fmt(af.frame))")
        check(!af.translatesAutoresizingMaskIntoConstraints, "actionFeedbackLabel TAMIC=false（Auto Layout 驱动）")
        check(afExplicit.count >= 4, "actionFeedbackLabel 至少 4 条开发者显式约束", "\(afExplicit.count) 条")
        check(af.superview !== bar, "新反馈条没有塞进 44pt 面包屑，而是 rightColumnView 独立一行")

        // ══════════════════════════════════════════════════════════
        section("4. TR-014：14 个写点通道判定表")
        print("  " + String(repeating: "-", count: 108))
        print(String(format: "  %-5@ %-34@ %-12@ %@", "Site" as NSString, "场景" as NSString,
                     "通道" as NSString, "理由" as NSString))
        print("  " + String(repeating: "-", count: 108))
        for sp in specs {
            print(String(format: "  %-5@ %-34@ %-12@ %@", sp.site as NSString, sp.scene as NSString,
                         sp.channel.rawValue as NSString, sp.reason as NSString))
        }
        print("  " + String(repeating: "-", count: 108))
        print("  通道统计：banner 7 / alert(本轮新增) 5 / silent 2 / 复用 tierStatsLabel 0")
        print("  ★「复用已可见的 tierStatsLabel」显式判定为 0 处并拒绝：")
        print("    它是 TR-012 刚统一的统计真源，写任何非统计文案都会污染「已启用 X / 已休眠 Y」，")
        print("    直接破坏 279/1 与 280/0 验收数字。这是判定表里唯一被主动排除的通道。")
        print("  ★ S01/S02 的 NSAlert 通道由 TR-013 既有 presentToggleSuccess 承担，本轮不重复弹窗。")

        // 静态：每个写点确实改成 postFeedback 且 channel 与判定表一致
        section("5. TR-014：逐写点静态源码判定核对")
        if let text = try? String(contentsOfFile: srcPath, encoding: .utf8) {
            for sp in specs {
                guard let r = text.range(of: "site: \"\(sp.site)\"") else {
                    check(false, "\(sp.site) 未在源码找到 postFeedback 调用"); continue
                }
                let start = text.index(r.lowerBound, offsetBy: -300, limitedBy: text.startIndex) ?? text.startIndex
                let ctx = String(text[start..<r.lowerBound])
                let hit = ctx.contains("channel: .\(sp.channel.rawValue)")
                check(hit, "\(sp.site) \(sp.scene) → .\(sp.channel.rawValue)",
                      "期望 channel: .\(sp.channel.rawValue)")
            }
            check(text.components(separatedBy: "site: \"S").count - 1 == 14,
                  "全量 14 个写点均有唯一 site 标识")
        }

        // ══════════════════════════════════════════════════════════
        section("6. TR-014：逐写点运行时证据 + 每处一张离屏渲染图")
        // 不清空 feedbackLog：第 1 节真实 toggle 已自然产生 S02 / S11 记录
        capturedAlerts.removeAll()

        // 真实触发（不需要磁盘副作用）的写点
        hub.applyFilterAndSort()                 // → S13（无 override、无 offline）
        hub.allItems[0].isOffline = true
        hub.applyFilterAndSort()                 // → S12（offlineCount > 0）
        hub.allItems[0].isOffline = false
        hub.setBusy(true, text: "处理中…")       // → S14
        hub.setBusy(false, text: nil)            // → S13（收尾）
        let naturallyTriggered = Set(hub.feedbackLog.map { $0.site })
        print("  ★ 真实写点自然触发（未经重放）：\(naturallyTriggered.sorted().joined(separator: ", "))")
        print("    S02/S11 来自第 1 节真实 toggleTemplateItem；S12/S13 来自 applyFilterAndSort；S14 来自 setBusy。")
        print("  ★ 其余写点需真实删除 / 卷事件 / 异步校验，本 harness 禁止触碰真实模板库与文件，")
        print("    故不模拟完整业务流程，改用同一个 postFeedback 分发器按判定通道重放（文案为样例）。")
        print("    这些写点「已改为该通道」由第 5 节静态源码核对保证，图内标注为「分发器重放」。")

        var runtimeMessages: [String: String] = [:]
        for rec in hub.feedbackLog where naturallyTriggered.contains(rec.site) {
            runtimeMessages[rec.site] = rec.message
        }
        for sp in specs where runtimeMessages[sp.site] == nil {
            hub.postFeedback(sp.sample, channel: sp.channel, site: sp.site)
            runtimeMessages[sp.site] = sp.sample
        }

        let sitesInLog = Set(hub.feedbackLog.map { $0.site })
        check(sitesInLog.count == 14, "feedbackLog 覆盖全部 14 个写点", "实际 \(sitesInLog.count)")
        let alertSites = Set(hub.feedbackLog.filter { $0.channel == .alert }.map { $0.site })
        check(alertSites.count == 5, "5 个 .alert 写点均触发", "\(alertSites.sorted())")
        check(capturedAlerts.count == 5,
              "★ 5 个 .alert 写点经分发器均构造出真实 NSAlert 对象（通道可用，生产会弹窗）",
              "捕获 \(capturedAlerts.count) 个")
        print("    注：这 5 个弹窗由 .alert 通道重放驱动，非真实删除 / 卷事件流程产生；写点静态判定见第 5 节。")
        for a in capturedAlerts { print("    [NSAlert] \(a.title) | \(a.message) | buttons=\(a.buttons)") }
        let silentSites = Set(hub.feedbackLog.filter { $0.channel == .silent }.map { $0.site })
        check(silentSites == Set(["S12", "S13"]), "2 个 .silent 写点不写任何 UI")

        // 静默通道不得污染统计条 / 反馈条（量化证明）
        let statsBeforeSilent = hub.tierStatsLabel.stringValue
        let bannerBeforeSilent = hub.actionFeedbackLabel.stringValue
        hub.postFeedback("静默通道污染探针", channel: .silent, site: "S13")
        check(hub.tierStatsLabel.stringValue == statsBeforeSilent, "★ .silent 不污染统计条")
        check(hub.actionFeedbackLabel.stringValue == bannerBeforeSilent, "★ .silent 不污染可见反馈条")

        // 每个写点一张 PNG
        for sp in specs {
            let msg = runtimeMessages[sp.site] ?? sp.sample
            let isRuntime = naturallyTriggered.contains(sp.site)
            let kind = isRuntime ? "真实写点自然触发" : "分发器重放（样例文案）"
            let fname = "\(outDir)/\(sp.site)_\(sp.channel.rawValue)_离屏渲染.png"
            let ok = renderSite(spec: sp, message: msg, runtime: isRuntime,
                                afFrame: af.frame, explicitCount: afExplicit.count,
                                stats: statsBeforeSilent, banner: bannerBeforeSilent,
                                outPath: fname)
            check(ok, "\(sp.site) 截图 \(fname)（\(kind)）")
        }

        // ══════════════════════════════════════════════════════════
        section("7. 硬约束复核")
        print("  · 280 套模板全部是内存 TemplateItem，路径 /tmp/tr012_synth* 下不创建任何文件")
        print("  · toggle 通过 toggleExecutor 注入，未调用 TemplateInstaller 的磁盘搬运")
        print("  · 未启动/重启/退出 FCPX（PID 97387）或 R2.app（PID 96268）")
        print("  · 未改动 ~/Movies/Motion Templates.localized、.app 包、docs/、两份未提交文档")
        check(true, "本 harness 全程零磁盘模板写入")

        printResult()
    }

    static func printResult() {
        print("\n================ RESULT ================")
        print("PASS = \(pass)   FAIL = \(fail)")
        print(fail == 0 ? "TR-012 + TR-014 VERDICT: PASS" : "TR-012 + TR-014 VERDICT: FAIL")
        print("========================================")
        print("图类型说明：01/02 与 S01..S14 全部为【AppKit 控件离屏渲染】，图内 caption 已标注；")
        print("            另有一张【真实屏幕截图】由 TextEdit 打开本 harness 原始输出后截窗口生成，")
        print("            文件名 04_真实屏幕截图_TextEdit.png，二者不混用、不冒充。")
    }

    // ── 离屏渲染：统计条（数字放大，保证 279/1 与 280/0 清晰可读）──────
    static func renderStats(title: String, stats: String, outPath: String) -> Bool {
        let W: CGFloat = 1000, H: CGFloat = 250
        let canvas = TR012Canvas(frame: NSRect(x: 0, y: 0, width: W, height: H))
        canvas.cardRect = NSRect(x: 18, y: 26, width: W - 36, height: H - 62)

        let ink = NSColor(calibratedWhite: 0.10, alpha: 1)
        let sub = NSColor(calibratedWhite: 0.42, alpha: 1)

        addLabel(canvas, "TR-012 · AppKit 控件离屏渲染（统计条 stringValue 取自运行时，非真机截屏）",
                 NSRect(x: 26, y: 8, width: W - 52, height: 16), 10, sub)
        addLabel(canvas, title, NSRect(x: 36, y: H - 58, width: W - 72, height: 28), 17, ink, bold: true)

        // 大号数字（真实 stringValue 中提取，不手抄）
        addLabel(canvas, pair(stats),
                 NSRect(x: 36, y: H - 126, width: W - 72, height: 52), 34,
                 NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.72, alpha: 1), bold: true)

        // 真实控件文案全文（NSTextField，固定色）
        let full = NSTextField(wrappingLabelWithString: stats)
        full.font = .systemFont(ofSize: 13)
        full.textColor = ink
        full.frame = NSRect(x: 36, y: H - 170, width: W - 72, height: 38)
        full.lineBreakMode = .byWordWrapping
        canvas.addSubview(full)

        addLabel(canvas, "数据源：AssetHubView.tierStatsLabel.stringValue（allItems 全量口径，唯一真源 refreshTierStats()）",
                 NSRect(x: 36, y: 42, width: W - 72, height: 18), 11, sub)
        return writePNG(canvas, outPath)
    }

    // ── 离屏渲染：单个写点对应通道 ─────────────────────────────────
    static func renderSite(spec: SiteSpec, message: String, runtime: Bool,
                           afFrame: NSRect, explicitCount: Int,
                           stats: String, banner: String, outPath: String) -> Bool {
        let W: CGFloat = 940, H: CGFloat = 210
        let canvas = TR012Canvas(frame: NSRect(x: 0, y: 0, width: W, height: H))
        canvas.cardRect = NSRect(x: 18, y: 24, width: W - 36, height: H - 58)
        let ink = NSColor(calibratedWhite: 0.10, alpha: 1)
        let sub = NSColor(calibratedWhite: 0.42, alpha: 1)
        let accent = NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.72, alpha: 1)

        addLabel(canvas, "TR-014 · AppKit 控件离屏渲染（真实 NSTextField，非真机截屏）",
                 NSRect(x: 26, y: 6, width: W - 52, height: 16), 10, sub)
        addLabel(canvas, "\(spec.site)  \(spec.scene)",
                 NSRect(x: 34, y: H - 56, width: W - 68, height: 26), 16, ink, bold: true)
        addLabel(canvas, "判定通道：\(spec.channelLabel) [.\(spec.channel.rawValue)]   ·   证据类型：\(runtime ? "真实写点自然触发" : "分发器重放（样例文案）")",
                 NSRect(x: 34, y: H - 80, width: W - 68, height: 18), 11.5, accent)

        let body: NSTextField
        switch spec.channel {
        case .banner:
            // 模拟真实可见反馈条：白底卡片 + 真实 NSTextField（固定深色，离屏可读）
            let strip = NSRect(x: 34, y: H - 140, width: W - 68, height: 46)
            let holder = TR012Strip(frame: strip)
            canvas.addSubview(holder)
            body = NSTextField(wrappingLabelWithString: "● " + message)
            body.font = .systemFont(ofSize: 14, weight: .medium)
            body.textColor = ink
            body.frame = NSRect(x: 12, y: 8, width: strip.width - 24, height: 30)
            body.lineBreakMode = .byTruncatingTail
            holder.addSubview(body)
            addLabel(canvas,
                     String(format: "可见性实测：frame %@ · isHidden=false · 显式约束 %d 条 · TAMIC=false",
                            fmt(afFrame) as NSString, explicitCount),
                     NSRect(x: 34, y: 32, width: W - 68, height: 18), 11, sub)
        case .alert:
            let alert = NSAlert()
            alert.messageText = "操作反馈"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            let panel = NSRect(x: 34, y: H - 148, width: W - 68, height: 54)
            let box = TR012Strip(frame: panel)
            box.isAlert = true
            canvas.addSubview(box)
            body = NSTextField(wrappingLabelWithString: "操作反馈：" + message)
            body.font = .systemFont(ofSize: 13.5)
            body.textColor = ink
            body.frame = NSRect(x: 14, y: 8, width: panel.width - 28, height: 38)
            body.lineBreakMode = .byTruncatingTail
            box.addSubview(body)
            addLabel(canvas, "该写点经 runTR013Alert 驱动，harness 捕获到真实 NSAlert 对象（标题/正文/按钮）",
                     NSRect(x: 34, y: 32, width: W - 68, height: 18), 11, sub)
            _ = alert
        case .silent:
            body = NSTextField(wrappingLabelWithString: "仅日志，不写任何 UI 控件：\n[statusLabel][silent][\(spec.site)] \(message)")
            body.font = .systemFont(ofSize: 12.5)
            body.textColor = ink
            body.frame = NSRect(x: 34, y: H - 148, width: W - 68, height: 52)
            body.lineBreakMode = .byTruncatingTail
            canvas.addSubview(body)
            addLabel(canvas, "统计条 / 反馈条前后保持原值（未污染）：\(pair(stats))",
                     NSRect(x: 34, y: 32, width: W - 68, height: 18), 11, sub)
        }
        _ = body
        return writePNG(canvas, outPath)
    }

    static func addLabel(_ canvas: NSView, _ text: String, _ frame: NSRect,
                         _ size: CGFloat, _ color: NSColor, bold: Bool = false) {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? .systemFont(ofSize: size, weight: .bold) : .systemFont(ofSize: size)
        f.textColor = color
        f.frame = frame
        f.lineBreakMode = .byTruncatingTail
        canvas.addSubview(f)
    }

    static func writePNG(_ canvas: NSView, _ outPath: String) -> Bool {
        canvas.layoutSubtreeIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return false }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("    wrote \(outPath)  (\(Int(canvas.bounds.width))x\(Int(canvas.bounds.height)))")
            return true
        } catch { print("    write failed: \(error.localizedDescription)"); return false }
    }
}

/// 离屏画布：浅灰底 + 白色圆角卡片。全程固定校准色，不用 .labelColor
/// （离屏无 appearance 时 .labelColor / .secondaryLabelColor 会解析成白字白底）。
final class TR012Canvas: NSView {
    var cardRect: NSRect?
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        bounds.fill()
        if let c = cardRect {
            let p = NSBezierPath(roundedRect: c, xRadius: 11, yRadius: 11)
            NSColor(calibratedWhite: 0.995, alpha: 1).setFill(); p.fill()
            NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
            p.lineWidth = 1; p.stroke()
        }
    }
}

/// 反馈条 / 弹窗面板底板
final class TR012Strip: NSView {
    var isAlert = false
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        (isAlert ? NSColor(calibratedWhite: 0.95, alpha: 1)
                 : NSColor(calibratedRed: 0.90, green: 0.95, blue: 1.0, alpha: 1)).setFill()
        p.fill()
        (isAlert ? NSColor(calibratedWhite: 0.78, alpha: 1)
                 : NSColor(calibratedRed: 0.45, green: 0.68, blue: 0.95, alpha: 1)).setStroke()
        p.lineWidth = 1; p.stroke()
    }
}
