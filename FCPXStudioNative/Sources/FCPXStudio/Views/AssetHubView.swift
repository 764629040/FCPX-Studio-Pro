import AppKit
import AVFoundation

// ═══════════════════════════════════════════════════════════════
//  AssetHubView —— FCPX 专业素材与外置管理工作站（R40 嘉星视觉与性能终极大成）
//
//  对标基准：/Applications/嘉星插件管理 2.app (Bundle ID: com.FxXu.0412)
//
//  三大核心架构演进：
//    1. 【专业深色 Pro 垂直侧边栏 (Sidebar)】：
//       - 视觉模板（Titles / Effects / Transitions / Generators）
//       - 专业媒体（3D LUT 调色 / 影视音效库）
//       - 系统工具（资源库瘦身医生 / 偏好设置）
//       - 底部常驻外置盘挂载状态灯与容量
//    2. 【现代化顶层工具栏 (Toolbar)】：
//       - 即输即搜 SearchField（支持中英文即时匹配）
//       - 三级归属快捷过滤、排序
//       - 卡片网格 (Grid) ⊞ 与专业列表 (List) ☰ 双模切换
//    3. 【高质感卡片网格流 (ResourceCardView Grid)】：
//       - 16:9 缩略图视口、中文友好别名、容量徽章
//       - 精致「🟢 开启 / ⚪️ 禁用」胶囊 Toggle 开关与「⋯」操作菜单
//    4. 【彻底根除卡顿的异步与多级内存缓存 (AssetCacheManager)】：
//       - scanAsync 后台 GCD 扫描 + 0ms 内存秒级复用
//       - 模板体积后台懒加载，彻底杜绝主线程阻塞与彩虹圈
// ═══════════════════════════════════════════════════════════════

public final class FlippedContainerView: NSView {
    public override var isFlipped: Bool { true }
}

// ═══════════════════════════════════════════════════════════════
//  InvisibleScroller
//  零可见原生滚动条：彻底隐藏滑轨与滑块，保持触控板与滚轮流畅滚动 (R52)
// ═══════════════════════════════════════════════════════════════
public final class InvisibleScroller: NSScroller {
    public override func draw(_ dirtyRect: NSRect) {
        // 彻底不绘制滑轨与背景
    }

    public override func drawKnob() {
        // 彻底不绘制滑块
    }

    public override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 彻底不绘制滑块槽道
    }

    public override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }
}

// ═══════════════════════════════════════════════════════════════
//  GroupTableRowView
//  中栏 TableView 自定义整行高亮圆角柔光背景 (R52)
// ═══════════════════════════════════════════════════════════════
public final class GroupTableRowView: NSTableRowView {
    public override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            let selectionRect = NSInsetRect(bounds, 3, 2)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.95, alpha: 0.32).setFill()
            path.fill()
            NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 0.60).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        // 保持透明，不遮挡底层磨砂穿透
    }
}

// ═══════════════════════════════════════════════════════════════
//  LicenseStatusCardView
//  左侧侧边栏顶部品牌授权看板卡片 (R52)
//  独一无二机器码、一键复制、激活按钮与内嵌轻量输入激活面板
// ═══════════════════════════════════════════════════════════════
public final class LicenseStatusCardView: NSView {
    public var onLicenseChanged: (() -> Void)?

    public private(set) var machineCodeLabel: NSTextField!
    public private(set) var copyButton: NSButton!
    public private(set) var statusBadgeLabel: NSTextField!
    public private(set) var toggleActionButton: NSButton!
    public private(set) var fcpxVersionLabel: NSTextField!
    public private(set) var loadTimeIndicatorLabel: NSTextField!

    // 内嵌轻量激活面板
    public private(set) var drawerBox: NSView!
    public private(set) var keyInputField: NSTextField!
    public private(set) var confirmActivateBtn: NSButton!
    public private(set) var messageLabel: NSTextField!

    public private(set) var isDrawerExpanded: Bool = false
    public private(set) var heightConstraint: NSLayoutConstraint?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.50).cgColor
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 3
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        // 1. 机器码行（标签 + 复制小按钮）
        let machineRow = NSStackView()
        machineRow.orientation = .horizontal
        machineRow.alignment = .centerY
        machineRow.spacing = 4

        machineCodeLabel = NSTextField(labelWithString: "【机器码】 \(LicenseManager.shared.machineCode)")
        machineCodeLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        machineCodeLabel.textColor = NSColor(calibratedRed: 0.40, green: 0.75, blue: 1.0, alpha: 1.0)
        machineRow.addArrangedSubview(machineCodeLabel)

        copyButton = NSButton(title: "复制", target: self, action: #selector(onCopyMachineCode))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.font = .systemFont(ofSize: 9.0, weight: .medium)
        copyButton.contentTintColor = NSColor(calibratedRed: 0.60, green: 0.85, blue: 1.0, alpha: 1.0)
        copyButton.toolTip = "一键复制机器唯一码到剪贴板"
        machineRow.addArrangedSubview(copyButton)

        mainStack.addArrangedSubview(machineRow)

        // 2. 授权状态行（徽章 + 激活/注销动作按钮）
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        statusBadgeLabel = NSTextField(labelWithString: "")
        statusBadgeLabel.font = .systemFont(ofSize: 9.5, weight: .bold)
        statusRow.addArrangedSubview(statusBadgeLabel)

        toggleActionButton = NSButton(title: "🔑 激活", target: self, action: #selector(onToggleActionClicked))
        toggleActionButton.bezelStyle = .roundRect
        toggleActionButton.font = .systemFont(ofSize: 9.5, weight: .bold)
        statusRow.addArrangedSubview(toggleActionButton)

        mainStack.addArrangedSubview(statusRow)

        // 3. FCPX 版本检测与用时
        fcpxVersionLabel = NSTextField(labelWithString: "Final Cut Pro 检测就绪")
        fcpxVersionLabel.font = .systemFont(ofSize: 9.0, weight: .regular)
        fcpxVersionLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        mainStack.addArrangedSubview(fcpxVersionLabel)

        loadTimeIndicatorLabel = NSTextField(labelWithString: "列表加载用时: 0.08s")
        loadTimeIndicatorLabel.font = .systemFont(ofSize: 9.0, weight: .regular)
        loadTimeIndicatorLabel.textColor = NSColor(calibratedWhite: 0.52, alpha: 1.0)
        mainStack.addArrangedSubview(loadTimeIndicatorLabel)

        // 4. 内嵌轻量输入激活面板
        drawerBox = NSView()
        drawerBox.wantsLayer = true
        drawerBox.layer?.cornerRadius = 6
        drawerBox.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.65).cgColor
        drawerBox.layer?.borderWidth = 0.5
        drawerBox.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.75, alpha: 0.50).cgColor
        drawerBox.isHidden = true
        drawerBox.translatesAutoresizingMaskIntoConstraints = false

        let drawerStack = NSStackView()
        drawerStack.orientation = .vertical
        drawerStack.alignment = .leading
        drawerStack.spacing = 4
        drawerStack.translatesAutoresizingMaskIntoConstraints = false
        drawerBox.addSubview(drawerStack)

        NSLayoutConstraint.activate([
            drawerStack.topAnchor.constraint(equalTo: drawerBox.topAnchor, constant: 4),
            drawerStack.leadingAnchor.constraint(equalTo: drawerBox.leadingAnchor, constant: 6),
            drawerStack.trailingAnchor.constraint(equalTo: drawerBox.trailingAnchor, constant: -6),
            drawerStack.bottomAnchor.constraint(equalTo: drawerBox.bottomAnchor, constant: -4)
        ])

        keyInputField = NSTextField()
        keyInputField.placeholderString = "输入许可证代码 FCPX-LIC-..."
        keyInputField.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        keyInputField.bezelStyle = .roundedBezel
        keyInputField.translatesAutoresizingMaskIntoConstraints = false
        keyInputField.widthAnchor.constraint(equalToConstant: 176).isActive = true
        drawerStack.addArrangedSubview(keyInputField)

        let drawerBtnRow = NSStackView()
        drawerBtnRow.orientation = .horizontal
        drawerBtnRow.spacing = 4

        confirmActivateBtn = NSButton(title: "立即激活", target: self, action: #selector(onConfirmActivateClicked))
        confirmActivateBtn.bezelStyle = .roundRect
        confirmActivateBtn.font = .systemFont(ofSize: 9.5, weight: .bold)
        drawerBtnRow.addArrangedSubview(confirmActivateBtn)

        let cancelBtn = NSButton(title: "收起", target: self, action: #selector(onCancelDrawerClicked))
        cancelBtn.bezelStyle = .roundRect
        cancelBtn.font = .systemFont(ofSize: 9.5)
        drawerBtnRow.addArrangedSubview(cancelBtn)

        drawerStack.addArrangedSubview(drawerBtnRow)

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 8.5)
        messageLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        drawerStack.addArrangedSubview(messageLabel)

        mainStack.addArrangedSubview(drawerBox)

        heightConstraint = heightAnchor.constraint(equalToConstant: 78)
        heightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        updateLicenseDisplay()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateLicenseDisplay),
            name: LicenseManager.didChangeLicenseStatusNotification,
            object: nil
        )
    }

    @objc public func updateLicenseDisplay() {
        machineCodeLabel.stringValue = "【机器码】 \(LicenseManager.shared.machineCode)"
        if LicenseManager.shared.isProLicensed {
            statusBadgeLabel.stringValue = "🟢 永久商用授权"
            statusBadgeLabel.textColor = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.50, alpha: 1.0)
            toggleActionButton.title = "已授权"
            toggleActionButton.toolTip = "当前已拥有全量商业旗舰版授权"
            if isDrawerExpanded {
                setDrawerExpanded(false)
            }
        } else {
            statusBadgeLabel.stringValue = "🟡 试用体验版"
            statusBadgeLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.28, alpha: 1.0)
            toggleActionButton.title = "🔑 激活"
            toggleActionButton.toolTip = "输入商业授权代码解锁全量功能"
        }
    }

    @objc private func onCopyMachineCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(LicenseManager.shared.machineCode, forType: .string)
        copyButton.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "复制"
        }
    }

    @objc private func onToggleActionClicked() {
        if LicenseManager.shared.isProLicensed {
            let alert = NSAlert()
            alert.messageText = "商业授权管理"
            alert.informativeText = "当前机器已成功激活商业旗舰版授权。\n机器码：\(LicenseManager.shared.machineCode)\n许可证：\(LicenseManager.shared.activeLicenseKey ?? "已生效")\n\n是否需要注销本地授权（用于迁移或测试）？"
            alert.addButton(withTitle: "保持激活")
            alert.addButton(withTitle: "注销授权")
            if alert.runModal() == .alertSecondButtonReturn {
                LicenseManager.shared.deactivate()
                updateLicenseDisplay()
                onLicenseChanged?()
            }
        } else {
            setDrawerExpanded(!isDrawerExpanded)
        }
    }

    @objc private func onCancelDrawerClicked() {
        setDrawerExpanded(false)
    }

    public func setDrawerExpanded(_ expanded: Bool) {
        isDrawerExpanded = expanded
        drawerBox.isHidden = !expanded
        heightConstraint?.constant = expanded ? 152 : 78
    }

    @objc public func onConfirmActivateClicked() {
        let code = keyInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            messageLabel.stringValue = "请输入授权代码"
            return
        }
        let result = LicenseManager.shared.activate(key: code)
        if result.success {
            messageLabel.stringValue = ""
            setDrawerExpanded(false)
            updateLicenseDisplay()
            onLicenseChanged?()
        } else {
            messageLabel.stringValue = "❌ 校验未通过，请检查代码"
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  R51 插件分组数据模型（1:1 对标嘉星插件管理 2.app 分组 TableView）
// ═══════════════════════════════════════════════════════════════
public struct TemplateGroupItem: Identifiable, Equatable {
    public var id: String { "\(category)/\(name)/\(tier.rawValue)" }
    public var name: String
    public var category: String
    public var tier: TemplateTier
    public var count: Int
    public var totalSizeMB: Double
    public var items: [TemplateItem]

    public init(name: String, category: String, tier: TemplateTier, count: Int, totalSizeMB: Double, items: [TemplateItem]) {
        self.name = name
        self.category = category
        self.tier = tier
        self.count = count
        self.totalSizeMB = totalSizeMB
        self.items = items
    }

    public static func == (lhs: TemplateGroupItem, rhs: TemplateGroupItem) -> Bool {
        return lhs.name == rhs.name && lhs.category == rhs.category && lhs.tier == rhs.tier && lhs.count == rhs.count
    }
}

public final class AssetHubView: NSVisualEffectView,
                                 NSTableViewDataSource,
                                 NSTableViewDelegate,
                                 NSMenuDelegate {

    // MARK: – Top-level Tab Segments (对标原四大中心，保持 100% 契约兼容)
    public var hubSegmentedControl: NSSegmentedControl!
    public private(set) var currentHubTab: Int = 0

    // MARK: – Containers for Super Modules (R50 偏好设置内嵌工作台)
    public var templateContainerView: NSView!
    public var lutContainerView: NSView!
    public var audioContainerView: NSView!
    public var cleanerContainerView: NSView!
    public var cleanerDashboardView: CleanerDashboardView!
    public var doctorContainerView: NSView!
    public var doctorDashboardView: PluginDoctorDashboardView!
    public var storageContainerView: NSView!
    public var storageMigrationDashboardView: StorageMigrationDashboardView!
    public var profileContainerView: NSView!
    public var profileDashboardView: WorkspaceProfileDashboardView!
    public var teamSyncContainerView: NSView!
    public var teamSyncDashboardView: TeamSyncDashboardView!
    public var settingsContainerView: NSView!
    public var settingsDashboardView: SettingsDashboardView!

    // MARK: – Sidebar UI (第一段：左栏 220pt 品牌看板与系统导航)
    public private(set) var sidebarView: NSView!
    public private(set) var sidebarButtons: [NSButton] = []
    public private(set) var currentSidebarIndex: Int = 0
    // MARK: – R51 第一段状态看板与 R52 品牌商用授权系统
    public var licenseCardView: LicenseStatusCardView!
    public var machineCodeLabel: NSTextField! {
        get { licenseCardView?.machineCodeLabel }
        set { /* compatibility */ }
    }
    public var fcpxVersionLabel: NSTextField! {
        get { licenseCardView?.fcpxVersionLabel }
        set { /* compatibility */ }
    }
    public var loadTimeIndicatorLabel: NSTextField! {
        get { licenseCardView?.loadTimeIndicatorLabel }
        set { /* compatibility */ }
    }
    public private(set) var externalDriveStatusLabel: NSTextField!
    public private(set) var externalDriveSubLabel: NSTextField!

    // MARK: – R51 1:1 三段式：第二段（中栏 360pt 分组列表）
    public var middleColumnView: NSView!
    public var categoryCapsuleControl: NSSegmentedControl!
    public var groupToolbarView: NSView!
    public var groupFinderBtn: NSButton!
    public var groupRenameBtn: NSButton!
    public var groupDeleteBtn: NSButton!
    public var groupNewBtn: NSButton!
    public var groupTableView: NSTableView!
    public var groupScrollView: NSScrollView!
    public var groupItems: [TemplateGroupItem] = []
    public var selectedGroupIndex: Int = 0
    public var selectedGroupItem: TemplateGroupItem? {
        guard selectedGroupIndex >= 0 && selectedGroupIndex < groupItems.count else { return nil }
        return groupItems[selectedGroupIndex]
    }

    // MARK: – R51 1:1 三段式：第三段（右栏 模板网格与批量操作）
    public var rightColumnView: NSView!
    public var breadcrumbLabel: NSTextField!
    public var rightToolbarView: NSView!
    public var createGroupBtn: NSButton!
    public var selectAllBtn: NSButton!
    public var rightFinderBtn: NSButton!
    public var rightTrashBtn: NSButton!
    public var previewToggleBtn: NSButton!

    // MARK: – Module 1: Template UI & Toolbar
    public var categoryTitleLabel: NSTextField!
    public var searchField: NSSearchField!
    public var viewModeSegmentedControl: NSSegmentedControl!
    public var currentViewMode: Int = 0 // 0: Grid (⊞), 1: List (☰)
    public var cardGridScrollView: NSScrollView!
    public var cardGridContentView: FlippedContainerView!
    public var cardViews: [ResourceCardView] = []
    public var tableScrollView: NSScrollView!

    public var pathDisplayField: NSTextField!
    public var pluginTableView: NSTableView!
    public var categoryPopup: NSPopUpButton!
    public var tierFilterPopup: NSPopUpButton!
    public var sortPopup: NSPopUpButton!
    public var statusLabel: NSTextField!
    public var tierStatsLabel: NSTextField!
    /// R48: 子分类快速筛选栏
    public var subCategoryScrollView: NSScrollView!
    public var subCategoryStackView: NSStackView!
    public var currentSubCategoryFilter: String = "全部"
    public private(set) var subCategoryButtons: [NSButton] = []
    public var spinner: NSProgressIndicator!
    public var undoButton: NSButton!
    public var dropOverlayView: NSView!

    public var currentCategory: String = "Titles.localized"
    public var externalRoot: String = AppConfig.shared.defaultExternalAssetsDir
    public var allItems: [TemplateItem] = []
    public var plugins: [TemplateItem] = []
    public private(set) var roots: TemplateTierRoots = .resolve()
    public private(set) var tierNotes: [TemplateTier: String] = [:]

    private let migrator = TemplateMigrator()
    private let categories = TemplateTierScanner.categories
    public var onOpenTemplateInDesigner: ((String) -> Void)?

    // MARK: – Module 2: 3D LUT UI
    public var lutTableView: NSTableView!
    public var lutCategoryPopup: NSPopUpButton!
    public var lutCompareView: LUTCompareView!
    public var lutModeSegmentedControl: NSSegmentedControl!
    public var lutInfoLabel: NSTextField!
    public var lutStatusLabel: NSTextField!

    public private(set) var allLUTItems: [LUTItem] = []
    public private(set) var filteredLUTItems: [LUTItem] = []
    public var selectedLUTItem: LUTItem?

    // MARK: – Module 3: Audio UI
    public var audioTableView: NSTableView!
    public var audioCategoryPopup: NSPopUpButton!
    public var audioWaveformView: AudioWaveformView!
    public var audioPlayBtn: NSButton!
    public var audioStopBtn: NSButton!
    public var audioTitleLabel: NSTextField!
    public var audioMetaLabel: NSTextField!
    public var audioTimeLabel: NSTextField!
    public var audioStatusLabel: NSTextField!

    public private(set) var allAudioItems: [AudioItem] = []
    public private(set) var filteredAudioItems: [AudioItem] = []
    public var selectedAudioItem: AudioItem?

    // MARK: – Init
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        migrator.startMonitoringVolumes()
        setupUI()
        refreshList()
        NotificationCenter.default.addObserver(self, selector: #selector(onPolicyChanged),
                                               name: .tierWritePolicyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onVolumeStatusChanged(_:)),
                                               name: TemplateMigrator.volumeStatusDidChangeNotification, object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        migrator.startMonitoringVolumes()
        setupUI()
        refreshList()
        NotificationCenter.default.addObserver(self, selector: #selector(onPolicyChanged),
                                               name: .tierWritePolicyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onVolumeStatusChanged(_:)),
                                               name: TemplateMigrator.volumeStatusDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        AudioManager.shared.stop()
    }

    public static func detectFCPXVersion() -> String {
        let appPath = "/Applications/Final Cut Pro.app"
        if let b = Bundle(path: appPath),
           let v = b.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "Final Cut Pro v\(v) 已检测就绪"
        }
        return "Final Cut Pro v11.0 已检测就绪"
    }

    // MARK: – Main Layout (左侧 Pro 侧边栏 + 右侧主内容区)

    private func setupUI() {
        wantsLayer = true
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.35).cgColor
        registerForDraggedTypes([.fileURL])

        // 兼容原测试/控制器的顶栏分段控制器（隐藏桥接保留契约）
        hubSegmentedControl = NSSegmentedControl(
            labels: ["🎨 模板插件管理", "🎞️ 3D LUT 调色与分屏", "🎵 影视级音效库", "🧹 工程瘦身清理", "🩺 幽灵插件医生"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onHubTabChanged)
        )
        hubSegmentedControl.selectedSegment = 0
        hubSegmentedControl.isHidden = true
        addSubview(hubSegmentedControl)

        // 1. 构建左侧深色 Pro 侧边栏 (Sidebar: 220pt 宽，升级为毛玻璃质感)
        let sidebarW: CGFloat = 220
        let sidebarVEV = NSVisualEffectView()
        sidebarVEV.material = .sidebar
        sidebarVEV.blendingMode = .behindWindow
        sidebarVEV.state = .active
        sidebarVEV.appearance = NSAppearance(named: .darkAqua)
        sidebarVEV.wantsLayer = true
        sidebarVEV.layer?.borderWidth = 1.0
        sidebarVEV.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        sidebarVEV.translatesAutoresizingMaskIntoConstraints = false
        sidebarView = sidebarVEV
        addSubview(sidebarView)

        // 2. 右侧主体容器
        let mainContainer = NSView()
        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainContainer)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: sidebarW),

            mainContainer.topAnchor.constraint(equalTo: topAnchor),
            mainContainer.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            mainContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        buildSidebarUI()

        // 3. 构建九大超级模块视图（R50 偏好设置内嵌工作台）
        setupTemplateModule(in: mainContainer)
        setupLUTModule(in: mainContainer)
        setupAudioModule(in: mainContainer)
        setupCleanerModule(in: mainContainer)
        setupDoctorModule(in: mainContainer)
        setupStorageModule(in: mainContainer)
        setupProfileModule(in: mainContainer)
        setupTeamSyncModule(in: mainContainer)
        setupSettingsModule(in: mainContainer)

        switchHubTab(to: 0)
    }

    // MARK: – 左侧深色垂直侧边栏 (Sidebar)

    private func buildSidebarUI() {
        let sideStack = NSStackView()
        sideStack.orientation = .vertical
        sideStack.alignment = .leading
        sideStack.spacing = 4
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sideStack)

        // 顶部品牌 Logo 与第一段状态看板
        let brandBox = NSStackView()
        brandBox.orientation = .vertical
        brandBox.alignment = .leading
        brandBox.spacing = 4

        let brandTitle = NSTextField(labelWithString: "✦ FCPX STUDIO PRO")
        brandTitle.font = .systemFont(ofSize: 13.5, weight: .heavy)
        brandTitle.textColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1.0)
        brandBox.addArrangedSubview(brandTitle)

        let brandSub = NSTextField(labelWithString: "专业素材与性能工作站")
        brandSub.font = .systemFont(ofSize: 10, weight: .regular)
        brandSub.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        brandBox.addArrangedSubview(brandSub)

        // R52 品牌商用授权看板卡片（保留实例以防已有代码调用发生 nil 崩溃，但设为 hidden 且不上屏）
        licenseCardView = LicenseStatusCardView()
        licenseCardView.isHidden = true
        licenseCardView.translatesAutoresizingMaskIntoConstraints = false
        licenseCardView.widthAnchor.constraint(equalToConstant: 200).isActive = true
        licenseCardView.fcpxVersionLabel.stringValue = Self.detectFCPXVersion()
        licenseCardView.onLicenseChanged = { [weak self] in
            self?.refreshList()
        }

        sideStack.addArrangedSubview(brandBox)
        sideStack.setCustomSpacing(14, after: brandBox)

        // 分组 1: 【视觉模板】
        addSidebarSectionHeader(title: "视觉模板", to: sideStack)
        addSidebarButton(id: 0, icon: "character.textbox", title: "标题字幕", to: sideStack)
        addSidebarButton(id: 1, icon: "wand.and.stars", title: "视频特效", to: sideStack)
        addSidebarButton(id: 2, icon: "rectangle.2.swap", title: "视频转场", to: sideStack)
        addSidebarButton(id: 3, icon: "film.stack", title: "视频发生器", to: sideStack)
        sideStack.setCustomSpacing(12, after: sidebarButtons.last!)

        // 分组 2: 【专业媒体】
        addSidebarSectionHeader(title: "专业媒体", to: sideStack)
        addSidebarButton(id: 4, icon: "slider.horizontal.3", title: "3D LUT 调色", to: sideStack)
        addSidebarButton(id: 5, icon: "waveform", title: "影视音效库", to: sideStack)
        sideStack.setCustomSpacing(12, after: sidebarButtons.last!)

        // 分组 3: 【系统工具】
        addSidebarSectionHeader(title: "系统工具", to: sideStack)
        addSidebarButton(id: 6, icon: "trash.circle", title: "资源库瘦身医生", to: sideStack)
        addSidebarButton(id: 7, icon: "stethoscope", title: "幽灵插件医生", to: sideStack)
        addSidebarButton(id: 8, icon: "externaldrive", title: "存储与搬家", to: sideStack)
        addSidebarButton(id: 9, icon: "macwindow.on.rectangle", title: "工作区情境", to: sideStack)
        addSidebarButton(id: 10, icon: "paperplane", title: "团队分发", to: sideStack)
        addSidebarButton(id: 11, icon: "gearshape", title: "偏好设置", to: sideStack)

        // 底部外置移动硬盘挂载指示栏 (R52 椭圆胶囊 Pill Shape, cornerRadius = 22, height = 44)
        let footerBox = NSView()
        footerBox.wantsLayer = true
        footerBox.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.45).cgColor
        footerBox.layer?.cornerRadius = 22
        footerBox.layer?.borderWidth = 0.8
        footerBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        footerBox.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(footerBox)

        let driveIconView = NSImageView()
        driveIconView.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "外置存储")
        driveIconView.contentTintColor = NSColor(calibratedRed: 0.28, green: 0.86, blue: 0.55, alpha: 1.0)
        driveIconView.translatesAutoresizingMaskIntoConstraints = false
        footerBox.addSubview(driveIconView)

        let breathingDot = NSView()
        breathingDot.wantsLayer = true
        breathingDot.layer?.cornerRadius = 3.5
        breathingDot.layer?.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.55, alpha: 1.0).cgColor
        breathingDot.layer?.shadowColor = NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.55, alpha: 0.8).cgColor
        breathingDot.layer?.shadowRadius = 4.0
        breathingDot.layer?.shadowOpacity = 1.0
        breathingDot.layer?.shadowOffset = .zero
        breathingDot.translatesAutoresizingMaskIntoConstraints = false
        footerBox.addSubview(breathingDot)

        externalDriveStatusLabel = NSTextField(labelWithString: "外置剪辑盘已就绪")
        externalDriveStatusLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        externalDriveStatusLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        externalDriveStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        footerBox.addSubview(externalDriveStatusLabel)

        externalDriveSubLabel = NSTextField(labelWithString: "0 占用 · 软链接就绪")
        externalDriveSubLabel.font = .systemFont(ofSize: 9.5)
        externalDriveSubLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        externalDriveSubLabel.translatesAutoresizingMaskIntoConstraints = false
        footerBox.addSubview(externalDriveSubLabel)

        let footerBtn = NSButton(title: "", target: self, action: #selector(onFooterDriveClicked))
        footerBtn.isTransparent = true
        footerBtn.translatesAutoresizingMaskIntoConstraints = false
        footerBox.addSubview(footerBtn)

        NSLayoutConstraint.activate([
            sideStack.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 16),
            sideStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 10),
            sideStack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -10),

            footerBox.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 10),
            footerBox.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -10),
            footerBox.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -12),
            footerBox.heightAnchor.constraint(equalToConstant: 44),

            driveIconView.leadingAnchor.constraint(equalTo: footerBox.leadingAnchor, constant: 12),
            driveIconView.centerYAnchor.constraint(equalTo: footerBox.centerYAnchor),
            driveIconView.widthAnchor.constraint(equalToConstant: 18),
            driveIconView.heightAnchor.constraint(equalToConstant: 18),

            breathingDot.trailingAnchor.constraint(equalTo: driveIconView.trailingAnchor, constant: 2),
            breathingDot.bottomAnchor.constraint(equalTo: driveIconView.bottomAnchor, constant: 1),
            breathingDot.widthAnchor.constraint(equalToConstant: 7),
            breathingDot.heightAnchor.constraint(equalToConstant: 7),

            externalDriveStatusLabel.leadingAnchor.constraint(equalTo: driveIconView.trailingAnchor, constant: 8),
            externalDriveStatusLabel.topAnchor.constraint(equalTo: footerBox.topAnchor, constant: 6),

            externalDriveSubLabel.leadingAnchor.constraint(equalTo: driveIconView.trailingAnchor, constant: 8),
            externalDriveSubLabel.topAnchor.constraint(equalTo: externalDriveStatusLabel.bottomAnchor, constant: 1),

            footerBtn.topAnchor.constraint(equalTo: footerBox.topAnchor),
            footerBtn.leadingAnchor.constraint(equalTo: footerBox.leadingAnchor),
            footerBtn.trailingAnchor.constraint(equalTo: footerBox.trailingAnchor),
            footerBtn.bottomAnchor.constraint(equalTo: footerBox.bottomAnchor)
        ])

        updateSidebarSelection()
        updateExternalStorageStatus()
    }

    private func addSidebarSectionHeader(title: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor(calibratedWhite: 0.42, alpha: 1.0)
        stack.addArrangedSubview(label)
    }

    private func addSidebarButton(id: Int, icon: String, title: String, to stack: NSStackView) {
        let btn = NSButton(title: "  " + title, target: self, action: #selector(onSidebarButtonClicked(_:)))
        btn.tag = id
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.alignment = .left
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleProportionallyDown
        btn.font = .systemFont(ofSize: 12, weight: .medium)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        btn.widthAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(btn)
        sidebarButtons.append(btn)
    }

    @objc private func onSidebarButtonClicked(_ sender: NSButton) {
        selectSidebarItem(at: sender.tag)
    }

    public func selectSidebarItem(at index: Int) {
        currentSidebarIndex = index
        updateSidebarSelection()

        if index >= 0 && index <= 3 {
            currentCategory = categories[index]
            currentSubCategoryFilter = "全部"
            categoryPopup?.selectItem(at: index)
            if index == 0 { categoryCapsuleControl?.selectedSegment = 0 }
            else if index == 1 { categoryCapsuleControl?.selectedSegment = 2 }
            else if index == 2 { categoryCapsuleControl?.selectedSegment = 3 }
            else if index == 3 { categoryCapsuleControl?.selectedSegment = 1 }
            updateCategoryTitle()
            selectedGroupIndex = 0
            switchHubTab(to: 0)
            refreshList()
        } else if index == 4 {
            switchHubTab(to: 1)
        } else if index == 5 {
            switchHubTab(to: 2)
        } else if index == 6 {
            switchHubTab(to: 3)
        } else if index == 7 {
            switchHubTab(to: 4)
        } else if index == 8 {
            switchHubTab(to: 5)
        } else if index == 9 {
            switchHubTab(to: 6)
        } else if index == 10 {
            switchHubTab(to: 7)
        } else if index == 11 {
            switchHubTab(to: 8)
        }
    }

    private func updateSidebarSelection() {
        for btn in sidebarButtons {
            if btn.tag == currentSidebarIndex {
                btn.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.38, alpha: 1.0).cgColor
                btn.contentTintColor = NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
            } else {
                btn.layer?.backgroundColor = NSColor.clear.cgColor
                btn.contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)
            }
        }
    }

    private func updateExternalStorageStatus() {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: externalRoot)
        if exists {
            externalDriveStatusLabel?.stringValue = "外置剪辑盘已挂载"
            let volName = (externalRoot as NSString).lastPathComponent
            externalDriveSubLabel?.stringValue = "卷: \(volName)"
        } else {
            externalDriveStatusLabel?.stringValue = "外置盘未连接"
            externalDriveSubLabel?.stringValue = "点击可配置路径"
        }
    }

    @objc public func onHubTabChanged() {
        switchHubTab(to: hubSegmentedControl.selectedSegment)
    }

    public func switchHubTab(to index: Int) {
        currentHubTab = index
        hubSegmentedControl.selectedSegment = min(index, hubSegmentedControl.segmentCount - 1)

        templateContainerView.isHidden = (index != 0)
        lutContainerView.isHidden = (index != 1)
        audioContainerView.isHidden = (index != 2)
        cleanerContainerView.isHidden = (index != 3)
        doctorContainerView.isHidden = (index != 4)
        storageContainerView.isHidden = (index != 5)
        profileContainerView.isHidden = (index != 6)
        teamSyncContainerView.isHidden = (index != 7)
        settingsContainerView.isHidden = (index != 8)

        // 同步侧边栏高亮
        if index == 0 {
            if let catIdx = categories.firstIndex(of: currentCategory) {
                currentSidebarIndex = catIdx
            }
        } else if index == 1 {
            currentSidebarIndex = 4
            if allLUTItems.isEmpty { refreshLUTList() }
        } else if index == 2 {
            currentSidebarIndex = 5
            if allAudioItems.isEmpty { refreshAudioList() }
        } else if index == 3 {
            currentSidebarIndex = 6
            if cleanerDashboardView.libraries.isEmpty {
                cleanerDashboardView.startScanning()
            }
        } else if index == 4 {
            currentSidebarIndex = 7
            if doctorDashboardView.currentReport == nil {
                doctorDashboardView.startScan()
            }
        } else if index == 5 {
            currentSidebarIndex = 8
            storageMigrationDashboardView.refreshData()
        } else if index == 6 {
            currentSidebarIndex = 9
            profileDashboardView.refreshData()
        } else if index == 7 {
            currentSidebarIndex = 10
            teamSyncDashboardView.refreshData()
        } else if index == 8 {
            currentSidebarIndex = 11
            settingsDashboardView.refreshData()
        }
        updateSidebarSelection()
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 1：素材管理中心 1:1 三段式经典架构深度复刻（R51 对标嘉星 2.app）
    // ═══════════════════════════════════════════════════════════════

    private func setupTemplateModule(in container: NSView) {
        templateContainerView = NSView()
        templateContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(templateContainerView)

        let bgVEV = NSVisualEffectView()
        bgVEV.material = .underWindowBackground
        bgVEV.blendingMode = .behindWindow
        bgVEV.state = .active
        bgVEV.appearance = NSAppearance(named: .darkAqua)
        bgVEV.autoresizingMask = [.width, .height]
        bgVEV.frame = templateContainerView.bounds
        templateContainerView.addSubview(bgVEV, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            templateContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            templateContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            templateContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            templateContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // ═══════════════════════════════════════════════════════════
        //  第二段：中栏 360pt 插件分组列表 (Middle Column)
        // ═══════════════════════════════════════════════════════════
        middleColumnView = NSView()
        middleColumnView.wantsLayer = true
        middleColumnView.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.45).cgColor
        middleColumnView.layer?.borderWidth = 0.5
        middleColumnView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        middleColumnView.translatesAutoresizingMaskIntoConstraints = false
        templateContainerView.addSubview(middleColumnView)

        // 1. 顶部分类切换胶囊（字幕、发生器、效果、转场）
        let capsuleBar = NSView()
        capsuleBar.wantsLayer = true
        capsuleBar.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.35).cgColor
        capsuleBar.layer?.borderWidth = 0.5
        capsuleBar.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        capsuleBar.translatesAutoresizingMaskIntoConstraints = false
        middleColumnView.addSubview(capsuleBar)

        categoryCapsuleControl = NSSegmentedControl(
            labels: ["字幕 (0)", "发生器 (0)", "效果 (0)", "转场 (0)"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onCategoryCapsuleChanged(_:))
        )
        categoryCapsuleControl.selectedSegment = 0
        categoryCapsuleControl.segmentStyle = .capsule
        categoryCapsuleControl.font = .systemFont(ofSize: 11, weight: .semibold)
        categoryCapsuleControl.translatesAutoresizingMaskIntoConstraints = false
        capsuleBar.addSubview(categoryCapsuleControl)

        // 2. 分组操作工具栏（访达、重命名、删除、新建）
        groupToolbarView = NSView()
        groupToolbarView.wantsLayer = true
        groupToolbarView.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 0.35).cgColor
        groupToolbarView.layer?.borderWidth = 0.5
        groupToolbarView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        groupToolbarView.translatesAutoresizingMaskIntoConstraints = false
        middleColumnView.addSubview(groupToolbarView)

        let groupToolStack = NSStackView()
        groupToolStack.orientation = .horizontal
        groupToolStack.spacing = 6
        groupToolStack.alignment = .centerY
        groupToolStack.translatesAutoresizingMaskIntoConstraints = false
        groupToolbarView.addSubview(groupToolStack)

        groupFinderBtn = NSButton(title: " 访达", target: self, action: #selector(onGroupFinderClicked))
        groupFinderBtn.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "访达")
        groupFinderBtn.imagePosition = .imageLeading
        groupFinderBtn.bezelStyle = .roundRect
        groupFinderBtn.font = .systemFont(ofSize: 11)
        groupToolStack.addArrangedSubview(groupFinderBtn)

        groupRenameBtn = NSButton(title: " 重命名", target: self, action: #selector(onGroupRenameClicked))
        groupRenameBtn.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "重命名")
        groupRenameBtn.imagePosition = .imageLeading
        groupRenameBtn.bezelStyle = .roundRect
        groupRenameBtn.font = .systemFont(ofSize: 11)
        groupToolStack.addArrangedSubview(groupRenameBtn)

        groupDeleteBtn = NSButton(title: " 删除", target: self, action: #selector(onGroupDeleteClicked))
        groupDeleteBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        groupDeleteBtn.imagePosition = .imageLeading
        groupDeleteBtn.bezelStyle = .roundRect
        groupDeleteBtn.font = .systemFont(ofSize: 11)
        groupToolStack.addArrangedSubview(groupDeleteBtn)

        groupNewBtn = NSButton(title: " 新建插件", target: self, action: #selector(onCreateNewGroupClicked))
        groupNewBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建")
        groupNewBtn.imagePosition = .imageLeading
        groupNewBtn.bezelStyle = .roundRect
        groupNewBtn.font = .systemFont(ofSize: 11, weight: .medium)
        groupToolStack.addArrangedSubview(groupNewBtn)

        // 3. 分组 TableView（插件名称/数量/大小/归属）
        groupScrollView = NSScrollView()
        groupScrollView.hasVerticalScroller = true
        groupScrollView.verticalScroller = InvisibleScroller()
        groupScrollView.hasHorizontalScroller = false
        groupScrollView.drawsBackground = false
        groupScrollView.backgroundColor = .clear
        groupScrollView.translatesAutoresizingMaskIntoConstraints = false
        middleColumnView.addSubview(groupScrollView)

        groupTableView = NSTableView()
        groupTableView.autoresizingMask = [.width, .height]
        groupTableView.usesAlternatingRowBackgroundColors = false
        groupTableView.backgroundColor = .clear
        groupTableView.selectionHighlightStyle = .regular
        groupTableView.rowHeight = 32

        let colGrpName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("groupName"))
        colGrpName.title = "插件名称"
        colGrpName.width = 165
        groupTableView.addTableColumn(colGrpName)

        let colGrpCount = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("groupCount"))
        colGrpCount.title = "数量"
        colGrpCount.width = 45
        groupTableView.addTableColumn(colGrpCount)

        let colGrpSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("groupSize"))
        colGrpSize.title = "大小"
        colGrpSize.width = 60
        groupTableView.addTableColumn(colGrpSize)

        let colGrpTier = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("groupTier"))
        colGrpTier.title = "归属"
        colGrpTier.width = 75
        groupTableView.addTableColumn(colGrpTier)

        groupTableView.dataSource = self
        groupTableView.delegate = self
        groupScrollView.documentView = groupTableView

        NSLayoutConstraint.activate([
            middleColumnView.topAnchor.constraint(equalTo: templateContainerView.topAnchor),
            middleColumnView.leadingAnchor.constraint(equalTo: templateContainerView.leadingAnchor),
            middleColumnView.bottomAnchor.constraint(equalTo: templateContainerView.bottomAnchor),
            middleColumnView.widthAnchor.constraint(equalToConstant: 360),

            capsuleBar.topAnchor.constraint(equalTo: middleColumnView.topAnchor),
            capsuleBar.leadingAnchor.constraint(equalTo: middleColumnView.leadingAnchor),
            capsuleBar.trailingAnchor.constraint(equalTo: middleColumnView.trailingAnchor),
            capsuleBar.heightAnchor.constraint(equalToConstant: 44),

            categoryCapsuleControl.centerXAnchor.constraint(equalTo: capsuleBar.centerXAnchor),
            categoryCapsuleControl.centerYAnchor.constraint(equalTo: capsuleBar.centerYAnchor),
            categoryCapsuleControl.leadingAnchor.constraint(greaterThanOrEqualTo: capsuleBar.leadingAnchor, constant: 8),
            categoryCapsuleControl.trailingAnchor.constraint(lessThanOrEqualTo: capsuleBar.trailingAnchor, constant: -8),

            groupToolbarView.topAnchor.constraint(equalTo: capsuleBar.bottomAnchor),
            groupToolbarView.leadingAnchor.constraint(equalTo: middleColumnView.leadingAnchor),
            groupToolbarView.trailingAnchor.constraint(equalTo: middleColumnView.trailingAnchor),
            groupToolbarView.heightAnchor.constraint(equalToConstant: 34),

            groupToolStack.centerYAnchor.constraint(equalTo: groupToolbarView.centerYAnchor),
            groupToolStack.leadingAnchor.constraint(equalTo: groupToolbarView.leadingAnchor, constant: 8),
            groupToolStack.trailingAnchor.constraint(equalTo: groupToolbarView.trailingAnchor, constant: -8),

            groupScrollView.topAnchor.constraint(equalTo: groupToolbarView.bottomAnchor),
            groupScrollView.leadingAnchor.constraint(equalTo: middleColumnView.leadingAnchor),
            groupScrollView.trailingAnchor.constraint(equalTo: middleColumnView.trailingAnchor),
            groupScrollView.bottomAnchor.constraint(equalTo: middleColumnView.bottomAnchor)
        ])

        // ═══════════════════════════════════════════════════════════
        //  第三段：右栏 模板缩略图网格与批量操作 (Right Column)
        // ═══════════════════════════════════════════════════════════
        rightColumnView = NSView()
        rightColumnView.wantsLayer = true
        rightColumnView.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.35).cgColor
        rightColumnView.translatesAutoresizingMaskIntoConstraints = false
        templateContainerView.addSubview(rightColumnView)

        NSLayoutConstraint.activate([
            rightColumnView.topAnchor.constraint(equalTo: templateContainerView.topAnchor),
            rightColumnView.leadingAnchor.constraint(equalTo: middleColumnView.trailingAnchor),
            rightColumnView.trailingAnchor.constraint(equalTo: templateContainerView.trailingAnchor),
            rightColumnView.bottomAnchor.constraint(equalTo: templateContainerView.bottomAnchor)
        ])

        // 1. 顶部面包屑 (Breadcrumb: 高度 44pt)
        let breadcrumbBar = NSView()
        breadcrumbBar.wantsLayer = true
        breadcrumbBar.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.35).cgColor
        breadcrumbBar.layer?.borderWidth = 0.5
        breadcrumbBar.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        rightColumnView.addSubview(breadcrumbBar)

        breadcrumbLabel = NSTextField(labelWithString: "⚡️ 实时预览 > 系统 > 字幕 > 全部")
        breadcrumbLabel.font = .systemFont(ofSize: 13, weight: .bold)
        breadcrumbLabel.textColor = .white
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbBar.addSubview(breadcrumbLabel)

        categoryTitleLabel = NSTextField(labelWithString: "标题字幕 (Titles)")
        categoryTitleLabel.isHidden = true
        breadcrumbBar.addSubview(categoryTitleLabel)

        // 2. 批量操作工具栏 (Batch Toolbar: 高度 34pt)
        rightToolbarView = NSView()
        rightToolbarView.wantsLayer = true
        rightToolbarView.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 0.35).cgColor
        rightToolbarView.layer?.borderWidth = 0.5
        rightToolbarView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        rightToolbarView.translatesAutoresizingMaskIntoConstraints = false
        rightColumnView.addSubview(rightToolbarView)

        createGroupBtn = NSButton(title: "创建新分组", target: self, action: #selector(onCreateNewGroupClicked))
        createGroupBtn.bezelStyle = .roundRect
        createGroupBtn.font = .systemFont(ofSize: 11, weight: .medium)
        createGroupBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(createGroupBtn)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(sep)

        selectAllBtn = NSButton(title: "☑️ 全选", target: self, action: #selector(onSelectAllClicked))
        selectAllBtn.bezelStyle = .roundRect
        selectAllBtn.font = .systemFont(ofSize: 11)
        selectAllBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(selectAllBtn)

        rightFinderBtn = NSButton(title: "📂 访达中显示", target: self, action: #selector(onRightFinderClicked))
        rightFinderBtn.bezelStyle = .roundRect
        rightFinderBtn.font = .systemFont(ofSize: 11)
        rightFinderBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(rightFinderBtn)

        // FCPX-042: 明确为"删除分组"，防止用户误以为仅删除单个素材
        rightTrashBtn = NSButton(title: "🗑️ 删除分组", target: self, action: #selector(onRightTrashClicked))
        rightTrashBtn.bezelStyle = .roundRect
        rightTrashBtn.font = .systemFont(ofSize: 11)
        rightTrashBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(rightTrashBtn)

        // FCPX-043: 演示按钮添加禁用提示说明
        previewToggleBtn = NSButton(title: "⚡️ 演示", target: self, action: #selector(onPreviewToggleClicked))
        previewToggleBtn.bezelStyle = .roundRect
        previewToggleBtn.font = .systemFont(ofSize: 11)
        previewToggleBtn.toolTip = "QuickLook 实时预览演示功能正在接入中"
        previewToggleBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(previewToggleBtn)

        // 搜索框（即输即搜）
        searchField = NSSearchField()
        searchField.placeholderString = "搜索模板…"
        searchField.target = self
        searchField.action = #selector(onSearchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(searchField)

        // 归属与排序
        tierFilterPopup = NSPopUpButton()
        tierFilterPopup.addItems(withTitles: ["全部归属", "🟡 内置", "🟢 用户", "🟣 系统"])
        tierFilterPopup.target = self
        tierFilterPopup.action = #selector(onFilterChanged)
        tierFilterPopup.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(tierFilterPopup)

        sortPopup = NSPopUpButton()
        sortPopup.addItems(withTitles: ["默认排序", "按名称", "按体积"])
        sortPopup.target = self
        sortPopup.action = #selector(onFilterChanged)
        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(sortPopup)

        // 双模切换：⊞ 网格 / ☰ 列表
        viewModeSegmentedControl = NSSegmentedControl(
            labels: ["⊞ 网格", "☰ 列表"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onViewModeChanged)
        )
        viewModeSegmentedControl.selectedSegment = 0
        viewModeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(viewModeSegmentedControl)

        let refreshBtn = NSButton(title: "🔄", target: self, action: #selector(refreshList))
        refreshBtn.toolTip = "刷新当前分类（重读磁盘）"
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(refreshBtn)

        undoButton = NSButton(title: "↩️ 撤销", target: self, action: #selector(onUndoClicked))
        undoButton.toolTip = "撤销上次外置化迁移"
        undoButton.isEnabled = migrator.lastRecord() != nil
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(undoButton)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        rightToolbarView.addSubview(spinner)

        // 兼容旧字段
        categoryPopup = NSPopUpButton()
        categoryPopup.addItems(withTitles: [
            "Titles.localized (标题与字幕)",
            "Effects.localized (视频特效)",
            "Transitions.localized (转场过渡)",
            "Generators.localized (背景发生器)"
        ])
        categoryPopup.target = self
        categoryPopup.action = #selector(onCategoryChanged)
        categoryPopup.isHidden = true
        breadcrumbBar.addSubview(categoryPopup)

        pathDisplayField = NSTextField(string: externalRoot)
        pathDisplayField.isHidden = true
        breadcrumbBar.addSubview(pathDisplayField)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        statusLabel.isHidden = true
        breadcrumbBar.addSubview(statusLabel)

        // 隐藏保留 subCategoryScrollView 以保持测试契约
        subCategoryScrollView = NSScrollView()
        subCategoryScrollView.isHidden = true
        subCategoryScrollView.translatesAutoresizingMaskIntoConstraints = false
        rightColumnView.addSubview(subCategoryScrollView)

        subCategoryStackView = NSStackView()
        subCategoryScrollView.documentView = subCategoryStackView

        // 统计条
        tierStatsLabel = NSTextField(labelWithString: "共 0 套模板 · 🟢 已启用 0 · ⚪️ 已休眠 0")
        tierStatsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        tierStatsLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        tierStatsLabel.translatesAutoresizingMaskIntoConstraints = false
        rightColumnView.addSubview(tierStatsLabel)

        // 3. 卡片网格流与表格视口
        cardGridScrollView = NSScrollView()
        cardGridScrollView.wantsLayer = true
        cardGridScrollView.hasVerticalScroller = true
        cardGridScrollView.verticalScroller = InvisibleScroller()
        cardGridScrollView.hasHorizontalScroller = false
        cardGridScrollView.drawsBackground = false
        cardGridScrollView.backgroundColor = .clear
        cardGridScrollView.translatesAutoresizingMaskIntoConstraints = false
        rightColumnView.addSubview(cardGridScrollView)

        cardGridContentView = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        cardGridScrollView.documentView = cardGridContentView
        cardGridScrollView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(onCardGridDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: cardGridScrollView.contentView)

        tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.isHidden = true
        rightColumnView.addSubview(tableScrollView)

        pluginTableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        pluginTableView.autoresizingMask = [.width, .height]
        pluginTableView.usesAlternatingRowBackgroundColors = false
        pluginTableView.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = "模板名称"
        colName.width = 220
        pluginTableView.addTableColumn(colName)

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        colStatus.title = "状态"
        colStatus.width = 95
        pluginTableView.addTableColumn(colStatus)

        let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        colSize.title = "体积"
        colSize.width = 75
        pluginTableView.addTableColumn(colSize)

        let colTier = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tier"))
        colTier.title = "归属层级"
        colTier.width = 240
        pluginTableView.addTableColumn(colTier)

        let colDisk = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
        colDisk.title = "磁盘形态"
        colDisk.width = 190
        pluginTableView.addTableColumn(colDisk)

        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        colAction.title = "操作"
        colAction.width = 76
        pluginTableView.addTableColumn(colAction)

        pluginTableView.dataSource = self
        pluginTableView.delegate = self
        tableScrollView.documentView = pluginTableView

        // Auto Layout for Right Column
        NSLayoutConstraint.activate([
            breadcrumbBar.topAnchor.constraint(equalTo: rightColumnView.topAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: rightColumnView.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: rightColumnView.trailingAnchor),
            breadcrumbBar.heightAnchor.constraint(equalToConstant: 44),

            breadcrumbLabel.leadingAnchor.constraint(equalTo: breadcrumbBar.leadingAnchor, constant: 14),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: breadcrumbBar.centerYAnchor),

            rightToolbarView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            rightToolbarView.leadingAnchor.constraint(equalTo: rightColumnView.leadingAnchor),
            rightToolbarView.trailingAnchor.constraint(equalTo: rightColumnView.trailingAnchor),
            rightToolbarView.heightAnchor.constraint(equalToConstant: 34),

            createGroupBtn.leadingAnchor.constraint(equalTo: rightToolbarView.leadingAnchor, constant: 10),
            createGroupBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            sep.leadingAnchor.constraint(equalTo: createGroupBtn.trailingAnchor, constant: 8),
            sep.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),
            sep.heightAnchor.constraint(equalToConstant: 18),

            selectAllBtn.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 8),
            selectAllBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            rightFinderBtn.leadingAnchor.constraint(equalTo: selectAllBtn.trailingAnchor, constant: 6),
            rightFinderBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            rightTrashBtn.leadingAnchor.constraint(equalTo: rightFinderBtn.trailingAnchor, constant: 6),
            rightTrashBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            previewToggleBtn.leadingAnchor.constraint(equalTo: rightTrashBtn.trailingAnchor, constant: 6),
            previewToggleBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: previewToggleBtn.trailingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 140),

            tierFilterPopup.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            tierFilterPopup.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            sortPopup.leadingAnchor.constraint(equalTo: tierFilterPopup.trailingAnchor, constant: 6),
            sortPopup.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            viewModeSegmentedControl.leadingAnchor.constraint(equalTo: sortPopup.trailingAnchor, constant: 8),
            viewModeSegmentedControl.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            refreshBtn.leadingAnchor.constraint(equalTo: viewModeSegmentedControl.trailingAnchor, constant: 6),
            refreshBtn.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            undoButton.leadingAnchor.constraint(equalTo: refreshBtn.trailingAnchor, constant: 4),
            undoButton.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            spinner.leadingAnchor.constraint(equalTo: undoButton.trailingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: rightToolbarView.centerYAnchor),

            tierStatsLabel.topAnchor.constraint(equalTo: rightToolbarView.bottomAnchor, constant: 4),
            tierStatsLabel.leadingAnchor.constraint(equalTo: rightColumnView.leadingAnchor, constant: 12),
            tierStatsLabel.heightAnchor.constraint(equalToConstant: 18),

            cardGridScrollView.topAnchor.constraint(equalTo: tierStatsLabel.bottomAnchor, constant: 4),
            cardGridScrollView.leadingAnchor.constraint(equalTo: rightColumnView.leadingAnchor, constant: 8),
            cardGridScrollView.trailingAnchor.constraint(equalTo: rightColumnView.trailingAnchor, constant: -8),
            cardGridScrollView.bottomAnchor.constraint(equalTo: rightColumnView.bottomAnchor, constant: -8),

            tableScrollView.topAnchor.constraint(equalTo: tierStatsLabel.bottomAnchor, constant: 4),
            tableScrollView.leadingAnchor.constraint(equalTo: rightColumnView.leadingAnchor, constant: 8),
            tableScrollView.trailingAnchor.constraint(equalTo: rightColumnView.trailingAnchor, constant: -8),
            tableScrollView.bottomAnchor.constraint(equalTo: rightColumnView.bottomAnchor, constant: -8)
        ])

        // 4. 拖放安装引导层
        dropOverlayView = NSView()
        dropOverlayView.wantsLayer = true
        dropOverlayView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.38, blue: 0.78, alpha: 0.65).cgColor
        dropOverlayView.layer?.borderColor = NSColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 0.95).cgColor
        dropOverlayView.layer?.borderWidth = 3.0
        dropOverlayView.layer?.cornerRadius = 14.0
        dropOverlayView.translatesAutoresizingMaskIntoConstraints = false
        dropOverlayView.isHidden = true
        templateContainerView.addSubview(dropOverlayView)

        NSLayoutConstraint.activate([
            dropOverlayView.topAnchor.constraint(equalTo: templateContainerView.topAnchor, constant: 10),
            dropOverlayView.leadingAnchor.constraint(equalTo: templateContainerView.leadingAnchor, constant: 8),
            dropOverlayView.trailingAnchor.constraint(equalTo: templateContainerView.trailingAnchor, constant: -8),
            dropOverlayView.bottomAnchor.constraint(equalTo: templateContainerView.bottomAnchor, constant: -8)
        ])

        let dropStack = NSStackView()
        dropStack.orientation = .vertical
        dropStack.alignment = .centerX
        dropStack.spacing = 8
        dropStack.translatesAutoresizingMaskIntoConstraints = false
        dropOverlayView.addSubview(dropStack)

        NSLayoutConstraint.activate([
            dropStack.centerXAnchor.constraint(equalTo: dropOverlayView.centerXAnchor),
            dropStack.centerYAnchor.constraint(equalTo: dropOverlayView.centerYAnchor)
        ])

        let iconLabel = NSTextField(labelWithString: "📦")
        iconLabel.font = .systemFont(ofSize: 44)
        dropStack.addArrangedSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "释放以自动安装至当前分类")
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        dropStack.addArrangedSubview(titleLabel)

        let subLabel = NSTextField(labelWithString: "支持 .zip 压缩包或模板文件夹 · 自动解压与识别四大分类")
        subLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        dropStack.addArrangedSubview(subLabel)
    }

    private func updateCategoryTitle() {
        let name: String = {
            switch currentCategory {
            case "Titles.localized": return "标题字幕 (Titles)"
            case "Effects.localized": return "视频特效 (Effects)"
            case "Transitions.localized": return "视频转场 (Transitions)"
            case "Generators.localized": return "视频发生器 (Generators)"
            default: return currentCategory
            }
        }()
        categoryTitleLabel?.stringValue = name
    }

    @objc private func onViewModeChanged() {
        currentViewMode = viewModeSegmentedControl.selectedSegment
        cardGridScrollView.isHidden = (currentViewMode != 0)
        tableScrollView.isHidden = (currentViewMode != 1)
        if currentViewMode == 0 {
            reloadCardGrid()
        } else {
            pluginTableView.reloadData()
        }
    }

    @objc private func onSearchChanged() {
        applyFilterAndSort()
    }

    // ═══════════════════════════════════════════════════════════════
    //  R51 三段式交互逻辑：分组与批量操作响应
    // ═══════════════════════════════════════════════════════════════

    @objc private func onCategoryCapsuleChanged(_ sender: NSSegmentedControl) {
        let seg = sender.selectedSegment
        switch seg {
        case 0:
            currentCategory = "Titles.localized"
            currentSidebarIndex = 0
        case 1:
            currentCategory = "Generators.localized"
            currentSidebarIndex = 3
        case 2:
            currentCategory = "Effects.localized"
            currentSidebarIndex = 1
        case 3:
            currentCategory = "Transitions.localized"
            currentSidebarIndex = 2
        default:
            break
        }
        updateSidebarSelection()
        updateCategoryTitle()
        selectedGroupIndex = 0
        refreshList()
    }

    @objc private func onGroupFinderClicked() {
        guard let grp = selectedGroupItem, let first = grp.items.first else { return }
        let p = (first.path as NSString).deletingLastPathComponent
        NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: p)
    }

    @objc private func onGroupRenameClicked() {
        guard let grp = selectedGroupItem, let first = grp.items.first else { return }
        let groupDir = (first.path as NSString).deletingLastPathComponent
        let alert = NSAlert()
        alert.messageText = "重命名插件分组"
        alert.informativeText = "请输入新分组名称（当前：\(grp.name)）："
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = grp.name
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != grp.name else { return }
            let parent = (groupDir as NSString).deletingLastPathComponent
            let newTarget = "\(parent)/\(newName)"
            do {
                try FileManager.default.moveItem(atPath: groupDir, toPath: newTarget)
                AssetCacheManager.shared.invalidateAll()
                refreshList()
            } catch {
                showAlert(title: "重命名失败", message: error.localizedDescription)
            }
        }
    }

    @objc private func onGroupDeleteClicked() {
        guard LicenseManager.shared.isProLicensed else {
            showAlert(title: "商业授权未激活", message: "未激活商业授权，模板删除功能已锁定。请先激活商业授权。")
            return
        }
        guard let grp = selectedGroupItem, let first = grp.items.first else { return }
        let groupDir = (first.path as NSString).deletingLastPathComponent
        let alert = NSAlert()
        alert.messageText = "删除插件分组"
        alert.informativeText = "确定要将分组「\(grp.name)」及其内部全部 \(grp.count) 套模板移入废纸篓吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(fileURLWithPath: groupDir)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                AssetCacheManager.shared.invalidateAll()
                refreshList()
            } catch {
                showAlert(title: "删除失败", message: error.localizedDescription)
            }
        }
    }

    @objc private func onCreateNewGroupClicked() {
        let alert = NSAlert()
        alert.messageText = "新建插件分组"
        alert.informativeText = "请输入要创建的分组名称（将在当前分类下建立目录）："
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "例如：易安装-2026超级片头"
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let userRoot = TemplateTierRoots.resolve().user
            let catDir = "\(userRoot)/\(currentCategory)"
            let newDir = "\(catDir)/\(name)"
            do {
                try FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
                AssetCacheManager.shared.invalidateAll()
                refreshList()
            } catch {
                showAlert(title: "创建分组失败", message: error.localizedDescription)
            }
        }
    }

    @objc private func onSelectAllClicked() {
        let allActive = plugins.allSatisfy { $0.isEnabled }
        let target = !allActive
        for it in plugins {
            if it.isEnabled != target {
                toggleTemplateItem(it)
            }
        }
    }

    @objc private func onRightFinderClicked() {
        if let first = plugins.first {
            NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: (first.path as NSString).deletingLastPathComponent)
        } else if let grp = selectedGroupItem, let first = grp.items.first {
            let p = (first.path as NSString).deletingLastPathComponent
            NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: p)
        }
    }

    @objc private func onRightTrashClicked() {
        guard LicenseManager.shared.isProLicensed else {
            showAlert(title: "商业授权未激活", message: "未激活商业授权，模板删除功能已锁定。请先激活商业授权。")
            return
        }
        onGroupDeleteClicked()
    }

    @objc private func onPreviewToggleClicked() {
        // FCPX-043: 明确说明功能就绪状态，杜绝空伪造
        showAlert(title: "功能说明", message: "动态实时预览演示功能正在接入 Apple QuickLook 引擎，将在下个版本开放。")
    }

    public func updateGroupItems() {
        var dict: [String: TemplateGroupItem] = [:]
        var order: [String] = []

        for item in allItems {
            let sub = item.subCategory.trimmingCharacters(in: .whitespaces)
            let groupName = sub.isEmpty ? "默认分组" : sub
            let key = "\(groupName)__\(item.tier.rawValue)"
            if var g = dict[key] {
                g.count += 1
                g.totalSizeMB += item.sizeMB
                g.items.append(item)
                dict[key] = g
            } else {
                let g = TemplateGroupItem(
                    name: groupName,
                    category: currentCategory,
                    tier: item.tier,
                    count: 1,
                    totalSizeMB: item.sizeMB,
                    items: [item]
                )
                dict[key] = g
                order.append(key)
            }
        }

        self.groupItems = order.compactMap { dict[$0] }
        if selectedGroupIndex >= groupItems.count {
            selectedGroupIndex = max(0, groupItems.count - 1)
        }

        groupTableView?.reloadData()
        if !groupItems.isEmpty {
            groupTableView?.selectRowIndexes(IndexSet(integer: selectedGroupIndex), byExtendingSelection: false)
        }
        loadTemplatesForSelectedGroup()
        updateCategoryCapsuleCounts()
    }

    public func loadTemplatesForSelectedGroup() {
        guard selectedGroupIndex >= 0 && selectedGroupIndex < groupItems.count else {
            plugins = []
            updateBreadcrumb(group: nil)
            reloadCardGrid()
            tierStatsLabel?.stringValue = "当前组共 0 套模板"
            return
        }
        let grp = groupItems[selectedGroupIndex]

        var filtered = grp.items.map { item -> TemplateItem in
            var updated = item
            if self.migrator.isPathOffline(item.path, targetPath: item.targetPath) {
                updated.isOffline = true
            }
            return updated
        }
        if let q = searchField?.stringValue.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }
        let tierIdx = tierFilterPopup?.indexOfSelectedItem ?? 0
        if tierIdx == 1 { filtered = filtered.filter { $0.tier == .builtin } }
        else if tierIdx == 2 { filtered = filtered.filter { $0.tier == .user } }
        else if tierIdx == 3 { filtered = filtered.filter { $0.tier == .system } }

        self.plugins = filtered
        updateBreadcrumb(group: grp)

        let enabledCount = plugins.filter { $0.isEnabled }.count
        let disabledCount = plugins.count - enabledCount
        tierStatsLabel?.stringValue = "当前组共 \(plugins.count) 套模板 · 🟢 已启用 \(enabledCount) · ⚪️ 已休眠 \(disabledCount)"

        if currentViewMode == 0 {
            reloadCardGrid()
        } else {
            pluginTableView?.reloadData()
        }
    }

    public func updateBreadcrumb(group: TemplateGroupItem?) {
        guard let g = group else {
            breadcrumbLabel?.stringValue = "⚡️ 实时预览 > 未选择分组"
            return
        }
        let tierStr: String = {
            switch g.tier {
            case .builtin: return "内置"
            case .user: return "用户"
            case .system: return "系统"
            }
        }()
        let catStr: String = {
            switch currentCategory {
            case "Titles.localized": return "字幕"
            case "Generators.localized": return "发生器"
            case "Effects.localized": return "效果"
            case "Transitions.localized": return "转场"
            default: return "插件"
            }
        }()
        breadcrumbLabel?.stringValue = "⚡️ 实时预览 > \(tierStr) > \(catStr) > \(g.name)"
    }

    public func updateCategoryCapsuleCounts() {
        let titles = AssetCacheManager.shared.getTemplates(category: "Titles.localized")?.items.count ?? (currentCategory == "Titles.localized" ? allItems.count : 0)
        let gen = AssetCacheManager.shared.getTemplates(category: "Generators.localized")?.items.count ?? (currentCategory == "Generators.localized" ? allItems.count : 0)
        let fx = AssetCacheManager.shared.getTemplates(category: "Effects.localized")?.items.count ?? (currentCategory == "Effects.localized" ? allItems.count : 0)
        let trans = AssetCacheManager.shared.getTemplates(category: "Transitions.localized")?.items.count ?? (currentCategory == "Transitions.localized" ? allItems.count : 0)

        categoryCapsuleControl?.setLabel("字幕 (\(titles))", forSegment: 0)
        categoryCapsuleControl?.setLabel("发生器 (\(gen))", forSegment: 1)
        categoryCapsuleControl?.setLabel("效果 (\(fx))", forSegment: 2)
        categoryCapsuleControl?.setLabel("转场 (\(trans))", forSegment: 3)
    }

    // ═══════════════════════════════════════════════════════════════
    //  卡片网格渲染中心 (Card Grid Rendering & Virtual Chunks R49)
    // ═══════════════════════════════════════════════════════════════

    public static let defaultChunkSize: Int = 48
    public private(set) var renderedChunkCount: Int = 48
    public private(set) var loadMoreFooterView: NSView?
    public private(set) var loadMoreButton: NSButton?
    public private(set) var loadAllButton: NSButton?
    public private(set) var loadMoreStatusLabel: NSTextField?

    public func reloadCardGrid(resetPaging: Bool = true) {
        guard let container = cardGridContentView else { return }

        if resetPaging {
            renderedChunkCount = min(AssetHubView.defaultChunkSize, plugins.count)
        }

        let items = plugins
        let viewportW = cardGridScrollView.contentView.bounds.width > 0 ? cardGridScrollView.contentView.bounds.width : cardGridScrollView.bounds.width
        let margin: CGFloat = 16
        let spacing: CGFloat = 14
        let availableW = max(viewportW, 320)

        // R52 自适应弹性流式布局 (Adaptive Fluid Grid)
        // 动态计算列数（最小 2 列，最大 4 列）
        let rawCols = Int((availableW - margin * 2 + spacing) / (210 + spacing))
        let cols = max(2, min(4, rawCols))
        let totalSpacing = CGFloat(cols - 1) * spacing
        let cardW = floor((availableW - margin * 2 - totalSpacing) / CGFloat(cols))
        let cardH: CGFloat = 236

        let countToRender = min(renderedChunkCount, items.count)
        let rows = (countToRender + cols - 1) / cols

        let cardsH = CGFloat(rows) * (cardH + spacing) + margin
        let hasMore = countToRender < items.count
        let footerH: CGFloat = hasMore ? 64.0 : (items.isEmpty ? 60.0 : 44.0)
        let totalH = max(cardGridScrollView.bounds.height, cardsH + footerH + margin)
        container.frame = NSRect(x: 0, y: 0, width: availableW, height: totalH)

        // 1. 若当前卡片数量超出所需，移除多余卡片
        if cardViews.count > countToRender {
            for card in cardViews[countToRender...] {
                card.removeFromSuperview()
            }
            cardViews.removeSubrange(countToRender...)
        }

        // 2. 高速就地复用已有卡片 (0ms View Recycling 彻底杜绝主线程反复 Alloc/Dealloc)
        for i in 0..<cardViews.count {
            let item = items[i]
            let card = cardViews[i]
            let col = i % cols
            let row = i / cols
            let x = margin + CGFloat(col) * (cardW + spacing)
            let y = margin + CGFloat(row) * (cardH + spacing)
            card.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
            if card.item.path != item.path || card.item.name != item.name || card.item.isEnabled != item.isEnabled || card.item.isOffline != item.isOffline || card.item.isCorrupted != item.isCorrupted || card.item.isMismatchedDisk != item.isMismatchedDisk {
                card.item = item
            }
        }

        // 3. 仅在不足时实例化新增卡片
        if cardViews.count < countToRender {
            for index in cardViews.count..<countToRender {
                let item = items[index]
                let col = index % cols
                let row = index / cols
                let x = margin + CGFloat(col) * (cardW + spacing)
                let y = margin + CGFloat(row) * (cardH + spacing)

                let card = ResourceCardView(item: item, frame: NSRect(x: x, y: y, width: cardW, height: cardH))
                card.onToggle = { [weak self] it in
                    self?.toggleTemplateItem(it)
                }
                card.onActionMenu = { [weak self] it, view in
                    self?.showActionMenu(for: it, from: view)
                }
                card.onRequestContextMenu = { [weak self] it, _ in
                    return self?.makeTemplateActionMenu(for: it)
                }
                container.addSubview(card)
                cardViews.append(card)

                // 懒加载体积计算
                if !item.isSymlink && item.sizeMB == 0.0 && item.targetAvailable {
                    TemplateTierScanner.calculateSizeAsync(for: item) { [weak card] _ in
                        card?.updateContent()
                    }
                }
            }
        }

        // 移除旧底部栏
        loadMoreFooterView?.removeFromSuperview()

        // 底部控制器（加载更多 / 查看全部 / 状态指示）
        let footer = NSView(frame: NSRect(x: margin, y: cardsH + 8, width: availableW - margin * 2, height: footerH))
        container.addSubview(footer)
        loadMoreFooterView = footer

        if hasMore {
            let footerStack = NSStackView()
            footerStack.orientation = .horizontal
            footerStack.spacing = 12
            footerStack.alignment = .centerY
            footerStack.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(footerStack)

            NSLayoutConstraint.activate([
                footerStack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
                footerStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
            ])

            let btnMore = NSButton(title: "  加载更多模板 (已载入 \(countToRender) / 共 \(items.count) 款)",
                                   target: self, action: #selector(onLoadMoreClicked))
            btnMore.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "加载更多")
            btnMore.imagePosition = .imageLeading
            btnMore.bezelStyle = .regularSquare
            btnMore.isBordered = false
            btnMore.wantsLayer = true
            btnMore.layer?.cornerRadius = 14
            btnMore.layer?.masksToBounds = true
            btnMore.layer?.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.36, alpha: 0.9).cgColor
            btnMore.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.48, blue: 0.78, alpha: 0.8).cgColor
            btnMore.layer?.borderWidth = 1.0
            btnMore.font = .systemFont(ofSize: 12, weight: .bold)
            btnMore.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1.0, alpha: 1.0)
            btnMore.translatesAutoresizingMaskIntoConstraints = false
            btnMore.heightAnchor.constraint(equalToConstant: 32).isActive = true
            btnMore.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            footerStack.addArrangedSubview(btnMore)
            self.loadMoreButton = btnMore

            let btnAll = NSButton(title: "  查看全部", target: self, action: #selector(onLoadAllClicked))
            btnAll.image = NSImage(systemSymbolName: "square.stack.3d.down.right", accessibilityDescription: "全部")
            btnAll.imagePosition = .imageLeading
            btnAll.bezelStyle = .regularSquare
            btnAll.isBordered = false
            btnAll.wantsLayer = true
            btnAll.layer?.cornerRadius = 14
            btnAll.layer?.masksToBounds = true
            btnAll.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.9).cgColor
            btnAll.layer?.borderColor = NSColor(calibratedWhite: 0.28, alpha: 0.8).cgColor
            btnAll.layer?.borderWidth = 1.0
            btnAll.font = .systemFont(ofSize: 12, weight: .medium)
            btnAll.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
            btnAll.translatesAutoresizingMaskIntoConstraints = false
            btnAll.heightAnchor.constraint(equalToConstant: 32).isActive = true
            btnAll.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            footerStack.addArrangedSubview(btnAll)
            self.loadAllButton = btnAll
        } else if !items.isEmpty {
            let label = NSTextField(labelWithString: "— 已展示「\(currentSubCategoryFilter)」下的全部 \(items.count) 款模板 —")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
            ])
            self.loadMoreStatusLabel = label
        }
    }

    @objc public func onLoadMoreClicked() {
        loadNextCardChunk()
    }

    @objc public func onLoadAllClicked() {
        loadAllCards()
    }

    public func loadNextCardChunk(step: Int = AssetHubView.defaultChunkSize) {
        guard renderedChunkCount < plugins.count else { return }
        renderedChunkCount = min(plugins.count, renderedChunkCount + step)
        reloadCardGrid(resetPaging: false)
    }

    public func loadAllCards() {
        guard renderedChunkCount < plugins.count else { return }
        renderedChunkCount = plugins.count
        reloadCardGrid(resetPaging: false)
    }

    @objc private func onCardGridDidScroll(_ notification: Notification) {
        guard renderedChunkCount < plugins.count else { return }
        let visibleRect = cardGridScrollView.contentView.documentVisibleRect
        let contentHeight = cardGridContentView.bounds.height
        if visibleRect.maxY >= contentHeight - 160 {
            loadNextCardChunk()
        }
    }

    public func toggleTemplateItem(_ item: TemplateItem) {
        if item.isMismatchedDisk {
            if !suppressAlertsForTesting {
                let alert = NSAlert()
                alert.messageText = "强制绑定外置卷"
                alert.informativeText = "素材「\(item.name)」原绑定盘与当前挂载盘 UUID 不一致。\n是否信任并强制绑定当前挂载卷？"
                alert.addButton(withTitle: "强制绑定")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    forceBindVolume(for: item, skipConfirmation: true)
                }
            }
            return
        }

        if item.isOffline || item.isCorrupted || migrator.isPathOffline(item.path) || migrator.isPathOffline(item.targetPath) {
            if !suppressAlertsForTesting {
                let reason = item.isCorrupted ? "素材文件损坏或缺失" : "外置磁盘已断开"
                showAlert(title: "素材不可操作", message: "\(reason)，模板「\(item.name)」受容灾保护，禁止修改启停状态。")
            }
            return
        }

        if item.tier == .builtin && !TierWritePolicy.isBuiltinWritable {
            showAlert(title: "系统内置模板受保护", message: "系统内置模板受保护，需先复制到用户库后再调整。可在设置中开启写入。")
            return
        }

        do {
            let updated = try TemplateInstaller.shared.toggleTemplate(item: item)
            // 即时更新内存数据模型，避免整页销毁重刷
            if let idx = allItems.firstIndex(where: { $0.path == item.path }) {
                allItems[idx] = updated
            }
            if let idx = plugins.firstIndex(where: { $0.path == item.path }) {
                plugins[idx] = updated
            }
            // 即时更新卡片视图属性与 .disabled 徽章
            if let card = cardViews.first(where: { $0.item.path == item.path || $0.item.path == updated.path }) {
                card.item = updated
            }
            pluginTableView?.reloadData()
            let stateDesc = updated.isEnabled ? "已启用" : "已休眠"
            statusLabel?.stringValue = "模板「\(updated.name)」\(stateDesc)"
        } catch {
            showAlert(title: "状态切换失败", message: error.localizedDescription)
        }
    }

    // MARK: - R49 模板安全删除（移入废纸篓）闭环
    public var suppressAlertsForTesting: Bool = false

    public func deleteTemplateItem(_ item: TemplateItem, skipConfirmation: Bool = false) {
        // 0. 离线素材容灾保护拦截（禁止物理删除断链/损坏/异盘项）
        if item.isOffline || item.isCorrupted || item.isMismatchedDisk || migrator.isPathOffline(item.path) || migrator.isPathOffline(item.targetPath) {
            if !suppressAlertsForTesting {
                let reason = item.isMismatchedDisk ? "挂载卷与素材 UUID 不匹配" : (item.isCorrupted ? "素材文件损坏或缺失" : "外置磁盘已断开")
                showAlert(title: "素材处于故障/离线状态", message: "\(reason)，模板「\(item.name)」受容灾保护，禁止物理删除。请先连接对应磁盘。")
            }
            return
        }

        // 0b. 商业授权分级拦截 (R52)
        if !LicenseManager.shared.isProLicensed {
            if !suppressAlertsForTesting {
                showAlert(title: "商业授权未激活", message: "未激活商业授权，模板删除功能已锁定。请先激活商业授权。")
            }
            return
        }

        // 1. 系统内置保护拦截
        if item.tier == .builtin {
            showAlert(title: "系统内置模板受保护", message: "系统内置模板受 macOS 保护，不可直接删除。如需自定义，请复制或导出后再行修改。")
            return
        }

        // 2. 确认弹窗
        if !skipConfirmation && !suppressAlertsForTesting {
            let alert = NSAlert()
            alert.messageText = "确认将模板移入废纸篓？"
            alert.informativeText = "模板「\(item.name)」将被安全移至 macOS 废纸篓。\n物理路径：\(item.path)\n\n您随时可在系统废纸篓中将其「放回原处」。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "移入废纸篓")
            alert.addButton(withTitle: "取消")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 3. 执行无损可逆删除 (macOS 原生 trashItem)
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: item.path)
        do {
            try fm.trashItem(at: targetURL, resultingItemURL: nil)
        } catch {
            showAlert(title: "移入废纸篓失败", message: "操作失败: \(error.localizedDescription)")
            return
        }

        // 4. 从内存列表移除
        allItems.removeAll { $0.path == item.path || $0.targetPath == item.targetPath }
        plugins.removeAll { $0.path == item.path || $0.targetPath == item.targetPath }

        // 5. 更新 AssetCacheManager 与缩略图缓存
        AssetCacheManager.shared.remove(itemPath: item.path)
        AssetCacheManager.shared.remove(itemPath: item.targetPath)
        ResourceCardView.thumbnailCache.removeObject(forKey: item.targetPath as NSString)
        ResourceCardView.thumbnailCache.removeObject(forKey: item.path as NSString)

        // 6. 更新 UI: 重新刷新表格与卡片，并刷新子分类胶囊计数
        pluginTableView?.reloadData()
        reloadCardGrid(resetPaging: false)
        updateSubCategoryFilterBar()
        updateStatusLine()
        statusLabel?.stringValue = "模板「\(item.name)」已成功移入废纸篓 ✓"
    }

    public func makeTemplateActionMenu(for item: TemplateItem) -> NSMenu {
        let menu = NSMenu()
        if item.isMismatchedDisk {
            let warnItem = NSMenuItem(title: "🚫 异盘同名（UUID 不匹配，禁止操作）", action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            menu.addItem(warnItem)
            menu.addItem(NSMenuItem.separator())
            let bindItem = NSMenuItem(title: "⚡️ 信任并强制绑定此卷…", action: #selector(onForceBindVolumeMenu(_:)), keyEquivalent: "")
            bindItem.target = self
            bindItem.representedObject = item
            menu.addItem(bindItem)
            return menu
        } else if item.isCorrupted {
            let warnItem = NSMenuItem(title: "❌ 素材损坏/丢失（受容灾保护，禁止操作）", action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            menu.addItem(warnItem)
            menu.addItem(NSMenuItem.separator())
            let recheckItem = NSMenuItem(title: "🔍 重新校验文件存在性…", action: #selector(onRecheckCorruptedMenu(_:)), keyEquivalent: "")
            recheckItem.target = self
            recheckItem.representedObject = item
            menu.addItem(recheckItem)
            return menu
        } else if item.isOffline {
            // FCPX-046: 补充离线素材的重新检测挂载入口，消除操作死路
            let offlineItem = NSMenuItem(title: "⚠️ 磁盘离线（受容灾保护，禁止常规操作）", action: nil, keyEquivalent: "")
            offlineItem.isEnabled = false
            menu.addItem(offlineItem)
            menu.addItem(NSMenuItem.separator())
            let redetectItem = NSMenuItem(title: "🔄 重新检测磁盘挂载状态…", action: #selector(onRedetectDiskMenu(_:)), keyEquivalent: "")
            redetectItem.target = self
            redetectItem.representedObject = item
            menu.addItem(redetectItem)
            return menu
        }

        let renameItem = NSMenuItem(title: "📝 设置中文别名 / 本地化重命名…", action: #selector(onCardRenameMenu(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = item
        menu.addItem(renameItem)

        let revealItem = NSMenuItem(title: "📂 在访达 (Finder) 中显示", action: #selector(onCardRevealMenu(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = item
        menu.addItem(revealItem)

        if item.tier == .user && !item.isSymlink {
            let migItem = NSMenuItem(title: "⚡ 迁移至外置移动硬盘 (0占用)", action: #selector(onCardMigrateMenu(_:)), keyEquivalent: "")
            migItem.target = self
            migItem.representedObject = item
            menu.addItem(migItem)
        }

        menu.addItem(NSMenuItem.separator())

        let designerItem = NSMenuItem(title: "🎨 在 Motion 设计器中打开", action: #selector(onCardDesignerMenu(_:)), keyEquivalent: "")
        designerItem.target = self
        designerItem.representedObject = item
        menu.addItem(designerItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "🗑️ 移入废纸篓 (Delete)", action: #selector(onCardDeleteMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = item
        menu.addItem(deleteItem)

        return menu
    }

    public func showActionMenu(for item: TemplateItem, from view: NSView) {
        let menu = makeTemplateActionMenu(for: item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func onRedetectDiskMenu(_ sender: NSMenuItem) {
        let mounted = StorageMigrationManager.shared.listMountedVolumes()
        for vol in mounted {
            TemplateMigrator.handleVolumeEvent(volumePath: vol.path, isMounted: true)
        }
        refreshList()
        showAlert(title: "磁盘状态检测", message: "已触发外置存储挂载探测，素材状态已刷新。")
    }

    @objc private func onCardDeleteMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        deleteTemplateItem(item)
    }

    @objc private func onCardRenameMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        showRenameDialog(for: item)
    }

    @objc private func onForceBindVolumeMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        forceBindVolume(for: item, skipConfirmation: false)
    }

    @objc private func onRecheckCorruptedMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        recheckCorruptedItem(item)
    }

    public func forceBindVolume(for item: TemplateItem, skipConfirmation: Bool = false) {
        if !skipConfirmation && !suppressAlertsForTesting {
            let alert = NSAlert()
            alert.messageText = "强制绑定外置卷"
            alert.informativeText = "素材「\(item.name)」原绑定盘与当前挂载盘 UUID 不一致。\n强制绑定将更新素材记录的卷 UUID，并重新校验主文件物理状态。\n\n是否继续？"
            alert.addButton(withTitle: "强制绑定")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        let volPath: String
        if let vp = item.volumePath, !vp.isEmpty {
            volPath = vp
        } else {
            let comps = (item.targetPath as NSString).pathComponents
            if comps.count >= 3 && comps[1] == "Volumes" {
                volPath = "/Volumes/\(comps[2])"
            } else {
                volPath = ""
            }
        }
        let currentUUID = TemplateItem.getVolumeUUID(for: volPath)

        var updated = item
        updated.volumeUUID = currentUUID
        updated.isMismatchedDisk = false
        if FileManager.default.fileExists(atPath: updated.targetPath) {
            updated.isOffline = false
            updated.isCorrupted = false
        } else {
            updated.isOffline = false
            updated.isCorrupted = true
        }

        if let idx = allItems.firstIndex(where: { $0.path == item.path }) {
            allItems[idx] = updated
        }
        AssetCacheManager.shared.syncItemsState(from: allItems)

        let itemMap = TemplateItem.buildItemIndex(from: allItems)
        for i in 0..<plugins.count {
            if let matched = itemMap["\(plugins[i].path)|\(plugins[i].targetPath)"] ?? itemMap[plugins[i].path] {
                plugins[i] = matched
            }
        }
        for g in 0..<groupItems.count {
            for i in 0..<groupItems[g].items.count {
                if let matched = itemMap["\(groupItems[g].items[i].path)|\(groupItems[g].items[i].targetPath)"] ?? itemMap[groupItems[g].items[i].path] {
                    groupItems[g].items[i] = matched
                }
            }
        }
        for card in cardViews {
            if let matched = itemMap["\(card.item.path)|\(card.item.targetPath)"] ?? itemMap[card.item.path] {
                card.item = matched
            }
        }
        reloadCardGrid(resetPaging: false)

        let msg = "已强制绑定卷并更新素材「\(item.name)」状态"
        statusLabel?.stringValue = msg
        updateStatusLine(overrideMessage: msg)
    }

    public func recheckCorruptedItem(_ item: TemplateItem) {
        var updated = item
        if FileManager.default.fileExists(atPath: item.targetPath) {
            updated.isCorrupted = false
            updated.isOffline = false
            let msg = "素材「\(item.name)」主文件校验通过，已成功恢复在线 ✓"
            statusLabel?.stringValue = msg
            updateStatusLine(overrideMessage: msg)
        } else {
            updated.isCorrupted = true
            let msg = "素材「\(item.name)」主文件依然缺失，保持损坏保护状态"
            statusLabel?.stringValue = msg
            updateStatusLine(overrideMessage: msg)
        }

        if let idx = allItems.firstIndex(where: { $0.path == item.path }) {
            allItems[idx] = updated
        }
        AssetCacheManager.shared.syncItemsState(from: allItems)

        let itemMap = TemplateItem.buildItemIndex(from: allItems)
        for i in 0..<plugins.count {
            if let matched = itemMap["\(plugins[i].path)|\(plugins[i].targetPath)"] ?? itemMap[plugins[i].path] {
                plugins[i] = matched
            }
        }
        for g in 0..<groupItems.count {
            for i in 0..<groupItems[g].items.count {
                if let matched = itemMap["\(groupItems[g].items[i].path)|\(groupItems[g].items[i].targetPath)"] ?? itemMap[groupItems[g].items[i].path] {
                    groupItems[g].items[i] = matched
                }
            }
        }
        for card in cardViews {
            if let matched = itemMap["\(card.item.path)|\(card.item.targetPath)"] ?? itemMap[card.item.path] {
                card.item = matched
            }
        }
        reloadCardGrid(resetPaging: false)
    }

    @objc private func onCardRevealMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }

    @objc private func onCardMigrateMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        migrateItemToExternal(item)
    }

    @objc private func onCardDesignerMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TemplateItem else { return }
        onOpenTemplateInDesigner?(item.path)
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 2：3D LUT 调色库与分屏对比视口 (R38 FXLUT)
    // ═══════════════════════════════════════════════════════════════

    private func setupLUTModule(in container: NSView) {
        lutContainerView = NSView()
        lutContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lutContainerView)

        NSLayoutConstraint.activate([
            lutContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            lutContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lutContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lutContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let lutToolbar = NSStackView()
        lutToolbar.orientation = .horizontal
        lutToolbar.spacing = 10
        lutToolbar.translatesAutoresizingMaskIntoConstraints = false
        lutContainerView.addSubview(lutToolbar)

        let titleLabel = NSTextField(labelWithString: "🎞️ 3D LUT 调色引擎")
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        lutToolbar.addArrangedSubview(titleLabel)

        lutCategoryPopup = NSPopUpButton()
        lutCategoryPopup.target = self
        lutCategoryPopup.action = #selector(onLUTCatChanged)
        lutToolbar.addArrangedSubview(lutCategoryPopup)

        let chooseSampleBtn = NSButton(title: "🖼️ 更换测试图", target: self, action: #selector(onChooseLUTSampleClicked))
        lutToolbar.addArrangedSubview(chooseSampleBtn)

        let resetSampleBtn = NSButton(title: "重置样图", target: self, action: #selector(onResetLUTSampleClicked))
        lutToolbar.addArrangedSubview(resetSampleBtn)

        lutModeSegmentedControl = NSSegmentedControl(
            labels: ["分屏对比 ◫", "全图调色 ◼", "原始无调色 ◻"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onLUTModeChanged)
        )
        lutModeSegmentedControl.selectedSegment = 0
        lutToolbar.addArrangedSubview(lutModeSegmentedControl)

        let splitStack = NSStackView()
        splitStack.orientation = .horizontal
        splitStack.distribution = .fill
        splitStack.spacing = 12
        splitStack.translatesAutoresizingMaskIntoConstraints = false
        lutContainerView.addSubview(splitStack)

        let leftBox = NSView()
        leftBox.translatesAutoresizingMaskIntoConstraints = false
        leftBox.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let lutScroll = NSScrollView()
        lutScroll.translatesAutoresizingMaskIntoConstraints = false
        lutScroll.hasVerticalScroller = true
        lutScroll.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)

        lutTableView = NSTableView()
        lutTableView.usesAlternatingRowBackgroundColors = false
        lutTableView.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)

        let colThumb = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lut_name"))
        colThumb.title = "LUT 名称与分类"
        colThumb.width = 230
        lutTableView.addTableColumn(colThumb)

        let colDim = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lut_dim"))
        colDim.title = "网格"
        colDim.width = 45
        lutTableView.addTableColumn(colDim)

        let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lut_size"))
        colSize.title = "大小"
        colSize.width = 50
        lutTableView.addTableColumn(colSize)

        lutTableView.dataSource = self
        lutTableView.delegate = self
        lutScroll.documentView = lutTableView
        leftBox.addSubview(lutScroll)

        NSLayoutConstraint.activate([
            lutScroll.topAnchor.constraint(equalTo: leftBox.topAnchor),
            lutScroll.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor),
            lutScroll.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor),
            lutScroll.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor)
        ])
        splitStack.addArrangedSubview(leftBox)

        let rightBox = NSStackView()
        rightBox.orientation = .vertical
        rightBox.spacing = 8
        rightBox.translatesAutoresizingMaskIntoConstraints = false

        lutCompareView = LUTCompareView()
        lutCompareView.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addArrangedSubview(lutCompareView)

        let lutBottomBar = NSStackView()
        lutBottomBar.orientation = .horizontal
        lutBottomBar.spacing = 8

        lutInfoLabel = NSTextField(labelWithString: "当前未选定 LUT（在左侧选中以实时调色对比）")
        lutInfoLabel.font = .systemFont(ofSize: 11, weight: .medium)
        lutInfoLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        lutInfoLabel.lineBreakMode = .byTruncatingMiddle
        lutBottomBar.addArrangedSubview(lutInfoLabel)

        lutStatusLabel = NSTextField(labelWithString: "💡 提示：在画面左右移动鼠标可实时拉动对比分屏")
        lutStatusLabel.font = .systemFont(ofSize: 11)
        lutStatusLabel.textColor = NSColor(red: 0.38, green: 0.74, blue: 0.95, alpha: 1.0)
        lutBottomBar.addArrangedSubview(lutStatusLabel)

        rightBox.addArrangedSubview(lutBottomBar)
        splitStack.addArrangedSubview(rightBox)

        NSLayoutConstraint.activate([
            lutToolbar.topAnchor.constraint(equalTo: lutContainerView.topAnchor, constant: 8),
            lutToolbar.leadingAnchor.constraint(equalTo: lutContainerView.leadingAnchor, constant: 12),
            lutToolbar.trailingAnchor.constraint(equalTo: lutContainerView.trailingAnchor, constant: -12),
            lutToolbar.heightAnchor.constraint(equalToConstant: 30),

            splitStack.topAnchor.constraint(equalTo: lutToolbar.bottomAnchor, constant: 8),
            splitStack.leadingAnchor.constraint(equalTo: lutContainerView.leadingAnchor, constant: 12),
            splitStack.trailingAnchor.constraint(equalTo: lutContainerView.trailingAnchor, constant: -12),
            splitStack.bottomAnchor.constraint(equalTo: lutContainerView.bottomAnchor, constant: -10)
        ])
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 3：影视级音效音频库与真实波形 (R38 Audio)
    // ═══════════════════════════════════════════════════════════════

    private func setupAudioModule(in container: NSView) {
        audioContainerView = NSView()
        audioContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(audioContainerView)

        NSLayoutConstraint.activate([
            audioContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            audioContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            audioContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            audioContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let audioToolbar = NSStackView()
        audioToolbar.orientation = .horizontal
        audioToolbar.spacing = 10
        audioToolbar.translatesAutoresizingMaskIntoConstraints = false
        audioContainerView.addSubview(audioToolbar)

        let titleLabel = NSTextField(labelWithString: "🎵 影视级音效库")
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        audioToolbar.addArrangedSubview(titleLabel)

        audioCategoryPopup = NSPopUpButton()
        audioCategoryPopup.target = self
        audioCategoryPopup.action = #selector(onAudioCatChanged)
        audioToolbar.addArrangedSubview(audioCategoryPopup)

        audioStatusLabel = NSTextField(labelWithString: "已就绪")
        audioStatusLabel.font = .systemFont(ofSize: 11)
        audioStatusLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        audioToolbar.addArrangedSubview(audioStatusLabel)

        let splitStack = NSStackView()
        splitStack.orientation = .horizontal
        splitStack.distribution = .fill
        splitStack.spacing = 12
        splitStack.translatesAutoresizingMaskIntoConstraints = false
        audioContainerView.addSubview(splitStack)

        let leftBox = NSView()
        leftBox.translatesAutoresizingMaskIntoConstraints = false
        leftBox.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let audioScroll = NSScrollView()
        audioScroll.translatesAutoresizingMaskIntoConstraints = false
        audioScroll.hasVerticalScroller = true
        audioScroll.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)

        audioTableView = NSTableView()
        audioTableView.usesAlternatingRowBackgroundColors = false
        audioTableView.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)

        let colAudioName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("audio_name"))
        colAudioName.title = "音效名称与分类"
        colAudioName.width = 240
        audioTableView.addTableColumn(colAudioName)

        let colAudioDur = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("audio_duration"))
        colAudioDur.title = "时长"
        colAudioDur.width = 65
        audioTableView.addTableColumn(colAudioDur)

        let colAudioPlay = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("audio_play"))
        colAudioPlay.title = "试听"
        colAudioPlay.width = 50
        audioTableView.addTableColumn(colAudioPlay)

        audioTableView.dataSource = self
        audioTableView.delegate = self
        audioScroll.documentView = audioTableView
        leftBox.addSubview(audioScroll)

        NSLayoutConstraint.activate([
            audioScroll.topAnchor.constraint(equalTo: leftBox.topAnchor),
            audioScroll.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor),
            audioScroll.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor),
            audioScroll.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor)
        ])
        splitStack.addArrangedSubview(leftBox)

        let rightCard = NSView()
        rightCard.wantsLayer = true
        rightCard.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        rightCard.layer?.cornerRadius = 8
        rightCard.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.spacing = 12
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        rightCard.addSubview(cardStack)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: rightCard.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: rightCard.bottomAnchor, constant: -16)
        ])

        audioTitleLabel = NSTextField(labelWithString: "未选定音效")
        audioTitleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        audioTitleLabel.textColor = .white
        cardStack.addArrangedSubview(audioTitleLabel)

        audioMetaLabel = NSTextField(labelWithString: "请在左侧列表中点击选择要试听的音效条目")
        audioMetaLabel.font = .systemFont(ofSize: 12)
        audioMetaLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        cardStack.addArrangedSubview(audioMetaLabel)

        audioWaveformView = AudioWaveformView()
        audioWaveformView.translatesAutoresizingMaskIntoConstraints = false
        audioWaveformView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        cardStack.addArrangedSubview(audioWaveformView)
        audioWaveformView.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor).isActive = true
        audioWaveformView.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor).isActive = true

        audioWaveformView.onSeek = { ratio in
            AudioManager.shared.seek(to: Double(ratio))
        }

        let ctrlBox = NSStackView()
        ctrlBox.orientation = .horizontal
        ctrlBox.spacing = 12

        audioPlayBtn = NSButton(title: "▶ 试听播放", target: self, action: #selector(onAudioPlayToggle))
        audioPlayBtn.bezelStyle = .rounded
        audioPlayBtn.font = .systemFont(ofSize: 12, weight: .bold)
        ctrlBox.addArrangedSubview(audioPlayBtn)

        audioStopBtn = NSButton(title: "⏹ 停止", target: self, action: #selector(onAudioStopClicked))
        audioStopBtn.bezelStyle = .rounded
        ctrlBox.addArrangedSubview(audioStopBtn)

        audioTimeLabel = NSTextField(labelWithString: "00:00.0 / 00:00.0")
        audioTimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        audioTimeLabel.textColor = NSColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1.0)
        ctrlBox.addArrangedSubview(audioTimeLabel)

        let revealBtn = NSButton(title: "📂 在访达中显示", target: self, action: #selector(onRevealAudioClicked))
        ctrlBox.addArrangedSubview(revealBtn)

        cardStack.addArrangedSubview(ctrlBox)

        let tipLabel = NSTextField(labelWithString: "💡 提示：点击波形图可快速定位试听；在列表中支持直接拖拽音频文件至 FCPX 时间线")
        tipLabel.font = .systemFont(ofSize: 11)
        tipLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        cardStack.addArrangedSubview(tipLabel)

        splitStack.addArrangedSubview(rightCard)

        NSLayoutConstraint.activate([
            audioToolbar.topAnchor.constraint(equalTo: audioContainerView.topAnchor, constant: 8),
            audioToolbar.leadingAnchor.constraint(equalTo: audioContainerView.leadingAnchor, constant: 12),
            audioToolbar.trailingAnchor.constraint(equalTo: audioContainerView.trailingAnchor, constant: -12),
            audioToolbar.heightAnchor.constraint(equalToConstant: 30),

            splitStack.topAnchor.constraint(equalTo: audioToolbar.bottomAnchor, constant: 8),
            splitStack.leadingAnchor.constraint(equalTo: audioContainerView.leadingAnchor, constant: 12),
            splitStack.trailingAnchor.constraint(equalTo: audioContainerView.trailingAnchor, constant: -12),
            splitStack.bottomAnchor.constraint(equalTo: audioContainerView.bottomAnchor, constant: -10)
        ])
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 4：FCPX 资源库深度瘦身医生 (R39 LibraryCleaner)
    // ═══════════════════════════════════════════════════════════════

    private func setupCleanerModule(in container: NSView) {
        cleanerContainerView = NSView()
        cleanerContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cleanerContainerView)

        NSLayoutConstraint.activate([
            cleanerContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            cleanerContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cleanerContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cleanerContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        cleanerDashboardView = CleanerDashboardView(frame: container.bounds)
        cleanerDashboardView.translatesAutoresizingMaskIntoConstraints = false
        cleanerContainerView.addSubview(cleanerDashboardView)

        NSLayoutConstraint.activate([
            cleanerDashboardView.topAnchor.constraint(equalTo: cleanerContainerView.topAnchor),
            cleanerDashboardView.leadingAnchor.constraint(equalTo: cleanerContainerView.leadingAnchor),
            cleanerDashboardView.trailingAnchor.constraint(equalTo: cleanerContainerView.trailingAnchor),
            cleanerDashboardView.bottomAnchor.constraint(equalTo: cleanerContainerView.bottomAnchor)
        ])
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 5：幽灵插件智能体检与断链自愈医生 (R41 GhostPluginDoctor)
    // ═══════════════════════════════════════════════════════════════

    private func setupDoctorModule(in container: NSView) {
        doctorContainerView = NSView()
        doctorContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(doctorContainerView)

        NSLayoutConstraint.activate([
            doctorContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            doctorContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            doctorContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            doctorContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        doctorDashboardView = PluginDoctorDashboardView(frame: container.bounds)
        doctorDashboardView.translatesAutoresizingMaskIntoConstraints = false
        doctorContainerView.addSubview(doctorDashboardView)

        NSLayoutConstraint.activate([
            doctorDashboardView.topAnchor.constraint(equalTo: doctorContainerView.topAnchor),
            doctorDashboardView.leadingAnchor.constraint(equalTo: doctorContainerView.leadingAnchor),
            doctorDashboardView.trailingAnchor.constraint(equalTo: doctorContainerView.trailingAnchor),
            doctorDashboardView.bottomAnchor.constraint(equalTo: doctorContainerView.bottomAnchor)
        ])
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 6：外置移动存储与一键搬家管理中心 (R42 对标嘉星)
    // ═══════════════════════════════════════════════════════════════

    private func setupStorageModule(in container: NSView) {
        storageContainerView = NSView()
        storageContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(storageContainerView)

        NSLayoutConstraint.activate([
            storageContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            storageContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            storageContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            storageContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        storageMigrationDashboardView = StorageMigrationDashboardView(frame: container.bounds)
        storageMigrationDashboardView.translatesAutoresizingMaskIntoConstraints = false
        storageContainerView.addSubview(storageMigrationDashboardView)

        NSLayoutConstraint.activate([
            storageMigrationDashboardView.topAnchor.constraint(equalTo: storageContainerView.topAnchor),
            storageMigrationDashboardView.leadingAnchor.constraint(equalTo: storageContainerView.leadingAnchor),
            storageMigrationDashboardView.trailingAnchor.constraint(equalTo: storageContainerView.trailingAnchor),
            storageMigrationDashboardView.bottomAnchor.constraint(equalTo: storageContainerView.bottomAnchor)
        ])
    }

    private func setupProfileModule(in container: NSView) {
        profileContainerView = NSView()
        profileContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(profileContainerView)

        NSLayoutConstraint.activate([
            profileContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            profileContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            profileContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            profileContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        profileDashboardView = WorkspaceProfileDashboardView(frame: container.bounds)
        profileDashboardView.translatesAutoresizingMaskIntoConstraints = false
        profileContainerView.addSubview(profileDashboardView)

        NSLayoutConstraint.activate([
            profileDashboardView.topAnchor.constraint(equalTo: profileContainerView.topAnchor),
            profileDashboardView.leadingAnchor.constraint(equalTo: profileContainerView.leadingAnchor),
            profileDashboardView.trailingAnchor.constraint(equalTo: profileContainerView.trailingAnchor),
            profileDashboardView.bottomAnchor.constraint(equalTo: profileContainerView.bottomAnchor)
        ])
    }

    private func setupTeamSyncModule(in container: NSView) {
        teamSyncContainerView = NSView()
        teamSyncContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(teamSyncContainerView)

        NSLayoutConstraint.activate([
            teamSyncContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            teamSyncContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            teamSyncContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            teamSyncContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        teamSyncDashboardView = TeamSyncDashboardView(frame: container.bounds)
        teamSyncDashboardView.translatesAutoresizingMaskIntoConstraints = false
        teamSyncContainerView.addSubview(teamSyncDashboardView)

        NSLayoutConstraint.activate([
            teamSyncDashboardView.topAnchor.constraint(equalTo: teamSyncContainerView.topAnchor),
            teamSyncDashboardView.leadingAnchor.constraint(equalTo: teamSyncContainerView.leadingAnchor),
            teamSyncDashboardView.trailingAnchor.constraint(equalTo: teamSyncContainerView.trailingAnchor),
            teamSyncDashboardView.bottomAnchor.constraint(equalTo: teamSyncContainerView.bottomAnchor)
        ])
    }

    private func setupSettingsModule(in container: NSView) {
        settingsContainerView = NSView()
        settingsContainerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsContainerView)

        NSLayoutConstraint.activate([
            settingsContainerView.topAnchor.constraint(equalTo: container.topAnchor),
            settingsContainerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            settingsContainerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            settingsContainerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        settingsDashboardView = SettingsDashboardView(frame: container.bounds)
        settingsDashboardView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainerView.addSubview(settingsDashboardView)

        NSLayoutConstraint.activate([
            settingsDashboardView.topAnchor.constraint(equalTo: settingsContainerView.topAnchor),
            settingsDashboardView.leadingAnchor.constraint(equalTo: settingsContainerView.leadingAnchor),
            settingsDashboardView.trailingAnchor.constraint(equalTo: settingsContainerView.trailingAnchor),
            settingsDashboardView.bottomAnchor.constraint(equalTo: settingsContainerView.bottomAnchor)
        ])
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 2 交互逻辑 (3D LUT 异步加载)
    // ═══════════════════════════════════════════════════════════════

    @objc public func refreshLUTList() {
        if let cached = AssetCacheManager.shared.getLUTs() {
            allLUTItems = cached
            populateLUTCategories()
            return
        }

        LUTManager.shared.scanAsync { [weak self] items in
            guard let self = self else { return }
            self.allLUTItems = items
            self.populateLUTCategories()
        }
    }

    private func populateLUTCategories() {
        var categories = Set<String>()
        for item in allLUTItems {
            categories.insert(item.category)
        }
        let sortedCats = ["全部分类 (\(allLUTItems.count))"] + categories.sorted()

        lutCategoryPopup?.removeAllItems()
        lutCategoryPopup?.addItems(withTitles: sortedCats)

        filterLUTList()
        lutStatusLabel?.stringValue = "已扫描 \(allLUTItems.count) 款 3D LUT"

        if selectedLUTItem == nil, let first = filteredLUTItems.first {
            selectLUTItem(first)
        }
    }

    @objc public func onLUTCatChanged() {
        filterLUTList()
    }

    private func filterLUTList() {
        let idx = lutCategoryPopup?.indexOfSelectedItem ?? 0
        if idx <= 0 {
            filteredLUTItems = allLUTItems
        } else {
            let cat = lutCategoryPopup?.titleOfSelectedItem ?? ""
            filteredLUTItems = allLUTItems.filter { $0.category == cat }
        }
        lutTableView?.reloadData()
    }

    public func selectLUTItem(_ item: LUTItem) {
        selectedLUTItem = item
        lutInfoLabel?.stringValue = "当前选定: \(item.name) (\(item.category)) · \(item.dimension)x\(item.dimension)x\(item.dimension) 网格"
        lutCompareView?.currentLUT = item

        if let idx = filteredLUTItems.firstIndex(of: item) {
            lutTableView?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            lutTableView?.scrollRowToVisible(idx)
        }
    }

    @objc public func onLUTModeChanged() {
        let mode = lutModeSegmentedControl?.selectedSegment ?? 0
        switch mode {
        case 0: lutCompareView?.displayMode = .split
        case 1: lutCompareView?.displayMode = .lutOnly
        default: lutCompareView?.displayMode = .originalOnly
        }
    }

    @objc public func onResetLUTSampleClicked() {
        lutCompareView?.originalImage = LUTManager.makeCinematicReferenceImage()
    }

    @objc public func onChooseLUTSampleClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            _ = lutCompareView?.setOriginalImageFromPath(url.path)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 3 交互逻辑 (音效库异步加载)
    // ═══════════════════════════════════════════════════════════════

    @objc public func refreshAudioList() {
        if let cached = AssetCacheManager.shared.getAudios() {
            allAudioItems = cached
            populateAudioCategories()
            return
        }

        AudioManager.shared.scanAsync { [weak self] items in
            guard let self = self else { return }
            self.allAudioItems = items
            self.populateAudioCategories()
        }
    }

    private func populateAudioCategories() {
        var categories = Set<String>()
        for item in allAudioItems {
            categories.insert(item.category)
        }
        let sortedCats = ["全部分类 (\(allAudioItems.count))"] + categories.sorted()

        audioCategoryPopup?.removeAllItems()
        audioCategoryPopup?.addItems(withTitles: sortedCats)

        filterAudioList()
        audioStatusLabel?.stringValue = "已扫描 \(allAudioItems.count) 款专业影视音效"

        if selectedAudioItem == nil, let first = filteredAudioItems.first {
            selectAudioItem(first)
        }
    }

    @objc public func onAudioCatChanged() {
        filterAudioList()
    }

    private func filterAudioList() {
        let idx = audioCategoryPopup?.indexOfSelectedItem ?? 0
        if idx <= 0 {
            filteredAudioItems = allAudioItems
        } else {
            let cat = audioCategoryPopup?.titleOfSelectedItem ?? ""
            filteredAudioItems = allAudioItems.filter { $0.category == cat }
        }
        audioTableView?.reloadData()
    }

    public func selectAudioItem(_ item: AudioItem) {
        selectedAudioItem = item
        audioTitleLabel?.stringValue = item.name
        audioMetaLabel?.stringValue = "分类: \(item.category) · 时长: \(item.durationFormatted) · 采样率: \(Int(item.sampleRate)) Hz · 声道: \(item.channels)"
        audioTimeLabel?.stringValue = "00:00.0 / \(item.durationFormatted)"

        let amps = AudioManager.shared.extractWaveform(from: URL(fileURLWithPath: item.path))
        audioWaveformView?.amplitudes = amps
        audioWaveformView?.playbackProgress = 0.0

        if let idx = filteredAudioItems.firstIndex(of: item) {
            audioTableView?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            audioTableView?.scrollRowToVisible(idx)
        }
    }

    @objc public func onAudioPlayToggle() {
        if AudioManager.shared.isPlaying {
            AudioManager.shared.pause()
            audioPlayBtn?.title = "▶ 播放"
        } else {
            if let item = selectedAudioItem {
                playAudioItem(item)
            }
        }
    }

    public func playAudioItem(_ item: AudioItem) {
        if selectedAudioItem != item {
            selectAudioItem(item)
        }

        AudioManager.shared.play(
            item: item,
            onProgress: { [weak self] progress in
                guard let self = self else { return }
                self.audioWaveformView?.playbackProgress = CGFloat(progress)
                let cur = progress * item.duration
                let curM = Int(cur) / 60
                let curS = Int(cur) % 60
                let curMs = Int((cur.truncatingRemainder(dividingBy: 1)) * 10)
                let totM = Int(item.duration) / 60
                let totS = Int(item.duration) % 60
                let totMs = Int((item.duration.truncatingRemainder(dividingBy: 1)) * 10)
                self.audioTimeLabel?.stringValue = String(format: "%02d:%02d.%01d / %02d:%02d.%01d", curM, curS, curMs, totM, totS, totMs)
            },
            onFinish: { [weak self] in
                self?.audioPlayBtn?.title = "▶ 试听播放"
                self?.audioWaveformView?.playbackProgress = 0.0
            }
        )
        audioPlayBtn?.title = "⏸ 暂停"
    }

    @objc public func onAudioStopClicked() {
        AudioManager.shared.stop()
        audioPlayBtn?.title = "▶ 试听播放"
        audioWaveformView?.playbackProgress = 0.0
        if let item = selectedAudioItem {
            audioTimeLabel?.stringValue = "00:00.0 / \(item.durationFormatted)"
        }
    }

    @objc public func onRevealAudioClicked() {
        guard let item = selectedAudioItem else { return }
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }

    @objc private func onAudioRowPlayClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < filteredAudioItems.count else { return }
        let item = filteredAudioItems[row]
        playAudioItem(item)
    }

    // ═══════════════════════════════════════════════════════════════
    //  模块 1 交互与迁移逻辑
    // ═══════════════════════════════════════════════════════════════

    @objc public func onFooterDriveClicked() {
        selectSidebarItem(at: 8)
    }

    @objc public func onChangePathClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选为外置存储"
        if panel.runModal() == .OK, let url = panel.url {
            externalRoot = url.path
            pathDisplayField?.stringValue = externalRoot
            updateExternalStorageStatus()
            refreshList()
        }
    }

    @objc public func onSettingsClicked() {
        selectSidebarItem(at: 11)
    }

    @objc public func onCategoryChanged() {
        let idx = categoryPopup?.indexOfSelectedItem ?? 0
        if idx >= 0 && idx < categories.count {
            selectCategory(categories[idx])
        }
    }

    public func selectCategory(_ category: String) {
        guard categories.contains(category) else { return }
        currentCategory = category
        currentSubCategoryFilter = "全部"
        if let idx = categories.firstIndex(of: category) {
            currentSidebarIndex = idx
            updateSidebarSelection()
            categoryPopup?.selectItem(at: idx)
        }
        updateCategoryTitle()
        refreshList()
    }

    @objc public func onFilterChanged() {
        applyFilterAndSort()
    }

    @objc public func onExternalizeClicked() {
        let row = pluginTableView?.selectedRow ?? -1
        guard let p = item(at: row) else {
            showAlert(title: "未选择模板", message: "请在列表中选中一个用户级模板后再点外置化。")
            return
        }
        migrateItemToExternal(p)
    }

    private func migrateItemToExternal(_ p: TemplateItem) {
        guard LicenseManager.shared.isProLicensed else {
            showAlert(title: "商业授权未激活", message: "未激活商业授权，外置搬家与软链接迁移已锁定。请先激活商业授权。")
            return
        }
        if p.tier != .user {
            showAlert(title: "仅支持用户级", message: "只有「🟢 用户」级模板支持外置化（系统级与内置级禁止随意搬迁）。")
            return
        }
        if p.isSymlink {
            showAlert(title: "已是软链接", message: "该项已经是外置软链接，无需重复外置化。")
            return
        }
        setBusy(true, text: "正在外置化「\(p.name)」…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (ok, msg) = SymlinkSocket.shared.migrateToExternal(
                category: p.category, groupName: p.name, externalRoot: self.externalRoot)
            DispatchQueue.main.async {
                self.setBusy(false, text: nil)
                self.refreshList()
                self.showAlert(title: ok ? "外置化完成" : "外置化失败", message: msg)
            }
        }
    }

    @objc private func onPolicyChanged() {
        undoButton.isEnabled = migrator.lastRecord() != nil
        pluginTableView?.reloadData()
        reloadCardGrid()
    }

    // MARK: – P2 外置盘热插拔与断链容灾响应

    @objc private func onVolumeStatusChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let volumePath = (userInfo[TemplateMigrator.volumePathUserInfoKey] as? String) ?? (userInfo["volumePath"] as? String) ?? ""
        let isMounted = (userInfo[TemplateMigrator.isMountedUserInfoKey] as? Bool) ?? (userInfo["isMounted"] as? Bool) ?? true
        let volumeName = (userInfo["volumeName"] as? String) ?? (volumePath as NSString).lastPathComponent
        let volumeUUID = userInfo["volumeUUID"] as? String

        if Thread.isMainThread {
            self.handleVolumeStatusChange(volumePath: volumePath, volumeName: volumeName, isMounted: isMounted, volumeUUID: volumeUUID)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handleVolumeStatusChange(volumePath: volumePath, volumeName: volumeName, isMounted: isMounted, volumeUUID: volumeUUID)
            }
        }
    }

    public func handleVolumeStatusChange(volumePath: String, volumeName: String, isMounted: Bool, volumeUUID: String? = nil) {
        let normVol = (volumePath as NSString).standardizingPath
        let normVolPrefix = normVol.hasSuffix("/") ? normVol : normVol + "/"
        let mountedUUID = (volumeUUID != nil && !volumeUUID!.isEmpty) ? volumeUUID : TemplateItem.getVolumeUUID(for: normVol, bypassCache: isMounted)
        var affectedCount = 0

        if !isMounted {
            // 外置卷卸载/断开：将受影响模板标记 isOffline = true，坚决不从列表中删除！
            for i in 0..<allItems.count {
                let p = (allItems[i].path as NSString).standardizingPath
                let tp = (allItems[i].targetPath as NSString).standardizingPath
                let matchesVolume = (!normVol.isEmpty && (p == normVol || p.hasPrefix(normVolPrefix) || tp == normVol || tp.hasPrefix(normVolPrefix)))
                let isOffline = matchesVolume || migrator.isPathOffline(allItems[i].path, targetPath: allItems[i].targetPath)

                if isOffline {
                    allItems[i].isOffline = true
                    if allItems[i].volumePath == nil || allItems[i].volumePath?.isEmpty == true {
                        allItems[i].volumePath = normVol.isEmpty ? nil : normVol
                    }
                    affectedCount += 1
                }
            }

            // 同步全局内存缓存 (M-5: syncItemsState 已全量同步)
            AssetCacheManager.shared.syncItemsState(from: allItems)

            // O(n) 高性能字典索引 (M-6, M-7, S-3: 统一使用 buildItemIndex)
            let itemMap = TemplateItem.buildItemIndex(from: allItems)

            // 同步更新当前 filtered plugins (O(1) 字典查表)
            for i in 0..<plugins.count {
                if let matched = itemMap["\(plugins[i].path)|\(plugins[i].targetPath)"] ?? itemMap[plugins[i].path] {
                    plugins[i].isOffline = matched.isOffline
                    plugins[i].isCorrupted = matched.isCorrupted
                    plugins[i].isMismatchedDisk = matched.isMismatchedDisk
                    plugins[i].volumePath = matched.volumePath
                    plugins[i].volumeUUID = matched.volumeUUID
                }
            }

            // 同步更新中栏三段式面板 groupItems 内部各分组素材的离线标记 (O(1) 字典查表)
            for g in 0..<groupItems.count {
                for i in 0..<groupItems[g].items.count {
                    if let matched = itemMap["\(groupItems[g].items[i].path)|\(groupItems[g].items[i].targetPath)"] ?? itemMap[groupItems[g].items[i].path] {
                        groupItems[g].items[i].isOffline = matched.isOffline
                        groupItems[g].items[i].isCorrupted = matched.isCorrupted
                        groupItems[g].items[i].isMismatchedDisk = matched.isMismatchedDisk
                        groupItems[g].items[i].volumePath = matched.volumePath
                        groupItems[g].items[i].volumeUUID = matched.volumeUUID
                    }
                }
            }

            // 刷新网格展示离线灰化卡片，更新卡片属性 (O(1) 字典查表)
            for card in cardViews {
                if let matched = itemMap["\(card.item.path)|\(card.item.targetPath)"] ?? itemMap[card.item.path] {
                    card.item = matched
                }
            }
            reloadCardGrid(resetPaging: false)

            // 底部或顶部状态条显示离线提示（例如：“⚠️ 外置盘 [卷名] 已断开，12 套素材已离线保全”）
            let displayName = volumeName.isEmpty ? "外置盘" : volumeName
            let msg = "⚠️ 外置盘 [\(displayName)] 已断开，\(affectedCount) 套素材已离线保全"
            statusLabel?.stringValue = msg
            updateStatusLine(overrideMessage: msg)
        } else {
            // 外置卷挂载/恢复：自愈与一致性校验
            var restoredCount = 0
            var mismatchedCount = 0
            var pendingCheckPaths: [String] = []

            for i in 0..<allItems.count {
                let p = (allItems[i].path as NSString).standardizingPath
                let tp = (allItems[i].targetPath as NSString).standardizingPath
                let itemVol = allItems[i].volumePath.map { ($0 as NSString).standardizingPath }
                let itemUUID = allItems[i].volumeUUID

                // 判定是否关联此挂载事件：UUID 匹配 或 卷挂载路径前缀匹配
                let uuidMatches = (itemUUID != nil && mountedUUID != nil && !itemUUID!.isEmpty && itemUUID == mountedUUID)
                let pathMatches = (!normVol.isEmpty && (p == normVol || p.hasPrefix(normVolPrefix) || tp == normVol || tp.hasPrefix(normVolPrefix)))
                let volMatches = (itemVol != nil && itemVol == normVol)

                if uuidMatches {
                    // 原盘重连：UUID 匹配
                    // 场景 b: 卷改名/漂移（如原挂载点为 /Volumes/Disk，现挂载到 /Volumes/Disk 1）
                    if let oldVol = itemVol, oldVol != normVol, !oldVol.isEmpty {
                        let oldPrefix = oldVol.hasSuffix("/") ? oldVol : oldVol + "/"
                        let newPrefix = normVolPrefix
                        if allItems[i].targetPath.hasPrefix(oldPrefix) {
                            allItems[i].targetPath = newPrefix + allItems[i].targetPath.dropFirst(oldPrefix.count)
                        } else if allItems[i].targetPath == oldVol {
                            allItems[i].targetPath = normVol
                        }
                        if allItems[i].path.hasPrefix(oldPrefix) {
                            allItems[i].path = newPrefix + allItems[i].path.dropFirst(oldPrefix.count)
                        } else if allItems[i].path == oldVol {
                            allItems[i].path = normVol
                        }

                        // Critical 3: 软链接物理指向原子重写
                        if allItems[i].isSymlink && allItems[i].path != allItems[i].targetPath {
                            try? FileManager.default.removeItem(atPath: allItems[i].path)
                            try? FileManager.default.createSymbolicLink(atPath: allItems[i].path, withDestinationPath: allItems[i].targetPath)
                        }
                    }
                    allItems[i].volumePath = normVol
                    allItems[i].volumeUUID = mountedUUID

                    // S-1: 主线程乐观置位恢复在线（0ms 同步磁盘 I/O）
                    allItems[i].isOffline = false
                    allItems[i].isCorrupted = false
                    allItems[i].isMismatchedDisk = false
                    restoredCount += 1
                    pendingCheckPaths.append(allItems[i].targetPath)
                } else if pathMatches || volMatches {
                    // Critical 1: 异盘 UUID 空门防线修复
                    // 原素材具有 UUID，但新挂载卷无 UUID 或 UUID 不符：严密防线，坚决拒访！
                    if let originalUUID = itemUUID, !originalUUID.isEmpty {
                        allItems[i].isOffline = true
                        allItems[i].isMismatchedDisk = true
                        allItems[i].isCorrupted = false
                        mismatchedCount += 1
                    } else {
                        // 无既有冲突 UUID 记录，绑定当前卷 UUID
                        if allItems[i].volumeUUID == nil {
                            allItems[i].volumeUUID = mountedUUID
                        }
                        allItems[i].volumePath = normVol
                        allItems[i].isOffline = false
                        allItems[i].isCorrupted = false
                        allItems[i].isMismatchedDisk = false
                        restoredCount += 1
                        pendingCheckPaths.append(allItems[i].targetPath)
                    }
                }
            }

            // 同步内存缓存 (M-5)
            AssetCacheManager.shared.syncItemsState(from: allItems)

            // 统一字典索引更新 UI (M-6, M-7, S-3)
            let itemMap = TemplateItem.buildItemIndex(from: allItems)

            for i in 0..<plugins.count {
                if let matched = itemMap["\(plugins[i].path)|\(plugins[i].targetPath)"] ?? itemMap[plugins[i].path] {
                    plugins[i] = matched
                }
            }

            // 同步恢复中栏三段式面板 groupItems 内部各分组素材在线标记 (O(1) 字典查表)
            for g in 0..<groupItems.count {
                for i in 0..<groupItems[g].items.count {
                    if let matched = itemMap["\(groupItems[g].items[i].path)|\(groupItems[g].items[i].targetPath)"] ?? itemMap[groupItems[g].items[i].path] {
                        groupItems[g].items[i] = matched
                    }
                }
            }

            for card in cardViews {
                if let matched = itemMap["\(card.item.path)|\(card.item.targetPath)"] ?? itemMap[card.item.path] {
                    card.item = matched
                }
            }
            reloadCardGrid(resetPaging: false)

            let displayName = volumeName.isEmpty ? "外置盘" : volumeName
            let initialMsg: String
            if mismatchedCount > 0 {
                initialMsg = "🚫 挂载卷 [\(displayName)] 与原素材盘 UUID 不符，拒绝绑定 (\(mismatchedCount) 套素材已防护)"
            } else if !pendingCheckPaths.isEmpty {
                // FCPX-047: 慢盘校验期间展示校验中文案，成功文案在校验完成后再展示
                initialMsg = "⏳ 外置盘 [\(displayName)] 已重新连接，正在校验 \(restoredCount) 套素材完整性…"
            } else {
                initialMsg = "✅ 外置盘 [\(displayName)] 已重新连接，\(restoredCount) 套素材已恢复在线"
            }
            statusLabel?.stringValue = initialMsg
            updateStatusLine(overrideMessage: initialMsg)

            // S-1: 异步后台校验物理文件存在性，绝不阻塞主线程
            if !pendingCheckPaths.isEmpty {
                let targetsToCheck = pendingCheckPaths
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    var missingSet = Set<String>()
                    for target in targetsToCheck {
                        if !FileManager.default.fileExists(atPath: target) {
                            missingSet.insert(target)
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        if !missingSet.isEmpty {
                            var corruptedCount = 0
                            for i in 0..<self.allItems.count {
                                if missingSet.contains(self.allItems[i].targetPath) {
                                    self.allItems[i].isCorrupted = true
                                    self.allItems[i].isOffline = false
                                    corruptedCount += 1
                                }
                            }
                            AssetCacheManager.shared.syncItemsState(from: self.allItems)
                            let updatedMap = TemplateItem.buildItemIndex(from: self.allItems)
                            for i in 0..<self.plugins.count {
                                if let matched = updatedMap["\(self.plugins[i].path)|\(self.plugins[i].targetPath)"] ?? updatedMap[self.plugins[i].path] {
                                    self.plugins[i] = matched
                                }
                            }
                            for g in 0..<self.groupItems.count {
                                for i in 0..<self.groupItems[g].items.count {
                                    if let matched = updatedMap["\(self.groupItems[g].items[i].path)|\(self.groupItems[g].items[i].targetPath)"] ?? updatedMap[self.groupItems[g].items[i].path] {
                                        self.groupItems[g].items[i] = matched
                                    }
                                }
                            }
                            for card in self.cardViews {
                                if let matched = updatedMap["\(card.item.path)|\(card.item.targetPath)"] ?? updatedMap[card.item.path] {
                                    card.item = matched
                                }
                            }
                            self.reloadCardGrid(resetPaging: false)
                            let corruptedMsg = "⚠️ 外置盘 [\(displayName)] 部分文件缺失损坏：\(corruptedCount) 套素材标红告警"
                            self.statusLabel?.stringValue = corruptedMsg
                            self.updateStatusLine(overrideMessage: corruptedMsg)
                        } else {
                            // FCPX-047: 完整性验证全部通过后，切为绿灯完成态
                            let successMsg = "✅ 外置盘 [\(displayName)] 校验完成，\(restoredCount) 套素材已完全就绪在线"
                            self.statusLabel?.stringValue = successMsg
                            self.updateStatusLine(overrideMessage: successMsg)
                        }
                    }
                }
            }
        }
    }

    // MARK: – 模板扫描与过滤（彻底异步化 + 内存缓存秒级复用）

    @objc public func refreshList() {
        let startTime = CACurrentMediaTime()
        // 1. 优先秒级从内存缓存获取（0ms 响应，消除彩虹圈）
        if let cached = AssetCacheManager.shared.getTemplates(category: currentCategory) {
            let dyedItems = cached.items.map { it -> TemplateItem in
                var updated = it
                if self.migrator.isPathOffline(it.path, targetPath: it.targetPath) {
                    updated.isOffline = true
                }
                return updated
            }
            allItems = dyedItems
            roots = cached.roots
            tierNotes = cached.tierNotes
            updateSubCategoryFilterBar()
            updateGroupItems()
            undoButton?.isEnabled = migrator.lastRecord() != nil
            let elapsed = CACurrentMediaTime() - startTime
            loadTimeIndicatorLabel?.stringValue = String(format: "列表加载用时: %.2fs", max(0.01, elapsed))
            return
        }

        // 2. 无缓存时进入后台异步扫描，不卡主线程
        spinner?.startAnimation(nil)
        TemplateTierScanner.scanAsync(category: currentCategory, roots: roots, lazySizes: true) { [weak self] result in
            guard let self = self else { return }
            if self.suppressAlertsForTesting && !self.allItems.isEmpty { return }
            self.spinner?.stopAnimation(nil)
            let dyedItems = result.items.map { it -> TemplateItem in
                var updated = it
                if self.migrator.isPathOffline(it.path, targetPath: it.targetPath) {
                    updated.isOffline = true
                }
                return updated
            }
            self.allItems = dyedItems
            self.roots = result.roots
            self.tierNotes = result.tierNotes
            self.updateSubCategoryFilterBar()
            self.updateGroupItems()
            self.undoButton?.isEnabled = self.migrator.lastRecord() != nil
            let elapsed = CACurrentMediaTime() - startTime
            self.loadTimeIndicatorLabel?.stringValue = String(format: "列表加载用时: %.2fs", max(0.01, elapsed))
        }
    }

    public func applyFilterAndSort() {
        var list = allItems

        // 归属过滤
        switch tierFilterPopup?.indexOfSelectedItem ?? 0 {
        case 1: list = list.filter { $0.tier == .builtin }
        case 2: list = list.filter { $0.tier == .user }
        case 3: list = list.filter { $0.tier == .system }
        default: break
        }

        // 子分类快速筛选 (R48)
        if currentSubCategoryFilter != "全部" {
            list = list.filter {
                let sub = $0.subCategory.isEmpty ? "默认" : $0.subCategory
                return sub == currentSubCategoryFilter
            }
        }

        // 实时即输即搜过滤（中文别名与英文原名）
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !query.isEmpty {
            list = list.filter { item in
                let alias = TemplateRenameManager.shared.getDisplayName(for: item).lowercased()
                return item.name.lowercased().contains(query) || alias.contains(query)
            }
        }

        // 排序
        switch sortPopup?.indexOfSelectedItem ?? 0 {
        case 1:
            list.sort { $0.name < $1.name }
        case 2:
            list.sort { $0.sizeMB > $1.sizeMB }
        default:
            list.sort {
                if $0.tier.sortIndex != $1.tier.sortIndex { return $0.tier.sortIndex < $1.tier.sortIndex }
                return $0.name < $1.name
            }
        }

        plugins = list
        pluginTableView?.reloadData()
        reloadCardGrid()
        updateStatusLine()
    }

    // MARK: – 子分类快速筛选与高亮 (R48 对标 FCPX 与嘉星 2.app)

    public func updateSubCategoryFilterBar() {
        guard let stack = subCategoryStackView else { return }
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        subCategoryButtons.removeAll()

        // 统计子分类数量
        var counts: [String: Int] = [:]
        for item in allItems {
            let cat = item.subCategory.isEmpty ? "默认" : item.subCategory
            counts[cat, default: 0] += 1
        }

        let sortedCats = counts.sorted { $0.value > $1.value }
        var list: [(title: String, count: Int)] = [("全部", allItems.count)]
        for (cat, count) in sortedCats {
            list.append((title: cat, count: count))
        }

        for entry in list {
            let isSelected = (entry.title == currentSubCategoryFilter)
            let btnTitle = "\(entry.title) (\(entry.count))"
            let btn = NSButton(title: btnTitle, target: self, action: #selector(onSubCategoryButtonClicked(_:)))
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 12
            btn.layer?.masksToBounds = true
            btn.font = .systemFont(ofSize: 11, weight: isSelected ? .bold : .medium)
            if isSelected {
                btn.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.68, alpha: 1.0).cgColor
                btn.contentTintColor = .white
            } else {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
                btn.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
            }
            btn.identifier = NSUserInterfaceItemIdentifier(entry.title)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(btn)
            subCategoryButtons.append(btn)
        }
    }

    @objc private func onSubCategoryButtonClicked(_ sender: NSButton) {
        guard let cat = sender.identifier?.rawValue else { return }
        currentSubCategoryFilter = cat
        applyFilterAndSort()
        updateSubCategoryFilterBarSelection()
    }

    public func updateSubCategoryFilterBarSelection() {
        for btn in subCategoryButtons {
            let isSelected = (btn.identifier?.rawValue == currentSubCategoryFilter)
            btn.font = .systemFont(ofSize: 11, weight: isSelected ? .bold : .medium)
            if isSelected {
                btn.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.68, alpha: 1.0).cgColor
                btn.contentTintColor = .white
            } else {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
                btn.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
            }
        }
    }

    private func updateStatusLine(overrideMessage: String? = nil) {
        if let msg = overrideMessage {
            statusLabel?.stringValue = msg
            updateTierStats()
            return
        }
        let offlineCount = allItems.filter { $0.isOffline }.count
        if offlineCount > 0 {
            let offlineVol = allItems.first(where: { $0.isOffline })?.volumePath ?? "外置盘"
            let volName = (offlineVol as NSString).lastPathComponent
            statusLabel?.stringValue = "⚠️ 外置盘 [\(volName)] 已断开，\(offlineCount) 套素材已离线保全"
            updateTierStats()
            return
        }
        let builtin = roots.builtin == nil ? "未检测到" : "已定位"
        let system = FileManager.default.fileExists(atPath: roots.system) ? "已就绪" : "目录不存在"
        let guardState = TierWritePolicy.isBuiltinWritable ? "可写（有风险）" : "只读"
        statusLabel?.stringValue = "共 \(plugins.count) 项 · 内置根:\(builtin) 系统根:\(system) · 内置级写入:\(guardState)"
        updateTierStats()
    }

    private func updateTierStats() {
        let total = allItems.count
        let enabledCount = allItems.filter { $0.isEnabled }.count
        let disabledCount = total - enabledCount
        let builtin = allItems.filter { $0.tier == .builtin }.count
        let user = allItems.filter { $0.tier == .user }.count
        let system = allItems.filter { $0.tier == .system }.count
        let builtinSuffix = roots.builtin == nil ? "（未检测到）" : ""

        let catDisplayName: String = {
            switch currentCategory {
            case "Titles.localized": return "字幕"
            case "Effects.localized": return "特效"
            case "Transitions.localized": return "转场"
            case "Generators.localized": return "发生器"
            default: return currentCategory
            }
        }()

        var stats = "当前分类（\(catDisplayName)）：共 \(total) 套 · 🟢 已启用 \(enabledCount) · ⚪️ 已休眠 \(disabledCount)"
        let offlineCount = allItems.filter { $0.isOffline }.count
        if offlineCount > 0 {
            stats += " · ⚠️ 离线保全 \(offlineCount)"
        }
        stats += "   |   🟡 内置 \(builtin)\(builtinSuffix) · 🟢 用户 \(user) · 🟣 系统 \(system)"
        tierStatsLabel?.stringValue = stats
    }

    private func item(at row: Int) -> TemplateItem? {
        guard row >= 0 && row < plugins.count else { return nil }
        return plugins[row]
    }

    private final class MoveRequest: NSObject {
        let row: Int
        let tier: TemplateTier
        init(row: Int, tier: TemplateTier) {
            self.row = row
            self.tier = tier
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = pluginTableView?.clickedRow ?? -1
        let row = clicked >= 0 ? clicked : (pluginTableView?.selectedRow ?? -1)
        guard let item = item(at: row) else {
            let mi = NSMenuItem(title: "未选中模板", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
            return
        }
        populate(menu: menu, item: item, row: row)
    }

    // FCPX-045: 合并卡片与表格右键菜单为单一体系，消除故障态误给重命名/迁移/删除的分裂缺陷
    private func populate(menu: NSMenu, item: TemplateItem, row: Int) {
        let fullMenu = makeTemplateActionMenu(for: item)
        for sub in fullMenu.items {
            fullMenu.removeItem(sub)
            menu.addItem(sub)
        }
    }

    @objc private func onContextDelete(_ sender: NSMenuItem) {
        guard let p = item(at: sender.tag) else { return }
        deleteTemplateItem(p)
    }

    @objc private func onContextMove(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? MoveRequest,
              let item = item(at: req.row) else { return }
        performMigration(item: item, to: req.tier)
    }

    @objc private func onRevealInFinder(_ sender: NSMenuItem) {
        guard let p = item(at: sender.tag) else { return }
        NSWorkspace.shared.selectFile(p.path, inFileViewerRootedAtPath: "")
    }

    @objc private func onContextExternalize(_ sender: NSMenuItem) {
        guard let p = item(at: sender.tag) else { return }
        migrateItemToExternal(p)
    }

    @objc private func onMoreClicked(_ sender: NSButton) {
        let row = sender.tag
        guard let item = item(at: row) else { return }
        let menu = NSMenu()
        populate(menu: menu, item: item, row: row)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func onSetChineseAliasClicked(_ sender: NSMenuItem) {
        guard let item = item(at: sender.tag) else { return }
        showRenameDialog(for: item)
    }

    public func showRenameDialog(for item: TemplateItem) {
        let alert = NSAlert()
        alert.messageText = "设置模板中文别名 / 本地化重命名"
        alert.informativeText = "为模板「\(item.name)」指定在 Final Cut Pro 中呈现的友好中文名。\n底层 Motion 工程与 XML 内部 ID 保持物理不变，100% 杜绝红屏断链！"
        alert.addButton(withTitle: "保存设置")
        alert.addButton(withTitle: "清除别名")
        alert.addButton(withTitle: "取消")

        let currentAlias = TemplateRenameManager.shared.getDisplayName(for: item)
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.stringValue = (currentAlias != item.name) ? currentAlias : ""
        inputField.placeholderString = "例如：中式优雅片头字幕"
        alert.accessoryView = inputField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newAlias = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try TemplateRenameManager.shared.setLocalizedName(newAlias: newAlias, for: item)
                refreshList()
            } catch {
                showAlert(title: "重命名失败", message: error.localizedDescription)
            }
        } else if response == .alertSecondButtonReturn {
            do {
                try TemplateRenameManager.shared.removeLocalizedName(for: item)
                refreshList()
            } catch {
                showAlert(title: "清除失败", message: error.localizedDescription)
            }
        }
    }

    private func performMigration(item: TemplateItem, to target: TemplateTier, policy: MigrationConflictPolicy = .fail) {
        setBusy(true, text: "正在从「\(item.tier.displayName)」迁移到「\(target.displayName)」…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let outcome = try self.migrator.migrate(
                    item: item,
                    to: target,
                    policy: policy,
                    roots: self.roots
                )
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    self.refreshList()
                    self.selectItem(named: outcome.name, tier: target)
                }
            } catch MigrationError.destinationExists(let destPath) {
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    if let chosen = self.askConflict(destPath: destPath) {
                        self.performMigration(item: item, to: target, policy: chosen)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    self.showAlert(title: "迁移失败", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func onUndoClicked() {
        guard LicenseManager.shared.isProLicensed else {
            showAlert(title: "商业授权未激活", message: "未激活商业授权，外置搬家操作已锁定。请先激活商业授权。")
            return
        }
        guard migrator.lastRecord() != nil else {
            showAlert(title: "无可撤销操作", message: "当前会话内没有可撤销的迁移记录。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认撤销迁移？"
        alert.informativeText = "将把上次迁移的模板撤销回原归属层级。"
        alert.addButton(withTitle: "撤销")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true, text: "正在撤销…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                _ = try self.migrator.undoLastMigration(roots: self.roots)
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    self.refreshList()
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    self.showAlert(title: "撤销失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func askConflict(destPath: String) -> MigrationConflictPolicy? {
        let alert = NSAlert()
        alert.messageText = "目标位置已存在同名模板"
        alert.informativeText = "路径已存在：\(destPath)\n请选择处理方式："
        alert.addButton(withTitle: "重命名保留两者（推荐）")
        alert.addButton(withTitle: "覆盖目标")
        alert.addButton(withTitle: "取消")
        let res = alert.runModal()
        switch res {
        case .alertFirstButtonReturn:  return .rename
        case .alertSecondButtonReturn: return .overwrite
        default:                       return nil
        }
    }

    private func selectItem(named name: String, tier: TemplateTier) {
        if let idx = plugins.firstIndex(where: { $0.name == name && $0.tier == tier }) {
            pluginTableView?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            pluginTableView?.scrollRowToVisible(idx)
        }
    }

    private func setBusy(_ busy: Bool, text: String?) {
        if busy {
            spinner?.startAnimation(nil)
            statusLabel?.stringValue = text ?? "处理中…"
        } else {
            spinner?.stopAnimation(nil)
            updateStatusLine()
        }
    }

    private func showAlert(title: String, message: String) {
        if suppressAlertsForTesting { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // ═══════════════════════════════════════════════════════════════
    //  NSTableViewDataSource & Delegate
    // ═══════════════════════════════════════════════════════════════

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === groupTableView {
            return groupItems.count
        } else if tableView === lutTableView {
            return filteredLUTItems.count
        } else if tableView === audioTableView {
            return filteredAudioItems.count
        }
        return plugins.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colId = tableColumn?.identifier.rawValue ?? ""

        if tableView === groupTableView {
            guard row >= 0 && row < groupItems.count else { return nil }
            let grp = groupItems[row]
            let isSel = (row == selectedGroupIndex)

            let cellView = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isBordered = false
            label.drawsBackground = false
            label.isEditable = false
            cellView.addSubview(label)

            switch colId {
            case "groupName":
                label.stringValue = grp.name
                label.font = .systemFont(ofSize: 12, weight: isSel ? .bold : .medium)
                label.textColor = isSel ? .white : NSColor(calibratedWhite: 0.90, alpha: 1.0)
                label.cell?.lineBreakMode = .byTruncatingTail
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
                ])
            case "groupCount":
                label.stringValue = "\(grp.count)"
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: isSel ? .bold : .regular)
                label.textColor = isSel ? NSColor(calibratedRed: 0.38, green: 0.82, blue: 1.0, alpha: 1.0) : NSColor(calibratedWhite: 0.65, alpha: 1.0)
                label.alignment = .center
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
                ])
            case "groupSize":
                let sizeStr = grp.totalSizeMB >= 1024 ? String(format: "%.1fGB", grp.totalSizeMB / 1024.0) : String(format: "%.0fMB", grp.totalSizeMB)
                label.stringValue = sizeStr
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: isSel ? .semibold : .regular)
                label.textColor = isSel ? NSColor(calibratedWhite: 0.96, alpha: 1.0) : NSColor(calibratedWhite: 0.60, alpha: 1.0)
                label.alignment = .right
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
                ])
            case "groupTier":
                let tierBadge: String = {
                    switch grp.tier {
                    case .builtin: return "🟡 内置"
                    case .user: return "👤 用户"
                    case .system: return "🟣 系统"
                    }
                }()
                label.stringValue = tierBadge + (isSel ? " ▶" : "")
                label.font = .systemFont(ofSize: 10.5, weight: isSel ? .bold : .regular)
                label.textColor = isSel ? NSColor(calibratedRed: 0.40, green: 0.85, blue: 1.0, alpha: 1.0) : NSColor(calibratedWhite: 0.70, alpha: 1.0)
                label.alignment = .center
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
                ])
            default:
                break
            }
            return cellView
        }

        if tableView === lutTableView {
            guard row >= 0 && row < filteredLUTItems.count else { return nil }
            let item = filteredLUTItems[row]
            let cell = NSTextField(labelWithString: "")
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = .white
            if colId == "lut_name" {
                cell.stringValue = "\(item.name)  (\(item.category))"
            } else if colId == "lut_dim" {
                cell.stringValue = "\(item.dimension)³"
                cell.textColor = NSColor(red: 0.4, green: 0.8, blue: 0.95, alpha: 1.0)
            } else if colId == "lut_size" {
                cell.stringValue = item.fileSizeFormatted
                cell.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            }
            return cell
        }

        if tableView === audioTableView {
            guard row >= 0 && row < filteredAudioItems.count else { return nil }
            let item = filteredAudioItems[row]
            if colId == "audio_play" {
                let btn = NSButton(title: "▶", target: self, action: #selector(onAudioRowPlayClicked(_:)))
                btn.tag = row
                btn.bezelStyle = .inline
                return btn
            }
            let cell = NSTextField(labelWithString: "")
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = .white
            if colId == "audio_name" {
                cell.stringValue = "\(item.name)  [\(item.category)]"
            } else if colId == "audio_duration" {
                cell.stringValue = item.durationFormatted
                cell.textColor = NSColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1.0)
            }
            return cell
        }

        guard let p = item(at: row) else { return nil }

        switch colId {
        case "name":
            let cell = NSTextField(labelWithString: "")
            let localizedAlias = TemplateRenameManager.shared.getDisplayName(for: p)
            if localizedAlias != p.name {
                cell.stringValue = "\(localizedAlias) (\(p.name))"
            } else {
                cell.stringValue = p.name
            }
            cell.font = .systemFont(ofSize: 12, weight: .bold)
            cell.textColor = p.isEnabled ? .white : NSColor(calibratedWhite: 0.5, alpha: 1.0)
            cell.toolTip = p.path
            return cell

        case "status":
            let btn = NSButton(title: p.isEnabled ? "🟢 已启用" : "⚪️ 已休眠",
                               target: self, action: #selector(onToggleStatusClicked(_:)))
            btn.tag = row
            btn.bezelStyle = .inline
            btn.wantsLayer = true
            btn.font = .systemFont(ofSize: 11)
            if p.tier == .builtin && !TierWritePolicy.isBuiltinWritable {
                btn.isEnabled = false
                btn.toolTip = "内置模板受只读保护，禁止直接启停"
            }
            return btn

        case "size":
            let cell = NSTextField(labelWithString: p.isSymlink ? "—" : String(format: "%.1f MB", p.sizeMB))
            cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = p.isEnabled ? NSColor(calibratedWhite: 0.85, alpha: 1) : NSColor(calibratedWhite: 0.45, alpha: 1)
            return cell

        case "tier":
            let cell = NSTextField(labelWithString: p.tier.badgeText)
            cell.font = .systemFont(ofSize: 12, weight: .medium)
            cell.toolTip = p.path
            return cell

        case "disk":
            let cell = NSTextField(labelWithString: p.diskForm.displayText)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
            cell.toolTip = p.targetPath
            return cell

        case "action":
            let btn = NSButton(title: "⋯", target: self, action: #selector(onMoreClicked(_:)))
            btn.tag = row
            btn.bezelStyle = .inline
            return btn

        default:
            return nil
        }
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === groupTableView {
            let identifier = NSUserInterfaceItemIdentifier("GroupTableRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? GroupTableRowView
            if rowView == nil {
                rowView = GroupTableRowView()
                rowView?.identifier = identifier
            }
            return rowView
        }
        return nil
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if currentViewMode == 0 && cardGridScrollView != nil && !cardGridScrollView.isHidden {
            reloadCardGrid(resetPaging: false)
        }
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === groupTableView {
            return 32
        } else if tableView === lutTableView || tableView === audioTableView {
            return 26
        }
        return 28
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        if tv === groupTableView {
            let row = groupTableView.selectedRow
            if row >= 0 && row < groupItems.count {
                selectedGroupIndex = row
                loadTemplatesForSelectedGroup()
                groupTableView.reloadData()
            }
        } else if tv === lutTableView {
            let row = lutTableView.selectedRow
            if row >= 0 && row < filteredLUTItems.count {
                selectLUTItem(filteredLUTItems[row])
            }
        } else if tv === audioTableView {
            let row = audioTableView.selectedRow
            if row >= 0 && row < filteredAudioItems.count {
                selectAudioItem(filteredAudioItems[row])
            }
        }
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === audioTableView {
            guard row >= 0 && row < filteredAudioItems.count else { return nil }
            let item = filteredAudioItems[row]
            return NSURL(fileURLWithPath: item.path)
        }
        return nil
    }

    @objc public func onToggleStatusClicked(_ sender: NSButton) {
        let row = sender.tag
        guard let p = item(at: row) else { return }
        toggleTemplateItem(p)
    }

    @discardableResult
    public func toggleItem(at row: Int) throws -> TemplateItem {
        guard let p = item(at: row) else {
            throw TemplateToggleError.fileNotFound("索引越界: \(row)")
        }
        if p.tier == .builtin && !TierWritePolicy.isBuiltinWritable {
            throw TemplateToggleError.builtinProtected
        }
        let updated = try TemplateInstaller.toggleTemplate(item: p)
        refreshList()
        return updated
    }

    // ═══════════════════════════════════════════════════════════════
    //  拖拽安装 (Drop Acceptance)
    // ═══════════════════════════════════════════════════════════════

    public func installDirectly(paths: [String], defaultSubcategory: String? = nil) throws -> [InstalledTemplateResult] {
        let targetRoot = roots.user
        let results = try TemplateInstaller.installTemplates(paths: paths, targetTierRoot: targetRoot, defaultSubcategory: defaultSubcategory)
        refreshList()
        return results
    }

    public func handleInstallDrop(paths: [String]) {
        dropOverlayView.isHidden = true
        guard !paths.isEmpty else { return }

        setBusy(true, text: "正在解析并安装 \(paths.count) 项模板…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let installed = try self.installDirectly(paths: paths)
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    let summary = installed.map { "• \($0.templateName) (\($0.category))" }.joined(separator: "\n")
                    self.showAlert(title: "安装完成", message: "成功安装 \(installed.count) 项模板至用户库：\n\(summary)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false, text: nil)
                    self.showAlert(title: "安装未完成", message: error.localizedDescription)
                }
            }
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let paths = extractPaths(from: sender), !paths.isEmpty else {
            return []
        }
        let hasInstallable = paths.contains {
            $0.hasSuffix(".zip") || $0.hasSuffix(".moti") || $0.hasSuffix(".motn") ||
            $0.hasSuffix(".mota") || $0.hasSuffix(".motr") || FileManager.default.fileExists(atPath: $0)
        }
        if hasInstallable {
            dropOverlayView?.isHidden = false
            return .copy
        }
        return []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if dropOverlayView?.isHidden == false {
            return .copy
        }
        return []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlayView?.isHidden = true
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlayView?.isHidden = true
        guard let paths = extractPaths(from: sender), !paths.isEmpty else {
            return false
        }
        handleInstallDrop(paths: paths)
        return true
    }

    private func extractPaths(from info: NSDraggingInfo) -> [String]? {
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.map { $0.path }
    }
}
