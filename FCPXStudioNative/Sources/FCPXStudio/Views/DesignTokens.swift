import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  DesignTokens —— 全局视觉语言与设计规范常量集 (UI-G010/G018/G026-G031)
// ═══════════════════════════════════════════════════════════════

/// 全仓圆角三档规范 (UI-G010)
public enum CornerRadius {
    /// 徽章、微小标签 (4pt)
    public static let badge: CGFloat = 4.0
    /// 缩略图、容器卡片、输入框、普通面板 (8pt)
    public static let card: CGFloat = 8.0
    /// 胶囊按钮、药丸切片 (14pt)
    public static let capsule: CGFloat = 14.0
}

/// 全仓四级字阶规范 (UI-G019)
public enum TypeScale {
    /// 微标签、辅助提示 (10pt)
    public static let caption: NSFont = .systemFont(ofSize: 10, weight: .regular)
    public static let captionMedium: NSFont = .systemFont(ofSize: 10, weight: .medium)
    
    /// 副标题、次级正文、表格小文字 (11pt)
    public static let footnote: NSFont = .systemFont(ofSize: 11, weight: .regular)
    public static let footnoteMedium: NSFont = .systemFont(ofSize: 11, weight: .medium)
    
    /// 标准正文、按钮文字 (13pt)
    public static let body: NSFont = .systemFont(ofSize: 13, weight: .regular)
    public static let bodyBold: NSFont = .systemFont(ofSize: 13, weight: .bold)
    
    /// 指标卡大数字、区块大标题 (17pt 等宽粗体)
    public static let metricTitle: NSFont = .monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
}

/// 全仓色彩收敛规范 (UI-G018 / UI-G031)
public enum ColorToken {
    /// 统一卡片与看板边框高光 (白 alpha 0.15, UI-G031)
    public static let cardBorder = NSColor(calibratedWhite: 1.0, alpha: 0.15)
    
    /// 统一主蓝系收敛（<=3 档）
    public static let primaryBlue = NSColor(calibratedRed: 0.05, green: 0.50, blue: 1.00, alpha: 1.0)
    public static let accentBlue = NSColor(calibratedRed: 0.20, green: 0.60, blue: 1.00, alpha: 1.0)
    public static let softBlue = NSColor(calibratedRed: 0.05, green: 0.50, blue: 1.00, alpha: 0.18)
    
    /// 表格与网格底色
    public static let tableRowBg = NSColor(calibratedWhite: 0.12, alpha: 0.6)
    public static let tableAlternateRowBg = NSColor(calibratedWhite: 0.15, alpha: 0.6)
    
    /// 面板与侧栏磨砂底色
    public static let panelBg = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.45)
    public static let subpanelBg = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.35)
    public static let activePillBg = NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.38, alpha: 1.0)
    public static let successGreen = NSColor(calibratedRed: 0.28, green: 0.86, blue: 0.55, alpha: 1.0)
    public static let warningAmber = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.28, alpha: 1.0)
    public static let alertRed = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)

    /// 画布与深色卡片背景 (UI-G018)
    public static let cardBg = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
    public static let darkSurface = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.07, alpha: 1.0)
    public static let surfaceRaised = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
    public static let badgeBackground = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.92)

    /// 音频与波形色彩令牌
    public static let waveformPlayed = NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0)
    public static let waveformUnplayed = NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.38, alpha: 0.85)
    public static let audioAccentText = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.95, alpha: 1.0)
    public static let lutAccentText = NSColor(calibratedRed: 0.38, green: 0.74, blue: 0.95, alpha: 1.0)

    /// 拖拽高亮覆盖层令牌
    public static let dropOverlayBg = NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.78, alpha: 0.65)
    public static let dropOverlayBorder = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1.0, alpha: 0.95)

    /// 清理与健康状态色令牌
    public static let statusNormal = NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)
    public static let statusWarning = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
    public static let statusDangerFill = NSColor(calibratedRed: 0.25, green: 0.05, blue: 0.05, alpha: 0.85)
}

public typealias AppTheme = ColorToken

// UI-O016: 统一 hover 响应按钮，支持主按钮与危险按钮鼠标悬停背景渐变反馈
public class HoverButton: NSButton {
    public var normalBgColor: NSColor? {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = normalBgColor?.cgColor
        }
    }
    public var hoverBgColor: NSColor?
    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled, let hover = hoverBgColor {
            wantsLayer = true
            layer?.backgroundColor = hover.cgColor
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let normal = normalBgColor {
            wantsLayer = true
            layer?.backgroundColor = normal.cgColor
        }
    }
}
