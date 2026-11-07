import Foundation

// ═══════════════════════════════════════════════════════════════
//  R31 原生逻辑直证 harness
//
//  用**同一批产品源码**（TemplateTier / TemplateMigrator / PSDImportPlanner）
//  在临时目录里真实跑一遍 A-61 / A-63 / A-64 的内容级判据。
//  编译方式见 docs/r31_evidence/run_native_harness.sh。
// ═══════════════════════════════════════════════════════════════

@main
struct R31Harness {
    static var failures = 0
    static var checks = 0
    static let fm = FileManager.default
    static var root = ""

    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        print("\(cond ? "PASS" : "FAIL") | \(name)\(detail.isEmpty ? "" : " | " + detail)")
    }

    static func mkdir(_ path: String) {
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func writeFile(_ path: String, bytes: Int = 2048) {
        mkdir((path as NSString).deletingLastPathComponent)
        fm.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
    }

    static func makeDirWithFile(_ path: String, marker: String) {
        mkdir(path)
        writeFile("\(path)/\(marker).bin", bytes: 4096)
    }

    static func main() {
        root = NSTemporaryDirectory() + "r31_harness_" + UUID().uuidString
        mkdir(root)
        defer { try? fm.removeItem(atPath: root) }
        print("HARNESS_ROOT=\(root)")

        // ═══ A-61 拖放 / 导入规划 ═══
        print("\n── A-61 PSDImportPlanner ──")
        let psdDir = "\(root)/psd_batch"
        mkdir(psdDir)
        for i in 1...50 { writeFile("\(psdDir)/batch_\(i).psd", bytes: 64) }
        writeFile("\(psdDir)/说明.txt", bytes: 10)
        mkdir("\(psdDir)/.hidden_dir")
        writeFile("\(psdDir)/.hidden_dir/hidden.psd", bytes: 10)
        mkdir("\(psdDir)/nested")
        writeFile("\(psdDir)/nested/deep.psd", bytes: 10)

        // 判据 1：拖单张 → 追加，不清空已有
        let single = PSDImportPlanner.plan(paths: ["\(psdDir)/batch_1.psd"],
                                           existing: ["/old/existing.psd"])
        check(single.added == ["\(psdDir)/batch_1.psd"] && single.rejected.isEmpty,
              "A-61-#1 单张追加", "added=\(single.added.count) rejected=\(single.rejected.count)")

        // 判据 2：含 50 个 PSD 的文件夹 → 数量对得上（51 含 nested/deep，隐藏目录不计）
        let dirPlan = PSDImportPlanner.plan(paths: [psdDir], existing: [])
        check(dirPlan.added.count == 51, "A-61-#2 目录递归",
              "added=\(dirPlan.added.count) (预期 51 = 50 + nested/deep)")

        // 判据 3：非 PSD → rejected，不崩溃
        let bad = PSDImportPlanner.plan(paths: ["\(psdDir)/说明.txt", "/definitely/not/exist.psd"], existing: [])
        check(bad.added.isEmpty && bad.rejected.count == 2, "A-61-#3 非PSD明确拒绝",
              "rejected=\(bad.rejected.count)")

        // 判据 4：连拖 3 个不同 PSD → 累积
        var accumulated: [String] = []
        for i in 1...3 {
            let p = PSDImportPlanner.plan(paths: ["\(psdDir)/batch_\(i).psd"], existing: accumulated)
            accumulated += p.added
        }
        check(accumulated.count == 3, "A-61-#4 连续拖放累积", "accumulated=\(accumulated.count)")

        // 去重（对齐 PyQt 侧 _append_psd_files）
        let dup = PSDImportPlanner.plan(paths: ["\(psdDir)/batch_1.psd"], existing: ["\(psdDir)/batch_1.psd"])
        check(dup.added.isEmpty && dup.duplicates.count == 1, "A-61 去重", "duplicates=\(dup.duplicates.count)")

        // 大小写后缀
        writeFile("\(psdDir)/UPPER.PSD")
        let upper = PSDImportPlanner.plan(paths: ["\(psdDir)/UPPER.PSD"], existing: [])
        check(upper.added.count == 1, "A-61 后缀大小写不敏感")

        // 混合：单文件 + 目录 + 文本
        let mixedDir = "\(root)/mixed_dir"
        mkdir(mixedDir)
        writeFile("\(mixedDir)/m1.psd"); writeFile("\(mixedDir)/m2.psd")
        let mixed = PSDImportPlanner.plan(paths: ["\(psdDir)/batch_5.psd", mixedDir, "\(psdDir)/说明.txt"], existing: [])
        check(mixed.added.count == 3 && mixed.rejected.count == 1, "A-61 混合多项分类",
              "added=\(mixed.added.count) rejected=\(mixed.rejected.count)")

        // 空目录
        let emptyDir = "\(root)/empty_dir"; mkdir(emptyDir)
        let empty = PSDImportPlanner.plan(paths: [emptyDir], existing: [])
        check(empty.emptyDirectories.count == 1 && empty.added.isEmpty, "A-61 空目录提示")

        // ═══ A-63 三级归属扫描 ═══
        print("\n── A-63 TemplateTierScanner ──")
        let builtin = "\(root)/tiers/builtin"
        let userRoot = "\(root)/tiers/user"
        let systemRoot = "\(root)/tiers/system"
        let extRoot = "\(root)/external_disk"
        for cfg in [builtin, userRoot, systemRoot] {
            makeDirWithFile("\(cfg)/Titles.localized/Same", marker: "same")
        }
        makeDirWithFile("\(userRoot)/Titles.localized/OnlyUser", marker: "u")
        // 体积判据用 2 MB 文件，避免 4 KB 被四舍五入成 0.0 MB
        writeFile("\(userRoot)/Titles.localized/OnlyUser/big.bin", bytes: 2_000_000)
        makeDirWithFile("\(systemRoot)/Titles.localized/OnlySystem", marker: "s")
        makeDirWithFile("\(builtin)/Titles.localized/OnlyBuiltin", marker: "b")
        // 用户级外置软链接
        makeDirWithFile("\(extRoot)/Titles.localized/Extern", marker: "e")
        try? fm.createSymbolicLink(atPath: "\(userRoot)/Titles.localized/Extern",
                                   withDestinationPath: "\(extRoot)/Titles.localized/Extern")

        let roots = TemplateTierRoots(builtin: builtin, user: userRoot, system: systemRoot, builtinNote: "")
        let scan = TemplateTierScanner.scan(category: "Titles.localized", roots: roots)

        let sameItems = scan.items.filter { $0.name == "Same" }
        check(sameItems.count == 3, "A-63-#4 同名跨三级全列出（不去重）", "Same=\(sameItems.count)")
        check(Set(sameItems.map { $0.tier }).count == 3, "A-63 三级各自标注")

        let extern = scan.items.first { $0.name == "Extern" }
        check(extern?.isSymlink == true && extern?.tier == .user, "A-63-#8 两个维度独立",
              "tier=\(extern?.tier.rawValue ?? "nil") disk=\(extern?.diskForm.displayText ?? "nil")")
        check(extern?.diskForm.displayText.contains("软链接") == true, "A-63 磁盘形态=软链接")

        let physical = scan.items.first { $0.name == "OnlyUser" }
        check(physical?.diskForm.displayText.contains("实体") == true && (physical?.sizeMB ?? 0) > 0,
              "A-63 磁盘形态=实体+体积", "size=\(physical?.sizeMB ?? -1)MB")

        // 内置级缺失 → 该级 note，其余照常
        let noBuiltin = TemplateTierRoots(builtin: nil, user: userRoot, system: systemRoot,
                                          builtinNote: "未检测到 FCPX")
        let scan2 = TemplateTierScanner.scan(category: "Titles.localized", roots: noBuiltin)
        check(scan2.tierNotes[.builtin] != nil && scan2.items.allSatisfy { $0.tier != .builtin },
              "A-63-#9 无内置级优雅降级", scan2.tierNotes[.builtin] ?? "")
        check(scan2.items.contains { $0.tier == .user }, "A-63-#9 其余级照常")

        // 系统级缺失 → note
        let noSystem = TemplateTierRoots(builtin: builtin, user: userRoot,
                                         system: "\(root)/tiers/not_exist", builtinNote: "")
        let scan3 = TemplateTierScanner.scan(category: "Titles.localized", roots: noSystem)
        check(scan3.tierNotes[.system] != nil, "A-63-#9 系统级缺失标注")

        // ═══ A-64 迁移 / 只读开关 / 备份 / 撤销 ═══
        print("\n── A-64 TemplateMigrator ──")
        let backupRoot = "\(root)/backup"
        setenv("FCPXSTUDIO_BACKUP_ROOT", backupRoot, 1)

        let migrator = TemplateMigrator()
        UserDefaults.standard.removeObject(forKey: TemplateMigrator.lastMigrationKey)
        TierWritePolicy.setBuiltinWritable(false)

        func makeItem(_ name: String, _ tier: TemplateTier, marker: String = "x") -> TemplateItem {
            let base: String
            switch tier {
            case .builtin: base = builtin
            case .user: base = userRoot
            case .system: base = systemRoot
            }
            let path = "\(base)/Titles.localized/\(name)"
            makeDirWithFile(path, marker: marker)
            return TemplateItem(name: name, category: "Titles.localized", tier: tier, path: path,
                                targetPath: path, isSymlink: false, targetAvailable: true, sizeMB: 0.0)
        }

        // 判据 12：用户 → 系统真实移动
        let mv1 = makeItem("MV1", .user, marker: "mv1")
        do {
            let out = try migrator.migrate(item: mv1, to: .system, roots: roots)
            let srcGone = !fm.fileExists(atPath: mv1.path)
            let dstThere = fm.fileExists(atPath: out.destinationPath)
            check(srcGone && dstThere, "A-64-#12 用户→系统真实移动",
                  "srcGone=\(srcGone) dst=\(out.destinationPath)")
        } catch {
            check(false, "A-64-#12 用户→系统真实移动", "抛出 \(error)")
        }

        // 判据 13：系统 → 用户（反向）
        do {
            let sysPath = "\(systemRoot)/Titles.localized/MV1"
            let item = TemplateItem(name: "MV1", category: "Titles.localized", tier: .system,
                                    path: sysPath, targetPath: sysPath, isSymlink: false,
                                    targetAvailable: true, sizeMB: 0)
            let out = try migrator.migrate(item: item, to: .user, roots: roots)
            check(!fm.fileExists(atPath: sysPath) && fm.fileExists(atPath: out.destinationPath),
                  "A-64-#13 系统→用户可来回搬")
        } catch {
            check(false, "A-64-#13 系统→用户可来回搬", "抛出 \(error)")
        }

        // 判据 15：同名冲突不覆盖
        let c1 = makeItem("C1", .user, marker: "new")
        makeDirWithFile("\(systemRoot)/Titles.localized/C1", marker: "old")
        do {
            _ = try migrator.migrate(item: c1, to: .system, policy: .fail, roots: roots)
            check(false, "A-64-#15 冲突默认不覆盖")
        } catch let e as MigrationError {
            if case .destinationExists = e {
                check(fm.fileExists(atPath: c1.path), "A-64-#15 冲突默认不覆盖", "源保持完好")
            } else { check(false, "A-64-#15 冲突默认不覆盖", "错误类型=\(e)") }
        } catch { check(false, "A-64-#15 冲突默认不覆盖", "\(error)") }

        // 冲突 → 改名
        do {
            let out = try migrator.migrate(item: c1, to: .system, policy: .rename, roots: roots)
            check(out.renamedTo == "C1 (2)" && fm.fileExists(atPath: out.destinationPath),
                  "A-64 冲突改名保留两份", "renamed=\(out.renamedTo ?? "nil")")
        } catch { check(false, "A-64 冲突改名保留两份", "\(error)") }

        // 冲突 → 跳过
        let c2 = makeItem("C2", .user)
        makeDirWithFile("\(systemRoot)/Titles.localized/C2", marker: "old")
        do {
            _ = try migrator.migrate(item: c2, to: .system, policy: .skip, roots: roots)
            check(false, "A-64 冲突跳过")
        } catch let e as MigrationError {
            if case .skipped = e {
                check(fm.fileExists(atPath: c2.path), "A-64 冲突跳过", "源保持完好")
            } else { check(false, "A-64 冲突跳过", "\(e)") }
        } catch { check(false, "A-64 冲突跳过", "\(error)") }

        // 冲突 → 覆盖（旧项进备份，不直接删除）
        let c3 = makeItem("C3", .user, marker: "new")
        makeDirWithFile("\(systemRoot)/Titles.localized/C3", marker: "old")
        do {
            _ = try migrator.migrate(item: c3, to: .system, policy: .overwrite, roots: roots)
            let newExists = fm.fileExists(atPath: "\(systemRoot)/Titles.localized/C3/new.bin")
            let backedUp = (try? fm.contentsOfDirectory(atPath: backupRoot))?.count ?? 0
            check(newExists && backedUp > 0, "A-64 覆盖时旧项进备份", "backup_ts_dirs=\(backedUp)")
        } catch { check(false, "A-64 覆盖时旧项进备份", "\(error)") }

        // 判据 14：权限失败 → 源完好、不出现零份/两份
        let roSystem = "\(root)/tiers/ro_system"
        mkdir("\(roSystem)/Titles.localized")
        let roItem = makeItem("RO1", .user)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: "\(roSystem)/Titles.localized")
        do {
            let roRoots = TemplateTierRoots(builtin: builtin, user: userRoot, system: roSystem, builtinNote: "")
            _ = try migrator.migrate(item: roItem, to: .system, roots: roRoots)
            check(false, "A-64-#14 权限失败回滚", "未抛错（环境可能允许写入）")
        } catch {
            let srcIntact = fm.fileExists(atPath: roItem.path)
            let dstAbsent = !fm.fileExists(atPath: "\(roSystem)/Titles.localized/RO1")
            check(srcIntact && dstAbsent, "A-64-#14 权限失败回滚",
                  "源完好=\(srcIntact) 目标无残片=\(dstAbsent) 错误=\(error)")
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(roSystem)/Titles.localized")

        // 判据 16：默认只读
        UserDefaults.standard.removeObject(forKey: TierWritePolicy.builtinWritableKey)
        check(TierWritePolicy.isBuiltinWritable == false, "A-64-#16 默认只读（未设置=false）")
        let b1 = makeItem("B1", .user)
        do {
            _ = try migrator.migrate(item: b1, to: .builtin, roots: roots)
            check(false, "A-64-#16 只读拦截写入内置级")
        } catch let e as MigrationError {
            if case .builtinReadOnly = e {
                check(fm.fileExists(atPath: b1.path), "A-64-#16 只读拦截写入内置级", "源完好")
            } else { check(false, "A-64-#16 只读拦截写入内置级", "\(e)") }
        } catch { check(false, "A-64-#16 只读拦截写入内置级", "\(error)") }

        // 判据 17/19：开启可写 → 迁移成功 + 自动备份 + 撤销
        TierWritePolicy.setBuiltinWritable(true)
        check(TierWritePolicy.isBuiltinWritable == true, "A-64-#17 切可写后立即生效")
        do {
            let out = try migrator.migrate(item: b1, to: .builtin, roots: roots)
            var backupOK = false
            if let b = out.backupPath { backupOK = fm.fileExists(atPath: b) }
            check(backupOK, "A-64-#19 写内置级前自动备份", out.backupPath ?? "nil")
            check(fm.fileExists(atPath: out.destinationPath), "A-64-#17 可写后内置级迁移成功")
            let undone = try migrator.undoLastMigration(roots: roots)
            check(fm.fileExists(atPath: undone.destinationPath) && !fm.fileExists(atPath: out.destinationPath),
                  "A-64 撤销上次迁移", "回到 \(undone.toTier.displayName)")
        } catch { check(false, "A-64-#17/#19 可写迁移+备份+撤销", "\(error)") }

        // 切回只读立即生效
        TierWritePolicy.setBuiltinWritable(false)
        let b2 = makeItem("B2", .user)
        do {
            _ = try migrator.migrate(item: b2, to: .builtin, roots: roots)
            check(false, "A-64-#17 切回只读立即禁用")
        } catch let e as MigrationError {
            if case .builtinReadOnly = e { check(true, "A-64-#17 切回只读立即禁用") }
            else { check(false, "A-64-#17 切回只读立即禁用", "\(e)") }
        } catch { check(false, "A-64-#17 切回只读立即禁用", "\(error)") }

        // 软链接项拒绝迁移（防止搬断链）
        let linkPath = "\(userRoot)/Titles.localized/LinkItem"
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: "\(extRoot)/Titles.localized/Extern")
        let linkItem = TemplateItem(name: "LinkItem", category: "Titles.localized", tier: .user,
                                    path: linkPath, targetPath: "\(extRoot)/Titles.localized/Extern",
                                    isSymlink: true, targetAvailable: true, sizeMB: 0)
        do {
            _ = try migrator.migrate(item: linkItem, to: .system, roots: roots)
            check(false, "A-64 软链接项拒绝直搬")
        } catch let e as MigrationError {
            if case .symlinkItemNeedsMaterialize = e { check(true, "A-64 软链接项拒绝直搬") }
            else { check(false, "A-64 软链接项拒绝直搬", "\(e)") }
        } catch { check(false, "A-64 软链接项拒绝直搬", "\(error)") }

        print("\nRESULT checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
