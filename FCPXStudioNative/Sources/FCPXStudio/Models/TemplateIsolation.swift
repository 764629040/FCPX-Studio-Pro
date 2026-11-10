// ═══════════════════════════════════════════════════════════════════════════
//  TemplateIsolation —— TR-010 真隔离仓（方案 A）
//
//  旧机制：把模板目录改名加 .disabled 后缀，FCPX 仍照常扫描加载（承诺不成立）。
//  新机制：禁用 = 把模板整体（目录/软链接）移出 FCPX 扫描树，搬进
//          ~/Library/Application Support/FCPXStudio/disabled/<分类>/<相对路径>/；
//          启用 = 原路搬回扫描树。FCPX 扫不到，启动确实变快，改名方案淘汰。
//  纯 Foundation，app 与独立校验脚本共用，无 AppKit 依赖。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

public enum TemplateIsolationStore {

    public static let motionTemplatesRoot: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Movies/Motion Templates.localized")
    }()

    public static let disabledRoot: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/FCPXStudio/disabled")
    }()

    public static let knownCategories = [
        "Titles.localized", "Effects.localized",
        "Transitions.localized", "Generators.localized",
    ]

    /// 判断路径是否位于禁用仓内
    public static func isDisabled(path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let d = (disabledRoot as NSString).standardizingPath
        return p == d || p.hasPrefix(d + "/")
    }

    /// 判断路径是否位于 FCPX 扫描树内
    public static func isInScanTree(path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let m = (motionTemplatesRoot as NSString).standardizingPath
        return p == m || p.hasPrefix(m + "/")
    }

    /// 从绝对路径解析 (分类, 分类下的相对路径含模板名)；找不到分类返回 nil
    public static func relativePathUnderCategory(for absPath: String) -> (category: String, relative: String)? {
        let std = (absPath as NSString).standardizingPath
        let parts = std.split(separator: "/").map(String.init)
        guard let idx = parts.firstIndex(where: { knownCategories.contains($0) }) else {
            return nil
        }
        let category = parts[idx]
        let relative = parts[(idx + 1)...].joined(separator: "/")
        return (category, relative)
    }

    /// 禁用：把扫描树内的模板移入禁用仓（保留分类与子分组结构）
    @discardableResult
    public static func disable(templatePath: String) throws -> String {
        let fm = FileManager.default
        let std = (templatePath as NSString).standardizingPath
        guard isInScanTree(path: std) else {
            throw NSError(domain: "TemplateIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "disable 仅接受扫描树内的模板: \(std)"])
        }
        guard let (category, relative) = relativePathUnderCategory(for: std) else {
            throw NSError(domain: "TemplateIsolation", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析分类: \(std)"])
        }
        let dest = "\(disabledRoot)/\(category)/\(relative)"
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) {
            throw NSError(domain: "TemplateIsolation", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "禁用仓内已存在同名: \(dest)"])
        }
        try fm.moveItem(atPath: std, toPath: dest)
        return dest
    }

    /// 启用：把禁用仓内的模板原路搬回扫描树
    @discardableResult
    public static func enable(disabledPath: String) throws -> String {
        let fm = FileManager.default
        let std = (disabledPath as NSString).standardizingPath
        guard isDisabled(path: std) else {
            throw NSError(domain: "TemplateIsolation", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "enable 仅接受禁用仓内的模板: \(std)"])
        }
        guard let (category, relative) = relativePathUnderCategory(for: std) else {
            throw NSError(domain: "TemplateIsolation", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析分类: \(std)"])
        }
        let dest = "\(motionTemplatesRoot)/\(category)/\(relative)"
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) {
            throw NSError(domain: "TemplateIsolation", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "扫描树内已存在同名: \(dest)"])
        }
        try fm.moveItem(atPath: std, toPath: dest)
        return dest
    }

    /// 一次性迁移：扫描树内所有 *.disabled 目录按方案 A 搬进禁用仓。
    /// 返回被移动的 (原路径 -> 禁用仓路径) 列表。
    ///
    /// TR-010 加固：只迁移「被改名禁用的 FCPX 模板目录」，判定条件是该目录本身或其
    /// 直接子项含 FCPX 模板主文件（.moti/.moef/.motr/.motn）。绝不动 bundle 内部的
    /// .disabled（如 *.framework/Resources.disabled 是框架自身版本化符号链接，搬走会破坏插件）。
    @discardableResult
    public static func migrateExistingDisabledInScanTree() throws -> [(from: String, to: String)] {
        let fm = FileManager.default
        var moved: [(from: String, to: String)] = []
        guard let enumerator = fm.enumerator(atPath: motionTemplatesRoot) else { return moved }
        while let rel = enumerator.nextObject() as? String {
            let full = (motionTemplatesRoot as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = (rel as NSString).lastPathComponent
            // 仅处理以 .disabled 结尾的目录（严格长度断言，避免误伤用户同名目录）
            guard name.hasSuffix(".disabled"), name.count > 9 else { continue }
            // 必须是真实被禁用的模板目录：含 FCPX 模板主文件；否则视为 bundle 内部残留，跳过
            guard containsMotionFile(dirPath: full) else { continue }
            // 不在已禁用仓内（理论上不可能，双保险）
            guard isInScanTree(path: full) else { continue }
            let cleanName = String(name.dropLast(9))
            // 计算禁用仓目标：把相对路径末段替换为去后缀名
            let parentRel = (rel as NSString).deletingLastPathComponent
            let destRel = parentRel.isEmpty
                ? cleanName
                : (parentRel as NSString).appendingPathComponent(cleanName)
            let dest = "\(disabledRoot)/\(destRel)"
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) {
                continue
            }
            try fm.moveItem(atPath: full, toPath: dest)
            moved.append((from: full, to: dest))
        }
        return moved
    }

    /// 判定目录是否为被禁用的 FCPX 模板：其顶层或指向（符号链接）目录的顶层含 .moti/.moef/.motr/.motn
    private static func containsMotionFile(dirPath: String) -> Bool {
        let fm = FileManager.default
        let exts: Set<String> = ["moti", "moef", "motr", "motn"]
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return false }
        for entry in entries {
            let full = "\(dirPath)/\(entry)"
            let lower = (entry as NSString).pathExtension.lowercased()
            if exts.contains(lower) { return true }
            // 符号链接（如框架 Resources.disabled -> Versions/Current/Resources）：检查目标是否含模板主文件
            if let dest = try? fm.destinationOfSymbolicLink(atPath: full) {
                let target = dest.hasPrefix("/") ? dest : (dirPath as NSString).appendingPathComponent(dest)
                if let inner = try? fm.contentsOfDirectory(atPath: target) {
                    if inner.contains(where: { exts.contains(($0 as NSString).pathExtension.lowercased()) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// 列出禁用仓内所有被禁用的模板（供 app UI 呈现并支持重新启用）
    public static func listDisabled() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: disabledRoot) else { return [] }
        var result: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let full = (disabledRoot as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            if relativePathUnderCategory(for: full) != nil {
                result.append(full)
            }
        }
        return result.sorted()
    }
}
