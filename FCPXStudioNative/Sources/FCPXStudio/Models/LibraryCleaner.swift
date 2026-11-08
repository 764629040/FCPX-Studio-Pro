import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  LibraryCleaner.swift —— FCPX 资源库深度安全瘦身与缓存清理医生
//  对标基准：/Applications/嘉星插件管理 2.app (FxXuCleanerCore / LibraryCleanerItems)
//
//  核心职责：
//    1. 自动探测与穿透扫描用户本机及外置盘所有 .fcpbundle 资源库；
//    2. 深度穿透资源库包结构，精确分类统计非破坏性缓存体积；
//    3. 严格安全红线：原始媒体 (Original Media) 与数据库绝对受保护；
//    4. 100% 安全移入 macOS 废纸篓 (trashItem)，严禁 rm -rf 硬抹除；
//    5. 一键安全瘦身 (Safe Clean All) 与单项定制瘦身，生成实时容量释放报表。
// ═══════════════════════════════════════════════════════════════

/// 缓存类型枚举（对标嘉星 LibraryCleaner 分类体系）
public enum LibraryCacheCategory: String, CaseIterable, Codable {
    case renderFiles     // 高画质渲染缓存与音频波形 (Render Files / High Quality Media / Peaks Data)
    case proxyMedia      // 剪辑代理媒体文件 (Transcoded Media / Proxy Media)
    case thumbnailMedia  // 缩略图与胶卷缓存 (Render Files / Thumbnail Media)
    case sharedItems     // 历史导出分享渲染残留 (Shared Items)
    case analysisFiles   // 光流与防抖分析追踪缓存 (Analysis Files: Optical Flow / Stabilization)
    case tempFiles       // 临时缓存与异步拷贝残留 (__Temp / __AsyncCopying)

    public var displayName: String {
        switch self {
        case .renderFiles:    return "高画质渲染与波形缓存"
        case .proxyMedia:     return "剪辑代理媒体 (Proxy)"
        case .thumbnailMedia: return "片段缩略图缓存 (Thumbnails)"
        case .sharedItems:    return "历史导出分享残留 (Shared)"
        case .analysisFiles:  return "光流与画面防抖分析缓存"
        case .tempFiles:      return "临时与异步拷贝缓存 (Temp)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .renderFiles:    return "🟠 渲染缓存"
        case .proxyMedia:     return "🔵 代理素材"
        case .thumbnailMedia: return "🟡 缩略图"
        case .sharedItems:    return "🟣 分享残留"
        case .analysisFiles:  return "⚪ 分析数据"
        case .tempFiles:      return "🔘 临时文件"
        }
    }

    public var safetyNote: String {
        switch self {
        case .renderFiles:    return "非破坏性。FCPX 在播放或导出时可随时按需重新渲染。"
        case .proxyMedia:     return "非破坏性。仅为代理文件，原始拍摄素材安然无恙。"
        case .thumbnailMedia: return "非破坏性。FCPX 在浏览器滚动时会自动重新生成。"
        case .sharedItems:    return "非破坏性。历史导出遗留的临时合成块，可安全清理。"
        case .analysisFiles:  return "非破坏性。再次开启防抖或光流时将重新分析生成。"
        case .tempFiles:      return "非破坏性。剪辑会话已结束的孤立临时数据。"
        }
    }
}

/// 单项缓存分类的详细统计
public struct LibraryCacheDetail: Codable, Equatable {
    public let category: LibraryCacheCategory
    public var byteSize: Int64
    public var fileCount: Int
    public var paths: [String]
    public var isSelected: Bool

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    public init(category: LibraryCacheCategory,
                byteSize: Int64 = 0,
                fileCount: Int = 0,
                paths: [String] = [],
                isSelected: Bool = true) {
        self.category = category
        self.byteSize = byteSize
        self.fileCount = fileCount
        self.paths = paths
        self.isSelected = isSelected
    }
}

/// 资源库条目模型（对标嘉星 `FxXuLibraryItem`）
public struct LibraryBundleItem: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let url: URL
    public let volumeName: String
    public let volumeUUID: String

    /// 资源库总物理占用体积
    public var totalSizeBytes: Int64
    /// 原始素材占用体积（最高安全红线：严禁触碰！）
    public var originalMediaSizeBytes: Int64
    /// 各分类缓存统计详情
    public var cacheDetails: [LibraryCacheDetail]
    /// 包含的事件数量
    public var eventsCount: Int
    /// 包含的项目/时间线数量
    public var projectsCount: Int
    /// 最近扫描时间
    public var lastScannedAt: Date

    /// 可清理缓存总字节数
    public var cleanableSizeBytes: Int64 {
        cacheDetails.reduce(0) { $0 + $1.byteSize }
    }

    /// 当前选中的待清理缓存字节数
    public var selectedCleanableSizeBytes: Int64 {
        cacheDetails.filter { $0.isSelected }.reduce(0) { $0 + $1.byteSize }
    }

    public var totalSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    public var originalMediaFormatted: String {
        ByteCountFormatter.string(fromByteCount: originalMediaSizeBytes, countStyle: .file)
    }

    public var cleanableSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: cleanableSizeBytes, countStyle: .file)
    }

    public var selectedCleanableFormatted: String {
        ByteCountFormatter.string(fromByteCount: selectedCleanableSizeBytes, countStyle: .file)
    }

    /// 瘦身率（缓存占总工程的百分比）
    public var slimmingRatioText: String {
        guard totalSizeBytes > 0 else { return "0%" }
        let ratio = Double(cleanableSizeBytes) / Double(totalSizeBytes) * 100.0
        return String(format: "%.1f%%", min(ratio, 100.0))
    }

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                volumeName: String = "",
                volumeUUID: String = "",
                totalSizeBytes: Int64 = 0,
                originalMediaSizeBytes: Int64 = 0,
                cacheDetails: [LibraryCacheDetail] = [],
                eventsCount: Int = 0,
                projectsCount: Int = 0,
                lastScannedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.url = URL(fileURLWithPath: path)
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.totalSizeBytes = totalSizeBytes
        self.originalMediaSizeBytes = originalMediaSizeBytes
        self.cacheDetails = cacheDetails
        self.eventsCount = eventsCount
        self.projectsCount = projectsCount
        self.lastScannedAt = lastScannedAt
    }
}

/// 清理执行结果报告
public struct LibraryCleanResult {
    public let libraryName: String
    public let libraryPath: String
    public let bytesFreed: Int64
    public let itemsTrashedCount: Int
    public let trashedURLs: [URL]
    public let cleanedCategories: [LibraryCacheCategory]
    public let timestamp: Date
    public let isSuccess: Bool
    public let errorMessages: [String]

    public var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }

    public var summaryMessage: String {
        if isSuccess {
            return "成功安全瘦身 \(formattedBytesFreed)，已移入 macOS 废纸篓 \(itemsTrashedCount) 项，资产 100% 可随时找回。"
        } else {
            return "瘦身完成但有部分警示：释放 \(formattedBytesFreed)，错误：\(errorMessages.joined(separator: "; "))"
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  LibraryCleaner 核心引擎
// ═══════════════════════════════════════════════════════════════

public final class LibraryCleaner {
    public static let shared = LibraryCleaner()

    public private(set) var defaultSearchRoots: [String] = [
        ("~/Movies/Final Cut Backups.localized" as NSString).expandingTildeInPath,
        ("~/Movies" as NSString).expandingTildeInPath,
        "/Volumes"
    ]

    private let fileManager = FileManager.default

    public init() {}

    // MARK: – 资源库探测与扫描

    /// 智能扫描默认路径或用户自定义目录下的所有真实 .fcpbundle 资源库
    public func scanLibraries(searchRoots: [String]? = nil, maxDepth: Int = 4) -> [LibraryBundleItem] {
        var results: [LibraryBundleItem] = []
        var visitedPaths = Set<String>()

        let roots = searchRoots ?? defaultSearchRoots

        for root in roots {
            let expandedRoot = (root as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expandedRoot) else { continue }

            let discovered = discoverFcpBundles(in: expandedRoot, maxDepth: maxDepth, visited: &visitedPaths)
            for bundleURL in discovered {
                if let item = analyzeBundle(at: bundleURL) {
                    results.append(item)
                }
            }
        }

        // 按体积降序排列，方便剪辑师优先瘦身最大工程
        return results.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
    }

    /// 异步智能扫描 .fcpbundle 资源库，切入后台 GCD 线程，自动命中/填充 AssetCacheManager
    public func scanLibrariesAsync(
        searchRoots: [String]? = nil,
        maxDepth: Int = 4,
        completion: @escaping ([LibraryBundleItem]) -> Void
    ) {
        if let cached = AssetCacheManager.shared.getLibraries() {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.scanLibraries(searchRoots: searchRoots, maxDepth: maxDepth)
            AssetCacheManager.shared.setLibraries(items)
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }

    /// 深度递归发现 .fcpbundle 包（避免遍历进 .fcpbundle 内部）
    private func discoverFcpBundles(in directory: String, maxDepth: Int, visited: inout Set<String>) -> [URL] {
        var bundles: [URL] = []
        guard maxDepth >= 0 else { return bundles }

        let dirURL = URL(fileURLWithPath: directory)
        let resolvedPath = (try? dirURL.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? directory

        guard !visited.contains(resolvedPath) else { return bundles }
        visited.insert(resolvedPath)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: nil
        ) else { return bundles }

        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.hasSuffix(".fcpbundle") {
                bundles.append(fileURL)
                enumerator.skipDescendants()
            }
        }

        return bundles
    }

    /// 分析单个 .fcpbundle 资源库，穿透事件、渲染文件、代理媒体与原始素材
    public func analyzeBundle(at bundleURL: URL) -> LibraryBundleItem? {
        let path = bundleURL.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard path.hasSuffix(".fcpbundle") || isFCPXBundle(at: bundleURL) else { return nil }

        let name = bundleURL.lastPathComponent

        // 获取卷信息
        var volumeName = "Macintosh HD"
        var volumeUUID = ""
        if let res = try? bundleURL.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey]) {
            volumeName = res.volumeName ?? "Macintosh HD"
            volumeUUID = res.volumeUUIDString ?? ""
        }

        var totalSize: Int64 = 0
        var originalMediaSize: Int64 = 0
        var eventsCount = 0
        var projectsCount = 0

        var renderPaths: [String] = []
        var renderSize: Int64 = 0
        var renderFilesCount = 0

        var proxyPaths: [String] = []
        var proxySize: Int64 = 0
        var proxyFilesCount = 0

        var thumbPaths: [String] = []
        var thumbSize: Int64 = 0
        var thumbFilesCount = 0

        var sharedPaths: [String] = []
        var sharedSize: Int64 = 0
        var sharedFilesCount = 0

        var analysisPaths: [String] = []
        var analysisSize: Int64 = 0
        var analysisFilesCount = 0

        var tempPaths: [String] = []
        var tempSize: Int64 = 0
        var tempFilesCount = 0

        // 穿透资源库包第一层（事件、临时目录、元数据）
        guard let topContents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return nil
        }

        for entry in topContents {
            let entryPath = (path as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDir) else { continue }

            if entry == "__Temp" || entry == "__AsyncCopying" {
                let stat = calculateDirectorySize(at: entryPath)
                tempSize += stat.size
                tempFilesCount += stat.count
                tempPaths.append(entryPath)
                totalSize += stat.size
                continue
            }

            // 根级别 Shared Items
            if entry == "Shared Items" {
                let stat = calculateDirectorySize(at: entryPath)
                sharedSize += stat.size
                sharedFilesCount += stat.count
                sharedPaths.append(entryPath)
                totalSize += stat.size
                continue
            }

            guard isDir.boolValue else {
                // 顶级文件（CurrentVersion.flexolibrary / Settings.plist 等元数据）
                let attr = (try? fileManager.attributesOfItem(atPath: entryPath)) ?? [:]
                let sz = (attr[.size] as? Int64) ?? 0
                totalSize += sz
                continue
            }

            // 检查是否为事件目录（包含 CurrentVersion.fcpevent）
            let fcpeventPath = (entryPath as NSString).appendingPathComponent("CurrentVersion.fcpevent")
            if fileManager.fileExists(atPath: fcpeventPath) {
                eventsCount += 1
            }

            // 扫描事件目录内部
            if let eventContents = try? fileManager.contentsOfDirectory(atPath: entryPath) {
                for item in eventContents {
                    let itemPath = (entryPath as NSString).appendingPathComponent(item)
                    var subIsDir: ObjCBool = false
                    guard fileManager.fileExists(atPath: itemPath, isDirectory: &subIsDir) else { continue }

                    if !subIsDir.boolValue {
                        let attr = (try? fileManager.attributesOfItem(atPath: itemPath)) ?? [:]
                        totalSize += (attr[.size] as? Int64) ?? 0
                        continue
                    }

                    // 1. Original Media —— 绝对红线！只计入体积，严禁加入清理路径！
                    if item == "Original Media" {
                        let stat = calculateDirectorySize(at: itemPath)
                        originalMediaSize += stat.size
                        totalSize += stat.size
                        continue
                    }

                    // 2. Transcoded Media —— 穿透 Proxy Media 与 High Quality Media
                    if item == "Transcoded Media" {
                        let proxyDir = (itemPath as NSString).appendingPathComponent("Proxy Media")
                        if fileManager.fileExists(atPath: proxyDir) {
                            let stat = calculateDirectorySize(at: proxyDir)
                            proxySize += stat.size
                            proxyFilesCount += stat.count
                            proxyPaths.append(proxyDir)
                        }

                        let hqDir = (itemPath as NSString).appendingPathComponent("High Quality Media")
                        if fileManager.fileExists(atPath: hqDir) {
                            let stat = calculateDirectorySize(at: hqDir)
                            // 优化媒体也归类至渲染/代理可瘦身缓存
                            proxySize += stat.size
                            proxyFilesCount += stat.count
                            proxyPaths.append(hqDir)
                        }

                        let allTrans = calculateDirectorySize(at: itemPath)
                        totalSize += allTrans.size
                        continue
                    }

                    // 3. Render Files —— 穿透 High Quality Media, Peaks Data, Thumbnail Media
                    if item == "Render Files" {
                        let hqRender = (itemPath as NSString).appendingPathComponent("High Quality Media")
                        if fileManager.fileExists(atPath: hqRender) {
                            let stat = calculateDirectorySize(at: hqRender)
                            renderSize += stat.size
                            renderFilesCount += stat.count
                            renderPaths.append(hqRender)
                        }

                        let peaks = (itemPath as NSString).appendingPathComponent("Peaks Data")
                        if fileManager.fileExists(atPath: peaks) {
                            let stat = calculateDirectorySize(at: peaks)
                            renderSize += stat.size
                            renderFilesCount += stat.count
                            renderPaths.append(peaks)
                        }

                        let thumbs = (itemPath as NSString).appendingPathComponent("Thumbnail Media")
                        if fileManager.fileExists(atPath: thumbs) {
                            let stat = calculateDirectorySize(at: thumbs)
                            thumbSize += stat.size
                            thumbFilesCount += stat.count
                            thumbPaths.append(thumbs)
                        }

                        let allRender = calculateDirectorySize(at: itemPath)
                        totalSize += allRender.size
                        continue
                    }

                    // 4. Analysis Files —— Stabilization, Optical Flow
                    if item == "Analysis Files" {
                        let stat = calculateDirectorySize(at: itemPath)
                        analysisSize += stat.size
                        analysisFilesCount += stat.count
                        analysisPaths.append(itemPath)
                        totalSize += stat.size
                        continue
                    }

                    // 5. Shared Items
                    if item == "Shared Items" {
                        let stat = calculateDirectorySize(at: itemPath)
                        sharedSize += stat.size
                        sharedFilesCount += stat.count
                        sharedPaths.append(itemPath)
                        totalSize += stat.size
                        continue
                    }

                    // 6. 其他子项目/时间线复合夹
                    let projEvent = (itemPath as NSString).appendingPathComponent("CurrentVersion.fcpevent")
                    if fileManager.fileExists(atPath: projEvent) {
                        projectsCount += 1
                    }

                    let stat = calculateDirectorySize(at: itemPath)
                    totalSize += stat.size
                }
            }
        }

        // 构造分类统计表
        var details: [LibraryCacheDetail] = []

        if renderSize > 0 || !renderPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .renderFiles, byteSize: renderSize, fileCount: renderFilesCount, paths: renderPaths))
        }
        if proxySize > 0 || !proxyPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .proxyMedia, byteSize: proxySize, fileCount: proxyFilesCount, paths: proxyPaths))
        }
        if thumbSize > 0 || !thumbPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .thumbnailMedia, byteSize: thumbSize, fileCount: thumbFilesCount, paths: thumbPaths))
        }
        if sharedSize > 0 || !sharedPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .sharedItems, byteSize: sharedSize, fileCount: sharedFilesCount, paths: sharedPaths))
        }
        if analysisSize > 0 || !analysisPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .analysisFiles, byteSize: analysisSize, fileCount: analysisFilesCount, paths: analysisPaths))
        }
        if tempSize > 0 || !tempPaths.isEmpty {
            details.append(LibraryCacheDetail(category: .tempFiles, byteSize: tempSize, fileCount: tempFilesCount, paths: tempPaths))
        }

        return LibraryBundleItem(
            name: name,
            path: path,
            volumeName: volumeName,
            volumeUUID: volumeUUID,
            totalSizeBytes: totalSize,
            originalMediaSizeBytes: originalMediaSize,
            cacheDetails: details,
            eventsCount: max(eventsCount, 1),
            projectsCount: projectsCount,
            lastScannedAt: Date()
        )
    }

    /// 判断是否是 FCPX 资源库包
    public func isFCPXBundle(at url: URL) -> Bool {
        let path = url.path
        if path.hasSuffix(".fcpbundle") { return true }
        let flexo = (path as NSString).appendingPathComponent("CurrentVersion.flexolibrary")
        return fileManager.fileExists(atPath: flexo)
    }

    // MARK: – 安全瘦身清理逻辑 (严格红线，Trash 保护)

    /// 对资源库执行安全瘦身
    /// - Parameters:
    ///   - item: 待清理的资源库条目
    /// 检查 Final Cut Pro 是否正在运行 (FCPX-031 防写入与锁死冲突)
    public static func isFinalCutRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "FinalCut"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    ///   - categoriesToClean: 选定的清理分类（若传 nil 则清理所有选中的分类）
    /// - Returns: 清理结果报表
    public func safeClean(item: LibraryBundleItem,
                          categoriesToClean: Set<LibraryCacheCategory>? = nil) -> LibraryCleanResult {
        // FCPX-031: 运行中检测，在跑则拒绝清理并提示退出
        if Self.isFinalCutRunning() {
            return LibraryCleanResult(
                libraryName: item.name,
                libraryPath: item.path,
                bytesFreed: 0,
                itemsTrashedCount: 0,
                trashedURLs: [],
                cleanedCategories: [],
                timestamp: Date(),
                isSuccess: false,
                errorMessages: ["Final Cut Pro 正在运行中，清理缓存文件可能导致工程锁死或损坏。请先完全退出 Final Cut Pro 后再执行清理。"]
            )
        }

        var freedBytes: Int64 = 0
        var trashedURLs: [URL] = []
        var cleanedCats: [LibraryCacheCategory] = []
        var errors: [String] = []

        let targetCategories: [LibraryCacheDetail]
        if let specified = categoriesToClean {
            targetCategories = item.cacheDetails.filter { specified.contains($0.category) }
        } else {
            targetCategories = item.cacheDetails.filter { $0.isSelected }
        }

        for detail in targetCategories {
            var categoryFreed: Int64 = 0
            for dirPath in detail.paths {
                // ═══════════════════════════════════════════════════════
                //  严密安全防线：原始素材、元数据数据库绝对禁止触碰！
                // ═══════════════════════════════════════════════════════
                guard !dirPath.contains("Original Media") else {
                    errors.append("【安全拦截】检测到原始素材路径 \(dirPath)，触发最高防线中止！")
                    continue
                }
                guard !dirPath.hasSuffix(".fcpevent") && !dirPath.hasSuffix(".flexolibrary") else {
                    errors.append("【安全拦截】检测到项目数据库，触发最高防线中止！")
                    continue
                }

                guard fileManager.fileExists(atPath: dirPath) else { continue }

                // FCPX-031: 穿透该缓存目录内部，将具体缓存文件逐一移入废纸篓并记录明细
                let dirURL = URL(fileURLWithPath: dirPath)
                guard let contents = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }
                for subName in contents {
                    let subURL = dirURL.appendingPathComponent(subName)
                    let subSize = calculateDirectorySize(at: subURL.path).size
                    do {
                        var resultingURL: NSURL?
                        try fileManager.trashItem(at: subURL, resultingItemURL: &resultingURL)
                        if let trashed = resultingURL as URL? {
                            trashedURLs.append(trashed)
                        }
                        categoryFreed += subSize
                    } catch {
                        errors.append("移入废纸篓失败 [\(subName)]: \(error.localizedDescription)")
                    }
                }
            }

            if categoryFreed > 0 {
                freedBytes += categoryFreed
                cleanedCats.append(detail.category)
            }
        }

        return LibraryCleanResult(
            libraryName: item.name,
            libraryPath: item.path,
            bytesFreed: freedBytes,
            itemsTrashedCount: trashedURLs.count,
            trashedURLs: trashedURLs,
            cleanedCategories: cleanedCats,
            timestamp: Date(),
            isSuccess: errors.isEmpty,
            errorMessages: errors
        )
    }

    /// 一键全选安全清理 (Safe Clean All)
    public func safeCleanAll(item: LibraryBundleItem) -> LibraryCleanResult {
        let allCategories = Set(item.cacheDetails.map { $0.category })
        return safeClean(item: item, categoriesToClean: allCategories)
    }

    // MARK: – 辅助工具函数

    /// 高效计算目录体积与文件总数
    public func calculateDirectorySize(at path: String) -> (size: Int64, count: Int) {
        var totalSize: Int64 = 0
        var totalCount = 0

        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileSizeKey, .fileSizeKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if resourceValues.isDirectory == false {
                let size = resourceValues.totalFileSize ?? resourceValues.fileSize ?? 0
                totalSize += Int64(size)
                totalCount += 1
            }
        }

        return (totalSize, totalCount)
    }
}
