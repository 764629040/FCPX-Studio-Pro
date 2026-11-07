import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  GhostPluginDoctor —— 幽灵插件智能体检与断链自愈医生引擎（白皮书建议 2）
//
//  三大病症深度扫描：
//    1. 悬空断链（Dangling Symlink）：外置盘拔掉或路径变动导致的悬空符号链接；
//    2. 破损 XML 模板（Corrupted XML）：0 字节、XML 解析失败或缺失根节点的破损工程；
//    3. 贴图媒体缺失（Missing Media）：模板引用但实际不存在的贴图/视频资源。
//
//  智能自愈与安全隔离：
//    - 模糊探测新盘符路径并秒级重建软链接（Relink）；
//    - 一键隔离破损模板至 _Quarantine 避免 FCPX 红屏与闪退；
//    - 支持一键还原（Restore）原路复原。
// ═══════════════════════════════════════════════════════════════

public enum GhostSymptom: String, Codable, CaseIterable {
    case danglingSymlink = "dangling_symlink"
    case corruptedXML = "corrupted_xml"
    case missingMedia = "missing_media"

    public var displayName: String {
        switch self {
        case .danglingSymlink: return "悬空断链"
        case .corruptedXML: return "破损 XML"
        case .missingMedia: return "贴图缺失"
        }
    }

    public var icon: String {
        switch self {
        case .danglingSymlink: return "🔗⚠️"
        case .corruptedXML: return "📄💥"
        case .missingMedia: return "🖼️❓"
        }
    }

    public var severityScore: Int {
        switch self {
        case .danglingSymlink: return 15
        case .corruptedXML: return 20
        case .missingMedia: return 10
        }
    }
}

public struct GhostIssue: Identifiable, Codable {
    public let id: String
    public let templateName: String
    public let category: String
    public let symptom: GhostSymptom
    public let path: String
    public let targetPath: String?
    public let detail: String
    public var suggestedFix: String
    public var canAutoRelink: Bool
    public var relinkCandidatePath: String?

    public init(id: String = UUID().uuidString,
                templateName: String,
                category: String,
                symptom: GhostSymptom,
                path: String,
                targetPath: String? = nil,
                detail: String,
                suggestedFix: String,
                canAutoRelink: Bool = false,
                relinkCandidatePath: String? = nil) {
        self.id = id
        self.templateName = templateName
        self.category = category
        self.symptom = symptom
        self.path = path
        self.targetPath = targetPath
        self.detail = detail
        self.suggestedFix = suggestedFix
        self.canAutoRelink = canAutoRelink
        self.relinkCandidatePath = relinkCandidatePath
    }
}

public struct QuarantineRecord: Identifiable, Codable {
    public let id: String
    public let originalPath: String
    public let quarantinePath: String
    public let templateName: String
    public let category: String
    public let symptom: GhostSymptom
    public let timestamp: Date

    public init(id: String = UUID().uuidString,
                originalPath: String,
                quarantinePath: String,
                templateName: String,
                category: String,
                symptom: GhostSymptom,
                timestamp: Date = Date()) {
        self.id = id
        self.originalPath = originalPath
        self.quarantinePath = quarantinePath
        self.templateName = templateName
        self.category = category
        self.symptom = symptom
        self.timestamp = timestamp
    }
}

public struct DoctorReport: Codable {
    public let scanDate: Date
    public let totalScanned: Int
    public let healthyCount: Int
    public let issues: [GhostIssue]
    public let danglingCount: Int
    public let corruptedXMLCount: Int
    public let missingMediaCount: Int
    public let healthScore: Int
    public let scoreRating: String
    public let quarantineRecords: [QuarantineRecord]

    public init(scanDate: Date = Date(),
                totalScanned: Int,
                healthyCount: Int,
                issues: [GhostIssue],
                quarantineRecords: [QuarantineRecord] = []) {
        self.scanDate = scanDate
        self.totalScanned = totalScanned
        self.healthyCount = healthyCount
        self.issues = issues
        self.quarantineRecords = quarantineRecords

        var dCount = 0
        var cCount = 0
        var mCount = 0
        var penalty = 0

        for issue in issues {
            switch issue.symptom {
            case .danglingSymlink:
                dCount += 1
                penalty += issue.symptom.severityScore
            case .corruptedXML:
                cCount += 1
                penalty += issue.symptom.severityScore
            case .missingMedia:
                mCount += 1
                penalty += issue.symptom.severityScore
            }
        }

        self.danglingCount = dCount
        self.corruptedXMLCount = cCount
        self.missingMediaCount = mCount

        let rawScore = max(0, 100 - penalty)
        self.healthScore = rawScore

        if rawScore >= 100 {
            self.scoreRating = "🟢 运行良好 (100分)"
        } else if rawScore >= 80 {
            self.scoreRating = "🟡 良好警告 (\(rawScore)分)"
        } else {
            self.scoreRating = "🔴 严重高危 (\(rawScore)分)"
        }
    }
}

public final class GhostPluginDoctor {
    public static let shared = GhostPluginDoctor()

    private let lock = NSRecursiveLock()
    private let fm = FileManager.default

    public var customQuarantineDir: String? = nil
    public var additionalSearchRoots: [String] = []

    public var quarantineBaseDirectory: String {
        if let custom = customQuarantineDir {
            return custom
        }
        let home = fm.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Movies/Motion Templates.localized/_Quarantine").path
    }

    private var ledgerFilePath: String {
        return URL(fileURLWithPath: quarantineBaseDirectory).appendingPathComponent("quarantine_ledger.json").path
    }

    public init() {}

    // MARK: – 扫描诊断 (Scan Engine)

    public func scan(customRoots: [String]? = nil) -> DoctorReport {
        lock.lock()
        defer { lock.unlock() }

        let rootsToScan: [String]
        if let roots = customRoots, !roots.isEmpty {
            rootsToScan = roots
        } else {
            rootsToScan = resolveDefaultRoots()
        }

        var scannedCount = 0
        var detectedIssues: [GhostIssue] = []

        for root in rootsToScan {
            guard fm.fileExists(atPath: root) else { continue }
            scanDirectory(rootPath: root, currentCategory: (root as NSString).lastPathComponent,
                          scannedCount: &scannedCount, issues: &detectedIssues)
        }

        let quarantineRecords = loadQuarantineLedger()
        let healthy = max(0, scannedCount - detectedIssues.count)

        let report = DoctorReport(
            scanDate: Date(),
            totalScanned: scannedCount,
            healthyCount: healthy,
            issues: detectedIssues,
            quarantineRecords: quarantineRecords
        )

        return report
    }

    public func scanAsync(customRoots: [String]? = nil, completion: @escaping (DoctorReport) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let report = self.scan(customRoots: customRoots)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    private func resolveDefaultRoots() -> [String] {
        var roots: [String] = []
        let home = fm.homeDirectoryForCurrentUser
        let userBase = home.appendingPathComponent("Movies/Motion Templates.localized")
        let categories = ["Titles.localized", "Effects.localized", "Transitions.localized", "Generators.localized"]

        for cat in categories {
            roots.append(userBase.appendingPathComponent(cat).path)
        }

        let sysBase = URL(fileURLWithPath: "/Library/Application Support/Final Cut Pro/Templates.localized")
        for cat in categories {
            roots.append(sysBase.appendingPathComponent(cat).path)
        }

        return roots
    }

    private func scanDirectory(rootPath: String,
                              currentCategory: String,
                              scannedCount: inout Int,
                              issues: inout [GhostIssue]) {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
            let path = fileURL.path
            let fileName = fileURL.lastPathComponent

            // 忽略隔离区自身
            if path.contains("/_Quarantine") || path.contains("/.Quarantine") {
                enumerator.skipDescendants()
                continue
            }

            // 1. 检查悬空符号链接 (Dangling Symlink)
            if isSymbolicLink(atPath: path) {
                scannedCount += 1
                let dest = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
                let resolved = resolveSymlinkDestination(linkPath: path, destination: dest)

                if !fm.fileExists(atPath: resolved) {
                    // 悬空断链！寻找自愈候选路径
                    let candidate = findRelinkCandidate(targetPath: resolved, templateName: fileName)
                    let issue = GhostIssue(
                        templateName: fileName,
                        category: currentCategory,
                        symptom: .danglingSymlink,
                        path: path,
                        targetPath: dest,
                        detail: "软链接指向目标不存在: \(dest)",
                        suggestedFix: candidate != nil ? "探测到有效位置: \(candidate!)，支持一键重连" : "目标盘未挂载，建议安全隔离",
                        canAutoRelink: candidate != nil,
                        relinkCandidatePath: candidate
                    )
                    issues.append(issue)
                    // 悬空软链接无需再遍历其内部
                    continue
                }
            }

            // 2. 检查 Motion XML 模板文件 (.moti, .moef, .motr, .motn)
            let ext = fileURL.pathExtension.lowercased()
            if ["moti", "moef", "motr", "motn"].contains(ext) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }

                scannedCount += 1
                let templateDir = fileURL.deletingLastPathComponent().path
                let tName = fileURL.deletingPathExtension().lastPathComponent

                // 2.1 检查 0 字节或破损 XML
                let fileSize = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                if fileSize == 0 {
                    let issue = GhostIssue(
                        templateName: tName,
                        category: currentCategory,
                        symptom: .corruptedXML,
                        path: path,
                        targetPath: nil,
                        detail: "XML 模板文件尺寸为 0 字节，无法解析",
                        suggestedFix: "一键安全隔离至 _Quarantine 避免红屏",
                        canAutoRelink: false
                    )
                    issues.append(issue)
                    continue
                }

                // 2.2 检查 XML 语法合法性与根节点
                guard let xmlData = try? Data(contentsOf: fileURL),
                      let xmlDoc = try? XMLDocument(data: xmlData, options: []),
                      let rootElem = xmlDoc.rootElement(),
                      !rootElem.name.isNilOrEmpty else {
                    let issue = GhostIssue(
                        templateName: tName,
                        category: currentCategory,
                        symptom: .corruptedXML,
                        path: path,
                        targetPath: nil,
                        detail: "XML 解析错误或缺少合法根节点，模板已损毁",
                        suggestedFix: "一键安全隔离至 _Quarantine 避免红屏",
                        canAutoRelink: false
                    )
                    issues.append(issue)
                    continue
                }

                // 2.3 检查媒体贴图断链 (Missing Media)
                let missingMedias = checkMissingMedia(xmlDoc: xmlDoc, xmlString: String(data: xmlData, encoding: .utf8) ?? "", templateDir: templateDir)
                if !missingMedias.isEmpty {
                    let detailMsg = "引用的 \(missingMedias.count) 项媒体贴图缺失: " + missingMedias.joined(separator: ", ")
                    let issue = GhostIssue(
                        templateName: tName,
                        category: currentCategory,
                        symptom: .missingMedia,
                        path: path,
                        targetPath: missingMedias.first,
                        detail: detailMsg,
                        suggestedFix: "媒体资源缺失，建议补齐 Media/ 或一键隔离",
                        canAutoRelink: false
                    )
                    issues.append(issue)
                }
            }
        }
    }

    private func isSymbolicLink(atPath path: String) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return false }
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func resolveSymlinkDestination(linkPath: String, destination: String) -> String {
        if (destination as NSString).isAbsolutePath {
            return (destination as NSString).standardizingPath
        }
        let parent = (linkPath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: parent).appendingPathComponent(destination).standardized.path
    }

    // MARK: – 媒体贴图检测 (Missing Media)

    private func checkMissingMedia(xmlDoc: XMLDocument, xmlString: String, templateDir: String) -> [String] {
        var missing: [String] = []

        // 提取 <fileURL>...</fileURL>
        let fileUrlPattern = try? NSRegularExpression(pattern: "<fileURL>(.*?)</fileURL>", options: .caseInsensitive)
        let matches = fileUrlPattern?.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString)) ?? []

        for match in matches {
            guard let range = Range(match.range(at: 1), in: xmlString) else { continue }
            let rawUrl = String(xmlString[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawUrl.isEmpty { continue }

            var localPath = rawUrl
            if localPath.hasPrefix("file://") {
                if let url = URL(string: localPath) {
                    localPath = url.path
                } else {
                    localPath = localPath.replacingOccurrences(of: "file://localhost", with: "")
                        .replacingOccurrences(of: "file://", with: "")
                }
            }

            // 检查相对路径与绝对路径
            let candidate1 = URL(fileURLWithPath: templateDir).appendingPathComponent(localPath).path
            let candidate2 = URL(fileURLWithPath: templateDir).appendingPathComponent("Media").appendingPathComponent((localPath as NSString).lastPathComponent).path

            if !fm.fileExists(atPath: localPath) && !fm.fileExists(atPath: candidate1) && !fm.fileExists(atPath: candidate2) {
                missing.append((localPath as NSString).lastPathComponent)
            }
        }

        // 检查 <footage ... src="..." file="...">
        let footagePattern = try? NSRegularExpression(pattern: "<footage[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive)
        let fMatches = footagePattern?.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString)) ?? []
        for match in fMatches {
            guard let range = Range(match.range(at: 1), in: xmlString) else { continue }
            let src = String(xmlString[range])
            let fn = (src as NSString).lastPathComponent
            let p1 = URL(fileURLWithPath: templateDir).appendingPathComponent("Media").appendingPathComponent(fn).path
            let p2 = URL(fileURLWithPath: templateDir).appendingPathComponent(src).path
            if !fm.fileExists(atPath: p1) && !fm.fileExists(atPath: p2) && !fm.fileExists(atPath: src) {
                if !missing.contains(fn) {
                    missing.append(fn)
                }
            }
        }

        // 检查 Media/ 目录是否存在但内部引用为空
        let mediaDir = URL(fileURLWithPath: templateDir).appendingPathComponent("Media").path
        if fm.fileExists(atPath: mediaDir) {
            if let files = try? fm.contentsOfDirectory(atPath: mediaDir) {
                for f in files where !f.hasPrefix(".") {
                    let fp = (mediaDir as NSString).appendingPathComponent(f)
                    if let sz = try? fm.attributesOfItem(atPath: fp)[.size] as? UInt64, sz == 0 {
                        if !missing.contains(f) {
                            missing.append("\(f) (0字节损坏)")
                        }
                    }
                }
            }
        }

        return missing
    }

    // MARK: – 智能自愈与重连 (Self-Healing Relink)

    public func findRelinkCandidate(targetPath: String, templateName: String) -> String? {
        // 1. 尝试在当前所有挂载卷中探测
        var candidateVolumes: [String] = []
        if let mounted = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for v in mounted {
                candidateVolumes.append("/Volumes/\(v)")
            }
        }
        for root in additionalSearchRoots {
            if !candidateVolumes.contains(root) {
                candidateVolumes.append(root)
            }
        }

        // 提取原盘路径中的相对尾缀，如 /Volumes/OldSSD/Templates/TitleA -> Templates/TitleA
        let pathComponents = (targetPath as NSString).pathComponents
        if pathComponents.count >= 3 && pathComponents[1] == "Volumes" {
            let subComponents = pathComponents.dropFirst(3) // 去掉 /, Volumes, DiskName
            let relativeSub = subComponents.joined(separator: "/")

            for vol in candidateVolumes {
                let candidate = (vol as NSString).appendingPathComponent(relativeSub)
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }

        // 2. 按模板名称在挂载卷中进行匹配探测
        for vol in candidateVolumes {
            let candidateDirect = (vol as NSString).appendingPathComponent(templateName)
            if fm.fileExists(atPath: candidateDirect) {
                return candidateDirect
            }

            let searchDirs = [
                "Movies/Motion Templates.localized",
                "Motion Templates.localized",
                "FCPX_Templates"
            ]
            for sd in searchDirs {
                let probe = URL(fileURLWithPath: vol).appendingPathComponent(sd).path
                if fm.fileExists(atPath: probe) {
                    if let subs = try? fm.subpathsOfDirectory(atPath: probe) {
                        for sub in subs where (sub as NSString).lastPathComponent == templateName {
                            let matchPath = (probe as NSString).appendingPathComponent(sub)
                            if fm.fileExists(atPath: matchPath) {
                                return matchPath
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    public func relink(issue: GhostIssue, candidatePath: String? = nil) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let target = candidatePath ?? issue.relinkCandidatePath ?? findRelinkCandidate(targetPath: issue.targetPath ?? "", templateName: issue.templateName) else {
            return false
        }

        guard fm.fileExists(atPath: target) else {
            return false
        }

        // 删除旧的断链软链接
        if isSymbolicLink(atPath: issue.path) || fm.fileExists(atPath: issue.path) {
            try fm.removeItem(atPath: issue.path)
        }

        // 重建指向新有效位置的软链接
        try fm.createSymbolicLink(atPath: issue.path, withDestinationPath: target)
        return true
    }

    public func relinkAll(issues: [GhostIssue]) -> (successCount: Int, failedCount: Int) {
        var success = 0
        var failed = 0

        for issue in issues where issue.symptom == .danglingSymlink {
            do {
                if try relink(issue: issue) {
                    success += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }

        return (success, failed)
    }

    // MARK: – 安全隔离区 (Safe Quarantine)

    public func quarantine(issue: GhostIssue) throws -> QuarantineRecord {
        lock.lock()
        defer { lock.unlock() }

        let qDir = quarantineBaseDirectory
        if !fm.fileExists(atPath: qDir) {
            try fm.createDirectory(atPath: qDir, withIntermediateDirectories: true)
        }

        let timestampStr = Int(Date().timeIntervalSince1970)
        let destName = "\(issue.category)_\(issue.templateName)_\(timestampStr)"
        let destPath = (qDir as NSString).appendingPathComponent(destName)

        // 移入隔离区
        if fm.fileExists(atPath: issue.path) || isSymbolicLink(atPath: issue.path) {
            try fm.moveItem(atPath: issue.path, toPath: destPath)
        }

        let record = QuarantineRecord(
            originalPath: issue.path,
            quarantinePath: destPath,
            templateName: issue.templateName,
            category: issue.category,
            symptom: issue.symptom,
            timestamp: Date()
        )

        var ledger = loadQuarantineLedger()
        ledger.append(record)
        saveQuarantineLedger(ledger)

        return record
    }

    public func quarantineAll(issues: [GhostIssue]) -> (quarantined: Int, failed: Int) {
        var success = 0
        var failed = 0

        for issue in issues {
            do {
                _ = try quarantine(issue: issue)
                success += 1
            } catch {
                failed += 1
            }
        }

        return (success, failed)
    }

    public func restore(recordId: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var ledger = loadQuarantineLedger()
        guard let idx = ledger.firstIndex(where: { $0.id == recordId }) else {
            return false
        }

        let record = ledger[idx]
        guard fm.fileExists(atPath: record.quarantinePath) || isSymbolicLink(atPath: record.quarantinePath) else {
            return false
        }

        let origDir = (record.originalPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: origDir) {
            try fm.createDirectory(atPath: origDir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: record.originalPath) {
            try fm.removeItem(atPath: record.originalPath)
        }

        try fm.moveItem(atPath: record.quarantinePath, toPath: record.originalPath)

        ledger.remove(at: idx)
        saveQuarantineLedger(ledger)
        return true
    }

    public func restoreAll() -> (restored: Int, failed: Int) {
        let ledger = loadQuarantineLedger()
        var success = 0
        var failed = 0

        for item in ledger {
            do {
                if try restore(recordId: item.id) {
                    success += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }

        return (success, failed)
    }

    // MARK: – 隔离账本存储

    public func loadQuarantineLedger() -> [QuarantineRecord] {
        let path = ledgerFilePath
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let list = try? JSONDecoder().decode([QuarantineRecord].self, from: data) else {
            return []
        }
        return list
    }

    private func saveQuarantineLedger(_ records: [QuarantineRecord]) {
        let path = ledgerFilePath
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(records) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        guard let str = self else { return true }
        return str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
