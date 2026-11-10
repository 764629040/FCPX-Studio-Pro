import Foundation

// ═══════════════════════════════════════════════════════════════
//  S3ThumbnailCache —— 缩略图多级异步缓存（S3 / P1）
//
//  现状问题（ResourceCardView.loadThumbnailAsync）：
//    static NSCache<NSString, NSImage> —— 单层内存、无 costLimit / 无磁盘层 /
//    无淘汰策略；每次 miss 都 DispatchQueue.global(qos:.utility).async，
//    **无并发上限、无 in-flight 去重**，一张图可能被重复解码多次；
//    结果用 DispatchQueue.main.async 无节流回主线程，滚动时回调拥塞。
//
//  本组件：
//    L1  内存 LRU        —— 按字节 costLimit 淘汰，存**已解码位图**，
//                           主线程拿到即可用，不在主线程做解码。
//    L2  磁盘 LRU        —— 按字节 diskByteLimit + mtime 淘汰，避免重复生成。
//    Gen 异步生成队列     —— maxConcurrentGenerations 硬上限；
//                           同一 key 的并发请求合并成一个任务（去重）；
//                           离屏请求可 cancel，取消后不回主线程。
//    投递 deliveries     —— 完成的位图进线程安全队列，由主线程 drain 后
//                           校验卡片是否仍绑定该 index 再应用。
//
//  executionMode = .manual 时后台工作不自动执行，由宿主每帧调用
//  runPending(limit:) 驱动（独立 harness 用，保证单线程确定性可复现）；
//  .asynchronous 为生产接入路径（OperationQueue 真实并发）。两条路径的
//  缓存 / 去重 / 取消 / 淘汰 / 统计逻辑完全相同。
// ═══════════════════════════════════════════════════════════════

public struct S3ThumbKey: Hashable {
    public let path: String
    public let pixelWidth: Int

    public init(path: String, pixelWidth: Int = 240) {
        self.path = path
        self.pixelWidth = pixelWidth
    }

    /// FNV-1a 64，跨进程稳定（不用 Hasher.hashValue，避免随机 seed 影响磁盘命中可复现性）。
    public var stableHex: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        h ^= UInt64(bitPattern: Int64(pixelWidth))
        h = h &* 0x100000001b3
        return String(format: "%016llx", h)
    }
}

/// 已解码 RGBA 位图。生产接入时转成 CGImage / NSImage 无需再解码。
public struct S3DecodedBitmap {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public var byteCost: Int { pixels.count }
}

public enum S3ThumbSource: String {
    case memoryL1 = "L1"
    case diskL2 = "L2"
    case generated = "GEN"
}

public struct S3ThumbToken {
    public let key: S3ThumbKey
    public let id: UInt64
}

public struct S3ThumbDelivery {
    public let key: S3ThumbKey
    public let bitmap: S3DecodedBitmap
    public let source: S3ThumbSource
    public let targetIndices: [Int]
}

public struct S3ThumbStats {
    public internal(set) var l1Hits: Int = 0
    public internal(set) var l2Hits: Int = 0
    public internal(set) var generated: Int = 0
    public internal(set) var diskReads: Int = 0
    public internal(set) var diskWrites: Int = 0
    public internal(set) var deduped: Int = 0
    public internal(set) var cancelled: Int = 0
    public internal(set) var l1Evictions: Int = 0
    public internal(set) var l2Evictions: Int = 0
    public internal(set) var deliveriesApplied: Int = 0
    public internal(set) var deliveriesSkipped: Int = 0
    public internal(set) var l1Bytes: Int = 0
    public internal(set) var l2Bytes: Int = 0
    public internal(set) var peakL1Bytes: Int = 0
    public internal(set) var peakL2Bytes: Int = 0
    public internal(set) var peakInFlight: Int = 0
    public internal(set) var mainThreadApplies: Int = 0

    mutating func observe(l1: Int, l2: Int, inFlight: Int) {
        l1Bytes = l1; l2Bytes = l2
        peakL1Bytes = max(peakL1Bytes, l1)
        peakL2Bytes = max(peakL2Bytes, l2)
        peakInFlight = max(peakInFlight, inFlight)
    }
}

public final class S3ThumbnailCache {

    public enum ExecutionMode {
        case asynchronous
        case manual
    }

    public struct Config {
        public var memoryCostLimit: Int = 8 * 1024 * 1024
        public var diskByteLimit: Int = 16 * 1024 * 1024
        public var maxConcurrentGenerations: Int = 4
        public var diskDirectory: URL = URL(fileURLWithPath: "/tmp/s3_verify/l2cache", isDirectory: true)
        public var mode: ExecutionMode = .asynchronous

        public init() {}
    }

    /// 从零生成 / 解码缩略图（最贵的路径），在后台执行。
    public typealias Generator = (S3ThumbKey) -> S3DecodedBitmap?

    private enum WorkKind { case generate, diskLoad }

    private struct Waiter {
        let id: UInt64
        let targetIndex: Int
    }

    private final class InFlight {
        let key: S3ThumbKey
        let kind: WorkKind
        var waiters: [Waiter] = []
        var cancelled = false
        var running = false
        init(key: S3ThumbKey, kind: WorkKind) { self.key = key; self.kind = kind }
    }

    private final class LRUNode {
        let key: S3ThumbKey
        let bitmap: S3DecodedBitmap
        let cost: Int
        var prev: LRUNode?
        var next: LRUNode?
        init(key: S3ThumbKey, bitmap: S3DecodedBitmap) {
            self.key = key; self.bitmap = bitmap; self.cost = bitmap.byteCost
        }
    }

    public let config: Config
    private let generator: Generator
    private let lock = NSLock()
    private let generationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "s3.thumbnail.generator"
        q.qualityOfService = .utility
        return q
    }()

    // L1
    private var l1: [S3ThumbKey: LRUNode] = [:]
    private var lruHead: LRUNode?     // MRU
    private var lruTail: LRUNode?     // LRU
    private var l1ByteCount = 0

    // in-flight / pending / deliveries
    private var inFlightByKey: [S3ThumbKey: InFlight] = [:]
    private var pending: [InFlight] = []
    private var deliveries: [S3ThumbDelivery] = []
    private var nextTokenID: UInt64 = 1
    private var currentRunning = 0
    private var l2ByteCount = 0
    private var stats = S3ThumbStats()

    private static let magic: [UInt8] = Array("S3THMB01".utf8)

    public init(config: Config, generator: @escaping Generator) {
        self.config = config
        self.generator = generator
        generationQueue.maxConcurrentOperationCount = max(1, config.maxConcurrentGenerations)
        try? FileManager.default.createDirectory(at: config.diskDirectory,
                                                  withIntermediateDirectories: true)
        l2ByteCount = Self.diskByteCount(at: config.diskDirectory)
    }

    // MARK: - Public API

    /// 主线程同步查 L1（命中即已解码位图，无需解码）。
    public func bitmap(forKey key: S3ThumbKey) -> S3DecodedBitmap? {
        lock.lock(); defer { lock.unlock() }
        guard let node = l1[key] else { return nil }
        touch(node)
        stats.l1Hits += 1
        return node.bitmap
    }

    /// 请求缩略图。返回值可用于 cancel。去重：同 key 的并发请求合并为一个后台任务。
    @discardableResult
    public func request(_ key: S3ThumbKey, targetIndex: Int) -> S3ThumbToken {
        lock.lock()
        let token = S3ThumbToken(key: key, id: nextTokenID)
        nextTokenID &+= 1

        // L1 命中：直接投递已解码位图（主线程只做一次赋值）
        if let node = l1[key] {
            touch(node)
            stats.l1Hits += 1
            deliveries.append(S3ThumbDelivery(key: key, bitmap: node.bitmap,
                                              source: .memoryL1, targetIndices: [targetIndex]))
            observeStatsLocked()
            lock.unlock()
            return token
        }

        // 在途任务命中：合并 waiter，不重复生成
        if let work = inFlightByKey[key] {
            work.waiters.append(Waiter(id: token.id, targetIndex: targetIndex))
            stats.deduped += 1
            observeStatsLocked()
            lock.unlock()
            return token
        }

        let kind: WorkKind = Self.diskFileExists(for: key, in: config.diskDirectory) ? .diskLoad : .generate
        let work = InFlight(key: key, kind: kind)
        work.waiters.append(Waiter(id: token.id, targetIndex: targetIndex))
        inFlightByKey[key] = work
        pending.append(work)
        observeStatsLocked()
        let shouldSubmit = config.mode == .asynchronous
        lock.unlock()

        if shouldSubmit { submitAsync(work) }
        return token
    }

    /// 取消单个请求。任务若已无 waiter 则标记取消，不产生主线程回调。
    public func cancel(_ token: S3ThumbToken) {
        lock.lock(); defer { lock.unlock() }
        guard let work = inFlightByKey[token.key] else { return }
        let before = work.waiters.count
        work.waiters.removeAll { $0.id == token.id }
        if work.waiters.count < before { stats.cancelled += 1 }
        if work.waiters.isEmpty { work.cancelled = true }
    }

    /// 批量取消离屏请求（滚动时每帧调用）。visibleKeys 之外的在途任务全部取消。
    public func cancelAll(exceptVisible visibleKeys: Set<S3ThumbKey>) {
        lock.lock(); defer { lock.unlock() }
        for (key, work) in inFlightByKey where !visibleKeys.contains(key) {
            if !work.waiters.isEmpty {
                stats.cancelled += work.waiters.count
                work.waiters.removeAll()
                work.cancelled = true
                stats.deliveriesSkipped += 1
            }
        }
    }

    /// 主线程每帧 drain 一次，把完成的位图应用到仍绑定该 index 的卡片。
    public func drainDeliveries() -> [S3ThumbDelivery] {
        lock.lock(); defer { lock.unlock() }
        let out = deliveries
        deliveries.removeAll(keepingCapacity: true)
        return out
    }

    /// manual 模式：每帧最多执行 limit 个后台工作（limit 通常 = maxConcurrentGenerations）。
    /// asynchronous 模式下为空操作（由 OperationQueue 驱动）。
    @discardableResult
    public func runPending(limit: Int) -> Int {
        guard config.mode == .manual else { return 0 }
        lock.lock()
        var works: [InFlight] = []
        let budget = max(0, limit)
        while works.count < budget, !pending.isEmpty {
            let w = pending.removeFirst()
            if w.running || w.cancelled { continue }
            w.running = true
            works.append(w)
        }
        currentRunning += works.count
        observeStatsLocked()
        lock.unlock()

        for w in works { execute(w) }

        lock.lock()
        currentRunning -= works.count
        lock.unlock()
        return works.count
    }

    public var pendingWorkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public func noteApply(count: Int = 1) {
        lock.lock(); stats.mainThreadApplies += count; lock.unlock()
    }
    public func noteSkip(count: Int = 1) {
        lock.lock(); stats.deliveriesSkipped += count; lock.unlock()
    }
    public func noteAppliedDelivery() {
        lock.lock(); stats.deliveriesApplied += 1; lock.unlock()
    }

    public func statistics() -> S3ThumbStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// 清空 L1/L2 与在途状态（harness 每轮冷启动用）。
    public func resetForColdStart() {
        lock.lock()
        l1.removeAll(); lruHead = nil; lruTail = nil; l1ByteCount = 0
        inFlightByKey.removeAll(); pending.removeAll(); deliveries.removeAll()
        currentRunning = 0
        stats = S3ThumbStats()
        lock.unlock()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: config.diskDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
        lock.lock(); l2ByteCount = 0; lock.unlock()
    }

    // MARK: - 后台执行

    private func submitAsync(_ work: InFlight) {
        generationQueue.addOperation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyRunning = work.running
            if !alreadyRunning { work.running = true }
            self.lock.unlock()
            if alreadyRunning { return }
            self.execute(work)
            self.lock.lock(); self.currentRunning = max(0, self.currentRunning - 1); self.lock.unlock()
        }
    }

    private func execute(_ work: InFlight) {
        lock.lock()
        let waiters = work.waiters
        let isCancelled = work.cancelled || waiters.isEmpty
        lock.unlock()
        if isCancelled { finish(work, bitmap: nil, source: .generated); return }

        var bitmap: S3DecodedBitmap?
        var source: S3ThumbSource = .generated

        switch work.kind {
        case .generate:
            bitmap = generator(work.key)                       // 真实 CPU：生成 / 解码
        case .diskLoad:
            bitmap = Self.readDisk(for: work.key, in: config.diskDirectory)
            if bitmap != nil {
                source = .diskL2
                lock.lock(); stats.diskReads += 1; stats.l2Hits += 1; lock.unlock()
            } else {
                // L2 损坏 / 被淘汰 → 回退重新生成
                bitmap = generator(work.key)
                source = .generated
            }
        }

        if let bmp = bitmap {
            if source == .generated {
                let writtenBytes = Self.writeDisk(bmp, for: work.key, in: config.diskDirectory)
                lock.lock()
                if let n = writtenBytes {
                    l2ByteCount += n
                    stats.diskWrites += 1
                    stats.generated += 1
                }
                lock.unlock()
            }
            insertL1(bmp, for: work.key)
            lock.lock()
            let needsTrim = l2ByteCount > config.diskByteLimit
            lock.unlock()
            if needsTrim { trimDiskIfNeeded() }
        } else {
            lock.lock(); stats.generated += 1; lock.unlock()
        }
        finish(work, bitmap: bitmap, source: source)
    }

    private func finish(_ work: InFlight, bitmap: S3DecodedBitmap?, source: S3ThumbSource) {
        lock.lock(); defer { lock.unlock() }
        let surviving: [Waiter] = work.cancelled ? [] : work.waiters
        if let bmp = bitmap, !work.cancelled, !surviving.isEmpty {
            deliveries.append(S3ThumbDelivery(key: work.key, bitmap: bmp,
                                              source: source,
                                              targetIndices: surviving.map { $0.targetIndex }))
        } else if !surviving.isEmpty || work.cancelled {
            stats.deliveriesSkipped += 1
        }
        inFlightByKey.removeValue(forKey: work.key)
        pending.removeAll { $0 === work }
        observeStatsLocked()
    }

    // MARK: - L1 LRU

    private func touch(_ node: LRUNode) {
        if lruHead === node { return }
        detach(node)
        node.prev = nil
        node.next = lruHead
        lruHead?.prev = node
        lruHead = node
        if lruTail == nil { lruTail = node }
    }

    private func detach(_ node: LRUNode) {
        if node.prev === node { return }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if lruHead === node { lruHead = node.next }
        if lruTail === node { lruTail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func insertL1(_ bitmap: S3DecodedBitmap, for key: S3ThumbKey) {
        lock.lock(); defer { lock.unlock() }
        if let old = l1[key] {
            l1ByteCount -= old.cost
            detach(old)
        }
        let node = LRUNode(key: key, bitmap: bitmap)
        l1[key] = node
        l1ByteCount += node.cost
        touch(node)
        // 按字节上限淘汰最久未用
        while l1ByteCount > config.memoryCostLimit, let victim = lruTail {
            l1ByteCount -= victim.cost
            l1.removeValue(forKey: victim.key)
            detach(victim)
            stats.l1Evictions += 1
        }
        observeStatsLocked()
    }

    // MARK: - L2 磁盘 LRU

    private func diskURL(for key: S3ThumbKey) -> URL {
        config.diskDirectory.appendingPathComponent("t_\(key.stableHex).s3thumb")
    }

    private static func diskFileExists(for key: S3ThumbKey, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("t_\(key.stableHex).s3thumb").path)
    }

    /// 返回写入字节数；失败返回 nil。增量维护 l2ByteCount，避免每次生成都遍历目录。
    private static func writeDisk(_ bitmap: S3DecodedBitmap, for key: S3ThumbKey, in dir: URL) -> Int? {
        var data = Data(capacity: 8 + 8 + bitmap.pixels.count)
        data.append(contentsOf: magic)
        var w = Int32(bitmap.width).littleEndian
        var h = Int32(bitmap.height).littleEndian
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        data.append(contentsOf: bitmap.pixels)
        let url = dir.appendingPathComponent("t_\(key.stableHex).s3thumb")
        do { try data.write(to: url, options: .atomic); return data.count } catch { return nil }
    }

    private static func readDisk(for key: S3ThumbKey, in dir: URL) -> S3DecodedBitmap? {
        let url = dir.appendingPathComponent("t_\(key.stableHex).s3thumb")
        guard let data = try? Data(contentsOf: url), data.count >= 16 else { return nil }
        guard Array(data.prefix(8)) == magic else { return nil }
        let w = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self).littleEndian }
        let h = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self).littleEndian }
        guard w > 0, h > 0, Int(w) * Int(h) * 4 == data.count - 16 else { return nil }
        var pixels = [UInt8](repeating: 0, count: data.count - 16)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(&pixels, base.advanced(by: 16), data.count - 16)
            }
        }
        return S3DecodedBitmap(width: Int(w), height: Int(h), pixels: pixels)
    }

    private func trimDiskIfNeeded() {
        // 只在超限时扫描目录（正常路径靠 l2ByteCount 增量维护，不产生遍历开销）
        let current = Self.diskByteCount(at: config.diskDirectory)
        guard current > config.diskByteLimit else {
            lock.lock(); l2ByteCount = current; lock.unlock()
            return
        }
        let bytesBefore = current
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: config.diskDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        var bytes = bytesBefore
        let target = Int(Double(config.diskByteLimit) * 0.8)
        var evicted = 0
        for f in sorted where bytes > target {
            let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: f)) != nil { bytes -= sz; evicted += 1 }
        }
        lock.lock(); l2ByteCount = bytes; stats.l2Evictions += evicted; observeStatsLocked(); lock.unlock()
    }

    private static func diskByteCount(at dir: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func observeStatsLocked() {
        stats.observe(l1: l1ByteCount, l2: l2ByteCount, inFlight: inFlightByKey.count)
    }
}
