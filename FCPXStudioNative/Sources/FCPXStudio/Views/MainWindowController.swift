import AppKit
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════
//  MainWindowController
//  原生态 macOS 插口架构主控制器
// ═══════════════════════════════════════════════════════════════

public final class MainWindowController: NSWindowController,
                                          NSWindowDelegate,
                                          NSTableViewDataSource,
                                          NSTableViewDelegate {

    // MARK: – Layout Constants
    private let TOP_H: CGFloat   = 50
    private let LEFT_W: CGFloat  = 230
    private let RIGHT_W: CGFloat = 360

    // MARK: – Subviews
    public var segmentedControl: NSSegmentedControl!
    public var engine1Container: NSView!
    public var psdTableView: NSTableView!
    public var canvasView: InfiniteCanvasView!
    public var canvasBackdropView: NSVisualEffectView!
    public var inspectorView: InspectorView!
    public var assetHubView: AssetHubView!
    /// R43：顶部工作区情境胶囊指示栏
    public var profileBadgeButton: NSButton!
    /// R45：顶部直观对比模式切换控件
    public var comparisonSegmentedControl: NSSegmentedControl!
    /// R46：当前批量导出进度面板
    public private(set) var activeExportSheet: BatchExportProgressSheet?

    // MARK: – State
    public var psdFiles: [String] = []
    public var currentPsdPath: String?
    /// R33 / A-70：是否把隐藏图层作为 visible=false 的预览层一起解析（默认关）
    public var includeHiddenLayers: Bool = false
    /// R42 / A-72：解析完成回调（供自动化 Harness 与 UI 监听）
    public var onParseCompleted: ((PSDParseResult) -> Void)?

    // MARK: – Init
    public convenience init() {
        let screen = NSScreen.screens.first(where: { $0.frame.origin.x == 0 })
                     ?? NSScreen.screens[0]
        let vf = screen.visibleFrame

        let winW = min(1200, vf.width  - 40)
        let winH = min(780,  vf.height - 40)
        let winX = vf.minX + (vf.width  - winW) / 2.0
        let winY = vf.minY + (vf.height - winH) / 2.0

        let win = NSWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "FCPX Studio Pro (macOS 原生旗舰版)"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.95)
        win.isReleasedWhenClosed = false
        win.collectionBehavior   = [.managed]
        win.level                = .normal

        // R31 / A-61：把 contentView 换成可接收文件拖放的子类。
        // NSWindow 默认不接收拖放，所以旧版拖 PSD 进来「完全没反应」。
        let dropView = DropAcceptingView(frame: win.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: winW, height: winH))
        dropView.autoresizingMask = [.width, .height]
        win.contentView = dropView

        self.init(window: win)
        win.delegate = self

        dropView.onFilesDropped = { [weak self] paths in
            self?.importPsdPaths(paths)
        }
        dropView.onFontsDropped = { [weak self] paths in
            self?.handleDroppedFonts(paths)
        }

        // ★ 核心：立即构建 UI 并填充数据
        buildUI()

        // R51: 强化 Dock 图标在主窗口创建时的即时注入
        if NSApp.applicationIconImage == nil {
            if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let iconImg = NSImage(contentsOfFile: iconPath) {
                NSApp.applicationIconImage = iconImg
            } else if let iconImg = NSImage(contentsOfFile: "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/FCPX Studio Pro.app/Contents/Resources/AppIcon.icns") {
                NSApp.applicationIconImage = iconImg
            }
        }

        // `--engine2` 启动参数：直接进入素材库页（用于自动化真机验收，正常用户不受影响）
        if ProcessInfo.processInfo.arguments.contains("--engine2") {
            segmentedControl?.selectedSegment = 1
            showEngine(index: 1)
        }

        let args = ProcessInfo.processInfo.arguments
        // `--open <psd 路径>` 启动参数：走与 ⌘O 完全相同的单文件导入路径
        // （importPsdPaths），用于 A-62 无辅助功能权限时的自动化真机验收。
        if let idx = args.firstIndex(of: "--open"), idx + 1 < args.count {
            let target = (args[idx + 1] as NSString).expandingTildeInPath
            DispatchQueue.main.async { [weak self] in
                self?.importPsdPaths([target])
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.psdFiles.isEmpty else { return }
                self.loadPsdDirectory(AppConfig.shared.defaultPsdDir)
            }
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        if engine1Container == nil {
            buildUI()
        }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: – Build UI
    private func buildUI() {
        guard let win = window, let root = win.contentView else { return }

        let totalW = root.bounds.width
        let totalH = root.bounds.height
        let bodyH  = totalH - TOP_H

        // 1. 顶部模式切换 Bar（NSVisualEffectView 毛玻璃质感）
        let topBar = NSVisualEffectView(frame: NSRect(x: 0, y: bodyH, width: totalW, height: TOP_H))
        topBar.autoresizingMask = [.width, .minYMargin]
        topBar.material = .sidebar
        topBar.blendingMode = .behindWindow
        topBar.state = .active
        topBar.appearance = NSAppearance(named: .darkAqua)
        topBar.wantsLayer = true
        topBar.layer?.borderWidth = 0.5
        topBar.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        let trafficLightPadding: CGFloat = 84
        let segW: CGFloat = 390
        let segH: CGFloat = 28
        segmentedControl = NSSegmentedControl(
            labels: ["  设计器 (PSD → Motion)",
                     "  素材库与管理中心"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onSegmentChanged)
        )
        segmentedControl.setImage(NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil), forSegment: 0)
        segmentedControl.setImage(NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil), forSegment: 1)
        segmentedControl.selectedSegment = 0
        segmentedControl.frame = NSRect(x: trafficLightPadding, y: (TOP_H - segH) / 2.0, width: segW, height: segH)
        segmentedControl.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        topBar.addSubview(segmentedControl)

        // 顶部工作区情境胶囊状态栏 (R43)
        let badgeW: CGFloat = 160
        let badgeH: CGFloat = 28
        let badgeX: CGFloat = totalW - badgeW - 16
        let badgeY: CGFloat = (TOP_H - badgeH) / 2.0
        profileBadgeButton = NSButton(title: "[🌟 全量模式]", target: self, action: #selector(onProfileBadgeClicked))
        profileBadgeButton.frame = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        profileBadgeButton.bezelStyle = .regularSquare
        profileBadgeButton.isBordered = false
        profileBadgeButton.wantsLayer = true
        profileBadgeButton.layer?.cornerRadius = 14
        profileBadgeButton.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1.0).cgColor
        profileBadgeButton.layer?.borderWidth = 1.0
        profileBadgeButton.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.45, blue: 0.75, alpha: 0.8).cgColor
        profileBadgeButton.font = .systemFont(ofSize: 11, weight: .bold)
        profileBadgeButton.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1.0, alpha: 1.0)
        profileBadgeButton.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        topBar.addSubview(profileBadgeButton)
        updateActiveProfileBadge()

        // 顶部直观对比模式切换分段控制器 (R45)
        let compW: CGFloat = 300
        let compH: CGFloat = 28
        let compX = badgeX - compW - 14
        comparisonSegmentedControl = NSSegmentedControl(
            labels: ["画板", "卷帘对比", "并排", "⌥透视"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onComparisonModeChanged)
        )
        comparisonSegmentedControl.setImage(NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil), forSegment: 0)
        comparisonSegmentedControl.setImage(NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: nil), forSegment: 1)
        comparisonSegmentedControl.setImage(NSImage(systemSymbolName: "rectangle.split.2x1.fill", accessibilityDescription: nil), forSegment: 2)
        comparisonSegmentedControl.setImage(NSImage(systemSymbolName: "eye", accessibilityDescription: nil), forSegment: 3)
        comparisonSegmentedControl.selectedSegment = 0
        comparisonSegmentedControl.frame = NSRect(x: compX, y: (TOP_H - compH) / 2.0, width: compW, height: compH)
        comparisonSegmentedControl.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        comparisonSegmentedControl.toolTip = "切换 PSD 原始成图 vs 实时转出直观对比 (或长按 ⌥ 键透视原图)"
        topBar.addSubview(comparisonSegmentedControl)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateActiveProfileBadge),
            name: WorkspaceProfileManager.didChangeActiveProfileNotification,
            object: nil
        )

        root.addSubview(topBar)

        // 2. 主体容器
        let body = makeView(
            frame: NSRect(x: 0, y: 0, width: totalW, height: bodyH),
            bg: .clear,
            mask: [.width, .height]
        )
        root.addSubview(body)

        // 3. 构建两大引擎
        buildEngine1(in: body, w: totalW, h: bodyH)
        buildEngine2(in: body, w: totalW, h: bodyH)

        showEngine(index: 0)
    }

    // MARK: – Engine 1: PSD -> Motion
    private func buildEngine1(in parent: NSView, w: CGFloat, h: CGFloat) {
        engine1Container = makeView(
            frame: NSRect(x: 0, y: 0, width: w, height: h),
            bg: .clear,
            mask: [.width, .height]
        )

        // ── 1. 中间：无限画布（包裹 NSVisualEffectView 磨砂背板） ──
        let midW = w - LEFT_W - RIGHT_W
        canvasBackdropView = NSVisualEffectView(frame: NSRect(x: LEFT_W, y: 0, width: midW, height: h))
        canvasBackdropView.autoresizingMask = [.width, .height]
        canvasBackdropView.material = .underWindowBackground
        canvasBackdropView.blendingMode = .behindWindow
        canvasBackdropView.state = .active
        canvasBackdropView.appearance = NSAppearance(named: .darkAqua)

        canvasView = InfiniteCanvasView(frame: canvasBackdropView.bounds)
        canvasView.autoresizingMask = [.width, .height]
        canvasBackdropView.addSubview(canvasView)
        engine1Container.addSubview(canvasBackdropView)

        // ── 2. 左侧：PSD 批处理列表（毛玻璃质感） ──
        let leftPanel = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: LEFT_W, height: h))
        leftPanel.autoresizingMask = [.height, .maxXMargin]
        leftPanel.material = .sidebar
        leftPanel.blendingMode = .behindWindow
        leftPanel.state = .active
        leftPanel.appearance = NSAppearance(named: .darkAqua)

        let leftTitle = NSTextField(labelWithString: "素材批处理列表 (50)")
        leftTitle.frame = NSRect(x: 12, y: h - 36, width: LEFT_W - 24, height: 22)
        leftTitle.font = .systemFont(ofSize: 12, weight: .bold)
        leftTitle.textColor = .white
        leftPanel.addSubview(leftTitle)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: LEFT_W, height: h - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        psdTableView = NSTableView(frame: scroll.bounds)
        psdTableView.autoresizingMask = [.width, .height]
        psdTableView.backgroundColor = .clear
        psdTableView.headerView = nil
        psdTableView.intercellSpacing = NSSize(width: 0, height: 4)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.title = "PSD 文件"
        col.width = LEFT_W - 20
        psdTableView.addTableColumn(col)
        psdTableView.dataSource = self
        psdTableView.delegate   = self
        scroll.documentView = psdTableView

        leftPanel.addSubview(scroll)
        engine1Container.addSubview(leftPanel)

        // ── 3. 右侧：属性检查器（顶层不透明） ──
        inspectorView = InspectorView(frame: NSRect(x: w - RIGHT_W, y: 0, width: RIGHT_W, height: h))
        inspectorView.autoresizingMask = [.height, .minXMargin]
        engine1Container.addSubview(inspectorView)

        // ── 插口事件绑定 ──
        canvasView.onLayerMoved = { [weak self] layer in
            self?.inspectorView.updateFromCanvasMove(layer)
        }
        canvasView.onLayerSelected = { [weak self] idx in
            self?.inspectorView.selectLayer(at: idx)
        }
        inspectorView.onLayerModified = { [weak self] _ in
            self?.canvasView.needsDisplay = true
        }
        inspectorView.onLayerVisibilityChanged = { [weak self] _ in
            self?.canvasView.needsDisplay = true
        }
        inspectorView.onAllVisibilityToggled = { [weak self] _ in
            self?.canvasView.needsDisplay = true
        }
        inspectorView.onLayerLockChanged = { [weak self] _ in
            self?.canvasView.needsDisplay = true
        }
        inspectorView.onHiddenLayersChanged = { [weak self] on in
            self?.setIncludeHiddenLayers(on)
        }
        inspectorView.onSaveTemplate = { [weak self] in
            self?.saveCurrentTemplate()
        }
        inspectorView.onBatchExport = { [weak self] in
            self?.batchExportAllTemplates()
        }
        inspectorView.onFontsDropped = { [weak self] paths in
            self?.handleDroppedFonts(paths)
        }

        parent.addSubview(engine1Container)
    }

    // MARK: – Engine 2: Asset Hub
    private func buildEngine2(in parent: NSView, w: CGFloat, h: CGFloat) {
        assetHubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        assetHubView.autoresizingMask = [.width, .height]
        assetHubView.isHidden = true
        assetHubView.onOpenTemplateInDesigner = { [weak self] _ in
            self?.showEngine(index: 0)
        }
        parent.addSubview(assetHubView)
    }

    // MARK: – Segment Toggle
    @objc private func onSegmentChanged() {
        showEngine(index: segmentedControl.selectedSegment)
    }

    // MARK: - R45 对比模式切换
    @objc private func onComparisonModeChanged() {
        guard let canvas = canvasView, let seg = comparisonSegmentedControl else { return }
        switch seg.selectedSegment {
        case 0:
            canvas.comparisonMode = .off
        case 1:
            canvas.comparisonMode = .splitCurtain
        case 2:
            canvas.comparisonMode = .sideBySide
        case 3:
            canvas.comparisonMode = .peekHold
        default:
            canvas.comparisonMode = .off
        }
    }

    private func showEngine(index: Int) {
        engine1Container?.isHidden = (index != 0)
        assetHubView?.isHidden     = (index != 1)
        if index == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.canvasView?.fitArtboard()
            }
        } else {
            assetHubView?.refreshList()
        }
    }

    // MARK: – PSD Loading（目录 / 单文件 / 拖放统一入口）

    public func loadPsdDirectory(_ dir: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let psds = files.sorted().filter { $0.hasSuffix(".psd") && !$0.hasPrefix(".") }
                        .map { "\(dir)/\($0)" }
        guard !psds.isEmpty else { return }
        psdFiles = psds
        psdTableView?.reloadData()
        psdTableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        selectPsdFile(at: 0)
    }

    /// A-61 / A-62 共用入口：拖放、⌘O、⇧⌘O 全部走这里。
    /// 规则：单文件**追加**不清空；目录递归；混合逐项分类；重复路径不重复添加；
    ///      非 psd 明确提示，不崩溃、不静默。
    @objc public func importPsdPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let plan = PSDImportPlanner.plan(paths: paths, existing: psdFiles)

        if !plan.added.isEmpty {
            psdFiles.append(contentsOf: plan.added)
            psdTableView?.reloadData()
            if let lastIndex = psdFiles.indices.last {
                psdTableView?.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
                psdTableView?.scrollRowToVisible(lastIndex)
                if currentPsdPath != psdFiles[lastIndex] {
                    selectPsdFile(at: lastIndex)
                }
            }
        }

        var notes: [String] = []
        if !plan.duplicates.isEmpty {
            notes.append("\(plan.duplicates.count) 个文件已在列表中，未重复添加。")
        }
        if plan.hasEmptyDirectories {
            notes.append("以下文件夹内没有 .psd 文件：\n" + plan.emptyDirectories.joined(separator: "\n"))
        }
        if plan.hasRejected {
            notes.append("仅支持 .psd 文件或包含 .psd 的文件夹，已忽略：\n"
                         + plan.rejected.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
        }
        if !notes.isEmpty {
            showAlert(title: "导入提示", msg: notes.joined(separator: "\n\n"))
        }
    }

    @objc public func openPsdFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let psd = UTType(filenameExtension: "psd") {
            panel.allowedContentTypes = [psd]
        }
        panel.prompt = "打开 PSD 文件"
        if panel.runModal() == .OK {
            importPsdPaths(panel.urls.map { $0.path })
        }
    }

    @objc public func openPsdDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 PSD 目录"
        if panel.runModal() == .OK, let url = panel.url {
            loadPsdDirectory(url.path)
        }
    }

    @objc public func openSettings(_ sender: Any?) {
        segmentedControl?.selectedSegment = 1
        showEngine(index: 1)
        assetHubView?.selectSidebarItem(at: 11)
    }

    // MARK: - R36 / D-74: 图层锁定与隐藏快捷动作
    @objc public func toggleLayerLockMenuAction(_ sender: Any?) {
        inspectorView?.toggleCurrentLayerLock()
    }

    @objc public func toggleLayerVisibilityMenuAction(_ sender: Any?) {
        inspectorView?.toggleCurrentLayerVisibility()
    }

    /// R33 / A-70 / R42 / A-72：切换「显示隐藏图层」→ 立即以 force=true 重新解析当前文件
    public func setIncludeHiddenLayers(_ on: Bool) {
        guard includeHiddenLayers != on else { return }
        includeHiddenLayers = on
        parseCurrentFile(force: true)
    }

    /// R42 / A-72：核心解析入口，解耦早退逻辑。当 force=true 时强制发起重新解析
    public func parseCurrentFile(force: Bool = false) {
        let path: String
        if let curr = currentPsdPath, !curr.isEmpty {
            path = curr
        } else {
            let row = psdTableView?.selectedRow ?? -1
            if row >= 0 && row < psdFiles.count {
                path = psdFiles[row]
            } else if let first = psdFiles.first {
                path = first
            } else {
                return
            }
        }

        if !force && currentPsdPath == path && !canvasView.layers.isEmpty {
            return
        }
        currentPsdPath = path
        let wantsHidden = includeHiddenLayers

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parseResult = PSDParserSocket.shared.parsePSD(at: path, includeHidden: wantsHidden)
            DispatchQueue.main.async {
                guard let self = self,
                      self.currentPsdPath == path,
                      self.includeHiddenLayers == wantsHidden else {
                    return
                }

                // R32 / A-65：解析失败 → 明确红色报错，绝不再显示绿色「✓ 完整提取」。
                guard parseResult.isValid else {
                    self.canvasView.layers = []
                    self.canvasView.backgroundPreview = nil
                    self.inspectorView.layers = []
                    self.inspectorView.updateDiagnostics(
                        aspectRatio: "—",
                        resolutionSpec: "—",
                        width: 0,
                        height: 0,
                        warnings: parseResult.warnings,
                        isValid: false,
                        failureReason: parseResult.failureReason,
                        layerCount: 0,
                        counts: parseResult.counts
                    )
                    self.onParseCompleted?(parseResult)
                    return
                }

                self.canvasView.setResolution(width: parseResult.width, height: parseResult.height)
                // R33 / A-68：底板 + 逐层贴图 → 纯照片 PSD 也能看见完整画面。
                self.canvasView.backgroundPreview = parseResult.backgroundPreview
                // R45：PSD 原始完整成图路径，用于直观对比
                self.canvasView.originalCompositePath = parseResult.originalCompositePath
                self.canvasView.layers = parseResult.layers
                self.inspectorView.layers = parseResult.layers
                self.inspectorView.updateDiagnostics(
                    aspectRatio: parseResult.aspectRatio,
                    resolutionSpec: parseResult.resolutionSpec,
                    width: parseResult.width,
                    height: parseResult.height,
                    warnings: parseResult.warnings,
                    isValid: true,
                    failureReason: nil,
                    layerCount: parseResult.layers.count,
                    counts: parseResult.counts
                )
                self.canvasView.fitArtboard()
                print("[A-72] PSD loaded: \(path) layers=\(parseResult.layers.count) valid=\(parseResult.isValid) includeHidden=\(wantsHidden)")
                self.onParseCompleted?(parseResult)
                if ProcessInfo.processInfo.arguments.contains("--verify-open") {
                    fflush(stdout)
                    exit(parseResult.isValid ? 0 : 1)
                }
            }
        }
    }

    public func selectPsdFile(at row: Int) {
        guard row >= 0, row < psdFiles.count else { return }
        if psdTableView?.selectedRow != row {
            psdTableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        parseCurrentFile(force: false)
    }

    /// R42：一键跳转至外置存储与搬家中心
    public func showStorageMigration() {
        segmentedControl?.selectedSegment = 1
        showEngine(index: 1)
        assetHubView?.selectSidebarItem(at: 8)
    }

    /// R43：一键跳转至多工作区情境隔离配置系统
    public func showWorkspaceProfiles() {
        segmentedControl?.selectedSegment = 1
        showEngine(index: 1)
        assetHubView?.selectSidebarItem(at: 9)
    }

    /// R44：一键跳转至团队资产免流量分发与环境克隆系统
    public func showTeamSync() {
        segmentedControl?.selectedSegment = 1
        showEngine(index: 1)
        assetHubView?.selectSidebarItem(at: 10)
    }

    @objc public func onProfileBadgeClicked() {
        showWorkspaceProfiles()
    }

    @objc public func updateActiveProfileBadge() {
        let p = WorkspaceProfileManager.shared.getActiveProfile()
        let shortName = p.name.components(separatedBy: " ").first ?? p.name
        profileBadgeButton?.title = "[\(p.icon) \(shortName)]"
    }

    // MARK: – R46 字体一键补齐与系统注册
    public func handleDroppedFonts(_ paths: [String]) {
        let fontUrls = paths.compactMap { p -> URL? in
            if FontInstaller.isFontFile(at: p) || PSDImportPlanner.isFont(p) {
                return URL(fileURLWithPath: p)
            }
            return nil
        }
        guard !fontUrls.isEmpty else { return }
        let report = FontInstaller.shared.registerFonts(at: fontUrls)
        print("[FontInstaller] 注册字体完成: 成功 \(report.successCount)/\(report.totalAttempted)")
        // 强制重新解析当前 PSD，消除缺字警告恢复正常
        self.parseCurrentFile(force: true)
    }

    // MARK: – Save & Export (安全检查、多路径自适应与异步调度)
    public func saveCurrentTemplate() {
        guard let path = currentPsdPath else { return }
        let resolved = AppConfig.shared.resolveExportDestination()
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".psd", with: "")
        let outDir = "\(resolved.targetDir)/\(base)"

        let ok = MotionBuilderSocket.shared.buildTemplate(
            psdPath: path,
            outputDir: outDir,
            templateName: base,
            layers: canvasView.layers
        )
        if ok {
            if resolved.isExternal, let extRoot = resolved.externalRoot {
                _ = SymlinkSocket.shared.linkToSystem(
                    category: "Titles.localized",
                    groupName: "PSD婚礼字幕",
                    externalRoot: extRoot
                )
            }
            let note = resolved.fallbackUsed ? "\n(未检测到可用外置存储，已自动无缝降级保存至本地系统盘)" : "\n(已挂载至 Final Cut Pro)"
            showAlert(title: "安装完成 ✓", msg: "模板已生成：\n\(outDir)\(note)\n(若此前已有同名模板，系统已自动完成安全备份)")
        } else {
            showAlert(title: "安装失败", msg: "生成 Motion 模板时发生错误，请查看诊断报告。")
        }
    }

    public func batchExportAllTemplates() {
        guard LicenseManager.shared.isProLicensed else {
            let alert = NSAlert()
            alert.messageText = "商业授权未激活"
            alert.informativeText = "未激活商业授权，全套模板批量导出功能已锁定。请先激活商业授权。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        guard !psdFiles.isEmpty else { return }
        let resolved = AppConfig.shared.resolveExportDestination()
        let sheet = BatchExportProgressSheet(totalCount: psdFiles.count, targetDir: resolved.targetDir)
        self.activeExportSheet = sheet

        if let win = self.window {
            win.beginSheet(sheet) { _ in }
        }

        let filesToExport = self.psdFiles
        let outRoot = resolved.targetDir
        let isExternal = resolved.isExternal
        let externalRoot = resolved.externalRoot

        sheet.onCancel = {
            print("[BatchExport] 用户取消批处理")
        }

        sheet.onRevealInFinder = { path in
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        // 完全移至后台全局高优先级队列异步执行，绝不阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak sheet] in
            var successCount = 0
            var failedCount = 0

            for (index, p) in filesToExport.enumerated() {
                if sheet?.isCancelled == true {
                    sheet?.appendLog(status: .warning, fileName: "调度器", message: "批处理已中止，退出队列")
                    break
                }

                let base = (p as NSString).lastPathComponent.replacingOccurrences(of: ".psd", with: "")
                let subOut = "\(outRoot)/\(base)"
                let currentName = (p as NSString).lastPathComponent

                sheet?.updateProgress(completed: index, total: filesToExport.count, currentFileName: currentName)

                let parseResult = PSDParserSocket.shared.parsePSD(at: p)
                if !parseResult.isValid {
                    failedCount += 1
                    sheet?.appendLog(status: .failure, fileName: currentName, message: "解析失败: \(parseResult.failureReason ?? "未知错误")")
                    sheet?.updateProgress(completed: index + 1, total: filesToExport.count, currentFileName: currentName)
                    continue
                }
                if parseResult.layers.isEmpty {
                    failedCount += 1
                    sheet?.appendLog(status: .failure, fileName: currentName, message: "无有效图层")
                    sheet?.updateProgress(completed: index + 1, total: filesToExport.count, currentFileName: currentName)
                    continue
                }

                let ok = MotionBuilderSocket.shared.buildTemplate(
                    psdPath: p,
                    outputDir: subOut,
                    templateName: base,
                    layers: parseResult.layers
                )
                if ok {
                    successCount += 1
                    sheet?.appendLog(status: .success, fileName: currentName, message: "生成成功 -> \(base)")
                } else {
                    failedCount += 1
                    sheet?.appendLog(status: .failure, fileName: currentName, message: "Motion 模板构建失败")
                }

                sheet?.updateProgress(completed: index + 1, total: filesToExport.count, currentFileName: currentName)
            }

            if sheet?.isCancelled != true {
                if isExternal, let extRoot = externalRoot {
                    _ = SymlinkSocket.shared.linkToSystem(
                        category: "Titles.localized",
                        groupName: "PSD婚礼字幕",
                        externalRoot: extRoot
                    )
                }
            }

            sheet?.finishExport(successCount: successCount, failedCount: failedCount, targetDir: outRoot)
        }
    }

    private func showAlert(title: String, msg: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.runModal()
    }

    // MARK: – TableView DataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return psdFiles.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let fn = (psdFiles[row] as NSString).lastPathComponent
        let tf = NSTextField(labelWithString: "  📄 \(fn)")
        tf.font = .systemFont(ofSize: 12)
        tf.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        tf.lineBreakMode = .byTruncatingMiddle
        return tf
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 28
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = psdTableView.selectedRow
        if row >= 0 {
            selectPsdFile(at: row)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: – Helper
    private func makeView(frame: NSRect, bg: NSColor, mask: NSView.AutoresizingMask) -> NSView {
        let v = NSView(frame: frame)
        v.autoresizingMask = mask
        if bg != .clear {
            v.wantsLayer = true
            v.layer?.backgroundColor = bg.cgColor
        }
        return v
    }
}
