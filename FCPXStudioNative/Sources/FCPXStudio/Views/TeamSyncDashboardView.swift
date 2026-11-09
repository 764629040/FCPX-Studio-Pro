import AppKit
import Foundation
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════
//  TeamSyncDashboardView —— 团队资产免流量分发与环境克隆看板（R44）
//
//  对标白皮书规格：《建议 3：团队插件与预设免流量极速分发与生产环境一键克隆》
//  视觉风格：嘉星 2.app 深度深色 Pro（#141518 纯黑底色、#1A1D24 卡片面板）
//
//  三大核心分区：
//    1. 【局域网在线设备雷达】：Bonjour 自动发现同网段剪辑设备，显示主机名/IP/状态，一键点对点直传
//    2. 【生产环境一键克隆与打包面板】：
//       - 导出 .fcpxpack 包（支持勾选标题/特效/转场/发生器/LUT/工作区情境）
//       - 导入并部署 .fcpxpack 包（支持覆盖/跳过/共存策略）
//    3. 【传输与同步历史审计日志】：实时展示发送与接收记录、耗时与 SHA-256 校验状态
// ═══════════════════════════════════════════════════════════════

public final class TeamSyncDashboardView: NSView,
                                          NSTableViewDataSource,
                                          NSTableViewDelegate {

    // MARK: – UI Controls
    public var serverStatusBadge: NSTextField!
    public var toggleServerBtn: NSButton!
    public var serverErrorLabel: NSTextField!
    public var refreshRadarBtn: NSButton!
    public var addPeerBtn: NSButton!
    public var radarTableView: NSTableView!
    public var historyTableView: NSTableView!
    public private(set) var lastServerError: String? = nil

    // Environment Cloner UI
    public var chkTitles: NSButton!
    public var chkEffects: NSButton!
    public var chkTransitions: NSButton!
    public var chkGenerators: NSButton!
    public var chkLUTs: NSButton!
    public var chkProfiles: NSButton!
    public var exportPackageBtn: NSButton!
    public var exportStatusLabel: NSTextField!

    public var conflictPolicyPopup: NSPopUpButton!
    public var importPackageBtn: NSButton!
    public var importStatusLabel: NSTextField!
    public var dropBoxView: NSView!

    // State
    public private(set) var peers: [PeerDevice] = []
    public private(set) var history: [SyncTransferRecord] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupNotifications()
        refreshData()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPeersUpdated),
            name: TeamP2PSyncManager.didUpdatePeersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTransfersUpdated),
            name: TeamP2PSyncManager.didUpdateTransfersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTemplateReceived),
            name: TeamP2PSyncManager.didReceiveTemplateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onServerStateChanged),
            name: TeamP2PSyncManager.didChangeServerStateNotification,
            object: nil
        )
    }

    @objc private func onServerStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateServerBadge()
        }
    }

    @objc private func onPeersUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.peers = TeamP2PSyncManager.shared.peers
            self.radarTableView?.reloadData()
        }
    }

    @objc private func onTransfersUpdated() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.history = TeamP2PSyncManager.shared.transferHistory
            self.historyTableView?.reloadData()
        }
    }

    @objc private func onTemplateReceived(_ notif: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshData()
        }
    }

    // MARK: – UI 构建
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor

        let scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        addSubview(scrollView)

        let contentView = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 860))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 14
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        // 1. 顶层标题与状态操作栏
        let topBar = buildTopBar()
        mainStack.addArrangedSubview(topBar)

        // 2. 分区 1：局域网在线设备雷达
        let radarCard = buildRadarCard()
        mainStack.addArrangedSubview(radarCard)

        // 3. 分区 2：生产环境一键克隆与打包器
        let clonerCard = buildClonerCard()
        mainStack.addArrangedSubview(clonerCard)

        // 4. 分区 3：传输与同步历史日志
        let historyCard = buildHistoryCard()
        mainStack.addArrangedSubview(historyCard)
    }

    // MARK: – 1. 顶层标题栏
    private func buildTopBar() -> NSView {
        let topStack = NSStackView()
        topStack.orientation = .horizontal
        topStack.spacing = 10
        topStack.alignment = .centerY
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let titleBox = NSStackView()
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 2

        let title = NSTextField(labelWithString: "团队资产免流量分发与环境克隆 (Team P2P Sync & Environment Cloner)")
        title.font = TypeScale.bodyBold
        title.textColor = .white
        titleBox.addArrangedSubview(title)

        let sub = NSTextField(labelWithString: "基于 Bonjour 局域网自发现与 TCP 直传 · SHA-256 硬件校验 · 生产环境一键打包克隆与秒级部署")
        sub.font = TypeScale.footnote
        sub.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        titleBox.addArrangedSubview(sub)
        topStack.addArrangedSubview(titleBox)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topStack.addArrangedSubview(spacer)

        // FCPX-050 / TR-005: 真实局域网服务状态徽章与启停控制
        serverStatusBadge = NSTextField(labelWithString: "⚪ 未开启局域网监听")
        serverStatusBadge.font = .systemFont(ofSize: 11, weight: .medium)
        serverStatusBadge.wantsLayer = true
        serverStatusBadge.layer?.cornerRadius = 5
        topStack.addArrangedSubview(serverStatusBadge)

        toggleServerBtn = makeProButton(title: "▶️ 启动局域网监听", target: self, action: #selector(onToggleServerClicked))
        topStack.addArrangedSubview(toggleServerBtn)

        serverErrorLabel = NSTextField(labelWithString: "")
        serverErrorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        serverErrorLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
        serverErrorLabel.isHidden = true
        topStack.addArrangedSubview(serverErrorLabel)

        updateServerBadge()

        refreshRadarBtn = makeProButton(title: "🔄 刷新雷达", target: self, action: #selector(onRefreshRadarClicked))
        topStack.addArrangedSubview(refreshRadarBtn)

        addPeerBtn = makeProButton(title: "➕ 手动添加对端", target: self, action: #selector(onAddPeerClicked))
        topStack.addArrangedSubview(addPeerBtn)

        return topStack
    }

    // MARK: – 2. 局域网设备雷达卡片
    private func buildRadarCard() -> NSView {
        let card = makeCardView(height: 180)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: "📡")
        iconLabel.font = .systemFont(ofSize: 14)
        headerRow.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "局域网在线剪辑工作站雷达")
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        headerRow.addArrangedSubview(titleLabel)

        let tipLabel = NSTextField(labelWithString: "(千兆局域网免流量点对点极速直传，目标机接收自动安装)")
        tipLabel.font = .systemFont(ofSize: 10)
        tipLabel.textColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
        headerRow.addArrangedSubview(tipLabel)

        stack.addArrangedSubview(headerRow)

        // 雷达列表 TableView
        let tableScroll = NSScrollView()
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 6
        tableScroll.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true

        radarTableView = NSTableView()
        radarTableView.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        radarTableView.headerView = NSTableHeaderView()
        radarTableView.rowHeight = 32
        radarTableView.gridStyleMask = .solidHorizontalGridLineMask
        radarTableView.usesAlternatingRowBackgroundColors = false
        radarTableView.dataSource = self
        radarTableView.delegate = self

        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColDeviceName"))
        col1.title = "剪辑设备主机名"
        col1.width = 240
        radarTableView.addTableColumn(col1)

        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColEndpoint"))
        col2.title = "IP 地址与通信端口"
        col2.width = 180
        radarTableView.addTableColumn(col2)

        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColStatus"))
        col3.title = "雷达在线状态"
        col3.width = 120
        radarTableView.addTableColumn(col3)

        let col4 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColAction"))
        col4.title = "快捷直传操作"
        col4.width = 220
        radarTableView.addTableColumn(col4)

        tableScroll.documentView = radarTableView
        stack.addArrangedSubview(tableScroll)

        NSLayoutConstraint.activate([
            tableScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])

        return card
    }

    // MARK: – 3. 生产环境一键克隆与打包卡片
    private func buildClonerCard() -> NSView {
        let card = makeCardView(height: 250)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: "📦")
        iconLabel.font = .systemFont(ofSize: 14)
        headerRow.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "生产环境与素材库一键克隆打包器 (.fcpxpack)")
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        headerRow.addArrangedSubview(titleLabel)

        let subLabel = NSTextField(labelWithString: "(一键将全套生产资产封存归档，新入职剪辑机 10 秒 100% 完整复刻)")
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
        headerRow.addArrangedSubview(subLabel)
        stack.addArrangedSubview(headerRow)

        // 左右双列
        let colsStack = NSStackView()
        colsStack.orientation = .horizontal
        colsStack.distribution = .fillEqually
        colsStack.spacing = 14
        colsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(colsStack)

        NSLayoutConstraint.activate([
            colsStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            colsStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            colsStack.heightAnchor.constraint(equalToConstant: 190)
        ])

        // 左列：【导出克隆包】
        let leftBox = makeSubBox(title: "【导出克隆包】封存本机生产环境")
        colsStack.addArrangedSubview(leftBox)

        let chkGrid = NSStackView()
        chkGrid.orientation = .vertical
        chkGrid.alignment = .leading
        chkGrid.spacing = 4
        chkGrid.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(chkGrid)

        chkTitles = makeCheckbox(title: "💬 标题字幕 (Titles)", state: true)
        chkEffects = makeCheckbox(title: "✨ 视频特效 (Effects)", state: true)
        chkTransitions = makeCheckbox(title: "🔄 视频转场 (Transitions)", state: true)
        chkGenerators = makeCheckbox(title: "⚡️ 视频发生器 (Generators)", state: true)
        chkLUTs = makeCheckbox(title: "🎨 3D LUT 调色库 (.cube)", state: true)
        chkProfiles = makeCheckbox(title: "🗂️ 工作区情境与预设配置", state: true)

        let rowA = NSStackView(views: [chkTitles, chkEffects])
        let rowB = NSStackView(views: [chkTransitions, chkGenerators])
        let rowC = NSStackView(views: [chkLUTs, chkProfiles])
        for r in [rowA, rowB, rowC] {
            r.orientation = .horizontal
            r.spacing = 16
            chkGrid.addArrangedSubview(r)
        }

        exportPackageBtn = makeProAccentButton(
            title: "📦 立即生成 .fcpxpack 克隆包",
            target: self,
            action: #selector(onExportPackageClicked)
        )
        exportPackageBtn.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(exportPackageBtn)

        exportStatusLabel = NSTextField(labelWithString: "就绪 · 勾选分类后即可生成一键克隆包")
        exportStatusLabel.font = .systemFont(ofSize: 10)
        exportStatusLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        exportStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(exportStatusLabel)

        NSLayoutConstraint.activate([
            chkGrid.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 32),
            chkGrid.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 12),
            chkGrid.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -12),

            exportPackageBtn.topAnchor.constraint(equalTo: chkGrid.bottomAnchor, constant: 10),
            exportPackageBtn.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 12),
            exportPackageBtn.widthAnchor.constraint(equalToConstant: 220),
            exportPackageBtn.heightAnchor.constraint(equalToConstant: 28),

            exportStatusLabel.topAnchor.constraint(equalTo: exportPackageBtn.bottomAnchor, constant: 6),
            exportStatusLabel.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 12),
            exportStatusLabel.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -12)
        ])

        // 右列：【导入恢复克隆包】
        let rightBox = makeSubBox(title: "【导入并部署】新机环境一键复刻")
        colsStack.addArrangedSubview(rightBox)

        let policyLabel = NSTextField(labelWithString: "重名资产冲突处理策略：")
        policyLabel.font = .systemFont(ofSize: 11)
        policyLabel.textColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
        policyLabel.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(policyLabel)

        conflictPolicyPopup = NSPopUpButton()
        conflictPolicyPopup.translatesAutoresizingMaskIntoConstraints = false
        conflictPolicyPopup.removeAllItems()
        conflictPolicyPopup.addItems(withTitles: ["覆盖现有", "跳过冲突", "保留两者"])
        rightBox.addSubview(conflictPolicyPopup)

        importPackageBtn = makeProAccentButton(
            title: "📥 选择 .fcpxpack 包并一键部署",
            target: self,
            action: #selector(onImportPackageClicked)
        )
        importPackageBtn.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(importPackageBtn)

        importStatusLabel = NSTextField(labelWithString: "支持从团队共享盘或 P2P 直传包导入，自动分类安装")
        importStatusLabel.font = .systemFont(ofSize: 10)
        importStatusLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        importStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(importStatusLabel)

        NSLayoutConstraint.activate([
            policyLabel.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 36),
            policyLabel.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 12),

            conflictPolicyPopup.leadingAnchor.constraint(equalTo: policyLabel.trailingAnchor, constant: 8),
            conflictPolicyPopup.centerYAnchor.constraint(equalTo: policyLabel.centerYAnchor),
            conflictPolicyPopup.widthAnchor.constraint(equalToConstant: 120),

            importPackageBtn.topAnchor.constraint(equalTo: policyLabel.bottomAnchor, constant: 16),
            importPackageBtn.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 12),
            importPackageBtn.widthAnchor.constraint(equalToConstant: 240),
            importPackageBtn.heightAnchor.constraint(equalToConstant: 28),

            importStatusLabel.topAnchor.constraint(equalTo: importPackageBtn.bottomAnchor, constant: 10),
            importStatusLabel.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 12),
            importStatusLabel.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -12)
        ])

        return card
    }

    // MARK: – 4. 传输历史审计日志卡片
    private func buildHistoryCard() -> NSView {
        let card = makeCardView(height: 220)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: "📋")
        iconLabel.font = .systemFont(ofSize: 14)
        headerRow.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "局域网传输与环境同步审计日志")
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        headerRow.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        let clearBtn = makeProButton(title: "清空日志", target: self, action: #selector(onClearHistoryClicked))
        headerRow.addArrangedSubview(clearBtn)
        stack.addArrangedSubview(headerRow)

        let tableScroll = NSScrollView()
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 6
        tableScroll.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true

        historyTableView = NSTableView()
        historyTableView.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        historyTableView.headerView = NSTableHeaderView()
        historyTableView.rowHeight = 26
        historyTableView.gridStyleMask = .solidHorizontalGridLineMask
        historyTableView.usesAlternatingRowBackgroundColors = false
        historyTableView.dataSource = self
        historyTableView.delegate = self

        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColTime"))
        col1.title = "时间"
        col1.width = 110
        historyTableView.addTableColumn(col1)

        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColDirection"))
        col2.title = "方向"
        col2.width = 70
        historyTableView.addTableColumn(col2)

        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColItem"))
        col3.title = "资产名称"
        col3.width = 200
        historyTableView.addTableColumn(col3)

        let col4 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColPeer"))
        col4.title = "对端工作站"
        col4.width = 160
        historyTableView.addTableColumn(col4)

        let col5 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColSize"))
        col5.title = "大小"
        col5.width = 80
        historyTableView.addTableColumn(col5)

        let col6 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColTransferStatus"))
        col6.title = "传输与校验状态"
        col6.width = 130
        historyTableView.addTableColumn(col6)

        let col7 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColDuration"))
        col7.title = "耗时"
        col7.width = 70
        historyTableView.addTableColumn(col7)

        tableScroll.documentView = historyTableView
        stack.addArrangedSubview(tableScroll)

        NSLayoutConstraint.activate([
            tableScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        return card
    }

    // MARK: – 交互操作与服务器监听控制
    // TR-006: 52888 监听端口只能由用户点击「▶️ 启动局域网监听」开启。
    // 严禁在 viewDidMoveToWindow / refreshData / 任何无 UI 入口的路径里调用 startServer()。
    // 看板挂载、切换、数据刷新都不得改变监听状态，只做 UI 状态同步。

    private func updateServerBadge() {
        let mgr = TeamP2PSyncManager.shared
        if let err = lastServerError {
            serverStatusBadge?.stringValue = "🔴 监听异常"
            serverStatusBadge?.textColor = NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
            serverStatusBadge?.layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.10, blue: 0.10, alpha: 1.0).cgColor
            serverErrorLabel?.stringValue = "(\(err))"
            serverErrorLabel?.isHidden = false
            toggleServerBtn?.title = "▶️ 重新启动监听"
        } else if mgr.isListening {
            serverStatusBadge?.stringValue = "🟢 局域网监听中: 端口 \(mgr.localPort)"
            serverStatusBadge?.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
            serverStatusBadge?.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.14, alpha: 1.0).cgColor
            serverErrorLabel?.isHidden = true
            toggleServerBtn?.title = "⏹ 停止局域网监听"
        } else {
            serverStatusBadge?.stringValue = "⚪ 未开启局域网监听"
            serverStatusBadge?.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            serverStatusBadge?.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
            serverErrorLabel?.isHidden = true
            toggleServerBtn?.title = "▶️ 启动局域网监听"
        }
    }

    // TR-006: 全局唯一开启/关闭局域网监听的 UI 入口。
    @objc public func onToggleServerClicked() {
        let mgr = TeamP2PSyncManager.shared
        if mgr.isListening {
            mgr.stopServer()
            lastServerError = nil
        } else {
            do {
                lastServerError = nil
                try mgr.startServer()
                mgr.startBrowsing()
            } catch {
                lastServerError = error.localizedDescription
                NSLog("[TeamSync] 启动服务器失败: \(error)")
            }
        }
        updateServerBadge()
    }

    // TR-006: 纯数据刷新 + 徽章同步，绝不启动监听。
    // init / 切换看板 / 收到模板 / 刷新雷达 都会走这里，均不允许成为隐式启动路径。
    @objc public func refreshData() {
        self.peers = TeamP2PSyncManager.shared.peers
        self.history = TeamP2PSyncManager.shared.transferHistory
        updateServerBadge()
        radarTableView?.reloadData()
        historyTableView?.reloadData()
    }

    @objc private func onRefreshRadarClicked() {
        TeamP2PSyncManager.shared.stopBrowsing()
        TeamP2PSyncManager.shared.startBrowsing()
        refreshData()
    }

    @objc private func onAddPeerClicked() {
        let alert = NSAlert()
        alert.messageText = "手动添加局域网剪辑对端"
        alert.informativeText = "请输入目标 Mac 的局域网 IP 地址与端口号："

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "127.0.0.1:52888"
        alert.accessoryView = input
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespaces)
            let comps = text.components(separatedBy: ":")
            let host = comps.first ?? "127.0.0.1"
            let port = (comps.count > 1 ? Int(comps[1]) : nil) ?? TeamP2PSyncManager.defaultPort
            TeamP2PSyncManager.shared.addManualPeer(name: "手动对端 (\(host))", host: host, port: port)
            refreshData()
        }
    }

    @objc private func onExportPackageClicked() {
        var cats: [String] = []
        if chkTitles.state == .on { cats.append("Titles.localized") }
        if chkEffects.state == .on { cats.append("Effects.localized") }
        if chkTransitions.state == .on { cats.append("Transitions.localized") }
        if chkGenerators.state == .on { cats.append("Generators.localized") }

        let incLUT = (chkLUTs.state == .on)
        let incProf = (chkProfiles.state == .on)

        let savePanel = NSSavePanel()
        savePanel.title = "导出 FCPX 生产环境克隆包"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "fcpxpack") ?? .data]
        // UI-O017: 统一命名格式 FCPXStudio_ProductionEnv_yyyyMMdd_HHmmss.fcpxpack
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        savePanel.nameFieldStringValue = "FCPXStudio_ProductionEnv_\(df.string(from: Date())).fcpxpack"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            // FCPX-012: 导出异步化与进度提示
            exportPackageBtn.isEnabled = false
            exportStatusLabel.stringValue = "⏳ 正在打包并生成环境克隆包，请稍候…"
            exportStatusLabel.textColor = NSColor.systemOrange

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let manifest = try EnvironmentCloner.shared.exportPackage(
                        categories: cats,
                        includeLUTs: incLUT,
                        includeProfiles: incProf,
                        outputPath: url.path
                    )
                    let mb = Double(manifest.totalSizeBytes) / (1024.0 * 1024.0)
                    DispatchQueue.main.async {
                        self.exportPackageBtn.isEnabled = true
                        self.exportStatusLabel.stringValue = "✅ 成功导出：\(manifest.templateCount) 款模板 · \(manifest.lutCount) 款 LUT · \(manifest.profileCount) 组情境 (\(String(format: "%.2f", mb)) MB)"
                        self.exportStatusLabel.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.exportPackageBtn.isEnabled = true
                        self.exportStatusLabel.stringValue = "❌ 导出失败：\(error.localizedDescription)"
                        self.exportStatusLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
                    }
                }
            }
        }
    }

    @objc private func onImportPackageClicked() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择要导入并恢复的 FCPX 环境克隆包"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "fcpxpack") ?? .data]
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            let sel = conflictPolicyPopup.indexOfSelectedItem
            let policy: ConflictPolicy
            switch sel {
            case 1: policy = .skip
            case 2: policy = .keepBoth
            default: policy = .overwrite
            }

            // FCPX-012: 导入部署异步化与进度提示
            importPackageBtn.isEnabled = false
            importStatusLabel.stringValue = "⏳ 正在解析并部署克隆包，请稍候…"
            importStatusLabel.textColor = NSColor.systemOrange

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let summary = try EnvironmentCloner.shared.importPackage(packagePath: url.path, conflictPolicy: policy)
                    DispatchQueue.main.async {
                        self.importPackageBtn.isEnabled = true
                        self.importStatusLabel.stringValue = "✅ 部署完成：\(summary.installedTemplatesCount) 模板 · \(summary.installedLUTsCount) LUT · \(summary.installedProfilesCount) 情境 (跳过 \(summary.skippedCount))"
                        self.importStatusLabel.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                        self.refreshData()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.importPackageBtn.isEnabled = true
                        self.importStatusLabel.stringValue = "❌ 导入失败：\(error.localizedDescription)"
                        self.importStatusLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
                    }
                }
            }
        }
    }

    @objc private func onClearHistoryClicked() {
        let count = history.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "清空传输记录"
        alert.informativeText = "将清空 \(count) 条传输记录，此操作不可撤销。\n是否确认？"
        alert.addButton(withTitle: "确认清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            TeamP2PSyncManager.shared.clearTransferHistory()
            refreshData()
        }
    }

    // MARK: – TableView DataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == radarTableView {
            return peers.count
        } else if tableView == historyTableView {
            return history.count
        }
        return 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier.rawValue else { return nil }

        if tableView == radarTableView {
            guard row < peers.count else { return nil }
            let p = peers[row]
            switch colId {
            case "ColDeviceName":
                let text = "\(p.isLocal ? "💻 [本机] " : "🖥️ ")\(p.name)"
                return makeCellLabel(text: text, bold: true)
            case "ColEndpoint":
                return makeCellLabel(text: "\(p.host):\(p.port)")
            case "ColStatus":
                let pill = makeCellLabel(text: p.status)
                pill.textColor = p.status.contains("在线")
                    ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                    : NSColor(calibratedWhite: 0.6, alpha: 1.0)
                return pill
            case "ColAction":
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 6
                let sendTmplBtn = makeSmallButton(title: "🚀 发送模板", tag: row)
                sendTmplBtn.target = self
                sendTmplBtn.action = #selector(onSendTemplateToPeerClicked(_:))
                stack.addArrangedSubview(sendTmplBtn)

                let sendPackBtn = makeSmallButton(title: "📦 发送克隆包", tag: row)
                sendPackBtn.target = self
                sendPackBtn.action = #selector(onSendPackageToPeerClicked(_:))
                stack.addArrangedSubview(sendPackBtn)
                return stack
            default:
                return nil
            }
        } else if tableView == historyTableView {
            guard row < history.count else { return nil }
            let h = history[row]
            switch colId {
            case "ColTime":
                let df = DateFormatter()
                df.dateFormat = "HH:mm:ss"
                return makeCellLabel(text: df.string(from: h.timestamp))
            case "ColDirection":
                return makeCellLabel(text: h.direction.rawValue)
            case "ColItem":
                return makeCellLabel(text: h.itemName, bold: true)
            case "ColPeer":
                return makeCellLabel(text: h.targetDevice)
            case "ColSize":
                let kb = Double(h.sizeBytes) / 1024.0
                return makeCellLabel(text: String(format: "%.1f KB", kb))
            case "ColTransferStatus":
                let l = makeCellLabel(text: h.status)
                if h.status.contains("成功") || h.status.contains("部署") {
                    l.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                } else {
                    l.textColor = NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1.0)
                }
                return l
            case "ColDuration":
                return makeCellLabel(text: "\(Int(h.durationMs)) ms")
            default:
                return nil
            }
        }
        return nil
    }

    @objc private func onSendTemplateToPeerClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < peers.count else { return }
        let peer = peers[idx]

        let openPanel = NSOpenPanel()
        openPanel.title = "选择要免流量直传到「\(peer.name)」的模板或文件夹"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            let cat = "Titles.localized"
            TeamP2PSyncManager.shared.sendTemplate(
                to: peer.host,
                port: peer.port,
                folderPath: url.path,
                category: cat
            ) { [weak self] result in
                switch result {
                case .success:
                    self?.showBanner(title: "直传成功", msg: "模板已成功免流量传输并安装至 \(peer.name)")
                case .failure(let err):
                    self?.showBanner(title: "直传失败", msg: err.localizedDescription)
                }
            }
        }
    }

    @objc private func onSendPackageToPeerClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < peers.count else { return }
        let peer = peers[idx]

        let openPanel = NSOpenPanel()
        openPanel.title = "选择要免流量直传到「\(peer.name)」的 .fcpxpack 环境克隆包"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "fcpxpack") ?? .data]

        if openPanel.runModal() == .OK, let url = openPanel.url {
            TeamP2PSyncManager.shared.sendPackage(
                to: peer.host,
                port: peer.port,
                packagePath: url.path
            ) { [weak self] result in
                switch result {
                case .success:
                    self?.showBanner(title: "克隆包分发成功", msg: "环境克隆包已成功直传并部署至 \(peer.name)")
                case .failure(let err):
                    self?.showBanner(title: "分发失败", msg: err.localizedDescription)
                }
            }
        }
    }

    private func showBanner(title: String, msg: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.runModal()
    }

    // MARK: – UI 小部件工场
    private func makeCardView(height: CGFloat) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = ColorToken.panelBg.cgColor
        card.layer?.cornerRadius = CornerRadius.card
        card.layer?.borderWidth = 0.8
        card.layer?.borderColor = ColorToken.cardBorder.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: height).isActive = true
        return card
    }

    private func makeSubBox(title: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ColorToken.subpanelBg.cgColor
        v.layer?.cornerRadius = CornerRadius.card
        v.layer?.borderWidth = 0.6
        v.layer?.borderColor = ColorToken.cardBorder.cgColor

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11, weight: .bold)
        t.textColor = .white
        t.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(t)

        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12)
        ])
        return v
    }

    private func makeProButton(title: String, target: AnyObject?, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 11, weight: .medium)
        return btn
    }

    private func makeProAccentButton(title: String, target: AnyObject?, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 11, weight: .bold)
        btn.wantsLayer = true
        btn.contentTintColor = .white
        return btn
    }

    private func makeSmallButton(title: String, tag: Int) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.tag = tag
        btn.bezelStyle = .inline
        btn.font = .systemFont(ofSize: 10, weight: .medium)
        return btn
    }

    private func makeCheckbox(title: String, state: Bool) -> NSButton {
        let chk = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        chk.font = .systemFont(ofSize: 11)
        chk.state = state ? .on : .off
        return chk
    }

    private func makeCellLabel(text: String, bold: Bool = false) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = .systemFont(ofSize: 11, weight: bold ? .semibold : .regular)
        tf.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }
}

fileprivate extension Date {
    var formattedDateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df.string(from: self)
    }
}
