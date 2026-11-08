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
}
