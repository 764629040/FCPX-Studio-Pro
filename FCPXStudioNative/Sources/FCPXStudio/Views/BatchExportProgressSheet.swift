import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  BatchExportProgressSheet —— 批量导出毛玻璃异步进度面板（R46）
//
//  核心设计：
//    1. macOS Pro 磨砂质感毛玻璃 Sheet 窗口（NSVisualEffectView）
//    2. 进度指示器平滑联动（百分比、完成数 / 总数）
//    3. 实时流水状态展示（当前转换项、耗时、状态图标 🟢 🟡 🔴）
//    4. 异步无锁流式日志滚动列表（NSTableView）
//    5. 智能动作切换：转换中支持安全【取消】；完成后切换为【在 Finder 中查看】与【完成】
// ═══════════════════════════════════════════════════════════════

public enum BatchExportItemStatus: String {
    case success = "success"
    case warning = "warning"
    case failure = "failure"

    public var badge: String {
        switch self {
        case .success: return "🟢"
        case .warning: return "🟡"
        case .failure: return "🔴"
        }
    }
}

public struct BatchExportLogItem {
    public let timestamp: String
    public let status: BatchExportItemStatus
    public let fileName: String
    public let message: String

    public init(status: BatchExportItemStatus, fileName: String, message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.timestamp = formatter.string(from: Date())
        self.status = status
        self.fileName = fileName
        self.message = message
    }
}

public final class BatchExportProgressSheet: NSWindow, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: – 外部控制与回调
    public var onCancel: (() -> Void)?
    public var onDone: (() -> Void)?
    public var onRevealInFinder: ((String) -> Void)?

    public private(set) var totalCount: Int
    public private(set) var completedCount: Int = 0
    public private(set) var successCount: Int = 0
    public private(set) var failedCount: Int = 0
    public private(set) var isCancelled: Bool = false
    public private(set) var isFinished: Bool = false
    public private(set) var targetDirectory: String

    public private(set) var logItems: [BatchExportLogItem] = []

    // MARK: – UI 组件
    public private(set) var titleLabel: NSTextField!
    public private(set) var subtitleLabel: NSTextField!
    public private(set) var destinationLabel: NSTextField!
    public private(set) var progressIndicator: NSProgressIndicator!
    public private(set) var percentageLabel: NSTextField!
    public private(set) var currentFileLabel: NSTextField!
    public private(set) var tableView: NSTableView!
    public private(set) var cancelButton: NSButton!
    public private(set) var revealButton: NSButton!
    public private(set) var doneButton: NSButton!

    private var visualEffectView: NSVisualEffectView!

    // MARK: – 初始化
    public init(totalCount: Int, targetDir: String = "") {
        self.totalCount = max(1, totalCount)
        self.targetDirectory = targetDir

        let contentRect = NSRect(x: 0, y: 0, width: 580, height: 440)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear

        setupUI(in: contentRect)
    }

    private func setupUI(in rect: NSRect) {
        visualEffectView = NSVisualEffectView(frame: rect)
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14.0
        visualEffectView.layer?.masksToBounds = true
        self.contentView = visualEffectView

        let container = NSView(frame: rect)
        container.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 20),
            container.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 22),
            container.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -22),
            container.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -18)
        ])

        // 1. 顶部标题与图标
        titleLabel = NSTextField(labelWithString: "🚀 批量模板导出与 FCPX 自动挂载")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "正在调度后台异步引擎，平滑生成 Motion XML 模板...")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        let shortPath = (targetDirectory as NSString).abbreviatingWithTildeInPath
        destinationLabel = NSTextField(labelWithString: "📁 输出位置: \(shortPath.isEmpty ? "智能自适应路径" : shortPath)")
        destinationLabel.font = .systemFont(ofSize: 10, weight: .medium)
        destinationLabel.textColor = NSColor(calibratedRed: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(destinationLabel)

        // 2. 进度条与百分比
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0.0
        progressIndicator.maxValue = Double(totalCount)
        progressIndicator.doubleValue = 0.0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressIndicator)

        percentageLabel = NSTextField(labelWithString: "0% (0/\(totalCount))")
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentageLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        percentageLabel.alignment = .right
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(percentageLabel)

        // 3. 当前文件动态状态
        currentFileLabel = NSTextField(labelWithString: "准备启动任务队列...")
        currentFileLabel.font = .systemFont(ofSize: 11)
        currentFileLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        currentFileLabel.lineBreakMode = .byTruncatingMiddle
        currentFileLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(currentFileLabel)

        // 4. 实时日志列表 (NSTableView)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6.0
        scroll.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.6).cgColor

        tableView = NSTableView()
        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        colStatus.title = "状态"
        colStatus.width = 45

        let colFile = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        colFile.title = "模板文件名"
        colFile.width = 160

        let colMsg = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("msg"))
        colMsg.title = "详情流水"
        colMsg.width = 290

        tableView.addTableColumn(colStatus)
        tableView.addTableColumn(colFile)
        tableView.addTableColumn(colMsg)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        container.addSubview(scroll)

        // 5. 底部按钮控制栏
        cancelButton = NSButton(title: "取消批处理", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)

        revealButton = NSButton(title: "在 Finder 中查看", target: self, action: #selector(onRevealClicked))
        revealButton.bezelStyle = .rounded
        revealButton.isHidden = true
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(revealButton)

        doneButton = NSButton(title: "完成", target: self, action: #selector(onDoneClicked))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(doneButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            destinationLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
            destinationLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            destinationLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            progressIndicator.topAnchor.constraint(equalTo: destinationLabel.bottomAnchor, constant: 14),
            progressIndicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: percentageLabel.leadingAnchor, constant: -12),
            progressIndicator.centerYAnchor.constraint(equalTo: percentageLabel.centerYAnchor),

            percentageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            percentageLabel.widthAnchor.constraint(equalToConstant: 100),

            currentFileLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 6),
            currentFileLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            currentFileLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: currentFileLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -14),

            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            doneButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 90),

            revealButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            revealButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -10)
        ])
    }

    // MARK: – 线程安全状态更新

    public func updateProgress(completed: Int, total: Int, currentFileName: String) {
        if Thread.isMainThread {
            self.totalCount = max(1, total)
            self.completedCount = completed
            self.progressIndicator.maxValue = Double(self.totalCount)
            self.progressIndicator.doubleValue = Double(completed)

            let pct = Int((Double(completed) / Double(self.totalCount)) * 100.0)
            self.percentageLabel.stringValue = "\(pct)% (\(completed)/\(self.totalCount))"
            self.currentFileLabel.stringValue = "正在生成: \(currentFileName)..."
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateProgress(completed: completed, total: total, currentFileName: currentFileName)
            }
        }
    }

    public func appendLog(status: BatchExportItemStatus, fileName: String, message: String) {
        if Thread.isMainThread {
            let item = BatchExportLogItem(status: status, fileName: fileName, message: message)
            logItems.append(item)
            if status == .success { successCount += 1 }
            if status == .failure { failedCount += 1 }

            tableView.reloadData()
            if !logItems.isEmpty {
                tableView.scrollRowToVisible(logItems.count - 1)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendLog(status: status, fileName: fileName, message: message)
            }
        }
    }

    public func finishExport(successCount: Int, failedCount: Int, targetDir: String) {
        if Thread.isMainThread {
            self.isFinished = true
            self.successCount = successCount
            self.failedCount = failedCount
            self.targetDirectory = targetDir

            progressIndicator.doubleValue = progressIndicator.maxValue
            percentageLabel.stringValue = "100% (\(totalCount)/\(totalCount))"

            if isCancelled {
                titleLabel.stringValue = "⚠️ 批量导出已取消"
                currentFileLabel.stringValue = "批处理已由用户中途取消，部分已生成模板保存在指定目录。"
                currentFileLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.25, alpha: 1.0)
            } else {
                titleLabel.stringValue = "✓ 批量导出与挂载完成"
                currentFileLabel.stringValue = "已成功生成并挂载 \(successCount) 款模板" + (failedCount > 0 ? "，失败 \(failedCount) 款" : "") + "。"
                currentFileLabel.textColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1.0)
            }

            cancelButton.isHidden = true
            revealButton.isHidden = false
            doneButton.isHidden = false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.finishExport(successCount: successCount, failedCount: failedCount, targetDir: targetDir)
            }
        }
    }

    public func markCancelled() {
        self.isCancelled = true
        appendLog(status: .warning, fileName: "调度器", message: "收到取消信号，正在安全停止任务...")
    }

    // MARK: – 用户交互动作 (FCPX-051: 取消二次确认，避免误触丢失已打包进度；保留隐藏面板入口)

    @objc private func onCancelClicked() {
        if isCancelled {
            if let parent = self.sheetParent {
                parent.endSheet(self)
            } else {
                self.orderOut(nil)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认取消批量导出？"
        alert.informativeText = "当前已导出 \(completedCount) / \(totalCount) 套模板。确认取消后，未处理的文件将停止导出。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "停止导出")
        alert.addButton(withTitle: "继续导出")
        if alert.runModal() == .alertFirstButtonReturn {
            markCancelled()
            cancelButton?.title = "隐藏面板"
            onCancel?()
        }
    }

    @objc private func onRevealClicked() {
        if let cb = onRevealInFinder {
            cb(targetDirectory)
        } else {
            let url = URL(fileURLWithPath: targetDirectory)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func onDoneClicked() {
        onDone?()
        if let parent = self.sheetParent {
            parent.endSheet(self)
        } else {
            self.close()
        }
    }

    // MARK: – NSTableView 数据源与代理

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return logItems.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < logItems.count else { return nil }
        let item = logItems[row]
        let colId = tableColumn?.identifier.rawValue ?? ""

        if colId == "status" {
            let tf = NSTextField(labelWithString: item.status.badge)
            tf.alignment = .center
            tf.font = .systemFont(ofSize: 11)
            return tf
        } else if colId == "file" {
            let tf = NSTextField(labelWithString: item.fileName)
            tf.font = .systemFont(ofSize: 11, weight: .medium)
            tf.textColor = .white
            tf.lineBreakMode = .byTruncatingTail
            return tf
        } else if colId == "msg" {
            let tf = NSTextField(labelWithString: "[\(item.timestamp)] \(item.message)")
            tf.font = .systemFont(ofSize: 10)
            switch item.status {
            case .success:
                tf.textColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.5, alpha: 1.0)
            case .warning:
                tf.textColor = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.25, alpha: 1.0)
            case .failure:
                tf.textColor = NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
            }
            tf.lineBreakMode = .byTruncatingMiddle
            return tf
        }
        return nil
    }
}
