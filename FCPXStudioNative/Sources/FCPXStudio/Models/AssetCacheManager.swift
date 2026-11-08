import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  AssetCacheManager —— FCPX 素材与模块多级内存缓存中心（R40 性能重构核心）
//  对标基准：/Applications/嘉星插件管理 2.app (FxXuAssetCacheCore)
//
//  核心职责：
//    1. 模板、LUT、音效、资源库多级数据毫秒级内存缓存；
//    2. 彻底杜绝每次切换 Tab / 分类时重复递归扫描磁盘 I/O；
//    3. 线程安全（并发读写保护）；
//    4. 精准缓存失效与增量局部更新机制（如启停、安装、体积懒加载回调）。
// ═══════════════════════════════════════════════════════════════

public final class AssetCacheManager {
    public static let shared = AssetCacheManager()

    private let lock = NSRecursiveLock()

    // 内存缓存字典
    private var templateCache: [String: TemplateScanResult] = [:]
    private var lutCache: [LUTItem]? = nil
    private var audioCache: [AudioItem]? = nil
    private var libraryCache: [LibraryBundleItem]? = nil
    private var doctorReportCache: DoctorReport? = nil

    // 缓存命中与耗时统计
    public private(set) var hitCount: Int = 0
    public private(set) var missCount: Int = 0
    public private(set) var lastFetchDurationMs: Double = 0.0

    public init() {}

    // MARK: – 模板缓存 (Templates)

    public func getTemplates(category: String) -> TemplateScanResult? {
        lock.lock()
        defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        if let result = templateCache[category] {
            hitCount += 1
            lastFetchDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return result
        }
        missCount += 1
        return nil
    }

    public func setTemplates(category: String, result: TemplateScanResult) {
        lock.lock()
        defer { lock.unlock() }
        templateCache[category] = result
    }

    public func updateTemplateSize(category: String, name: String, sizeMB: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = templateCache[category] else { return }
        var updatedItems = existing.items
        if let idx = updatedItems.firstIndex(where: { $0.name == name }) {
            var item = updatedItems[idx]
            item.sizeMB = sizeMB
            updatedItems[idx] = item
            templateCache[category] = TemplateScanResult(
                items: updatedItems,
                tierNotes: existing.tierNotes,
                roots: existing.roots
            )
        }
    }

    /// R49: 安全删除后即时同步更新内存缓存
    public func remove(itemPath: String) {
        removeTemplate(path: itemPath)
    }

    public func removeTemplate(path: String, category: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let cats = category != nil ? [category!] : Array(templateCache.keys)
        for cat in cats {
            guard let existing = templateCache[cat] else { continue }
            let filtered = existing.items.filter { $0.path != path && $0.targetPath != path }
            if filtered.count != existing.items.count {
                templateCache[cat] = TemplateScanResult(
                    items: filtered,
                    tierNotes: existing.tierNotes,
                    roots: existing.roots
                )
            }
        }
    }

    public func invalidateTemplates(category: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let cat = category {
            templateCache.removeValue(forKey: cat)
        } else {
            templateCache.removeAll()
        }
    }

    /// 统计指定卷上的素材数量（用于断链通知受影响计数）
    public func countTemplates(onVolume volumePath: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let normVol = (volumePath as NSString).standardizingPath
        guard !normVol.isEmpty else { return 0 }
        var count = 0
        for res in templateCache.values {
            for item in res.items {
                let p = (item.path as NSString).standardizingPath
                let tp = (item.targetPath as NSString).standardizingPath
                if p == normVol || p.hasPrefix(normVol + "/") || tp == normVol || tp.hasPrefix(normVol + "/") {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: – 3D LUT 缓存

    public func getLUTs() -> [LUTItem]? {
        lock.lock()
        defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        if let items = lutCache {
            hitCount += 1
            lastFetchDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return items
        }
        missCount += 1
        return nil
    }

    public func setLUTs(_ items: [LUTItem]) {
        lock.lock()
        defer { lock.unlock() }
        lutCache = items
    }

    public func invalidateLUTs() {
        lock.lock()
        defer { lock.unlock() }
        lutCache = nil
    }

    // MARK: – 音效缓存 (Audio)

    public func getAudios() -> [AudioItem]? {
        lock.lock()
        defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        if let items = audioCache {
            hitCount += 1
            lastFetchDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return items
        }
        missCount += 1
        return nil
    }

    public func setAudios(_ items: [AudioItem]) {
        lock.lock()
        defer { lock.unlock() }
        audioCache = items
    }

    public func invalidateAudios() {
        lock.lock()
        defer { lock.unlock() }
        audioCache = nil
    }

    // MARK: – 资源库瘦身缓存 (Libraries)

    public func getLibraries() -> [LibraryBundleItem]? {
        lock.lock()
        defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        if let items = libraryCache {
            hitCount += 1
            lastFetchDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return items
        }
        missCount += 1
        return nil
    }

    public func setLibraries(_ items: [LibraryBundleItem]) {
        lock.lock()
        defer { lock.unlock() }
        libraryCache = items
    }

    public func invalidateLibraries() {
        lock.lock()
        defer { lock.unlock() }
        libraryCache = nil
    }

    // MARK: – 幽灵插件体检医生缓存 (Ghost Doctor)

    public func getDoctorReport() -> DoctorReport? {
        lock.lock()
        defer { lock.unlock() }
        let start = CFAbsoluteTimeGetCurrent()
        if let report = doctorReportCache {
            hitCount += 1
            lastFetchDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return report
        }
        missCount += 1
        return nil
    }

    public func setDoctorReport(_ report: DoctorReport) {
        lock.lock()
        defer { lock.unlock() }
        doctorReportCache = report
    }

    public func invalidateDoctorReport() {
        lock.lock()
        defer { lock.unlock() }
        doctorReportCache = nil
    }

    // MARK: – 全局清空

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        templateCache.removeAll()
        lutCache = nil
        audioCache = nil
        libraryCache = nil
        doctorReportCache = nil
    }
}
