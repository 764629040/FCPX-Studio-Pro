import AppKit

// ═══════════════════════════════════════════════════════════════
//  TemplateTier —— FCPX 模板存储的三级归属（R31 / A-63）
//
//  背景：旧实现把 `~/Movies/Motion Templates.localized` 叫 system_root
//  并显示成「系统内置盘」，这是错的——它在 FCPX 语义里是「用户」级。
//  同时用「是不是软链接」冒充归属层级，两个维度被混成了一个布尔值。
//
//  本文件只做三件事：
//    1. 定义三级归属枚举与磁盘形态（两个独立维度）；
//    2. 动态定位三级根目录（禁止写死 FCPX 应用名）；
//    3. 三级各自独立扫描，同名项全部列出、各自标注。
// ═══════════════════════════════════════════════════════════════

/// FCPX 模板存储的三级归属
public enum TemplateTier: String, CaseIterable, Codable {
    case builtin   // 内置：FCPX 应用程序包内部
    case user      // 用户：~/Movies/Motion Templates.localized
    case system    // 系统：/Library/Application Support/Final Cut Pro/Templates

    public var displayName: String {
        switch self {
        case .builtin: return "内置"
        case .user:    return "用户"
        case .system:  return "系统"
        }
    }

    /// 表格「归属」列的文案（颜色由 UI 层按 tier 上色）
    public var badgeText: String {
        switch self {
        case .builtin: return "🟡 内置"
        case .user:    return "🟢 用户"
        case .system:  return "🟣 系统"
        }
    }

    public var sortIndex: Int {
        switch self {
        case .builtin: return 0
        case .user:    return 1
        case .system:  return 2
        }
    }
}

/// 磁盘形态（与「归属层级」正交的第二个维度）
public enum DiskForm {
    case physical(sizeMB: Double)
    case externalLink(target: String, targetAvailable: Bool)

    /// 表格「磁盘形态」列文案。绝不再用它冒充归属。
    public var displayText: String {
        switch self {
        case .physical(let size):
            return String(format: "实体（占用系统盘 %.1f MB）", size)
        case .externalLink(_, let ok):
            let base = "软链接 → 外置盘（0 占用）"
            return ok ? base : base + " ⚠︎ 目标缺失"
        }
    }
}

/// 扫描出的一条模板
public struct TemplateItem {
    public let name: String
    public let category: String
    public var subCategory: String
    public let tier: TemplateTier
    /// 该层级根目录下的真实路径（可能是软链接本体）
    public var path: String
    /// 软链接解析后的目标；非软链接时等于 path
    public var targetPath: String
    public let isSymlink: Bool
    public let targetAvailable: Bool
    public var sizeMB: Double
    public var isEnabled: Bool
    public var isOffline: Bool = false
    public var volumePath: String? = nil
    public var volumeUUID: String? = nil
    public var isCorrupted: Bool = false
    public var isMismatchedDisk: Bool = false

    private static let volumeUUIDLock = NSLock()
    private static var volumeUUIDCache: [String: String] = [:]

    // ⚠️ 性能关键路径：按卷缓存禁止移除，移除将导致 2000 条遍历退化为 72ms 主线程卡顿
    /// S-2: 线程安全的卷硬件 UUID 查询（静态内存缓存，单卷仅触发一次磁盘 I/O）
    public static func getVolumeUUID(for volumePath: String, bypassCache: Bool = false) -> String? {
        let norm = (volumePath as NSString).standardizingPath
        guard !norm.isEmpty else { return nil }
        if !bypassCache {
            volumeUUIDLock.lock()
            if let cached = volumeUUIDCache[norm] {
                volumeUUIDLock.unlock()
                return cached
            }
            volumeUUIDLock.unlock()
        }

        let url = URL(fileURLWithPath: norm)
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString else { return nil }

        volumeUUIDLock.lock()
        volumeUUIDCache[norm] = uuid
        volumeUUIDLock.unlock()
        return uuid
    }

    /// 卷插拔时失效路径 UUID 缓存，防止异盘挂载到同一挂载点时返回脏缓存
    public static func invalidateVolumeUUIDCache(for volumePath: String? = nil) {
        volumeUUIDLock.lock()
        defer { volumeUUIDLock.unlock() }
        if let path = volumePath {
            let norm = (path as NSString).standardizingPath
            volumeUUIDCache.removeValue(forKey: norm)
        } else {
            volumeUUIDCache.removeAll()
        }
    }

    /// M-6 / M-7: 公共高性能素材索引构建器（仅使用 compositeKey 与 path 两级强唯一键，保持首项优先语义）
    public static func buildItemIndex(from items: [TemplateItem]) -> [String: TemplateItem] {
        var index: [String: TemplateItem] = [:]
        index.reserveCapacity(items.count * 2)
        for item in items {
            let compositeKey = "\(item.path)|\(item.targetPath)"
            if index[compositeKey] == nil {
                index[compositeKey] = item
            }
            if index[item.path] == nil {
                index[item.path] = item
            }
        }
        return index
    }

    public var diskForm: DiskForm {
        isSymlink
            ? .externalLink(target: targetPath, targetAvailable: targetAvailable)
            : .physical(sizeMB: sizeMB)
    }

    public init(name: String, category: String, subCategory: String = "", tier: TemplateTier, path: String,
                targetPath: String, isSymlink: Bool, targetAvailable: Bool, sizeMB: Double,
                isEnabled: Bool = true, isOffline: Bool = false, volumePath: String? = nil,
                volumeUUID: String? = nil, isCorrupted: Bool = false, isMismatchedDisk: Bool = false) {
        self.name = name
        self.category = category
        self.subCategory = subCategory
        self.tier = tier
        self.path = path
        self.targetPath = targetPath
        self.isSymlink = isSymlink
        self.targetAvailable = targetAvailable
        self.sizeMB = sizeMB
        self.isEnabled = isEnabled
        self.isOffline = isOffline
        self.isCorrupted = isCorrupted
        self.isMismatchedDisk = isMismatchedDisk

        if let volumePath = volumePath {
            self.volumePath = volumePath
        } else if targetPath.hasPrefix("/Volumes/") {
            let comps = targetPath.split(separator: "/")
            self.volumePath = comps.count >= 2 ? "/Volumes/\(comps[1])" : nil
        } else if path.hasPrefix("/Volumes/") {
            let comps = path.split(separator: "/")
            self.volumePath = comps.count >= 2 ? "/Volumes/\(comps[1])" : nil
        } else {
            self.volumePath = nil
        }

        if let volumeUUID = volumeUUID {
            self.volumeUUID = volumeUUID
        } else if let vp = self.volumePath {
            self.volumeUUID = Self.getVolumeUUID(for: vp)
        } else {
            self.volumeUUID = nil
        }
    }

    public init(name: String, category: String, tier: TemplateTier, path: String,
                targetPath: String, isSymlink: Bool, targetAvailable: Bool, sizeMB: Double,
                isEnabled: Bool = true, isOffline: Bool = false, volumePath: String? = nil,
                volumeUUID: String? = nil, isCorrupted: Bool = false, isMismatchedDisk: Bool = false) {
        self.init(name: name, category: category, subCategory: "", tier: tier, path: path,
                  targetPath: targetPath, isSymlink: isSymlink, targetAvailable: targetAvailable,
                  sizeMB: sizeMB, isEnabled: isEnabled, isOffline: isOffline, volumePath: volumePath,
                  volumeUUID: volumeUUID, isCorrupted: isCorrupted, isMismatchedDisk: isMismatchedDisk)
    }
}

// MARK: – U-10 全局状态色板收敛 (StatusPalette)

public struct StatusPalette {
    /// 中性离线灰
    public static let offlineGray = NSColor(calibratedRed: 0.50, green: 0.52, blue: 0.56, alpha: 1.0)
    public static let offlineBg = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.27, alpha: 0.95)
    public static let offlineBorder = NSColor(calibratedWhite: 0.28, alpha: 0.6)

    /// 警示红（损坏/丢失、严重故障）
    public static let alertRed = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)
    public static let alertRedBg = NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.20, alpha: 0.95)
    public static let alertRedBorder = NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.20, alpha: 0.8)

    /// 琥珀橙（异盘同名、隔离保护）
    public static let amberOrange = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.12, alpha: 1.0)
    public static let amberOrangeBg = NSColor(calibratedRed: 0.92, green: 0.55, blue: 0.10, alpha: 0.95)
    public static let amberOrangeBorder = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.12, alpha: 0.8)

    /// 启用绿
    public static let successGreen = NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.42, alpha: 1.0)
    public static let successGreenBg = NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.18, alpha: 0.9)
    public static let successGreenBorder = NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.35, alpha: 1.0)

    /// 停用中性灰
    public static let disabledBg = NSColor(calibratedWhite: 0.18, alpha: 0.9)
    public static let disabledBorder = NSColor(calibratedWhite: 0.32, alpha: 1.0)
    public static let cardBorderNormal = NSColor(calibratedWhite: 0.20, alpha: 1.0)
}

// MARK: – 三级根目录

public struct TemplateTierRoots {
    public let builtin: String?
    public let user: String
    public let system: String
    /// builtin 为 nil 时的原因（用于 UI 优雅降级文案）
    public let builtinNote: String

    public func root(for tier: TemplateTier) -> String? {
        switch tier {
        case .builtin: return builtin
        case .user:    return user
        case .system:  return system
        }
    }

    public init(builtin: String?, user: String, system: String, builtinNote: String) {
        self.builtin = builtin
        self.user = user
        self.system = system
        self.builtinNote = builtinNote
    }

    /// 解析三级根目录。
    ///
    /// 两个 `FCPXSTUDIO_*_TEMPLATES_ROOT` 环境变量是给逻辑 harness / 自动化验收用的
    /// 覆盖入口（真机用户不设），保证迁移逻辑可以在临时目录里真实跑一遍。
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> TemplateTierRoots {
        let userRoot = environment["FCPXSTUDIO_USER_TEMPLATES_ROOT"]
            ?? (NSString(string: "~/Movies/Motion Templates.localized").expandingTildeInPath)

        let systemRoot = environment["FCPXSTUDIO_SYSTEM_TEMPLATES_ROOT"]
            ?? "/Library/Application Support/Final Cut Pro/Templates"

        if let override = environment["FCPXSTUDIO_BUILTIN_TEMPLATES_ROOT"] {
            return TemplateTierRoots(builtin: override, user: userRoot,
                                     system: systemRoot, builtinNote: "内置级根目录由环境变量覆盖")
        }

        let located = FCPXLocator.locateMotionTemplatesRoot()
        return TemplateTierRoots(builtin: located.path, user: userRoot,
                                 system: systemRoot, builtinNote: located.note)
    }
}

/// 动态定位 FCPX 应用包里的 METemplates 根目录。
///
/// 禁止写死应用名：真机上是 `Final Cut Pro Creator Studio.app`。
public enum FCPXLocator {
    /// 已知 bundle id。真机实测 `com.apple.FinalCutApp`；任务单写的是
    /// `com.apple.FinalCut`（部分版本/旧文档），两个都试，不赌。
    public static let bundleIdentifiers = ["com.apple.FinalCut", "com.apple.FinalCutApp"]

    public static let relativePluginPath = "Contents/PlugIns/MediaProviders/MotionEffect.fxp"
    public static let relativeTemplatesPath = "Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/METemplates.localized"

    /// 返回 (METemplates.localized 绝对路径 或 nil, 人类可读原因)
    public static func locateMotionTemplatesRoot() -> (path: String?, note: String) {
        let fm = FileManager.default

        // 1. 优先按 bundle id 问系统
        for bid in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let candidate = url.appendingPathComponent(relativeTemplatesPath).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                    return (candidate, "已按 bundle id \(bid) 定位到 \(url.lastPathComponent)")
                }
                // bundle id 命中了，但包里没有模板目录 —— 继续兜底扫描，不提前失败
            }
        }

        // 2. 兜底：扫描 /Applications、~/Applications、/System/Applications 下的一级 *.app
        //    条件：包内存在 MotionEffect.fxp（再确认 METemplates.localized）
        var sawPluginWithoutTemplates = false
        for base in ["/Applications", "~/Applications", "/System/Applications"] {
            let basePath = (base as NSString).expandingTildeInPath
            guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let appPath = "\(basePath)/\(entry)"
                let pluginPath = "\(appPath)/\(relativePluginPath)"
                guard fm.fileExists(atPath: pluginPath) else { continue }
                let templates = "\(appPath)/\(relativeTemplatesPath)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: templates, isDirectory: &isDir), isDir.boolValue {
                    return (templates, "已按包结构扫描定位到 \(entry)")
                }
                sawPluginWithoutTemplates = true
            }
        }

        if sawPluginWithoutTemplates {
            return (nil, "找到 FCPX 插件但缺少 METemplates.localized，内置级不可用")
        }
        return (nil, "未检测到 FCPX（未找到包含 MotionEffect.fxp 的应用）")
    }
}

// MARK: – 三级扫描

public struct TemplateScanResult {
    public let items: [TemplateItem]
    /// tier -> 该级不可用的原因（该级为空是正常状态，不进这里）
    public let tierNotes: [TemplateTier: String]
    public let roots: TemplateTierRoots

    public init(items: [TemplateItem], tierNotes: [TemplateTier: String], roots: TemplateTierRoots) {
        self.items = items
        self.tierNotes = tierNotes
        self.roots = roots
    }
}

public enum TemplateTierScanner {
    public static let categories = [
        "Titles.localized",
        "Effects.localized",
        "Transitions.localized",
        "Generators.localized"
    ]

    /// 计算指定目录的物理占用（MB，避免软链接循环）
    public static func calculateDirectorySize(at target: String) -> Double {
        let fm = FileManager.default
        var bytes: Int64 = 0
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir) else { return 0.0 }
        if !isDir.boolValue {
            if let attrs = try? fm.attributesOfItem(atPath: target),
               let size = attrs[.size] as? NSNumber {
                bytes += size.int64Value
            }
            return round(Double(bytes) / (1024.0 * 1024.0) * 10) / 10.0
        }
        if let en = fm.enumerator(atPath: target) {
            while let rel = en.nextObject() as? String {
                let fp = "\(target)/\(rel)"
                // 跳过软链接，避免重复计入
                if (try? fm.destinationOfSymbolicLink(atPath: fp)) != nil { continue }
                if let attrs = try? fm.attributesOfItem(atPath: fp),
                   let size = attrs[.size] as? NSNumber {
                    bytes += size.int64Value
                }
            }
        }
        return round(Double(bytes) / (1024.0 * 1024.0) * 10) / 10.0
    }

    /// 三级各自独立深度扫描；同名项全部保留（不去重）。
    /// 支持递归穿透子分类目录（如 03综艺动漫/图标/图标01），精准定位真实模板与 large.png
    /// lazySizes: 为 true 时跳过耗时的递归文件体积遍历，先快速输出列表（10ms 内），后续可后台懒加载
    public static func scan(category: String, roots: TemplateTierRoots = .resolve(), lazySizes: Bool = false) -> TemplateScanResult {
        let fm = FileManager.default
        var items: [TemplateItem] = []
        var notes: [TemplateTier: String] = [:]

        if roots.builtin == nil {
            notes[.builtin] = roots.builtinNote
        }
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: roots.system, isDirectory: &isDir) || !isDir.boolValue {
            notes[.system] = "系统级目录不存在（可由 FCPX 或管理员创建）"
        }

        let templateExts: Set<String> = ["moti", "moef", "motr", "motn"]

        func scanRecursive(logicalDir: String, targetDir: String, subCategory: String, isSymParent: Bool, tier: TemplateTier) -> [TemplateItem] {
            var foundItems: [TemplateItem] = []
            guard let entries = try? fm.contentsOfDirectory(atPath: targetDir) else { return foundItems }

            // 1. 检查当前目录本身是否直接包含 Motion 模板工程文件（.moti / .moef / .motr / .motn）
            var hasTemplateFile = false
            var templateFileStem = ""
            for entry in entries {
                let ext = (entry as NSString).pathExtension.lowercased()
                if templateExts.contains(ext) {
                    hasTemplateFile = true
                    templateFileStem = (entry as NSString).deletingPathExtension
                    break
                }
            }

            if hasTemplateFile {
                let dirName = (logicalDir as NSString).lastPathComponent
                let isEnabled = !dirName.hasSuffix(".disabled")
                let cleanDirName = isEnabled ? dirName : String(dirName.dropLast(9))
                let displayName = templateFileStem.isEmpty ? cleanDirName : templateFileStem
                let targetExists = fm.fileExists(atPath: targetDir)

                var sizeMB: Double = 0.0
                if !lazySizes && targetExists {
                    sizeMB = calculateDirectorySize(at: targetDir)
                }

                foundItems.append(TemplateItem(
                    name: displayName,
                    category: category,
                    subCategory: subCategory,
                    tier: tier,
                    path: logicalDir,
                    targetPath: targetDir,
                    isSymlink: isSymParent,
                    targetAvailable: targetExists,
                    sizeMB: sizeMB,
                    isEnabled: isEnabled
                ))
                return foundItems
            }

            // 2. 检查子目录（R51：严格过滤非模板目录及 framework/app/bundle 内部资源，杜绝外置盘阻塞）
            var subdirs: [(entry: String, childLogical: String, childTarget: String, isSymlink: Bool)] = []
            for entry in entries.sorted() {
                let lower = entry.lowercased()
                if entry.hasPrefix(".") || entry == "Icon\r" || entry == "templateThemes" ||
                   lower.hasSuffix(".framework") || lower.hasSuffix(".app") ||
                   lower.hasSuffix(".pluginkit") || lower.hasSuffix(".bundle") ||
                   lower.hasSuffix(".lproj") || lower.hasSuffix(".dylib") ||
                   entry == "_CodeSignature" || entry == "Contents" || entry == "Versions" ||
                   entry == "Resources" || entry == "Headers" || entry == "Modules" {
                    continue
                }
                let childLogical = "\(logicalDir)/\(entry)"
                let childTargetCandidate = "\(targetDir)/\(entry)"
                var isDirectory: ObjCBool = false
                var currentSym = isSymParent
                var resolvedTarget = childTargetCandidate
                if let dest = try? fm.destinationOfSymbolicLink(atPath: childTargetCandidate) {
                    currentSym = true
                    resolvedTarget = dest.hasPrefix("/") ? dest : ((targetDir as NSString).appendingPathComponent(dest))
                }
                if fm.fileExists(atPath: resolvedTarget, isDirectory: &isDirectory), isDirectory.boolValue {
                    subdirs.append((entry: entry, childLogical: childLogical, childTarget: resolvedTarget, isSymlink: currentSym))
                }
            }

            // 3. 若无子目录且非分类根目录，作为叶子目录项（排除非模板及内部 bundle 目录）
            if subdirs.isEmpty && !subCategory.isEmpty {
                let dirName = (logicalDir as NSString).lastPathComponent
                let lowerDir = dirName.lowercased()
                if lowerDir.hasSuffix(".framework") || lowerDir.hasSuffix(".app") ||
                   lowerDir.hasSuffix(".pluginkit") || lowerDir.hasSuffix(".bundle") ||
                   lowerDir.hasSuffix(".lproj") || lowerDir.hasSuffix(".dylib") ||
                   dirName == "Contents" || dirName == "_CodeSignature" ||
                   dirName == "Resources" || dirName == "Versions" {
                    return foundItems
                }
                let isEnabled = !dirName.hasSuffix(".disabled")
                let cleanDirName = isEnabled ? dirName : String(dirName.dropLast(9))
                let targetExists = fm.fileExists(atPath: targetDir)

                var sizeMB: Double = 0.0
                if !lazySizes && targetExists {
                    sizeMB = calculateDirectorySize(at: targetDir)
                }

                foundItems.append(TemplateItem(
                    name: cleanDirName,
                    category: category,
                    subCategory: subCategory,
                    tier: tier,
                    path: logicalDir,
                    targetPath: targetDir,
                    isSymlink: isSymParent,
                    targetAvailable: targetExists,
                    sizeMB: sizeMB,
                    isEnabled: isEnabled
                ))
                return foundItems
            }

            // 4. 递归深入子目录扫描
            for sub in subdirs {
                let nextSubCat = subCategory.isEmpty ? sub.entry : subCategory
                let children = scanRecursive(
                    logicalDir: sub.childLogical,
                    targetDir: sub.childTarget,
                    subCategory: nextSubCat,
                    isSymParent: sub.isSymlink,
                    tier: tier
                )
                foundItems.append(contentsOf: children)
            }

            return foundItems
        }

        for tier in TemplateTier.allCases {
            guard let root = roots.root(for: tier) else { continue }
            let catPath = "\(root)/\(category)"
            guard fm.fileExists(atPath: catPath) else { continue }

            var isSym = false
            var targetCatPath = catPath
            if let dest = try? fm.destinationOfSymbolicLink(atPath: catPath) {
                isSym = true
                targetCatPath = dest.hasPrefix("/") ? dest : ((root as NSString).appendingPathComponent(dest))
            }

            let tierItems = scanRecursive(
                logicalDir: catPath,
                targetDir: targetCatPath,
                subCategory: "",
                isSymParent: isSym,
                tier: tier
            )
            items.append(contentsOf: tierItems)
        }

        return TemplateScanResult(items: items, tierNotes: notes, roots: roots)
    }

    /// 异步扫描指定分类，强制切入后台 GCD 线程，自动命中/填充 AssetCacheManager
    public static func scanAsync(
        category: String,
        roots: TemplateTierRoots = .resolve(),
        lazySizes: Bool = true,
        completion: @escaping (TemplateScanResult) -> Void
    ) {
        if let cached = AssetCacheManager.shared.getTemplates(category: category) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = scan(category: category, roots: roots, lazySizes: lazySizes)
            AssetCacheManager.shared.setTemplates(category: category, result: result)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// 后台懒加载单个模板的体积并更新缓存
    public static func calculateSizeAsync(
        for item: TemplateItem,
        completion: @escaping (Double) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let size = calculateDirectorySize(at: item.targetPath)
            AssetCacheManager.shared.updateTemplateSize(category: item.category, name: item.name, sizeMB: size)
            DispatchQueue.main.async {
                completion(size)
            }
        }
    }
}

// MARK: – 内置级写入权限（A-64 / 5.2）

public enum TierWritePolicy {
    /// 必须与设置面板、文档、`defaults read` 三处一致
    public static let builtinWritableKey = "builtinTierWritable"

    /// 默认 false（只读）
    public static var isBuiltinWritable: Bool {
        UserDefaults.standard.bool(forKey: builtinWritableKey)
    }

    public static func setBuiltinWritable(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: builtinWritableKey)
        UserDefaults.standard.synchronize()
    }

    public static var statusText: String {
        isBuiltinWritable ? "可写（高级）" : "只读（默认，推荐）"
    }
}
