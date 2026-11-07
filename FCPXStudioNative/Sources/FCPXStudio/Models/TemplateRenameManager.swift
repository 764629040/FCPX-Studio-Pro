import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  TemplateRenameManager.swift —— FCPX 模板多语言与中文友好本地化重命名引擎
//  对标基准：/Applications/嘉星插件管理 2.app (TemplateRenameManager / TemplateStringsMutationWriter)
//
//  核心职责：
//    1. 读取 Motion 模板在 FCPX 内部呈现的本地化中文别名；
//    2. 安全创建/更新 `.localized/zh_CN.strings` 与 `zh-Hans.strings` 字典映射；
//    3. 规范写入标准 Apple .strings 键值对，保留原字典其他条目；
//    4. 绝不触动底层 Motion 文件物理路径与 XML 内部引用 ID，彻底杜绝 FCPX 红色感叹号断链！
// ═══════════════════════════════════════════════════════════════

public final class TemplateRenameManager {
    public static let shared = TemplateRenameManager()

    private let fileManager = FileManager.default
    private var stringsFileCache: [String: [String: String]] = [:]
    private var negativeStringsPathCache: Set<String> = []
    private var displayNameCache: [String: String] = [:]
    private let cacheLock = NSLock()

    public init() {}

    // MARK: – 读取本地化名称

    /// 获取模板在指定语言下的友好显示名（默认优先检索 zh_CN / zh-Hans 中文）
    public func getDisplayName(for item: TemplateItem, language: String = "zh_CN") -> String {
        let cacheKey = "\(item.path)#\(language)"
        cacheLock.lock()
        if let cached = displayNameCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let name: String
        if let alias = getLocalizedName(templatePath: item.path, templateName: item.name, language: language),
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = alias
        } else {
            name = item.name
        }

        cacheLock.lock()
        displayNameCache[cacheKey] = name
        cacheLock.unlock()
        return name
    }

    /// 检索指定模板是否存在本地化别名
    public func getLocalizedName(templatePath: String,
                                 templateName: String,
                                 language: String = "zh_CN") -> String? {
        let candidateLanguages = languageAliases(for: language)

        // 1. 优先探测模板自身包内部的 `.localized/<lang>.strings`
        let templateDirURL = URL(fileURLWithPath: templatePath)
        for lang in candidateLanguages {
            let directStringsURL = templateDirURL
                .appendingPathComponent(".localized", isDirectory: true)
                .appendingPathComponent("\(lang).strings")
            if let dict = parseStringsFile(at: directStringsURL) {
                if let val = dict[templateName], !val.isEmpty {
                    return val
                }
            }
        }

        // 2. 探测模板所属分类父目录下的 `.localized/<lang>.strings`
        let parentDirURL = templateDirURL.deletingLastPathComponent()
        for lang in candidateLanguages {
            let parentStringsURL = parentDirURL
                .appendingPathComponent(".localized", isDirectory: true)
                .appendingPathComponent("\(lang).strings")
            if let dict = parseStringsFile(at: parentStringsURL),
               let val = dict[templateName], !val.isEmpty {
                return val
            }
        }

        return nil
    }

    // MARK: – 设置与写入本地化中文别名

    /// 为指定模板设置友好中文别名（对标嘉星 `applyLocalizedStringsMutationAtFile`）
    /// - Parameters:
    ///   - newAlias: 友好中文名（如“中式婚礼优雅字幕”）
    ///   - item: 目标模板对象
    ///   - language: 语言代码（默认 "zh_CN"）
    @discardableResult
    public func setLocalizedName(newAlias: String,
                                 for item: TemplateItem,
                                 language: String = "zh_CN") throws -> Bool {
        return try setLocalizedName(newAlias: newAlias,
                                    templatePath: item.path,
                                    templateName: item.name,
                                    language: language)
    }

    /// 为指定模板路径写入 .strings 映射
    @discardableResult
    public func setLocalizedName(newAlias: String,
                                 templatePath: String,
                                 templateName: String,
                                 language: String = "zh_CN") throws -> Bool {
        let cleanAlias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty else {
            // 如果传入空字符串，执行别名清除
            return try removeLocalizedName(templatePath: templatePath,
                                           templateName: templateName,
                                           language: language)
        }

        let targetLanguages = languageAliases(for: language)
        let templateDirURL = URL(fileURLWithPath: templatePath)
        let localizedDirURL = templateDirURL.appendingPathComponent(".localized", isDirectory: true)

        // 确保 .localized 目录存在
        if !fileManager.fileExists(atPath: localizedDirURL.path) {
            try fileManager.createDirectory(at: localizedDirURL, withIntermediateDirectories: true, attributes: nil)
        }

        var writeSuccess = false

        // 同步写入 zh_CN.strings 与 zh-Hans.strings，确保不同 macOS 系统区域设置都能完美识别
        for lang in targetLanguages {
            let stringsURL = localizedDirURL.appendingPathComponent("\(lang).strings")
            var dict = parseStringsFile(at: stringsURL) ?? [:]
            dict[templateName] = cleanAlias

            try writeStringsFile(dict: dict, to: stringsURL)
            writeSuccess = true
        }

        // 同时智能尝试在所属分类父目录中也挂载映射（嘉星兼容特性）
        let parentDirURL = templateDirURL.deletingLastPathComponent()
        let parentLocalizedURL = parentDirURL.appendingPathComponent(".localized", isDirectory: true)
        if fileManager.fileExists(atPath: parentLocalizedURL.path) {
            for lang in targetLanguages {
                let parentStringsURL = parentLocalizedURL.appendingPathComponent("\(lang).strings")
                if fileManager.fileExists(atPath: parentStringsURL.path) {
                    var dict = parseStringsFile(at: parentStringsURL) ?? [:]
                    dict[templateName] = cleanAlias
                    try? writeStringsFile(dict: dict, to: parentStringsURL)
                }
            }
        }

        AssetCacheManager.shared.invalidateTemplates()
        cacheLock.lock()
        stringsFileCache.removeAll()
        negativeStringsPathCache.removeAll()
        displayNameCache.removeAll()
        cacheLock.unlock()
        return writeSuccess
    }

    /// 移除指定模板的本地化别名，恢复原始英文显示
    @discardableResult
    public func removeLocalizedName(for item: TemplateItem, language: String = "zh_CN") throws -> Bool {
        return try removeLocalizedName(templatePath: item.path, templateName: item.name, language: language)
    }

    /// 移除指定模板的本地化别名，恢复原始英文显示
    @discardableResult
    public func removeLocalizedName(templatePath: String,
                                    templateName: String,
                                    language: String = "zh_CN") throws -> Bool {
        let targetLanguages = languageAliases(for: language)
        let templateDirURL = URL(fileURLWithPath: templatePath)
        let localizedDirURL = templateDirURL.appendingPathComponent(".localized", isDirectory: true)

        var modified = false

        for lang in targetLanguages {
            let stringsURL = localizedDirURL.appendingPathComponent("\(lang).strings")
            if var dict = parseStringsFile(at: stringsURL) {
                if dict.removeValue(forKey: templateName) != nil {
                    try writeStringsFile(dict: dict, to: stringsURL)
                    modified = true
                }
            }
        }

        let parentDirURL = templateDirURL.deletingLastPathComponent()
        let parentLocalizedURL = parentDirURL.appendingPathComponent(".localized", isDirectory: true)
        for lang in targetLanguages {
            let parentStringsURL = parentLocalizedURL.appendingPathComponent("\(lang).strings")
            if var dict = parseStringsFile(at: parentStringsURL) {
                if dict.removeValue(forKey: templateName) != nil {
                    try? writeStringsFile(dict: dict, to: parentStringsURL)
                    modified = true
                }
            }
        }

        if modified {
            AssetCacheManager.shared.invalidateTemplates()
            cacheLock.lock()
            stringsFileCache.removeAll()
            negativeStringsPathCache.removeAll()
            displayNameCache.removeAll()
            cacheLock.unlock()
        }
        return modified
    }

    // MARK: – 规范 .strings 解析与安全写入器 (TemplateStringsMutationWriter)

    /// 解析指定 URL 的 .strings 文件（支持标准 Apple .strings 与 XML Plist 两种常见格式）
    public func parseStringsFile(at url: URL) -> [String: String]? {
        let path = url.path
        cacheLock.lock()
        if let cached = stringsFileCache[path] {
            cacheLock.unlock()
            return cached
        }
        if negativeStringsPathCache.contains(path) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        guard fileManager.fileExists(atPath: path) else {
            cacheLock.lock()
            negativeStringsPathCache.insert(path)
            cacheLock.unlock()
            return nil
        }

        // 尝试作为 PropertyList 读取
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: String] {
            cacheLock.lock()
            stringsFileCache[path] = dict
            cacheLock.unlock()
            return dict
        }

        // 尝试以 UTF-8 或 UTF-16 文本解析标准 "key" = "value"; 语法
        guard let content = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16)) else {
            cacheLock.lock()
            negativeStringsPathCache.insert(path)
            cacheLock.unlock()
            return nil
        }

        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)

        // 匹配 "key" = "value"; 格式
        let pattern = #"^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
                continue
            }
            let nsLine = trimmed as NSString
            let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsLine.length))
            if let match = matches.first, match.numberOfRanges >= 3 {
                let keyRange = match.range(at: 1)
                let valRange = match.range(at: 2)
                let key = nsLine.substring(with: keyRange)
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                let val = nsLine.substring(with: valRange)
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                result[key] = val
            }
        }

        cacheLock.lock()
        stringsFileCache[path] = result
        cacheLock.unlock()
        return result
    }

    /// 规范写回标准 .strings 文件
    public func writeStringsFile(dict: [String: String], to url: URL) throws {
        var outputLines: [String] = []
        outputLines.append("/* FCPX Studio Pro 本地化字典 (自动对标 FCPX / Motion 规范) */")
        outputLines.append("/* 物理文件夹或工程 ID 保持不变，仅在 FCPX 字幕/效果浏览器呈现亲切中文名 */\n")

        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let escapedKey = k.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedVal = v.replacingOccurrences(of: "\"", with: "\\\"")
            outputLines.append("\"\(escapedKey)\" = \"\(escapedVal)\";")
        }

        let fullContent = outputLines.joined(separator: "\n") + "\n"
        guard let data = fullContent.data(using: .utf8) else {
            throw NSError(domain: "TemplateRenameManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "编码 UTF-8 数据失败"])
        }

        try data.write(to: url, options: .atomic)
    }

    // MARK: – 语言代码别名映射

    private func languageAliases(for language: String) -> [String] {
        if language == "zh_CN" || language == "zh-Hans" || language == "zh" {
            return ["zh_CN", "zh-Hans"]
        }
        return [language]
    }
}
