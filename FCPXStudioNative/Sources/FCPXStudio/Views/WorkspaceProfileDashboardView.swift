import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  WorkspaceProfileDashboardView —— 多工作区情境隔离配置看板（R43）
//
//  对标规格：产品白皮书《建议 1：多工作区情境隔离配置》与嘉星 2.app 深度视觉风格
//  布局结构：
//    1. 顶层情境管理操作栏（新建/复制/删除/一键全开/刷新）
//    2. 顶部情境切换卡片流（水平滚动卡片组，激活徽章与一键激活按钮）
//    3. 当前情境详情看板（活跃插件、已休眠隔离、FCPX 启动项节省比例与提速倍率）
//    4. 模板归属勾选矩阵 TableView（即时勾选/取消归属于当前选中情境）
// ═══════════════════════════════════════════════════════════════

public final class WorkspaceProfileCardView: NSView {
    public let profile: WorkspaceProfile
    public let isActive: Bool
    public let isSelected: Bool

    public var onActivate: (() -> Void)?
    public var onSelect: (() -> Void)?

    public private(set) var spinner: NSProgressIndicator!
    public private(set) var activeBadge: NSTextField!
    public private(set) var activateBtn: NSButton!
    private var borderLayer: CALayer?

    public init(profile: WorkspaceProfile, isActive: Bool, isSelected: Bool) {
        self.profile = profile
        self.isActive = isActive
        self.isSelected = isSelected
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 110))
        setupUI()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = isSelected
            ? NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1.0).cgColor
            : NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0).cgColor

        layer?.borderWidth = isActive ? 1.5 : (isSelected ? 1.2 : 0.8)
        layer?.borderColor = isActive
            ? NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.95, alpha: 1.0).cgColor
            : (isSelected ? NSColor(calibratedRed: 0.40, green: 0.50, blue: 0.65, alpha: 0.8).cgColor
                          : NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 220).isActive = true
        heightAnchor.constraint(equalToConstant: 105).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        // 1. 顶行：图标 + 名称 + 加载器 + 激活胶囊
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: profile.icon)
        iconLabel.font = .systemFont(ofSize: 16)
        headerRow.addArrangedSubview(iconLabel)

        let nameLabel = NSTextField(labelWithString: profile.name)
        nameLabel.font = TypeScale.bodyBold
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        headerRow.addArrangedSubview(nameLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        headerRow.addArrangedSubview(spinner)

        activeBadge = NSTextField(labelWithString: isActive ? "🟢 激活中" : "⚪️ 未激活")
        activeBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        activeBadge.textColor = isActive
            ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
            : NSColor(calibratedWhite: 0.50, alpha: 1.0)
        headerRow.addArrangedSubview(activeBadge)
        stack.addArrangedSubview(headerRow)

        // 2. 描述 / 分类
        let subLabel = NSTextField(labelWithString: "\(profile.category) · \(profile.isDefault ? "包含全部模板" : "\(profile.includedTemplateIDs.count) 组规则")")
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        stack.addArrangedSubview(subLabel)

        // 3. 底部操作按钮行
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 6
        btnRow.alignment = .centerY

        activateBtn = NSButton(title: isActive ? "⚡️ 正在使用" : "⚡️ 激活此情境", target: self, action: #selector(onActivateClicked))
        activateBtn.bezelStyle = .rounded
        activateBtn.font = .systemFont(ofSize: 10, weight: .medium)
        activateBtn.isEnabled = !isActive
        if isActive {
            activateBtn.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        }
        btnRow.addArrangedSubview(activateBtn)

        let selectBtn = NSButton(title: isSelected ? "🔍 正在配置" : "⚙️ 配置矩阵", target: self, action: #selector(onSelectClicked))
        selectBtn.bezelStyle = .rounded
        selectBtn.font = .systemFont(ofSize: 10, weight: .regular)
        btnRow.addArrangedSubview(selectBtn)

        stack.addArrangedSubview(btnRow)
    }

    public func showLoading(_ loading: Bool) {
        if loading {
            spinner?.startAnimation(nil)
            activeBadge?.stringValue = "⚡️ 切换中…"
            activeBadge?.textColor = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.20, alpha: 1.0)
            activateBtn?.isEnabled = false
        } else {
            spinner?.stopAnimation(nil)
            activeBadge?.stringValue = isActive ? "🟢 激活中" : "⚪️ 未激活"
            activeBadge?.textColor = isActive
                ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                : NSColor(calibratedWhite: 0.50, alpha: 1.0)
            activateBtn?.isEnabled = !isActive
        }
    }

    @objc private func onActivateClicked() {
        showLoading(true)
        onActivate?()
    }

    @objc private func onSelectClicked() {
        onSelect?()
    }

    public override func mouseDown(with event: NSEvent) {
        // FCPX-011: 点击卡片仅选中当前情境查看矩阵，激活必须点击专属激活按钮并二次确认
        onSelect?()
    }
}

public final class WorkspaceProfileDashboardView: NSView,
                                                  NSTableViewDataSource,
                                                  NSTableViewDelegate {

    // MARK: – Top Action Bar Controls
    public var refreshButton: NSButton!
    public var addProfileButton: NSButton!
    public var duplicateButton: NSButton!
    public var deleteButton: NSButton!
    public var resetAllButton: NSButton!
    public var spinner: NSProgressIndicator!
    public var statusLabel: NSTextField!
    public private(set) var profileCards: [WorkspaceProfileCardView] = []

    // MARK: – Metric Cards
    public var activeProfileValueLabel: NSTextField!
    public var activeCountValueLabel: NSTextField!
    public var disabledCountValueLabel: NSTextField!
    public var savingsValueLabel: NSTextField!

    // MARK: – R50: 情境隔离（.disabled 机制）底层生效指示
    public var mechanismBannerView: NSView!
    public var isolatedStatusSummaryLabel: NSTextField!
    public var diskSafetyStatusLabel: NSTextField!
    public var memorySavingStatusLabel: NSTextField!
    public var instantResumeStatusLabel: NSTextField!

    // MARK: – Profile Cards Flow
    public var profileCardsScrollView: NSScrollView!
    public var profileCardsStackView: NSStackView!

    // MARK: – Template Matrix Section
    public var matrixTitleLabel: NSTextField!
    public var searchField: NSSearchField!
    public var categoryPopUp: NSPopUpButton!
    public var selectAllButton: NSButton!
    public var deselectAllButton: NSButton!
    public var matrixTableView: NSTableView!

    // MARK: – State
    public private(set) var profiles: [WorkspaceProfile] = []
    public private(set) var selectedProfileId: UUID = WorkspaceProfile.allActiveId
    public private(set) var allTemplates: [TemplateItem] = []
    public private(set) var filteredTemplates: [TemplateItem] = []
    public private(set) var currentStats: WorkspaceProfileStats?

    public var onProfileActivated: ((WorkspaceProfile) -> Void)?

    // MARK: – Init
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupNotificationObservers()
        refreshData()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupNotificationObservers()
        refreshData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onProfilesChangedNotification),
            name: WorkspaceProfileManager.didUpdateProfilesNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onActiveProfileChangedNotification),
            name: WorkspaceProfileManager.didChangeActiveProfileNotification,
            object: nil
        )
    }

    @objc private func onProfilesChangedNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshData()
        }
    }

    @objc private func onActiveProfileChangedNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshData()
        }
    }

    // MARK: – UI Setup
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = ColorToken.panelBg.cgColor

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        // 1. 顶层标题与主操作栏
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topBar)

        let titleBox = NSStackView()
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 2

        let mainTitle = NSTextField(labelWithString: "多工作区情境隔离配置系统 (Workspace Context Isolation)")
        mainTitle.font = TypeScale.bodyBold
        mainTitle.textColor = .white
        titleBox.addArrangedSubview(mainTitle)

        let subTitle = NSTextField(labelWithString: "按影视项目情境按需启停插件 · FCPX 启动提速 5~10x · 毫秒级 .disabled 隔离 · 一键无损全开")
        subTitle.font = TypeScale.footnote
        subTitle.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        titleBox.addArrangedSubview(subTitle)

        topBar.addArrangedSubview(titleBox)

        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(spacer1)

        addProfileButton = NSButton(title: "新建情境", target: self, action: #selector(onAddProfileClicked))
        addProfileButton.bezelStyle = .rounded
        topBar.addArrangedSubview(addProfileButton)

        duplicateButton = NSButton(title: "复制情境", target: self, action: #selector(onDuplicateClicked))
        duplicateButton.bezelStyle = .rounded
        topBar.addArrangedSubview(duplicateButton)

        deleteButton = NSButton(title: "删除情境", target: self, action: #selector(onDeleteClicked))
        deleteButton.bezelStyle = .rounded
        topBar.addArrangedSubview(deleteButton)

        resetAllButton = NSButton(title: "还原全部启用", target: self, action: #selector(onResetAllClicked))
        resetAllButton.bezelStyle = .rounded
        resetAllButton.contentTintColor = ColorToken.successGreen
        topBar.addArrangedSubview(resetAllButton)

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(onRefreshClicked))
        refreshButton.bezelStyle = .rounded
        topBar.addArrangedSubview(refreshButton)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        topBar.addArrangedSubview(spinner)

        topBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 2. 顶部情境切换卡片流 (Profile Cards Flow)
        profileCardsScrollView = NSScrollView()
        profileCardsScrollView.hasHorizontalScroller = true
        profileCardsScrollView.hasVerticalScroller = false
        profileCardsScrollView.borderType = .noBorder
        profileCardsScrollView.drawsBackground = false
        profileCardsScrollView.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(profileCardsScrollView)

        profileCardsScrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        profileCardsScrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let clipView = NSClipView()
        clipView.drawsBackground = false
        profileCardsScrollView.contentView = clipView

        profileCardsStackView = NSStackView()
        profileCardsStackView.orientation = .horizontal
        profileCardsStackView.spacing = 10
        profileCardsStackView.alignment = .centerY
        profileCardsStackView.translatesAutoresizingMaskIntoConstraints = false
        profileCardsScrollView.documentView = profileCardsStackView

        // 3. 当前情境详情看板 (4 张暗色石墨卡片)
        let cardsRow = NSStackView()
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 10
        cardsRow.distribution = .fillEqually
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(cardsRow)
        cardsRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        cardsRow.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let card1 = makeMetricCard(title: "当前激活情境", icon: "⚡️")
        activeProfileValueLabel = card1.1
        cardsRow.addArrangedSubview(card1.0)

        let card2 = makeMetricCard(title: "活跃插件数量", icon: "🟢")
        activeCountValueLabel = card2.1
        cardsRow.addArrangedSubview(card2.0)

        let card3 = makeMetricCard(title: "已休眠隔离插件", icon: "⚪️")
        disabledCountValueLabel = card3.1
        cardsRow.addArrangedSubview(card3.0)

        let card4 = makeMetricCard(title: "FCPX 启动项节省", icon: "🚀")
        savingsValueLabel = card4.1
        cardsRow.addArrangedSubview(card4.0)

        // 3.5 情境隔离（.disabled 机制）底层生效机制直观指示卡片 (R50 状态强化)
        mechanismBannerView = NSView()
        mechanismBannerView.wantsLayer = true
        mechanismBannerView.layer?.cornerRadius = 8
        mechanismBannerView.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.20, alpha: 0.85).cgColor
        mechanismBannerView.layer?.borderWidth = 1.0
        mechanismBannerView.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.75, alpha: 0.50).cgColor
        mechanismBannerView.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(mechanismBannerView)
        mechanismBannerView.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        let bannerStack = NSStackView()
        bannerStack.orientation = .vertical
        bannerStack.alignment = .leading
        bannerStack.spacing = 6
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        mechanismBannerView.addSubview(bannerStack)

        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: mechanismBannerView.topAnchor, constant: 10),
            bannerStack.leadingAnchor.constraint(equalTo: mechanismBannerView.leadingAnchor, constant: 14),
            bannerStack.trailingAnchor.constraint(equalTo: mechanismBannerView.trailingAnchor, constant: -14),
            bannerStack.bottomAnchor.constraint(equalTo: mechanismBannerView.bottomAnchor, constant: -10)
        ])

        let bHeader = NSStackView()
        bHeader.orientation = .horizontal
        bHeader.spacing = 8
        bHeader.alignment = .centerY

        let bShieldIcon = NSImageView()
        bShieldIcon.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
        bShieldIcon.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        bShieldIcon.translatesAutoresizingMaskIntoConstraints = false
        bShieldIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        bShieldIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        bHeader.addArrangedSubview(bShieldIcon)

        let bTitle = NSTextField(labelWithString: "情境隔离（.disabled 机制）底层运行状态与安全保障")
        bTitle.font = .systemFont(ofSize: 12, weight: .bold)
        bTitle.textColor = .white
        bHeader.addArrangedSubview(bTitle)

        let bSpacer = NSView()
        bSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bHeader.addArrangedSubview(bSpacer)

        isolatedStatusSummaryLabel = NSTextField(labelWithString: "已安全隔离 0 项 · 节省 0% 启动扫描")
        isolatedStatusSummaryLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        isolatedStatusSummaryLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1.0)
        bHeader.addArrangedSubview(isolatedStatusSummaryLabel)
        bannerStack.addArrangedSubview(bHeader)
        bHeader.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true

        let bGrid = NSStackView()
        bGrid.orientation = .horizontal
        bGrid.spacing = 16
        bGrid.distribution = .fillEqually
        bGrid.translatesAutoresizingMaskIntoConstraints = false
        bannerStack.addArrangedSubview(bGrid)
        bGrid.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true

        diskSafetyStatusLabel = NSTextField(wrappingLabelWithString: "📁 物理文件安全：100% 磁盘保留，原文件绝不移动或删除，零数据损坏风险。")
        diskSafetyStatusLabel.font = .systemFont(ofSize: 10)
        diskSafetyStatusLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        bGrid.addArrangedSubview(diskSafetyStatusLabel)

        memorySavingStatusLabel = NSTextField(wrappingLabelWithString: "🚀 零 FCPX 内存开销：加注 .disabled 后缀使 FCPX 启动深度跳过扫描，完全不入内存。")
        memorySavingStatusLabel.font = .systemFont(ofSize: 10)
        memorySavingStatusLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        bGrid.addArrangedSubview(memorySavingStatusLabel)

        instantResumeStatusLabel = NSTextField(wrappingLabelWithString: "⚡️ 秒级瞬时恢复：切回「全量模式」或对应情境瞬时去除后缀，FCPX 菜单即刻恢复。")
        instantResumeStatusLabel.font = .systemFont(ofSize: 10)
        instantResumeStatusLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        bGrid.addArrangedSubview(instantResumeStatusLabel)

        // 4. 模板归属勾选矩阵工具栏
        let matrixToolBar = NSStackView()
        matrixToolBar.orientation = .horizontal
        matrixToolBar.spacing = 8
        matrixToolBar.alignment = .centerY
        matrixToolBar.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(matrixToolBar)
        matrixToolBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        matrixTitleLabel = NSTextField(labelWithString: "📋 模板归属勾选矩阵")
        matrixTitleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        matrixTitleLabel.textColor = .white
        matrixToolBar.addArrangedSubview(matrixTitleLabel)

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        matrixToolBar.addArrangedSubview(spacer2)

        searchField = NSSearchField()
        searchField.placeholderString = "搜索模板名称..."
        searchField.target = self
        searchField.action = #selector(onFilterChanged)
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        matrixToolBar.addArrangedSubview(searchField)

        categoryPopUp = NSPopUpButton()
        categoryPopUp.addItem(withTitle: "全部类别")
        for cat in TemplateTierScanner.categories {
            let clean = cat.replacingOccurrences(of: ".localized", with: "")
            categoryPopUp.addItem(withTitle: clean)
        }
        categoryPopUp.target = self
        categoryPopUp.action = #selector(onFilterChanged)
        matrixToolBar.addArrangedSubview(categoryPopUp)

        selectAllButton = NSButton(title: "全选归属", target: self, action: #selector(onSelectAllTemplatesClicked))
        selectAllButton.bezelStyle = .rounded
        matrixToolBar.addArrangedSubview(selectAllButton)

        deselectAllButton = NSButton(title: "全不选", target: self, action: #selector(onDeselectAllTemplatesClicked))
        deselectAllButton.bezelStyle = .rounded
        matrixToolBar.addArrangedSubview(deselectAllButton)

        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        matrixToolBar.addArrangedSubview(statusLabel)

        // 5. 模板明细矩阵 TableView
        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .bezelBorder

        matrixTableView = NSTableView()
        matrixTableView.headerView = NSTableHeaderView()
        matrixTableView.rowHeight = 32
        matrixTableView.gridColor = NSColor(calibratedWhite: 0.16, alpha: 1.0)
        matrixTableView.gridStyleMask = [.solidHorizontalGridLineMask]
        matrixTableView.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)

        let colCheck = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("include"))
        colCheck.title = "归属情境"
        colCheck.width = 75
        matrixTableView.addTableColumn(colCheck)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = "模板名称"
        colName.width = 240
        matrixTableView.addTableColumn(colName)

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        colCategory.title = "所属分类"
        colCategory.width = 140
        matrixTableView.addTableColumn(colCategory)

        let colState = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        colState.title = "当前物理状态"
        colState.width = 120
        matrixTableView.addTableColumn(colState)

        let colTier = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tier"))
        colTier.title = "存储层级"
        colTier.width = 90
        matrixTableView.addTableColumn(colTier)

        matrixTableView.dataSource = self
        matrixTableView.delegate = self

        tableScrollView.documentView = matrixTableView
        mainStack.addArrangedSubview(tableScrollView)

        NSLayoutConstraint.activate([
            tableScrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: mainStack.bottomAnchor)
        ])
    }

    private func makeMetricCard(title: String, icon: String) -> (NSView, NSTextField) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = CornerRadius.card
        card.layer?.backgroundColor = ColorToken.panelBg.cgColor
        card.layer?.borderColor = ColorToken.cardBorder.cgColor
        card.layer?.borderWidth = 1

        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.alignment = .leading
        vStack.spacing = 2
        vStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            vStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            vStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            vStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])

        let hTitle = NSStackView()
        hTitle.orientation = .horizontal
        hTitle.spacing = 6
        hTitle.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = TypeScale.footnote
        hTitle.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = TypeScale.footnoteMedium
        titleLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        hTitle.addArrangedSubview(titleLabel)

        vStack.addArrangedSubview(hTitle)

        let valueLabel = NSTextField(labelWithString: "--")
        valueLabel.font = TypeScale.metricTitle
        valueLabel.textColor = .white
        vStack.addArrangedSubview(valueLabel)

        return (card, valueLabel)
    }

    // MARK: – 数据刷新与更新 (UI-G046)
    public func refreshData() {
        let mgr = WorkspaceProfileManager.shared
        mgr.reload()
        profiles = mgr.profiles

        if !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = mgr.activeProfileId
        }

        updateCardsFlow()
        updateDashboardMetrics()

        if !allTemplates.isEmpty {
            applyFilter()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var scanned: [TemplateItem] = []
            for cat in TemplateTierScanner.categories {
                if let cached = AssetCacheManager.shared.getTemplates(category: cat) {
                    scanned.append(contentsOf: cached.items)
                } else {
                    let res = TemplateTierScanner.scan(category: cat, roots: .resolve(), lazySizes: true)
                    scanned.append(contentsOf: res.items)
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allTemplates = scanned
                self.applyFilter()
                self.updateDashboardMetrics()
            }
        }
    }

    private func updateCardsFlow() {
        profileCardsStackView.arrangedSubviews.forEach {
            profileCardsStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        profileCards.removeAll()

        let activeId = WorkspaceProfileManager.shared.activeProfileId
        for profile in profiles {
            let card = WorkspaceProfileCardView(
                profile: profile,
                isActive: (profile.id == activeId),
                isSelected: (profile.id == selectedProfileId)
            )
            card.onActivate = { [weak self] in
                self?.activateProfile(id: profile.id)
            }
            card.onSelect = { [weak self] in
                self?.selectProfile(id: profile.id)
            }
            profileCardsStackView.addArrangedSubview(card)
            profileCards.append(card)
        }
    }

    private func updateDashboardMetrics() {
        let mgr = WorkspaceProfileManager.shared
        let stats = mgr.getCurrentStats()
        currentStats = stats

        let activeProfile = mgr.getActiveProfile()
        activeProfileValueLabel.stringValue = "\(activeProfile.icon) \(activeProfile.name.components(separatedBy: " ").first ?? activeProfile.name)"
        activeCountValueLabel.stringValue = "\(stats.activeTemplates) / \(stats.totalTemplates)"
        disabledCountValueLabel.stringValue = "\(stats.disabledTemplates) 个"

        if stats.reductionPercentage > 0 {
            savingsValueLabel.stringValue = "\(stats.reductionPercentage)% (提速 \(stats.estimatedSpeedup)x)"
            savingsValueLabel.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
            isolatedStatusSummaryLabel?.stringValue = "已安全隔离 \(stats.disabledTemplates) 项 · 节省 \(stats.reductionPercentage)% 启动扫描 (提速 \(stats.estimatedSpeedup)x)"
            isolatedStatusSummaryLabel?.textColor = NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1.0)
            memorySavingStatusLabel?.stringValue = "🚀 零 FCPX 内存开销：已物理隔离 \(stats.disabledTemplates) 项，FCPX 完全跳过扫描，零内存占用。"
        } else {
            savingsValueLabel.stringValue = "0% (全量运行)"
            savingsValueLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
            isolatedStatusSummaryLabel?.stringValue = "全量就绪 · 0 插件休眠隔离"
            isolatedStatusSummaryLabel?.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
            memorySavingStatusLabel?.stringValue = "🚀 零 FCPX 内存开销：加注 .disabled 后缀使 FCPX 启动深度跳过扫描，完全不入内存。"
        }

        if let selected = profiles.first(where: { $0.id == selectedProfileId }) {
            matrixTitleLabel.stringValue = "📋 模板归属勾选矩阵（正在配置：\(selected.icon) \(selected.name)）"
        }
    }

    private func applyFilter() {
        let kw = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let catIdx = categoryPopUp?.indexOfSelectedItem ?? 0

        filteredTemplates = allTemplates.filter { it in
            if !kw.isEmpty {
                let hitName = it.name.lowercased().contains(kw)
                let hitCat  = it.category.lowercased().contains(kw)
                if !hitName && !hitCat { return false }
            }
            if catIdx > 0 {
                let targetCat = TemplateTierScanner.categories[catIdx - 1]
                if it.category != targetCat { return false }
            }
            return true
        }
        matrixTableView?.reloadData()
    }

    @objc private func onFilterChanged() {
        applyFilter()
    }

    public func selectProfile(id: UUID) {
        selectedProfileId = id
        updateCardsFlow()
        updateDashboardMetrics()
        matrixTableView?.reloadData()
    }

    // MARK: – 用户操作响应
    public func activateProfile(id: UUID) {
        guard LicenseManager.shared.isProLicensed else {
            let alert = NSAlert()
            alert.messageText = "商业授权未激活"
            alert.informativeText = "未激活商业授权，多工作区情境隔离快速切换已锁定。请先激活商业授权。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        guard let p = profiles.first(where: { $0.id == id }) else { return }

        // FCPX-011: 激活专属二次确认弹窗
        let confirmAlert = NSAlert()
        confirmAlert.messageText = "激活情境「\(p.name)」"
        confirmAlert.informativeText = "激活后将根据情境规则临时隔离非关联插件（添加 .disabled 后缀），加速 FCPX 启动。原插件文件完好无损，随时可一键全开恢复。\n\n是否确认激活此情境？"
        confirmAlert.addButton(withTitle: "确认激活")
        confirmAlert.addButton(withTitle: "取消")
        if confirmAlert.runModal() != .alertFirstButtonReturn {
            updateCardsFlow()
            return
        }

        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在激活情境「\(p.name)」并隔离插件..."

        for card in profileCards {
            if card.profile.id == id {
                card.showLoading(true)
            } else {
                card.showLoading(false)
            }
        }

        WorkspaceProfileManager.shared.activateProfile(id: id) { [weak self] result in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let stats):
                self.statusLabel.stringValue = "情境「\(p.name)」已激活！已休眠 \(stats.disabledTemplates) 个插件"
                self.selectedProfileId = id
                self.refreshData()
                self.onProfileActivated?(p)
                if !stats.failures.isEmpty {
                    let failList = stats.failures.joined(separator: "\n")
                    self.showAlert(title: "部分模板切换失败", msg: "共 \(stats.failures.count) 项模板状态切换失败：\n\(failList)")
                }
            case .failure(let error):
                self.statusLabel.stringValue = "激活失败: \(error.localizedDescription)"
                self.refreshData()
                self.showAlert(title: "情境激活失败", msg: error.localizedDescription)
            }
        }
    }

    @objc private func onRefreshClicked() {
        refreshData()
        statusLabel.stringValue = "已刷新情境与模板状态"
    }

    @objc private func onResetAllClicked() {
        activateProfile(id: WorkspaceProfile.allActiveId)
    }

    @objc private func onAddProfileClicked() {
        let alert = NSAlert()
        alert.messageText = "新建自定义工作区情境"
        alert.informativeText = "请输入新情境名称（例如：微电影制作、纪录片包装）："
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "情境名称"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let created = WorkspaceProfileManager.shared.addProfile(
                name: name,
                icon: "🎬",
                category: "自定义情境",
                description: "剪辑师专属自定义工作区情境"
            )
            selectedProfileId = created.id
            refreshData()
            statusLabel.stringValue = "已创建新情境「\(name)」"
        }
    }

    @objc private func onDuplicateClicked() {
        if let copy = WorkspaceProfileManager.shared.duplicateProfile(id: selectedProfileId) {
            selectedProfileId = copy.id
            refreshData()
            statusLabel.stringValue = "已复制情境「\(copy.name)」"
        }
    }

    @objc private func onDeleteClicked() {
        guard let p = profiles.first(where: { $0.id == selectedProfileId }) else { return }
        if p.isBuiltin {
            showAlert(title: "内置情境受保护", msg: "出厂预置的【\(p.name)】受保护，不支持删除。您可以自由新建自定义情境。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认删除情境「\(p.name)」？"
        alert.informativeText = "删除后不可恢复。若该情境正处于激活状态，系统将自动切回全量默认模式。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            _ = WorkspaceProfileManager.shared.deleteProfile(id: p.id)
            selectedProfileId = WorkspaceProfile.allActiveId
            refreshData()
            statusLabel.stringValue = "已删除情境「\(p.name)」"
        }
    }

    @objc private func onSelectAllTemplatesClicked() {
        guard let p = profiles.first(where: { $0.id == selectedProfileId }), !p.isDefault else { return }
        for it in filteredTemplates {
            if !p.matches(templateName: it.name) {
                WorkspaceProfileManager.shared.toggleTemplate(named: it.name, in: selectedProfileId)
            }
        }
        refreshData()
        statusLabel.stringValue = "已批量选中当前分类下的全部模板"
    }

    @objc private func onDeselectAllTemplatesClicked() {
        guard let p = profiles.first(where: { $0.id == selectedProfileId }), !p.isDefault else { return }
        for it in filteredTemplates {
            if p.matches(templateName: it.name) {
                WorkspaceProfileManager.shared.toggleTemplate(named: it.name, in: selectedProfileId)
            }
        }
        refreshData()
        statusLabel.stringValue = "已清空当前分类下的全部模板归属"
    }

    private func showAlert(title: String, msg: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: – NSTableViewDataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredTemplates.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredTemplates.count else { return nil }
        let item = filteredTemplates[row]
        let colId = tableColumn?.identifier.rawValue ?? ""

        switch colId {
        case "include":
            let isIncluded = WorkspaceProfileManager.shared.isTemplateIncluded(templateName: item.name, in: selectedProfileId)
            let checkBtn = NSButton(checkboxWithTitle: "", target: self, action: #selector(onTableRowCheckboxToggled(_:)))
            checkBtn.tag = row
            checkBtn.state = isIncluded ? .on : .off
            return checkBtn

        case "name":
            let cell = NSTextField(labelWithString: item.name)
            cell.font = .systemFont(ofSize: 12, weight: .bold)
            cell.textColor = .white
            return cell

        case "category":
            let clean = item.category.replacingOccurrences(of: ".localized", with: "")
            let cell = NSTextField(labelWithString: clean)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
            return cell

        case "state":
            let cell = NSTextField(labelWithString: item.isEnabled ? "🟢 正常活跃" : "⚪️ 已休眠 (.disabled)")
            cell.font = .systemFont(ofSize: 11, weight: .medium)
            cell.textColor = item.isEnabled
                ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                : NSColor(calibratedWhite: 0.50, alpha: 1.0)
            return cell

        case "tier":
            let cell = NSTextField(labelWithString: item.tier == .builtin ? "系统内置" : (item.isSymlink ? "外置软链" : "用户本地"))
            cell.font = .systemFont(ofSize: 10)
            cell.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
            return cell

        default:
            return nil
        }
    }

    @objc private func onTableRowCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < filteredTemplates.count else { return }
        let item = filteredTemplates[row]

        WorkspaceProfileManager.shared.toggleTemplate(named: item.name, in: selectedProfileId)

        // 若当前选中的情境正是正在激活的情境，则即时应用启停状态
        if selectedProfileId == WorkspaceProfileManager.shared.activeProfileId {
            activateProfile(id: selectedProfileId)
        } else {
            refreshData()
        }
    }
}
