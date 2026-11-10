import Foundation

// ═══════════════════════════════════════════════════════════════
//  S3GridLayout —— 纯几何网格布局（S3 / P1 虚拟滚动）
//
//  设计约束：
//   • 只依赖 Foundation（CGFloat 来自 Darwin），**不 import AppKit**，
//     因此可被独立 harness 用 swiftc 直编，不牵连 AssetHubView / ResourceCardView。
//   • 列宽/行高公式 1:1 复刻 AssetHubView.reloadCardGrid 的 R52 自适应流式布局，
//     保证「现状实现」与「新实现」在同样的视口宽度下得到同样的卡片坐标。
//   • 新增能力：由 documentVisibleRect 直接算出「可见 + 缓冲行」的 index 区间，
//     这是视口复用只创建 O(visible) 个视图的几何基础。
// ═══════════════════════════════════════════════════════════════

/// 平台无关的矩形；接入层用 `NSRect(x:y:width:height:)` 转换。
public struct S3Rect {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minY: CGFloat { y }
    public var maxY: CGFloat { y + height }
    public var minX: CGFloat { x }
    public var maxX: CGFloat { x + width }
}

public struct S3GridLayout {
    public let columns: Int
    public let cardWidth: CGFloat
    public let cardHeight: CGFloat
    public let spacing: CGFloat
    public let margin: CGFloat
    public let viewportWidth: CGFloat
    public let viewportHeight: CGFloat
    public let itemCount: Int
    public let rows: Int
    public let contentHeight: CGFloat
    public let footerHeight: CGFloat

    /// 与 AssetHubView.reloadCardGrid 相同的布局参数。
    /// - `itemCount` 为**数据总量**（不是已渲染量）；内容高度按全量计算，
    ///   这样滚动条一次到位，不需要「加载更多」按钮或触底追加。
    public init(viewportWidth: CGFloat,
                viewportHeight: CGFloat = 0,
                itemCount: Int,
                footerHeight: CGFloat = 44) {
        let margin: CGFloat = 16
        let spacing: CGFloat = 14
        let availableW = max(viewportWidth, 320)
        let rawCols = Int((availableW - margin * 2 + spacing) / (210 + spacing))
        let cols = availableW < 440 ? 1 : max(1, min(4, rawCols))
        let totalSpacing = CGFloat(max(0, cols - 1)) * spacing
        let cardW = floor((availableW - margin * 2 - totalSpacing) / CGFloat(cols))
        let cardH: CGFloat = cols == 1 ? 250 : 236
        let rows = max(0, (itemCount + cols - 1) / cols)
        let cardsH = CGFloat(rows) * (cardH + spacing) + margin
        let totalH = max(viewportHeight, cardsH + footerHeight + margin)

        self.columns = cols
        self.cardWidth = cardW
        self.cardHeight = cardH
        self.spacing = spacing
        self.margin = margin
        self.viewportWidth = availableW
        self.viewportHeight = viewportHeight
        self.itemCount = max(0, itemCount)
        self.rows = rows
        self.contentHeight = totalH
        self.footerHeight = footerHeight
    }

    /// 单个卡片的 frame（flipped 坐标系，y 向下）。
    public func frame(for index: Int) -> S3Rect {
        let col = index % columns
        let row = index / columns
        let x = margin + CGFloat(col) * (cardWidth + spacing)
        let y = margin + CGFloat(row) * (cardHeight + spacing)
        return S3Rect(x: x, y: y, width: cardWidth, height: cardHeight)
    }

    public var rowStride: CGFloat { cardHeight + spacing }

    /// 可见行区间（含上下 bufferRows 行预取缓冲）。
    public func visibleRowRange(visibleRect: S3Rect, bufferRows: Int, itemCountOverride: Int? = nil) -> Range<Int> {
        let n = max(0, itemCountOverride ?? itemCount)
        guard n > 0 else { return 0..<0 }
        let totalRows = max(1, (n + columns - 1) / columns)
        let top = (visibleRect.minY - margin) / rowStride
        let bottom = (visibleRect.maxY - margin) / rowStride
        let first = max(0, Int(floor(top)) - max(0, bufferRows))
        let last = min(totalRows - 1, Int(floor(bottom)) + max(0, bufferRows))
        guard last >= first else { return 0..<0 }
        return first..<(last + 1)
    }

    /// 「可见 + 缓冲」的卡片 index 区间。视图实例数上限恒为
    /// `(可见行数 + 2*bufferRows) * columns`，**与数据总量无关**。
    public func visibleIndexRange(visibleRect: S3Rect, bufferRows: Int, itemCountOverride: Int? = nil) -> Range<Int> {
        let n = max(0, itemCountOverride ?? itemCount)
        let rr = visibleRowRange(visibleRect: visibleRect, bufferRows: bufferRows, itemCountOverride: n)
        guard rr.lowerBound < rr.upperBound, n > 0 else { return 0..<0 }
        let lo = min(n, rr.lowerBound * columns)
        let hi = min(n, rr.upperBound * columns)
        return lo..<max(lo, hi)
    }

    /// 理论视图数上限（用于验收报告中的「应有视图数」校验）。
    public func theoreticalViewCeiling(visibleRect: S3Rect, bufferRows: Int) -> Int {
        let r = visibleIndexRange(visibleRect: visibleRect, bufferRows: bufferRows)
        return r.count
    }
}
