import Foundation

// ═══════════════════════════════════════════════════════════════
//  PSDImportPlanner —— 拖放 / 菜单导入的纯规划层（R31 / A-61、A-62）
//
//  把「一堆路径」分类成：
//    · added            新收的 .psd（已去重、已排序）
//    · duplicates       已在列表中的
//    · rejected         非 .psd 文件 / 不存在的路径
//    · emptyDirectories 目录里没有 .psd
//
//  纯逻辑 + FileManager 只读，方便 harness 用临时目录直证。
//  UI 层（MainWindowController）只负责：追加、选中、渲染、弹提示。
// ═══════════════════════════════════════════════════════════════

public struct PSDImportPlan {
    public let added: [String]
    public let duplicates: [String]
    public let rejected: [String]
    public let emptyDirectories: [String]

    public var hasRejected: Bool { !rejected.isEmpty }
    public var hasEmptyDirectories: Bool { !emptyDirectories.isEmpty }
}

public enum PSDImportPlanner {

    public static func isPSD(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "psd"
    }

    public static func isFont(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["ttf", "otf", "ttc", "dfont"].contains(ext)
    }

    public static func plan(paths: [String], existing: [String]) -> PSDImportPlan {
        let fm = FileManager.default
        var added: [String] = []
        var duplicates: [String] = []
        var rejected: [String] = []
        var emptyDirs: [String] = []

        // 用标准化路径做去重键，保留展示用原路径
        var seen = Set(existing.map { normalize($0) })

        func appendPSD(_ path: String) {
            let key = normalize(path)
            if seen.contains(key) {
                duplicates.append(path)
                return
            }
            seen.insert(key)
            added.append(path)
        }

        for raw in paths {
            let path = normalize(raw)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                rejected.append(raw)
                continue
            }

            if isDir.boolValue {
                let found = scanDirectory(path)
                if found.isEmpty {
                    emptyDirs.append(path)
                } else {
                    found.forEach(appendPSD)
                }
            } else if isPSD(path) {
                appendPSD(path)
            } else {
                rejected.append(raw)
            }
        }

        return PSDImportPlan(added: added.sorted(), duplicates: duplicates,
                             rejected: rejected, emptyDirectories: emptyDirs)
    }

    /// 递归收集目录下的 .psd（跳过隐藏项与软链接目录，避免环）
    public static func scanDirectory(_ dir: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        guard let en = fm.enumerator(atPath: dir) else { return results }
        while let rel = en.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") {
                en.skipDescendants()
                continue
            }
            let full = "\(dir)/\(rel)"
            if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue { continue }
            if isPSD(full) { results.append(full) }
        }
        return results
    }

    public static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// 拖入时的快速可接受判断：.psd 文件、字体文件(.ttf/.otf/.ttc)，或任意目录（目录内容在落盘时再校验）
    public static func acceptsDrop(paths: [String]) -> Bool {
        let fm = FileManager.default
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if isDir.boolValue || isPSD(p) || isFont(p) { return true }
        }
        return false
    }
}
