import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  PluginDoctorDashboardView —— 幽灵插件医生体检与自愈控制台（白皮书建议 2）
//
//  视觉体系与嘉星一致：深色 Pro 质感、健康评分仪表盘、三类病症卡片、
//  详细故障诊断列表、一键自愈 (Relink All) 与一键隔离 (Quarantine All)。
// ═══════════════════════════════════════════════════════════════

public final class PluginDoctorDashboardView: NSView,
                                             NSTableViewDataSource,
                                             NSTableViewDelegate {

    // MARK: – Top Controls
    public var scanButton: NSButton!
    public var relinkAllButton: NSButton!
    public var quarantineAllButton: NSButton!
    public var restoreAllButton: NSButton!
    public var spinner: NSProgressIndicator!
    public var statusSummaryLabel: NSTextField!

    // MARK: – Metric Cards
    public var scoreCardValueLabel: NSTextField!
    public var scoreCardRatingLabel: NSTextField!
    public var danglingCardLabel: NSTextField!
    public var corruptedCardLabel: NSTextField!
    public var mediaCardLabel: NSTextField!

    // MARK: – Issue Table
    public var issuesTableView: NSTableView!
    public var emptyHintLabel: NSTextField!

    // MARK: – Data
    public private(set) var currentReport: DoctorReport?
    public private(set) var issues: [GhostIssue] = []

    public var onScanFinished: ((DoctorReport) -> Void)?

    // MARK: – Init
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: – UI Setup
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = ColorToken.cardBg.cgColor

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])

        // 1. 顶层标题与快捷操作栏
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topBar)

        let titleBox = NSStackView()
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 2

        // UI-O015: 缩短主标题，800px 窄窗与副标题不叠字
        let mainTitle = NSTextField(labelWithString: "幽灵插件体检医生")
        mainTitle.font = TypeScale.bodyBold
        mainTitle.textColor = .white
        titleBox.addArrangedSubview(mainTitle)

        let subTitle = NSTextField(labelWithString: "深度扫描三大病症：悬空断链 · 破损 XML · 贴图缺失 ｜ 秒级重连自愈 ｜ 零风险安全隔离")
        subTitle.font = TypeScale.footnote
        subTitle.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        titleBox.addArrangedSubview(subTitle)

        topBar.addArrangedSubview(titleBox)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(spacer)

        scanButton = NSButton(title: "全面体检", target: self, action: #selector(onScanClicked))
        scanButton.bezelStyle = .rounded

        relinkAllButton = NSButton(title: "智能自愈", target: self, action: #selector(onRelinkAllClicked))
        relinkAllButton.bezelStyle = .rounded
        relinkAllButton.contentTintColor = NSColor.systemGreen

        quarantineAllButton = NSButton(title: "隔离破损", target: self, action: #selector(onQuarantineAllClicked))
        quarantineAllButton.bezelStyle = .rounded
        quarantineAllButton.contentTintColor = NSColor.systemOrange

        restoreAllButton = NSButton(title: "还原隔离", target: self, action: #selector(onRestoreAllClicked))
        restoreAllButton.bezelStyle = .rounded

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        topBar.addArrangedSubview(scanButton)
        topBar.addArrangedSubview(relinkAllButton)
        topBar.addArrangedSubview(quarantineAllButton)
        topBar.addArrangedSubview(restoreAllButton)
        topBar.addArrangedSubview(spinner)

        // 2. 四大健康指标卡片栏
        let cardsStack = NSStackView()
        cardsStack.orientation = .horizontal
        cardsStack.distribution = .fillEqually
        cardsStack.spacing = 10
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(cardsStack)

        cardsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        cardsStack.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let (card1, v1, r1) = makeMetricCard(title: "健康体检评分", defaultVal: "100", sub: "运行良好")
        scoreCardValueLabel = v1
        scoreCardRatingLabel = r1
        cardsStack.addArrangedSubview(card1)

        let (card2, v2, _) = makeMetricCard(title: "悬空断链病症", defaultVal: "0", sub: "外置盘移动或脱机")
        danglingCardLabel = v2
        cardsStack.addArrangedSubview(card2)

        let (card3, v3, _) = makeMetricCard(title: "破损 XML 模板", defaultVal: "0", sub: "0 字节或语法损毁")
        corruptedCardLabel = v3
        cardsStack.addArrangedSubview(card3)

        let (card4, v4, _) = makeMetricCard(title: "🖼️ 贴图媒体缺失", defaultVal: "0", sub: "引用的 Media 丢失")
        mediaCardLabel = v4
        cardsStack.addArrangedSubview(card4)

        // 3. 状态提示栏
        statusSummaryLabel = NSTextField(labelWithString: "就绪。点击【🩺 全面体检】开始扫描系统与用户级 Motion 模板。")
        statusSummaryLabel.font = .systemFont(ofSize: 11)
        statusSummaryLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        mainStack.addArrangedSubview(statusSummaryLabel)

        // 4. 故障诊断列表容器
        let listContainer = NSView()
        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = ColorToken.panelBg.cgColor
        listContainer.layer?.cornerRadius = CornerRadius.card
        listContainer.layer?.borderWidth = 0.8
        listContainer.layer?.borderColor = ColorToken.cardBorder.cgColor
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(listContainer)

        listContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        topBar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        cardsStack.setContentHuggingPriority(.defaultHigh, for: .vertical)
        listContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        listContainer.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -6)
        ])

        issuesTableView = NSTableView()
        issuesTableView.headerView = NSTableHeaderView()
        issuesTableView.rowHeight = 32
        issuesTableView.gridStyleMask = .solidHorizontalGridLineMask
        issuesTableView.usesAlternatingRowBackgroundColors = false
        issuesTableView.dataSource = self
        issuesTableView.delegate = self

        let colSym = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colSym"))
        colSym.title = "病症类型"
        colSym.width = 110
        issuesTableView.addTableColumn(colSym)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colName"))
        colName.title = "模板名称"
        colName.width = 160
        issuesTableView.addTableColumn(colName)

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colCategory"))
        colCategory.title = "所属分类"
        colCategory.width = 120
        issuesTableView.addTableColumn(colCategory)

        let colDetail = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colDetail"))
        colDetail.title = "故障详情"
        colDetail.width = 300
        issuesTableView.addTableColumn(colDetail)

        let colFix = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colFix"))
        colFix.title = "建议修复方案"
        colFix.width = 200
        issuesTableView.addTableColumn(colFix)

        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colAction"))
        colAction.title = "自愈/隔离"
        colAction.width = 120
        issuesTableView.addTableColumn(colAction)

        scroll.documentView = issuesTableView

        // 5. 空白健康状态占位
        emptyHintLabel = NSTextField(labelWithString: "完美状态！未检出任何悬空断链、破损 XML 或缺失贴图。")
        emptyHintLabel.font = TypeScale.bodyBold
        emptyHintLabel.textColor = NSColor.systemGreen
        emptyHintLabel.alignment = .center
        emptyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(emptyHintLabel)

        NSLayoutConstraint.activate([
            emptyHintLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyHintLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor)
        ])
    }

    private func makeMetricCard(title: String, defaultVal: String, sub: String) -> (NSView, NSTextField, NSTextField) {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = ColorToken.panelBg.cgColor
        box.layer?.cornerRadius = CornerRadius.card
        box.layer?.borderWidth = 1.0
        box.layer?.borderColor = ColorToken.cardBorder.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)
        ])

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = TypeScale.captionMedium
        titleLbl.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        stack.addArrangedSubview(titleLbl)

        let valLbl = NSTextField(labelWithString: defaultVal)
        valLbl.font = TypeScale.metricTitle
        valLbl.textColor = .white
        stack.addArrangedSubview(valLbl)

        let subLbl = NSTextField(labelWithString: sub)
        subLbl.font = TypeScale.caption
        subLbl.textColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
        stack.addArrangedSubview(subLbl)

        return (box, valLbl, subLbl)
    }

    // MARK: – Actions

    @objc public func onScanClicked() {
        startScan()
    }

    public func startScan(customRoots: [String]? = nil) {
        spinner?.startAnimation(nil)
        statusSummaryLabel?.stringValue = "正在深度体检 Motion Templates 全盘目录，排查断链、破损与贴图缺失…"

        GhostPluginDoctor.shared.scanAsync(customRoots: customRoots) { [weak self] report in
            guard let self = self else { return }
            self.spinner?.stopAnimation(nil)
            self.applyReport(report)
            self.onScanFinished?(report)
        }
    }

    public func applyReport(_ report: DoctorReport) {
        currentReport = report
        issues = report.issues

        scoreCardValueLabel?.stringValue = "\(report.healthScore)"
        scoreCardRatingLabel?.stringValue = report.scoreRating
        danglingCardLabel?.stringValue = "\(report.danglingCount)"
        corruptedCardLabel?.stringValue = "\(report.corruptedXMLCount)"
        mediaCardLabel?.stringValue = "\(report.missingMediaCount)"

        if report.healthScore == 100 {
            scoreCardValueLabel?.textColor = .systemGreen
        } else if report.healthScore >= 80 {
            scoreCardValueLabel?.textColor = .systemYellow
        } else {
            scoreCardValueLabel?.textColor = .systemRed
        }

        let qCount = report.quarantineRecords.count
        let qInfo = qCount > 0 ? " ｜ 已安全隔离: \(qCount) 项" : ""
        statusSummaryLabel?.stringValue = "体检完成：扫描 \(report.totalScanned) 项，发现 \(report.issues.count) 项病症 (断链 \(report.danglingCount) / 破损 \(report.corruptedXMLCount) / 缺贴图 \(report.missingMediaCount))\(qInfo)"

        emptyHintLabel?.isHidden = !report.issues.isEmpty
        issuesTableView?.reloadData()

        AssetCacheManager.shared.setDoctorReport(report)
    }

    @objc public func onRelinkAllClicked() {
        guard let report = currentReport, !report.issues.isEmpty else {
            statusSummaryLabel?.stringValue = "当前无待重连的悬空断链。"
            return
        }

        let danglingIssues = report.issues.filter { $0.symptom == .danglingSymlink }
        guard !danglingIssues.isEmpty else {
            statusSummaryLabel?.stringValue = "当前无待重连的悬空断链。"
            return
        }

        // FCPX-056: 自愈前弹窗确认影响条数
        let alert = NSAlert()
        alert.messageText = "确认一键智能自愈？"
        alert.informativeText = "将扫描外置硬盘并对检测到的 \(danglingIssues.count) 项悬空软链接进行目标重连写入。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开始自愈")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let (success, failed) = GhostPluginDoctor.shared.relinkAll(issues: danglingIssues)
        statusSummaryLabel?.stringValue = "一键自愈完成：成功重连 \(success) 项软链接，失败 \(failed) 项。"

        AssetCacheManager.shared.invalidateAll()
        startScan()
    }

    @objc public func onQuarantineAllClicked() {
        guard let report = currentReport, !report.issues.isEmpty else {
            statusSummaryLabel?.stringValue = "当前无待隔离的破损模板。"
            return
        }

        // FCPX-055: 隔离前弹窗确认影响数量与可撤销提示
        let alert = NSAlert()
        alert.messageText = "确认一键隔离破损模板？"
        alert.informativeText = "将把检测到的全部 \(report.issues.count) 项破损模板安全移入隔离区（_Quarantine 目录）。隔离后可随时在下方点击【一键全部还原】撤销恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "执行隔离")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let (success, failed) = GhostPluginDoctor.shared.quarantineAll(issues: report.issues)
        statusSummaryLabel?.stringValue = "一键隔离完成：已安全移入 _Quarantine \(success) 项，失败 \(failed) 项（可随时点击下方【一键全部还原】恢复）。"

        AssetCacheManager.shared.invalidateAll()
        startScan()
    }

    @objc public func onRestoreAllClicked() {
        let (success, failed) = GhostPluginDoctor.shared.restoreAll()
        statusSummaryLabel?.stringValue = "一键还原完成：已从隔离区原路复原 \(success) 项，失败 \(failed) 项。"

        AssetCacheManager.shared.invalidateAll()
        startScan()
    }

    // MARK: – TableView DataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return issues.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < issues.count else { return nil }
        let issue = issues[row]
        let colId = tableColumn?.identifier.rawValue ?? ""

        if colId == "colSym" {
            let cell = NSTextField(labelWithString: "\(issue.symptom.icon) \(issue.symptom.displayName)")
            cell.font = .systemFont(ofSize: 11, weight: .bold)
            switch issue.symptom {
            case .danglingSymlink: cell.textColor = .systemYellow
            case .corruptedXML:    cell.textColor = .systemRed
            case .missingMedia:    cell.textColor = .systemOrange
            }
            return cell
        } else if colId == "colName" {
            let cell = NSTextField(labelWithString: issue.templateName)
            cell.font = .systemFont(ofSize: 12, weight: .medium)
            cell.textColor = .white
            return cell
        } else if colId == "colCategory" {
            let cell = NSTextField(labelWithString: issue.category)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            return cell
        } else if colId == "colDetail" {
            let cell = NSTextField(labelWithString: issue.detail)
            cell.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            cell.textColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
            return cell
        } else if colId == "colFix" {
            let cell = NSTextField(labelWithString: issue.suggestedFix)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = issue.canAutoRelink ? .systemGreen : NSColor(calibratedWhite: 0.70, alpha: 1.0)
            return cell
        } else if colId == "colAction" {
            let box = NSView()
            if issue.symptom == .danglingSymlink && issue.canAutoRelink {
                let btn = NSButton(title: "⚡️ 自愈", target: self, action: #selector(onSingleRelinkClicked(_:)))
                btn.tag = row
                btn.bezelStyle = .inline
                btn.frame = NSRect(x: 2, y: 4, width: 68, height: 22)
                box.addSubview(btn)
            } else {
                let btn = NSButton(title: "🛡️ 隔离", target: self, action: #selector(onSingleQuarantineClicked(_:)))
                btn.tag = row
                btn.bezelStyle = .inline
                btn.frame = NSRect(x: 2, y: 4, width: 68, height: 22)
                box.addSubview(btn)
            }
            return box
        }

        return nil
    }

    @objc private func onSingleRelinkClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < issues.count else { return }
        let issue = issues[idx]
        do {
            if try GhostPluginDoctor.shared.relink(issue: issue) {
                statusSummaryLabel?.stringValue = "成功自愈重连：\(issue.templateName)"
                AssetCacheManager.shared.invalidateAll()
                startScan()
            }
        } catch {
            statusSummaryLabel?.stringValue = "重连失败：\(error.localizedDescription)"
        }
    }

    @objc private func onSingleQuarantineClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < issues.count else { return }
        let issue = issues[idx]
        do {
            _ = try GhostPluginDoctor.shared.quarantine(issue: issue)
            statusSummaryLabel?.stringValue = "已移入安全隔离区: \(issue.templateName)"
            AssetCacheManager.shared.invalidateAll()
            startScan()
        } catch {
            statusSummaryLabel?.stringValue = "隔离失败：\(error.localizedDescription)"
        }
    }
}
