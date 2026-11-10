import Foundation

// ═══════════════════════════════════════════════════════════════
//  S3GridPerformanceController —— 一行接入门面（S3 / P1）
//
//  把「几何布局 + 视口复用 + 多级缩略图缓存」串成一次 scrollDidChange 调用。
//
//  ┌─ 集成阶段接线步骤（本轮 S3 **未接线**，以下仅为说明）─────────────┐
//  │ 1. AssetHubView 增加属性：                                          │
//  │      private var s3Performance: S3GridPerformanceController?       │
//  │ 2. setupUI() 中 cardGridScrollView 创建之后初始化一次：             │
//  │      var cfg = S3ThumbnailCache.Config()                            │
//  │      cfg.diskDirectory = <App Support>/S3ThumbCache                  │
//  │      cfg.mode = .asynchronous                                        │
//  │      s3Performance = S3GridPerformanceController(                    │
//  │          host: <S3CardHost 适配器>,                                  │
//  │          viewportWidth: cardGridScrollView.contentView.bounds.width, │
//  │          viewportHeight: cardGridScrollView.bounds.height,            │
//  │          config: cfg,                                                 │
//  │          generator: { key in <后台生成/解码 NSImage 的位图> },        │
//  │          applyTarget: <S3ThumbnailApplying 适配器>)                   │
//  │ 3. 数据变更后（reloadCardGrid / 筛选 / 排序）调用：                  │
//  │      s3Performance?.updateData(itemCount: plugins.count) {           │
//  │          plugins[$0].targetPath                                       │
//  │      }                                                                │
//  │      并把 cardGridContentView.frame.size.height 设为                  │
//  │      s3Performance!.layout.contentHeight（全量高度，无需「加载更多」）│
//  │ 4. **确切的一行接线**，加在 AssetHubView.swift 的                     │
//  │    `@objc private func onCardGridDidScroll(_ notification: Notification)`│
//  │    （当前文件 ~line 1697）函数体首行：                                │
//  │      s3Performance?.scrollDidChange(visibleRect: cardGridScrollView.contentView.documentVisibleRect) │
//  │    并移除/停用原 loadNextCardChunk 触底追加逻辑（视图数已由本组件托管）。│
//  └─────────────────────────────────────────────────────────────────────┘
//
//  注意：本轮性能数字来自 tools/s3_* 独立 harness，**非真机 App 实测**。
// ═══════════════════════════════════════════════════════════════

/// 缩略图应用目标：校验卡片是否仍绑定该 index，避免复用后错位贴图。
public protocol S3ThumbnailApplying: AnyObject {
    func s3_shouldApply(at index: Int, identifier: String) -> Bool
    func s3_applyThumbnail(_ bitmap: S3DecodedBitmap, at index: Int, identifier: String)
}

public struct S3FrameReport {
    public var visibleCards: Int = 0
    public var entered: Int = 0
    public var exited: Int = 0
    public var createdViews: Int = 0
    public var reusedViews: Int = 0
    public var recycledViews: Int = 0
    public var layoutOperations: Int = 0
    public var mountedViews: Int = 0
    public var liveViews: Int = 0
    public var poolSize: Int = 0
    public var thumbnailRequests: Int = 0
    public var thumbnailCancels: Int = 0
    public var mainThreadApplies: Int = 0
    public var deliveriesSkipped: Int = 0
    public var backgroundWorksRun: Int = 0
    public var cache: S3ThumbStats = S3ThumbStats()
}

public final class S3GridPerformanceController {

    public private(set) var layout: S3GridLayout
    public private(set) var engine: S3ViewportReuseEngine
    public private(set) var cache: S3ThumbnailCache
    public weak var applyTarget: S3ThumbnailApplying?

    private var itemCount: Int = 0
    private var identifiers: (Int) -> String = { _ in "" }
    private var tokens: [Int: S3ThumbToken] = [:]
    private var lastApplies: Int = 0
    private var lastSkips: Int = 0

    public init(host: S3CardHost,
                viewportWidth: CGFloat,
                viewportHeight: CGFloat,
                config: S3ThumbnailCache.Config,
                generator: @escaping S3ThumbnailCache.Generator,
                applyTarget: S3ThumbnailApplying? = nil,
                bufferRows: Int = 2) {
        self.layout = S3GridLayout(viewportWidth: viewportWidth,
                                   viewportHeight: viewportHeight,
                                   itemCount: 0)
        self.engine = S3ViewportReuseEngine(host: host, bufferRows: bufferRows)
        self.cache = S3ThumbnailCache(config: config, generator: generator)
        self.applyTarget = applyTarget
    }

    /// 数据总量 / 视口尺寸变化后调用。identifier 传模板的 targetPath（缩略图缓存键）。
    public func updateData(itemCount: Int,
                           identifier: @escaping (Int) -> String,
                           viewportWidth: CGFloat? = nil,
                           viewportHeight: CGFloat? = nil) {
        self.itemCount = max(0, itemCount)
        self.identifiers = identifier
        self.layout = S3GridLayout(viewportWidth: viewportWidth ?? layout.viewportWidth,
                                   viewportHeight: viewportHeight ?? layout.viewportHeight,
                                   itemCount: self.itemCount)
        self.tokens.removeAll()
        self.engine.invalidateAll()
        self.cache.cancelAll(exceptVisible: [])
        self.lastApplies = 0
        self.lastSkips = 0
    }

    public func thumbnailKey(for index: Int) -> S3ThumbKey {
        S3ThumbKey(path: identifiers(index), pixelWidth: 240)
    }

    /// 每次滚动（boundsDidChange）调用一次；返回本帧工作量报告。
    /// 生产模式（.asynchronous）后台任务在 OperationQueue 执行；
    /// harness 模式（.manual）本函数内按并发上限驱动后台任务，保证单线程确定性。
    @discardableResult
    public func scrollDidChange(visibleRect: S3Rect) -> S3FrameReport {
        var report = S3FrameReport()

        // 1) 视口复用：只调整 O(visible) 个视图
        let diff = engine.update(visibleRect: visibleRect,
                                 layout: layout,
                                 itemCount: itemCount,
                                 identifier: identifiers)
        report.entered = diff.entered.count
        report.exited = diff.exited.count
        report.createdViews = diff.created
        report.reusedViews = diff.reusedFromPool
        report.recycledViews = diff.exited.count
        report.layoutOperations = diff.layoutOperations
        report.visibleCards = layout.visibleIndexRange(visibleRect: visibleRect,
                                                       bufferRows: engine.bufferRows,
                                                       itemCountOverride: itemCount).count
        report.mountedViews = engine.mountedViewCount
        report.liveViews = engine.liveViewCount
        report.poolSize = engine.reusePool.count

        // 2) 取消离屏请求
        for idx in diff.exited {
            if let token = tokens.removeValue(forKey: idx) {
                cache.cancel(token)
                report.thumbnailCancels += 1
            }
        }

        // 3) 新进入视口的卡片请求缩略图（L1 命中立即投递；miss 合并到在途任务）
        for idx in diff.entered {
            let key = thumbnailKey(for: idx)
            tokens[idx] = cache.request(key, targetIndex: idx)
            report.thumbnailRequests += 1
        }

        // 4) 后台工作：并发上限硬约束
        report.backgroundWorksRun = cache.runPending(limit: cache.config.maxConcurrentGenerations)

        // 5) 主线程 drain：校验绑定后再应用，杜绝复用后错位贴图
        let pending = cache.drainDeliveries()
        for delivery in pending {
            for idx in delivery.targetIndices {
                let ident = (idx >= 0 && idx < itemCount) ? identifiers(idx) : ""
                guard let card = engine.card(for: idx),
                      card.s3_boundIndex == idx,
                      card.s3_boundIdentifier == ident,
                      tokens[idx]?.key == delivery.key else {
                    cache.noteSkip()
                    continue
                }
                if applyTarget?.s3_shouldApply(at: idx, identifier: ident) ?? true {
                    applyTarget?.s3_applyThumbnail(delivery.bitmap, at: idx, identifier: ident)
                }
                cache.noteApply()
                cache.noteAppliedDelivery()
                tokens.removeValue(forKey: idx)
            }
        }

        let s = cache.statistics()
        report.cache = s
        report.mainThreadApplies = s.mainThreadApplies - lastApplies
        report.deliveriesSkipped = s.deliveriesSkipped - lastSkips
        lastApplies = s.mainThreadApplies
        lastSkips = s.deliveriesSkipped
        return report
    }

    /// 冷启动复跑用（harness）。
    public func resetForColdStart() {
        tokens.removeAll()
        engine.invalidateAll()
        cache.resetForColdStart()
        lastApplies = 0
        lastSkips = 0
    }

    /// 内存告警时调用：清掉 L1 与回收池，保留 L2。
    public func didReceiveMemoryWarning() {
        cache.cancelAll(exceptVisible: [])
        tokens.removeAll()
    }
}
