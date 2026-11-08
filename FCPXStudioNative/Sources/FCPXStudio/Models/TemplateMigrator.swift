import Foundation

// ═══════════════════════════════════════════════════════════════
//  TemplateMigrator —— 三级归属之间的真实迁移（R31 / A-64）
//
//  规则（来自任务单）：
//    · 迁移 = 先移动到目标级 → 校验 → 才认为成功；失败必须回滚，
//      不允许出现「两边都没有」或「两份都在」。
//    · 目标同名不覆盖：由调用方选 覆盖 / 跳过 / 改名。
//    · 内置级默认只读：默认拒绝任何对 App 包的写入（源或目标为内置）。
//    · 仅在开启可写时，迁移到内置级前自动备份，并支持「撤销上次迁移」。
//    · 绝不静默提权：权限失败明确报「需要管理员授权」。
// ═══════════════════════════════════════════════════════════════

public enum MigrationConflictPolicy {
    case fail        // 直接报冲突（默认，UI 据此弹三选一）
    case skip
    case overwrite   // 用户明确选择：旧的同名项先移入备份区，不直接删除
    case rename      // 自动改名为 "name (2)"
}

public enum MigrationError: Error, LocalizedError {
    case sameTier
    case builtinReadOnly
    case tierUnavailable(TemplateTier, String)
    case sourceMissing(String)
    case destinationExists(String)
    case symlinkItemNeedsMaterialize(String)
    case permissionDenied(String)
    case skipped
    case ioFailure(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sameTier:
            return "目标层级与当前层级相同"
        case .builtinReadOnly:
            return "内置级默认只读。若要写入，请在「设置 → 内置级写入权限」中开启可写（有风险）"
        case .tierUnavailable(let tier, let note):
            return "\(tier.displayName)级不可用：\(note)"
        case .sourceMissing(let path):
            return "源目录不存在：\(path)"
        case .destinationExists(let path):
            return "目标位置已存在同名项：\(path)"
        case .symlinkItemNeedsMaterialize(let path):
            return "该项是外置软链接，请先实体化再迁移：\(path)"
        case .permissionDenied(let path):
            return "需要管理员授权：没有写入权限（\(path)）"
        case .skipped:
            return "已跳过（目标已存在）"
        case .ioFailure(let msg):
            return "迁移失败：\(msg)"
        case .verificationFailed(let msg):
            return "迁移后校验失败，已回滚：\(msg)"
        }
    }
}

public struct MigrationOutcome {
    public let name: String
    public let category: String
    public let fromTier: TemplateTier
    public let toTier: TemplateTier
    public let destinationPath: String
    public let backupPath: String?
    public let renamedTo: String?
}

/// 迁移记录（用于「撤销上次迁移」）
public struct MigrationRecord: Codable {
    public let name: String
    public let category: String
    public let fromTier: String
    public let toTier: String
    public let destinationPath: String
    public let backupPath: String?
    public let timestamp: String
}

public final class TemplateMigrator {
    public static let shared = TemplateMigrator()
    public static let lastMigrationKey = "lastMigrationRecord"

    // MARK: – P2 卷监听与离线容灾通知常量
    public static let volumeStatusDidChangeNotification = Notification.Name("TemplateMigratorVolumeStatusDidChangeNotification")
    public static let volumePathUserInfoKey = "volumePath"
    public static let isMountedUserInfoKey = "isMounted"
    public static let affectedCountUserInfoKey = "affectedCount"

    private static let lock = NSRecursiveLock()
    private static var _offlineVolumes: Set<String> = []

    /// 当前系统已记录的离线卷集合
    public static var offlineVolumes: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _offlineVolumes
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _offlineVolumes = newValue
        }
    }

    public var offlineVolumes: Set<String> {
        get { Self.offlineVolumes }
        set { Self.offlineVolumes = newValue }
    }

    /// 纯初始化，杜绝隐式启动监听副作用
    public init() {}

    /// 显式幂等启动卷挂载/卸载监听（桥接至 Sockets 层 VolumeMonitor）
    public static func startMonitoringVolumes() {
        VolumeMonitor.shared.startMonitoring()
    }

    public func startMonitoringVolumes() {
        Self.startMonitoringVolumes()
    }

    /// 接收 VolumeMonitor 桥接转发的卷事件并更新状态
    public static func handleVolumeEvent(volumePath: String, isMounted: Bool) {
        let normPath = (volumePath as NSString).standardizingPath
        lock.lock()
        if isMounted {
            _offlineVolumes.remove(normPath)
        } else {
            _offlineVolumes.insert(normPath)
        }
        lock.unlock()

        let count = AssetCacheManager.shared.countTemplates(onVolume: normPath)
        postVolumeChange(volumePath: normPath, isMounted: isMounted, affectedCount: count)
    }

    /// 广播卷状态变更通知，userInfo 包含卷信息、UUID 与受影响模板数量
    public static func postVolumeChange(volumePath: String, isMounted: Bool, affectedCount: Int) {
        let normPath = (volumePath as NSString).standardizingPath
        TemplateItem.invalidateVolumeUUIDCache(for: normPath)
        lock.lock()
        if isMounted {
            _offlineVolumes.remove(normPath)
        } else {
            _offlineVolumes.insert(normPath)
        }
        lock.unlock()

        let volName = (normPath as NSString).lastPathComponent
        let volumeUUID = isMounted ? TemplateItem.getVolumeUUID(for: normPath) : nil
        var userInfo: [String: Any] = [
            TemplateMigrator.volumePathUserInfoKey: normPath,
            TemplateMigrator.isMountedUserInfoKey: isMounted,
            TemplateMigrator.affectedCountUserInfoKey: affectedCount,
            "volumeName": volName,
            "isOffline": !isMounted
        ]
        if let uuid = volumeUUID {
            userInfo["volumeUUID"] = uuid
        }
        NotificationCenter.default.post(
            name: TemplateMigrator.volumeStatusDidChangeNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    public func postVolumeChange(volumePath: String, isMounted: Bool, affectedCount: Int) {
        Self.postVolumeChange(volumePath: volumePath, isMounted: isMounted, affectedCount: affectedCount)
    }

    /// 判定素材 targetPath 或 path 是否处于离线卷（纯只读内存函数，绝不触发磁盘 IO 与写锁副作用）
    public func isPathOffline(_ path: String, targetPath: String? = nil) -> Bool {
        return Self.isPathOffline(path, targetPath: targetPath)
    }

    /// 判定素材 targetPath 或 path 是否处于离线卷（纯只读内存函数，绝不触发磁盘 IO 与写锁副作用）
    public static func isPathOffline(_ path: String, targetPath: String? = nil) -> Bool {
        lock.lock()
        let currentOffline = _offlineVolumes
        lock.unlock()

        guard !currentOffline.isEmpty else { return false }

        let normalizedPath = (path as NSString).standardizingPath
        for vol in currentOffline {
            if normalizedPath == vol || normalizedPath.hasPrefix(vol + "/") {
                return true
            }
        }

        if let tp = targetPath {
            let normalizedTarget = (tp as NSString).standardizingPath
            for vol in currentOffline {
                if normalizedTarget == vol || normalizedTarget.hasPrefix(vol + "/") {
                    return true
                }
            }
        } else if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: normalizedPath) {
            let normalizedTarget = (dest as NSString).standardizingPath
            for vol in currentOffline {
                if normalizedTarget == vol || normalizedTarget.hasPrefix(vol + "/") {
                    return true
                }
            }
        }

        return false
    }

    /// 备份根目录。默认 `~/Movies/FCPX_Studio_Backup`；
    /// `FCPXSTUDIO_BACKUP_ROOT` 仅供逻辑 harness / 自动化验收覆盖到临时目录，
    /// 避免测试污染用户的 ~/Movies。
    public static var backupRoot: String {
        if let override = ProcessInfo.processInfo.environment["FCPXSTUDIO_BACKUP_ROOT"] {
            return override
        }
        return (NSString(string: "~/Movies/FCPX_Studio_Backup").expandingTildeInPath)
    }

    // MARK: – 迁移

    public func migrate(item: TemplateItem,
                        to targetTier: TemplateTier,
                        policy: MigrationConflictPolicy = .fail,
                        roots: TemplateTierRoots = .resolve()) throws -> MigrationOutcome {
        guard item.tier != targetTier else { throw MigrationError.sameTier }

        // 内置级写入权限：源或目标任一为内置，都算「写 App 包」
        if (targetTier == .builtin || item.tier == .builtin) && !TierWritePolicy.isBuiltinWritable {
            throw MigrationError.builtinReadOnly
        }
        guard let destRoot = roots.root(for: targetTier) else {
            throw MigrationError.tierUnavailable(targetTier, roots.builtinNote)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: item.path) || (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil else {
            throw MigrationError.sourceMissing(item.path)
        }
        // 软链接项：直接搬链接会留下断链/搬错对象，明确拒绝并给出口
        guard !item.isSymlink else {
            throw MigrationError.symlinkItemNeedsMaterialize(item.path)
        }

        let destCategoryDir = "\(destRoot)/\(item.category)"
        do {
            try fm.createDirectory(atPath: destCategoryDir, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: destCategoryDir)
        }

        var destName = item.name
        var destPath = "\(destCategoryDir)/\(destName)"
        var displacedBackup: String?

        if pathOccupied(destPath) {
            switch policy {
            case .fail:
                throw MigrationError.destinationExists(destPath)
            case .skip:
                throw MigrationError.skipped
            case .rename:
                destName = uniqueName(base: item.name, in: destCategoryDir)
                destPath = "\(destCategoryDir)/\(destName)"
            case .overwrite:
                let backup = try makeBackupSlot(category: item.category, name: item.name, tag: "displaced")
                do {
                    try fm.moveItem(atPath: destPath, toPath: backup)
                    displacedBackup = backup
                } catch {
                    throw mapError(error, path: destPath)
                }
            }
        }

        // 写入内置级（或从内置级搬出）前，先备份源
        var backupPath: String?
        if targetTier == .builtin || item.tier == .builtin {
            let slot = try makeBackupSlot(category: item.category, name: item.name, tag: "pre-migrate")
            do {
                try fm.copyItem(atPath: item.path, toPath: slot)
                backupPath = slot
            } catch {
                throw mapError(error, path: item.path)
            }
        }

        // 真实移动
        do {
            try fm.moveItem(atPath: item.path, toPath: destPath)
        } catch {
            // 回滚：清理可能产生的半成品；源若已被消费则从备份恢复
            if fm.fileExists(atPath: destPath) { try? fm.removeItem(atPath: destPath) }
            if let displaced = displacedBackup, !fm.fileExists(atPath: destPath) {
                try? fm.moveItem(atPath: displaced, toPath: destPath)
            }
            if !fm.fileExists(atPath: item.path), let backup = backupPath {
                try? fm.copyItem(atPath: backup, toPath: item.path)
            }
            throw mapError(error, path: item.path)
        }

        // 成功后校验：源必须消失，目标必须存在
        let sourceStillThere = fm.fileExists(atPath: item.path)
        let destThere = fm.fileExists(atPath: destPath)
        if sourceStillThere || !destThere {
            // 尝试把目标搬回源位置
            if destThere { try? fm.moveItem(atPath: destPath, toPath: item.path) }
            throw MigrationError.verificationFailed("源存在=\(sourceStillThere)，目标存在=\(destThere)")
        }

        // 记录迁移（供撤销）
        let record = MigrationRecord(
            name: item.name,
            category: item.category,
            fromTier: item.tier.rawValue,
            toTier: targetTier.rawValue,
            destinationPath: destPath,
            backupPath: backupPath,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        saveRecord(record)

        return MigrationOutcome(
            name: destName,
            category: item.category,
            fromTier: item.tier,
            toTier: targetTier,
            destinationPath: destPath,
            backupPath: backupPath,
            renamedTo: destName == item.name ? nil : destName
        )
    }

    // MARK: – 撤销上次迁移

    public func lastRecord() -> MigrationRecord? {
        guard let data = UserDefaults.standard.data(forKey: Self.lastMigrationKey) else { return nil }
        return try? JSONDecoder().decode(MigrationRecord.self, from: data)
    }

    @discardableResult
    public func undoLastMigration(roots: TemplateTierRoots = .resolve()) throws -> MigrationOutcome {
        guard let record = lastRecord() else {
            throw MigrationError.ioFailure("没有可撤销的迁移记录")
        }
        guard let fromTier = TemplateTier(rawValue: record.fromTier),
              let toTier = TemplateTier(rawValue: record.toTier) else {
            throw MigrationError.ioFailure("迁移记录已损坏")
        }
        if (fromTier == .builtin || toTier == .builtin) && !TierWritePolicy.isBuiltinWritable {
            throw MigrationError.builtinReadOnly
        }
        guard let backRoot = roots.root(for: fromTier) else {
            throw MigrationError.tierUnavailable(fromTier, roots.builtinNote)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: record.destinationPath) else {
            throw MigrationError.sourceMissing(record.destinationPath)
        }
        let backCategory = "\(backRoot)/\(record.category)"
        let backPath = "\(backCategory)/\(record.name)"
        if pathOccupied(backPath) {
            throw MigrationError.destinationExists(backPath)
        }
        do {
            try fm.createDirectory(atPath: backCategory, withIntermediateDirectories: true)
            try fm.moveItem(atPath: record.destinationPath, toPath: backPath)
        } catch {
            throw mapError(error, path: record.destinationPath)
        }
        UserDefaults.standard.removeObject(forKey: Self.lastMigrationKey)
        UserDefaults.standard.synchronize()

        return MigrationOutcome(
            name: record.name,
            category: record.category,
            fromTier: toTier,
            toTier: fromTier,
            destinationPath: backPath,
            backupPath: record.backupPath,
            renamedTo: nil
        )
    }

    // MARK: – 内部工具

    private func pathOccupied(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        return (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func uniqueName(base: String, in dir: String) -> String {
        var idx = 2
        while true {
            let candidate = "\(base) (\(idx))"
            if !pathOccupied("\(dir)/\(candidate)") { return candidate }
            idx += 1
        }
    }

    /// 在 ~/Movies/FCPX_Studio_Backup/<时间戳>/<分类>/<名称> 下建立不冲突的备份槽
    private func makeBackupSlot(category: String, name: String, tag: String) throws -> String {
        let fm = FileManager.default
        let ts = Self.timestamp()
        let dir = "\(Self.backupRoot)/\(ts)-\(tag)/\(category)"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: dir)
        }
        var candidate = "\(dir)/\(name)"
        var idx = 2
        while pathOccupied(candidate) {
            candidate = "\(dir)/\(name) (\(idx))"
            idx += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func saveRecord(_ record: MigrationRecord) {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: Self.lastMigrationKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// 把 FileManager 的错误映射成可行动的中文错误（权限失败必须点名）
    private func mapError(_ error: Error, path: String) -> MigrationError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied(path)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) {
            return .permissionDenied(path)
        }
        return .ioFailure("\(ns.localizedDescription)（\(path)）")
    }
}

// ═══════════════════════════════════════════════════════════════
//  StorageMigrationManager —— 外置盘全量/分项搬家与符号链接管理引擎（R42 对标嘉星）
// ═══════════════════════════════════════════════════════════════

public struct StorageCategoryInfo: Equatable {
    public let category: String
    public let displayName: String
    public let path: String
    public let isSymlink: Bool
    public let targetPath: String?
    public let sizeBytes: Int64
    public let sizeFormatted: String

    public init(category: String, displayName: String, path: String, isSymlink: Bool, targetPath: String?, sizeBytes: Int64, sizeFormatted: String) {
        self.category = category
        self.displayName = displayName
        self.path = path
        self.isSymlink = isSymlink
        self.targetPath = targetPath
        self.sizeBytes = sizeBytes
        self.sizeFormatted = sizeFormatted
    }
}

public struct MountedVolumeInfo: Equatable {
    public let name: String
    public let path: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isWritable: Bool

    public init(name: String, path: String, totalBytes: Int64, freeBytes: Int64, isWritable: Bool) {
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isWritable = isWritable
    }

    public var freeFormatted: String {
        ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }
    public var totalFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

public struct StorageOverview: Equatable {
    public let localMotionRoot: String
    public let isEntireRootSymlinked: Bool
    public let symlinkTarget: String?
    public let totalPhysicalSizeBytes: Int64
    public let totalPhysicalSizeFormatted: String
    public let savedDiskSizeBytes: Int64
    public let savedDiskSizeFormatted: String
    public let categories: [StorageCategoryInfo]

    public init(localMotionRoot: String, isEntireRootSymlinked: Bool, symlinkTarget: String?, totalPhysicalSizeBytes: Int64, totalPhysicalSizeFormatted: String, savedDiskSizeBytes: Int64, savedDiskSizeFormatted: String, categories: [StorageCategoryInfo]) {
        self.localMotionRoot = localMotionRoot
        self.isEntireRootSymlinked = isEntireRootSymlinked
        self.symlinkTarget = symlinkTarget
        self.totalPhysicalSizeBytes = totalPhysicalSizeBytes
        self.totalPhysicalSizeFormatted = totalPhysicalSizeFormatted
        self.savedDiskSizeBytes = savedDiskSizeBytes
        self.savedDiskSizeFormatted = savedDiskSizeFormatted
        self.categories = categories
    }
}

public final class StorageMigrationManager {
    public static let shared = StorageMigrationManager()
    public init() {}

    public static var defaultMotionRoot: String {
        if let override = ProcessInfo.processInfo.environment["FCPXSTUDIO_MOTION_ROOT"] {
            return override
        }
        return (NSString(string: "~/Movies/Motion Templates.localized").expandingTildeInPath)
    }

    /// 列出所有当前挂载的外置可写磁盘卷
    public func listMountedVolumes() -> [MountedVolumeInfo] {
        let fm = FileManager.default
        guard let volUrls = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeIsInternalKey], options: [.skipHiddenVolumes]) else {
            return []
        }
        var results: [MountedVolumeInfo] = []
        for url in volUrls {
            let path = url.path
            if path == "/" || path.hasPrefix("/System") { continue }
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeIsInternalKey])
            let isReadOnly = values?.volumeIsReadOnly ?? false
            let isInternal = values?.volumeIsInternal ?? false
            if isReadOnly { continue }
            let name = values?.volumeName ?? url.lastPathComponent
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = Int64(values?.volumeAvailableCapacity ?? 0)
            if path.hasPrefix("/Volumes") || !isInternal {
                results.append(MountedVolumeInfo(
                    name: name,
                    path: path,
                    totalBytes: total,
                    freeBytes: free,
                    isWritable: fm.isWritableFile(atPath: path)
                ))
            }
        }
        return results.sorted(by: { $0.freeBytes > $1.freeBytes })
    }

    /// 计算指定目录物理磁盘占用字节数（若自身是软链接则计为 0 物理系统盘占用）
    public func calculatePhysicalSizeBytes(at path: String) -> Int64 {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
            return 0
        }
        guard fm.fileExists(atPath: path) else { return 0 }
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { continue }
            if vals.isSymbolicLink == true { continue }
            total += Int64(vals.fileSize ?? 0)
        }
        return total
    }

    /// 深度扫描当前 Motion Templates 存储布局
    public func scanStorage(motionRoot: String? = nil) -> StorageOverview {
        let root = motionRoot ?? Self.defaultMotionRoot
        let fm = FileManager.default

        var isEntireSymlinked = false
        var rootSymlinkTarget: String?
        if let dest = try? fm.destinationOfSymbolicLink(atPath: root) {
            isEntireSymlinked = true
            rootSymlinkTarget = dest
        }

        let catNames = [
            ("Titles.localized", "💬 标题字幕"),
            ("Effects.localized", "✨ 视频特效"),
            ("Transitions.localized", "🔄 视频转场"),
            ("Generators.localized", "⚡️ 视频发生器")
        ]

        var catInfos: [StorageCategoryInfo] = []
        var totalPhys: Int64 = 0
        var totalSaved: Int64 = 0

        for (dirName, dispName) in catNames {
            let catPath = "\(root)/\(dirName)"
            var isSym = false
            var target: String?
            if let dest = try? fm.destinationOfSymbolicLink(atPath: catPath) {
                isSym = true
                target = dest
            }

            let physBytes: Int64
            let effectivePath = target ?? catPath
            let actualBytes = calculatePhysicalSizeBytes(at: effectivePath)

            if isEntireSymlinked || isSym {
                physBytes = 0
                totalSaved += actualBytes
            } else {
                physBytes = actualBytes
                totalPhys += actualBytes
            }

            let fmt = ByteCountFormatter.string(fromByteCount: (isSym || isEntireSymlinked) ? actualBytes : physBytes, countStyle: .file)
            catInfos.append(StorageCategoryInfo(
                category: dirName,
                displayName: dispName,
                path: catPath,
                isSymlink: isSym || isEntireSymlinked,
                targetPath: target ?? (isEntireSymlinked ? "\(rootSymlinkTarget ?? "")/\(dirName)" : nil),
                sizeBytes: actualBytes,
                sizeFormatted: fmt
            ))
        }

        let totalPhysFmt = ByteCountFormatter.string(fromByteCount: totalPhys, countStyle: .file)
        let totalSavedFmt = ByteCountFormatter.string(fromByteCount: totalSaved, countStyle: .file)

        return StorageOverview(
            localMotionRoot: root,
            isEntireRootSymlinked: isEntireSymlinked,
            symlinkTarget: rootSymlinkTarget,
            totalPhysicalSizeBytes: totalPhys,
            totalPhysicalSizeFormatted: totalPhysFmt,
            savedDiskSizeBytes: totalSaved,
            savedDiskSizeFormatted: totalSavedFmt,
            categories: catInfos
        )
    }

    /// 一键全量搬家至外置卷根目录（并在本地原子创建软链接）
    @discardableResult
    public func migrateEntireLibrary(toVolumePath volumePath: String, motionRoot: String? = nil) throws -> String {
        let root = motionRoot ?? Self.defaultMotionRoot
        let fm = FileManager.default

        guard fm.fileExists(atPath: volumePath) else {
            throw MigrationError.sourceMissing("外置目标卷不可用: \(volumePath)")
        }
        guard fm.isWritableFile(atPath: volumePath) else {
            throw MigrationError.permissionDenied("外置卷无写入权限: \(volumePath)")
        }

        let targetRoot = "\(volumePath)/Motion Templates.localized"

        if let dest = try? fm.destinationOfSymbolicLink(atPath: root) {
            if dest == targetRoot {
                return "已是目标外置卷的软链接，无需重复搬迁"
            }
            try fm.removeItem(atPath: root)
        }

        if !fm.fileExists(atPath: root) {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: targetRoot) {
            try fm.moveItem(atPath: root, toPath: targetRoot)
        }

        if fm.fileExists(atPath: root) {
            try fm.removeItem(atPath: root)
        }

        try fm.createSymbolicLink(atPath: root, withDestinationPath: targetRoot)

        guard let finalDest = try? fm.destinationOfSymbolicLink(atPath: root), finalDest == targetRoot else {
            throw MigrationError.verificationFailed("软链接建立校验失败: \(root) -> \(targetRoot)")
        }

        return targetRoot
    }

    /// 一键原路还原至内置系统盘（删除外置软链接，物理迁回本地）
    @discardableResult
    public func restoreEntireLibraryToInternal(motionRoot: String? = nil) throws -> String {
        let root = motionRoot ?? Self.defaultMotionRoot
        let fm = FileManager.default

        guard let target = try? fm.destinationOfSymbolicLink(atPath: root) else {
            return "当前已是本地内置存储，无需还原"
        }
        guard fm.fileExists(atPath: target) else {
            throw MigrationError.sourceMissing("软链接目标外置路径不存在: \(target)")
        }

        try fm.removeItem(atPath: root)

        do {
            try fm.moveItem(atPath: target, toPath: root)
        } catch {
            try? fm.createSymbolicLink(atPath: root, withDestinationPath: target)
            throw MigrationError.ioFailure("搬迁回本地失败: \(error.localizedDescription)")
        }

        return root
    }

    /// 单个分类搬迁至外置卷
    @discardableResult
    public func migrateCategory(category: String, toVolumePath: String, motionRoot: String? = nil) throws -> String {
        let root = motionRoot ?? Self.defaultMotionRoot
        let fm = FileManager.default
        let catPath = "\(root)/\(category)"
        let targetCat = "\(toVolumePath)/Motion Templates.localized/\(category)"

        if let dest = try? fm.destinationOfSymbolicLink(atPath: catPath), dest == targetCat {
            return "该分类已完成外置搬家"
        }

        try fm.createDirectory(atPath: "\(toVolumePath)/Motion Templates.localized", withIntermediateDirectories: true)

        if fm.fileExists(atPath: catPath) && (try? fm.destinationOfSymbolicLink(atPath: catPath)) == nil {
            if fm.fileExists(atPath: targetCat) {
                try fm.removeItem(atPath: targetCat)
            }
            try fm.moveItem(atPath: catPath, toPath: targetCat)
        } else {
            try? fm.removeItem(atPath: catPath)
            if !fm.fileExists(atPath: targetCat) {
                try fm.createDirectory(atPath: targetCat, withIntermediateDirectories: true)
            }
        }

        try fm.createSymbolicLink(atPath: catPath, withDestinationPath: targetCat)
        return targetCat
    }

    /// 单个分类原路还原至内置系统盘
    @discardableResult
    public func restoreCategory(category: String, motionRoot: String? = nil) throws -> String {
        let root = motionRoot ?? Self.defaultMotionRoot
        let fm = FileManager.default
        let catPath = "\(root)/\(category)"

        guard let target = try? fm.destinationOfSymbolicLink(atPath: catPath) else {
            return "该分类已是本地内置存储"
        }

        try fm.removeItem(atPath: catPath)
        try fm.moveItem(atPath: target, toPath: catPath)
        return catPath
    }
}
