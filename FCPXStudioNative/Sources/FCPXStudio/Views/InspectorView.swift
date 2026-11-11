import AppKit

fileprivate final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

public final class InspectorView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    // MARK: - @IBOutlet 插口绑定
    public var layerTableView: NSTableView!
    public var textEditor: NSTextView!
    public var toggleOrientationButton: NSButton!
    public var rotationSlider: NSSlider!
    public var rotationField: NSTextField!
    public var scaleSlider: NSSlider!
    public var scaleField: NSTextField!
    public var opacitySlider: NSSlider!
    public var posXField: NSTextField!
    public var posYField: NSTextField!

    public var resolutionLabel: NSTextField!
    /// TR-019-R：只读态常驻标签，挂在幅面规格下方，固定高度 + 抗压缩，谁都挤不掉
    public var readOnlyBadgeLabel: NSTextField!
    public var diagnosticsBox: NSTextField!

    // TR-019-R：诊断收进「默认折叠」的小角标，不再把整块红字塞进主布局顶掉幅面规格
    public var diagnosticsBadgeBox: NSView!
    public var diagnosticsSummaryLabel: NSTextField!
    public var diagnosticsToggleButton: NSButton!
    public var diagnosticsDetailBox: NSView!

    // R36 / D-74: 锁定横幅插口与回调
    public var lockBannerBox: NSView!
    public var lockBannerLabel: NSTextField!

    /// TR-019-R：.moti 只读预览态。
    /// 为真时锁定横幅与所有 toolTip 改显示「只读，不可编辑」，⌘L 解锁被吞掉。
    public var motiReadOnlyMode: Bool = false {
        didSet { applyMotiReadOnlyText() }
    }

    // TR-019-R：只读态把图层表拉高以一次显示 11 行，并隐藏不可编辑的属性区
    private weak var mainStackView: NSStackView?
    private var tableScrollHeight: NSLayoutConstraint?
    private let motionPropsTag = 9901
    /// TR-022-7：保留「发布」列引用，只读态整列移除（连表头），非只读态再加回。
    private var publishColumn: NSTableColumn?
    public var onLayerLockChanged: ((LayerModel) -> Void)?

    // 发布复选框插口
    public var publishTextCheck: NSButton!
    public var publishPosCheck: NSButton!
    public var publishRotCheck: NSButton!
    public var publishScaleCheck: NSButton!

    // MARK: - TR-023-B 文字样式分组插口（字号 / 对齐 / 颜色 / 当前字体名）
    // 只覆盖阶段 2 放行的四项。字距、行距、行高、描边、阴影、渐变一概不做。
    public private(set) var textStyleGroup: NSStackView!
    public private(set) var textStyleTitleLabel: NSTextField!
    public private(set) var fontSizeField: NSTextField!
    public private(set) var fontSizeStepper: NSStepper!
    public private(set) var alignmentSegment: NSSegmentedControl!
    public private(set) var colorWell: NSColorWell!
    public private(set) var colorHexField: NSTextField!
    public private(set) var fontNameLabel: NSTextField!
    public private(set) var fontReplaceButton: NSButton!

    public var layers: [LayerModel] = [] {
        didSet {
            layerTableView?.reloadData()
            // TR-023-B：换数据源（PSD ↔ .moti 预览）时，旧选中对象已经不在新列表里，
            // 必须重选第 0 层，否则面板会一直挂着上一份数据源的属性值。
            let stillPresent = currentSelectedLayer.map { current in
                layers.contains { $0 === current }
            } ?? false
            if layers.isEmpty {
                currentSelectedLayer = nil
                refreshTextStyleControls()
            } else if !stillPresent {
                currentSelectedLayer = nil
                selectLayer(at: 0)
            }
        }
    }
    public var currentSelectedLayer: LayerModel?

    public var onLayerModified: ((LayerModel) -> Void)?
    public var onLayerVisibilityChanged: ((LayerModel) -> Void)?
    /// R45：表头总控一键全显/全隐回调
    public var onAllVisibilityToggled: (([LayerModel]) -> Void)?
    /// R33 / A-70：显示隐藏图层开关（默认关；打开后由主窗口重新解析带预览层的版本）
    public var onHiddenLayersChanged: ((Bool) -> Void)?
    public var onSaveTemplate: (() -> Void)?
    public var onBatchExport: (() -> Void)?
    /// R46: 字体拖拽补齐回调
    public var onFontsDropped: (([String]) -> Void)?

    public var hiddenLayersCheckbox: NSButton!
    public private(set) var fontDropPromptBox: NSBox!
    public private(set) var fontDropPromptLabel: NSTextField!
    public private(set) var saveButton: NSButton?
    public private(set) var batchExportButton: NSButton?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        setupOutlets()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        setupOutlets()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 优雅哑光左侧细边框
        NSColor(white: 1.0, alpha: 0.08).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    private func setupOutlets() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).cgColor
        registerForDraggedTypes([.fileURL])

        // 外部滚动视图，自适应各种屏幕高度，防止控件挤压
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        // FCPX-052: 高度跟随 mainStack 底锚，防止窗口变矮时底部"批量导出"被裁切
        let contentView = FlippedClipView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 820))
        contentView.autoresizingMask = [.width]
        scroll.documentView = contentView
        addSubview(scroll)

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)
        mainStackView = mainStack

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        // ── 0. 幅面规格（TR-019-R：固定高度 + 抗压缩，任何诊断都挤不掉）──
        resolutionLabel = NSTextField(labelWithString: "📐 幅面规格 1920×1080")
        resolutionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        resolutionLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        resolutionLabel.translatesAutoresizingMaskIntoConstraints = false
        resolutionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        resolutionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        resolutionLabel.setContentHuggingPriority(.required, for: .vertical)
        mainStack.addArrangedSubview(resolutionLabel)
        resolutionLabel.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        resolutionLabel.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // TR-019-R：只读态常驻提示，与幅面规格同级、同样抗压缩
        readOnlyBadgeLabel = NSTextField(labelWithString: "🔒 只读，不可编辑")
        readOnlyBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        readOnlyBadgeLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 1.0)
        readOnlyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        readOnlyBadgeLabel.heightAnchor.constraint(equalToConstant: 20).isActive = true
        readOnlyBadgeLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        readOnlyBadgeLabel.isHidden = true
        mainStack.addArrangedSubview(readOnlyBadgeLabel)
        readOnlyBadgeLabel.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        readOnlyBadgeLabel.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // TR-019-R：诊断收进「默认折叠」的小角标，只显示一句白话摘要
        diagnosticsBadgeBox = NSView()
        diagnosticsBadgeBox.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsBadgeBox.heightAnchor.constraint(equalToConstant: 24).isActive = true

        diagnosticsSummaryLabel = NSTextField(labelWithString: "ⓘ 解析完成")
        diagnosticsSummaryLabel.font = .systemFont(ofSize: 10)
        diagnosticsSummaryLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
        diagnosticsSummaryLabel.lineBreakMode = .byTruncatingTail
        diagnosticsSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsBadgeBox.addSubview(diagnosticsSummaryLabel)

        diagnosticsToggleButton = NSButton(title: "详情", target: self, action: #selector(onToggleDiagnostics(_:)))
        diagnosticsToggleButton.bezelStyle = .inline
        diagnosticsToggleButton.font = .systemFont(ofSize: 10)
        diagnosticsToggleButton.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsBadgeBox.addSubview(diagnosticsToggleButton)

        NSLayoutConstraint.activate([
            diagnosticsSummaryLabel.leadingAnchor.constraint(equalTo: diagnosticsBadgeBox.leadingAnchor),
            diagnosticsSummaryLabel.centerYAnchor.constraint(equalTo: diagnosticsBadgeBox.centerYAnchor),
            diagnosticsSummaryLabel.trailingAnchor.constraint(equalTo: diagnosticsToggleButton.leadingAnchor, constant: -6),
            diagnosticsToggleButton.trailingAnchor.constraint(equalTo: diagnosticsBadgeBox.trailingAnchor),
            diagnosticsToggleButton.centerYAnchor.constraint(equalTo: diagnosticsBadgeBox.centerYAnchor),
            diagnosticsToggleButton.widthAnchor.constraint(equalToConstant: 58)
        ])
        mainStack.addArrangedSubview(diagnosticsBadgeBox)
        diagnosticsBadgeBox.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        diagnosticsBadgeBox.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // 展开区：固定 108 高，默认隐藏（NSStackView 对 hidden arranged subview 不分配空间）
        diagnosticsDetailBox = NSView()
        diagnosticsDetailBox.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsDetailBox.heightAnchor.constraint(equalToConstant: 108).isActive = true
        diagnosticsDetailBox.wantsLayer = true
        diagnosticsDetailBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.55).cgColor
        diagnosticsDetailBox.layer?.cornerRadius = 5

        diagnosticsBox = NSTextField(wrappingLabelWithString: "✓ 矢量文字层完整提取")
        diagnosticsBox.font = .systemFont(ofSize: 10)
        diagnosticsBox.textColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.45, alpha: 1.0)
        diagnosticsBox.maximumNumberOfLines = 8
        diagnosticsBox.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsDetailBox.addSubview(diagnosticsBox)
        NSLayoutConstraint.activate([
            diagnosticsBox.topAnchor.constraint(equalTo: diagnosticsDetailBox.topAnchor, constant: 6),
            diagnosticsBox.leadingAnchor.constraint(equalTo: diagnosticsDetailBox.leadingAnchor, constant: 8),
            diagnosticsBox.trailingAnchor.constraint(equalTo: diagnosticsDetailBox.trailingAnchor, constant: -8),
            diagnosticsBox.bottomAnchor.constraint(lessThanOrEqualTo: diagnosticsDetailBox.bottomAnchor, constant: -6)
        ])
        diagnosticsDetailBox.isHidden = true
        mainStack.addArrangedSubview(diagnosticsDetailBox)
        diagnosticsDetailBox.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        diagnosticsDetailBox.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // R46: 字体拖拽一键补全提示区
        fontDropPromptBox = NSBox()
        fontDropPromptBox.boxType = .custom
        fontDropPromptBox.borderWidth = 1.0
        fontDropPromptBox.borderColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.9, alpha: 0.5)
        fontDropPromptBox.fillColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 0.5)
        fontDropPromptBox.cornerRadius = 6.0
        fontDropPromptBox.translatesAutoresizingMaskIntoConstraints = false

        fontDropPromptLabel = NSTextField(wrappingLabelWithString: "🔤 缺失字体？拖拽 .ttf / .otf 字体文件至此处一键补齐安装")
        fontDropPromptLabel.font = .systemFont(ofSize: 10, weight: .medium)
        fontDropPromptLabel.textColor = NSColor(calibratedRed: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
        fontDropPromptLabel.alignment = .center
        fontDropPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        fontDropPromptBox.addSubview(fontDropPromptLabel)

        NSLayoutConstraint.activate([
            fontDropPromptLabel.topAnchor.constraint(equalTo: fontDropPromptBox.topAnchor, constant: 5),
            fontDropPromptLabel.bottomAnchor.constraint(equalTo: fontDropPromptBox.bottomAnchor, constant: -5),
            fontDropPromptLabel.leadingAnchor.constraint(equalTo: fontDropPromptBox.leadingAnchor, constant: 8),
            fontDropPromptLabel.trailingAnchor.constraint(equalTo: fontDropPromptBox.trailingAnchor, constant: -8)
        ])
        mainStack.addArrangedSubview(fontDropPromptBox)
        fontDropPromptBox.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        fontDropPromptBox.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // ── 1. 图层列表区块 ──
        let titleLabel = NSTextField(labelWithString: "图层结构与 FCPX 发布控制")
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        mainStack.addArrangedSubview(titleLabel)

        // R33 / A-70：「显示隐藏图层」开关（默认关）。
        // 打开后主窗口用 include_hidden 重新解析，列表会多出隐藏层的可见预览。
        hiddenLayersCheckbox = NSButton(
            checkboxWithTitle: "显示隐藏图层（默认关）",
            target: self,
            action: #selector(onHiddenLayersToggled)
        )
        hiddenLayersCheckbox.font = .systemFont(ofSize: 11)
        hiddenLayersCheckbox.contentTintColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        hiddenLayersCheckbox.state = .off
        mainStack.addArrangedSubview(hiddenLayersCheckbox)

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        // TR-019-R：保存约束，只读态拉高到能一次显示 11 行
        tableScrollHeight = tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        tableScrollHeight?.isActive = true
        tableScroll.hasVerticalScroller = true

        layerTableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 330, height: 180))
        layerTableView.autoresizingMask = [.width, .height]
        layerTableView.intercellSpacing = NSSize(width: 0, height: 3)

        let colVis = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("vis"))
        colVis.headerCell.title = ""
        colVis.headerCell.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "全选/全部隐藏")
        colVis.headerToolTip = "一键全选显示 / 全部隐藏所有图层 (Toggle All)"
        colVis.width = 36
        layerTableView.addTableColumn(colVis)

        let colLock = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lock"))
        colLock.headerCell.title = ""
        colLock.headerCell.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "锁定")
        colLock.width = 36
        layerTableView.addTableColumn(colLock)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = "图层名称"
        colName.width = 165
        layerTableView.addTableColumn(colName)

        let colPub = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pub"))
        colPub.title = "发布"
        colPub.width = 55
        layerTableView.addTableColumn(colPub)
        publishColumn = colPub   // TR-022-7：只读态整列移除用

        layerTableView.dataSource = self
        layerTableView.delegate   = self
        tableScroll.documentView  = layerTableView

        if let header = layerTableView.headerView {
            let click = NSClickGestureRecognizer(target: self, action: #selector(onHeaderClicked(_:)))
            header.addGestureRecognizer(click)
        }

        mainStack.addArrangedSubview(tableScroll)
        tableScroll.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        tableScroll.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // ── 1.5 锁定提示横幅（R36 / D-74：选中锁定图层时显式提示）──
        lockBannerBox = NSView()
        lockBannerBox.translatesAutoresizingMaskIntoConstraints = false
        lockBannerBox.wantsLayer = true
        lockBannerBox.layer?.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.08, alpha: 0.95).cgColor
        lockBannerBox.layer?.cornerRadius = 4.0
        lockBannerBox.layer?.borderWidth = 1.0
        lockBannerBox.layer?.borderColor = NSColor(calibratedRed: 0.85, green: 0.65, blue: 0.2, alpha: 0.8).cgColor
        lockBannerBox.isHidden = true

        // UI-O014: 缩短文案并支持尾部截断，280pt 宽窄栏完整可见
        lockBannerLabel = NSTextField(labelWithString: "🔒 图层已锁定 (⌘L 解锁)")
        lockBannerLabel.lineBreakMode = .byTruncatingTail
        lockBannerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        lockBannerLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 1.0)
        lockBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        lockBannerBox.addSubview(lockBannerLabel)

        NSLayoutConstraint.activate([
            lockBannerBox.heightAnchor.constraint(equalToConstant: 26),
            lockBannerLabel.centerYAnchor.constraint(equalTo: lockBannerBox.centerYAnchor),
            lockBannerLabel.leadingAnchor.constraint(equalTo: lockBannerBox.leadingAnchor, constant: 8),
            lockBannerLabel.trailingAnchor.constraint(equalTo: lockBannerBox.trailingAnchor, constant: -8)
        ])
        mainStack.addArrangedSubview(lockBannerBox)
        lockBannerBox.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        lockBannerBox.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // ── 2. Motion 属性区块 ──
        let propTitle = NSTextField(labelWithString: "选中图层 Motion 属性")
        propTitle.tag = motionPropsTag   // TR-019-R：只读态从这里起整块隐藏
        propTitle.font = TypeScale.bodyBold
        propTitle.textColor = .white
        mainStack.addArrangedSubview(propTitle)

        // 横竖排一键切换按钮
        toggleOrientationButton = NSButton(title: "转为横排版式", target: self, action: #selector(onOrientationToggled))
        toggleOrientationButton.image = NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: "转为横排")
        toggleOrientationButton.imagePosition = .imageLeading
        toggleOrientationButton.bezelStyle = .rounded
        mainStack.addArrangedSubview(toggleOrientationButton)
        toggleOrientationButton.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        toggleOrientationButton.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // 文字内容
        let textLabel = NSTextField(labelWithString: "文字内容:")
        textLabel.textColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        textLabel.font = .systemFont(ofSize: 11)
        mainStack.addArrangedSubview(textLabel)

        let textScroll = NSTextView.scrollableTextView()
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 55).isActive = true
        textEditor = textScroll.documentView as? NSTextView
        textEditor?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0)
        textEditor?.textColor = .white
        textEditor?.font = .systemFont(ofSize: 12)
        textEditor?.isRichText = false
        mainStack.addArrangedSubview(textScroll)
        textScroll.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        textScroll.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // ── 2.5 文字样式（TR-023-B）────────────────────────────────────────
        // 复用 mainStack 垂直分组 + TypeScale 标题，不新造样式体系。
        // 无数据的属性一律显示「—」并禁用，不用 0 / 默认值冒充可用。
        let styleGroup = NSStackView()
        styleGroup.orientation = .vertical
        styleGroup.alignment = .leading
        styleGroup.spacing = 6
        styleGroup.translatesAutoresizingMaskIntoConstraints = false
        textStyleGroup = styleGroup

        let styleTitle = NSTextField(labelWithString: "文字样式")
        styleTitle.font = TypeScale.bodyBold
        styleTitle.textColor = .white
        styleTitle.translatesAutoresizingMaskIntoConstraints = false
        styleTitle.heightAnchor.constraint(equalToConstant: 18).isActive = true
        styleTitle.setContentCompressionResistancePriority(.required, for: .vertical)
        styleTitle.setContentHuggingPriority(.required, for: .vertical)
        textStyleTitleLabel = styleTitle
        styleGroup.addArrangedSubview(styleTitle)

        let minorLabelColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)

        // 字号
        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        let sizeLabel = NSTextField(labelWithString: "字号:")
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.textColor = minorLabelColor
        sizeLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        sizeRow.addArrangedSubview(sizeLabel)

        fontSizeField = NSTextField(string: "—")
        fontSizeField.font = .systemFont(ofSize: 11)
        fontSizeField.alignment = .right
        fontSizeField.widthAnchor.constraint(equalToConstant: 74).isActive = true
        fontSizeField.target = self
        fontSizeField.action = #selector(onFontSizeFieldCommitted)
        sizeRow.addArrangedSubview(fontSizeField)

        fontSizeStepper = NSStepper()
        fontSizeStepper.minValue = 1
        fontSizeStepper.maxValue = 2000
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(onFontSizeStepperChanged)
        sizeRow.addArrangedSubview(fontSizeStepper)
        styleGroup.addArrangedSubview(sizeRow)

        // 对齐（左 / 中 / 右三档，与 AppKit NSTextAlignment 数值一致）
        let alignRow = NSStackView()
        alignRow.orientation = .horizontal
        alignRow.spacing = 6
        let alignLabel = NSTextField(labelWithString: "对齐:")
        alignLabel.font = .systemFont(ofSize: 11)
        alignLabel.textColor = minorLabelColor
        alignLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        alignRow.addArrangedSubview(alignLabel)

        alignmentSegment = NSSegmentedControl(labels: ["左", "中", "右"],
                                             trackingMode: .selectOne,
                                             target: self,
                                             action: #selector(onAlignmentSegmentChanged))
        alignmentSegment.segmentStyle = .rounded
        alignmentSegment.controlSize = .small
        alignmentSegment.selectedSegment = -1
        alignRow.addArrangedSubview(alignmentSegment)
        styleGroup.addArrangedSubview(alignRow)

        // 文字颜色（系统调色板 + HEX 输入）
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        let colorLabel = NSTextField(labelWithString: "颜色:")
        colorLabel.font = .systemFont(ofSize: 11)
        colorLabel.textColor = minorLabelColor
        colorLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorRow.addArrangedSubview(colorLabel)

        colorWell = NSColorWell()
        colorWell.target = self
        colorWell.action = #selector(onColorWellChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        colorRow.addArrangedSubview(colorWell)

        colorHexField = NSTextField(string: "未取到")
        colorHexField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        colorHexField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        colorHexField.target = self
        colorHexField.action = #selector(onColorHexFieldCommitted)
        colorRow.addArrangedSubview(colorHexField)
        styleGroup.addArrangedSubview(colorRow)

        // 当前字体名（只读显示 + 替换入口）
        let fontRow = NSStackView()
        fontRow.orientation = .horizontal
        fontRow.spacing = 6
        let fontLabel = NSTextField(labelWithString: "字体:")
        fontLabel.font = .systemFont(ofSize: 11)
        fontLabel.textColor = minorLabelColor
        fontLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        fontRow.addArrangedSubview(fontLabel)

        fontNameLabel = NSTextField(labelWithString: "未取到")
        fontNameLabel.font = .systemFont(ofSize: 11)
        fontNameLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        fontNameLabel.lineBreakMode = .byTruncatingMiddle
        fontNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontRow.addArrangedSubview(fontNameLabel)

        fontReplaceButton = NSButton(title: "替换", target: self, action: #selector(onReplaceFontClicked))
        fontReplaceButton.bezelStyle = .rounded
        fontReplaceButton.controlSize = .small
        fontReplaceButton.font = .systemFont(ofSize: 11)
        fontReplaceButton.setContentHuggingPriority(.required, for: .horizontal)
        fontRow.addArrangedSubview(fontReplaceButton)
        styleGroup.addArrangedSubview(fontRow)

        mainStack.addArrangedSubview(styleGroup)
        styleGroup.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        styleGroup.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true
        sizeRow.leadingAnchor.constraint(equalTo: styleGroup.leadingAnchor).isActive = true
        sizeRow.trailingAnchor.constraint(equalTo: styleGroup.trailingAnchor).isActive = true
        alignRow.leadingAnchor.constraint(equalTo: styleGroup.leadingAnchor).isActive = true
        alignRow.trailingAnchor.constraint(equalTo: styleGroup.trailingAnchor).isActive = true
        colorRow.leadingAnchor.constraint(equalTo: styleGroup.leadingAnchor).isActive = true
        colorRow.trailingAnchor.constraint(equalTo: styleGroup.trailingAnchor).isActive = true
        fontRow.leadingAnchor.constraint(equalTo: styleGroup.leadingAnchor).isActive = true
        fontRow.trailingAnchor.constraint(equalTo: styleGroup.trailingAnchor).isActive = true
        styleTitle.leadingAnchor.constraint(equalTo: styleGroup.leadingAnchor).isActive = true

        // 旋转 Rotation 控制
        let rotStack = NSStackView()
        rotStack.orientation = .horizontal
        rotStack.spacing = 8
        let rotLabel = NSTextField(labelWithString: "旋转:")
        rotLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        rotStack.addArrangedSubview(rotLabel)
        rotationSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: self, action: #selector(onRotationChanged))
        rotationField = NSTextField(string: "0.0°")
        rotationField.alignment = .right
        rotationField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        rotStack.addArrangedSubview(rotationSlider)
        rotStack.addArrangedSubview(rotationField)
        mainStack.addArrangedSubview(rotStack)
        rotStack.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        rotStack.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // 缩放 Scale 控制
        let scaleStack = NSStackView()
        scaleStack.orientation = .horizontal
        scaleStack.spacing = 8
        let scaleLabel = NSTextField(labelWithString: "缩放:")
        scaleLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        scaleStack.addArrangedSubview(scaleLabel)
        scaleSlider = NSSlider(value: 1.0, minValue: 0.1, maxValue: 3.0, target: self, action: #selector(onScaleChanged))
        scaleField = NSTextField(string: "100%")
        scaleField.alignment = .right
        scaleField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        scaleStack.addArrangedSubview(scaleSlider)
        scaleStack.addArrangedSubview(scaleField)
        mainStack.addArrangedSubview(scaleStack)
        scaleStack.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        scaleStack.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true

        // 坐标微调 X / Y (FCPX-048: 挂载 target/action，支持输入框键入回车后实时生效)
        let posStack = NSStackView()
        posStack.orientation = .horizontal
        posStack.spacing = 8
        posStack.addArrangedSubview(NSTextField(labelWithString: "X:"))
        posXField = NSTextField(string: "0.0")
        posXField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        posXField.target = self
        posXField.action = #selector(onPosFieldChanged)
        posStack.addArrangedSubview(posXField)
        posStack.addArrangedSubview(NSTextField(labelWithString: "Y:"))
        posYField = NSTextField(string: "0.0")
        posYField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        posYField.target = self
        posYField.action = #selector(onPosFieldChanged)
        posStack.addArrangedSubview(posYField)
        mainStack.addArrangedSubview(posStack)

        // 发布勾选组
        let pubBoxTitle = NSTextField(labelWithString: "发布到 FCPX 检查器项:")
        pubBoxTitle.textColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        pubBoxTitle.font = .systemFont(ofSize: 11)
        mainStack.addArrangedSubview(pubBoxTitle)

        let pubRow1 = NSStackView()
        pubRow1.orientation = .horizontal
        pubRow1.spacing = 16
        publishTextCheck = NSButton(checkboxWithTitle: "发布文本内容", target: self, action: #selector(onPublishChannelsChanged))
        publishPosCheck  = NSButton(checkboxWithTitle: "发布位置坐标", target: self, action: #selector(onPublishChannelsChanged))
        publishTextCheck.state = .on
        publishPosCheck.state  = .on
        pubRow1.addArrangedSubview(publishTextCheck)
        pubRow1.addArrangedSubview(publishPosCheck)
        mainStack.addArrangedSubview(pubRow1)

        let pubRow2 = NSStackView()
        pubRow2.orientation = .horizontal
        pubRow2.spacing = 16
        publishRotCheck   = NSButton(checkboxWithTitle: "发布旋转角度", target: self, action: #selector(onPublishChannelsChanged))
        publishScaleCheck = NSButton(checkboxWithTitle: "发布缩放大小", target: self, action: #selector(onPublishChannelsChanged))
        pubRow2.addArrangedSubview(publishRotCheck)
        pubRow2.addArrangedSubview(publishScaleCheck)
        mainStack.addArrangedSubview(pubRow2)

        // ── 3. 底部操作按钮（R49 高度标准化 28pt 与磨砂质感对齐） ──
        let saveBtn = NSButton(title: " 保存当前模板至 FCPX", target: self, action: #selector(onSaveCurrentTemplateAction))
        saveBtn.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存")
        saveBtn.imagePosition = .imageLeading
        saveBtn.bezelStyle = .rounded
        saveBtn.font = .systemFont(ofSize: 12, weight: .medium)
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(saveBtn)
        saveBtn.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        saveBtn.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true
        saveBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        self.saveButton = saveBtn

        let exportBtn = NSButton(title: " 批量导出全套模板", target: self, action: #selector(onBatchExportAction))
        exportBtn.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "批量导出")
        exportBtn.imagePosition = .imageLeading
        exportBtn.bezelStyle = .rounded
        exportBtn.font = .systemFont(ofSize: 12, weight: .medium)
        exportBtn.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(exportBtn)
        exportBtn.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor).isActive = true
        exportBtn.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor).isActive = true
        exportBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        self.batchExportButton = exportBtn
    }

    // MARK: - @IBAction 动作插口
    @objc public func onOrientationToggled(_ sender: Any) {
        guard let layer = currentSelectedLayer else { return }
        if layer.writingDirection == "vertical" {
            layer.convertToHorizontal()
            toggleOrientationButton.image = NSImage(systemSymbolName: "arrow.up.and.down.text.horizontal", accessibilityDescription: "转为竖排")
            toggleOrientationButton.title = " 转为竖排版式"
        } else {
            layer.convertToVertical()
            toggleOrientationButton.image = NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: "转为横排")
            toggleOrientationButton.title = " 转为横排版式"
        }
        textEditor?.string = layer.text
        onLayerModified?(layer)
    }

    @objc public func onRotationChanged(_ sender: Any) {
        guard let layer = currentSelectedLayer else { return }
        let val = rotationSlider.doubleValue
        layer.rotation = round(val * 10) / 10.0
        rotationField.stringValue = "\(layer.rotation)°"
        onLayerModified?(layer)
    }

    @objc public func onScaleChanged(_ sender: Any) {
        guard let layer = currentSelectedLayer else { return }
        let val = scaleSlider.doubleValue
        layer.scaleX = round(val * 100) / 100.0
        layer.scaleY = layer.scaleX
        scaleField.stringValue = "\(Int(layer.scaleX * 100))%"
        onLayerModified?(layer)
    }

    @objc public func onPublishChannelsChanged(_ sender: Any) {
        guard let layer = currentSelectedLayer else { return }
        layer.publishText = (publishTextCheck.state == .on)
        layer.publishPosition = (publishPosCheck.state == .on)
        layer.publishRotation = (publishRotCheck.state == .on)
        layer.publishScale = (publishScaleCheck.state == .on)
    }

    @objc private func onTablePublishToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < layers.count else { return }
        layers[row].isPublished = (sender.state == .on)
        onLayerModified?(layers[row])
    }

    @objc public func onSaveCurrentTemplateAction(_ sender: Any) {
        onSaveTemplate?()
    }

    @objc public func onBatchExportAction(_ sender: Any) {
        onBatchExport?()
    }

    @objc private func onHiddenLayersToggled() {
        onHiddenLayersChanged?(hiddenLayersCheckbox.state == .on)
    }

    // MARK: - R45 表头总控全选/全部隐藏
    @objc public func toggleAllVisibility() {
        guard !layers.isEmpty else { return }
        let hasAnyVisible = layers.contains { $0.visible }
        let targetState = !hasAnyVisible
        for layer in layers {
            layer.visible = targetState
            onLayerModified?(layer)
        }
        layerTableView?.reloadData()
        onAllVisibilityToggled?(layers)
        if let first = layers.first {
            onLayerVisibilityChanged?(first)
        }
    }

    @objc private func onHeaderClicked(_ gesture: NSClickGestureRecognizer) {
        guard let header = layerTableView?.headerView else { return }
        let pt = gesture.location(in: header)
        let colIdx = layerTableView.column(at: pt)
        if colIdx >= 0 && colIdx < layerTableView.tableColumns.count {
            let col = layerTableView.tableColumns[colIdx]
            if col.identifier.rawValue == "vis" {
                toggleAllVisibility()
            }
        }
    }

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if tableColumn.identifier.rawValue == "vis" {
            toggleAllVisibility()
        }
    }

    @objc public func onVisibilityToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < layers.count else { return }
        let layer = layers[row]
        layer.visible.toggle()
        let symName = layer.visible ? "eye" : "eye.slash"
        sender.image = NSImage(systemSymbolName: symName, accessibilityDescription: layer.visible ? "显示" : "隐藏")
        sender.contentTintColor = layer.visible ? NSColor.controlAccentColor : NSColor(calibratedWhite: 0.45, alpha: 1.0)
        sender.toolTip = layer.visible ? "点击隐藏图层 (⌘H)" : "点击显示图层 (⌘H)"
        onLayerVisibilityChanged?(layer)
        onLayerModified?(layer)
    }

    @objc public func onLockToggled(_ sender: NSButton) {
        // TR-019-R：只读预览下不允许解锁，也不显示 ⌘L 解锁提示
        if motiReadOnlyMode {
            sender.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "只读")
            sender.toolTip = "只读，不可编辑"
            return
        }
        let row = sender.tag
        guard row >= 0 && row < layers.count else { return }
        let layer = layers[row]
        layer.isLocked.toggle()
        let symName = layer.isLocked ? "lock.fill" : "lock.open"
        sender.image = NSImage(systemSymbolName: symName, accessibilityDescription: layer.isLocked ? "锁定" : "解锁")
        sender.contentTintColor = layer.isLocked ? NSColor.systemYellow : NSColor(calibratedWhite: 0.45, alpha: 1.0)
        sender.toolTip = layer.isLocked ? "点击解锁图层 (⌘L)" : "点击锁定图层 (⌘L)"
        if currentSelectedLayer?.id == layer.id {
            updateControlStates(isLocked: layer.isLocked)
        }
        onLayerLockChanged?(layer)
        onLayerModified?(layer)
    }

    @objc private func onPosFieldChanged() {
        guard let layer = currentSelectedLayer else { return }
        if let x = Double(posXField.stringValue) {
            layer.posX = x
        }
        if let y = Double(posYField.stringValue) {
            layer.posY = y
        }
        onLayerModified?(layer)
    }

    // MARK: - TR-023-B 文字样式：动作
    /// 只读预览态 / 图层锁定态一律不许改（与 updateControlStates 同一处判据）。
    private var canEditTextStyle: Bool {
        guard let layer = currentSelectedLayer else { return false }
        return !motiReadOnlyMode && !layer.isLocked
    }

    @objc private func onFontSizeFieldCommitted() {
        guard let layer = currentSelectedLayer, canEditTextStyle else {
            refreshTextStyleControls()
            return
        }
        let raw = fontSizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value > 0 else {
            refreshTextStyleControls()
            return
        }
        let clamped = min(2000.0, max(1.0, value))
        layer.fontSize = (clamped * 10).rounded() / 10
        fontSizeField.stringValue = Self.formatFontSize(layer.fontSize)
        fontSizeStepper.doubleValue = layer.fontSize
        onLayerModified?(layer)
    }

    @objc private func onFontSizeStepperChanged() {
        guard let layer = currentSelectedLayer, canEditTextStyle else { return }
        let value = fontSizeStepper.doubleValue
        layer.fontSize = (value * 10).rounded() / 10
        fontSizeField.stringValue = Self.formatFontSize(layer.fontSize)
        onLayerModified?(layer)
    }

    @objc private func onAlignmentSegmentChanged() {
        guard let layer = currentSelectedLayer, canEditTextStyle else { return }
        switch alignmentSegment.selectedSegment {
        case 0: layer.alignment = "left"
        case 1: layer.alignment = "center"
        case 2: layer.alignment = "right"
        default: return
        }
        onLayerModified?(layer)
    }

    @objc private func onColorWellChanged() {
        guard let layer = currentSelectedLayer, canEditTextStyle else { return }
        let hex = Self.hexString(from: colorWell.color)
        layer.textColor = hex
        colorHexField.stringValue = hex
        onLayerModified?(layer)
    }

    @objc private func onColorHexFieldCommitted() {
        guard let layer = currentSelectedLayer, canEditTextStyle else {
            refreshTextStyleControls()
            return
        }
        guard let color = Self.color(fromHex: colorHexField.stringValue) else {
            // 输入不合法：回退到图层真值，不静默吞掉也不写入脏值
            refreshTextStyleControls()
            return
        }
        let hex = Self.hexString(from: color)
        layer.textColor = hex
        colorWell.color = color
        colorHexField.stringValue = hex
        onLayerModified?(layer)
    }

    @objc private func onReplaceFontClicked() {
        guard let layer = currentSelectedLayer, canEditTextStyle,
              let button = fontReplaceButton else { return }
        let menu = NSMenu()
        let current = NSMenuItem(title: "当前：\(layer.fontName)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())
        for family in NSFontManager.shared.availableFontFamilies.sorted() {
            let item = NSMenuItem(title: family, action: #selector(onPickFontFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 2),
                   in: button)
    }

    @objc private func onPickFontFamily(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        let postScript = (NSFontManager.shared.availableMembers(ofFontFamily: family)?
            .first?.first as? String) ?? family
        applyFontName(postScript)
    }

    /// 替换字体（harness 直接调这个，不依赖菜单弹出）。
    public func applyFontName(_ name: String) {
        guard let layer = currentSelectedLayer, canEditTextStyle else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        layer.fontName = trimmed
        fontNameLabel.stringValue = trimmed
        onLayerModified?(layer)
    }

    // MARK: - TR-023-B 文字样式：状态刷新

    /// 把当前选中图层的文字样式同步到控件。没数据的属性显示「—」并禁用。
    public func refreshTextStyleControls() {
        guard let layer = currentSelectedLayer else {
            fontSizeField?.stringValue = "—"
            fontSizeStepper?.doubleValue = 1
            alignmentSegment?.selectedSegment = -1
            colorHexField?.stringValue = "未取到"
            colorWell?.color = Self.emptyColorWellPlaceholder
            fontNameLabel?.stringValue = "未取到"
            applyTextStyleEnabledState()
            return
        }
        if layer.fontSize > 0 {
            fontSizeField?.stringValue = Self.formatFontSize(layer.fontSize)
            fontSizeStepper?.doubleValue = layer.fontSize
        } else {
            fontSizeField?.stringValue = "—"
            fontSizeStepper?.doubleValue = 1
        }
        switch layer.alignment.lowercased() {
        case "left":   alignmentSegment?.selectedSegment = 0
        case "center": alignmentSegment?.selectedSegment = 1
        case "right":  alignmentSegment?.selectedSegment = 2
        default:       alignmentSegment?.selectedSegment = -1
        }
        if let color = Self.color(fromHex: layer.textColor) {
            colorWell?.color = color
            colorHexField?.stringValue = Self.hexString(from: color)
        } else {
            colorWell?.color = Self.emptyColorWellPlaceholder
            colorHexField?.stringValue = "未取到"
        }
        fontNameLabel?.stringValue = layer.fontName.isEmpty ? "未取到" : layer.fontName
        applyTextStyleEnabledState()
    }

    /// 启用/禁用只跟「是否可编辑」和「该属性有没有真值」两件事有关。
    /// 空态一律给 toolTip 说明原因，不出现可点的 0 值控件。
    private func applyTextStyleEnabledState() {
        guard let layer = currentSelectedLayer else {
            fontSizeField?.isEnabled = false
            fontSizeStepper?.isEnabled = false
            alignmentSegment?.isEnabled = false
            colorWell?.isEnabled = false
            colorHexField?.isEnabled = false
            fontReplaceButton?.isEnabled = false
            return
        }
        let editable = canEditTextStyle
        let hasSize = layer.fontSize > 0
        let hasAlignment = !layer.alignment.isEmpty
        let hasColor = Self.color(fromHex: layer.textColor) != nil
        let hasFont = !layer.fontName.isEmpty

        fontSizeField?.isEnabled = editable && hasSize
        fontSizeStepper?.isEnabled = editable && hasSize
        alignmentSegment?.isEnabled = editable && hasAlignment
        colorWell?.isEnabled = editable && hasColor
        colorHexField?.isEnabled = editable && hasColor
        fontReplaceButton?.isEnabled = editable && hasFont

        fontSizeField?.toolTip = hasSize ? nil : "该图层没有字号数据（模板未写 Size / 大小）"
        fontSizeStepper?.toolTip = fontSizeField?.toolTip
        alignmentSegment?.toolTip = hasAlignment
            ? nil
            : "该图层没有左 / 中 / 右三档对齐数据（未写对齐，或为两端对齐等其它取值）"
        let colorTip = hasColor
            ? nil
            : "该图层没有取到文字填充色（物质/颜色 与 Object/Basic/Substance/Color 实测为空壳，不作取色源）"
        colorWell?.toolTip = colorTip
        colorHexField?.toolTip = colorTip
        fontReplaceButton?.toolTip = hasFont ? nil : "该图层没有字体名数据"
    }

    static func formatFontSize(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    /// 空态下 NSColorWell 的灰底：仅作占位，不代表任何取到的颜色。
    static let emptyColorWellPlaceholder = NSColor(calibratedWhite: 0.32, alpha: 1.0)

    /// "#RRGGBB" / "RRGGBB" → NSColor；非法返回 nil。
    static func color(fromHex hex: String) -> NSColor? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1.0)
    }

    /// NSColor → "#RRGGBB"（用 sRGB 分量，避免不同色彩空间换算漂移）。
    static func hexString(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ raw: CGFloat) -> Int { Int((max(0, min(1, raw)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      channel(rgb.redComponent),
                      channel(rgb.greenComponent),
                      channel(rgb.blueComponent))
    }

    public func updateControlStates(isLocked: Bool) {        // TR-019-R：只读预览态下横幅只显示「只读，不可编辑」
        lockBannerLabel?.stringValue = motiReadOnlyMode ? "只读，不可编辑" : "🔒 图层已锁定 (⌘L 解锁)"
        // TR-019-R：只读态统一用顶部常驻标签，原横幅不重复出现
        lockBannerBox?.isHidden = motiReadOnlyMode ? true : !isLocked
        toggleOrientationButton?.isEnabled = !isLocked
        textEditor?.isEditable = !isLocked
        textEditor?.textColor = isLocked ? NSColor(calibratedWhite: 0.45, alpha: 1.0) : .white
        rotationSlider?.isEnabled = !isLocked
        rotationField?.isEnabled = !isLocked
        scaleSlider?.isEnabled = !isLocked
        scaleField?.isEnabled = !isLocked
        posXField?.isEnabled = !isLocked
        posYField?.isEnabled = !isLocked
        publishTextCheck?.isEnabled = !isLocked
        publishPosCheck?.isEnabled = !isLocked
        publishRotCheck?.isEnabled = !isLocked
        publishScaleCheck?.isEnabled = !isLocked
        // TR-023-B：文字样式四项跟锁定态 / 只读态走同一处判据
        applyTextStyleEnabledState()
    }

    public func toggleCurrentLayerLock() {
        guard let layer = currentSelectedLayer,
              let idx = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layer.isLocked.toggle()
        updateControlStates(isLocked: layer.isLocked)
        layerTableView?.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integersIn: 0..<layerTableView.tableColumns.count))
        onLayerLockChanged?(layer)
        onLayerModified?(layer)
    }

    public func toggleCurrentLayerVisibility() {
        guard let layer = currentSelectedLayer,
              let idx = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layer.visible.toggle()
        layerTableView?.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integersIn: 0..<layerTableView.tableColumns.count))
        onLayerVisibilityChanged?(layer)
        onLayerModified?(layer)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == "l" {
                // TR-019-R：只读预览下吞掉 ⌘L，不解锁、不给解锁暗示
                if motiReadOnlyMode { return true }
                toggleCurrentLayerLock()
                return true
            } else if chars == "h" {
                toggleCurrentLayerVisibility()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public func selectLayer(at index: Int) {
        guard index >= 0 && index < layers.count else { return }
        currentSelectedLayer = layers[index]
        let layer = layers[index]

        textEditor?.string = layer.text
        let isVert = (layer.writingDirection == "vertical")
        toggleOrientationButton.image = NSImage(systemSymbolName: isVert ? "arrow.up.and.down.text.horizontal" : "text.aligncenter", accessibilityDescription: nil)
        toggleOrientationButton.imagePosition = .imageLeading
        toggleOrientationButton.title = isVert ? " 转为横排版式" : " 转为竖排版式"
        rotationSlider.doubleValue = layer.rotation
        rotationField.stringValue = "\(layer.rotation)°"
        scaleSlider.doubleValue = layer.scaleX
        scaleField.stringValue = "\(Int(layer.scaleX * 100))%"
        posXField.stringValue = "\(layer.posX)"
        posYField.stringValue = "\(layer.posY)"

        publishTextCheck.state = layer.publishText ? .on : .off
        publishPosCheck.state = layer.publishPosition ? .on : .off
        publishRotCheck.state = layer.publishRotation ? .on : .off
        publishScaleCheck.state = layer.publishScale ? .on : .off

        // TR-023-B：切图层时先把文字样式四项刷成该层的真值 / 空态
        refreshTextStyleControls()
        updateControlStates(isLocked: layer.isLocked)
    }

    public func updateFromCanvasMove(_ layer: LayerModel) {
        if currentSelectedLayer?.id == layer.id {
            posXField.stringValue = "\(layer.posX)"
            posYField.stringValue = "\(layer.posY)"
        }
    }

    // MARK: - NSTableViewDataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return layers.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let layer = layers[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        if id == "vis" {
            // R33 / A-70 / R36 / R45: 可见性状态按钮（SF Symbols eye / eye.slash）
            let symName = layer.visible ? "eye" : "eye.slash"
            let btn = NSButton()
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symName, accessibilityDescription: layer.visible ? "显示" : "隐藏")
            btn.tag = row
            btn.contentTintColor = layer.visible ? NSColor.controlAccentColor : NSColor(calibratedWhite: 0.45, alpha: 1.0)
            btn.toolTip = layer.visible ? "点击隐藏图层 (⌘H)" : "点击显示图层 (⌘H)"
            btn.target = self
            btn.action = #selector(onVisibilityToggled(_:))
            return btn
        } else if id == "lock" {
            // R36 / D-74 / R45: 锁定状态按钮（SF Symbols lock.fill / lock.open）
            let symName = layer.isLocked ? "lock.fill" : "lock.open"
            let btn = NSButton()
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symName, accessibilityDescription: layer.isLocked ? "锁定" : "解锁")
            btn.tag = row
            btn.contentTintColor = layer.isLocked ? NSColor.systemYellow : NSColor(calibratedWhite: 0.45, alpha: 1.0)
            btn.toolTip = motiReadOnlyMode
                ? "只读，不可编辑"
                : (layer.isLocked ? "点击解锁图层 (⌘L)" : "点击锁定图层 (⌘L)")
            btn.target = self
            btn.action = #selector(onLockToggled(_:))
            return btn
        } else if id == "name" {
            // R28 / A-51：缺字/缺字体风险逐层高亮（⚠ 徽标 + 橙色前景 + 悬停提示）
            if layer.highlightMissingFont {
                let tf = NSTextField(labelWithString: "⚠ \(layer.name)")
                tf.font = .systemFont(ofSize: 11)
                tf.textColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.2, alpha: 1.0)
                var tip = "缺字/字体风险（\(layer.fontStatus.isEmpty ? "未知" : layer.fontStatus)）：\(layer.missingGlyphReason)"
                if !layer.missingChars.isEmpty {
                    tip += "\n缺失字形: \(layer.missingChars.joined())"
                }
                if !layer.markedText.isEmpty {
                    tip += "\n预览（□ 表示缺字）: \(layer.markedText)"
                }
                tf.toolTip = tip
                return tf
            }
            let tf = NSTextField(labelWithString: layer.name)
            tf.textColor = .white
            tf.font = .systemFont(ofSize: 11)
            return tf
        } else if id == "pub" {
            let btn = NSButton(checkboxWithTitle: "发布", target: self, action: #selector(onTablePublishToggled(_:)))
            btn.tag = row
            btn.state = layer.isPublished ? .on : .off
            return btn
        }
        return nil
    }

    /// R32 / A-65 + R33 / A-69：判定抽到 ParseDiagnosticsState（纯逻辑，可直证）。
    /// 绿色「完整提取」只在无忽略层且两条层数守恒都成立时出现。
    public func updateDiagnostics(aspectRatio: String,
                                  resolutionSpec: String,
                                  width: CGFloat,
                                  height: CGFloat,
                                  warnings: [String],
                                  isValid: Bool = true,
                                  failureReason: String? = nil,
                                  layerCount: Int = -1,
                                  counts: PSDLayerCounts = .empty) {
        let state = ParseDiagnosticsState.resolve(
            isValid: isValid,
            failureReason: failureReason,
            warnings: warnings,
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            layerCount: layerCount,
            counts: counts
        )
        // TR-019-R：幅面规格常驻；诊断只把摘要放角标，全文进折叠区且默认折叠
        resolutionLabel?.stringValue = state.resolutionText
        resolutionLabel?.isHidden = false
        let firstLine = state.text.components(separatedBy: .newlines).first ?? state.text
        diagnosticsSummaryLabel?.stringValue = "ⓘ " + Self.short(firstLine)
        diagnosticsBox?.stringValue = state.text
        switch state.tone {
        case .red:    diagnosticsBox?.textColor = .systemRed
        case .orange: diagnosticsBox?.textColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.2, alpha: 1.0)
        case .green:  diagnosticsBox?.textColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.45, alpha: 1.0)
        }
        diagnosticsDetailBox?.isHidden = true
        diagnosticsToggleButton?.title = "详情"
        applyMotiReadOnlyText()
    }

    private static func short(_ s: String, limit: Int = 42) -> String {
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// TR-019-R：.moti 只读预览专用信息更新。
    /// 直接设置幅面规格与白话提示，绕开 PSD 的 ParseDiagnosticsState
    /// （它的 counts 为空时会输出「桥接未返回层数统计」这类技术黑话）。
    public func updateMotiReadOnlyInfo(canvasWidth: Int,
                                       canvasHeight: Int,
                                       layerCount: Int,
                                       notes: [String]) {
        motiReadOnlyMode = true
        resolutionLabel?.stringValue = "📐 幅面规格 \(canvasWidth)×\(canvasHeight)"
        resolutionLabel?.isHidden = false
        let summary = notes.first ?? "只读预览，共 \(layerCount) 层"
        diagnosticsSummaryLabel?.stringValue = "ⓘ " + Self.short(summary)
        diagnosticsBox?.stringValue = notes.joined(separator: "\n")
        diagnosticsBox?.textColor = NSColor(calibratedWhite: 0.86, alpha: 1.0)
        diagnosticsToggleButton?.title = "详情 (\(notes.count))"
        diagnosticsDetailBox?.isHidden = true   // 默认折叠
        applyMotiReadOnlyText()
    }

    /// 只读态：锁定横幅 / toolTip 一律改「只读，不可编辑」，不出现 ⌘L 解锁。
    private func applyMotiReadOnlyText() {
        let banner = motiReadOnlyMode ? "只读，不可编辑" : "🔒 图层已锁定 (⌘L 解锁)"
        lockBannerLabel?.stringValue = banner
        lockBannerLabel?.toolTip = motiReadOnlyMode ? "只读预览，不可编辑" : nil
        lockBannerBox?.toolTip = motiReadOnlyMode ? "只读，不可编辑" : nil
        // 常驻只读标签由本方法统一控制；原锁定横幅在只读态隐藏，避免两处重复
        readOnlyBadgeLabel?.isHidden = !motiReadOnlyMode
        if motiReadOnlyMode { lockBannerBox?.isHidden = true }

        // TR-019-R：只读态把图层表拉到 320pt、行高 20pt，11 行一次全可见；
        // 属性区控件本就不可编辑，整块隐藏腾出空间（NSStackView 对 hidden view 不分配高度）。
        tableScrollHeight?.constant = motiReadOnlyMode ? 320 : 180
        layerTableView?.rowHeight = motiReadOnlyMode ? 20 : 24
        if let stack = mainStackView,
           let idx = stack.arrangedSubviews.firstIndex(where: { $0.tag == motionPropsTag }) {
            for v in stack.arrangedSubviews.suffix(from: idx) {
                v.isHidden = motiReadOnlyMode
            }
        }

        // TR-023-B：只读态保留「文字样式」分组可见（全灰、只供查看真值），
        // 其余属性区继续隐藏，不挤占表格一次显示 11 行的空间。
        textStyleGroup?.isHidden = false
        textStyleTitleLabel?.stringValue = motiReadOnlyMode ? "文字样式（只读）" : "文字样式"
        refreshTextStyleControls()

        // TR-022-7：只读态整列移除「发布」（含表头），避免出现可勾选外观；
        // 退出只读态再加回。用对象身份判断，避免重复增删。
        if let pubCol = publishColumn, let table = layerTableView {
            let present = table.tableColumns.contains { $0 === pubCol }
            if motiReadOnlyMode && present {
                table.removeTableColumn(pubCol)
            } else if !motiReadOnlyMode && !present {
                table.addTableColumn(pubCol)
            }
        }

        layerTableView?.reloadData()
    }

    /// TR-022-5：真机测量「表格从上滚到底」耗时。滚动到最后一行的耗时，
    /// 连做 runs 次，返回 最小 / 平均（毫秒）与行数，用于 564 层模板性能验收。
    public func tr022MeasureScrollToBottom(runs: Int = 5) -> (min: Double, avg: Double, rows: Int) {
        guard let table = layerTableView, layers.count > 1 else { return (0, 0, layers.count) }
        let lastRow = layers.count - 1
        table.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(0)
        var times: [Double] = []
        for _ in 0..<max(1, runs) {
            table.scrollRowToVisible(0)
            let t0 = Date()
            table.scrollRowToVisible(lastRow)
            table.layoutSubtreeIfNeeded()
            times.append(Date().timeIntervalSince(t0) * 1000.0)
        }
        // 测完停在最底：用最后一行 rect 的 maxY 减可视高度算出精确 offset，必贴底。
        table.scrollRowToVisible(lastRow)
        table.layoutSubtreeIfNeeded()
        if let scroll = table.enclosingScrollView {
            let rowRect = table.rect(ofRow: lastRow)
            let clipH = scroll.contentView.bounds.height
            let targetY = max(0, rowRect.maxY - clipH)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let mx = times.min() ?? 0
        let avg = times.reduce(0, +) / Double(max(1, times.count))
        return ((mx * 10).rounded() / 10, (avg * 10).rounded() / 10, layers.count)
    }

    @objc private func onToggleDiagnostics(_ sender: NSButton) {
        guard let box = diagnosticsDetailBox else { return }
        box.isHidden.toggle()
        sender.title = box.isHidden ? "详情" : "收起"
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = layerTableView.selectedRow
        if row >= 0 {
            selectLayer(at: row)
        }
    }

    // MARK: – R46 字体文件拖拽接收协议
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = extractFontPaths(from: sender)
        guard !paths.isEmpty else { return [] }
        fontDropPromptBox.borderColor = NSColor.systemGreen
        fontDropPromptBox.fillColor = NSColor.systemGreen.withAlphaComponent(0.2)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = extractFontPaths(from: sender)
        return !paths.isEmpty ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        resetFontDropPromptStyle()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !extractFontPaths(from: sender).isEmpty
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        resetFontDropPromptStyle()
        let paths = extractFontPaths(from: sender)
        guard !paths.isEmpty else { return false }
        onFontsDropped?(paths)
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resetFontDropPromptStyle()
    }

    private func resetFontDropPromptStyle() {
        fontDropPromptBox.borderColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.9, alpha: 0.5)
        fontDropPromptBox.fillColor = NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 0.5)
    }

    private func extractFontPaths(from info: NSDraggingInfo) -> [String] {
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: classes, options: options)
        let urls = (objects as? [URL]) ?? []
        return urls.map { $0.path }.filter { FontInstaller.isFontFile(at: $0) || PSDImportPlanner.isFont($0) }
    }
}
