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
    public var diagnosticsBox: NSTextField!

    // R36 / D-74: 锁定横幅插口与回调
    public var lockBannerBox: NSView!
    public var lockBannerLabel: NSTextField!
    public var onLayerLockChanged: ((LayerModel) -> Void)?

    // 发布复选框插口
    public var publishTextCheck: NSButton!
    public var publishPosCheck: NSButton!
    public var publishRotCheck: NSButton!
    public var publishScaleCheck: NSButton!

    public var layers: [LayerModel] = [] {
        didSet {
            layerTableView?.reloadData()
            if !layers.isEmpty && currentSelectedLayer == nil {
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

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14)
        ])

        // ── 0. 画幅规格与转换诊断 ──
        resolutionLabel = NSTextField(labelWithString: "📐 画幅规格: 1920×1080 (16:9 横版宽屏)")
        resolutionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        resolutionLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        mainStack.addArrangedSubview(resolutionLabel)

        diagnosticsBox = NSTextField(wrappingLabelWithString: "✓ 矢量文字层完整提取")
        diagnosticsBox.font = .systemFont(ofSize: 10)
        diagnosticsBox.textColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.45, alpha: 1.0)
        diagnosticsBox.maximumNumberOfLines = 6
        mainStack.addArrangedSubview(diagnosticsBox)

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
        tableScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        tableScroll.hasVerticalScroller = true

        layerTableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 330, height: 140))
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

        lockBannerLabel = NSTextField(labelWithString: "🔒 图层已锁定，解锁后可修改属性")
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
        propTitle.font = .systemFont(ofSize: 12, weight: .bold)
        propTitle.textColor = NSColor(calibratedRed: 0.25, green: 0.65, blue: 1.0, alpha: 1.0)
        mainStack.addArrangedSubview(propTitle)

        // 横竖排一键切换按钮
        toggleOrientationButton = NSButton(title: " 转为横排版式", target: self, action: #selector(onOrientationToggled))
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

        // 坐标微调 X / Y
        let posStack = NSStackView()
        posStack.orientation = .horizontal
        posStack.spacing = 8
        posStack.addArrangedSubview(NSTextField(labelWithString: "X:"))
        posXField = NSTextField(string: "0.0")
        posXField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        posStack.addArrangedSubview(posXField)
        posStack.addArrangedSubview(NSTextField(labelWithString: "Y:"))
        posYField = NSTextField(string: "0.0")
        posYField.widthAnchor.constraint(equalToConstant: 80).isActive = true
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

    public func updateControlStates(isLocked: Bool) {
        lockBannerBox?.isHidden = !isLocked
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
            btn.toolTip = layer.isLocked ? "点击解锁图层 (⌘L)" : "点击锁定图层 (⌘L)"
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
        resolutionLabel.stringValue = state.resolutionText
        diagnosticsBox.stringValue = state.text
        switch state.tone {
        case .red:    diagnosticsBox.textColor = .systemRed
        case .orange: diagnosticsBox.textColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.2, alpha: 1.0)
        case .green:  diagnosticsBox.textColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.45, alpha: 1.0)
        }
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
