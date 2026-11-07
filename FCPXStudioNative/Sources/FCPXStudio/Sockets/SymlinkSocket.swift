import Foundation

public struct PluginItem {
    public let name: String
    public let category: String
    public let isSymlink: Bool
    public let targetPath: String
    public let sizeMB: Double
}

public protocol SymlinkSocketProtocol {
    func linkToSystem(category: String, groupName: String, externalRoot: String) -> (Bool, String)
    func listInstalled(category: String) -> [PluginItem]
    func migrateToExternal(category: String, groupName: String, externalRoot: String) -> (Bool, String)
}

public final class SymlinkSocket: SymlinkSocketProtocol {
    public static let shared = SymlinkSocket()
    private let systemMotionRoot = NSString(string: "~/Movies/Motion Templates.localized").expandingTildeInPath

    public init() {}

    public func linkToSystem(category: String, groupName: String, externalRoot: String) -> (Bool, String) {
        let externalTarget = "\(externalRoot)/\(category)/\(groupName)"
        let systemLink = "\(systemMotionRoot)/\(category)/\(groupName)"

        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: externalTarget, isDirectory: &isDir) {
            return (false, "外置目标不存在: \(externalTarget)")
        }

        // 确保系统目录存在
        let sysCat = "\(systemMotionRoot)/\(category)"
        try? FileManager.default.createDirectory(atPath: sysCat, withIntermediateDirectories: true)

        // 检查软链
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: systemLink) {
            if dest == externalTarget {
                return (true, "已正确挂载")
            } else {
                try? FileManager.default.removeItem(atPath: systemLink)
            }
        }

        do {
            try FileManager.default.createSymbolicLink(atPath: systemLink, withDestinationPath: externalTarget)
            return (true, "成功创建软链接 -> \(systemLink)")
        } catch {
            return (false, "创建失败: \(error.localizedDescription)")
        }
    }

    public func listInstalled(category: String) -> [PluginItem] {
        let sysCat = "\(systemMotionRoot)/\(category)"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: sysCat) else {
            return []
        }

        var results: [PluginItem] = []
        for item in items.sorted() {
            if item.hasPrefix(".") || item.hasPrefix("Icon") { continue }
            let fullPath = "\(sysCat)/\(item)"
            var isSymlink = false
            var target = fullPath
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: fullPath) {
                isSymlink = true
                target = dest
            }

            var totalBytes: Int64 = 0
            if let enumerator = FileManager.default.enumerator(atPath: target) {
                while let file = enumerator.nextObject() as? String {
                    let fp = "\(target)/\(file)"
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fp) {
                        totalBytes += (attrs[.size] as? Int64) ?? 0
                    }
                }
            }

            let sizeMB = Double(totalBytes) / (1024.0 * 1024.0)
            results.append(PluginItem(name: item, category: category, isSymlink: isSymlink, targetPath: target, sizeMB: round(sizeMB * 10) / 10.0))
        }
        return results
    }

    public func migrateToExternal(category: String, groupName: String, externalRoot: String) -> (Bool, String) {
        let systemPath = "\(systemMotionRoot)/\(category)/\(groupName)"
        let externalTarget = "\(externalRoot)/\(category)/\(groupName)"

        guard FileManager.default.fileExists(atPath: systemPath) else {
            return (false, "系统目录不存在")
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: systemPath)) != nil {
            return (true, "已是外置软链")
        }

        try? FileManager.default.createDirectory(atPath: "\(externalRoot)/\(category)", withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(atPath: systemPath, toPath: externalTarget)
            try FileManager.default.createSymbolicLink(atPath: systemPath, withDestinationPath: externalTarget)
            return (true, "成功搬家并挂载软链接")
        } catch {
            return (false, "搬家失败: \(error.localizedDescription)")
        }
    }
}
