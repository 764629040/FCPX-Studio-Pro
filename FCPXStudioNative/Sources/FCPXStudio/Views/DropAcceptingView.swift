import AppKit

// ═══════════════════════════════════════════════════════════════
//  DropAcceptingView —— 整窗拖放接收层（R31 / A-61）
//
//  NSWindow 默认不接收文件拖放，所以旧版把 PSD 拖进来「完全没反应」。
//  这里把 window.contentView 换成该子类并注册 .fileURL：
//    · 拖入 .psd 或目录 → 返回 .copy，并显示高亮边框
//    · 拖入其它文件     → 不接受（不崩溃），落盘后由控制器给明确提示
// ═══════════════════════════════════════════════════════════════

/// 只用于画高亮的穿透层：不抢鼠标事件
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public final class DropAcceptingView: NSView {

    /// 拖放落盘回调（已过滤出真实存在的文件路径）
    public var onFilesDropped: (([String]) -> Void)?
    /// R46: 字体拖拽专用落盘回调 (.ttf / .otf / .ttc)
    public var onFontsDropped: (([String]) -> Void)?

    private var highlightView: NSView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: – 拖放协议

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = droppedPaths(from: sender)
        guard PSDImportPlanner.acceptsDrop(paths: paths) else { return [] }
        showHighlight()
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = droppedPaths(from: sender)
        return PSDImportPlanner.acceptsDrop(paths: paths) ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlight()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(from: sender)
        let accepted = PSDImportPlanner.acceptsDrop(paths: paths)
        // FCPX-039: 拖入不受支持的文件时弹出明确提示，杜绝静默失败
        if !accepted && !paths.isEmpty {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "格式不支持"
                alert.informativeText = "本工作站仅支持拖入 PSD 设计文件 (.psd) 或字体文件 (.ttf / .otf)。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
        }
        return accepted
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideHighlight()
        let paths = droppedPaths(from: sender)
        guard !paths.isEmpty else { return false }

        let fontPaths = paths.filter { PSDImportPlanner.isFont($0) }
        let otherPaths = paths.filter { !PSDImportPlanner.isFont($0) }

        if !fontPaths.isEmpty {
            if let onFonts = onFontsDropped {
                onFonts(fontPaths)
            } else {
                onFilesDropped?(fontPaths)
            }
        }

        if !otherPaths.isEmpty {
            onFilesDropped?(otherPaths)
        }
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideHighlight()
    }

    // MARK: – 工具

    func droppedPaths(from info: NSDraggingInfo) -> [String] {
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = info.draggingPasteboard.readObjects(forClasses: classes, options: options)
        let urls = (objects as? [URL]) ?? []
        return urls.map { $0.path }
    }

    private func highlightViewIfNeeded() -> NSView {
        if let v = highlightView { return v }
        let v = PassthroughView(frame: bounds.insetBy(dx: 2, dy: 2))
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.borderWidth = 3
        v.layer?.borderColor = NSColor.systemBlue.cgColor
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        addSubview(v, positioned: .above, relativeTo: nil)
        highlightView = v
        return v
    }

    private func showHighlight() {
        highlightViewIfNeeded().isHidden = false
    }

    private func hideHighlight() {
        highlightView?.isHidden = true
    }
}
