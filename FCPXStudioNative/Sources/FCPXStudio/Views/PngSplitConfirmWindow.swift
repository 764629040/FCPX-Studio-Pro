import AppKit

/// TR-020 第二步：人工确认窗口。
/// 预切结果只作为「候选」展示；合并 / 拆分 / 删除 / 确认全部由人点按钮，
/// 最终层数 = 点「确认并导出」那一刻 blocks.count，程序绝不替用户决定层数。
public final class PngSplitConfirmWindowController: NSWindowController {

    // 不叫 document：NSWindowController 已有 document 属性，同名会撞 override。
    private let splitDocument: PngSplitDocument
    private let pngPath: String
    private let workDir: String
    private let autoConfirm: Bool
    private let onConfirm: (String) -> Void

    private var blocks: [PngSplitBlock]
    private var selected: Set<Int> = []
    private var actions: [PngSplitAction] = []

    private var cardStack: NSStackView!
    private var confirmButton = NSButton()
    private var mergeButton = NSButton()
    private var splitButton = NSButton()
    private var removeButton = NSButton()
    private var statusLabel: NSTextField!

    public init(splitDocument: PngSplitDocument,
                pngPath: String,
                workDir: String,
                autoConfirm: Bool = false,
                onConfirm: @escaping (String) -> Void) {
        self.splitDocument = splitDocument
        self.pngPath = pngPath
        self.workDir = workDir
        self.autoConfirm = autoConfirm
        self.onConfirm = onConfirm
        self.blocks = splitDocument.candidates.map { PngSplitBlock(candidate: $0, workDir: workDir) }
        super.init(window: nil)
        buildWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Window

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "PNG 智能拆图层 · 人工确认"
        win.minSize = NSSize(width: 880, height: 560)
        win.center()
        win.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 760))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        win.contentView = root
        self.window = win
        buildUI(in: root)
        rebuildCards()
        if autoConfirm {
            // 自动化真机验收：候选展示 1.5s 后触发【同一个确认按钮】的 action，
            // 不绕过 UI、不直接写 approved.json。正式人工使用时不带该参数。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.confirmButton.isEnabled else { return }
                self.confirmButton.performClick(nil)
            }
        }
    }

    private func label(_ text: String, size: CGFloat = 12, bold: Bool = false,
                       color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        b.font = NSFont.systemFont(ofSize: 12)
        return b
    }

    private func buildUI(in root: NSView) {
        let head = label("源文件：\((pngPath as NSString).lastPathComponent)   |   "
                         + "画幅 \(splitDocument.width)×\(splitDocument.height)   |   "
                         + "前景像素 \(splitDocument.foregroundPixels)   |   "
                         + "8 邻域原始块 \(splitDocument.rawComponentCount)", size: 13, bold: true)
        let adaptive = splitDocument.adaptive
        let adapt = label("自适应膨胀 r = \(adaptive.radiusPx) px（核 \(adaptive.kernelPx)×\(adaptive.kernelPx)，"
                          + "搜索上限 \(adaptive.radiusSearchCapPx) px，稳定平台 "
                          + "\(adaptive.plateauStartPx)…\(adaptive.plateauEndPx)）   |   "
                          + "跨组最小间距 "
                          + (adaptive.minGapBetweenFinalGroupsPx.map { String(format: "%.1f px", $0) } ?? "无"),
                          size: 11, color: .secondaryLabelColor)
        let hint = label("下面是预切候选，请人工核对。可勾选后合并 / 拆分 / 删除；"
                         + "层数由你点「确认并导出」时批准，程序不会替你决定。",
                         size: 12, color: .controlAccentColor)
        let warnText = splitDocument.warnings.isEmpty
            ? "过合并告警：0 条"
            : "过合并告警：\(splitDocument.warnings.count) 条 — " + splitDocument.warnings.joined(separator: "；")
        let warn = label(warnText, size: 11,
                         color: splitDocument.warnings.isEmpty ? .systemGreen : .systemRed)

        statusLabel = label("", size: 11, color: .secondaryLabelColor)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.controlBackgroundColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        cardStack = stack

        mergeButton = button("合并所选", action: #selector(onMerge))
        splitButton = button("拆分所选", action: #selector(onSplit))
        removeButton = button("删除所选", action: #selector(onRemove))
        let clearButton = button("取消选择", action: #selector(onClearSelection))
        let cancelButton = button("取消", action: #selector(onCancel))
        confirmButton = button("确认并导出 (\(blocks.count) 层)", action: #selector(onConfirmClicked))
        confirmButton.bezelStyle = .rounded
        confirmButton.contentTintColor = .white
        confirmButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        for b in [mergeButton, splitButton, removeButton, clearButton, cancelButton, confirmButton] {
            row.addArrangedSubview(b)
        }
        confirmButton.widthAnchor.constraint(equalToConstant: 210).isActive = true
        for b in [mergeButton, splitButton, removeButton, clearButton, cancelButton] {
            b.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }

        root.addSubview(head)
        root.addSubview(adapt)
        root.addSubview(hint)
        root.addSubview(warn)
        root.addSubview(scroll)
        root.addSubview(row)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            adapt.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 6),
            adapt.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            adapt.trailingAnchor.constraint(equalTo: head.trailingAnchor),

            hint.topAnchor.constraint(equalTo: adapt.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: head.trailingAnchor),

            warn.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            warn.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            warn.trailingAnchor.constraint(equalTo: head.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: warn.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 0),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 0),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: 0),

            statusLabel.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -8),

            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 30),
        ])
        updateButtons()
    }

    // MARK: - Cards

    private func hexColor(_ hex: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0, alpha: 1.0)
    }

    private func rebuildCards() {
        for v in cardStack.arrangedSubviews {
            cardStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (idx, block) in blocks.enumerated() {
            let card = makeCard(idx: idx, block: block)
            cardStack.addArrangedSubview(card)
            // 必须在加入 stack 之后再加宽度约束，否则两端不在同一视图树会抛异常
            card.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -16).isActive = true
        }
        statusLabel.stringValue = "当前候选 \(blocks.count) 块，已选 \(selected.count) 块  |  "
            + "确认后导出层数 = \(blocks.count)（由你批准）  |  操作记录 \(actions.count) 条"
        updateButtons()
    }

    private func makeCard(idx: Int, block: PngSplitBlock) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = selected.contains(idx) ? 3 : 1
        card.layer?.borderColor = (selected.contains(idx)
                                   ? hexColor(block.hex).cgColor
                                   : NSColor(calibratedWhite: 0.65, alpha: 1.0).cgColor)
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 116).isActive = true

        let thumbBox = NSView()
        thumbBox.wantsLayer = true
        thumbBox.layer?.cornerRadius = 6
        thumbBox.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        thumbBox.translatesAutoresizingMaskIntoConstraints = false
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        if FileManager.default.fileExists(atPath: block.thumbPath),
           let img = NSImage(contentsOfFile: block.thumbPath) {
            iv.image = img
        } else {
            let swatch = NSImage(size: NSSize(width: 96, height: 96))
            swatch.lockFocus()
            hexColor(block.hex).setFill()
            NSRect(x: 8, y: 8, width: 80, height: 80).fill()
            swatch.unlockFocus()
            iv.image = swatch
        }
        thumbBox.addSubview(iv)

        let check = NSButton(checkboxWithTitle: "选中", target: self, action: #selector(onToggleSelect(_:)))
        check.tag = idx
        check.state = selected.contains(idx) ? .on : .off
        check.translatesAutoresizingMaskIntoConstraints = false

        let nameField = NSTextField(string: block.name)
        nameField.font = NSFont.boldSystemFont(ofSize: 14)
        nameField.tag = idx
        nameField.target = self
        nameField.action = #selector(onNameChanged(_:))
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = hexColor(block.hex).cgColor
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor(calibratedWhite: 0.65, alpha: 1.0).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false

        let meta = label("#\(idx + 1)  \(block.hex)  RGB(\(block.rgb.map { String(format: "%.1f", $0) }.joined(separator: ", ")))"
                         + "   像素 \(block.pixels)   bbox \(block.bbox)   原始块 \(block.componentIds.count) 个",
                         size: 11)
        let warnText = block.warnings.isEmpty ? "无过合并告警"
            : "⚠️ " + block.warnings.joined(separator: "；")
        let warn = label(warnText, size: 10,
                         color: block.warnings.isEmpty ? .systemGreen : .systemRed)

        card.addSubview(thumbBox)
        card.addSubview(check)
        card.addSubview(nameField)
        card.addSubview(swatch)
        card.addSubview(meta)
        card.addSubview(warn)

        NSLayoutConstraint.activate([
            thumbBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            thumbBox.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            thumbBox.widthAnchor.constraint(equalToConstant: 96),
            thumbBox.heightAnchor.constraint(equalToConstant: 96),
            iv.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor, constant: 4),
            iv.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: -4),
            iv.topAnchor.constraint(equalTo: thumbBox.topAnchor, constant: 4),
            iv.bottomAnchor.constraint(equalTo: thumbBox.bottomAnchor, constant: -4),

            check.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            check.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),

            nameField.leadingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: 12),
            nameField.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -8),
            nameField.heightAnchor.constraint(equalToConstant: 22),

            swatch.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            swatch.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            swatch.widthAnchor.constraint(equalToConstant: 20),
            swatch.heightAnchor.constraint(equalToConstant: 20),

            meta.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            meta.centerYAnchor.constraint(equalTo: swatch.centerYAnchor),
            meta.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            warn.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            warn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            warn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        return card
    }

    private func updateButtons() {
        let n = selected.count
        let splittable = selected.contains { blocks[$0].componentIds.count > 1 }
        mergeButton.isEnabled = n >= 2
        splitButton.isEnabled = splittable
        removeButton.isEnabled = n > 0
        confirmButton.title = "确认并导出 (\(blocks.count) 层)"
        confirmButton.isEnabled = !blocks.isEmpty
    }

    // MARK: - Actions

    @objc private func onToggleSelect(_ sender: NSButton) {
        let idx = sender.tag
        if sender.state == .on { selected.insert(idx) } else { selected.remove(idx) }
        rebuildCards()
    }

    @objc private func onNameChanged(_ sender: NSTextField) {
        let idx = sender.tag
        guard blocks.indices.contains(idx) else { return }
        blocks[idx].name = sender.stringValue
    }

    @objc private func onClearSelection() {
        selected.removeAll()
        rebuildCards()
    }

    @objc private func onMerge() {
        let idxs = selected.sorted()
        guard idxs.count >= 2 else { return }
        let picked = idxs.map { blocks[$0] }
        let total = picked.reduce(0) { $0 + $1.pixels }
        var rgb = [0.0, 0.0, 0.0]
        for b in picked where total > 0 {
            let w = Double(b.pixels) / Double(total)
            for i in 0..<3 where i < b.rgb.count { rgb[i] += b.rgb[i] * w }
        }
        let hex = "#" + rgb.map { String(format: "%02X", max(0, min(255, Int(round($0))))) }.joined()
        var merged = picked[0]
        merged.componentIds = Array(Set(picked.flatMap { $0.componentIds })).sorted()
        merged.bbox = [picked.map { $0.bbox[0] }.min()!, picked.map { $0.bbox[1] }.min()!,
                       picked.map { $0.bbox[2] }.max()!, picked.map { $0.bbox[3] }.max()!]
        merged.pixels = total
        merged.rgb = rgb.map { Double(round($0 * 10) / 10) }
        merged.hex = hex
        merged.name = "人工合并 \(idxs.count) 块 · \(hex)"
        merged.thumbPath = ""
        merged.warnings = ["人工合并块，颜色为各块按像素数加权"]
        let insertAt = min(idxs[0], blocks.count - idxs.count)
        blocks = blocks.enumerated().filter { !selected.contains($0.offset) }.map { $0.element }
        blocks.insert(merged, at: max(0, insertAt))
        actions.append(PngSplitAction(action: "merge", source: "designer_ui",
                                      note: "人工合并 \(idxs.count) 个候选块为 1 层"))
        selected.removeAll()
        rebuildCards()
    }

    @objc private func onSplit() {
        var didSplit = 0
        for idx in selected.sorted().reversed() {
            guard blocks.indices.contains(idx), blocks[idx].componentIds.count > 1 else { continue }
            let comps = blocks[idx].componentIds.compactMap { cid in
                splitDocument.components.first { $0.id == cid }
            }
            guard comps.count > 1 else { continue }
            let parts = comps.enumerated().map {
                PngSplitBlock(component: $0.element, workDir: workDir, index: $0.offset + 1)
            }
            blocks.replaceSubrange(idx...idx, with: parts)
            didSplit += 1
        }
        if didSplit > 0 {
            actions.append(PngSplitAction(action: "split", source: "designer_ui",
                                          note: "人工拆分 \(didSplit) 个候选块为原始连通块"))
        }
        selected.removeAll()
        rebuildCards()
    }

    @objc private func onRemove() {
        let n = selected.count
        guard n > 0 else { return }
        blocks = blocks.enumerated().filter { !selected.contains($0.offset) }.map { $0.element }
        actions.append(PngSplitAction(action: "remove", source: "designer_ui",
                                      note: "人工删除 \(n) 个候选块"))
        selected.removeAll()
        rebuildCards()
    }

    @objc private func onCancel() {
        close()
    }

    @objc private func onConfirmClicked() {
        guard !blocks.isEmpty else {
            alert("候选块为空，无法导出。")
            return
        }
        confirmButton.isEnabled = false
        let approvedPath = (workDir as NSString).appendingPathComponent("approved.json")
        let approved = PngSplitApproved.make(
            document: splitDocument, blocks: blocks, actions: actions,
            approvalSource: autoConfirm ? "designer_ui_auto" : "designer_ui")
        do {
            try approved.write(to: approvedPath)
        } catch {
            alert("写入人工确认文件失败：\(error.localizedDescription)")
            confirmButton.isEnabled = true
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let psdPath = (workDir as NSString).appendingPathComponent("split_\(df.string(from: Date())).psd")
        statusLabel.stringValue = "已批准 \(blocks.count) 层，正在切块并导出多层 PSD…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PngSplitSocket.commit(pngPath: self?.pngPath ?? "",
                                               workDir: self?.workDir ?? "",
                                               approvedPath: approvedPath,
                                               psdPath: psdPath)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let path):
                    self.statusLabel.stringValue = "导出完成：\(path)"
                    self.onConfirm(path)
                    self.close()
                case .failure(let msg):
                    self.alert("导出失败：\(msg.message)")
                    self.confirmButton.isEnabled = true
                }
            }
        }
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "PNG 智能拆图层"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        if let win = window {
            a.beginSheetModal(for: win) { _ in }
        } else {
            a.runModal()
        }
    }
}
