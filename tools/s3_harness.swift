import Foundation
import Darwin

// ═══════════════════════════════════════════════════════════════
//  S3 / P1 独立 harness —— 主程序
//
//  编译（不碰整个源码树、不跑 SwiftPM）：
//    swiftc -O -swift-version 5 \
//      FCPXStudioNative/Sources/FCPXStudio/Performance/*.swift \
//      tools/s3_harness_models.swift tools/s3_harness.swift \
//      -o /tmp/s3_verify/s3_harness
//
//  运行：/tmp/s3_verify/s3_harness --rounds 5 --out reports/verify_s3
//
//  ⚠ 本 harness 是**独立合成负载**，不是真机 App 实测。
//    见 reports/verify_s3/ACCEPTANCE.md「适用边界与局限」。
// ═══════════════════════════════════════════════════════════════

// MARK: - 现状实现仿真（Legacy）

/// 忠实复刻 AssetHubView.reloadCardGrid + ResourceCardView.loadThumbnailAsync 的算法行为：
///  1. `renderedChunkCount` 初始 48，触底 +48（`loadNextCardChunk`），**只增不减**；
///  2. `cardViews` 全量常驻，永不回收；每次 reload 遍历 0..<cardViews.count 重排 frame
///     并比较 6 个 item 字段（真实代码 line 1536-1547）；
///  3. 新建卡片 = ResourceCardView.init -> setupUI()(15 子视图) -> updateContent()
///     -> loadThumbnailAsync() + calculateSizeAsync()（后者 main.asyncAfter 1.5s 回主线程
///     并再次 updateContent()，line 343-352）；
///  4. 缩略图单层 NSCache（无 costLimit / 无磁盘层 / 无淘汰）；
///  5. miss 时 DispatchQueue.global(qos:.utility).async **无并发上限、无 in-flight 去重**，
///     完成后 DispatchQueue.main.async 无节流回主线程。
///
/// 建模假设 A2（报告里显式标注）：为了在「同一段滚动轨迹」上覆盖同一份万级数据，
/// 把用户「反复滚到底触发 +48」压缩为每帧的追赶加载 while 循环。
/// 这是等效压缩，不是真机逐次触底的时序。
final class LegacyGridEngine: GridEngineUnderTest {

    let implementationName = "legacy(现状:分页+全量重排+单层NSCache)"

    private let items: [SyntheticItem]
    private let track: ScrollTrack
    private let host: SyntheticCardHost
    private let cache = LegacyMemoryCache()
    private static let defaultChunkSize = 48

    private var renderedChunkCount: Int
    private var cardViews: [SyntheticCard] = []
    private var layout: S3GridLayout
    private var needsInitialReload = true

    private var pendingGenerations: [(key: S3ThumbKey, index: Int)] = []
    private var mainDeliveries: [(key: S3ThumbKey, index: Int, bitmap: S3DecodedBitmap)] = []
    private var sizeCallbacks: [(dueFrame: Int, index: Int)] = []
    private var currentFrame = 0

    private var summary = EngineSummary()
    private var peakMounted = 0
    private var peakLive = 0

    init(items: [SyntheticItem], track: ScrollTrack, host: SyntheticCardHost) {
        self.items = items
        self.track = track
        self.host = host
        self.renderedChunkCount = min(Self.defaultChunkSize, items.count)
        self.layout = S3GridLayout(viewportWidth: CGFloat(track.viewportWidth),
                                   viewportHeight: CGFloat(track.viewportHeight),
                                   itemCount: renderedChunkCount)
    }

    private func key(for index: Int) -> S3ThumbKey {
        S3ThumbKey(path: items[index].path, pixelWidth: 240)
    }

    /// 复刻 loadThumbnailAsync：命中则主线程赋值；miss 则无上限投到全局队列。
    private func legacyRequestThumbnail(for index: Int) {
        guard index >= 0 && index < items.count else { return }
        let k = key(for: index)
        if let bmp = cache.get(k) {
            summary.totalCacheHits += 1
            mainDeliveries.append((key: k, index: index, bitmap: bmp))
            summary.mainCallbacks += 1
        } else {
            pendingGenerations.append((key: k, index: index))
        }
    }

    /// 复刻 reloadCardGrid(resetPaging: false)
    private func reloadCardGrid() {
        let countToRender = min(renderedChunkCount, items.count)
        layout = S3GridLayout(viewportWidth: CGFloat(track.viewportWidth),
                              viewportHeight: CGFloat(track.viewportHeight),
                              itemCount: countToRender)

        // 1) 超出所需才移除（正常路径不会触发 → 视图只增不减）
        if cardViews.count > countToRender {
            for c in cardViews[countToRender...] { host.s3_detach(c) }
            cardViews.removeSubrange(countToRender...)
        }

        // 2) O(已加载数) 全量重排 + 6 字段比较（现状 line 1536-1547）
        var ops = 0
        for i in 0..<cardViews.count {
            let item = items[i]
            let card = cardViews[i]
            card.s3_frame = layout.frame(for: i)
            if card.itemPath != item.path || card.itemName != item.name
                || card.isEnabled != item.enabled || card.isOffline != item.offline
                || card.isCorrupted != item.corrupted || card.isMismatchedDisk != false {
                card.itemPath = item.path
                card.itemName = item.name
                card.isEnabled = item.enabled
                card.isOffline = item.offline
                card.isCorrupted = item.corrupted
                card.s3_bind(index: i, identifier: item.path)
            }
            ops += 1
        }
        summary.totalLayoutOperations += ops

        // 3) 仅在不足时实例化新增卡片（ResourceCardView.init 的全部成本）
        if cardViews.count < countToRender {
            for index in cardViews.count..<countToRender {
                let item = items[index]
                guard let card = host.s3_makeCard() as? SyntheticCard else { continue }
                card.s3_frame = layout.frame(for: index)
                card.itemPath = item.path
                card.itemName = item.name
                card.sizeMB = item.sizeMB
                card.isEnabled = item.enabled
                card.isOffline = item.offline
                card.isCorrupted = item.corrupted
                card.s3_bind(index: index, identifier: item.path)
                host.s3_attach(card)
                cardViews.append(card)

                legacyRequestThumbnail(for: index)                    // init -> loadThumbnailAsync
                sizeCallbacks.append((dueFrame: currentFrame + 90, index: index)) // 1.5s @60Hz
            }
        }
        peakMounted = max(peakMounted, cardViews.count)
        peakLive = max(peakLive, SyntheticCard.liveCount)
    }

    func scrollFrame(visibleRect: S3Rect, frameIndex: Int) -> EngineFrameStats {
        currentFrame = frameIndex
        var st = EngineFrameStats()

        // ── 主线程：处理上一帧后台任务排入的 DispatchQueue.main.async 回调 ──
        for d in mainDeliveries {
            if d.index >= 0 && d.index < cardViews.count {
                let card = cardViews[d.index]
                if card.itemPath == d.key.path {          // 现状 guard targetPath 一致
                    card.applyThumbnail(d.bitmap)          // 真实主线程赋值成本
                    st.mainThreadApplies += 1
                }
            }
            st.mainThreadOperations += 1
        }
        mainDeliveries.removeAll(keepingCapacity: true)

        // ── 主线程：1.5s 延迟的 calculateSizeAsync 回调（会再次 updateContent）──
        if !sizeCallbacks.isEmpty {
            var remaining: [(dueFrame: Int, index: Int)] = []
            remaining.reserveCapacity(sizeCallbacks.count)
            for cb in sizeCallbacks {
                if cb.dueFrame <= frameIndex {
                    if cb.index < cardViews.count {
                        cardViews[cb.index].sizeMB = items[cb.index].sizeMB
                        legacyRequestThumbnail(for: cb.index)   // updateContent -> loadThumbnailAsync
                        summary.sizeCallbacks += 1
                        st.mainThreadOperations += 1
                    }
                } else {
                    remaining.append(cb)
                }
            }
            sizeCallbacks = remaining
        }

        // ── 首次 reloadCardGrid(resetPaging: true) ──
        if needsInitialReload {
            renderedChunkCount = min(Self.defaultChunkSize, items.count)
            reloadCardGrid()
            needsInitialReload = false
        }

        // ── onCardGridDidScroll：只在接近底部时 +48，不做视口回收（现状 line 1697-1704）──
        // A2：把同一段轨迹上「用户反复触底」压缩为追赶循环，保证覆盖同一份数据。
        var chunkLoads = 0
        while visibleRect.maxY >= layout.contentHeight - 160 && renderedChunkCount < items.count {
            renderedChunkCount = min(items.count, renderedChunkCount + Self.defaultChunkSize)
            reloadCardGrid()
            chunkLoads += 1
        }
        st.mainThreadOperations += chunkLoads

        // ── 后台全局队列：无并发上限，本帧把全部 miss 生成完 ──
        if !pendingGenerations.isEmpty {
            for job in pendingGenerations {
                let bmp = S3ThumbnailWorkload.render(key: job.key)
                cache.put(bmp, for: job.key)
                mainDeliveries.append((key: job.key, index: job.index, bitmap: bmp))
                st.backgroundWorksRun += 1
                st.thumbnailGenerations += 1
                summary.totalThumbnailGenerations += 1
                summary.mainCallbacks += 1
            }
            pendingGenerations.removeAll(keepingCapacity: true)
        }

        st.mountedViews = cardViews.count
        st.liveViews = SyntheticCard.liveCount
        st.createdViews = 0
        peakLive = max(peakLive, SyntheticCard.liveCount)
        return st
    }

    func finalStats() -> EngineSummary {
        summary.totalCreatedViews = SyntheticCard.totalCreated
        summary.peakLiveViews = max(peakLive, SyntheticCard.peakLiveCount)
        summary.peakMountedViews = peakMounted
        summary.finalLiveViews = cardViews.count
        summary.legacyCachePeakBytes = cache.peakBytes
        summary.peakL1Bytes = cache.peakBytes          // 单层内存缓存即 L1
        summary.mainThreadApplies = summary.mainCallbacks
        summary.estimatedPeakMemoryBytes = cache.peakBytes + peakMounted * S3HarnessConfig.cardBytesEstimate
        return summary
    }
}

// MARK: - 新实现（S3 组件）

final class S3GridEngine: GridEngineUnderTest {

    let implementationName = "s3(视口复用+L1/L2+并发上限+去重取消)"

    private let controller: S3GridPerformanceController
    private let host: SyntheticCardHost
    private var lastReport = S3FrameReport()

    init(items: [SyntheticItem], track: ScrollTrack, host: SyntheticCardHost) {
        self.host = host
        var cfg = S3ThumbnailCache.Config()
        cfg.mode = .manual                     // harness 单线程确定性驱动
        cfg.memoryCostLimit = 8 * 1024 * 1024
        cfg.diskByteLimit = 16 * 1024 * 1024
        cfg.maxConcurrentGenerations = 4
        cfg.diskDirectory = URL(fileURLWithPath: "/tmp/s3_verify/l2cache", isDirectory: true)

        let target = SyntheticApplyTarget()
        let c = S3GridPerformanceController(
            host: host,
            viewportWidth: CGFloat(track.viewportWidth),
            viewportHeight: CGFloat(track.viewportHeight),
            config: cfg,
            generator: { key in S3ThumbnailWorkload.render(key: key) },
            applyTarget: nil,
            bufferRows: 2)
        target.engine = c.engine
        c.applyTarget = target
        c.updateData(itemCount: items.count) { items[$0].path }
        self.controller = c
    }

    func scrollFrame(visibleRect: S3Rect, frameIndex: Int) -> EngineFrameStats {
        let r = controller.scrollDidChange(visibleRect: visibleRect)
        lastReport = r
        var st = EngineFrameStats()
        st.mainThreadOperations = r.layoutOperations + r.entered + r.exited
                                + r.mainThreadApplies + r.thumbnailRequests + r.thumbnailCancels
        st.backgroundWorksRun = r.backgroundWorksRun
        st.thumbnailGenerations = r.cache.generated
        st.cacheHits = r.cache.l1Hits + r.cache.l2Hits
        st.mountedViews = r.mountedViews
        st.liveViews = r.liveViews
        st.mainThreadApplies = r.mainThreadApplies
        st.reuses = r.reusedViews
        st.createdViews = r.createdViews
        return st
    }

    func finalStats() -> EngineSummary {
        let s = controller.cache.statistics()
        let e = controller.engine.stats
        var out = EngineSummary()
        out.totalCreatedViews = e.totalCreated
        out.peakLiveViews = e.peakLiveViews
        out.peakMountedViews = e.peakMountedViews
        out.finalLiveViews = controller.engine.liveViewCount
        out.totalLayoutOperations = e.totalLayoutOperations
        out.totalThumbnailGenerations = s.generated
        out.totalCacheHits = s.l1Hits + s.l2Hits
        out.l1Hits = s.l1Hits
        out.l2Hits = s.l2Hits
        out.deduped = s.deduped
        out.cancelled = s.cancelled
        out.mainThreadApplies = s.mainThreadApplies
        out.deliveriesSkipped = s.deliveriesSkipped
        out.l1Evictions = s.l1Evictions
        out.l2Evictions = s.l2Evictions
        out.peakL1Bytes = s.peakL1Bytes
        out.peakL2Bytes = s.peakL2Bytes
        out.peakInFlight = s.peakInFlight
        out.diskWrites = s.diskWrites
        out.estimatedPeakMemoryBytes = s.peakL1Bytes + e.peakLiveViews * S3HarnessConfig.cardBytesEstimate
        return out
    }
}

// MARK: - 配置 / vsync 采样

enum S3HarnessConfig {
    /// 一张 SyntheticCard（含 15 个子视图）的估算常驻字节。
    /// 这是**估算**，不是 Instruments 实测，报告里显式标注。
    static let cardBytesEstimate = 1200
    static let defaultPeriodMs = 1000.0 / 60.0
}

struct VsyncSample {
    var frameWorkMs: [Double] = []
    var droppedFrames = 0
    var deadlineMissFrames = 0
    var overBudgetFrames = 0
    var avgIntervalMs = 0.0
    var wallMs = 0.0
}

/// 用主线程 RunLoop + mach_absolute_time/mach_wait_until 合成 60Hz vsync 节拍
/// （任务允许的「等价的主线程 RunLoop 采样」）。每帧实测该帧全部工作的耗时，
/// 并按 deadline slip 统计掉帧。periodNs 可由 CVDisplayLink 探测到的真实刷新周期覆盖。
enum VsyncSampler {
    static func measure(frames: Int,
                        periodNs: Double,
                        work: (Int) -> EngineFrameStats) -> (VsyncSample, [EngineFrameStats]) {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let nsPerTick = Double(tb.numer) / Double(tb.denom)
        let periodTicks = UInt64((periodNs / nsPerTick).rounded())
        // frameStart = 本帧 vsync 起点；deadline = frameStart + period。
        // （注意：不能把「等待到的时刻」直接当下一帧的 deadline，否则每帧必误报 miss。）
        var frameStart = mach_absolute_time()
        let wallStart = frameStart

        var sample = VsyncSample()
        var perFrame: [EngineFrameStats] = []
        sample.frameWorkMs.reserveCapacity(frames)
        perFrame.reserveCapacity(frames)

        for f in 0..<frames {
            let deadline = frameStart + periodTicks
            let t0 = mach_absolute_time()
            let st = work(f)
            let t1 = mach_absolute_time()
            perFrame.append(st)

            let workNs = Double(t1 - t0) * nsPerTick
            sample.frameWorkMs.append(workNs / 1_000_000.0)
            if workNs > periodNs { sample.overBudgetFrames += 1 }

            if t1 > deadline {
                let slipNs = Double(t1 - deadline) * nsPerTick
                sample.deadlineMissFrames += 1
                sample.droppedFrames += Int(ceil(slipNs / periodNs))
                // 一次卡顿后重新对齐，避免同一卡顿在后续帧被连锁重复计数
                frameStart = t1
            } else {
                frameStart = deadline
            }
            let now = mach_absolute_time()
            if now < frameStart { _ = mach_wait_until(frameStart) }
        }

        let wallNs = Double(mach_absolute_time() - wallStart) * nsPerTick
        sample.wallMs = wallNs / 1_000_000.0
        sample.avgIntervalMs = sample.wallMs / Double(max(1, frames))
        return (sample, perFrame)
    }
}

// MARK: - 结果

struct RoundResult {
    let dataset: Int
    let impl: String
    let round: Int
    let frames: Int
    let periodMs: Double
    let droppedFrames: Int
    let deadlineMissFrames: Int
    let overBudgetFrames: Int
    let avgFrameMs: Double
    let p50FrameMs: Double
    let p95FrameMs: Double
    let maxFrameMs: Double
    let avgIntervalMs: Double
    let effectiveFps: Double
    let wallMs: Double
    let peakLiveViewsObserved: Int
    let summary: EngineSummary
    let dataSHA: String
    let trackSHA: String

    static let csvHeader = [
        "dataset", "impl", "round", "frames", "period_ms",
        "dropped_frames", "deadline_miss_frames", "over_budget_frames",
        "avg_frame_ms", "p50_frame_ms", "p95_frame_ms", "max_frame_ms",
        "avg_interval_ms", "effective_fps", "wall_ms",
        "peak_live_views", "peak_mounted_views", "final_live_views", "total_created_views",
        "total_layout_ops", "thumb_generations", "cache_hits", "l1_hits", "l2_hits",
        "deduped", "cancelled", "main_thread_applies", "deliveries_skipped",
        "l1_evictions", "l2_evictions", "peak_l1_bytes", "peak_l2_bytes",
        "legacy_cache_peak_bytes", "est_peak_memory_bytes", "disk_writes",
        "size_callbacks", "main_callbacks", "peak_in_flight",
        "data_sha256", "track_sha256"
    ].joined(separator: ",")

    var csvLine: String {
        let s = summary
        let vals: [String] = [
            "\(dataset)", impl, "\(round)", "\(frames)", S3Number.fmt(periodMs, 4),
            "\(droppedFrames)", "\(deadlineMissFrames)", "\(overBudgetFrames)",
            S3Number.fmt(avgFrameMs, 4), S3Number.fmt(p50FrameMs, 4),
            S3Number.fmt(p95FrameMs, 4), S3Number.fmt(maxFrameMs, 4),
            S3Number.fmt(avgIntervalMs, 4), S3Number.fmt(effectiveFps, 3), S3Number.fmt(wallMs, 2),
            "\(s.peakLiveViews)", "\(s.peakMountedViews)", "\(s.finalLiveViews)", "\(s.totalCreatedViews)",
            "\(s.totalLayoutOperations)", "\(s.totalThumbnailGenerations)", "\(s.totalCacheHits)",
            "\(s.l1Hits)", "\(s.l2Hits)", "\(s.deduped)", "\(s.cancelled)",
            "\(s.mainThreadApplies)", "\(s.deliveriesSkipped)", "\(s.l1Evictions)", "\(s.l2Evictions)",
            "\(s.peakL1Bytes)", "\(s.peakL2Bytes)", "\(s.legacyCachePeakBytes)",
            "\(s.estimatedPeakMemoryBytes)", "\(s.diskWrites)", "\(s.sizeCallbacks)",
            "\(s.mainCallbacks)", "\(s.peakInFlight)", dataSHA, trackSHA
        ]
        return vals.joined(separator: ",")
    }
}

func parseManifest(_ text: String) -> (data: [Int: String], track: String) {
    var data: [Int: String] = [:]
    var track = "unknown"
    for line in text.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        let sha = parts[0], name = parts[1]
        if name == "track.json" { track = sha }
        if name.hasPrefix("dataset_"), name.hasSuffix(".json") {
            let start = name.index(name.startIndex, offsetBy: 8)
            let end = name.index(name.endIndex, offsetBy: -5)
            if let n = Int(name[start..<end]) { data[n] = sha }
        }
    }
    return (data, track)
}

// MARK: - 参数

struct Args {
    var counts: [Int] = [1000, 10000]
    var rounds: Int = 5
    var periodMs: Double = S3HarnessConfig.defaultPeriodMs
    var outDir = "reports/verify_s3"
    var csvPath = "reports/verify_s3/results.csv"
    var summaryPath = "reports/verify_s3/results_summary.csv"
    var framesOverride: Int? = nil

    static func parse() -> Args {
        var a = Args()
        let argv = CommandLine.arguments
        var i = 1
        while i < argv.count {
            let k = argv[i]
            let v: String? = (i + 1 < argv.count) ? argv[i + 1] : nil
            switch k {
            case "--counts": if let v { a.counts = v.split(separator: ",").compactMap { Int($0) } }; i += 1
            case "--rounds": if let v, let n = Int(v) { a.rounds = n }; i += 1
            case "--period-ms": if let v, let d = Double(v) { a.periodMs = d }; i += 1
            case "--out": if let v { a.outDir = v; a.csvPath = "\(v)/results.csv"; a.summaryPath = "\(v)/results_summary.csv" }; i += 1
            case "--frames": if let v, let n = Int(v) { a.framesOverride = n }; i += 1
            default: break
            }
            i += 1
        }
        return a
    }
}

// MARK: - main

func run() {
    let args = Args.parse()
    let fm = FileManager.default
    try? fm.createDirectory(atPath: args.outDir, withIntermediateDirectories: true)
    let periodNs = args.periodMs * 1_000_000.0

    print("==============================================================")
    print("S3 / P1 虚拟滚动 + 多级缩略图缓存 —— 前后对比独立 harness")
    print("==============================================================")
    print("swiftc  : \(S3HarnessConfig.compilerVersion)")
    print("period  : \(S3Number.fmt(args.periodMs, 4)) ms (= \(S3Number.fmt(1000.0/args.periodMs, 2)) Hz vsync 等价节拍)")
    print("rounds  : \(args.rounds)  (每场景独立冷启动)")
    print("out     : \(args.outDir)")
    print("NOTE    : 独立合成负载，非真机 App 实测；见 ACCEPTANCE.md 边界说明")
    print("")

    var csvLines: [String] = [RoundResult.csvHeader]
    var summaryLines: [String] = []

    for count in args.counts {
        guard let data = try? S3HarnessData.load(count: count) else {
            print("FATAL: 无法加载 dataset_\(count).json"); continue
        }
        let parsed = parseManifest(data.manifest)
        let dataSHA = parsed.data[count] ?? "unknown"
        let trackSHA = parsed.track
        let frames = min(args.framesOverride ?? data.track.frames, data.track.offsets.count)

        print("──────────────────────────────────────────────────────────────")
        print("DATASET n=\(count)  items=\(data.items.count)  frames=\(frames)  cols=\(data.track.columns)")
        print("  file      : \(data.datasetPath)")
        print("  sha256    : \(dataSHA)")
        print("  track     : \(data.trackPath)  sha256=\(trackSHA)")
        print("  maxOffset : \(data.track.maxOffset) pt  contentH=\(data.track.contentHeight) pt")
        print("  viewport  : \(data.track.viewportWidth)x\(data.track.viewportHeight)")
        print("")

        var sceneResults: [String: [RoundResult]] = ["legacy": [], "s3": []]

        for impl in ["legacy", "s3"] {
            for round in 1...args.rounds {
                // 冷启动：清掉 L2 磁盘缓存，保证每轮从零开始
                let l2 = URL(fileURLWithPath: "/tmp/s3_verify/l2cache", isDirectory: true)
                if let files = try? fm.contentsOfDirectory(at: l2, includingPropertiesForKeys: nil) {
                    for f in files { try? fm.removeItem(at: f) }
                }

                var result: RoundResult?
                autoreleasepool {
                    SyntheticCard.resetCounters()
                    let host = SyntheticCardHost()
                    let engine: GridEngineUnderTest
                    if impl == "legacy" {
                        engine = LegacyGridEngine(items: data.items, track: data.track, host: host)
                    } else {
                        engine = S3GridEngine(items: data.items, track: data.track, host: host)
                    }
                    let (sample, perFrame) = VsyncSampler.measure(frames: frames, periodNs: periodNs) { f in
                        engine.scrollFrame(visibleRect: data.visibleRect(at: f), frameIndex: f)
                    }
                    let s = engine.finalStats()
                    let xs = sample.frameWorkMs
                    let avg = S3Number.mean(xs)
                    let p50 = S3Number.percentile(xs, 0.50)
                    let p95 = S3Number.percentile(xs, 0.95)
                    let mx = xs.max() ?? 0
                    let fps = (1000.0 / args.periodMs) * Double(frames) / Double(frames + sample.droppedFrames)
                    let observedPeak = perFrame.map { $0.liveViews }.max() ?? 0

                    result = RoundResult(
                        dataset: count, impl: impl, round: round, frames: frames,
                        periodMs: args.periodMs,
                        droppedFrames: sample.droppedFrames,
                        deadlineMissFrames: sample.deadlineMissFrames,
                        overBudgetFrames: sample.overBudgetFrames,
                        avgFrameMs: avg, p50FrameMs: p50, p95FrameMs: p95, maxFrameMs: mx,
                        avgIntervalMs: sample.avgIntervalMs,
                        effectiveFps: fps, wallMs: sample.wallMs,
                        peakLiveViewsObserved: max(observedPeak, s.peakLiveViews),
                        summary: s, dataSHA: dataSHA, trackSHA: trackSHA)

                    // 每帧原始耗时序列写 /tmp（不外置卷）
                    let fp = "/tmp/s3_verify/frames_\(count)_\(impl)_r\(round).csv"
                    var txt = "frame,visible_offset_pt,work_ms\n"
                    for (i, ms) in xs.enumerated() {
                        txt += "\(i),\(data.track.offsets[i]),\(S3Number.fmt(ms, 4))\n"
                    }
                    try? txt.write(toFile: fp, atomically: true, encoding: .utf8)
                }

                guard let r = result else { continue }
                sceneResults[impl]?.append(r)
                csvLines.append(r.csvLine)
                print("[\(impl)] round \(round)/\(args.rounds)  dropped=\(r.droppedFrames)  miss=\(r.deadlineMissFrames)  overBudget=\(r.overBudgetFrames)  avg=\(S3Number.fmt(r.avgFrameMs))ms  p95=\(S3Number.fmt(r.p95FrameMs))ms  max=\(S3Number.fmt(r.maxFrameMs))ms  effFPS=\(S3Number.fmt(r.effectiveFps,1))  peakViews=\(r.summary.peakLiveViews)  liveNow=\(r.summary.finalLiveViews)  wall=\(S3Number.fmt(r.wallMs,1))ms")
            }
        }

        // 场景汇总
        print("")
        print("  ── 场景汇总 n=\(count)，R=\(args.rounds)（均值 ± 样本标准差）──")
        var agg: [String: [String: Double]] = [:]
        for impl in ["legacy", "s3"] {
            guard let rs = sceneResults[impl], !rs.isEmpty else { continue }
            func aggOf(_ key: (RoundResult) -> Double) -> (Double, Double, Double, Double) {
                let xs = rs.map(key)
                return (S3Number.mean(xs), S3Number.stdev(xs), xs.min() ?? 0, xs.max() ?? 0)
            }
            let d = aggOf { Double($0.droppedFrames) }
            let a = aggOf { $0.avgFrameMs }
            let p = aggOf { $0.p95FrameMs }
            let v = aggOf { Double($0.summary.peakLiveViews) }
            let g = aggOf { Double($0.summary.totalThumbnailGenerations) }
            let l = aggOf { Double($0.summary.totalLayoutOperations) }
            let m = aggOf { Double($0.summary.estimatedPeakMemoryBytes) }
            agg[impl] = ["dropped": d.0, "dropped_sd": d.1,
                         "avg": a.0, "p95": p.0, "views": v.0,
                         "gen": g.0, "layout": l.0, "mem": m.0]
            print("  \(impl): dropped=\(S3Number.fmt(d.0,1))±\(S3Number.fmt(d.1,1)) [min \(S3Number.fmt(d.2,0)) max \(S3Number.fmt(d.3,0))]  avgFrame=\(S3Number.fmt(a.0))±\(S3Number.fmt(a.1))ms  p95=\(S3Number.fmt(p.0))ms  peakViews=\(S3Number.fmt(v.0,0))  gen=\(S3Number.fmt(g.0,0))  layoutOps=\(S3Number.fmt(l.0,0))  estMem=\(S3Number.fmt(m.0/1048576.0,2))MiB")
            summaryLines.append("\(count),\(impl),\(args.rounds),\(frames),\(S3Number.fmt(d.0,3)),\(S3Number.fmt(d.1,3)),\(S3Number.fmt(d.2,0)),\(S3Number.fmt(d.3,0)),\(S3Number.fmt(a.0,4)),\(S3Number.fmt(a.1,4)),\(S3Number.fmt(p.0,4)),\(S3Number.fmt(v.0,1)),\(S3Number.fmt(g.0,1)),\(S3Number.fmt(l.0,1)),\(S3Number.fmt(m.0,0)),\(dataSHA),\(trackSHA)")
        }
        if let a = agg["legacy"], let b = agg["s3"] {
            func ratio(_ x: Double, _ y: Double) -> String {
                y == 0 ? (x == 0 ? "1.00x" : "inf") : S3Number.fmt(x / y, 2) + "x"
            }
            print("  ── 前后对比 (legacy / s3) ──")
            print("     掉帧数        : \(S3Number.fmt(a["dropped"]!,1)) -> \(S3Number.fmt(b["dropped"]!,1))   (\(ratio(a["dropped"]!, b["dropped"]!)))")
            print("     平均帧时(ms)  : \(S3Number.fmt(a["avg"]!)) -> \(S3Number.fmt(b["avg"]!))   (\(ratio(a["avg"]!, b["avg"]!)))")
            print("     p95 帧时(ms)  : \(S3Number.fmt(a["p95"]!)) -> \(S3Number.fmt(b["p95"]!))   (\(ratio(a["p95"]!, b["p95"]!)))")
            print("     视图实例峰值  : \(S3Number.fmt(a["views"]!,0)) -> \(S3Number.fmt(b["views"]!,0))   (\(ratio(a["views"]!, b["views"]!)))")
            print("     布局操作总数  : \(S3Number.fmt(a["layout"]!,0)) -> \(S3Number.fmt(b["layout"]!,0))   (\(ratio(a["layout"]!, b["layout"]!)))")
            print("     缩略图生成数  : \(S3Number.fmt(a["gen"]!,0)) -> \(S3Number.fmt(b["gen"]!,0))   (\(ratio(a["gen"]!, b["gen"]!)))")
            print("     估算内存(MiB) : \(S3Number.fmt(a["mem"]!/1048576.0,2)) -> \(S3Number.fmt(b["mem"]!/1048576.0,2))   (\(ratio(a["mem"]!, b["mem"]!)))")
        }
        print("")
    }

    do {
        try csvLines.joined(separator: "\n").appending("\n")
            .write(toFile: args.csvPath, atomically: true, encoding: .utf8)
        let head = "dataset,impl,rounds,frames,dropped_mean,dropped_sd,dropped_min,dropped_max,avg_frame_ms_mean,avg_frame_ms_sd,p95_frame_ms,peak_live_views,thumb_generations,layout_ops,est_peak_memory_bytes,data_sha256,track_sha256\n"
        try (head + summaryLines.joined(separator: "\n") + "\n")
            .write(toFile: args.summaryPath, atomically: true, encoding: .utf8)
        print("WROTE \(args.csvPath)")
        print("WROTE \(args.summaryPath)")
    } catch {
        print("FATAL write results: \(error)")
    }
    print("DONE")
}

extension S3HarnessConfig {
    static let compilerVersion: String = {
        #if swift(>=6.0)
        return "Swift 6.x (swiftc -swift-version 5 语言模式)"
        #else
        return "Swift 5.x"
        #endif
    }()
}

@main
struct S3HarnessEntry {
    static func main() { run() }
}
