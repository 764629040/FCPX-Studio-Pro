import AppKit
import Foundation
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════
//  CleanerDashboardView.swift —— FCPX 资源库深度安全瘦身医生控制台
//  对标基准：/Applications/嘉星插件管理 2.app (FxXuCleanerCore / LibraryCleanerItems)
// ═══════════════════════════════════════════════════════════════

public final class CleanerDashboardView: NSView,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate {

    // MARK: – UI Controls
    public var scanButton: NSButton!
    public var addLibraryButton: NSButton!
    public var openTrashButton: NSButton!
    public var statusSummaryLabel: NSTextField!

    public var libraryTableView: NSTableView!
    public var cleanAllButton: NSButton!
    public var cleanSelectedButton: NSButton!
    public var revealButton: NSButton!

    public var detailTitleLabel: NSTextField!
    public var detailPathLabel: NSTextField!
    public var detailOriginalMediaLabel: NSTextField!
    public var detailCleanableLabel: NSTextField!
    public var storageBarView: LibraryStorageBarView!
    public var categoryStackView: NSStackView!
    public var cleanResultLabel: NSTextField!
    public var spinner: NSProgressIndicator!

    // MARK: – Data
    public private(set) var libraries: [LibraryBundleItem] = []
    public var selectedLibrary: LibraryBundleItem?

    // MARK: – Init
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: – Layout Setup
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor

        // 顶层垂直主布局
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        // 1. 顶部控制栏
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        scanButton = NSButton(title: "🔄 扫描资源库", target: self, action: #selector(onScanClicked))
        scanButton.bezelStyle = .rounded

        addLibraryButton = NSButton(title: "📂 添加资源库…", target: self, action: #selector(onAddLibraryClicked))
        addLibraryButton.bezelStyle = .rounded

        openTrashButton = NSButton(title: "🗑️ 打开废纸篓", target: self, action: #selector(onOpenTrashClicked))
        openTrashButton.bezelStyle = .rounded

        statusSummaryLabel = NSTextField(labelWithString: "正在就绪… 支持将剪辑盘的任意 .fcpbundle 拖拽至此处扫描")
        statusSummaryLabel.textColor = .secondaryLabelColor
        statusSummaryLabel.font = .systemFont(ofSize: 12)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        topBar.addArrangedSubview(scanButton)
        topBar.addArrangedSubview(addLibraryButton)
        topBar.addArrangedSubview(openTrashButton)
        topBar.addArrangedSubview(spinner)
        topBar.addArrangedSubview(statusSummaryLabel)

        mainStack.addArrangedSubview(topBar)

        // 2. 主体左右分栏
        let splitStack = NSStackView()
        splitStack.orientation = .horizontal
        splitStack.distribution = .fill
        splitStack.spacing = 14
        splitStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(splitStack)

        splitStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        splitStack.heightAnchor.constraint(equalTo: mainStack.heightAnchor, constant: -50).isActive = true

        // 左侧：资源库表格容器
        let leftBox = NSView()
        leftBox.wantsLayer = true
        leftBox.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).cgColor
        leftBox.layer?.cornerRadius = 8
        leftBox.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        leftBox.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: -6)
        ])

        libraryTableView = NSTableView()
        libraryTableView.headerView = NSTableHeaderView()
        libraryTableView.rowHeight = 36
        libraryTableView.usesAlternatingRowBackgroundColors = true
        libraryTableView.dataSource = self
        libraryTableView.delegate = self

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colName"))
        colName.title = "资源库名称"
        colName.width = 200
        libraryTableView.addTableColumn(colName)

        let colTotal = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colTotal"))
        colTotal.title = "总占用"
        colTotal.width = 80
        libraryTableView.addTableColumn(colTotal)

        let colCleanable = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colCleanable"))
        colCleanable.title = "可瘦身体积"
        colCleanable.width = 90
        libraryTableView.addTableColumn(colCleanable)

        let colSafety = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("colSafety"))
        colSafety.title = "安全状态"
        colSafety.width = 110
        libraryTableView.addTableColumn(colSafety)

        scroll.documentView = libraryTableView

        splitStack.addArrangedSubview(leftBox)
        leftBox.widthAnchor.constraint(equalTo: splitStack.widthAnchor, multiplier: 0.52).isActive = true

        // 右侧：瘦身详情与操作面板
        let rightBox = NSView()
        rightBox.wantsLayer = true
        rightBox.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0).cgColor
        rightBox.layer?.cornerRadius = 8
        rightBox.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(rightStack)

        NSLayoutConstraint.activate([
            rightStack.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 14),
            rightStack.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 14),
            rightStack.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -14),
            rightStack.bottomAnchor.constraint(lessThanOrEqualTo: rightBox.bottomAnchor, constant: -14)
        ])

        detailTitleLabel = NSTextField(labelWithString: "未选择资源库")
        detailTitleLabel.font = .systemFont(ofSize: 15, weight: .bold)

        detailPathLabel = NSTextField(labelWithString: "")
        detailPathLabel.font = .systemFont(ofSize: 11)
        detailPathLabel.textColor = .secondaryLabelColor
        detailPathLabel.lineBreakMode = .byTruncatingMiddle

        // 容量可视化进度条
        storageBarView = LibraryStorageBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        storageBarView.translatesAutoresizingMaskIntoConstraints = false
        storageBarView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        // 安全提示
        detailOriginalMediaLabel = NSTextField(labelWithString: "🛡️ 原始素材: -- (最高安全级别，100% 绝对保护)")
        detailOriginalMediaLabel.font = .systemFont(ofSize: 12)
        detailOriginalMediaLabel.textColor = NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)

        detailCleanableLabel = NSTextField(labelWithString: "🧹 可安全瘦身: --")
        detailCleanableLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailCleanableLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)

        // 缓存细项勾选列表
        categoryStackView = NSStackView()
        categoryStackView.orientation = .vertical
        categoryStackView.alignment = .leading
        categoryStackView.spacing = 6
        categoryStackView.translatesAutoresizingMaskIntoConstraints = false

        // 操作按钮行
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        cleanAllButton = NSButton(title: "⚡ 一键安全瘦身 (Safe Clean All)", target: self, action: #selector(onCleanAllClicked))
        cleanAllButton.bezelStyle = .rounded
        cleanAllButton.contentTintColor = NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)

        cleanSelectedButton = NSButton(title: "🧹 清理所选缓存", target: self, action: #selector(onCleanSelectedClicked))
        cleanSelectedButton.bezelStyle = .rounded

        revealButton = NSButton(title: "🔍 在访达中定位", target: self, action: #selector(onRevealClicked))
        revealButton.bezelStyle = .rounded

        actionRow.addArrangedSubview(cleanAllButton)
        actionRow.addArrangedSubview(cleanSelectedButton)
        actionRow.addArrangedSubview(revealButton)

        cleanResultLabel = NSTextField(labelWithString: "")
        cleanResultLabel.font = .systemFont(ofSize: 12)
        cleanResultLabel.textColor = .secondaryLabelColor

        rightStack.addArrangedSubview(detailTitleLabel)
        rightStack.addArrangedSubview(detailPathLabel)
        rightStack.addArrangedSubview(storageBarView)
        rightStack.addArrangedSubview(detailOriginalMediaLabel)
        rightStack.addArrangedSubview(detailCleanableLabel)
        rightStack.addArrangedSubview(categoryStackView)
        rightStack.addArrangedSubview(actionRow)
        rightStack.addArrangedSubview(cleanResultLabel)

        splitStack.addArrangedSubview(rightBox)
        rightBox.widthAnchor.constraint(equalTo: splitStack.widthAnchor, multiplier: 0.48).isActive = true

        updateDetailPanel()
    }

    // MARK: – Actions & Data Loading

    @objc public func onScanClicked() {
        startScanning()
    }

    public func startScanning(searchRoots: [String]? = nil) {
        spinner.startAnimation(nil)
        statusSummaryLabel.stringValue = "正在深度穿透扫描 Final Cut Pro 资源库…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discovered = LibraryCleaner.shared.scanLibraries(searchRoots: searchRoots)
            let totalBytes = discovered.reduce(0) { $0 + $1.cleanableSizeBytes }
            let totalFormatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.libraries = discovered
                self?.libraryTableView.reloadData()
                self?.statusSummaryLabel.stringValue = "扫描完成！共发现 \(discovered.count) 个资源库，累计可瘦身 \(totalFormatted)"

                if !discovered.isEmpty {
                    self?.libraryTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self?.selectedLibrary = discovered[0]
                } else {
                    self?.selectedLibrary = nil
                }
                self?.updateDetailPanel()
            }
        }
    }

    public func addLibrary(at url: URL) {
        guard let item = LibraryCleaner.shared.analyzeBundle(at: url) else {
            statusSummaryLabel.stringValue = "非有效 Final Cut Pro 资源库: \(url.lastPathComponent)"
            return
        }

        // 避免重复添加
        if let idx = libraries.firstIndex(where: { $0.path == item.path }) {
            libraries[idx] = item
            libraryTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            selectedLibrary = item
        } else {
            libraries.insert(item, at: 0)
            libraryTableView.reloadData()
            libraryTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectedLibrary = item
        }
        statusSummaryLabel.stringValue = "成功载入资源库: \(item.name)（可瘦身 \(item.cleanableSizeFormatted)）"
        updateDetailPanel()
    }

    @objc public func onAddLibraryClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // FCPX-054: 限制仅选取资源库包与文件夹，防止选取任意无关文件
        if let fcpType = UTType(filenameExtension: "fcpbundle") {
            panel.allowedContentTypes = [fcpType, .folder, .bundle]
        } else {
            panel.allowedContentTypes = [.folder, .bundle]
        }
        panel.prompt = "选择资源库"

        if panel.runModal() == .OK {
            for url in panel.urls {
                addLibrary(at: url)
            }
        }
    }

    @objc public func onOpenTrashClicked() {
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(trashURL)
        }
    }

    @objc public func onCleanAllClicked() {
        guard let item = selectedLibrary else { return }

        let alert = NSAlert()
        alert.messageText = "确认一键安全瘦身？"
        alert.informativeText = "即将对【\(item.name)】执行深度瘦身。\n\n• 预计清理: \(item.cleanableSizeFormatted)\n• 原始拍摄素材 (Original Media): 100% 绝对安全不触碰\n• 清理操作将安全移入 macOS 废纸篓，可随时放回原处。"
        alert.addButton(withTitle: "安全移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            executeClean(item: item, categories: nil)
        }
    }

    @objc public func onCleanSelectedClicked() {
        guard let item = selectedLibrary else { return }
        let selectedCats = Set(item.cacheDetails.filter { $0.isSelected }.map { $0.category })
        guard !selectedCats.isEmpty else {
            cleanResultLabel.stringValue = "请先勾选至少一项要瘦身的缓存分类"
            return
        }

        executeClean(item: item, categories: selectedCats)
    }

    private func executeClean(item: LibraryBundleItem, categories: Set<LibraryCacheCategory>?) {
        spinner.startAnimation(nil)
        cleanResultLabel.stringValue = "正在安全移入废纸篓…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LibraryCleaner.shared.safeClean(item: item, categoriesToClean: categories)

            // 重新分析该资源库最新体积
            let updated = LibraryCleaner.shared.analyzeBundle(at: item.url)

            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.cleanResultLabel.stringValue = result.summaryMessage

                if let up = updated, let idx = self?.libraries.firstIndex(where: { $0.path == item.path }) {
                    self?.libraries[idx] = up
                    self?.selectedLibrary = up
                    self?.libraryTableView.reloadData()
                    self?.updateDetailPanel()
                }
            }
        }
    }

    @objc public func onRevealClicked() {
        guard let item = selectedLibrary else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: – Detail View Updates

    private func updateDetailPanel() {
        guard let item = selectedLibrary else {
            detailTitleLabel.stringValue = "未选择资源库"
            detailPathLabel.stringValue = "请在左侧列表中点击选择，或将 .fcpbundle 拖拽至窗口"
            detailOriginalMediaLabel.stringValue = "🛡️ 原始素材: --"
            detailCleanableLabel.stringValue = "🧹 可安全瘦身: --"
            storageBarView.updateRatios(original: 0, cache: 0)
            categoryStackView.subviews.forEach { $0.removeFromSuperview() }
            cleanAllButton.isEnabled = false
            cleanSelectedButton.isEnabled = false
            revealButton.isEnabled = false
            return
        }

        detailTitleLabel.stringValue = "📦 \(item.name)"
        detailPathLabel.stringValue = item.path
        detailOriginalMediaLabel.stringValue = "🛡️ 原始拍摄素材: \(item.originalMediaFormatted) (最高安全级别，绝不触碰)"
        detailCleanableLabel.stringValue = "🧹 可安全瘦身体积: \(item.cleanableSizeFormatted) (瘦身率 \(item.slimmingRatioText))"

        let total = Double(max(item.totalSizeBytes, 1))
        let origRatio = Double(item.originalMediaSizeBytes) / total
        let cleanRatio = Double(item.cleanableSizeBytes) / total
        storageBarView.updateRatios(original: origRatio, cache: cleanRatio)

        cleanAllButton.isEnabled = item.cleanableSizeBytes > 0
        cleanSelectedButton.isEnabled = item.selectedCleanableSizeBytes > 0
        revealButton.isEnabled = true

        // 重新构建分类勾选列表
        categoryStackView.subviews.forEach { $0.removeFromSuperview() }

        if item.cacheDetails.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "✨ 该工程非常清爽，无冗余渲染或代理缓存！")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            categoryStackView.addArrangedSubview(emptyLabel)
        } else {
            for (idx, detail) in item.cacheDetails.enumerated() {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                row.alignment = .centerY

                let check = NSButton(checkboxWithTitle: "\(detail.category.shortBadge) \(detail.category.displayName)  (\(detail.formattedSize))",
                                     target: self, action: #selector(onCategoryCheckboxToggled(_:)))
                check.tag = idx
                check.state = detail.isSelected ? .on : .off

                let note = NSTextField(labelWithString: "• \(detail.category.safetyNote)")
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor

                row.addArrangedSubview(check)
                row.addArrangedSubview(note)
                categoryStackView.addArrangedSubview(row)
            }
        }
    }

    @objc private func onCategoryCheckboxToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard var item = selectedLibrary, idx < item.cacheDetails.count else { return }
        item.cacheDetails[idx].isSelected = (sender.state == .on)
        selectedLibrary = item
        cleanSelectedButton.isEnabled = item.selectedCleanableSizeBytes > 0
    }

    // MARK: – NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return libraries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < libraries.count else { return nil }
        let item = libraries[row]
        let colId = tableColumn?.identifier.rawValue ?? ""

        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)

        switch colId {
        case "colName":
            cell.stringValue = "📦 \(item.name)"
            cell.font = .systemFont(ofSize: 12, weight: .medium)
        case "colTotal":
            cell.stringValue = item.totalSizeFormatted
            cell.alignment = .right
        case "colCleanable":
            cell.stringValue = item.cleanableSizeFormatted
            cell.textColor = item.cleanableSizeBytes > 0
                ? NSColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
                : .secondaryLabelColor
            cell.alignment = .right
        case "colSafety":
            cell.stringValue = "🛡️ 原始素材安全"
            cell.textColor = NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)
        default:
            break
        }

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = libraryTableView.selectedRow
        if row >= 0 && row < libraries.count {
            selectedLibrary = libraries[row]
        } else {
            selectedLibrary = nil
        }
        updateDetailPanel()
    }

    // MARK: – 拖拽扫描支持

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if let types = pb.types, types.contains(.fileURL) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }

        for url in urls {
            if url.pathExtension == "fcpbundle" || LibraryCleaner.shared.isFCPXBundle(at: url) {
                addLibrary(at: url)
            }
        }
        return true
    }
}

// ═══════════════════════════════════════════════════════════════
//  容量可视化彩色比例条 (LibraryStorageBarView)
// ═══════════════════════════════════════════════════════════════

public final class LibraryStorageBarView: NSView {
    private var originalRatio: Double = 0.0
    private var cacheRatio: Double = 0.0

    public func updateRatios(original: Double, cache: Double) {
        self.originalRatio = max(0, min(original, 1.0))
        self.cacheRatio = max(0, min(cache, 1.0))
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor(white: 0.2, alpha: 1.0).setFill()
        bgPath.fill()

        let totalWidth = bounds.width
        let origWidth = totalWidth * CGFloat(originalRatio)
        let cacheWidth = totalWidth * CGFloat(cacheRatio)

        // 1. 原始素材（安全绿色）
        if origWidth > 0 {
            let origRect = NSRect(x: 0, y: 0, width: origWidth, height: bounds.height)
            let path = NSBezierPath(roundedRect: origRect, xRadius: 4, yRadius: 4)
            NSColor(red: 0.2, green: 0.75, blue: 0.4, alpha: 1.0).setFill()
            path.fill()
        }

        // 2. 缓存区域（醒目橙黄色）
        if cacheWidth > 0 {
            let cacheRect = NSRect(x: origWidth, y: 0, width: min(cacheWidth, totalWidth - origWidth), height: bounds.height)
            let path = NSBezierPath(rect: cacheRect)
            NSColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0).setFill()
            path.fill()
        }
    }
}
