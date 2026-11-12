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
    public var leftTitleLabel: NSTextField!
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

    // MARK: – TR-019 阶段一：.moti 只读预览态
    /// 只读态为 true 时：图层全部锁定，保存/批量导出被硬阻断，
    /// 任何 PSD 解析操作都会先 exitMotiReadOnlyMode() 自动退出该态。
    public private(set) var motiReadOnlyMode: Bool = false
    public private(set) var currentMotiPath: String?

    // MARK: – TR-002-C：.moti 编辑态（与只读预览互斥，只读代码路径一行未动）
    public private(set) var motiEditMode: Bool = false
    public private(set) var motiEditSession: MotiEditSession?
    private var motiTextBridge: MotiTextEditBridge?
    private var motiPlannedBackupPath: String?

    // MARK: – TR-020 PNG 智能拆图层（人工确认窗口需强持有）
    public private(set) var pngSplitConfirmWindow: PngSplitConfirmWindowController?

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
        // FCPX-037: 设立窗口全局最小尺寸，杜绝超窄布局崩溃与控件对撞
        win.minSize              = NSSize(width: 1000, height: 680)

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

        // R51 / UI-G001: 强化 Dock 图标在主窗口创建时的即时注入 (剔除外部路径写死，仅走 Bundle.main)
        if NSApp.applicationIconImage == nil {
            if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let iconImg = NSImage(contentsOfFile: iconPath) {
                NSApp.applicationIconImage = iconImg
            } else if let iconImg = NSImage(named: "AppIcon") {
                NSApp.applicationIconImage = iconImg
            }
        }

        // `--engine2` 启动参数：直接进入素材库页（用于自动化真机验收，正常用户不受影响）
        if ProcessInfo.processInfo.arguments.contains("--engine2") {
            segmentedControl?.selectedSegment = 1
            showEngine(index: 1)
        }

        let args = ProcessInfo.processInfo.arguments
        // TR-019 阶段一：`--preview-moti <path>` 直接进只读预览。
        // 必须排在 --open 之前且阻止默认目录加载，否则 loadPsdDirectory 会
        // 触发 parseCurrentFile 把只读态顶掉。
        // TR-002-C：`--edit-moti <path>` 进可编辑态；--preview-moti 分支一行未改。
        if let idx = args.firstIndex(of: "--edit-moti"), idx + 1 < args.count {
            let target = (args[idx + 1] as NSString).expandingTildeInPath
            DispatchQueue.main.async { [weak self] in
                self?.editMotiInDesigner(path: target)
            }
        } else if let idx = args.firstIndex(of: "--preview-moti"), idx + 1 < args.count {
            let target = (args[idx + 1] as NSString).expandingTildeInPath
            DispatchQueue.main.async { [weak self] in
                self?.previewMotiInDesigner(path: target)
            }
        } else if let idx = args.firstIndex(of: "--split-png"), idx + 1 < args.count {
            // TR-020：真机验收直接打开预切确认窗口；--split-auto-confirm 仅用于
            // 无人值守截图，触发的是 UI 里同一个「确认并导出」按钮，不绕过确认。
            // TR-022：--split-names "a,b,c" 预置卡片语义名；--split-selftest 跑合并/拆分/删除自检。
            let target = (args[idx + 1] as NSString).expandingTildeInPath
            let auto = args.contains("--split-auto-confirm")
            let selfTest = args.contains("--split-selftest")
            let scrollBottom = args.contains("--split-scroll-bottom")
            var presetNames: [String]? = nil
            if let ni = args.firstIndex(of: "--split-names"), ni + 1 < args.count {
                presetNames = args[ni + 1].split(separator: ",").map { String($0) }
            }
            DispatchQueue.main.async { [weak self] in
                self?.startPngSplit(path: target, autoConfirm: auto,
                                    presetNames: presetNames, selfTest: selfTest,
                                    scrollBottom: scrollBottom)
            }
        } else if let idx = args.firstIndex(of: "--open"), idx + 1 < args.count {
            // `--open <psd 路径>` 启动参数：走与 ⌘O 完全相同的单文件导入路径
            // （importPsdPaths），用于 A-62 无辅助功能权限时的自动化真机验收。
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
        // UI-O001: 改用原生 image+title，无手写前导空格
        segmentedControl = NSSegmentedControl(
            labels: ["设计器 (PSD → Motion)",
                     "素材库与管理中心"],
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
        profileBadgeButton = NSButton(title: "全量模式", target: self, action: #selector(onProfileBadgeClicked))
        profileBadgeButton.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "全量模式")
        profileBadgeButton.imagePosition = .imageLeading
        profileBadgeButton.frame = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        profileBadgeButton.bezelStyle = .regularSquare
        profileBadgeButton.isBordered = false
        profileBadgeButton.wantsLayer = true
        profileBadgeButton.layer?.cornerRadius = CornerRadius.capsule
        profileBadgeButton.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1.0).cgColor
        profileBadgeButton.layer?.borderWidth = 1.0
        profileBadgeButton.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.45, blue: 0.75, alpha: 0.8).cgColor
        profileBadgeButton.font = TypeScale.footnoteMedium
        profileBadgeButton.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1.0, alpha: 1.0)
        profileBadgeButton.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        topBar.addSubview(profileBadgeButton)
        updateActiveProfileBadge()

        // 顶部直观对比模式切换分段控制器 (R45 / UI-G011: 标签为"透视原图")
        let compW: CGFloat = 300
        let compH: CGFloat = 28
        let compX = badgeX - compW - 14
        comparisonSegmentedControl = NSSegmentedControl(
            labels: ["画板", "卷帘对比", "并排", "透视原图"],
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
        // FCPX-037: midW 设立保底最小宽度 280pt，防止窗口变窄后出负值对撞
        let midW = max(280.0, w - LEFT_W - RIGHT_W)
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

        // FCPX-032: 动态展示实际 PSD 素材条数
        leftTitleLabel = NSTextField(labelWithString: "素材批处理列表 (0)")
        leftTitleLabel.frame = NSRect(x: 12, y: h - 36, width: LEFT_W - 24, height: 22)
        leftTitleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        leftTitleLabel.textColor = .white
        leftPanel.addSubview(leftTitleLabel)

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
            guard let self = self else { return }
            self.canvasView.needsDisplay = true
            // TR-002-C：文本 / X / Y / 可见 / 锁定 任意改动都刷新「有无改动」与保存按钮
            if self.motiEditMode { self.refreshMotiEditState() }
        }
        inspectorView.onLayerVisibilityChanged = { [weak self] _ in
            guard let self = self else { return }
            self.canvasView.needsDisplay = true
            if self.motiEditMode { self.refreshMotiEditState() }
        }
        inspectorView.onAllVisibilityToggled = { [weak self] _ in
            guard let self = self else { return }
            self.canvasView.needsDisplay = true
            if self.motiEditMode { self.refreshMotiEditState() }
        }
        inspectorView.onLayerLockChanged = { [weak self] _ in
            guard let self = self else { return }
            self.canvasView.needsDisplay = true
            if self.motiEditMode { self.refreshMotiEditState() }
        }
        inspectorView.onHiddenLayersChanged = { [weak self] on in
            self?.setIncludeHiddenLayers(on)
        }
        // TR-019 阶段一：只读预览态下，写回 / 导出在入口处二次硬阻断
        // （按钮已置灰，这里防菜单快捷键等旁路）
        inspectorView.onSaveTemplate = { [weak self] in
            guard let self = self else { return }
            // TR-002-C：编辑态保存走 .moti 单点字节写回，绝不走 PSD 生成链
            if self.motiEditMode { self.confirmAndSaveMotiEdits(); return }
            guard !self.motiReadOnlyMode else { self.showMotiReadOnlyAlert(); return }
            self.saveCurrentTemplate()
        }
        inspectorView.onBatchExport = { [weak self] in
            guard let self = self else { return }
            guard !self.motiEditMode else {
                self.showAlert(title: "编辑态", msg: "当前是 .moti 编辑态，本版不支持批量导出。")
                return
            }
            guard !self.motiReadOnlyMode else { self.showMotiReadOnlyAlert(); return }
            self.batchExportAllTemplates()
        }
        inspectorView.onFontsDropped = { [weak self] paths in
            self?.handleDroppedFonts(paths)
        }
        // TR-002-C：切图层会走 selectLayer → updateControlStates，
        // 异步补一次编辑态配置，保证旋转/缩放恒为置灰、发布列恒隐藏。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(motiEditSelectionDidChange(_:)),
            name: NSTableView.selectionDidChangeNotification,
            object: inspectorView.layerTableView
        )

        parent.addSubview(engine1Container)
    }

    // MARK: – Engine 2: Asset Hub
    private func buildEngine2(in parent: NSView, w: CGFloat, h: CGFloat) {
        assetHubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        assetHubView.autoresizingMask = [.width, .height]
        assetHubView.isHidden = true
        assetHubView.onOpenTemplateInDesigner = { [weak self] _ in
            self?.exitMotiReadOnlyMode()
            self?.showEngine(index: 0)
        }
        // TR-019 阶段一：.moti 只读解析进设计器（不写回、不打开外部 Motion）
        assetHubView.onPreviewMotiInDesigner = { [weak self] path in
            self?.previewMotiInDesigner(path: path)
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
        comparisonSegmentedControl?.isHidden = (index != 0)
        if index == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.canvasView?.fitArtboard()
            }
        } else {
            assetHubView?.refreshList()
        }
    }

    // MARK: – TR-019 阶段一：.moti 只读解析进设计器（不写回）

    /// 只读解析 .moti 并注入画布 / 检查器。
    /// 阶段一硬约束：不生成任何文件、不修改 .moti、不调用 MotionBuilderSocket；
    /// 保存与批量导出在只读态下被硬阻断，生成的 LayerModel 一律 isLocked=true。
    public func previewMotiInDesigner(path: String) {
        // TR-022-5：真机性能埋点（解析 / 建模型 / 表格填充），打印到 stdout 供验收采集
        let tStart = Date()
        let snapshot = MotiDocumentParser.parse(path: path)
        let tParse = Date()
        guard snapshot.isValid else {
            showAlert(title: "只读预览失败",
                      msg: (snapshot.failureReason ?? "无法解析该 .moti 文件。") + "\n\(path)")
            return
        }
        let models = MotiDocumentParser.toLayerModels(snapshot)
        let tModels = Date()
        guard !models.isEmpty else {
            showAlert(title: "只读预览失败",
                      msg: "该 .moti 未解析出任何图层，设计器保持原状。\n\(path)")
            return
        }

        // 进入只读态：先切断一切写回路径，再注入数据
        motiReadOnlyMode = true
        currentMotiPath = path
        currentPsdPath = nil
        inspectorView.saveButton?.isEnabled = false
        inspectorView.batchExportButton?.isEnabled = false

        segmentedControl?.selectedSegment = 0
        showEngine(index: 0)

        canvasView.backgroundPreview = nil
        canvasView.originalCompositePath = nil
        canvasView.setResolution(width: CGFloat(snapshot.canvasWidth),
                                 height: CGFloat(snapshot.canvasHeight))
        // TR-019-R：只读预览没有位图贴图，打开占位绘制保证画布不空黑
        canvasView.motiPreviewMode = true
        canvasView.layers = models

        let tTable0 = Date()
        inspectorView.layers = models

        // TR-019-R：绕开 PSD 诊断逻辑，幅面规格常驻 + 白话诊断默认折叠
        inspectorView.updateMotiReadOnlyInfo(canvasWidth: snapshot.canvasWidth,
                                             canvasHeight: snapshot.canvasHeight,
                                             layerCount: models.count,
                                             notes: snapshot.warnings)
        let tTable1 = Date()
        canvasView.fitArtboard()

        let parseMs = tParse.timeIntervalSince(tStart) * 1000.0
        let modelsMs = tModels.timeIntervalSince(tParse) * 1000.0
        let fillMs = tTable1.timeIntervalSince(tTable0) * 1000.0
        print(String(format: "[TR-022] moti_preview layers=%d parse_ms=%.1f models_ms=%.1f table_fill_ms=%.1f canvas=%dx%d file=%@",
                     models.count, parseMs, modelsMs, fillMs,
                     snapshot.canvasWidth, snapshot.canvasHeight,
                     (path as NSString).lastPathComponent))
        print("[TR-019] moti read-only preview: \(path) layers=\(models.count) "
              + "canvas=\(snapshot.canvasWidth)x\(snapshot.canvasHeight)")
        fflush(stdout)

        // TR-022-5：真机验收 --moti-scroll-bottom 时测量「从上滚到底」耗时并打印
        if ProcessInfo.processInfo.arguments.contains("--moti-scroll-bottom") {
            // 先把窗口拉高到屏幕可用高度，避免 564 层表格底部被窗口底边裁掉
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let win = self?.window, let scr = win.screen else { return }
                var f = win.frame
                f.size.height = scr.visibleFrame.height - 16
                f.origin.y = scr.visibleFrame.maxY - f.size.height - 8
                win.setFrame(f, display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self = self else { return }
                let r = self.inspectorView.tr022MeasureScrollToBottom(runs: 5)
                print(String(format: "[TR-022] scroll_bottom min_ms=%.1f avg_ms=%.1f rows=%d",
                             r.min, r.avg, r.rows))
                fflush(stdout)
            }
        }
    }

    /// 退出只读态：恢复保存 / 导出按钮。任何 PSD 相关操作前调用。
    public func exitMotiReadOnlyMode() {
        // TR-002-C：编辑态也是由 .moti 打开的，PSD 操作前必须一并退出，
        // 否则 parseCurrentFile 会把编辑态数据顶掉。非编辑态时本行是 no-op。
        exitMotiEditMode()
        guard motiReadOnlyMode else { return }
        motiReadOnlyMode = false
        currentMotiPath = nil
        // TR-019-R：退出只读态后恢复常规画布渲染与锁定提示文案
        canvasView.motiPreviewMode = false
        inspectorView.motiReadOnlyMode = false
        inspectorView.saveButton?.isEnabled = true
        inspectorView.batchExportButton?.isEnabled = true
    }

    // MARK: – TR-002-C：.moti 编辑态（--edit-moti <path>）

    /// 打开 .moti 进入可编辑态。只读预览 previewMotiInDesigner 一行未动。
    public func editMotiInDesigner(path: String) {
        guard let session = MotiEditSession(path: path) else {
            showAlert(title: "编辑失败", msg: "该 .moti 无法解析或没有图层。\n\(path)")
            return
        }
        let snapshot = session.baseline
        motiEditSession = session
        motiEditMode = true
        motiReadOnlyMode = false
        currentMotiPath = path
        currentPsdPath = nil

        // 自动化验收预置改动；正常用户交互路径完全不走这里。
        applyAutomationPreset(to: session)

        segmentedControl?.selectedSegment = 0
        showEngine(index: 0)
        canvasView.backgroundPreview = nil
        canvasView.originalCompositePath = nil
        canvasView.setResolution(width: CGFloat(snapshot.canvasWidth),
                                 height: CGFloat(snapshot.canvasHeight))
        canvasView.motiPreviewMode = true
        canvasView.motiPreviewBadgeOverride = "编辑态 · 共 \(session.models.count) 层"
        canvasView.layers = session.models

        inspectorView.motiReadOnlyMode = false
        inspectorView.layers = session.models
        inspectorView.motiEditMode = true
        inspectorView.motiEditWritable = session.writable.0
        inspectorView.resolutionLabel?.stringValue = "📐 幅面规格 \(snapshot.canvasWidth)×\(snapshot.canvasHeight)"
        inspectorView.resolutionLabel?.isHidden = false
        // TR-002-D-1-r2：摘要行按可写层数分支（仅文案，判定逻辑仍全在 MotiEditSession/保存前置）。
        let motiTotalLayers = session.models.count
        let motiEditableLayers = session.editableLayerCount
        if motiEditableLayers == 0 {
            inspectorView.diagnosticsSummaryLabel?.stringValue =
                "ⓘ 编辑态：本模板无可写图层，仅支持只读预览"
        } else if motiEditableLayers < motiTotalLayers {
            // 第一行原文，第二行「（可写 n/m 层）」——换行点放在括号前，避免「可写」与数字被拆开。
            inspectorView.diagnosticsSummaryLabel?.stringValue =
                "ⓘ 编辑态：仅 文本 / X / Y / 可见 / 锁定 会写回 .moti"
                + "\n（可写 \(motiEditableLayers)/\(motiTotalLayers) 层）"
        } else {
            inspectorView.diagnosticsSummaryLabel?.stringValue =
                "ⓘ 编辑态：仅 文本 / X / Y / 可见 / 锁定 会写回 .moti"
        }
        // 混链分支的摘要比单行宽度长约 60pt，不放开换行必然被省略号截断（判据要求「可写 7/8 层」可见）。
        // 仅此分支允许两行；字体、锚点、盒高与所有判定一行不动，其余分支仍是单行截断。
        let motiSummaryMultiLine = motiEditableLayers > 0 && motiEditableLayers < motiTotalLayers
        if let summaryLabel = inspectorView.diagnosticsSummaryLabel {
            if let h = summaryLabel.constraints.first(where: { $0.identifier == "motiSummaryH" }) {
                h.constant = motiSummaryMultiLine ? 26 : 14
            } else {
                let h = summaryLabel.heightAnchor.constraint(
                    equalToConstant: motiSummaryMultiLine ? 26 : 14)
                h.identifier = "motiSummaryH"
                h.isActive = true
            }
            summaryLabel.lineBreakMode = motiSummaryMultiLine ? .byCharWrapping : .byTruncatingTail
            summaryLabel.maximumNumberOfLines = motiSummaryMultiLine ? 2 : 1
            summaryLabel.cell?.wraps = motiSummaryMultiLine
            summaryLabel.cell?.isScrollable = false
        }
        inspectorView.diagnosticsBox?.stringValue = [
            "备份目录：~/Library/Application Support/FCPXStudioPro/moti_backups/",
            "保存会覆盖原文件；写后读回不一致会自动回填到写前状态。",
            "字号 / 对齐 / 颜色 / 旋转 / 缩放 / 发布列本版不写回。"
        ].joined(separator: "\n")
        inspectorView.diagnosticsDetailBox?.isHidden = true
        inspectorView.diagnosticsToggleButton?.title = "详情 (3)"

        let bridge = MotiTextEditBridge()
        bridge.onChange = { [weak self] text in
            guard let self = self, self.motiEditMode,
                  let layer = self.inspectorView.currentSelectedLayer else { return }
            layer.text = text
            self.inspectorView.onLayerModified?(layer)
        }
        motiTextBridge = bridge
        inspectorView.textEditor?.delegate = bridge

        refreshMotiEditState()
        inspectorView.applyMotiEditMode()
        canvasView.fitArtboard()

        // TR-002-D-1 BUG-4D1-1：日志诚实——同一行必须能看出
        // 「文件可写(writable) ≠ 这一层可写(editable_layers/selected_writable)」。
        // writable 保留文件级写权限语义；editable_layers 为中文链可写层总数
        // （564 层英文链模板应为 0）；selected_writable 按当前选中层判。
        let selectedIdx = inspectorView.currentSelectedLayer.flatMap { selected in
            session.models.firstIndex(where: { $0 === selected })
        }
        let selectedPart: String
        if let idx = selectedIdx {
            selectedPart = session.layerWritable(index: idx)
                ? "selected_writable=true"
                : "selected_writable=false reason=参数链非本工具格式"
        } else {
            selectedPart = "selected_writable=na"
        }
        print("[TR-002C] edit_moti_open path=\(path) layers=\(session.models.count) "
              + "canvas=\(snapshot.canvasWidth)x\(snapshot.canvasHeight) "
              + "writable=\(session.writable.0) reason=\(session.writable.1) "
              + "editable_layers=\(session.editableLayerCount) \(selectedPart)")
        fflush(stdout)

        // 无人值守取证：预置改动后自动走「同一次确认 + 同一次写回」；
        // 正常用户路径完全不触发这里。
        // TR-002-D BUG-4D-3：自动化开关编译期隔离（方案 A）——交付包
        // （swift build 不带 -DTR002C_AUTOMATION）整段不编译，任何参数组合
        // 都无法跳过确认或触发自动写盘；取证用 tools/ 侧带该条件的构建产物。
#if TR002C_AUTOMATION
        if ProcessInfo.processInfo.arguments.contains("--edit-moti-auto-save") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.confirmAndSaveMotiEdits()
            }
        }
#endif
    }

    /// 仅供无人值守真机取证：按启动参数预置一层改动，用户界面不显示这些参数。
    /// TR-002-D BUG-4D-3：整段条件编译，交付包内不存在的开关；取证构建才可用。
    /// TR-002-D BUG-4D-1：非中文链层的 X/Y 不预置、不进 ops——
    /// 否则写回成功、读回恒 0.0、必然回填，用户只会看到莫名其妙的失败。
    private func applyAutomationPreset(to session: MotiEditSession) {
#if TR002C_AUTOMATION
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let idx = Int(value("--edit-moti-layer") ?? "0") ?? 0
        guard idx >= 0, idx < session.models.count else { return }
        let layer = session.models[idx]
        let chain = idx < session.baseline.layers.count
            ? session.baseline.layers[idx].positionChain : "zh"
        if let t = value("--edit-moti-text") { layer.text = t }
        if chain == "zh" {
            if let x = value("--edit-moti-x"), let d = Double(x) { layer.posX = d }
            if let y = value("--edit-moti-y"), let d = Double(y) { layer.posY = d }
        } else if value("--edit-moti-x") != nil || value("--edit-moti-y") != nil {
            print("[TR-002D] preset_skip_xy layer=\(idx) chain=\(chain) "
                  + "reason=该层参数链非中文链，X/Y 不进写回 ops")
            fflush(stdout)
        }
        if let e = value("--edit-moti-enabled") {
            layer.visible = (e == "1" || e.lowercased() == "true")
        }
        if let l = value("--edit-moti-locked") {
            layer.isLocked = (l == "1" || l.lowercased() == "true")
        }
#endif
    }

    /// 任何改动后刷新「有无改动 / 可写性 / 保存按钮」并补一次编辑态控件配置。
    private func refreshMotiEditState() {
        guard motiEditMode, let session = motiEditSession else { return }
        inspectorView.motiEditHasChanges = session.changeCount > 0
        inspectorView.motiEditWritable = session.writable.0
        inspectorView.applyMotiEditMode()
    }

    /// 切图层后 updateControlStates 会重置控件状态，异步补挂编辑态配置。
    @objc private func motiEditSelectionDidChange(_ note: Notification) {
        guard motiEditMode else { return }
        DispatchQueue.main.async { [weak self] in
            self?.inspectorView.applyMotiEditMode()
        }
    }

    /// 保存前唯一一次确认：备份路径、将改几处、原文件会被覆盖。
    private func confirmAndSaveMotiEdits() {
        guard let session = motiEditSession else { return }
        let edits = session.edits()
        let count = session.changeCount
        guard count > 0 else {
            showAlert(title: "没有改动", msg: "当前与写前状态一致，不允许保存。")
            return
        }
        // TR-002-D-1 BUG-4D1-1：保存前置拦截——edits() 里存在不可写层
        // （positionChain != "zh"）的改动时，根本不许进 MotiWriteBack：
        // 不算备份路径、不写盘、无 SAVE_OK，文件 sha 与备份目录计数不变。
        // 这是核心判据，不依赖写回报错，绝不落到「落点未找到」。
        if let unwritableIdx = session.firstUnwritableEditLayer() {
            print("[TR-002D1] SAVE_REJECT error=图层不可写：参数链非本工具格式 (L\(unwritableIdx))")
            fflush(stdout)
            let rejectMsg = "第 \(unwritableIdx + 1) 层（L\(unwritableIdx)）的参数链非本工具格式，该层不可写。\n本次改动未写回，原文件一个字节未变。"
#if TR002C_AUTOMATION
            if !ProcessInfo.processInfo.arguments.contains("--edit-moti-auto-confirm") {
                showAlert(title: "保存被拒绝", msg: rejectMsg)
            }
#else
            showAlert(title: "保存被拒绝", msg: rejectMsg)
#endif
            return
        }
        let (writable, why) = session.writable
        guard writable else {
            showAlert(title: "目标不可写", msg: "已禁用保存：\(why)")
            return
        }
        // 先算好备份路径并显示在弹窗里，写回时用同一个值，绝不弹窗一套、落盘另一套。
        let backup = MotiWriteBack.backupPath(for: session.path)
        motiPlannedBackupPath = backup
        let msg = "备份路径：\(backup)\n将改 \(count) 处\n原文件会被覆盖：\(session.path)"

        // 无人值守取证开关：跳过模态弹窗，但走完全相同的 performMotiSave。
        // TR-002-D BUG-4D-3：交付包内该开关不编译，确认弹窗永远生效。
#if TR002C_AUTOMATION
        if ProcessInfo.processInfo.arguments.contains("--edit-moti-auto-confirm") {
            print("[TR-002C] confirm_auto backup=\(backup) changes=\(count)")
            fflush(stdout)
            performMotiSave(edits: edits, backupPath: backup)
            return
        }
#endif
        let alert = NSAlert()
        alert.messageText = "确认保存回 .moti"
        alert.informativeText = msg
        alert.addButton(withTitle: "保存回 .moti")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            print("[TR-002C] confirm_cancelled")
            fflush(stdout)
            return
        }
        performMotiSave(edits: edits, backupPath: backup)
    }

    private func performMotiSave(edits: [MotiLayerEdit], backupPath: String) {
        guard let session = motiEditSession else { return }
        let t0 = Date()
        do {
            let outcome = try MotiWriteBack.apply(path: session.path, edits: edits,
                                                  plannedBackupPath: backupPath)
            let ms = Date().timeIntervalSince(t0) * 1000.0
            session.refreshBaselineAfterSave()
            inspectorView.motiEditHasChanges = false
            inspectorView.applyMotiEditMode()
            print("[TR-002C] SAVE_OK before_sha=\(outcome.beforeSHA) after_sha=\(outcome.afterSHA) "
                  + "backup_sha=\(outcome.backupSHA) backup=\(outcome.backupPath) "
                  + "delta=\(outcome.actualDelta) changed_lines=\(outcome.changedLines) "
                  + "changes=\(outcome.changedCount) readback=\(outcome.readback.count) "
                  + "elapsed_ms=\(String(format: "%.1f", ms))")
            for row in outcome.readback { print("[TR-002C] \(row.description)") }
            fflush(stdout)
            // 无人值守取证不弹模态框，避免卡住截图；正常用户仍看到一次结果提示。
            // BUG-4D-3：交付包内 --edit-moti-auto-confirm 不编译，总是弹。
#if TR002C_AUTOMATION
            if !ProcessInfo.processInfo.arguments.contains("--edit-moti-auto-confirm") {
                showAlert(title: "已保存", msg: "已写回 \(outcome.changedCount) 处。\n备份：\(outcome.backupPath)")
            }
#else
            showAlert(title: "已保存", msg: "已写回 \(outcome.changedCount) 处。\n备份：\(outcome.backupPath)")
#endif
        } catch {
            let now = (try? Data(contentsOf: URL(fileURLWithPath: session.path)))
                .map { MotiWriteBack.sha256($0) } ?? ""
            print("[TR-002C] SAVE_FAIL error=\(error.localizedDescription) current_sha=\(now)")
            fflush(stdout)
#if TR002C_AUTOMATION
            if !ProcessInfo.processInfo.arguments.contains("--edit-moti-auto-confirm") {
                showAlert(title: "保存失败", msg: "\(error.localizedDescription)\n原文件当前 sha256：\(now)")
            }
#else
            showAlert(title: "保存失败", msg: "\(error.localizedDescription)\n原文件当前 sha256：\(now)")
#endif
            refreshMotiEditState()
        }
    }

    /// 退出编辑态：清引用、复位按钮；发布列由 applyMotiReadOnlyText() 加回。
    public func exitMotiEditMode() {
        guard motiEditMode else { return }
        motiEditMode = false
        motiEditSession = nil
        motiPlannedBackupPath = nil
        motiTextBridge = nil
        inspectorView.textEditor?.delegate = nil
        inspectorView.leaveMotiEditMode()
        inspectorView.motiReadOnlyMode = false
        canvasView.motiPreviewBadgeOverride = nil
        canvasView.motiPreviewMode = false
    }

    private func showMotiReadOnlyAlert() {
        showAlert(title: "只读预览",
                  msg: "当前处于 .moti 只读预览（TR-019 阶段一），不写回、不导出。\n"
                     + "请先在左侧选择一个 PSD 文件，即可恢复编辑态。")
    }

    // MARK: – TR-020 PNG 智能拆图层：两步（预切 → 人工确认 → 双路导出）

    /// 文件菜单入口：选一张 PNG，先预切再让人确认，绝不静默决定层数。
    @objc public func openPngSplit(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let png = UTType(filenameExtension: "png") {
            panel.allowedContentTypes = [png]
        }
        panel.prompt = "选择 PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startPngSplit(path: url.path, autoConfirm: false)
    }

    /// 预切（后台）→ 弹人工确认窗口 → 确认后导出多层 PSD → 走真实 PSD 解析链装进设计器。
    public func startPngSplit(path: String, autoConfirm: Bool = false,
                              presetNames: [String]? = nil, selfTest: Bool = false,
                              scrollBottom: Bool = false) {
        exitMotiReadOnlyMode()
        let workDir = "/tmp/tr020_ui"
        let fm = FileManager.default
        try? fm.removeItem(atPath: workDir)
        try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PngSplitSocket.analyze(pngPath: path, workDir: workDir)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case .failure(let err):
                    self.showAlert(title: "PNG 智能拆图层", msg: err.message)
                case .success(let doc):
                    let ctrl = PngSplitConfirmWindowController(
                        splitDocument: doc, pngPath: path, workDir: workDir,
                        autoConfirm: autoConfirm, presetNames: presetNames,
                        selfTest: selfTest, scrollBottomOnly: scrollBottom) { [weak self] psdPath in
                            // 路径 B：多层 PSD 回导设计器，图层树由真实解析链生成
                            self?.exitMotiReadOnlyMode()
                            self?.importPsdPaths([psdPath])
                            print("[TR-020] installed split layers into designer: \(psdPath)")
                            fflush(stdout)
                        }
                    self.pngSplitConfirmWindow = ctrl
                    ctrl.showWindow(nil)
                    ctrl.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    print("[TR-020] split confirm: \(doc.candidateCount) candidates, "
                          + "r=\(doc.adaptive.radiusPx)px, autoConfirm=\(autoConfirm)")
                    fflush(stdout)
                }
            }
        }
    }

    // MARK: – PSD Loading（目录 / 单文件 / 拖放统一入口）

    public func loadPsdDirectory(_ dir: String) {
        // FCPX-034: 目录不存在、无权限或为空时提供明确反馈与空态指示，杜绝永久静默空白
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            leftTitleLabel?.stringValue = "素材批处理列表 (0)"
            psdTableView?.reloadData()
            return
        }
        let psds = files.sorted().filter { $0.hasSuffix(".psd") && !$0.hasPrefix(".") }
                        .map { "\(dir)/\($0)" }
        guard !psds.isEmpty else {
            leftTitleLabel?.stringValue = "素材批处理列表 (0)"
            psdTableView?.reloadData()
            return
        }
        psdFiles = psds
        leftTitleLabel?.stringValue = "素材批处理列表 (\(psdFiles.count))"
        psdTableView?.reloadData()
        psdTableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        selectPsdFile(at: 0)
    }

    /// A-61 / A-62 共用入口：拖放、⌘O、⇧⌘O 全部走这里。
    /// 规则：单文件**追加**不清空；目录递归；混合逐项分类；重复路径不重复添加；
    ///      非 psd 明确提示，不崩溃、不静默。
    @objc public func importPsdPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        // TR-019 阶段一：拖入 .moti 直接进只读预览，不混入 PSD 批处理列表。
        // 混合拖放以 .moti 优先，避免只读态被随后的 PSD 解析覆盖。
        let motis = paths.filter { ($0 as NSString).pathExtension.lowercased() == "moti" }
        if let first = motis.first {
            previewMotiInDesigner(path: first)
            return
        }
        let plan = PSDImportPlanner.plan(paths: paths, existing: psdFiles)

        if !plan.added.isEmpty {
            psdFiles.append(contentsOf: plan.added)
            leftTitleLabel?.stringValue = "素材批处理列表 (\(psdFiles.count))"
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
        // TR-019：任何 PSD 解析都自动退出 .moti 只读预览态，恢复编辑能力
        exitMotiReadOnlyMode()
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
        profileBadgeButton?.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: shortName)
        profileBadgeButton?.title = shortName
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
        guard let path = currentPsdPath else {
            showAlert(title: "提示", msg: "未选择任何 PSD 文件，请先从左侧列表选择或拖入 PSD。")
            return
        }
        guard !canvasView.layers.isEmpty else {
            showAlert(title: "提示", msg: "当前 PSD 没有任何可导出的有效图层。")
            return
        }

        let resolved = AppConfig.shared.resolveExportDestination()
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".psd", with: "")
        let outDir = "\(resolved.targetDir)/\(base)"

        // FCPX-001: 保存整体进入后台异步队列，禁用按钮防止重入，彻底消除主线程阻塞与彩虹球
        inspectorView.saveButton?.isEnabled = false
        inspectorView.batchExportButton?.isEnabled = false
        let originalSaveTitle = inspectorView.saveButton?.title ?? " 保存当前模板至 FCPX"
        inspectorView.saveButton?.title = " 正在生成模板…"

        let layersSnapshot = canvasView.layers
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let buildResult = MotionBuilderSocket.shared.buildTemplateResult(
                psdPath: path,
                outputDir: outDir,
                templateName: base,
                layers: layersSnapshot,
                timeout: 180.0
            )

            DispatchQueue.main.async {
                self.inspectorView.saveButton?.isEnabled = true
                self.inspectorView.batchExportButton?.isEnabled = true
                self.inspectorView.saveButton?.title = originalSaveTitle

                if buildResult.success {
                    if resolved.isExternal, let extRoot = resolved.externalRoot {
                        _ = SymlinkSocket.shared.linkToSystem(
                            category: "Titles.localized",
                            groupName: "PSD婚礼字幕",
                            externalRoot: extRoot
                        )
                    }
                    let note = resolved.fallbackUsed ? "\n(未检测到可用外置存储，已自动无缝降级保存至本地系统盘)" : "\n(已挂载至 Final Cut Pro)"
                    // UI-O003: 统一使用 systemSymbol 图标，不再硬编码字符 ✓
                    let checkIcon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "完成")
                    self.showAlert(title: "安装完成", msg: "模板已生成：\n\(outDir)\(note)\n(若此前已有同名模板，系统已自动完成安全备份)", style: .informational, icon: checkIcon)
                } else {
                    // FCPX-004: 结构化回传具体失败原因
                    let detailMsg = buildResult.errorMessage ?? "生成 Motion 模板时发生未知错误，请查看诊断报告。"
                    self.showAlert(title: "安装失败", msg: "生成 Motion 模板失败：\n\(detailMsg)")
                }
            }
        }
    }

    public func batchExportAllTemplates() {
        // FCPX-035: 空列表时提示先导入 PSD，杜绝静默无响应
        guard !psdFiles.isEmpty else {
            showAlert(title: "提示", msg: "素材批处理列表为空，请先从左侧列表选择或拖入 PSD 文件。")
            return
        }
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

    private func showAlert(title: String, msg: String, style: NSAlert.Style = .informational, icon: NSImage? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.alertStyle = style
        if let icon = icon {
            alert.icon = icon
        }
        alert.runModal()
    }

    // MARK: – TableView DataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return psdFiles.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let fn = (psdFiles[row] as NSString).lastPathComponent
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.spacing = 6
        cell.alignment = .centerY
        let iconName = fn.hasSuffix(".cube") ? "slider.horizontal.3" : "doc.text"
        let iconView = NSImageView(image: NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage())
        iconView.contentTintColor = NSColor.secondaryLabelColor
        let tf = NSTextField(labelWithString: fn)
        tf.font = TypeScale.footnote
        tf.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addArrangedSubview(iconView)
        cell.addArrangedSubview(tf)
        return cell
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
