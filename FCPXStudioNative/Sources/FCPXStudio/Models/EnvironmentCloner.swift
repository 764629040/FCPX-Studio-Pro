import AppKit
import Foundation
import CryptoKit

// ═══════════════════════════════════════════════════════════════
//  EnvironmentCloner —— 生产环境一键克隆打包器（R44 对标白皮书建议 3）
//
//  核心技术规格：
//    1. 一键归档：将指定的模板分类（Titles/Effects/Transitions/Generators）、
//       3D LUT 调色库与工作区情境隔离配置打包为标准 .fcpxpack（ZIP 规范归档包）
//    2. 携带全局 manifest.json 清单、时间戳、SHA-256 校验和与元数据统计
//    3. 目标机一键导入部署：支持覆盖（Overwrite）、跳过（Skip）与共存（KeepBoth）策略
//    4. 环境解耦与沙箱隔离：支持 FCPXSTUDIO_USER_TEMPLATES_ROOT、FCPXSTUDIO_LUTS_DIR
//       与 FCPXSTUDIO_PROFILES_DIR，支持完整单机多环境直证
// ═══════════════════════════════════════════════════════════════

public enum ConflictPolicy: String, Codable, CaseIterable {
    case overwrite = "覆盖现有"
    case skip = "跳过冲突"
    case keepBoth = "保留两者"
}

public struct CloneManifest: Codable {
    public var version: String
    public var createdAt: String
    public var generatorName: String
    public var categories: [String]
    public var templateCount: Int
    public var includeLUTs: Bool
    public var lutCount: Int
    public var includeProfiles: Bool
    public var profileCount: Int
    public var templateFiles: [String]
    public var lutFiles: [String]
    public var profileFiles: [String]
    public var totalSizeBytes: Int64
    public var sha256: String

    public init(version: String = "1.0.0",
                createdAt: String = ISO8601DateFormatter().string(from: Date()),
                generatorName: String = "FCPX Studio Pro Environment Cloner",
                categories: [String],
                templateCount: Int,
                includeLUTs: Bool,
                lutCount: Int,
                includeProfiles: Bool,
                profileCount: Int,
                templateFiles: [String],
                lutFiles: [String],
                profileFiles: [String],
                totalSizeBytes: Int64 = 0,
                sha256: String = "") {
        self.version = version
        self.createdAt = createdAt
        self.generatorName = generatorName
        self.categories = categories
        self.templateCount = templateCount
        self.includeLUTs = includeLUTs
        self.lutCount = lutCount
        self.includeProfiles = includeProfiles
        self.profileCount = profileCount
        self.templateFiles = templateFiles
        self.lutFiles = lutFiles
        self.profileFiles = profileFiles
        self.totalSizeBytes = totalSizeBytes
        self.sha256 = sha256
    }
}

public struct ImportSummary: Codable {
    public var success: Bool
    public var installedTemplatesCount: Int
    public var installedLUTsCount: Int
    public var installedProfilesCount: Int
    public var skippedCount: Int
    public var totalInstalled: Int
    public var details: [String]

    public init(success: Bool,
                installedTemplatesCount: Int,
                installedLUTsCount: Int,
                installedProfilesCount: Int,
                skippedCount: Int,
                details: [String] = []) {
        self.success = success
        self.installedTemplatesCount = installedTemplatesCount
        self.installedLUTsCount = installedLUTsCount
        self.installedProfilesCount = installedProfilesCount
        self.skippedCount = skippedCount
        self.totalInstalled = installedTemplatesCount + installedLUTsCount + installedProfilesCount
        self.details = details
    }
}

public enum EnvironmentClonerError: Error, LocalizedError {
    case stagingFailed(String)
    case packagingFailed(String)
    case invalidPackage(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .stagingFailed(let msg):
            return "临时暂存区构建失败：\(msg)"
        case .packagingFailed(let msg):
            return "归档打包失败：\(msg)"
        case .invalidPackage(let msg):
            return "无效的克隆包文件：\(msg)"
        case .ioError(let msg):
            return "文件读写 I/O 错误：\(msg)"
        }
    }
}

public final class EnvironmentCloner {
    public static let shared = EnvironmentCloner()

    public init() {}

    // MARK: – 路径解析
    public var userTemplatesRoot: String {
        return TemplateTierRoots.resolve().user
    }

    public var lutsRoot: String {
        if let env = ProcessInfo.processInfo.environment["FCPXSTUDIO_LUTS_DIR"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return LUTManager.shared.defaultSearchPaths.first ?? ("~/Library/Application Support/ProApps/Camera LUTs" as NSString).expandingTildeInPath
    }

    public var profilesDirectory: String {
        return WorkspaceProfileManager.profilesDirectory
    }

    // MARK: – 导出克隆包 (.fcpxpack)
    @discardableResult
    public func exportPackage(categories: [String],
                              includeLUTs: Bool,
                              includeProfiles: Bool,
                              outputPath: String) throws -> CloneManifest {
        let fm = FileManager.default
        let stagingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPX_CloneStaging_\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: stagingDir) }

        try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)

        var templateFilesList: [String] = []
        var lutFilesList: [String] = []
        var profileFilesList: [String] = []

        // 1. 打包选定的模板分类
        let templatesStaging = (stagingDir as NSString).appendingPathComponent("Templates")
        try fm.createDirectory(atPath: templatesStaging, withIntermediateDirectories: true)

        let userRoot = self.userTemplatesRoot
        for cat in categories {
            let catPath = (userRoot as NSString).appendingPathComponent(cat)
            guard fm.fileExists(atPath: catPath) else { continue }

            let targetCatStaging = (templatesStaging as NSString).appendingPathComponent(cat)
            try fm.createDirectory(atPath: targetCatStaging, withIntermediateDirectories: true)

            guard let subcats = try? fm.contentsOfDirectory(atPath: catPath) else { continue }
            for subcat in subcats {
                if subcat.hasPrefix(".") || subcat == "__MACOSX" { continue }
                let subcatPath = (catPath as NSString).appendingPathComponent(subcat)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subcatPath, isDirectory: &isDir), isDir.boolValue else { continue }

                let targetSubcatStaging = (targetCatStaging as NSString).appendingPathComponent(subcat)
                try fm.createDirectory(atPath: targetSubcatStaging, withIntermediateDirectories: true)

                guard let templates = try? fm.contentsOfDirectory(atPath: subcatPath) else { continue }
                for tmpl in templates {
                    if tmpl.hasPrefix(".") || tmpl == "__MACOSX" { continue }
                    let tmplPath = (subcatPath as NSString).appendingPathComponent(tmpl)
                    let dstPath = (targetSubcatStaging as NSString).appendingPathComponent(tmpl)
                    try fm.copyItem(atPath: tmplPath, toPath: dstPath)
                    templateFilesList.append("\(cat)/\(subcat)/\(tmpl)")
                }
            }
        }

        // 2. 打包 3D LUT
        if includeLUTs {
            let lutsStaging = (stagingDir as NSString).appendingPathComponent("LUTs")
            try fm.createDirectory(atPath: lutsStaging, withIntermediateDirectories: true)

            let lutSrc = self.lutsRoot
            if fm.fileExists(atPath: lutSrc), let files = try? fm.contentsOfDirectory(atPath: lutSrc) {
                for f in files {
                    if f.lowercased().hasSuffix(".cube") {
                        let srcPath = (lutSrc as NSString).appendingPathComponent(f)
                        let dstPath = (lutsStaging as NSString).appendingPathComponent(f)
                        try fm.copyItem(atPath: srcPath, toPath: dstPath)
                        lutFilesList.append(f)
                    }
                }
            }
        }

        // 3. 打包工作区情境隔离配置
        if includeProfiles {
            let profilesStaging = (stagingDir as NSString).appendingPathComponent("Profiles")
            try fm.createDirectory(atPath: profilesStaging, withIntermediateDirectories: true)

            let profDir = self.profilesDirectory
            let jsonPath = (profDir as NSString).appendingPathComponent("workspace_profiles.json")
            if fm.fileExists(atPath: jsonPath) {
                let dstPath = (profilesStaging as NSString).appendingPathComponent("workspace_profiles.json")
                try fm.copyItem(atPath: jsonPath, toPath: dstPath)
                profileFilesList.append("workspace_profiles.json")
            }
            let activePath = (profDir as NSString).appendingPathComponent("active_profile_id.txt")
            if fm.fileExists(atPath: activePath) {
                let dstPath = (profilesStaging as NSString).appendingPathComponent("active_profile_id.txt")
                try fm.copyItem(atPath: activePath, toPath: dstPath)
                profileFilesList.append("active_profile_id.txt")
            }
        }

        // 4. 生成 manifest.json
        var manifest = CloneManifest(
            categories: categories,
            templateCount: templateFilesList.count,
            includeLUTs: includeLUTs,
            lutCount: lutFilesList.count,
            includeProfiles: includeProfiles,
            profileCount: profileFilesList.count,
            templateFiles: templateFilesList,
            lutFiles: lutFilesList,
            profileFiles: profileFilesList
        )

        let manifestPath = (stagingDir as NSString).appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: URL(fileURLWithPath: manifestPath))

        // 5. 归档为 .fcpxpack
        var finalOut = outputPath
        if !finalOut.hasSuffix(".fcpxpack") {
            finalOut += ".fcpxpack"
        }
        let outDir = (finalOut as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: finalOut) {
            try fm.removeItem(atPath: finalOut)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", stagingDir, finalOut]
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fm.fileExists(atPath: finalOut) else {
            throw EnvironmentClonerError.packagingFailed("生成 .fcpxpack 归档包失败")
        }

        let packData = try Data(contentsOf: URL(fileURLWithPath: finalOut))
        let hash = TeamP2PSyncManager.sha256(data: packData)
        manifest.sha256 = hash
        manifest.totalSizeBytes = Int64(packData.count)

        return manifest
    }

    // MARK: – 导入部署克隆包 (.fcpxpack)
    @discardableResult
    public func importPackage(packagePath: String, conflictPolicy: ConflictPolicy = .overwrite) throws -> ImportSummary {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packagePath) else {
            throw EnvironmentClonerError.invalidPackage("未找到指定的克隆包：\(packagePath)")
        }

        let sandboxDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPX_Unpack_\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: sandboxDir) }

        try fm.createDirectory(atPath: sandboxDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", packagePath, sandboxDir]
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw EnvironmentClonerError.invalidPackage("解压 .fcpxpack 失败")
        }

        var installedTemplates = 0
        var installedLUTs = 0
        var installedProfiles = 0
        var skipped = 0
        var details: [String] = []

        // 1. 恢复模板
        let tmplDir = (sandboxDir as NSString).appendingPathComponent("Templates")
        if fm.fileExists(atPath: tmplDir) {
            let targetRoot = self.userTemplatesRoot
            try fm.createDirectory(atPath: targetRoot, withIntermediateDirectories: true)

            guard let categories = try? fm.contentsOfDirectory(atPath: tmplDir) else {
                throw EnvironmentClonerError.ioError("无法读取暂存 Templates 目录")
            }

            for cat in categories {
                if cat.hasPrefix(".") || cat == "__MACOSX" { continue }
                let catSrc = (tmplDir as NSString).appendingPathComponent(cat)
                let catDst = (targetRoot as NSString).appendingPathComponent(cat)
                try fm.createDirectory(atPath: catDst, withIntermediateDirectories: true)

                guard let subcats = try? fm.contentsOfDirectory(atPath: catSrc) else { continue }
                for sub in subcats {
                    if sub.hasPrefix(".") || sub == "__MACOSX" { continue }
                    let subSrc = (catSrc as NSString).appendingPathComponent(sub)
                    let subDst = (catDst as NSString).appendingPathComponent(sub)
                    try fm.createDirectory(atPath: subDst, withIntermediateDirectories: true)

                    guard let items = try? fm.contentsOfDirectory(atPath: subSrc) else { continue }
                    for item in items {
                        if item.hasPrefix(".") || item == "__MACOSX" { continue }
                        let srcItem = (subSrc as NSString).appendingPathComponent(item)
                        var dstItem = (subDst as NSString).appendingPathComponent(item)

                        var existingBackupPath: String? = nil
                        if fm.fileExists(atPath: dstItem) {
                            switch conflictPolicy {
                            case .skip:
                                skipped += 1
                                details.append("跳过模板：\(cat)/\(sub)/\(item)")
                                continue
                            case .overwrite:
                                // FCPX-008: 先原子移动至临时备份，copy 成功后再清理；失败自动回滚
                                let bkp = "\(dstItem)_importbak_\(UUID().uuidString)"
                                try fm.moveItem(atPath: dstItem, toPath: bkp)
                                existingBackupPath = bkp
                            case .keepBoth:
                                let base = (item as NSString).deletingPathExtension
                                let ext = (item as NSString).pathExtension
                                let newName = ext.isEmpty ? "\(base) (副本)" : "\(base) (副本).\(ext)"
                                dstItem = (subDst as NSString).appendingPathComponent(newName)
                            }
                        }

                        do {
                            try fm.copyItem(atPath: srcItem, toPath: dstItem)
                            if let bkp = existingBackupPath {
                                try? fm.removeItem(atPath: bkp)
                            }
                            installedTemplates += 1
                            details.append("已安装模板：\(cat)/\(sub)/\(item)")
                        } catch {
                            // 失败回滚保护原模板
                            if let bkp = existingBackupPath, fm.fileExists(atPath: bkp) {
                                try? fm.removeItem(atPath: dstItem)
                                try? fm.moveItem(atPath: bkp, toPath: dstItem)
                            }
                            throw error
                        }
                    }
                }
            }
        }

        // 2. 恢复 3D LUT
        let lutsDir = (sandboxDir as NSString).appendingPathComponent("LUTs")
        if fm.fileExists(atPath: lutsDir) {
            let targetLUTDir = self.lutsRoot
            try fm.createDirectory(atPath: targetLUTDir, withIntermediateDirectories: true)

            guard let lutFiles = try? fm.contentsOfDirectory(atPath: lutsDir) else {
                throw EnvironmentClonerError.ioError("无法读取暂存 LUTs 目录")
            }

            for lut in lutFiles {
                if !lut.lowercased().hasSuffix(".cube") { continue }
                let srcLut = (lutsDir as NSString).appendingPathComponent(lut)
                var dstLut = (targetLUTDir as NSString).appendingPathComponent(lut)

                if fm.fileExists(atPath: dstLut) {
                    switch conflictPolicy {
                    case .skip:
                        skipped += 1
                        details.append("跳过 LUT：\(lut)")
                        continue
                    case .overwrite:
                        try fm.removeItem(atPath: dstLut)
                    case .keepBoth:
                        let base = (lut as NSString).deletingPathExtension
                        let newName = "\(base) (副本).cube"
                        dstLut = (targetLUTDir as NSString).appendingPathComponent(newName)
                    }
                }

                try fm.copyItem(atPath: srcLut, toPath: dstLut)
                installedLUTs += 1
                details.append("已导入调色 LUT：\(lut)")
            }
        }

        // 3. 恢复工作区情境隔离配置
        let profDir = (sandboxDir as NSString).appendingPathComponent("Profiles")
        if fm.fileExists(atPath: profDir) {
            let targetProfDir = self.profilesDirectory
            try fm.createDirectory(atPath: targetProfDir, withIntermediateDirectories: true)

            let incomingJson = (profDir as NSString).appendingPathComponent("workspace_profiles.json")
            if fm.fileExists(atPath: incomingJson),
               let data = try? Data(contentsOf: URL(fileURLWithPath: incomingJson)),
               let incomingProfiles = try? JSONDecoder().decode([WorkspaceProfile].self, from: data) {

                let localProfiles = WorkspaceProfileManager.shared.loadProfiles()
                var mergedProfiles = localProfiles

                for inc in incomingProfiles {
                    if let idx = mergedProfiles.firstIndex(where: { $0.id == inc.id || $0.name == inc.name }) {
                        if conflictPolicy == .overwrite {
                            mergedProfiles[idx] = inc
                            installedProfiles += 1
                        } else if conflictPolicy == .keepBoth {
                            var dup = inc
                            dup.id = UUID()
                            dup.name = "\(inc.name) (导入)"
                            dup.isBuiltin = false
                            dup.isDefault = false
                            mergedProfiles.append(dup)
                            installedProfiles += 1
                        } else {
                            skipped += 1
                        }
                    } else {
                        mergedProfiles.append(inc)
                        installedProfiles += 1
                    }
                }

                WorkspaceProfileManager.shared.saveProfiles(mergedProfiles)
                details.append("合并情境配置：共导入 \(installedProfiles) 项")
            }
        }

        // 4. 刷新缓存与状态
        AssetCacheManager.shared.invalidateAll()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: WorkspaceProfileManager.didUpdateProfilesNotification, object: nil)
        }

        return ImportSummary(
            success: true,
            installedTemplatesCount: installedTemplates,
            installedLUTsCount: installedLUTs,
            installedProfilesCount: installedProfiles,
            skippedCount: skipped,
            details: details
        )
    }
}
