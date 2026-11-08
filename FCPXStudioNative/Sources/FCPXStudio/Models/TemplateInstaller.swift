import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  TemplateInstaller —— 智能拖拽与 Zip 自动识别安装引擎（R37）
//  对标基准：/Applications/嘉星插件管理 2.app (FxXuZipInstall)
//
//  核心能力：
//    1. 自动识别 .moti / .moef / .motr / .motn 四大分类
//    2. 安全解压沙箱，递归感知分类与模板包目录
//    3. 原子安装与重名自动备份（防覆盖隔离）
//    4. 模板一键启停隔离（.disabled 机制，加速 FCPX 启动）
// ═══════════════════════════════════════════════════════════════

public enum MotionCategory: String, CaseIterable, Codable {
    case titles = "Titles.localized"
    case effects = "Effects.localized"
    case transitions = "Transitions.localized"
    case generators = "Generators.localized"

    public var displayName: String {
        switch self {
        case .titles:      return "字幕"
        case .effects:     return "特效"
        case .transitions: return "转场"
        case .generators:  return "发生器"
        }
    }

    public var motionExtension: String {
        switch self {
        case .titles:      return "moti"
        case .effects:     return "moef"
        case .transitions: return "motr"
        case .generators:  return "motn"
        }
    }

    public static func fromExtension(_ ext: String) -> MotionCategory? {
        let clean = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch clean {
        case "moti": return .titles
        case "moef": return .effects
        case "motr": return .transitions
        case "motn": return .generators
        default:     return nil
        }
    }
}

public struct DiscoveredTemplate {
    public let templateName: String
    public let category: MotionCategory
    public let subcategory: String
    public let folderPath: String
    public let motionFilePath: String

    public init(templateName: String, category: MotionCategory, subcategory: String,
                folderPath: String, motionFilePath: String) {
        self.templateName = templateName
        self.category = category
        self.subcategory = subcategory
        self.folderPath = folderPath
        self.motionFilePath = motionFilePath
    }
}

public struct InstalledTemplateResult {
    public let templateName: String
    public let category: String
    public let subcategory: String
    public let installedPath: String
    public let backupPath: String?

    public init(templateName: String, category: String, subcategory: String,
                installedPath: String, backupPath: String?) {
        self.templateName = templateName
        self.category = category
        self.subcategory = subcategory
        self.installedPath = installedPath
        self.backupPath = backupPath
    }
}

public enum TemplateInstallerError: Error, LocalizedError {
    case unzipFailed(String)
    case noTemplatesFound
    case destinationNotWritable(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unzipFailed(let msg):
            return "解压压缩包失败：\(msg)"
        case .noTemplatesFound:
            return "未在提供的文件或目录中检测到有效的 FCPX 模板（.moti/.moef/.motr/.motn）"
        case .destinationNotWritable(let path):
            return "目标安装路径不可写：\(path)"
        case .ioFailure(let msg):
            return "模板安装 I/O 错误：\(msg)"
        }
    }
}

public enum TemplateToggleError: Error, LocalizedError {
    case builtinProtected
    case destinationExists(String)
    case fileNotFound(String)
    case failure(String)

    public var errorDescription: String? {
        switch self {
        case .builtinProtected:
            return "系统内置模板受保护，需先复制到用户库后再调整"
        case .destinationExists(let path):
            return "目标路径已存在同名项：\(path)"
        case .fileNotFound(let path):
            return "模板文件未找到：\(path)"
        case .failure(let msg):
            return "启停切换失败：\(msg)"
        }
    }
}

public class TemplateInstaller {
    public static let shared = TemplateInstaller()
    public init() {}

    public func toggleTemplate(item: TemplateItem) throws -> TemplateItem {
        return try Self.toggleTemplate(item: item)
    }

    public static let knownMotionExtensions: Set<String> = ["moti", "moef", "motr", "motn"]

    // MARK: – 拖拽感知检测

    public static func acceptsDrop(paths: [String]) -> Bool {
        let fm = FileManager.default
        for path in paths {
            if path.lowercased().hasSuffix(".zip") { return true }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                if containsMotionFiles(dirPath: path, maxDepth: 4) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsMotionFiles(dirPath: String, maxDepth: Int) -> Bool {
        guard maxDepth > 0 else { return false }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return false }
        for entry in entries {
            if entry.hasPrefix(".") || entry == "__MACOSX" { continue }
            let full = "\(dirPath)/\(entry)"
            let ext = (entry as NSString).pathExtension.lowercased()
            if knownMotionExtensions.contains(ext) { return true }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                if containsMotionFiles(dirPath: full, maxDepth: maxDepth - 1) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: – 解压与智能扫描

    public static func unzip(zipPath: String, to destinationDir: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir) {
            try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipPath, destinationDir]
        let pipe = Pipe()
        process.standardError = pipe

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()

        // 60s 超时时间窗，避免损坏 zip 导致 ditto 进程永久挂起
        let timeout = group.wait(timeout: .now() + 60.0)
        if timeout == .timedOut {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw TemplateInstallerError.unzipFailed("解压超时 (超过 60 秒)")
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "code \(process.terminationStatus)"
            throw TemplateInstallerError.unzipFailed(errMsg.isEmpty ? "code \(process.terminationStatus)" : errMsg)
        }
    }

    public static func discoverTemplates(inDirectory rootDir: String, defaultSubcategory: String = "FCPX Studio") -> [DiscoveredTemplate] {
        let fm = FileManager.default
        var results: [DiscoveredTemplate] = []
        var seenFolders = Set<String>()

        guard let enumerator = fm.enumerator(atPath: rootDir) else { return [] }

        while let relPath = enumerator.nextObject() as? String {
            if relPath.contains("__MACOSX") || relPath.contains(".DS_Store") { continue }
            let ext = (relPath as NSString).pathExtension.lowercased()
            guard let category = MotionCategory.fromExtension(ext) else { continue }

            let fullMotionPath = (rootDir as NSString).appendingPathComponent(relPath)
            let folderPath = (fullMotionPath as NSString).deletingLastPathComponent
            guard !seenFolders.contains(folderPath) else { continue }
            seenFolders.insert(folderPath)

            let templateName = (folderPath as NSString).lastPathComponent
            // 计算子分类名（Theme / Subcategory）
            let relFolder = (folderPath as NSString).replacingOccurrences(of: rootDir, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = relFolder.split(separator: "/").map(String.init)

            var subcategory = defaultSubcategory
            if components.count >= 2 {
                // 上级目录作为子分类
                let parentComponent = components[components.count - 2]
                if !parentComponent.hasSuffix(".localized") {
                    subcategory = parentComponent
                } else if components.count >= 3 {
                    subcategory = components[components.count - 3]
                }
            } else if !defaultSubcategory.isEmpty {
                subcategory = defaultSubcategory
            }

            results.append(DiscoveredTemplate(
                templateName: templateName,
                category: category,
                subcategory: subcategory,
                folderPath: folderPath,
                motionFilePath: fullMotionPath
            ))
        }

        return results
    }

    // MARK: – 原子安装

    public static func install(paths: [String],
                               targetTierRoot: String? = nil,
                               defaultSubcategory: String? = nil) throws -> [InstalledTemplateResult] {
        let fm = FileManager.default
        let userRoot = targetTierRoot ?? TemplateTierRoots.resolve().user
        var installed: [InstalledTemplateResult] = []

        let tempSandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPX_Installer_\(UUID().uuidString)").path
        defer {
            try? fm.removeItem(atPath: tempSandbox)
        }

        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }

            var scanDir = path
            var derivedSubcat = defaultSubcategory ?? (path as NSString).lastPathComponent

            if path.lowercased().hasSuffix(".zip") {
                derivedSubcat = defaultSubcategory ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let unpackDir = "\(tempSandbox)/\(UUID().uuidString)"
                try unzip(zipPath: path, to: unpackDir)
                scanDir = unpackDir
            }

            let discovered = discoverTemplates(inDirectory: scanDir, defaultSubcategory: derivedSubcat)
            guard !discovered.isEmpty else { continue }

            for item in discovered {
                let catDir = "\(userRoot)/\(item.category.rawValue)/\(item.subcategory)"
                let targetPath = "\(catDir)/\(item.templateName)"

                try fm.createDirectory(atPath: catDir, withIntermediateDirectories: true)

                var backupPath: String? = nil
                if fm.fileExists(atPath: targetPath) {
                    // 安全隔离备份：防覆盖
                    let backupDir = "\(TemplateMigrator.backupRoot)/installer_conflicts"
                    try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
                    let df = DateFormatter()
                    df.dateFormat = "yyyyMMdd_HHmmss"
                    let ts = df.string(from: Date())
                    let bPath = "\(backupDir)/\(ts)_\(item.templateName)"
                    try fm.moveItem(atPath: targetPath, toPath: bPath)
                    backupPath = bPath
                }

                try fm.copyItem(atPath: item.folderPath, toPath: targetPath)
                guard fm.fileExists(atPath: targetPath) else {
                    throw TemplateInstallerError.ioFailure("安装文件落盘验证失败：\(targetPath)")
                }

                installed.append(InstalledTemplateResult(
                    templateName: item.templateName,
                    category: item.category.rawValue,
                    subcategory: item.subcategory,
                    installedPath: targetPath,
                    backupPath: backupPath
                ))
            }
        }

        guard !installed.isEmpty else {
            throw TemplateInstallerError.noTemplatesFound
        }

        return installed
    }

    // MARK: – 模板一键启停隔离（.disabled Toggle）

    public static func toggleTemplate(item: TemplateItem) throws -> TemplateItem {
        // 内置级只读保护
        if item.tier == .builtin && !TierWritePolicy.isBuiltinWritable {
            throw TemplateToggleError.builtinProtected
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: item.path) else {
            throw TemplateToggleError.fileNotFound(item.path)
        }

        let parentDir = (item.path as NSString).deletingLastPathComponent
        let currentName = (item.path as NSString).lastPathComponent

        let newName: String
        let targetEnabled: Bool

        if item.isEnabled {
            newName = currentName.hasSuffix(".disabled") ? currentName : "\(currentName).disabled"
            targetEnabled = false
        } else {
            newName = currentName.hasSuffix(".disabled") ? String(currentName.dropLast(9)) : currentName
            targetEnabled = true
        }

        let newPath = "\(parentDir)/\(newName)"
        if fm.fileExists(atPath: newPath) && newPath != item.path {
            throw TemplateToggleError.destinationExists(newPath)
        }

        do {
            try fm.moveItem(atPath: item.path, toPath: newPath)
        } catch {
            throw TemplateToggleError.failure(error.localizedDescription)
        }

        let cleanDisplayName = newName.hasSuffix(".disabled") ? String(newName.dropLast(9)) : newName
        AssetCacheManager.shared.invalidateTemplates(category: item.category)

        return TemplateItem(
            name: cleanDisplayName,
            category: item.category,
            subCategory: item.subCategory,
            tier: item.tier,
            path: newPath,
            targetPath: item.isSymlink ? item.targetPath : newPath,
            isSymlink: item.isSymlink,
            targetAvailable: item.targetAvailable,
            sizeMB: item.sizeMB,
            isEnabled: targetEnabled
        )
    }

    @discardableResult
    public static func installTemplates(paths: [String],
                                        targetTierRoot: String? = nil,
                                        defaultSubcategory: String? = nil) throws -> [InstalledTemplateResult] {
        return try install(paths: paths, targetTierRoot: targetTierRoot, defaultSubcategory: defaultSubcategory)
    }

    @discardableResult
    public static func installTemplates(atPath path: String,
                                        targetTierRoot: String? = nil,
                                        defaultSubcategory: String? = nil) throws -> [InstalledTemplateResult] {
        return try install(paths: [path], targetTierRoot: targetTierRoot, defaultSubcategory: defaultSubcategory)
    }

    public static func setTemplateEnabled(item: TemplateItem, enabled: Bool) throws -> TemplateItem {
        if item.isEnabled == enabled { return item }
        return try toggleTemplate(item: item)
    }
}
