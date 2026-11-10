import Foundation
import Darwin

// ═══════════════════════════════════════════════════════════════
//  S3 / P1 独立 harness —— 公共模型层
//
//  自包含：只依赖 Foundation/Darwin + 同 module 的 Performance/*.swift。
//  **不 import AppKit，不引用 AssetHubView / ResourceCardView / TemplateItem**，
//  因此 S1 同时编辑现有 Sources 文件时本 harness 仍可 swiftc 直编。
//
//  公平性约定（两份实现严格共用）：
//   • 同一份 [:SyntheticItem]（从 /tmp/s3_verify/data/*.json 读，SHA256 记录在案）
//   • 同一段 [CGFloat] 滚动轨迹（同一 track.json）
//   • 同一个 SyntheticCard 类（同样的 15 个子视图分配成本）
//   • 同一个 S3ThumbnailWorkload.render(key:)（同样的生成/解码 CPU 成本）
//   • 同一个 vsync 帧节拍与同样的轮次
// ═══════════════════════════════════════════════════════════════

// MARK: - 数据文件

struct SyntheticItem: Decodable {
    let idx: Int
    let path: String
    let name: String
    let sizeMB: Double
    let tier: String
    let category: String
    let enabled: Bool
    let offline: Bool
    let corrupted: Bool
    let symlink: Bool
    let thumbSeed: Int
}

struct ScrollTrack: Decodable {
    let frames: Int
    let viewportWidth: Double
    let viewportHeight: Double
    let columns: Int
    let maxItemCount: Int
    let contentHeight: Double
    let maxOffset: Double
    let offsets: [Double]
}

struct S3HarnessData {
    let items: [SyntheticItem]
    let track: ScrollTrack
    let datasetPath: String
    let trackPath: String
    let manifest: String

    static func load(count: Int) throws -> S3HarnessData {
        let base = "/tmp/s3_verify/data"
        let dp = "\(base)/dataset_\(count).json"
        let tp = "\(base)/track.json"
        let dd = try Data(contentsOf: URL(fileURLWithPath: dp))
        let td = try Data(contentsOf: URL(fileURLWithPath: tp))
        let decoder = JSONDecoder()
        let items = try decoder.decode([SyntheticItem].self, from: dd)
        let track = try decoder.decode(ScrollTrack.self, from: td)
        precondition(items.count == count, "dataset count mismatch: \(items.count) != \(count)")
        let manifest = (try? String(contentsOfFile: "\(base)/MANIFEST.sha256", encoding: .utf8)) ?? "(missing)"
        return S3HarnessData(items: items, track: track, datasetPath: dp, trackPath: tp, manifest: manifest)
    }

    func visibleRect(at frame: Int) -> S3Rect {
        let y = track.offsets[min(frame, track.offsets.count - 1)]
        return S3Rect(x: 0, y: CGFloat(y),
                      width: CGFloat(track.viewportWidth), height: CGFloat(track.viewportHeight))
    }
}

// MARK: - 缩略图工作负载（两边共用的真实 CPU 成本）

enum S3ThumbnailWorkload {
    static let width = 120
    static let height = 68

    /// 由 key 派生确定性 seed（FNV-1a），保证两份实现对同一条目生成成本/内容一致。
    static func seed(for key: S3ThumbKey) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.path.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// 模拟「读盘 + 图像解码 + 缩放 + 色彩转换」：真实逐像素运算，非 sleep。
    /// 返回**已解码** RGBA 位图。L1 命中时该成本完全省掉。
    static func render(key: S3ThumbKey) -> S3DecodedBitmap {
        let w = width, h = height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var s = seed(for: key)
        var i = 0
        for y in 0..<h {
            let rowTint = UInt8(truncatingIfNeeded: y &* 3)
            for x in 0..<w {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let r = UInt8(truncatingIfNeeded: s >> 27)
                let g = UInt8(truncatingIfNeeded: (s >> 19) &+ UInt64(x &* 2))
                let b = UInt8(truncatingIfNeeded: (s >> 11) &+ UInt64(rowTint))
                px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
                i += 4
            }
        }
        // 第二遍：模拟色彩空间转换 / 预乘 alpha（解码阶段常见成本）
        var j = 0
        while j < px.count {
            let a = Int(px[j + 3])
            px[j] = UInt8((Int(px[j]) * a) >> 8)
            px[j + 1] = UInt8((Int(px[j + 1]) * a) >> 8)
            px[j + 2] = UInt8((Int(px[j + 2]) * a) >> 8)
            j += 4
        }
        return S3DecodedBitmap(width: w, height: h, pixels: px)
    }

    static var byteCost: Int { width * height * 4 }
}

// MARK: - 卡片视图（模拟 ResourceCardView 的创建/绑定成本）

final class SyntheticSubview {
    var tag: Int
    var text: String?
    var isHidden = false
    var alpha: Double = 1.0
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0
    init(tag: Int) { self.tag = tag }
}

/// 现状 ResourceCardView 有 ~15 个子视图（thumbnailContainer / imageView /
/// 8 个 label / 2 个 button / ...）。这里真实分配同样数量的对象，
/// 让「视图实例数」和「创建成本」不是空壳。
final class SyntheticCard: S3ReusableCard {
    static var liveCount = 0
    static var peakLiveCount = 0
    static var totalCreated = 0
    static func resetCounters() { liveCount = 0; peakLiveCount = 0; totalCreated = 0 }

    let subviews: [SyntheticSubview]
    var s3_boundIndex: Int?
    var s3_boundIdentifier: String?
    var s3_frame: S3Rect = S3Rect(x: 0, y: 0, width: 0, height: 0)

    var itemPath: String = ""
    var itemName: String = ""
    var isEnabled = true
    var isOffline = false
    var isCorrupted = false
    var isMismatchedDisk = false
    var sizeMB: Double = 0
    var thumbnailApplied = 0

    init() {
        subviews = (0..<15).map { SyntheticSubview(tag: $0) }
        SyntheticCard.liveCount += 1
        SyntheticCard.totalCreated += 1
        if SyntheticCard.liveCount > SyntheticCard.peakLiveCount {
            SyntheticCard.peakLiveCount = SyntheticCard.liveCount
        }
    }

    deinit { SyntheticCard.liveCount -= 1 }

    func s3_prepareForReuse() {
        s3_boundIndex = nil
        s3_boundIdentifier = nil
        itemPath = ""
        itemName = ""
        thumbnailApplied = 0
        for sv in subviews { sv.text = nil; sv.isHidden = false }
    }

    /// 模拟 updateContent()：写入 6 个字段并做若干属性赋值。
    func s3_bind(index: Int, identifier: String) {
        s3_boundIndex = index
        s3_boundIdentifier = identifier
        itemPath = identifier
        itemName = "item-\(index)"
        subviews[0].text = itemName
        subviews[1].text = identifier
        subviews[3].text = String(format: "%.1f MB", sizeMB)
        subviews[4].isHidden = !isEnabled
        subviews[5].alpha = isOffline ? 0.4 : 1.0
    }

    /// 模拟 NSImageView.image = img 的主线程赋值成本。
    func applyThumbnail(_ bitmap: S3DecodedBitmap) {
        thumbnailApplied += 1
        let first = bitmap.pixels[0]
        subviews[2].text = "thumb \(bitmap.width)x\(bitmap.height):\(first)"
        subviews[2].isHidden = false
    }
}

final class SyntheticCardHost: S3CardHost {
    var attachCount = 0
    var detachCount = 0
    func s3_makeCard() -> S3ReusableCard { SyntheticCard() }
    func s3_attach(_ card: S3ReusableCard) { attachCount += 1; _ = card }
    func s3_detach(_ card: S3ReusableCard) { detachCount += 1; _ = card }
}

final class SyntheticApplyTarget: S3ThumbnailApplying {
    weak var engine: S3ViewportReuseEngine?

    func s3_shouldApply(at index: Int, identifier: String) -> Bool {
        guard let c = engine?.card(for: index) as? SyntheticCard else { return false }
        return c.s3_boundIndex == index && c.s3_boundIdentifier == identifier
    }

    func s3_applyThumbnail(_ bitmap: S3DecodedBitmap, at index: Int, identifier: String) {
        guard let c = engine?.card(for: index) as? SyntheticCard else { return }
        c.applyThumbnail(bitmap)
    }
}

// MARK: - 现状单层 NSCache 等价物（无 costLimit / 无淘汰 / 无磁盘层）

final class LegacyMemoryCache {
    private var store: [S3ThumbKey: S3DecodedBitmap] = [:]
    private(set) var bytes = 0
    private(set) var peakBytes = 0
    private(set) var hits = 0
    private(set) var misses = 0

    func get(_ key: S3ThumbKey) -> S3DecodedBitmap? {
        if let v = store[key] { hits += 1; return v }
        misses += 1
        return nil
    }

    func put(_ bitmap: S3DecodedBitmap, for key: S3ThumbKey) {
        if store[key] != nil { store[key] = bitmap; return }
        store[key] = bitmap
        bytes += bitmap.byteCost
        if bytes > peakBytes { peakBytes = bytes }
    }

    var count: Int { store.count }
}

// MARK: - 统计容器

struct EngineFrameStats {
    var mainThreadOperations: Int = 0
    var backgroundWorksRun: Int = 0
    var thumbnailGenerations: Int = 0
    var cacheHits: Int = 0
    var mountedViews: Int = 0
    var liveViews: Int = 0
    var mainThreadApplies: Int = 0
    var reuses: Int = 0
    var createdViews: Int = 0
}

struct EngineSummary {
    var totalCreatedViews: Int = 0
    var peakLiveViews: Int = 0
    var peakMountedViews: Int = 0
    var finalLiveViews: Int = 0
    var totalLayoutOperations: Int = 0
    var totalThumbnailGenerations: Int = 0
    var totalCacheHits: Int = 0
    var l1Hits: Int = 0
    var l2Hits: Int = 0
    var deduped: Int = 0
    var cancelled: Int = 0
    var mainThreadApplies: Int = 0
    var deliveriesSkipped: Int = 0
    var l1Evictions: Int = 0
    var l2Evictions: Int = 0
    var peakL1Bytes: Int = 0
    var peakL2Bytes: Int = 0
    var legacyCachePeakBytes: Int = 0
    var peakInFlight: Int = 0
    var diskWrites: Int = 0
    var sizeCallbacks: Int = 0
    var mainCallbacks: Int = 0
    var estimatedPeakMemoryBytes: Int = 0
}

protocol GridEngineUnderTest: AnyObject {
    func scrollFrame(visibleRect: S3Rect, frameIndex: Int) -> EngineFrameStats
    func finalStats() -> EngineSummary
    var implementationName: String { get }
}

// MARK: - 数值工具

enum S3Number {
    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func stdev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return sqrt(v)
    }
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let rank = p * Double(s.count - 1)
        let lo = Int(floor(rank)), hi = Int(ceil(rank))
        guard lo >= 0, hi < s.count else { return s.last ?? 0 }
        if lo == hi { return s[lo] }
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }
    static func fmt(_ x: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", x)
    }
}
