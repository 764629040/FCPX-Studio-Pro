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
    // TR-004: 多库选中支持
    public var selectedLibraries: [LibraryBundleItem] = []

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
        layer?.backgroundColor = ColorToken.cardBg.cgColor

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

        addLibraryButton = NSButton(title: "添加资源库…", target: self, action: #selector(onAddLibraryClicked))
        addLibraryButton.bezelStyle = .rounded

        openTrashButton = NSButton(title: "打开废纸篓", target: self, action: #selector(onOpenTrashClicked))
        openTrashButton.bezelStyle = .rounded

        statusSummaryLabel = NSTextField(labelWithString: "已就绪 · 可将剪辑盘 .fcpbundle 拖入扫描")
        statusSummaryLabel.textColor = .secondaryLabelColor
        statusSummaryLabel.font = TypeScale.footnote

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
        topBar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        splitStack.setContentHuggingPriority(.defaultLow, for: .vertical)

        // 左侧：资源库表格容器
        let leftBox = NSView()
        leftBox.wantsLayer = true
        leftBox.layer?.backgroundColor = ColorToken.panelBg.cgColor
        leftBox.layer?.cornerRadius = CornerRadius.card
        leftBox.layer?.borderWidth = 0.8
        leftBox.layer?.borderColor = ColorToken.cardBorder.cgColor
        leftBox.translatesAutoresizingMaskIntoConstraints = false

        // TR-004: 左侧头部工具条：资源库标题与「全选 / 取消全选」按钮
        let leftHeader = NSStackView()
        leftHeader.orientation = .horizontal
        leftHeader.alignment = .centerY
        leftHeader.distribution = .fill
        leftHeader.translatesAutoresizingMaskIntoConstraints = false
        leftBox.addSubview(leftHeader)

        let leftTitle = NSTextField(labelWithString: "发现的 .fcpbundle 资源库")
        leftTitle.font = TypeScale.footnoteMedium
        leftTitle.textColor = .white
        leftHeader.addArrangedSubview(leftTitle)

        let toggleAllLibsBtn = NSButton(title: "全选 / 取消全选 (⌘A)", target: self, action: #selector(onToggleSelectAllLibrariesClicked))
        toggleAllLibsBtn.bezelStyle = .inline
        toggleAllLibsBtn.font = TypeScale.caption
        leftHeader.addArrangedSubview(toggleAllLibsBtn)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        leftBox.addSubview(scroll)

        NSLayoutConstraint.activate([
            leftHeader.topAnchor.constraint(equalTo: leftBox.topAnchor, constant: 8),
            leftHeader.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 10),
            leftHeader.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -10),
            leftHeader.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: leftHeader.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leftBox.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: leftBox.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: leftBox.bottomAnchor, constant: -6)
        ])

        libraryTableView = NSTableView()
        libraryTableView.headerView = NSTableHeaderView()
        libraryTableView.rowHeight = 32
        libraryTableView.gridStyleMask = .solidHorizontalGridLineMask
        libraryTableView.usesAlternatingRowBackgroundColors = false
        // TR-004: 开启多选支持与 ⌘A
        libraryTableView.allowsMultipleSelection = true
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

        // 右侧：瘦身详情与操作面板 (UI-G043)
        let rightBox = NSView()
        rightBox.wantsLayer = true
        rightBox.layer?.backgroundColor = ColorToken.panelBg.cgColor
        rightBox.layer?.cornerRadius = CornerRadius.card
        rightBox.layer?.borderWidth = 0.8
        rightBox.layer?.borderColor = ColorToken.cardBorder.cgColor
        rightBox.translatesAutoresizingMaskIntoConstraints = false

        let rightScroll = NSScrollView()
        rightScroll.drawsBackground = false
        rightScroll.hasVerticalScroller = true
        rightScroll.translatesAutoresizingMaskIntoConstraints = false
        rightBox.addSubview(rightScroll)

        let rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightScroll.documentView = rightStack

        NSLayoutConstraint.activate([
            rightScroll.topAnchor.constraint(equalTo: rightBox.topAnchor, constant: 14),
            rightScroll.leadingAnchor.constraint(equalTo: rightBox.leadingAnchor, constant: 14),
            rightScroll.trailingAnchor.constraint(equalTo: rightBox.trailingAnchor, constant: -14),
            rightScroll.bottomAnchor.constraint(equalTo: rightBox.bottomAnchor, constant: -14),
            rightStack.widthAnchor.constraint(equalTo: rightScroll.widthAnchor)
        ])

        detailTitleLabel = NSTextField(labelWithString: "未选择资源库")
        detailTitleLabel.font = TypeScale.metricTitle

        detailPathLabel = NSTextField(labelWithString: "")
        detailPathLabel.font = TypeScale.footnote
        detailPathLabel.textColor = .secondaryLabelColor
        detailPathLabel.lineBreakMode = .byTruncatingMiddle

        // 容量可视化进度条
        storageBarView = LibraryStorageBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        storageBarView.translatesAutoresizingMaskIntoConstraints = false
        storageBarView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        // 安全提示
        detailOriginalMediaLabel = NSTextField(labelWithString: "原始素材: -- (最高安全级别，100% 绝对保护)")
        detailOriginalMediaLabel.font = TypeScale.footnote
        detailOriginalMediaLabel.textColor = ColorToken.successGreen

        detailCleanableLabel = NSTextField(labelWithString: "可安全清理: --")
        detailCleanableLabel.font = TypeScale.bodyBold
        detailCleanableLabel.textColor = ColorToken.warningAmber

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

        cleanAllButton = NSButton(title: "安全清理全部缓存", target: self, action: #selector(onCleanAllClicked))
        cleanAllButton.bezelStyle = .rounded
        cleanAllButton.contentTintColor = ColorToken.successGreen

        cleanSelectedButton = NSButton(title: "清理所选缓存", target: self, action: #selector(onCleanSelectedClicked))
        cleanSelectedButton.bezelStyle = .rounded

        revealButton = NSButton(title: "在访达中显示", target: self, action: #selector(onRevealClicked))
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

    // TR-004: 全选/取消全选资源库
    @objc public func onToggleSelectAllLibrariesClicked() {
        if libraryTableView.selectedRowIndexes.count == libraries.count && !libraries.isEmpty {
            libraryTableView.deselectAll(nil)
        } else {
            libraryTableView.selectAll(nil)
        }
    }

    @objc public func onCleanAllClicked() {
        let targets = selectedLibraries.isEmpty ? (selectedLibrary != nil ? [selectedLibrary!] : []) : selectedLibraries
        guard !targets.isEmpty else { return }

        let count = targets.count
        let totalCleanableBytes = targets.reduce(0) { $0 + $1.cleanableSizeBytes }
        let totalFormatted = ByteCountFormatter.string(fromByteCount: totalCleanableBytes, countStyle: .file)

        let alert = NSAlert()
        alert.messageText = "确认一键安全瘦身全部缓存？"
        alert.informativeText = "即将对 \(count) 个资源库共 \(totalFormatted) 缓存执行深度瘦身。\n\n• 原始拍摄素材 (Original Media): 100% 绝对安全不触碰\n• 清理项将安全移入 macOS 废纸篓，可随时放回原处。"
        alert.addButton(withTitle: "安全移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            executeBatchClean(items: targets, categories: nil)
        }
    }

    @objc public func onCleanSelectedClicked() {
        let targets = selectedLibraries.isEmpty ? (selectedLibrary != nil ? [selectedLibrary!] : []) : selectedLibraries
        guard !targets.isEmpty else { return }

        let count = targets.count
        let totalCleanableBytes: Int64
        let selectedCats: Set<LibraryCacheCategory>?

        if count == 1 {
            let item = targets[0]
            let cats = Set(item.cacheDetails.filter { $0.isSelected }.map { $0.category })
            guard !cats.isEmpty else {
                cleanResultLabel.stringValue = "请先勾选至少一项要瘦身的缓存分类"
                return
            }
            selectedCats = cats
            totalCleanableBytes = item.selectedCleanableSizeBytes
        } else {
            selectedCats = nil
            totalCleanableBytes = targets.reduce(0) { $0 + $1.cleanableSizeBytes }
        }

        let totalFormatted = ByteCountFormatter.string(fromByteCount: totalCleanableBytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "确认执行所选资源库瘦身？"
        alert.informativeText = "即将对 \(count) 个资源库共 \(totalFormatted) 缓存执行瘦身，原始素材 100% 不触碰，清理项移入废纸篓。"
        alert.addButton(withTitle: "安全移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            executeBatchClean(items: targets, categories: selectedCats)
        }
    }

    private func executeBatchClean(items: [LibraryBundleItem], categories: Set<LibraryCacheCategory>?) {
        spinner.startAnimation(nil)
        cleanResultLabel.stringValue = "正在安全移入废纸篓 (0/\(items.count))…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var totalFreed: Int64 = 0
            var countSuccess = 0
            for (idx, it) in items.enumerated() {
                let res = LibraryCleaner.shared.safeClean(item: it, categoriesToClean: categories)
                totalFreed += res.bytesFreed
                countSuccess += 1
                if let updated = LibraryCleaner.shared.analyzeBundle(at: it.url) {
                    DispatchQueue.main.async {
                        if let localIdx = self?.libraries.firstIndex(where: { $0.path == it.path }) {
                            self?.libraries[localIdx] = updated
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.cleanResultLabel.stringValue = "正在处理 (\(idx + 1)/\(items.count))…"
                }
            }

            let freedFormatted = ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.cleanResultLabel.stringValue = "批量瘦身完成！共为 \(countSuccess) 个资源库释放 \(freedFormatted) 空间。"
                self?.libraryTableView.reloadData()
                let rows = self?.libraryTableView.selectedRowIndexes ?? IndexSet()
                self?.selectedLibraries = rows.compactMap { idx in
                    guard let libs = self?.libraries, idx >= 0 && idx < libs.count else { return nil }
                    return libs[idx]
                }
                self?.selectedLibrary = self?.selectedLibraries.first
                self?.updateDetailPanel()
            }
        }
    }

    @objc public func onRevealClicked() {
        guard let item = selectedLibrary else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: – Detail View Updates

    private func updateDetailPanel() {
        guard !selectedLibraries.isEmpty || selectedLibrary != nil else {
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

        let isMulti = selectedLibraries.count > 1
        if isMulti {
            let count = selectedLibraries.count
            let totalBytes = selectedLibraries.reduce(0) { $0 + $1.totalSizeBytes }
            let totalCleanable = selectedLibraries.reduce(0) { $0 + $1.cleanableSizeBytes }
            let totalOriginal = selectedLibraries.reduce(0) { $0 + $1.originalMediaSizeBytes }
            let cleanFormatted = ByteCountFormatter.string(fromByteCount: totalCleanable, countStyle: .file)
            let origFormatted = ByteCountFormatter.string(fromByteCount: totalOriginal, countStyle: .file)

            detailTitleLabel.stringValue = "📦 已选择 \(count) 个资源库"
            detailPathLabel.stringValue = "\(count) 个跨盘或本地资源库已全选就绪"
            detailOriginalMediaLabel.stringValue = "🛡️ 原始拍摄素材总计: \(origFormatted) (最高安全级别，100% 保护)"
            detailCleanableLabel.stringValue = "🧹 累计可安全瘦身: \(cleanFormatted)"

            let total = Double(max(totalBytes, 1))
            let origRatio = Double(totalOriginal) / total
            let cleanRatio = Double(totalCleanable) / total
            storageBarView.updateRatios(original: origRatio, cache: cleanRatio)

            cleanAllButton.isEnabled = totalCleanable > 0
            cleanSelectedButton.isEnabled = totalCleanable > 0
            revealButton.isEnabled = true
        } else if let item = selectedLibrary {
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
        }

        // 重新构建分类勾选列表
        categoryStackView.subviews.forEach { $0.removeFromSuperview() }

        guard let currentItem = selectedLibrary else { return }

        // TR-004: 分类勾选区顶部增加「全选 / 全不选」按钮
        let catHeaderRow = NSStackView()
        catHeaderRow.orientation = .horizontal
        catHeaderRow.spacing = 8
        catHeaderRow.alignment = .centerY

        let catHeaderTitle = NSTextField(labelWithString: "细分缓存项目 (多选时按公共分类应用)：")
        catHeaderTitle.font = TypeScale.footnoteMedium
        catHeaderTitle.textColor = .white
        catHeaderRow.addArrangedSubview(catHeaderTitle)

        let toggleAllCatsBtn = NSButton(title: "全选 / 全不选分类", target: self, action: #selector(onToggleAllCategoriesClicked))
        toggleAllCatsBtn.bezelStyle = .inline
        toggleAllCatsBtn.font = TypeScale.caption
        catHeaderRow.addArrangedSubview(toggleAllCatsBtn)
        categoryStackView.addArrangedSubview(catHeaderRow)

        if currentItem.cacheDetails.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "✨ 该工程非常清爽，无冗余渲染或代理缓存！")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            categoryStackView.addArrangedSubview(emptyLabel)
        } else {
            for (idx, detail) in currentItem.cacheDetails.enumerated() {
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

    @objc private func onToggleAllCategoriesClicked() {
        guard !libraries.isEmpty else { return }
        if selectedLibraries.count > 1 {
            let anyUnselected = selectedLibraries.contains { lib in lib.cacheDetails.contains { !$0.isSelected } }
            let newState = anyUnselected
            for i in 0..<selectedLibraries.count {
                for j in 0..<selectedLibraries[i].cacheDetails.count {
                    selectedLibraries[i].cacheDetails[j].isSelected = newState
                }
            }
            if var first = selectedLibrary {
                for j in 0..<first.cacheDetails.count {
                    first.cacheDetails[j].isSelected = newState
                }
                selectedLibrary = first
            }
        } else if var item = selectedLibrary {
            let anyUnselected = item.cacheDetails.contains { !$0.isSelected }
            for j in 0..<item.cacheDetails.count {
                item.cacheDetails[j].isSelected = anyUnselected
            }
            selectedLibrary = item
        }
        updateDetailPanel()
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
                ? ColorToken.statusWarning
                : .secondaryLabelColor
            cell.alignment = .right
        case "colSafety":
            cell.stringValue = "🛡️ 原始素材安全"
            cell.textColor = ColorToken.statusNormal
        default:
            break
        }

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let rows = libraryTableView.selectedRowIndexes
        selectedLibraries = rows.compactMap { idx in
            guard idx >= 0 && idx < libraries.count else { return nil }
            return libraries[idx]
        }
        selectedLibrary = selectedLibraries.first
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
            ColorToken.statusNormal.setFill()
            path.fill()
        }

        // 2. 缓存区域（醒目橙黄色）
        if cacheWidth > 0 {
            let cacheRect = NSRect(x: origWidth, y: 0, width: min(cacheWidth, totalWidth - origWidth), height: bounds.height)
            let path = NSBezierPath(rect: cacheRect)
            ColorToken.statusWarning.setFill()
            path.fill()
        }
    }
}
