import AppKit

// ═══════════════════════════════════════════════════════════════
//  SettingsWindow.swift —— 偏好设置与系统环境体检工作台（R50 架构整合）
//
//  架构重构（R50）：
//    1. 核心视图升级为内嵌工作台控件 `SettingsDashboardView`，
//       直接内嵌于 `AssetHubView` 右侧主视口（Tab 8，Tag 11），
//       彻底废除切屏割裂的独立模态弹窗。
//    2. 兼容保留 `SettingsWindowController` 包装器，
//       保证旧调用链与快捷键平滑兼容。
// ═══════════════════════════════════════════════════════════════

public final class SettingsDashboardView: NSView {

    // MARK: – UI Controls
    public var readonlyRadio: NSButton!
    public var writableRadio: NSButton!
    public var statusBadge: NSTextField!
    public var statusLabel: NSTextField!
    public var forceReadOnlyButton: NSButton!

    public var envStatusLabel: NSTextField!
    public var recheckButton: NSButton!
    public var envBadge: NSTextField!

    public var storageStatusSummaryLabel: NSTextField!
    public var workspaceStatusSummaryLabel: NSTextField!

    /// 自动化测试时抑制弹窗以防阻塞 Harness
    public var suppressAlertsForTesting: Bool = false

    // MARK: – Init
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        refreshData()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        refreshData()
    }

    // MARK: – UI Setup
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.40).cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48)
        ])

        // 1. 顶部工作台标题栏
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(headerRow)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        headerRow.addArrangedSubview(iconView)

        let titleVStack = NSStackView()
        titleVStack.orientation = .vertical
        titleVStack.alignment = .leading
        titleVStack.spacing = 2

        let mainTitle = NSTextField(labelWithString: "偏好设置与系统环境体检工作台")
        mainTitle.font = .systemFont(ofSize: 18, weight: .bold)
        mainTitle.textColor = .white
        titleVStack.addArrangedSubview(mainTitle)

        let subTitle = NSTextField(labelWithString: "配置系统内置模板只读安全策略 · 便携式零依赖运行时与 Metal 硬件加速自检")
        subTitle.font = .systemFont(ofSize: 12, weight: .regular)
        subTitle.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        titleVStack.addArrangedSubview(subTitle)

        headerRow.addArrangedSubview(titleVStack)

        // 2. 卡片 1: 内置级写入权限与安全策略 (Builtin Tier Write Policy)
        let card1 = makeCardView()
        contentStack.addArrangedSubview(card1)
        card1.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let card1Stack = NSStackView()
        card1Stack.orientation = .vertical
        card1Stack.alignment = .leading
        card1Stack.spacing = 10
        card1Stack.translatesAutoresizingMaskIntoConstraints = false
        card1.addSubview(card1Stack)

        NSLayoutConstraint.activate([
            card1Stack.topAnchor.constraint(equalTo: card1.topAnchor, constant: 14),
            card1Stack.leadingAnchor.constraint(equalTo: card1.leadingAnchor, constant: 16),
            card1Stack.trailingAnchor.constraint(equalTo: card1.trailingAnchor, constant: -16),
            card1Stack.bottomAnchor.constraint(equalTo: card1.bottomAnchor, constant: -14)
        ])

        let c1Header = NSStackView()
        c1Header.orientation = .horizontal
        c1Header.spacing = 8
        c1Header.alignment = .centerY

        let c1Title = NSTextField(labelWithString: "内置级写入权限策略 (Tier Write Policy)")
        c1Title.font = .systemFont(ofSize: 14, weight: .bold)
        c1Title.textColor = .white
        c1Header.addArrangedSubview(c1Title)

        statusBadge = NSTextField(labelWithString: "🔒 安全只读保护中")
        statusBadge.font = .systemFont(ofSize: 11, weight: .bold)
        statusBadge.textColor = NSColor.systemGreen
        c1Header.addArrangedSubview(statusBadge)
        card1Stack.addArrangedSubview(c1Header)

        let hint = NSTextField(wrappingLabelWithString:
            "内置级 = FCPX 应用程序包内部 (METemplates)。系统盘默认只读，只影响物理写操作，不影响扫描、索引与素材展示。")
        hint.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
        hint.font = .systemFont(ofSize: 12)
        card1Stack.addArrangedSubview(hint)

        readonlyRadio = NSButton(radioButtonWithTitle: "只读安全保护模式（默认，强烈推荐）",
                                 target: self, action: #selector(onRadioChanged(_:)))
        readonlyRadio.tag = 0
        readonlyRadio.font = .systemFont(ofSize: 12, weight: .medium)
        card1Stack.addArrangedSubview(readonlyRadio)

        writableRadio = NSButton(radioButtonWithTitle: "可写高级模式（允许写入 FCPX 应用内部包，有损坏应用签名风险）",
                                 target: self, action: #selector(onRadioChanged(_:)))
        writableRadio.tag = 1
        writableRadio.font = .systemFont(ofSize: 12, weight: .medium)
        card1Stack.addArrangedSubview(writableRadio)

        let c1ActionRow = NSStackView()
        c1ActionRow.orientation = .horizontal
        c1ActionRow.spacing = 10
        c1ActionRow.alignment = .centerY

        statusLabel = NSTextField(labelWithString: "当前状态：\(TierWritePolicy.statusText)")
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        c1ActionRow.addArrangedSubview(statusLabel)

        forceReadOnlyButton = NSButton(title: "改回安全只读", target: self, action: #selector(forceReadOnly(_:)))
        forceReadOnlyButton.bezelStyle = .rounded
        forceReadOnlyButton.font = .systemFont(ofSize: 11, weight: .medium)
        c1ActionRow.addArrangedSubview(forceReadOnlyButton)
        card1Stack.addArrangedSubview(c1ActionRow)

        let warningBox = NSView()
        warningBox.wantsLayer = true
        warningBox.layer?.cornerRadius = 6
        warningBox.layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.16, blue: 0.08, alpha: 0.6).cgColor
        warningBox.layer?.borderWidth = 1.0
        warningBox.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
        warningBox.translatesAutoresizingMaskIntoConstraints = false
        card1Stack.addArrangedSubview(warningBox)
        warningBox.widthAnchor.constraint(equalTo: card1Stack.widthAnchor).isActive = true

        let warningLabel = NSTextField(wrappingLabelWithString:
            "⚠️ 写入内置级会直接修改 FCPX.app 内部结构，可能导致 macOS Gatekeeper 安全隔离拦截、应用签名损坏或 FCPX 启动闪退。更安全的专业方案：一键迁移至「系统」级 (~/Movies) 或「外置卷」。")
        warningLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.40, alpha: 1.0)
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningBox.addSubview(warningLabel)

        NSLayoutConstraint.activate([
            warningLabel.topAnchor.constraint(equalTo: warningBox.topAnchor, constant: 8),
            warningLabel.leadingAnchor.constraint(equalTo: warningBox.leadingAnchor, constant: 10),
            warningLabel.trailingAnchor.constraint(equalTo: warningBox.trailingAnchor, constant: -10),
            warningLabel.bottomAnchor.constraint(equalTo: warningBox.bottomAnchor, constant: -8)
        ])

        // 3. 卡片 2: 运行环境、硬件加速与便携化自检
        let card2 = makeCardView()
        contentStack.addArrangedSubview(card2)
        card2.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let card2Stack = NSStackView()
        card2Stack.orientation = .vertical
        card2Stack.alignment = .leading
        card2Stack.spacing = 10
        card2Stack.translatesAutoresizingMaskIntoConstraints = false
        card2.addSubview(card2Stack)

        NSLayoutConstraint.activate([
            card2Stack.topAnchor.constraint(equalTo: card2.topAnchor, constant: 14),
            card2Stack.leadingAnchor.constraint(equalTo: card2.leadingAnchor, constant: 16),
            card2Stack.trailingAnchor.constraint(equalTo: card2.trailingAnchor, constant: -16),
            card2Stack.bottomAnchor.constraint(equalTo: card2.bottomAnchor, constant: -14)
        ])

        let c2Header = NSStackView()
        c2Header.orientation = .horizontal
        c2Header.spacing = 10
        c2Header.alignment = .centerY

        let c2Title = NSTextField(labelWithString: "运行环境、硬件加速与便携化自检 (D-82 / D-83)")
        c2Title.font = .systemFont(ofSize: 14, weight: .bold)
        c2Title.textColor = .white
        c2Header.addArrangedSubview(c2Title)

        envBadge = NSTextField(labelWithString: "🟢 便携运行时就绪")
        envBadge.font = .systemFont(ofSize: 11, weight: .bold)
        envBadge.textColor = NSColor.systemGreen
        c2Header.addArrangedSubview(envBadge)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c2Header.addArrangedSubview(spacer)

        recheckButton = NSButton(title: " 重新自检", target: self, action: #selector(onRecheckClicked(_:)))
        recheckButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        recheckButton.bezelStyle = .rounded
        recheckButton.font = .systemFont(ofSize: 11, weight: .medium)
        c2Header.addArrangedSubview(recheckButton)
        card2Stack.addArrangedSubview(c2Header)
        c2Header.widthAnchor.constraint(equalTo: card2Stack.widthAnchor).isActive = true

        let envBox = NSView()
        envBox.wantsLayer = true
        envBox.layer?.cornerRadius = 6
        envBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.85).cgColor
        envBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        envBox.layer?.borderWidth = 1.0
        envBox.translatesAutoresizingMaskIntoConstraints = false
        card2Stack.addArrangedSubview(envBox)
        envBox.widthAnchor.constraint(equalTo: card2Stack.widthAnchor).isActive = true

        envStatusLabel = NSTextField(wrappingLabelWithString: "")
        envStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        envStatusLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        envStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        envBox.addSubview(envStatusLabel)

        NSLayoutConstraint.activate([
            envStatusLabel.topAnchor.constraint(equalTo: envBox.topAnchor, constant: 10),
            envStatusLabel.leadingAnchor.constraint(equalTo: envBox.leadingAnchor, constant: 12),
            envStatusLabel.trailingAnchor.constraint(equalTo: envBox.trailingAnchor, constant: -12),
            envStatusLabel.bottomAnchor.constraint(equalTo: envBox.bottomAnchor, constant: -10)
        ])

        // 4. 卡片 3: 外置移动存储与情境工作区协同说明 (Storage & Workspace Synergy)
        let card3 = makeCardView()
        contentStack.addArrangedSubview(card3)
        card3.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let card3Stack = NSStackView()
        card3Stack.orientation = .vertical
        card3Stack.alignment = .leading
        card3Stack.spacing = 8
        card3Stack.translatesAutoresizingMaskIntoConstraints = false
        card3.addSubview(card3Stack)

        NSLayoutConstraint.activate([
            card3Stack.topAnchor.constraint(equalTo: card3.topAnchor, constant: 14),
            card3Stack.leadingAnchor.constraint(equalTo: card3.leadingAnchor, constant: 16),
            card3Stack.trailingAnchor.constraint(equalTo: card3.trailingAnchor, constant: -16),
            card3Stack.bottomAnchor.constraint(equalTo: card3.bottomAnchor, constant: -14)
        ])

        let c3Title = NSTextField(labelWithString: "外置存储搬家与情境隔离联动机制")
        c3Title.font = .systemFont(ofSize: 14, weight: .bold)
        c3Title.textColor = .white
        card3Stack.addArrangedSubview(c3Title)

        storageStatusSummaryLabel = NSTextField(wrappingLabelWithString:
            "• 外置移动存储透明穿透：搬移至外置高速卡（如 128G SSD）后在系统盘建立 POSIX 标准软链接，FCPX 底层透明解析调用，成图渲染与系统盘完全无异；")
        storageStatusSummaryLabel.font = .systemFont(ofSize: 11)
        storageStatusSummaryLabel.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        card3Stack.addArrangedSubview(storageStatusSummaryLabel)

        workspaceStatusSummaryLabel = NSTextField(wrappingLabelWithString:
            "• 工作区情境隔离：使用 .disabled 后缀物理屏蔽非当前情境插件，0 字节占用 FCPX 内存，启动提速 5~10 倍，切回情境瞬间秒级恢复。")
        workspaceStatusSummaryLabel.font = .systemFont(ofSize: 11)
        workspaceStatusSummaryLabel.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        card3Stack.addArrangedSubview(workspaceStatusSummaryLabel)
    }

    private func makeCardView() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.75).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    // MARK: – 数据刷新
    public func refreshData() {
        let writable = TierWritePolicy.isBuiltinWritable
        readonlyRadio?.state = writable ? .off : .on
        writableRadio?.state = writable ? .on : .off
        statusLabel?.stringValue = "当前状态：\(TierWritePolicy.statusText)"
        statusLabel?.textColor = writable ? .systemOrange : .systemGreen

        if writable {
            statusBadge?.stringValue = "⚠️ 开启可写（高风险）"
            statusBadge?.textColor = .systemOrange
        } else {
            statusBadge?.stringValue = "🔒 安全只读保护中"
            statusBadge?.textColor = .systemGreen
        }

        let cfg = AppConfig.shared
        let mode = cfg.isPortableEnvironment ? "🟢 零依赖便携运行时就绪 (Zero-Dependency Standalone)" : "🟡 主机系统环境 (Host-System)"
        let psd = cfg.hasPsdTools ? "🟢 psd-tools 核心引擎已就绪" : "🔴 缺失 psd-tools"
        let lines = [
            "应用版本: \(cfg.appVersionString)",
            "便携状态: \(mode)",
            "硬件加速: \(cfg.hardwareAccelerationSummary)",
            "核心依赖: \(psd)",
            "Python 路径: \(cfg.pythonPath)",
            "CLI Bridge: \(cfg.bridgeScriptPath)"
        ]
        envStatusLabel?.stringValue = lines.joined(separator: "\n")
        envBadge?.stringValue = cfg.isPortableEnvironment ? "🟢 便携运行时就绪" : "🟡 系统运行时"
        envBadge?.textColor = cfg.isPortableEnvironment ? .systemGreen : .systemYellow
    }

    // MARK: – Actions
    @objc private func onRadioChanged(_ sender: NSButton) {
        if sender.tag == 1 {
            guard confirmWritable() else {
                refreshData()
                return
            }
            TierWritePolicy.setBuiltinWritable(true)
        } else {
            TierWritePolicy.setBuiltinWritable(false)
        }
        refreshData()
        NotificationCenter.default.post(name: .tierWritePolicyChanged, object: nil)
    }

    @objc private func forceReadOnly(_ sender: Any?) {
        TierWritePolicy.setBuiltinWritable(false)
        refreshData()
        NotificationCenter.default.post(name: .tierWritePolicyChanged, object: nil)
    }

    @objc private func onRecheckClicked(_ sender: Any?) {
        refreshData()
    }

    private func confirmWritable() -> Bool {
        if suppressAlertsForTesting { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "开启内置级写入会修改 FCPX 应用包"
        alert.informativeText = """
        写入内置级会修改 FCPX 应用程序包内部文件，可能导致应用签名失效、Gatekeeper 拦截、FCPX 无法启动或内置模板全部不加载。更安全的替代方案是迁移到「系统」级。是否继续？
        """
        alert.addButton(withTitle: "继续（开启可写）")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// ═══════════════════════════════════════════════════════════════
//  SettingsWindowController —— 兼容保留控制器（桥接内嵌工作台）
// ═══════════════════════════════════════════════════════════════

public final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = SettingsWindowController()

    public private(set) var dashboardView: SettingsDashboardView!

    private convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "FCPX Studio Pro 偏好设置与环境体检"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        buildUI()
        win.center()
    }

    private func buildUI() {
        guard let win = window else { return }
        dashboardView = SettingsDashboardView(frame: win.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 620))
        dashboardView.autoresizingMask = [.width, .height]
        win.contentView = dashboardView
    }

    public func show() {
        dashboardView?.refreshData()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

public extension Notification.Name {
    /// 内置级写入权限变化（素材库据此刷新「🔒 只读」状态）
    static let tierWritePolicyChanged = Notification.Name("FCPXStudioTierWritePolicyChanged")
}
