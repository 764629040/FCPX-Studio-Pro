import AppKit
import CoreImage
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════
//  LUTCompareView —— 动态分屏悬停对比视口
//  对标基准：/Applications/嘉星插件管理 2.app (FXLUTCompareImageView & Overlay)
// ═══════════════════════════════════════════════════════════════

public final class LUTCompareView: NSView {

    public enum DisplayMode: Int {
        case split = 0
        case originalOnly = 1
        case lutOnly = 2
    }

    // MARK: – Properties

    public var originalImage: NSImage {
        didSet {
            recalculateLUTImage()
            needsDisplay = true
        }
    }

    public var currentLUT: LUTItem? {
        didSet {
            recalculateLUTImage()
            needsDisplay = true
        }
    }

    public private(set) var lutImage: NSImage?
    public var splitRatio: CGFloat = 0.5 {
        didSet {
            needsDisplay = true
        }
    }
    public var displayMode: DisplayMode = .split {
        didSet {
            needsDisplay = true
        }
    }

    public var showDividerAndHandle: Bool = true
    private var trackingArea: NSTrackingArea?
    private var isDraggingHandle: Bool = false

    // MARK: – Init

    public override init(frame frameRect: NSRect) {
        self.originalImage = LUTManager.makeCinematicReferenceImage()
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.originalImage = LUTManager.makeCinematicReferenceImage()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1.0).cgColor
        layer?.masksToBounds = true
        layer?.cornerRadius = 8.0
        registerForDraggedTypes([.fileURL])
    }

    // MARK: – LUT Application

    public func recalculateLUTImage() {
        guard let lut = currentLUT else {
            lutImage = nil
            return
        }

        do {
            let (dim, cubeData) = try LUTManager.shared.parseCube(at: lut.path)
            lutImage = LUTManager.shared.renderLUTImage(input: originalImage, dimension: dim, cubeData: cubeData)
        } catch {
            print("LUT 渲染失败: \(error)")
            lutImage = nil
        }
    }

    public func setOriginalImageFromPath(_ path: String) -> Bool {
        guard let img = NSImage(contentsOfFile: path) else { return false }
        self.originalImage = img
        return true
    }

    // MARK: – Tracking Area

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    // MARK: – Mouse Events

    public override func mouseMoved(with event: NSEvent) {
        guard displayMode == .split else { return }
        let loc = convert(event.locationInWindow, from: nil)
        updateSplitRatio(with: loc.x)
    }

    public override func mouseDown(with event: NSEvent) {
        guard displayMode == .split else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let splitX = bounds.width * splitRatio
        if abs(loc.x - splitX) < 24 {
            isDraggingHandle = true
        }
        updateSplitRatio(with: loc.x)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard displayMode == .split else { return }
        let loc = convert(event.locationInWindow, from: nil)
        updateSplitRatio(with: loc.x)
    }

    public override func mouseUp(with event: NSEvent) {
        isDraggingHandle = false
    }

    private func updateSplitRatio(with x: CGFloat) {
        guard bounds.width > 0 else { return }
        let ratio = max(0.02, min(0.98, x / bounds.width))
        self.splitRatio = ratio
    }

    // MARK: – Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let targetBounds = bounds
        guard targetBounds.width > 0, targetBounds.height > 0 else { return }

        // 背景
        NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0).setFill()
        dirtyRect.fill()

        let rightImage = lutImage ?? originalImage

        switch displayMode {
        case .originalOnly:
            drawScaledImage(originalImage, in: targetBounds)
            drawOverlayBadge(text: "原始参考画面 (Rec.709 / Log)", alignment: .left)
            return

        case .lutOnly:
            drawScaledImage(rightImage, in: targetBounds)
            let lutName = currentLUT?.name ?? "未选定 LUT"
            drawOverlayBadge(text: "3D LUT: \(lutName)", alignment: .right)
            return

        case .split:
            break
        }

        let splitX = targetBounds.width * splitRatio

        // 1. 绘制左半屏：原始画面（带剪裁）
        NSGraphicsContext.saveGraphicsState()
        let leftClip = NSRect(x: 0, y: 0, width: splitX, height: targetBounds.height)
        NSBezierPath(rect: leftClip).addClip()
        drawScaledImage(originalImage, in: targetBounds)
        NSGraphicsContext.restoreGraphicsState()

        // 2. 绘制右半屏：LUT 调色画面（带剪裁）
        NSGraphicsContext.saveGraphicsState()
        let rightClip = NSRect(x: splitX, y: 0, width: targetBounds.width - splitX, height: targetBounds.height)
        NSBezierPath(rect: rightClip).addClip()
        drawScaledImage(rightImage, in: targetBounds)
        NSGraphicsContext.restoreGraphicsState()

        // 3. 绘制分屏指示线与中轴指示手柄
        if showDividerAndHandle {
            // 分割线
            let linePath = NSBezierPath()
            linePath.move(to: NSPoint(x: splitX, y: 0))
            linePath.line(to: NSPoint(x: splitX, y: targetBounds.height))
            linePath.lineWidth = 2.0
            NSColor(white: 1.0, alpha: 0.95).setStroke()
            linePath.stroke()

            // 细阴影
            let shadowLine = NSBezierPath()
            shadowLine.move(to: NSPoint(x: splitX - 1, y: 0))
            shadowLine.line(to: NSPoint(x: splitX - 1, y: targetBounds.height))
            shadowLine.lineWidth = 1.0
            NSColor(white: 0.0, alpha: 0.5).setStroke()
            shadowLine.stroke()

            // 对标嘉星中轴手柄指示胶囊
            let handleW: CGFloat = 146
            let handleH: CGFloat = 26
            let handleY = targetBounds.height / 2.0 - handleH / 2.0
            let handleRect = NSRect(x: splitX - handleW / 2.0, y: handleY, width: handleW, height: handleH)

            let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 13, yRadius: 13)
            NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.92).setFill()
            handlePath.fill()
            NSColor(white: 1.0, alpha: 0.85).setStroke()
            handlePath.lineWidth = 1.5
            handlePath.stroke()

            let text = "◀ 原始 ｜ LUT 效果 ▶"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let strSize = (text as NSString).size(withAttributes: attrs)
            let textPoint = NSPoint(
                x: handleRect.midX - strSize.width / 2.0,
                y: handleRect.midY - strSize.height / 2.0
            )
            (text as NSString).draw(at: textPoint, withAttributes: attrs)
        }

        // 4. 左下角与右下角小标识
        drawCornerTag(text: "原片 (Log/Rec709)", isLeft: true)
        let lutTag = currentLUT != nil ? "LUT: \(currentLUT!.name)" : "未挂载 LUT"
        drawCornerTag(text: lutTag, isLeft: false)
    }

    private func drawScaledImage(_ image: NSImage, in rect: NSRect) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // 等比填充并居中 (Aspect Fit)
        let scale = min(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let drawX = rect.origin.x + (rect.width - drawW) / 2.0
        let drawY = rect.origin.y + (rect.height - drawH) / 2.0
        let drawRect = NSRect(x: drawX, y: drawY, width: drawW, height: drawH)

        image.draw(in: drawRect, from: NSRect(origin: .zero, size: imgSize),
                   operation: .sourceOver, fraction: 1.0)
    }

    private func drawCornerTag(text: String, isLeft: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(white: 0.9, alpha: 0.9)
        ]
        let strSize = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let bgW = strSize.width + padX * 2
        let bgH = strSize.height + padY * 2
        let bgX = isLeft ? 12 : bounds.width - bgW - 12
        let bgY: CGFloat = 12

        let bgRect = NSRect(x: bgX, y: bgY, width: bgW, height: bgH)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
        NSColor(white: 0.0, alpha: 0.65).setFill()
        path.fill()

        (text as NSString).draw(at: NSPoint(x: bgX + padX, y: bgY + padY), withAttributes: attrs)
    }

    private func drawOverlayBadge(text: String, alignment: NSTextAlignment) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let strSize = (text as NSString).size(withAttributes: attrs)
        let x = alignment == .left ? 16 : bounds.width - strSize.width - 24
        let y = bounds.height - strSize.height - 16
        let bgRect = NSRect(x: x - 8, y: y - 4, width: strSize.width + 16, height: strSize.height + 8)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
        NSColor(white: 0.0, alpha: 0.75).setFill()
        path.fill()
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: – Drag and Drop (支持拖入原片测试)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let pboard = sender.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let url = URL(string: pboard) else {
            return []
        }
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "tiff", "tif", "heic"].contains(ext) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pboard = sender.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let url = URL(string: pboard) else {
            return false
        }
        return setOriginalImageFromPath(url.path)
    }
}
