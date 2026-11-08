import AppKit

// ═══════════════════════════════════════════════════════════════
//  AudioWaveformView —— 真实声学 128 点对称波形图与交互指示器
//  对标基准：/Applications/嘉星插件管理 2.app (FxAudioWaveformView)
// ═══════════════════════════════════════════════════════════════

public final class AudioWaveformView: NSView {

    // MARK: – Properties

    public var amplitudes: [Float] = [] {
        didSet {
            needsDisplay = true
        }
    }

    public var playbackProgress: CGFloat = 0.0 {
        didSet {
            needsDisplay = true
        }
    }

    public var onSeek: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoverRatio: CGFloat?

    // 颜色配置
    public var playedColor = ColorToken.waveformPlayed     // 天蓝
    public var unplayedColor = ColorToken.waveformUnplayed   // 暗石板灰
    public var playheadColor = NSColor.white
    public var centerLineColor = NSColor(white: 0.3, alpha: 0.4)

    // MARK: – Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = ColorToken.cardBg.cgColor
        layer?.cornerRadius = 6.0
        layer?.masksToBounds = true
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
        let loc = convert(event.locationInWindow, from: nil)
        hoverRatio = max(0.0, min(1.0, loc.x / bounds.width))
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hoverRatio = nil
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        handleSeek(event: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        handleSeek(event: event)
    }

    private func handleSeek(event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        let ratio = max(0.0, min(1.0, loc.x / bounds.width))
        playbackProgress = ratio
        onSeek?(ratio)
    }

    // MARK: – Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let targetBounds = bounds
        guard targetBounds.width > 0, targetBounds.height > 0 else { return }

        // UI-G040: amplitudes 为空时居中显示"无音频数据"，不绘制误导性中心线
        if amplitudes.isEmpty {
            let emptyText = "无音频数据"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: TypeScale.footnote,
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0)
            ]
            let strSize = (emptyText as NSString).size(withAttributes: attrs)
            let drawPoint = NSPoint(x: (targetBounds.width - strSize.width) / 2.0,
                                    y: (targetBounds.height - strSize.height) / 2.0)
            (emptyText as NSString).draw(at: drawPoint, withAttributes: attrs)
            return
        }

        let midY = targetBounds.midY
        let maxHeight = (targetBounds.height - 12) / 2.0

        // 1. 中心水平基准线
        let centerLine = NSBezierPath()
        centerLine.move(to: NSPoint(x: 0, y: midY))
        centerLine.line(to: NSPoint(x: targetBounds.width, y: midY))
        centerLine.lineWidth = 1.0
        centerLineColor.setStroke()
        centerLine.stroke()

        let count = max(1, amplitudes.count)
        let slotWidth = targetBounds.width / CGFloat(count)
        let barWidth = max(1.5, slotWidth * 0.72)
        let playheadX = targetBounds.width * playbackProgress

        // 2. 绘制 128 点平滑对称柱状波形
        for (i, amp) in amplitudes.enumerated() {
            let x = CGFloat(i) * slotWidth + (slotWidth - barWidth) / 2.0
            let h = max(2.0, CGFloat(amp) * maxHeight)

            let isPlayed = (x + barWidth) <= playheadX
            let color = isPlayed ? playedColor : unplayedColor
            color.setFill()

            // 上半部分
            let upperRect = NSRect(x: x, y: midY, width: barWidth, height: h)
            let upperPath = NSBezierPath(roundedRect: upperRect, xRadius: 1.0, yRadius: 1.0)
            upperPath.fill()

            // 下半部分（对称镜像）
            let lowerRect = NSRect(x: x, y: midY - h, width: barWidth, height: h)
            let lowerPath = NSBezierPath(roundedRect: lowerRect, xRadius: 1.0, yRadius: 1.0)
            lowerPath.fill()
        }

        // 3. 悬停参考虚线
        if let hr = hoverRatio {
            let hx = targetBounds.width * hr
            let hoverLine = NSBezierPath()
            hoverLine.move(to: NSPoint(x: hx, y: 0))
            hoverLine.line(to: NSPoint(x: hx, y: targetBounds.height))
            let dashes: [CGFloat] = [2.0, 2.0]
            hoverLine.setLineDash(dashes, count: 2, phase: 0)
            hoverLine.lineWidth = 1.0
            NSColor(white: 1.0, alpha: 0.35).setStroke()
            hoverLine.stroke()
        }

        // 4. 播放指针线 (Playhead Indicator)
        let playhead = NSBezierPath()
        playhead.move(to: NSPoint(x: playheadX, y: 0))
        playhead.line(to: NSPoint(x: playheadX, y: targetBounds.height))
        playhead.lineWidth = 2.0
        playheadColor.setStroke()
        playhead.stroke()

        // 播放指针顶部小菱形/三角形装饰
        let capH: CGFloat = 6.0
        let capPath = NSBezierPath()
        capPath.move(to: NSPoint(x: playheadX - 4, y: targetBounds.height))
        capPath.line(to: NSPoint(x: playheadX + 4, y: targetBounds.height))
        capPath.line(to: NSPoint(x: playheadX, y: targetBounds.height - capH))
        capPath.close()
        playheadColor.setFill()
        capPath.fill()
    }
}
