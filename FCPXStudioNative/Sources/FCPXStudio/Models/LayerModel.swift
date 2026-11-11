import Foundation

public final class LayerModel: NSObject {
    public var id: Int
    public var name: String
    public var kind: String // "type" (矢量文字) 或 "fallback_png" (降级贴图)
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var tracking: Double
    public var posX: Double
    public var posY: Double
    public var rotation: Double
    public var scaleX: Double
    public var scaleY: Double
    public var opacity: Double
    public var writingDirection: String // "horizontal" 或 "vertical"
    public var visible: Bool
    public var isPublished: Bool
    /// R36 / D-74：图层锁定状态（true 时防画布误触拾取/拖动，检查器属性控件置灰只读）
    public var isLocked: Bool
    public var fallbackPngPath: String?
    /// R34: 段落对齐 ("left" / "center" / "right") 与真实行距
    public var alignment: String
    public var lineSpacing: Double
    /// TR-023-B：文字填充色 HEX（"#RRGGBB"）。空串 = 该层没有取到颜色，
    /// 检查器据此显示禁用态 + 空态文案，禁止用默认色冒充可用数据。
    public var textColor: String
    /// R33 / A-68：PSD 图层包围盒 (left, top, right, bottom)，位图层按它定位/缩放。
    /// 文本层也带上，便于画布做选中框与拾取的一致性处理。
    public var psdBBox: [Double]
    public var diagnosticNotes: [String]

    /// 该层是否需要按位图绘制（视觉层），而不是矢量文字。
    public var isBitmapLayer: Bool {
        return kind == "fallback_png" || kind == "pixel"
    }

    /// 位图层的像素尺寸（bbox 宽高）；bbox 缺失时为 .zero。
    public var bitmapSize: (width: Double, height: Double) {
        guard psdBBox.count == 4 else { return (0, 0) }
        return (max(0, psdBBox[2] - psdBBox[0]), max(0, psdBBox[3] - psdBBox[1]))
    }

    // MARK: - R28 / A-51：缺字风险一等字段（数据源：core/psd_parser.py 的 to_dict，
    // 判定口径由 core/missing_font.py 统一，Swift 侧只读不重复判定）
    public var highlightMissingFont: Bool   // 需要高亮（缺字形 / 字体风险）
    public var markedText: String           // 可见标记版文本（□=缺字），可能为空
    public var missingChars: [String]       // 缺失字形字符清单
    public var fontStatus: String           // detected / font_missing / unverifiable / missing_fallback
    public var hasConfirmedMissingGlyphs: Bool // R31 / A-59: 确证缺字（missing_chars 非空）
    public var hasGlyphRisk: Bool              // R31 / A-59: 缺字风险（含未验证风险）

    /// 高亮原因摘要：与 core/missing_font.py 的口径一致（缺字形 / 字体风险）
    public var missingGlyphReason: String {
        var reasons: [String] = []
        if !missingChars.isEmpty { reasons.append("缺字形") }
        if highlightMissingFont { reasons.append("字体风险") }
        return reasons.isEmpty ? "缺字风险" : reasons.joined(separator: "/")
    }

    public var publishText: Bool = true
    public var publishFont: Bool = true
    public var publishSize: Bool = true
    public var publishPosition: Bool = true
    public var publishRotation: Bool = false
    public var publishScale: Bool = false
    public var publishTracking: Bool = true

    public init(id: Int, name: String, kind: String = "type", text: String = "", fontName: String = "Helvetica",
                fontSize: Double = 36.0, tracking: Double = 0.0,
                posX: Double = 0.0, posY: Double = 0.0, rotation: Double = 0.0,
                scaleX: Double = 1.0, scaleY: Double = 1.0, opacity: Double = 1.0,
                writingDirection: String = "vertical", visible: Bool = true, isPublished: Bool = true,
                fallbackPngPath: String? = nil, psdBBox: [Double] = [], diagnosticNotes: [String] = [],
                highlightMissingFont: Bool = false, markedText: String = "",
                missingChars: [String] = [], fontStatus: String = "",
                hasConfirmedMissingGlyphs: Bool = false, hasGlyphRisk: Bool = false,
                alignment: String = "center", lineSpacing: Double = 0.0,
                isLocked: Bool = false, textColor: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.tracking = tracking
        self.posX = posX
        self.posY = posY
        self.rotation = rotation
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.opacity = opacity
        self.writingDirection = writingDirection
        self.visible = visible
        self.isPublished = isPublished
        self.isLocked = isLocked
        self.fallbackPngPath = fallbackPngPath
        self.psdBBox = psdBBox
        self.diagnosticNotes = diagnosticNotes
        self.highlightMissingFont = highlightMissingFont
        self.markedText = markedText
        self.missingChars = missingChars
        self.fontStatus = fontStatus
        self.hasConfirmedMissingGlyphs = hasConfirmedMissingGlyphs
        self.hasGlyphRisk = hasGlyphRisk
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.textColor = textColor
        super.init()
    }

    /// R36 / D-74: 深拷贝与状态同步方法
    public func copyModel() -> LayerModel {
        let copy = LayerModel(
            id: id,
            name: name,
            kind: kind,
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            tracking: tracking,
            posX: posX,
            posY: posY,
            rotation: rotation,
            scaleX: scaleX,
            scaleY: scaleY,
            opacity: opacity,
            writingDirection: writingDirection,
            visible: visible,
            isPublished: isPublished,
            fallbackPngPath: fallbackPngPath,
            psdBBox: psdBBox,
            diagnosticNotes: diagnosticNotes,
            highlightMissingFont: highlightMissingFont,
            markedText: markedText,
            missingChars: missingChars,
            fontStatus: fontStatus,
            hasConfirmedMissingGlyphs: hasConfirmedMissingGlyphs,
            hasGlyphRisk: hasGlyphRisk,
            alignment: alignment,
            lineSpacing: lineSpacing,
            isLocked: isLocked,
            textColor: textColor
        )
        copy.publishText = self.publishText
        copy.publishFont = self.publishFont
        copy.publishSize = self.publishSize
        copy.publishPosition = self.publishPosition
        copy.publishRotation = self.publishRotation
        copy.publishScale = self.publishScale
        copy.publishTracking = self.publishTracking
        return copy
    }

    public func sync(from other: LayerModel) {
        self.id = other.id
        self.name = other.name
        self.kind = other.kind
        self.text = other.text
        self.fontName = other.fontName
        self.fontSize = other.fontSize
        self.tracking = other.tracking
        self.posX = other.posX
        self.posY = other.posY
        self.rotation = other.rotation
        self.scaleX = other.scaleX
        self.scaleY = other.scaleY
        self.opacity = other.opacity
        self.writingDirection = other.writingDirection
        self.visible = other.visible
        self.isPublished = other.isPublished
        self.isLocked = other.isLocked
        self.fallbackPngPath = other.fallbackPngPath
        self.psdBBox = other.psdBBox
        self.diagnosticNotes = other.diagnosticNotes
        self.highlightMissingFont = other.highlightMissingFont
        self.markedText = other.markedText
        self.missingChars = other.missingChars
        self.fontStatus = other.fontStatus
        self.hasConfirmedMissingGlyphs = other.hasConfirmedMissingGlyphs
        self.hasGlyphRisk = other.hasGlyphRisk
        self.alignment = other.alignment
        self.lineSpacing = other.lineSpacing
        self.textColor = other.textColor
        self.publishText = other.publishText
        self.publishFont = other.publishFont
        self.publishSize = other.publishSize
        self.publishPosition = other.publishPosition
        self.publishRotation = other.publishRotation
        self.publishScale = other.publishScale
        self.publishTracking = other.publishTracking
    }

    /// 一键转为横排版式：去除单字符换行，重组连贯横排文字
    public func convertToHorizontal() {
        guard kind == "type" else { return }
        let lines = text.components(separatedBy: "\n")
        if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).count <= 1 }) {
            text = lines.joined()
        } else {
            text = lines.joined(separator: " ")
        }
        writingDirection = "horizontal"
    }

    /// 一键转为竖排版式：逐字垂直排列
    public func convertToVertical() {
        guard kind == "type" else { return }
        let raw = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let chars = raw.map { String($0) }
        text = chars.joined(separator: "\n")
        writingDirection = "vertical"
    }
}
