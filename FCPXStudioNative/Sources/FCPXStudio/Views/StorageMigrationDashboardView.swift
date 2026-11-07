import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  StorageMigrationDashboardView —— 外置盘搬家与存储管理中心（R42 对标嘉星）
// ═══════════════════════════════════════════════════════════════

public final class StorageMigrationDashboardView: NSView,
                                                  NSTableViewDataSource,
                                                  NSTableViewDelegate {

    // MARK: – Top Controls
    public var refreshButton: NSButton!
    public var migrateAllButton: NSButton!
    public var restoreAllButton: NSButton!
    public var spinner: NSProgressIndicator!
    public var statusLabel: NSTextField!

    // MARK: – Metric Cards
    public var physicalSizeValueLabel: NSTextField!
    public var statusValueLabel: NSTextField!
    public var savedSizeValueLabel: NSTextField!
    public var targetVolumeValueLabel: NSTextField!

    // MARK: – Volume Selector
    public var volumePopUp: NSPopUpButton!
    public var volumeFreeSpaceLabel: NSTextField!

    // MARK: – Category Table
    public var categoryTableView: NSTableView!

    // MARK: – State
    public private(set) var currentOverview: StorageOverview?
    public private(set) var mountedVolumes: [MountedVolumeInfo] = []
    public private(set) var selectedVolume: MountedVolumeInfo?

    public var onMigrationFinished: ((String) -> Void)?

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
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])

        // 1. 顶层标题与主操作栏
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(topBar)

        let titleBox = NSStackView()
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 2

        let mainTitle = NSTextField(labelWithString: "外置移动存储与一键搬家管理中心")
        mainTitle.font = .systemFont(ofSize: 15, weight: .heavy)
        mainTitle.textColor = .white
        titleBox.addArrangedSubview(mainTitle)

        let subTitle = NSTextField(labelWithString: "零占用系统盘 · 物理无损迁移至外置高速 SSD · 透明符号链接 · 原路秒级回滚")
        subTitle.font = .systemFont(ofSize: 11)
        subTitle.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        titleBox.addArrangedSubview(subTitle)

        topBar.addArrangedSubview(titleBox)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(spacer)

        refreshButton = NSButton(title: " 刷新", target: self, action: #selector(onRefreshClicked))
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
        refreshButton.imagePosition = .imageLeading
        refreshButton.bezelStyle = .rounded
        topBar.addArrangedSubview(refreshButton)

        migrateAllButton = NSButton(title: " 一键搬家至外置卷 (0占用)", target: self, action: #selector(onMigrateAllClicked))
        migrateAllButton.image = NSImage(systemSymbolName: "arrow.up.forward.app.fill", accessibilityDescription: "一键搬家")
        migrateAllButton.imagePosition = .imageLeading
        migrateAllButton.bezelStyle = .rounded
        migrateAllButton.wantsLayer = true
        migrateAllButton.contentTintColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        topBar.addArrangedSubview(migrateAllButton)

        restoreAllButton = NSButton(title: " 还原至内置盘", target: self, action: #selector(onRestoreAllClicked))
        restoreAllButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "还原")
        restoreAllButton.imagePosition = .imageLeading
        restoreAllButton.bezelStyle = .rounded
        topBar.addArrangedSubview(restoreAllButton)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        topBar.addArrangedSubview(spinner)

        topBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 2. 指标卡片行 (4 张暗色石墨微光卡片，全升级为 SF Symbols 矢量图标)
        let cardsRow = NSStackView()
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 10
        cardsRow.distribution = .fillEqually
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(cardsRow)
        cardsRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        cardsRow.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let card1 = makeMetricCard(title: "内置物理占用", sfSymbol: "internaldrive")
        physicalSizeValueLabel = card1.1
        cardsRow.addArrangedSubview(card1.0)

        let card2 = makeMetricCard(title: "存储归属状态", sfSymbol: "externaldrive.badge.checkmark")
        statusValueLabel = card2.1
        cardsRow.addArrangedSubview(card2.0)

        let card3 = makeMetricCard(title: "节省系统盘空间", sfSymbol: "bolt.circle.fill")
        savedSizeValueLabel = card3.1
        cardsRow.addArrangedSubview(card3.0)

        let card4 = makeMetricCard(title: "目标外置盘", sfSymbol: "externaldrive")
        targetVolumeValueLabel = card4.1
        cardsRow.addArrangedSubview(card4.0)

        // 3. 目标外置盘选择栏
        let volumeBox = NSStackView()
        volumeBox.orientation = .horizontal
        volumeBox.spacing = 10
        volumeBox.alignment = .centerY
        volumeBox.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(volumeBox)
        volumeBox.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        let volLabel = NSTextField(labelWithString: "选择外置磁盘：")
        volLabel.font = .systemFont(ofSize: 12, weight: .bold)
        volLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        volumeBox.addArrangedSubview(volLabel)

        volumePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        volumePopUp.target = self
        volumePopUp.action = #selector(onVolumeSelected)
        volumePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        volumeBox.addArrangedSubview(volumePopUp)

        volumeFreeSpaceLabel = NSTextField(labelWithString: "可用空间：检测中…")
        volumeFreeSpaceLabel.font = .systemFont(ofSize: 11)
        volumeFreeSpaceLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        volumeBox.addArrangedSubview(volumeFreeSpaceLabel)

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        volumeBox.addArrangedSubview(spacer2)

        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        volumeBox.addArrangedSubview(statusLabel)

        // 4. 分类明细列表 TableView
        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .bezelBorder

        categoryTableView = NSTableView()
        categoryTableView.headerView = NSTableHeaderView()
        categoryTableView.rowHeight = 36
        categoryTableView.gridColor = NSColor(calibratedWhite: 0.16, alpha: 1.0)
        categoryTableView.gridStyleMask = [.solidHorizontalGridLineMask]
        categoryTableView.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        colCategory.title = "分类模块"
        colCategory.width = 160
        categoryTableView.addTableColumn(colCategory)

        let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        colSize.title = "物理占用"
        colSize.width = 110
        categoryTableView.addTableColumn(colSize)

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        colStatus.title = "挂载状态"
        colStatus.width = 140
        categoryTableView.addTableColumn(colStatus)

        let colTarget = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
        colTarget.title = "目标物理路径"
        colTarget.width = 320
        categoryTableView.addTableColumn(colTarget)

        let colAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        colAction.title = "单项操作"
        colAction.width = 140
        categoryTableView.addTableColumn(colAction)

        categoryTableView.dataSource = self
        categoryTableView.delegate = self
        tableScrollView.documentView = categoryTableView
        mainStack.addArrangedSubview(tableScrollView)

        NSLayoutConstraint.activate([
            tableScrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func makeMetricCard(title: String, sfSymbol: String) -> (NSView, NSTextField) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.85).cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .centerY

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: title)
        iconView.contentTintColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.0, alpha: 0.95)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        topRow.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        topRow.addArrangedSubview(titleLabel)

        stack.addArrangedSubview(topRow)

        let valLabel = NSTextField(labelWithString: "—")
        valLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        valLabel.textColor = .white
        stack.addArrangedSubview(valLabel)

        return (card, valLabel)
    }

    // MARK: – Data Refresh
    @objc public func onRefreshClicked() {
        refreshData()
    }

    public func refreshData() {
        spinner?.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let mgr = StorageMigrationManager.shared
            let overview = mgr.scanStorage()
            let volumes = mgr.listMountedVolumes()

            DispatchQueue.main.async {
                self.spinner?.stopAnimation(nil)
                self.applyOverview(overview, volumes: volumes)
            }
        }
    }

    public func applyOverview(_ overview: StorageOverview, volumes: [MountedVolumeInfo]) {
        self.currentOverview = overview
        self.mountedVolumes = volumes

        // 更新指标卡片
        physicalSizeValueLabel.stringValue = overview.totalPhysicalSizeFormatted
        savedSizeValueLabel.stringValue = overview.savedDiskSizeFormatted

        if overview.isEntireRootSymlinked {
            statusValueLabel.stringValue = "已全量外置"
            statusValueLabel.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
        } else if overview.categories.contains(where: { $0.isSymlink }) {
            statusValueLabel.stringValue = "部分外置"
            statusValueLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.25, alpha: 1.0)
        } else {
            statusValueLabel.stringValue = "内置系统盘"
            statusValueLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        }

        // 更新外置盘下拉列表
        volumePopUp.removeAllItems()
        if volumes.isEmpty {
            volumePopUp.addItem(withTitle: "未检测到已挂载外置盘")
            selectedVolume = nil
            volumeFreeSpaceLabel.stringValue = "请连接外置移动硬盘（如高速 SSD）后刷新"
            targetVolumeValueLabel.stringValue = "未连接"
            migrateAllButton.isEnabled = false
        } else {
            for vol in volumes {
                let title = "\(vol.name) (\(vol.freeFormatted) 可用)"
                volumePopUp.addItem(withTitle: title)
            }
            selectedVolume = volumes[0]
            volumeFreeSpaceLabel.stringValue = "可用空间：\(volumes[0].freeFormatted) / 总容量：\(volumes[0].totalFormatted)"
            targetVolumeValueLabel.stringValue = volumes[0].name
            migrateAllButton.isEnabled = true
        }

        categoryTableView.reloadData()
        statusLabel.stringValue = "扫描完成 · 发现 \(overview.categories.count) 个模板分类"
    }

    @objc private func onVolumeSelected() {
        let idx = volumePopUp.indexOfSelectedItem
        guard idx >= 0, idx < mountedVolumes.count else { return }
        selectedVolume = mountedVolumes[idx]
        let vol = mountedVolumes[idx]
        volumeFreeSpaceLabel.stringValue = "可用空间：\(vol.freeFormatted) / 总容量：\(vol.totalFormatted)"
        targetVolumeValueLabel.stringValue = vol.name
    }

    // MARK: – Actions
    @objc public func onMigrateAllClicked() {
        guard LicenseManager.shared.isProLicensed else {
            showAlert(title: "商业授权未激活", msg: "未激活商业授权，外置一键搬家与软链接迁移已锁定。请先激活商业授权。")
            return
        }
        guard let vol = selectedVolume else {
            showAlert(title: "未选择外置盘", msg: "请先连接并选择目标外置移动硬盘后再执行搬家。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认一键全量搬家至外置卷？"
        alert.informativeText = "将把全部 Final Cut Pro 模板物理迁移至外置硬盘：\n\(vol.path)/Motion Templates.localized\n并在本地系统盘建立透明软链接。\n迁移后系统盘将释放全部占用，FCPX 完全无感读取。"
        alert.addButton(withTitle: "开始搬家")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在执行物理无损迁移与软链创建…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let target = try StorageMigrationManager.shared.migrateEntireLibrary(toVolumePath: vol.path)
                DispatchQueue.main.async {
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "全量搬家成功 ✓ -> \(target)"
                    self.onMigrationFinished?(target)
                    self.refreshData()
                    self.showAlert(title: "搬家完成 ✓", msg: "Motion 模板已成功迁移至外置盘并建立符号链接：\n\(target)\n系统盘已实现 0 字节占用！")
                }
            } catch {
                DispatchQueue.main.async {
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "搬家失败: \(error.localizedDescription)"
                    self.showAlert(title: "搬家失败", msg: error.localizedDescription)
                }
            }
        }
    }

    @objc public func onRestoreAllClicked() {
        guard let overview = currentOverview, overview.isEntireRootSymlinked || overview.categories.contains(where: { $0.isSymlink }) else {
            showAlert(title: "无需还原", msg: "当前模板已全部位于内置系统盘。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认一键原路还原至内置系统盘？"
        alert.informativeText = "将删除外置软链接，把外置硬盘上的模板数据物理迁回本地系统盘目录：\n\(overview.localMotionRoot)"
        alert.addButton(withTitle: "开始还原")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在将数据原路迁回系统盘…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let path = try StorageMigrationManager.shared.restoreEntireLibraryToInternal()
                DispatchQueue.main.async {
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "已还原至内置盘 ✓"
                    self.refreshData()
                    self.showAlert(title: "还原完成 ✓", msg: "模板已成功还原至内置系统盘：\n\(path)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "还原失败: \(error.localizedDescription)"
                    self.showAlert(title: "还原失败", msg: error.localizedDescription)
                }
            }
        }
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
        return currentOverview?.categories.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let cats = currentOverview?.categories, row >= 0, row < cats.count else { return nil }
        let item = cats[row]
        let colId = tableColumn?.identifier.rawValue ?? ""

        switch colId {
        case "category":
            let cell = NSTextField(labelWithString: item.displayName)
            cell.font = .systemFont(ofSize: 12, weight: .bold)
            cell.textColor = .white
            return cell

        case "size":
            let cell = NSTextField(labelWithString: item.sizeFormatted)
            cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            cell.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
            return cell

        case "status":
            let cell = NSTextField(labelWithString: item.isSymlink ? "外置软链接 (0占用)" : "内置系统盘")
            cell.font = .systemFont(ofSize: 11, weight: .medium)
            cell.textColor = item.isSymlink
                ? NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
                : NSColor(calibratedWhite: 0.65, alpha: 1.0)
            return cell

        case "target":
            let cell = NSTextField(labelWithString: item.targetPath ?? item.path)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
            cell.lineBreakMode = .byTruncatingMiddle
            cell.toolTip = item.targetPath ?? item.path
            return cell

        case "action":
            let cell = NSView()
            let btn = NSButton(
                title: item.isSymlink ? " 迁回内置" : " 搬到外置",
                target: self,
                action: #selector(onCategoryActionClicked(_:))
            )
            btn.tag = row
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 12
            btn.layer?.masksToBounds = true
            btn.layer?.borderWidth = 1.0
            btn.font = .systemFont(ofSize: 11, weight: .medium)

            if item.isSymlink {
                btn.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "迁回内置")
                btn.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.24, alpha: 0.9).cgColor
                btn.layer?.borderColor = NSColor(calibratedRed: 0.35, green: 0.40, blue: 0.48, alpha: 0.8).cgColor
                btn.contentTintColor = NSColor(calibratedRed: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
            } else {
                btn.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "搬到外置")
                btn.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.45, alpha: 0.9).cgColor
                btn.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.48, blue: 0.85, alpha: 0.8).cgColor
                btn.contentTintColor = NSColor(calibratedRed: 0.65, green: 0.85, blue: 1.0, alpha: 1.0)
            }
            btn.imagePosition = .imageLeading

            btn.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                btn.widthAnchor.constraint(equalToConstant: 96),
                btn.heightAnchor.constraint(equalToConstant: 24)
            ])
            return cell

        default:
            return nil
        }
    }

    @objc private func onCategoryActionClicked(_ sender: NSButton) {
        let row = sender.tag
        guard let cats = currentOverview?.categories, row >= 0, row < cats.count else { return }
        let cat = cats[row]

        if cat.isSymlink {
            // 单项迁回
            do {
                try StorageMigrationManager.shared.restoreCategory(category: cat.category)
                refreshData()
            } catch {
                showAlert(title: "迁回失败", msg: error.localizedDescription)
            }
        } else {
            // 单项搬家
            guard let vol = selectedVolume else {
                showAlert(title: "未选择外置盘", msg: "请先连接外置硬盘。")
                return
            }
            do {
                try StorageMigrationManager.shared.migrateCategory(category: cat.category, toVolumePath: vol.path)
                refreshData()
            } catch {
                showAlert(title: "搬家失败", msg: error.localizedDescription)
            }
        }
    }
}
