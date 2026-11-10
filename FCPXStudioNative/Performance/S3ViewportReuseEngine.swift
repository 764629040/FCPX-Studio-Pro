import Foundation

// ═══════════════════════════════════════════════════════════════
//  S3ViewportReuseEngine —— 视口复用组件（S3 / P1）
//
//  现状问题（AssetHubView.reloadCardGrid）：
//    cardViews: [ResourceCardView] 只增不减；滚到底 +48；每次 reload 全量
//    遍历所有已加载卡片重排 frame → 视图数与主线程工作量随数据总量线性增长。
//
//  本组件：
//    • active: [index: card] 只保存「可见 + 缓冲行」的卡片；
//    • 离开视口的卡片 detach 进 reusePool（有上限，超出即释放）；
//    • 进入视口的卡片优先从 pool 取，prepareForReuse 后 bind 新数据；
//    • 每帧布局操作数 = O(visible)，与 totalItemCount 无关。
//
//  视图层通过 S3ReusableCard / S3CardHost 两个协议注入，组件本身不依赖
//  AppKit / NSView。接入层用一个 NSView 适配类遵守协议即可（见 INTEGRATION.md）。
// ═══════════════════════════════════════════════════════════════

/// 一张可被复用的卡片视图需遵守的最小契约。
public protocol S3ReusableCard: AnyObject {
    /// 当前绑定的数据 index；回收时置 nil。
    var s3_boundIndex: Int? { get set }
    /// 当前绑定的数据标识（用于缩略图回调时校验卡片是否已被复用）。
    var s3_boundIdentifier: String? { get set }
    var s3_frame: S3Rect { get set }
    /// 回收前清理内容 / 取消该卡片上的异步请求。
    func s3_prepareForReuse()
    /// 绑定新数据（接入点里把 TemplateItem 写进 ResourceCardView）。
    func s3_bind(index: Int, identifier: String)
}

/// 视图创建与挂载/卸载由宿主（AssetHubView 的 container）实现。
public protocol S3CardHost: AnyObject {
    func s3_makeCard() -> S3ReusableCard
    func s3_attach(_ card: S3ReusableCard)
    func s3_detach(_ card: S3ReusableCard)
}

public struct S3ReuseDiff {
    /// 本帧新进入视口（含缓冲）的 index —— 触发缩略图请求。
    public var entered: [Int] = []
    /// 本帧离开视口的 index —— 触发在途缩略图请求取消。
    public var exited: [Int] = []
    public var reusedFromPool: Int = 0
    public var created: Int = 0
    public var layoutOperations: Int = 0
}

public struct S3ReuseStats {
    public private(set) var totalCreated: Int = 0
    public private(set) var totalDiscarded: Int = 0
    public private(set) var totalRecycles: Int = 0
    public private(set) var totalReuses: Int = 0
    public private(set) var totalBinds: Int = 0
    public private(set) var totalLayoutOperations: Int = 0
    public private(set) var peakMountedViews: Int = 0
    public private(set) var peakLiveViews: Int = 0
    public private(set) var peakPoolSize: Int = 0

    mutating func bumpCreated(_ n: Int) { totalCreated += n }
    mutating func bumpDiscarded(_ n: Int) { totalDiscarded += n }
    mutating func bumpRecycles(_ n: Int) { totalRecycles += n }
    mutating func bumpReuses(_ n: Int) { totalReuses += n }
    mutating func bumpBinds(_ n: Int) { totalBinds += n }
    mutating func bumpLayout(_ n: Int) { totalLayoutOperations += n }
    mutating func observe(mounted: Int, live: Int, pool: Int) {
        peakMountedViews = max(peakMountedViews, mounted)
        peakLiveViews = max(peakLiveViews, live)
        peakPoolSize = max(peakPoolSize, pool)
    }
}

public final class S3ViewportReuseEngine {
    public weak var host: S3CardHost?
    public let maxPoolSize: Int
    public let bufferRows: Int

    /// 当前挂载（可见 + 缓冲）的卡片：index -> card
    public private(set) var active: [Int: S3ReusableCard] = [:]
    /// 回收池（未挂载但对象仍存活，等待复用）
    public private(set) var reusePool: [S3ReusableCard] = []
    public private(set) var stats = S3ReuseStats()

    public init(host: S3CardHost, maxPoolSize: Int = 64, bufferRows: Int = 2) {
        self.host = host
        self.maxPoolSize = max(1, maxPoolSize)
        self.bufferRows = max(0, bufferRows)
    }

    /// 已创建且未被丢弃的卡片对象总数（active + pool）。接入层不额外持有卡片时等于真实 live 视图数。
    public var liveViewCount: Int { stats.totalCreated - stats.totalDiscarded }
    public var mountedViewCount: Int { active.count }

    public func card(for index: Int) -> S3ReusableCard? { active[index] }

    /// 核心：把视图集合调整为「visibleRect 对应的可见 + 缓冲区间」。
    /// - identifier: 由 index 取数据标识（避免组件耦合 TemplateItem 模型）。
    /// - 返回值给出进入/离开的 index，供缩略图缓存做请求 / 取消。
    @discardableResult
    public func update(visibleRect: S3Rect,
                       layout: S3GridLayout,
                       itemCount: Int,
                       identifier: (Int) -> String) -> S3ReuseDiff {
        let wanted = layout.visibleIndexRange(visibleRect: visibleRect,
                                              bufferRows: bufferRows,
                                              itemCountOverride: itemCount)
        let wantedSet = Set(wanted)
        var diff = S3ReuseDiff()

        // 1) 回收离开视口的卡片：detach + prepareForReuse + 进池（有上限）
        for (idx, card) in active where !wantedSet.contains(idx) {
            card.s3_prepareForReuse()
            card.s3_boundIndex = nil
            card.s3_boundIdentifier = nil
            host?.s3_detach(card)
            active.removeValue(forKey: idx)
            diff.exited.append(idx)
            stats.bumpRecycles(1)
            if reusePool.count < maxPoolSize {
                reusePool.append(card)
            } else {
                stats.bumpDiscarded(1)   // 超出池上限，ARC 释放视图
            }
        }

        // 2) 补齐新进入视口的卡片：优先复用池，否则新建
        for idx in wanted where active[idx] == nil {
            let card: S3ReusableCard
            if let reused = reusePool.popLast() {
                card = reused
                diff.reusedFromPool += 1
                stats.bumpReuses(1)
            } else {
                guard let made = host?.s3_makeCard() else { continue }
                card = made
                diff.created += 1
                stats.bumpCreated(1)
            }
            let ident = identifier(idx)
            card.s3_prepareForReuse()
            card.s3_bind(index: idx, identifier: ident)
            card.s3_boundIndex = idx
            card.s3_boundIdentifier = ident
            card.s3_frame = layout.frame(for: idx)
            host?.s3_attach(card)
            active[idx] = card
            diff.entered.append(idx)
            stats.bumpBinds(1)
        }

        // 3) 本帧布局：只对 active（O(visible)）重排 frame，不触碰总量
        for (idx, card) in active {
            card.s3_frame = layout.frame(for: idx)
            diff.layoutOperations += 1
        }
        stats.bumpLayout(diff.layoutOperations)
        stats.observe(mounted: active.count, live: liveViewCount, pool: reusePool.count)
        return diff
    }

    /// 数据变更（筛选 / 排序 / 增删）时调用：清空绑定，下一帧重新绑定。
    public func invalidateAll() {
        for (_, card) in active {
            card.s3_prepareForReuse()
            card.s3_boundIndex = nil
            card.s3_boundIdentifier = nil
            host?.s3_detach(card)
            if reusePool.count < maxPoolSize { reusePool.append(card) }
            else { stats.bumpDiscarded(1) }
        }
        active.removeAll(keepingCapacity: true)
    }
}
