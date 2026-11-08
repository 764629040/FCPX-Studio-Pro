import Foundation
import AppKit

// ═══════════════════════════════════════════════════════════════
//  WorkspaceProfileManager —— 多工作区情境隔离配置系统（R43）
//
//  核心职责：
//    1. 定义项目情境数据模型（WorkspaceProfile），内置全量、婚礼、商业、短视频等情境；
//    2. 基于 .disabled 命名规则，实现毫秒级批量模板启停隔离；
//    3. 支持 FCPXSTUDIO_PROFILES_DIR 环境变量隔离，实现沙盒化测试；
//    4. 精准计算 FCPX 启动项节省比例与预估提速倍率。
// ═══════════════════════════════════════════════════════════════

public struct WorkspaceProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var category: String
    public var description: String
    public var includedTemplateIDs: [String]
    public var excludedTemplateIDs: [String]
    public var isDefault: Bool
    public var isBuiltin: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "📁",
        category: String = "自定义情境",
        description: String = "",
        includedTemplateIDs: [String] = [],
        excludedTemplateIDs: [String] = [],
        isDefault: Bool = false,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.category = category
        self.description = description
        self.includedTemplateIDs = includedTemplateIDs
        self.excludedTemplateIDs = excludedTemplateIDs
        self.isDefault = isDefault
        self.isBuiltin = isBuiltin
    }

    /// 判断指定模板名称是否归属于当前情境
    public func matches(templateName: String) -> Bool {
        // 全量模式匹配一切
        if isDefault { return true }

        // 显式排除名单优先生效
        if excludedTemplateIDs.contains(templateName) {
            return false
        }

        // 显式白名单命中
        if includedTemplateIDs.contains(templateName) {
            return true
        }

        // 内置情境支持基于行业关键字的自动语义匹配
        if isBuiltin {
            for kw in includedTemplateIDs {
                let trimmed = kw.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && templateName.localizedCaseInsensitiveContains(trimmed) {
                    return true
                }
            }
        }

        return false
    }

    // 预置确定性 UUID 常量
    public static let allActiveId   = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let weddingId     = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let commercialId  = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let shortVideoId  = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    /// 官方出厂预置四大核心情境
    public static var builtins: [WorkspaceProfile] {
        return [
            WorkspaceProfile(
                id: allActiveId,
                name: "全量模式 (Default - All Active)",
                icon: "🌟",
                category: "全量默认",
                description: "激活全部已安装插件与特效，无任何隐藏隔离，完整后期制作能力",
                includedTemplateIDs: [],
                excludedTemplateIDs: [],
                isDefault: true,
                isBuiltin: true
            ),
            WorkspaceProfile(
                id: weddingId,
                name: "婚礼纪实 (Wedding & Romance)",
                icon: "💍",
                category: "行业专属",
                description: "专注婚礼唯美片头、浪漫色调、柔和光效转场与誓言字幕条",
                includedTemplateIDs: [
                    "婚礼", "Wedding", "Romance", "Love", "唯美",
                    "浪漫", "喜宴", "誓言", "相册", "PSD婚礼字幕"
                ],
                excludedTemplateIDs: [],
                isDefault: false,
                isBuiltin: true
            ),
            WorkspaceProfile(
                id: commercialId,
                name: "商业广告与宣传片 (Commercial & Tech)",
                icon: "📺",
                category: "行业专属",
                description: "企业科技感字幕条、HUD 元素、商业快节奏包装与震撼片头",
                includedTemplateIDs: [
                    "商业", "Commercial", "Tech", "HUD", "企业",
                    "宣传片", "科技", "商务", "新闻", "发布会", "图表", "包装"
                ],
                excludedTemplateIDs: [],
                isDefault: false,
                isBuiltin: true
            ),
            WorkspaceProfile(
                id: shortVideoId,
                name: "短视频与自媒体 (Vlog & Social Shorts)",
                icon: "📱",
                category: "自媒体专属",
                description: "9:16 竖版适配、网感动态花字、动感卡点特效、社交短视频包装",
                includedTemplateIDs: [
                    "短视频", "Vlog", "Social", "Shorts", "抖音",
                    "快手", "小红书", "竖版", "花字", "卡点", "弹幕", "自媒体", "网感"
                ],
                excludedTemplateIDs: [],
                isDefault: false,
                isBuiltin: true
            )
        ]
    }
}

/// 情境激活统计看板数据
public struct WorkspaceProfileStats: Equatable {
    public let profileId: UUID
    public let profileName: String
    public let totalTemplates: Int
    public let activeTemplates: Int
    public let disabledTemplates: Int

    public var reductionPercentage: Double {
        guard totalTemplates > 0 else { return 0.0 }
        let pct = Double(disabledTemplates) / Double(totalTemplates) * 100.0
        return round(pct * 10) / 10.0
    }

    public var estimatedSpeedup: Double {
        guard totalTemplates > 0, activeTemplates > 0 else { return 1.0 }
        let ratio = Double(totalTemplates) / Double(activeTemplates)
        return max(1.0, round(ratio * 10) / 10.0)
    }

    public init(
        profileId: UUID,
        profileName: String,
        totalTemplates: Int,
        activeTemplates: Int,
        disabledTemplates: Int
    ) {
        self.profileId = profileId
        self.profileName = profileName
        self.totalTemplates = totalTemplates
        self.activeTemplates = activeTemplates
        self.disabledTemplates = disabledTemplates
    }
}

public final class WorkspaceProfileManager {
    public static let shared = WorkspaceProfileManager()

    public static let didChangeActiveProfileNotification = Notification.Name("FCPXStudioActiveProfileChanged")
    public static let didUpdateProfilesNotification      = Notification.Name("FCPXStudioProfilesUpdated")

    public private(set) var profiles: [WorkspaceProfile] = []
    public private(set) var activeProfileId: UUID = WorkspaceProfile.allActiveId

    public var onProfileChanged: ((WorkspaceProfile) -> Void)?

    // MARK: – 路径解析与沙盒化隔离支持
    public static var profilesDirectory: String {
        if let customDir = ProcessInfo.processInfo.environment["FCPXSTUDIO_PROFILES_DIR"], !customDir.isEmpty {
            return (customDir as NSString).expandingTildeInPath
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FCPXStudio").path
    }

    public static var profilesFilePath: String {
        return "\(profilesDirectory)/workspace_profiles.json"
    }

    public static var activeProfileIdFilePath: String {
        return "\(profilesDirectory)/active_profile_id.txt"
    }

    public init() {
        reload()
    }

    /// 重新载入持久化情境配置
    public func reload() {
        profiles = loadProfiles()

        // 载入当前活跃情境 ID
        if let idStr = try? String(contentsOfFile: Self.activeProfileIdFilePath, encoding: .utf8) {
            let trimmed = idStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let uuid = UUID(uuidString: trimmed), profiles.contains(where: { $0.id == uuid }) {
                activeProfileId = uuid
            } else {
                activeProfileId = WorkspaceProfile.allActiveId
            }
        } else {
            activeProfileId = WorkspaceProfile.allActiveId
        }
    }

    // MARK: – 持久化与加载
    public func loadProfiles() -> [WorkspaceProfile] {
        let fm = FileManager.default
        let dir = Self.profilesDirectory
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let path = Self.profilesFilePath
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([WorkspaceProfile].self, from: data),
              !decoded.isEmpty else {
            let defaults = WorkspaceProfile.builtins
            saveProfiles(defaults)
            return defaults
        }

        // 确保内置的 4 大核心情境永不丢失
        var merged = decoded
        for builtin in WorkspaceProfile.builtins {
            if !merged.contains(where: { $0.id == builtin.id }) {
                merged.append(builtin)
            }
        }
        return merged
    }

    public func saveProfiles(_ newProfiles: [WorkspaceProfile]? = nil) {
        if let np = newProfiles {
            profiles = np
        }

        let dir = Self.profilesDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: URL(fileURLWithPath: Self.profilesFilePath))
        }

        try? activeProfileId.uuidString.write(
            to: URL(fileURLWithPath: Self.activeProfileIdFilePath),
            atomically: true,
            encoding: .utf8
        )

        NotificationCenter.default.post(name: Self.didUpdateProfilesNotification, object: nil)
    }

    public func getActiveProfile() -> WorkspaceProfile {
        if let p = profiles.first(where: { $0.id == activeProfileId }) {
            return p
        }
        return profiles.first(where: { $0.isDefault }) ?? WorkspaceProfile.builtins[0]
    }

    // MARK: – 情境 CRUD 操作
    @discardableResult
    public func addProfile(
        name: String,
        icon: String = "📁",
        category: String = "自定义情境",
        description: String = "",
        includedTemplateIDs: [String] = []
    ) -> WorkspaceProfile {
        let newProfile = WorkspaceProfile(
            id: UUID(),
            name: name,
            icon: icon,
            category: category,
            description: description,
            includedTemplateIDs: includedTemplateIDs,
            excludedTemplateIDs: [],
            isDefault: false,
            isBuiltin: false
        )
        profiles.append(newProfile)
        saveProfiles()
        return newProfile
    }

    public func updateProfile(_ profile: WorkspaceProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveProfiles()
        }
    }

    @discardableResult
    public func deleteProfile(id: UUID) -> Bool {
        guard let p = profiles.first(where: { $0.id == id }), !p.isBuiltin else {
            return false // 内置情境保护，禁止删除
        }
        profiles.removeAll(where: { $0.id == id })

        // 若当前删除的是正在激活的情境，自动切回全量默认
        if activeProfileId == id {
            _ = try? activateProfileSync(id: WorkspaceProfile.allActiveId)
        } else {
            saveProfiles()
        }
        return true
    }

    public func duplicateProfile(id: UUID) -> WorkspaceProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        let copy = WorkspaceProfile(
            id: UUID(),
            name: "\(original.name) 副本",
            icon: original.icon,
            category: "自定义情境",
            description: original.description,
            includedTemplateIDs: original.includedTemplateIDs,
            excludedTemplateIDs: original.excludedTemplateIDs,
            isDefault: false,
            isBuiltin: false
        )
        profiles.append(copy)
        saveProfiles()
        return copy
    }

    public func resetToDefaults() {
        profiles = WorkspaceProfile.builtins
        _ = try? activateProfileSync(id: WorkspaceProfile.allActiveId)
    }

    /// 切换模板在特定情境中的归属状态
    public func toggleTemplate(named templateName: String, in profileId: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        var p = profiles[idx]

        let currentlyMatched = p.matches(templateName: templateName)
        if currentlyMatched {
            // 当前已匹配 -> 移除归属
            p.includedTemplateIDs.removeAll(where: { $0 == templateName })
            if !p.excludedTemplateIDs.contains(templateName) {
                p.excludedTemplateIDs.append(templateName)
            }
        } else {
            // 当前未匹配 -> 添加归属
            p.excludedTemplateIDs.removeAll(where: { $0 == templateName })
            if !p.includedTemplateIDs.contains(templateName) {
                p.includedTemplateIDs.append(templateName)
            }
        }

        profiles[idx] = p
        saveProfiles()
    }

    public func isTemplateIncluded(templateName: String, in profileId: UUID) -> Bool {
        guard let p = profiles.first(where: { $0.id == profileId }) else { return false }
        return p.matches(templateName: templateName)
    }

    // MARK: – 核心：毫秒级情境激活与批量隔离引擎
    public func activateProfile(
        id: UUID,
        roots: TemplateTierRoots = .resolve(),
        completion: @escaping (Result<WorkspaceProfileStats, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let stats = try self.activateProfileSync(id: id, roots: roots)
                DispatchQueue.main.async {
                    completion(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    @discardableResult
    public func activateProfileSync(
        id: UUID,
        roots: TemplateTierRoots = .resolve(),
        enforceLicense: Bool = true
    ) throws -> WorkspaceProfileStats {
        if enforceLicense && !LicenseManager.shared.isProLicensed {
            throw NSError(
                domain: "WorkspaceProfileManager",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "未激活商业授权，多工作区情境隔离快速切换已锁定。请先激活商业授权。"]
            )
        }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw NSError(
                domain: "WorkspaceProfileManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到指定的情境配置 (ID: \(id))"]
            )
        }

        // 1. 扫描当前全部模板
        var allScannedItems: [TemplateItem] = []
        for cat in TemplateTierScanner.categories {
            let res = TemplateTierScanner.scan(category: cat, roots: roots, lazySizes: true)
            allScannedItems.append(contentsOf: res.items)
        }

        // FCPX-024: 状态快照防静默复活
        let snapshotKey = "FCPX_WorkspaceProfile_ManualDisabledSnapshot"
        let isSwitchingToDefault = profile.isDefault
        let manualDisabledSnapshot: Set<String>
        if isSwitchingToDefault {
            manualDisabledSnapshot = Set(UserDefaults.standard.stringArray(forKey: snapshotKey) ?? [])
        } else {
            // 从默认全量切向定制情境前，记录当前用户已手动停用的模板快照
            let currentDisabled = allScannedItems.filter { !$0.isEnabled }.map { $0.path }
            UserDefaults.standard.set(currentDisabled, forKey: snapshotKey)
            manualDisabledSnapshot = []
        }

        // 2. 批量处理启停隔离（R51：严格过滤 framework/app 等内部包，避免外置盘阻塞）
        for item in allScannedItems {
            // 系统内置模板若不可写则跳过
            if item.tier == .builtin && !TierWritePolicy.isBuiltinWritable {
                continue
            }

            let lower = item.path.lowercased()
            if lower.contains(".framework") || lower.contains(".app/") ||
               lower.contains(".pluginkit") || lower.contains(".bundle") ||
               lower.contains(".lproj") || lower.contains("_codesignature") {
                continue
            }

            // 仅对真实存在于磁盘的模板目录进行操作，防止外置卷挂载延迟抛错
            guard FileManager.default.fileExists(atPath: item.path) else {
                continue
            }

            let shouldBeActive: Bool
            if isSwitchingToDefault {
                // 恢复全量时，保留手动停用的模板，避免静默复活
                shouldBeActive = !manualDisabledSnapshot.contains(item.path)
            } else {
                shouldBeActive = profile.matches(templateName: item.name)
            }

            if item.isEnabled != shouldBeActive {
                do {
                    _ = try TemplateInstaller.setTemplateEnabled(item: item, enabled: shouldBeActive)
                } catch {
                    // 若个别因权限冲突跳过，不阻塞其他模板批量切换
                    print("[WorkspaceProfileManager] 警告: 模板 \(item.name) 状态切换失败: \(error)")
                }
            }
        }

        // 3. 更新激活 ID 与持久化
        activeProfileId = id
        saveProfiles()

        // 4. 清除内存素材缓存，确保素材库下次即刻重新读取最新状态
        AssetCacheManager.shared.invalidateAll()

        // 5. 统计最新激活分布
        let stats = getCurrentStats(roots: roots)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onProfileChanged?(profile)
            NotificationCenter.default.post(
                name: Self.didChangeActiveProfileNotification,
                object: profile,
                userInfo: ["stats": stats]
            )
        }

        return stats
    }

    // MARK: – 统计计算
    public func getCurrentStats(roots: TemplateTierRoots = .resolve()) -> WorkspaceProfileStats {
        let p = getActiveProfile()
        var active = 0
        var disabled = 0

        for cat in TemplateTierScanner.categories {
            let res = TemplateTierScanner.scan(category: cat, roots: roots, lazySizes: true)
            for it in res.items {
                if it.isEnabled {
                    active += 1
                } else {
                    disabled += 1
                }
            }
        }

        return WorkspaceProfileStats(
            profileId: p.id,
            profileName: p.name,
            totalTemplates: active + disabled,
            activeTemplates: active,
            disabledTemplates: disabled
        )
    }

    public func calculateStats(
        for profile: WorkspaceProfile,
        roots: TemplateTierRoots = .resolve()
    ) -> WorkspaceProfileStats {
        var total = 0
        var matched = 0

        for cat in TemplateTierScanner.categories {
            let res = TemplateTierScanner.scan(category: cat, roots: roots, lazySizes: true)
            for it in res.items {
                total += 1
                if profile.matches(templateName: it.name) {
                    matched += 1
                }
            }
        }

        return WorkspaceProfileStats(
            profileId: profile.id,
            profileName: profile.name,
            totalTemplates: total,
            activeTemplates: matched,
            disabledTemplates: max(0, total - matched)
        )
    }
}
