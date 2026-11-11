import AppKit

/// R35 / D-73：智能对齐吸附参考线模型
public struct AlignmentGuide: Equatable {
    public enum Orientation: Equatable {
        case vertical   // X 固定，在 (position, start) 到 (position, end) 画线
        case horizontal // Y 固定，在 (start, position) 到 (end, position) 画线
    }
    public var orientation: Orientation
    public var position: CGFloat
    public var start: CGFloat
    public var end: CGFloat
    public var color: NSColor

    public init(orientation: Orientation, position: CGFloat, start: CGFloat, end: CGFloat, color: NSColor) {
        self.orientation = orientation
        self.position = position
        self.start = start
        self.end = end
        self.color = color
    }
}

public enum ComparisonMode: Int {
    case off = 0           // 正常画布模式
    case splitCurtain = 1  // 中轴卷帘分屏对比（3D LUT 风格）
    case sideBySide = 2    // 并排双画板对比
    case peekHold = 3      // ⌥ 按住瞬时透视原图
}

public final class InfiniteCanvasView: NSView {
    public var artboardWidth: CGFloat = 1920
    public var artboardHeight: CGFloat = 1080
    // UI-O007: 统一 kMinZoom 与 kMaxZoom 常量
    public static let kMinZoom: CGFloat = 0.08
    public static let kMaxZoom: CGFloat = 4.0

    public var zoomScale: CGFloat = 0.25
    public var panOffset: CGPoint = .zero

    public var layers: [LayerModel] = [] {
        didSet { needsDisplay = true }
    }
    public var selectedLayerIndex: Int = -1 {
        didSet { needsDisplay = true }
    }

    /// R35 / D-73：当前激活的对齐辅助线
    public var activeGuides: [AlignmentGuide] = [] {
        didSet { needsDisplay = true }
    }

    /// R33 / A-68：底板预览（转换仍忽略底板，但画布必须显示它，否则纯照片稿全黑）
    public var backgroundPreview: LayerModel? {
        didSet { needsDisplay = true }
    }

    // MARK: - R45 对比功能插口
    public var comparisonMode: ComparisonMode = .off {
        didSet { needsDisplay = true }
    }
    public var splitDividerPosition: CGFloat = 0.5 { // 0.0 ~ 1.0 卷帘中轴线位置
        didSet { needsDisplay = true }
    }
    public var isPeekingOriginal: Bool = false { // 按住 ⌥ 或长按瞬时透视
        didSet { needsDisplay = true }
    }
    public var originalCompositePath: String? {
        didSet {
            originalCompositeImage = nil
            if let p = originalCompositePath, !p.isEmpty {
                originalCompositeImage = NSImage(contentsOfFile: p)
            }
            needsDisplay = true
        }
    }
    public var originalCompositeImage: NSImage?
    private var isDraggingDivider: Bool = false

    /// TR-019-R：.moti 只读预览态。
    /// 只读预览没有 PSD 位图贴图（backgroundPreview / fallbackPngPath 全为空），
    /// 分组层又没有文字，旧版 drawLayer 会什么都不画，画布就是一片黑。
    /// 打开此开关后画布改走 drawMotiPlaceholders：按每层坐标画彩色占位框 +
    /// 序号 + 文字（或层名），保证「没有贴图也看得见模板长什么样」。
    public var motiPreviewMode: Bool = false {
        didSet { needsDisplay = true }
    }

    public override var acceptsFirstResponder: Bool { true }

    /// 位图贴图缓存：避免每次 draw 都从磁盘解码大图（2848×1600 每帧重读会卡顿）
    private let imageCache = NSCache<NSString, NSImage>()

    public var onLayerMoved: ((LayerModel) -> Void)?
    public var onLayerSelected: ((Int) -> Void)?
    public var onZoomChanged: ((CGFloat) -> Void)?

    private var isDraggingLayer: Bool = false
    private var dragStartMousePos: CGPoint = .zero
    private var dragStartLayerPos: CGPoint = .zero
    private var isPanning: Bool = false
    private var panStartMousePos: CGPoint = .zero

    // MARK: - R49 磨砂半透明质感常量
    public static let canvasBackdropAlpha: CGFloat = 0.35
    public static let artboardCoreColor = NSColor(calibratedRed: 18.0/255.0, green: 20.0/255.0, blue: 24.0/255.0, alpha: 1.0)
    public static let artboardBorderColor = NSColor(white: 1.0, alpha: 0.16)
    public static let artboardBorderWidth: CGFloat = 1.0

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: InfiniteCanvasView.canvasBackdropAlpha).cgColor
        layer?.masksToBounds = true // ★ 绝对防止图层溢出到侧边栏
        imageCache.totalCostLimit = 200 * 1024 * 1024 // 200MB (UI-G023)
        imageCache.countLimit = 40
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: InfiniteCanvasView.canvasBackdropAlpha).cgColor
        layer?.masksToBounds = true
        imageCache.totalCostLimit = 200 * 1024 * 1024
        imageCache.countLimit = 40
    }

    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        fitArtboard()
    }

    public func fitArtboard() {
        guard bounds.width > 100, bounds.height > 100 else { return }
        let margin: CGFloat = 50.0
        let availableW = bounds.width - margin * 2
        let availableH = bounds.height - margin * 2
        let scaleX = availableW / artboardWidth
        let scaleY = availableH / artboardHeight
        // UI-O007: 统一使用 kMinZoom，避免适应后滚轮跳变
        zoomScale = max(Self.kMinZoom, min(scaleX, scaleY))
        panOffset = .zero
        onZoomChanged?(zoomScale)
        needsDisplay = true
    }

    public func setResolution(width: CGFloat, height: CGFloat) {
        artboardWidth = width
        artboardHeight = height
        fitArtboard()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // ★ 核心修复：画布必须先裁剪到自己的 bounds，绝不能越界绘制到侧边栏！
        ctx.saveGState()
        ctx.clip(to: bounds)

        // 填充半透明石墨调底色（让磨砂玻璃背板自然穿透）
        ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: InfiniteCanvasView.canvasBackdropAlpha).cgColor)
        ctx.fill(bounds)

        // 1. 绘制无限点阵背景
        drawDotGrid(in: bounds, ctx: ctx)

        // 2. 变换矩阵应用 (居中 + PanOffset + ZoomScale)
        let centerX = bounds.width / 2.0 + panOffset.x
        let centerY = bounds.height / 2.0 + panOffset.y

        ctx.saveGState()
        ctx.translateBy(x: centerX, y: centerY)
        ctx.scaleBy(x: zoomScale, y: zoomScale)

        let artboardRect = CGRect(x: -artboardWidth / 2, y: -artboardHeight / 2, width: artboardWidth, height: artboardHeight)

        if isPeekingOriginal || comparisonMode == .peekHold {
            // ⌥ 瞬时透视 PSD 原始成图
            drawArtboardContent(ctx: ctx, artboardRect: artboardRect, isLiveCanvas: false, badgeTitle: "🪞 瞬时透视 PSD 原始成图 (松开 ⌥ 恢复)")
        } else if comparisonMode == .splitCurtain {
            // 中轴卷帘对比模式 (3D LUT 风格分屏对比)
            let dividerX = artboardRect.minX + artboardRect.width * splitDividerPosition
            let leftRect = CGRect(x: artboardRect.minX, y: artboardRect.minY, width: max(0, dividerX - artboardRect.minX), height: artboardRect.height)
            let rightRect = CGRect(x: dividerX, y: artboardRect.minY, width: max(0, artboardRect.maxX - dividerX), height: artboardRect.height)

            // 左侧：原始成图
            ctx.saveGState()
            ctx.clip(to: leftRect)
            drawArtboardContent(ctx: ctx, artboardRect: artboardRect, isLiveCanvas: false, badgeTitle: "🪞 PSD 原始成图")
            ctx.restoreGState()

            // 右侧：实时转出
            ctx.saveGState()
            ctx.clip(to: rightRect)
            drawArtboardContent(ctx: ctx, artboardRect: artboardRect, isLiveCanvas: true, badgeTitle: "⚡️ 实时转出画面")
            ctx.restoreGState()

            // 卷帘分割中轴线与控制手柄
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(2.5)
            ctx.move(to: CGPoint(x: dividerX, y: artboardRect.minY))
            ctx.addLine(to: CGPoint(x: dividerX, y: artboardRect.maxY))
            ctx.strokePath()

            let handleRadius: CGFloat = 16.0
            let handleRect = CGRect(x: dividerX - handleRadius, y: -handleRadius, width: handleRadius * 2, height: handleRadius * 2)
            ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: handleRect)
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: handleRect)

            let arrowAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .black),
                .foregroundColor: NSColor.systemCyan
            ]
            let arrowStr = NSAttributedString(string: "◀▶", attributes: arrowAttrs)
            let arrowSize = arrowStr.size()
            arrowStr.draw(at: CGPoint(x: dividerX - arrowSize.width / 2, y: -arrowSize.height / 2))
            ctx.restoreGState()

        } else if comparisonMode == .sideBySide {
            // 并排直观对比模式
            let gap: CGFloat = 80.0
            let offset: CGFloat = artboardWidth / 2 + gap / 2
            let leftRect = CGRect(x: -offset - artboardWidth / 2, y: -artboardHeight / 2, width: artboardWidth, height: artboardHeight)

            // 左画板：原图
            ctx.saveGState()
            drawArtboardContent(ctx: ctx, artboardRect: leftRect, isLiveCanvas: false, badgeTitle: "🪞 PSD 原始成图")
            ctx.restoreGState()

            // 右画板：转出画面
            ctx.saveGState()
            ctx.translateBy(x: offset, y: 0)
            let localRect = CGRect(x: -artboardWidth / 2, y: -artboardHeight / 2, width: artboardWidth, height: artboardHeight)
            drawArtboardContent(ctx: ctx, artboardRect: localRect, isLiveCanvas: true, badgeTitle: "⚡️ 实时转出画面")
            ctx.restoreGState()

        } else {
            // 正常单画板转出模式
            drawArtboardContent(ctx: ctx, artboardRect: artboardRect, isLiveCanvas: true, badgeTitle: nil)
        }

        ctx.restoreGState() // 恢复变换矩阵
        ctx.restoreGState() // 恢复裁剪区域
    }

    private func drawArtboardContent(ctx: CGContext, artboardRect: CGRect, isLiveCanvas: Bool, badgeTitle: String?) {
        ctx.saveGState()
        // 柔和深邃悬浮投影与深色画芯 (#121418)
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 32, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(InfiniteCanvasView.artboardCoreColor.cgColor)
        ctx.fill(artboardRect)
        ctx.restoreGState()

        // 1.0pt 灰白微光 Pro 边框 (white 16%)
        ctx.setStrokeColor(InfiniteCanvasView.artboardBorderColor.cgColor)
        ctx.setLineWidth(InfiniteCanvasView.artboardBorderWidth)
        ctx.stroke(artboardRect)

        if isLiveCanvas {
            // 3.5 R33 / A-68：先铺底板预览（纯照片 PSD 的画面主体在底板层）
            if let bg = backgroundPreview, bg.visible {
                drawBackgroundPreview(bg, artboardRect: artboardRect, ctx: ctx)
            }
            // UI-O012: 空态叠加居中引导文案+图示，拖入后消失
            if layers.isEmpty && (backgroundPreview == nil || !backgroundPreview!.visible) {
                drawEmptyStatePrompt(in: artboardRect, ctx: ctx)
            }
            // 4. 绘制安全框与十字准星
            drawSafeFrames(in: artboardRect, ctx: ctx)
            // 5. 绘制图层：从底往顶画
            // TR-019-R：只读预览改走占位绘制（不依赖位图贴图，分组层也可见）
            if motiPreviewMode {
                drawMotiPlaceholders(in: artboardRect, ctx: ctx)
            } else {
                for (idx, layer) in layers.enumerated().reversed() {
                    guard layer.visible else { continue }
                    drawLayer(layer, isSelected: idx == selectedLayerIndex, ctx: ctx)
                }
            }
            // 6. R35 / D-73：绘制高光智能对齐辅助线
            drawAlignmentGuides(in: artboardRect, ctx: ctx)
        } else {
            // 原始 PSD 完整成图呈现
            if let comp = originalCompositeImage {
                if let cgImg = comp.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ctx.saveGState()
                    ctx.draw(cgImg, in: artboardRect)
                    ctx.restoreGState()
                }
            } else if let bg = backgroundPreview {
                drawBackgroundPreview(bg, artboardRect: artboardRect, ctx: ctx)
            }
        }

        if let badge = badgeTitle {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.85, blue: 1.0, alpha: 0.95),
                .backgroundColor: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.85)
            ]
            let astr = NSAttributedString(string: " \(badge) ", attributes: badgeAttrs)
            astr.draw(at: CGPoint(x: artboardRect.minX + 16, y: artboardRect.minY + 16))
        }
    }

    /// TR-019-R：只读预览的可见占位绘制。
    /// 每个图层按其 Motion 坐标画一个彩色边框占位块，块内写文字内容（无文字则写层名），
    /// 左上角标序号，底部标层名。全程不读位图，因此分组层 / 无贴图模板也不会全黑。
    private func drawMotiPlaceholders(in artboardRect: CGRect, ctx: CGContext) {
        guard !layers.isEmpty else { return }

        let palette: [NSColor] = [
            NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1.0),
            NSColor(calibratedRed: 0.31, green: 0.80, blue: 0.77, alpha: 1.0),
            NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.40, alpha: 1.0),
            NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.98, alpha: 1.0),
            NSColor(calibratedRed: 0.49, green: 0.83, blue: 0.99, alpha: 1.0),
            NSColor(calibratedRed: 0.98, green: 0.63, blue: 0.83, alpha: 1.0)
        ]

        // 画板顶部标题条：让「预览」有明确的内容标识
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 46),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0)
        ]
        NSAttributedString(string: "只读预览 · 共 \(layers.count) 层", attributes: titleAttrs)
            .draw(at: CGPoint(x: artboardRect.minX + 36, y: artboardRect.maxY - 82))

        let centerStyle = NSMutableParagraphStyle()
        centerStyle.alignment = .center
        centerStyle.lineBreakMode = .byTruncatingTail

        for (i, layer) in layers.enumerated() {
            guard layer.visible else { continue }
            let color = palette[i % palette.count]
            let hasText = !layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let display = hasText
                ? layer.text.replacingOccurrences(of: "\n", with: " ")
                : "［\(layer.name)］"

            // 框宽按文字长度估，限制在画板宽度内
            let boxW = min(artboardRect.width * 0.44, max(260, CGFloat(display.count) * 32))
            let boxH: CGFloat = hasText ? 118 : 94
            // Motion 坐标：X 向右、Y 向上；与 drawLayer 保持同一约定
            let cx = CGFloat(layer.posX)
            let cy = CGFloat(-layer.posY)
            let rect = CGRect(x: cx - boxW / 2, y: cy - boxH / 2, width: boxW, height: boxH)

            ctx.saveGState()
            ctx.setFillColor(color.withAlphaComponent(hasText ? 0.20 : 0.10).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(3.0)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

            // 左上角序号
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 26),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85)
            ]
            NSAttributedString(string: " \(i + 1) ", attributes: badgeAttrs)
                .draw(at: CGPoint(x: rect.minX + 10, y: rect.maxY - 34))

            // 中间文字 / 占位层名
            let clipped = display.count > 26 ? String(display.prefix(26)) + "…" : display
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: hasText ? 48 : 36, weight: .semibold),
                .foregroundColor: hasText ? NSColor.white : color.withAlphaComponent(0.92),
                .paragraphStyle: centerStyle
            ]
            NSAttributedString(string: clipped, attributes: textAttrs)
                .draw(in: CGRect(x: rect.minX + 10, y: rect.midY - 30, width: rect.width - 20, height: 60))

            // 底部层名
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1.0),
                .paragraphStyle: centerStyle
            ]
            NSAttributedString(string: layer.name, attributes: nameAttrs)
                .draw(in: CGRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: 28))
        }
    }

    private func drawDotGrid(in rect: CGRect, ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.07).cgColor)
        let step: CGFloat = 32.0
        let startX = rect.minX - rect.minX.truncatingRemainder(dividingBy: step)
        let startY = rect.minY - rect.minY.truncatingRemainder(dividingBy: step)

        for x in stride(from: startX, to: rect.maxX, by: step) {
            for y in stride(from: startY, to: rect.maxY, by: step) {
                ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
    }

    // UI-O012: 空态叠加居中引导文案+图示，拖入后消失
    private func drawEmptyStatePrompt(in artboardRect: CGRect, ctx: CGContext) {
        let title = "拖入 PSD 开始设计"
        let subtitle = "支持拖放单个或批量 .psd 文件至此画布"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.65)
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        ]
        let tStr = NSAttributedString(string: title, attributes: titleAttrs)
        let sStr = NSAttributedString(string: subtitle, attributes: subAttrs)
        let tSize = tStr.size()
        let sSize = sStr.size()
        let totalH = tSize.height + 8 + sSize.height
        let startY = artboardRect.midY + totalH / 2.0 - tSize.height

        let tRect = CGRect(x: artboardRect.midX - tSize.width / 2.0, y: startY, width: tSize.width, height: tSize.height)
        let sRect = CGRect(x: artboardRect.midX - sSize.width / 2.0, y: startY - 8 - sSize.height, width: sSize.width, height: sSize.height)
        tStr.draw(in: tRect)
        sStr.draw(in: sRect)
    }

    private func drawSafeFrames(in rect: CGRect, ctx: CGContext) {
        // 90% 动作安全框
        let r90 = rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05)
        ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.12).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 6])
        ctx.stroke(r90)

        // 80% 标题安全框
        let r80 = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.25).cgColor)
        ctx.stroke(r80)

        // 十字准星
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.35).cgColor)
        ctx.move(to: CGPoint(x: 0, y: rect.minY))
        ctx.addLine(to: CGPoint(x: 0, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.minX, y: 0))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: 0))
        ctx.strokePath()
    }

    /// R33 / A-68：从缓存/磁盘取位图。缓存 key 用绝对路径。
    /// TR-024：位图层带 colorOverride 时按「路径 + 模式 + 颜色」取换色结果，
    /// 否则 key 退化成纯路径，行为和改动前完全一致。
    private func image(for layer: LayerModel) -> NSImage? {
        guard let path = layer.fallbackPngPath, !path.isEmpty else { return nil }
        let recolorKey = Self.recolorCacheKey(for: layer)
        let key = (recolorKey.isEmpty ? path : "\(path)|\(recolorKey)") as NSString
        if let cached = imageCache.object(forKey: key) { return cached }

        let base = NSImage(contentsOfFile: path)
        var img = base
        if !recolorKey.isEmpty, let base = base, let target = Self.recolorColor(for: layer) {
            var proposed = CGRect(origin: .zero, size: base.size)
            if let cg = base.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
               let recolored = PngRecolor.recolor(cg, mode: Self.recolorMode(for: layer), color: target) {
                img = NSImage(cgImage: recolored, size: base.size)
            }
        }
        guard let img = img else { return nil }
        imageCache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4))
        return img
    }

    /// TR-024：换色缓存键片段（""=不换色）。换模式或换颜色都必须换 key，否则画布不刷新 / 串色。
    static func recolorCacheKey(for layer: LayerModel) -> String {
        guard layer.isBitmapLayer, let color = recolorColor(for: layer) else { return "" }
        return "\(recolorMode(for: layer).rawValue)#\(InfiniteCanvasView.hexString(from: color))"
    }

    static func recolorMode(for layer: LayerModel) -> RecolorMode {
        RecolorMode(rawValue: layer.recolorMode) ?? .luminance
    }

    /// 空串 / 非法 HEX → nil，该层继续用原图像素，绝不拿默认色冒充「已换色」。
    static func recolorColor(for layer: LayerModel) -> NSColor? {
        let raw = layer.colorOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count == 7, raw.hasPrefix("#"),
              let value = UInt32(raw.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1.0)
    }

    static func hexString(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func ch(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", ch(c.redComponent), ch(c.greenComponent), ch(c.blueComponent))
    }

    /// 底板预览：按 PSD bbox 直接落在画板坐标（bbox 原点=画布左上角）。
    private func drawBackgroundPreview(_ layer: LayerModel, artboardRect: CGRect, ctx: CGContext) {
        let b = layer.psdBBox
        let rect: CGRect
        if b.count == 4, b[2] > b[0], b[3] > b[1] {
            rect = CGRect(x: b[0] - artboardWidth / 2, y: b[1] - artboardHeight / 2,
                          width: b[2] - b[0], height: b[3] - b[1])
        } else {
            rect = artboardRect
        }
        guard let img = image(for: layer) else { return }
        img.draw(in: rect, from: .zero, operation: .sourceOver,
                 fraction: CGFloat(layer.opacity), respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high])
    }

    /// R33 / A-68：位图图层渲染（含缺失贴图的显式占位，绝不画“空”冒充成功）。
    private func drawBitmap(layer: LayerModel, isSelected: Bool, ctx: CGContext) {
        let size = layer.bitmapSize
        var w = CGFloat(size.width)
        var h = CGFloat(size.height)
        let img = image(for: layer)
        if (w <= 0 || h <= 0), let img = img {
            w = img.size.width
            h = img.size.height
        }
        guard w > 0, h > 0 else { return }

        ctx.saveGState()
        // Motion: X 向右，Y 向上；AppKit: Y 向下
        ctx.translateBy(x: CGFloat(layer.posX), y: CGFloat(-layer.posY))
        ctx.rotate(by: CGFloat(layer.rotation) * .pi / 180.0)
        ctx.scaleBy(x: CGFloat(layer.scaleX), y: CGFloat(layer.scaleY))
        ctx.setAlpha(CGFloat(layer.opacity))

        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

        if isSelected {
            drawSelectionFrame(in: rect.insetBy(dx: -8, dy: -8), isLocked: layer.isLocked, ctx: ctx)
        }

        if let img = img {
            img.draw(in: rect, from: .zero, operation: .sourceOver,
                     fraction: 1.0, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // 贴图缺失：画出可见的失败占位 + 原因，不允许“全黑=正常”。
            ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.12, blue: 0.10, alpha: 0.55).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(2.0 / zoomScale)
            ctx.setLineDash(phase: 0, lengths: [6 / zoomScale, 4 / zoomScale])
            ctx.stroke(rect)
            let msg = "位图层未生成贴图：\(layer.name)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(12, min(w, h) * 0.04), weight: .medium),
                .foregroundColor: NSColor.systemOrange
            ]
            NSAttributedString(string: msg, attributes: attrs).draw(
                in: CGRect(x: rect.minX + 8, y: rect.midY - 10, width: max(10, rect.width - 16), height: 24)
            )
        }

        ctx.restoreGState()
    }

    // MARK: - R36 / D-74：图层选中高亮与锁定徽标绘制
    public func drawSelectionFrame(in boxRect: CGRect, isLocked: Bool, ctx: CGContext) {
        if isLocked {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemGray.cgColor)
            ctx.setLineWidth(1.5 / zoomScale)
            ctx.setLineDash(phase: 0, lengths: [2.5 / zoomScale, 2.5 / zoomScale])
            ctx.stroke(boxRect)
            ctx.restoreGState()

            // 绘制 🔒 LOCKED 徽标（右上角）
            let badgeH = max(16.0, 18.0 / zoomScale)
            let badgeW = max(65.0, 72.0 / zoomScale)
            let badgeRect = CGRect(x: boxRect.maxX - badgeW, y: boxRect.minY - badgeH - (4.0 / zoomScale), width: badgeW, height: badgeH)

            ctx.saveGState()
            ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.95).cgColor)
            let path = CGPath(roundedRect: badgeRect, cornerWidth: 3.0 / zoomScale, cornerHeight: 3.0 / zoomScale, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            ctx.setStrokeColor(NSColor.systemGray.cgColor)
            ctx.setLineWidth(1.0 / zoomScale)
            ctx.addPath(path)
            ctx.strokePath()

            let fontSize = max(9.0, 11.0 / zoomScale)
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0),
                .paragraphStyle: pStyle
            ]
            let badgeStr = NSAttributedString(string: "🔒 LOCKED", attributes: attrs)
            badgeStr.draw(in: CGRect(x: badgeRect.minX, y: badgeRect.midY - fontSize * 0.65, width: badgeRect.width, height: fontSize * 1.3))
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.9).cgColor)
            ctx.setLineWidth(1.5 / zoomScale)
            ctx.setLineDash(phase: 0, lengths: [4 / zoomScale, 4 / zoomScale])
            ctx.stroke(boxRect)
            ctx.restoreGState()
        }
    }

    // MARK: - R35 / D-73：智能对齐吸附系统
    private func drawAlignmentGuides(in artboardRect: CGRect, ctx: CGContext) {
        guard !activeGuides.isEmpty else { return }
        for guide in activeGuides {
            ctx.saveGState()
            ctx.setStrokeColor(guide.color.cgColor)
            ctx.setLineWidth(max(1.0, 1.2 / zoomScale))
            ctx.setLineDash(phase: 0, lengths: [4.0 / zoomScale, 3.0 / zoomScale])
            ctx.beginPath()
            if guide.orientation == .vertical {
                ctx.move(to: CGPoint(x: guide.position, y: guide.start))
                ctx.addLine(to: CGPoint(x: guide.position, y: guide.end))
            } else {
                ctx.move(to: CGPoint(x: guide.start, y: guide.position))
                ctx.addLine(to: CGPoint(x: guide.end, y: guide.position))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    public func layerVisualSize(for layer: LayerModel) -> CGSize {
        if layer.isBitmapLayer {
            let s = layer.bitmapSize
            var w = CGFloat(s.width)
            var h = CGFloat(s.height)
            if (w <= 0 || h <= 0), let img = image(for: layer) {
                w = img.size.width
                h = img.size.height
            }
            return CGSize(width: max(1.0, w), height: max(1.0, h))
        }

        let b = layer.psdBBox
        var bw = (b.count == 4) ? max(1.0, CGFloat(b[2] - b[0])) : 0.0
        var bh = (b.count == 4) ? max(1.0, CGFloat(b[3] - b[1])) : 0.0

        if !layer.text.isEmpty {
            let fontSize = CGFloat(layer.fontSize)
            let font = NSFont(name: layer.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let style = NSMutableParagraphStyle()
            if layer.lineSpacing > 0 {
                style.lineSpacing = max(0, CGFloat(layer.lineSpacing) - CGFloat(layer.fontSize * 1.15))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: style
            ]
            let astr = NSAttributedString(string: layer.text, attributes: attrs)
            let neededSize = astr.boundingRect(
                with: CGSize(width: max(bw * 2.0, 4000), height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size
            bw = max(bw, ceil(neededSize.width) + 24)
            bh = max(bh, ceil(neededSize.height) + 24)
        }

        if bw > 0 && bh > 0 {
            // 图元以几何中心为原点。旋转 90°/270° 时，屏幕上的视觉高度对应局部宽度，视觉宽度对应局部高度
            if abs(sin(CGFloat(layer.rotation) * .pi / 180.0)) > 0.7 {
                return CGSize(width: bh, height: bw)
            } else {
                return CGSize(width: bw, height: bh)
            }
        } else {
            let lines = layer.text.components(separatedBy: "\n")
            let lineCount = CGFloat(max(1, lines.count))
            let fontSize = CGFloat(layer.fontSize)
            let lineHeight = layer.lineSpacing > 0 ? CGFloat(layer.lineSpacing) : (fontSize * 1.25)
            let totalH = lineCount * lineHeight
            let totalW = max(40.0, CGFloat(layer.text.count) * fontSize * 0.8)
            return CGSize(width: totalW, height: totalH)
        }
    }

    /// R35 / D-73：拖拽图层时的智能对齐吸附计算
    /// - Parameters:
    ///   - proposedCanvasX: 待吸附的画布 X 坐标（图层几何中心，等价于 layer.posX）
    ///   - proposedCanvasY: 待吸附的画布 Y 坐标（图层几何中心，向下为正，等价于 -layer.posY）
    ///   - layerIndex: 正在拖动的图层索引
    ///   - disableSnapping: 是否临时禁用吸附（例如按住 ⌘ 键）
    ///   - screenThreshold: 屏幕吸附阈值（像素），默认 6.0
    /// - Returns: 吸附后的坐标 (snappedX, snappedY) 以及生成的参考线
    public func calculateSnap(
        proposedCanvasX: CGFloat,
        proposedCanvasY: CGFloat,
        layerIndex: Int,
        disableSnapping: Bool = false,
        screenThreshold: CGFloat = 6.0
    ) -> (snappedX: CGFloat, snappedY: CGFloat, guides: [AlignmentGuide]) {
        guard !disableSnapping, layerIndex >= 0, layerIndex < layers.count else {
            return (proposedCanvasX, proposedCanvasY, [])
        }

        let curLayer = layers[layerIndex]
        let curSize = layerVisualSize(for: curLayer)
        let halfW = curSize.width / 2.0
        let halfH = curSize.height / 2.0

        // 阈值设为 <= 6.0 像素（换算到画布坐标空间）
        let threshold = screenThreshold / max(0.001, zoomScale)

        var guides: [AlignmentGuide] = []

        // 收集 X 轴吸附目标（垂直线）
        // 探测源：① 画板几何中心 X=0；② 90% 动作安全区、80% 标题安全区；③ 其他所有可见图层
        var xTargets: [(val: CGFloat, yMin: CGFloat, yMax: CGFloat, isCenterOrSafe: Bool)] = [
            (0.0, -artboardHeight / 2.0, artboardHeight / 2.0, true),
            (-artboardWidth * 0.45, -artboardHeight * 0.45, artboardHeight * 0.45, true),
            (artboardWidth * 0.45, -artboardHeight * 0.45, artboardHeight * 0.45, true),
            (-artboardWidth * 0.40, -artboardHeight * 0.40, artboardHeight * 0.40, true),
            (artboardWidth * 0.40, -artboardHeight * 0.40, artboardHeight * 0.40, true)
        ]

        // 收集 Y 轴吸附目标（水平线）
        // 探测源：① 画板几何中心 Y=0；② 90% 动作安全区、80% 标题安全区；③ 其他所有可见图层
        var yTargets: [(val: CGFloat, xMin: CGFloat, xMax: CGFloat, isCenterOrSafe: Bool)] = [
            (0.0, -artboardWidth / 2.0, artboardWidth / 2.0, true),
            (-artboardHeight * 0.45, -artboardWidth * 0.45, artboardWidth * 0.45, true),
            (artboardHeight * 0.45, -artboardWidth * 0.45, artboardWidth * 0.45, true),
            (-artboardHeight * 0.40, -artboardWidth * 0.40, artboardWidth * 0.40, true),
            (artboardHeight * 0.40, -artboardWidth * 0.40, artboardWidth * 0.40, true)
        ]

        for (i, other) in layers.enumerated() {
            guard i != layerIndex, other.visible else { continue }
            let oSize = layerVisualSize(for: other)
            let oCx = CGFloat(other.posX)
            let oCy = CGFloat(-other.posY)
            let oHalfW = oSize.width / 2.0
            let oHalfH = oSize.height / 2.0

            let yMin = oCy - oHalfH
            let yMax = oCy + oHalfH
            let xMin = oCx - oHalfW
            let xMax = oCx + oHalfW

            xTargets.append((oCx - oHalfW, yMin, yMax, false))
            xTargets.append((oCx, yMin, yMax, false))
            xTargets.append((oCx + oHalfW, yMin, yMax, false))

            yTargets.append((oCy - oHalfH, xMin, xMax, false))
            yTargets.append((oCy, xMin, xMax, false))
            yTargets.append((oCy + oHalfH, xMin, xMax, false))
        }

        // 1. X 轴吸附探测（图层的左、中、右）
        let curXPoints: [(val: CGFloat, offset: CGFloat)] = [
            (proposedCanvasX - halfW, -halfW),
            (proposedCanvasX, 0.0),
            (proposedCanvasX + halfW, halfW)
        ]

        var bestDeltaX: CGFloat? = nil
        var bestTargetX: (val: CGFloat, yMin: CGFloat, yMax: CGFloat, isCenterOrSafe: Bool)? = nil

        for p in curXPoints {
            for target in xTargets {
                let delta = target.val - p.val
                if abs(delta) <= threshold {
                    if let curBest = bestDeltaX {
                        if abs(delta) < abs(curBest) || (abs(delta) == abs(curBest) && target.isCenterOrSafe && !(bestTargetX?.isCenterOrSafe ?? false)) {
                            bestDeltaX = delta
                            bestTargetX = target
                        }
                    } else {
                        bestDeltaX = delta
                        bestTargetX = target
                    }
                }
            }
        }

        let finalX: CGFloat
        if let dx = bestDeltaX, let target = bestTargetX {
            finalX = proposedCanvasX + dx
            let color = target.isCenterOrSafe
                ? NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 0.95)
                : NSColor(calibratedRed: 0.0, green: 0.85, blue: 1.0, alpha: 0.95)
            let minY = min(proposedCanvasY - halfH, target.yMin) - 24
            let maxY = max(proposedCanvasY + halfH, target.yMax) + 24
            guides.append(AlignmentGuide(orientation: .vertical, position: target.val, start: minY, end: maxY, color: color))
        } else {
            finalX = proposedCanvasX
        }

        // 2. Y 轴吸附探测（图层的顶、中、底）
        let curYPoints: [(val: CGFloat, offset: CGFloat)] = [
            (proposedCanvasY - halfH, -halfH),
            (proposedCanvasY, 0.0),
            (proposedCanvasY + halfH, halfH)
        ]

        var bestDeltaY: CGFloat? = nil
        var bestTargetY: (val: CGFloat, xMin: CGFloat, xMax: CGFloat, isCenterOrSafe: Bool)? = nil

        for p in curYPoints {
            for target in yTargets {
                let delta = target.val - p.val
                if abs(delta) <= threshold {
                    if let curBest = bestDeltaY {
                        if abs(delta) < abs(curBest) || (abs(delta) == abs(curBest) && target.isCenterOrSafe && !(bestTargetY?.isCenterOrSafe ?? false)) {
                            bestDeltaY = delta
                            bestTargetY = target
                        }
                    } else {
                        bestDeltaY = delta
                        bestTargetY = target
                    }
                }
            }
        }

        let finalY: CGFloat
        if let dy = bestDeltaY, let target = bestTargetY {
            finalY = proposedCanvasY + dy
            let color = target.isCenterOrSafe
                ? NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 0.95)
                : NSColor(calibratedRed: 0.0, green: 0.85, blue: 1.0, alpha: 0.95)
            let minX = min(finalX - halfW, target.xMin) - 24
            let maxX = max(finalX + halfW, target.xMax) + 24
            guides.append(AlignmentGuide(orientation: .horizontal, position: target.val, start: minX, end: maxX, color: color))
        } else {
            finalY = proposedCanvasY
        }

        return (finalX, finalY, guides)
    }

    /// TR-023-B：把 "#RRGGBB" 解析成 NSColor。空串 / 格式不对返回 nil，
    /// 调用方退回 labelColor —— 绝不拿默认色冒充「已取到颜色」。
    static func textColor(fromHex hex: String) -> NSColor? {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count == 7, raw.hasPrefix("#"),
              let value = UInt32(raw.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1.0)
    }

    private func drawLayer(_ layer: LayerModel, isSelected: Bool, ctx: CGContext) {        // R33 / A-68：位图层走位图渲染分支（旧实现只有文字路径，位图层画出来是空的）
        if layer.isBitmapLayer {
            drawBitmap(layer: layer, isSelected: isSelected, ctx: ctx)
            return
        }

        ctx.saveGState()
        // Motion: X 向右，Y 向上；AppKit: Y 向下
        ctx.translateBy(x: CGFloat(layer.posX), y: CGFloat(-layer.posY))
        ctx.rotate(by: CGFloat(layer.rotation) * .pi / 180.0)
        ctx.scaleBy(x: CGFloat(layer.scaleX), y: CGFloat(layer.scaleY))
        ctx.setAlpha(CGFloat(layer.opacity))

        // 绘制文字
        let style = NSMutableParagraphStyle()
        switch layer.alignment.lowercased() {
        case "left":
            style.alignment = .left
        case "right":
            style.alignment = .right
        case "center":
            style.alignment = .center
        default:
            style.alignment = .center
        }
        if layer.lineSpacing > 0 {
            style.lineSpacing = max(0, CGFloat(layer.lineSpacing) - CGFloat(layer.fontSize * 1.15))
        }

        let fontSize = CGFloat(layer.fontSize)
        let font = NSFont(name: layer.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .medium)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            // UI-O008: 未取到颜色时退回语义化 labelColor，确保未来切浅色主题时文字不消失
            .foregroundColor: Self.textColor(fromHex: layer.textColor) ?? NSColor.labelColor,
            .paragraphStyle: style
        ]

        let astr = NSAttributedString(string: layer.text, attributes: attrs)

        let b = layer.psdBBox
        let bw = (b.count == 4) ? max(1.0, CGFloat(b[2] - b[0])) : 0.0
        let bh = (b.count == 4) ? max(1.0, CGFloat(b[3] - b[1])) : 0.0

        let neededSize = astr.boundingRect(
            with: CGSize(width: max(bw * 2.0, 4000), height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let drawW = max(bw, ceil(neededSize.width) + 24)
        let drawH = max(bh, ceil(neededSize.height) + 24)

        let textRect = CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH)

        // 选中高亮边框（支持普通高亮与锁定专属灰色虚框+🔒徽标）
        if isSelected {
            drawSelectionFrame(in: textRect.insetBy(dx: -8, dy: -8), isLocked: layer.isLocked, ctx: ctx)
        }

        astr.draw(in: textRect)

        ctx.restoreGState()
    }

    // MARK: - 鼠标手势与平移缩放
    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let mousePos = convert(event.locationInWindow, from: nil)
            let delta = event.deltaY * 0.02
            let oldZoom = zoomScale
            let newZoom = max(Self.kMinZoom, min(Self.kMaxZoom, oldZoom + delta))
            if oldZoom != newZoom {
                // UI-O006: 以光标为锚点反算 panOffset，跟随鼠标位置缩放
                let centerPt = CGPoint(x: bounds.midX + panOffset.x, y: bounds.midY + panOffset.y)
                let cursorToCenter = CGPoint(x: mousePos.x - centerPt.x, y: mousePos.y - centerPt.y)
                let scaleRatio = newZoom / oldZoom
                panOffset.x += cursorToCenter.x * (1.0 - scaleRatio)
                panOffset.y += cursorToCenter.y * (1.0 - scaleRatio)
                zoomScale = newZoom
                onZoomChanged?(zoomScale)
                needsDisplay = true
            }
        } else {
            panOffset.x += event.deltaX * 1.5
            panOffset.y += event.deltaY * 1.5
            needsDisplay = true
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let peeking = event.modifierFlags.contains(.option)
        if peeking != isPeekingOriginal {
            isPeekingOriginal = peeking
            needsDisplay = true
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let mousePos = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            isPanning = true
            panStartMousePos = mousePos
            return
        }

        // 卷帘对比模式下，检测是否拖动中轴分割线
        if comparisonMode == .splitCurtain {
            let centerX = bounds.width / 2.0 + panOffset.x
            let mouseArtX = (mousePos.x - centerX) / zoomScale
            let dividerX = -artboardWidth / 2 + artboardWidth * splitDividerPosition
            if abs(mouseArtX - dividerX) <= 30 / zoomScale {
                isDraggingDivider = true
                return
            }
        }

        // 图层拾取检测
        let hitIdx = hitTestLayer(at: mousePos)
        if hitIdx >= 0 {
            selectedLayerIndex = hitIdx
            onLayerSelected?(hitIdx)
            let l = layers[hitIdx]
            // R36 / D-74: 锁定状态下禁止拖动平移
            if !l.isLocked {
                isDraggingLayer = true
                dragStartMousePos = mousePos
                dragStartLayerPos = CGPoint(x: l.posX, y: l.posY)
            } else {
                isDraggingLayer = false
            }
        } else {
            selectedLayerIndex = -1
            isPanning = true
            panStartMousePos = mousePos
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let mousePos = convert(event.locationInWindow, from: nil)

        // 卷帘中轴线拖拽
        if isDraggingDivider && comparisonMode == .splitCurtain {
            let centerX = bounds.width / 2.0 + panOffset.x
            let mouseArtX = (mousePos.x - centerX) / zoomScale
            let ratio = (mouseArtX - (-artboardWidth / 2)) / artboardWidth
            splitDividerPosition = min(0.98, max(0.02, ratio))
            needsDisplay = true
            return
        }

        if isPanning {
            // FCPX-044: panOffset 设立视口边界钳制（±3000pt），杜绝拖到屏幕外无穷远
            let maxPan: CGFloat = 3000.0
            let newX = panOffset.x + (mousePos.x - panStartMousePos.x)
            let newY = panOffset.y + (mousePos.y - panStartMousePos.y)
            panOffset.x = min(maxPan, max(-maxPan, newX))
            panOffset.y = min(maxPan, max(-maxPan, newY))
            panStartMousePos = mousePos
            needsDisplay = true
            return
        }

        if isDraggingLayer && selectedLayerIndex >= 0 && selectedLayerIndex < layers.count {
            let layer = layers[selectedLayerIndex]
            // R36 / D-74: 防御性拦截，锁定图层绝不响应拖动
            guard !layer.isLocked else {
                isDraggingLayer = false
                return
            }
            let dx = (mousePos.x - dragStartMousePos.x) / zoomScale
            let dy = (mousePos.y - dragStartMousePos.y) / zoomScale

            let rawCanvasX = dragStartLayerPos.x + dx
            let rawCanvasY = -dragStartLayerPos.y + dy // Motion Y -> Canvas Y

            let isCmd = event.modifierFlags.contains(.command)
            let snap = calculateSnap(
                proposedCanvasX: rawCanvasX,
                proposedCanvasY: rawCanvasY,
                layerIndex: selectedLayerIndex,
                disableSnapping: isCmd
            )

            layer.posX = round(snap.snappedX * 10) / 10.0
            layer.posY = round(-snap.snappedY * 10) / 10.0 // Canvas Y -> Motion Y
            activeGuides = snap.guides
            onLayerMoved?(layer)
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if isDraggingLayer && selectedLayerIndex >= 0 && selectedLayerIndex < layers.count {
            onLayerMoved?(layers[selectedLayerIndex])
        }
        isDraggingDivider = false
        isDraggingLayer = false
        isPanning = false
        if !activeGuides.isEmpty {
            activeGuides.removeAll()
            needsDisplay = true
        }
    }

    public func hitTestLayer(at mousePos: CGPoint) -> Int {
        if comparisonMode == .sideBySide {
            let gap: CGFloat = 80.0
            let offset = (artboardWidth / 2 + gap / 2) * zoomScale
            var ptLeft = mousePos
            ptLeft.x -= offset
            let hitLeft = testHitLayers(at: ptLeft)
            if hitLeft != -1 { return hitLeft }

            var ptRight = mousePos
            ptRight.x += offset
            let hitRight = testHitLayers(at: ptRight)
            if hitRight != -1 { return hitRight }
            return -1
        }
        return testHitLayers(at: mousePos)
    }

    private func testHitLayers(at pt: CGPoint) -> Int {
        let centerX = bounds.width / 2.0 + panOffset.x
        let centerY = bounds.height / 2.0 + panOffset.y

        // PSD 数组顺序是「顶 → 底」，拾取必须从顶到底（正序）判断。
        for i in 0..<layers.count {
            let layer = layers[i]
            guard layer.visible else { continue }
            // R36 / D-74：拾取穿透保护，跳过被锁定图层，优先拾取其下方的未锁定图层
            guard !layer.isLocked else { continue }

            let layerCanvasX = centerX + CGFloat(layer.posX) * zoomScale
            let layerCanvasY = centerY - CGFloat(layer.posY) * zoomScale

            let size = layerVisualSize(for: layer)
            let halfW = max(4, size.width * zoomScale / 2.0) + 8
            let halfH = max(4, size.height * zoomScale / 2.0) + 8

            let r = CGRect(x: layerCanvasX - halfW, y: layerCanvasY - halfH,
                           width: halfW * 2, height: halfH * 2)
            if r.contains(pt) {
                return i
            }
        }
        return -1
    }

    // FCPX-044: ⌘0 适应画板 / 回到画板
    public func resetPanAndZoom() {
        panOffset = .zero
        zoomScale = 1.0
        needsDisplay = true
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "0" {
            resetPanAndZoom()
            return
        }
        super.keyDown(with: event)
    }
}
