// ═══════════════════════════════════════════════════════════════
//  R37 引擎二对标嘉星：一键安装引擎与模板启停系统自动化直证 Harness
//  对标基准：/Applications/嘉星插件管理 2.app (com.FxXu.0412)
// ═══════════════════════════════════════════════════════════════

import AppKit
import Foundation

@main
struct R37InstallerToggleHarness {
    static var failures = 0
    static var checks = 0

    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        let status = cond ? "✅ PASS" : "❌ FAIL"
        print("\(status) | \(name)\(detail.isEmpty ? "" : " | " + detail)")
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R37 一键安装与模板启停 Harness 开始")
        print("==================================================")

        let rootDir = FileManager.default.currentDirectoryPath
        let evidenceDir = "\(rootDir)/docs/r37_evidence"
        try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPX_R37_Harness_\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempRoot)
        }

        test1_CategorySmartRecognition()
        test2_ZipUnpackAndSafeInstall(tempRoot: tempRoot)
        test3_TemplateDisableIsolation(tempRoot: tempRoot)
        test4_TemplateEnableRestoration(tempRoot: tempRoot)
        test5_AllCategoriesNavigationAndStats(tempRoot: tempRoot)
        test6_AppBinaryAndSignature(rootDir: rootDir)

        print("==================================================")
        print("  总计检查点: \(checks) | 失败: \(failures)")
        print("==================================================")
        exit(failures == 0 ? 0 : 1)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：模板分类智能识别（100% 准确探测四大类）
    // ─────────────────────────────────────────────────────────────
    static func test1_CategorySmartRecognition() {
        print("\n── 判据 1：模板分类智能识别（.moti / .moef / .motr / .motn）──")

        check(MotionCategory.fromExtension("moti") == .titles, "扩展名 moti -> Titles.localized (字幕)")
        check(MotionCategory.fromExtension(".moti") == .titles, "带点扩展名 .moti -> Titles.localized")
        check(MotionCategory.fromExtension("moef") == .effects, "扩展名 moef -> Effects.localized (特效)")
        check(MotionCategory.fromExtension("motr") == .transitions, "扩展名 motr -> Transitions.localized (转场)")
        check(MotionCategory.fromExtension("motn") == .generators, "扩展名 motn -> Generators.localized (发生器)")
        check(MotionCategory.fromExtension("xyz") == nil, "非法扩展名识别为 nil")

        check(MotionCategory.titles.displayName == "字幕", "字幕显示名准确")
        check(MotionCategory.effects.displayName == "特效", "特效显示名准确")
        check(MotionCategory.transitions.displayName == "转场", "转场显示名准确")
        check(MotionCategory.generators.displayName == "发生器", "发生器显示名准确")

        // 临时构造四大分类模板目录进行全量 discoverTemplates 探测
        let fm = FileManager.default
        let sampleDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("R37_Recognition_\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: sampleDir) }

        let titleFolder = "\(sampleDir)/SubTheme1/MyTitle"
        let effectFolder = "\(sampleDir)/SubTheme2/MyEffect"
        let transFolder = "\(sampleDir)/SubTheme3/MyTransition"
        let genFolder = "\(sampleDir)/SubTheme4/MyGenerator"

        try? fm.createDirectory(atPath: titleFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: effectFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: transFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: genFolder, withIntermediateDirectories: true)

        fm.createFile(atPath: "\(titleFolder)/MyTitle.moti", contents: Data("motion title".utf8))
        fm.createFile(atPath: "\(effectFolder)/MyEffect.moef", contents: Data("motion effect".utf8))
        fm.createFile(atPath: "\(transFolder)/MyTransition.motr", contents: Data("motion trans".utf8))
        fm.createFile(atPath: "\(genFolder)/MyGenerator.motn", contents: Data("motion gen".utf8))

        let discovered = TemplateInstaller.discoverTemplates(inDirectory: sampleDir)
        check(discovered.count == 4, "智能扫描出全部 4 个不同分类的模板", "count=\(discovered.count)")

        let titleItem = discovered.first { $0.templateName == "MyTitle" }
        check(titleItem?.category == .titles, "MyTitle 归入 Titles", "category=\(titleItem?.category.rawValue ?? "")")
        check(titleItem?.subcategory == "SubTheme1", "MyTitle 提取子分类 SubTheme1")

        let effectItem = discovered.first { $0.templateName == "MyEffect" }
        check(effectItem?.category == .effects, "MyEffect 归入 Effects")

        let transItem = discovered.first { $0.templateName == "MyTransition" }
        check(transItem?.category == .transitions, "MyTransition 归入 Transitions")

        let genItem = discovered.first { $0.templateName == "MyGenerator" }
        check(genItem?.category == .generators, "MyGenerator 归入 Generators")

        // 拖拽感知检测
        check(TemplateInstaller.acceptsDrop(paths: [sampleDir]) == true, "acceptsDrop 识别有效模板目录为 true")
        check(TemplateInstaller.acceptsDrop(paths: ["/tmp/nonexistent.zip"]) == true, "acceptsDrop 识别 .zip 文件扩展名")
        check(TemplateInstaller.acceptsDrop(paths: ["/bin/zsh"]) == false, "acceptsDrop 识别普通文件为 false")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：Zip 一键解压安装与安全防覆盖
    // ─────────────────────────────────────────────────────────────
    static func test2_ZipUnpackAndSafeInstall(tempRoot: String) {
        print("\n── 判据 2：Zip 一键解压安装与防覆盖隔离 ──")

        let fm = FileManager.default
        let stagingDir = "\(tempRoot)/zip_staging"
        let templateFolder = "\(stagingDir)/CinematicPack/EpicIntro"
        try? fm.createDirectory(atPath: templateFolder, withIntermediateDirectories: true)

        let motiContent = "<motion-project version=\"1.0\"><title>Epic</title></motion-project>"
        fm.createFile(atPath: "\(templateFolder)/EpicIntro.moti", contents: Data(motiContent.utf8))
        fm.createFile(atPath: "\(templateFolder)/large_media.bin", contents: Data(repeating: 0x41, count: 50_000))

        // 打包为 zip
        let zipPath = "\(tempRoot)/TestTemplate.zip"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", stagingDir, zipPath]
        try? process.run()
        process.waitUntilExit()

        check(fm.fileExists(atPath: zipPath), "模拟 Zip 安装包打包成功", zipPath)

        // 执行安装至虚拟用户根目录
        let userRoot = "\(tempRoot)/UserMotionTemplates"
        let backupRoot = "\(tempRoot)/Backups"
        setenv("FCPXSTUDIO_BACKUP_ROOT", backupRoot, 1)

        do {
            let results = try TemplateInstaller.installTemplates(paths: [zipPath], targetTierRoot: userRoot)
            check(results.count >= 1, "Zip 一键安装成功返回结果", "count=\(results.count)")

            let installed = results.first { $0.templateName == "EpicIntro" }
            check(installed != nil, "EpicIntro 成功安装")
            check(installed?.category == "Titles.localized", "自动分流归入 Titles.localized")

            let expectedPath = "\(userRoot)/Titles.localized/\(installed?.subcategory ?? "")/EpicIntro"
            check(fm.fileExists(atPath: expectedPath), "模板落盘目录存在", expectedPath)
            check(fm.fileExists(atPath: "\(expectedPath)/EpicIntro.moti"), "模板核心 .moti 文件存在且完整")

            // 再次安装：触发防覆盖原子备份
            let secondResults = try TemplateInstaller.installTemplates(paths: [zipPath], targetTierRoot: userRoot)
            check(secondResults.first?.backupPath != nil, "重复安装触发防覆盖备份，返回备份路径", secondResults.first?.backupPath ?? "")
            if let bPath = secondResults.first?.backupPath {
                check(fm.fileExists(atPath: bPath), "安全备份文件实际存在于隔离区", bPath)
            }
        } catch {
            check(false, "Zip 安装抛出异常: \(error.localizedDescription)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：模板一键禁用 (Disable 隔离机制)
    // ─────────────────────────────────────────────────────────────
    static func test3_TemplateDisableIsolation(tempRoot: String) {
        print("\n── 判据 3：模板一键禁用（.disabled 机制与内置保护）──")

        let fm = FileManager.default
        let userRoot = "\(tempRoot)/UserMotionTemplates"
        let catDir = "\(userRoot)/Titles.localized"
        let templateDir = "\(catDir)/ActiveTemplate"
        try? fm.createDirectory(atPath: templateDir, withIntermediateDirectories: true)
        fm.createFile(atPath: "\(templateDir)/ActiveTemplate.moti", contents: Data("active".utf8))

        // 初始扫描
        let roots = TemplateTierRoots(builtin: nil, user: userRoot, system: "\(tempRoot)/system", builtinNote: "")
        let initialScan = TemplateTierScanner.scan(category: "Titles.localized", roots: roots)
        guard let item = initialScan.items.first(where: { $0.name == "ActiveTemplate" }) else {
            check(false, "扫描初始模板失败")
            return
        }

        check(item.isEnabled == true, "新创建模板默认 isEnabled == true")
        check(!item.path.hasSuffix(".disabled"), "初始模板路径无 .disabled")

        // 执行禁用
        do {
            let disabledItem = try TemplateInstaller.toggleTemplate(item: item)
            check(disabledItem.isEnabled == false, "禁用后返回 isEnabled == false")
            check(disabledItem.name == "ActiveTemplate", "禁用后展示名称自动去除 .disabled 后缀", disabledItem.name)
            check(disabledItem.path.hasSuffix(".disabled"), "禁用后物理路径带 .disabled 后缀", disabledItem.path)
            check(fm.fileExists(atPath: disabledItem.path), "物理 .disabled 目录存在")
            check(!fm.fileExists(atPath: item.path), "原路径已原子迁移")
            check(fm.fileExists(atPath: "\(disabledItem.path)/ActiveTemplate.moti"), "内部资源 0 丢失完整保留")

            // 重新扫描验证扫描器
            let scanAfterDisable = TemplateTierScanner.scan(category: "Titles.localized", roots: roots)
            let scannedDisabled = scanAfterDisable.items.first { $0.name == "ActiveTemplate" }
            check(scannedDisabled != nil, "扫描器能列出休眠模板")
            check(scannedDisabled?.isEnabled == false, "扫描器准确识别带有 .disabled 目录的模板为 isEnabled = false")
            check(scannedDisabled?.name == "ActiveTemplate", "扫描器展示名称无 .disabled 后缀")
        } catch {
            check(false, "toggleTemplate 失败: \(error.localizedDescription)")
        }

        // 内置模板只读保护验证
        let builtinDir = "\(tempRoot)/BuiltinRoot"
        let builtinCat = "\(builtinDir)/Titles.localized"
        let builtinTemplate = "\(builtinCat)/SystemBuiltinTitle"
        try? fm.createDirectory(atPath: builtinTemplate, withIntermediateDirectories: true)
        fm.createFile(atPath: "\(builtinTemplate)/SystemBuiltinTitle.moti", contents: Data("b".utf8))

        TierWritePolicy.setBuiltinWritable(false)
        let builtinItem = TemplateItem(
            name: "SystemBuiltinTitle",
            category: "Titles.localized",
            tier: .builtin,
            path: builtinTemplate,
            targetPath: builtinTemplate,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 1.0,
            isEnabled: true
        )

        var protectedBlocked = false
        do {
            _ = try TemplateInstaller.toggleTemplate(item: builtinItem)
        } catch let err as TemplateToggleError {
            if case .builtinProtected = err {
                protectedBlocked = true
            }
        } catch {}
        check(protectedBlocked, "内置只读模板被保护拦截，严禁未授权修改")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：模板一键启用 (Enable 复原机制)
    // ─────────────────────────────────────────────────────────────
    static func test4_TemplateEnableRestoration(tempRoot: String) {
        print("\n── 判据 4：模板一键启用（秒级复原与可用性）──")

        let fm = FileManager.default
        let userRoot = "\(tempRoot)/UserMotionTemplates"
        let roots = TemplateTierRoots(builtin: nil, user: userRoot, system: "\(tempRoot)/system", builtinNote: "")

        let scan = TemplateTierScanner.scan(category: "Titles.localized", roots: roots)
        guard let disabledItem = scan.items.first(where: { $0.name == "ActiveTemplate" && !$0.isEnabled }) else {
            check(false, "未找到待唤醒的已休眠模板")
            return
        }

        do {
            let enabledItem = try TemplateInstaller.toggleTemplate(item: disabledItem)
            check(enabledItem.isEnabled == true, "启用后返回 isEnabled == true")
            check(enabledItem.name == "ActiveTemplate", "启用后名称正确")
            check(!enabledItem.path.hasSuffix(".disabled"), "启用后路径去除 .disabled 后缀", enabledItem.path)
            check(fm.fileExists(atPath: enabledItem.path), "复原物理路径存在")
            check(fm.fileExists(atPath: "\(enabledItem.path)/ActiveTemplate.moti"), "模板数据与核心文件完整复原")

            // 再次扫描验证
            let scan2 = TemplateTierScanner.scan(category: "Titles.localized", roots: roots)
            let scannedEnabled = scan2.items.first { $0.name == "ActiveTemplate" }
            check(scannedEnabled?.isEnabled == true, "扫描器确认状态已切回 🟢 已启用")
        } catch {
            check(false, "唤醒模板失败: \(error.localizedDescription)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：全分类导航与状态统计条升级
    // ─────────────────────────────────────────────────────────────
    static func test5_AllCategoriesNavigationAndStats(tempRoot: String) {
        print("\n── 判据 5：全分类导航与状态统计条（Titles / Effects / Transitions / Generators）──")

        let fm = FileManager.default
        let userRoot = "\(tempRoot)/UserMotionTemplates"
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", userRoot, 1)
        setenv("FCPXSTUDIO_SYSTEM_TEMPLATES_ROOT", "\(tempRoot)/SystemTemplates", 1)
        setenv("FCPXSTUDIO_BUILTIN_TEMPLATES_ROOT", "\(tempRoot)/BuiltinRoot", 1)

        // 在四大分类分别放置测试模板
        for cat in TemplateTierScanner.categories {
            let catDir = "\(userRoot)/\(cat)"
            let t1 = "\(catDir)/T1_Enabled"
            let t2 = "\(catDir)/T2_Sleeping.disabled"
            try? fm.createDirectory(atPath: t1, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: t2, withIntermediateDirectories: true)
            fm.createFile(atPath: "\(t1)/marker.dat", contents: Data("1".utf8))
            fm.createFile(atPath: "\(t2)/marker.dat", contents: Data("2".utf8))
        }

        let assetHub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        check(assetHub.dropOverlayView != nil, "Drop Overlay 视图初始化完备")
        check(assetHub.dropOverlayView.isHidden == true, "Drop Overlay 默认隐藏")

        // 验证各分类切换与统计条
        let expectedCategories = [
            ("Titles.localized", "字幕"),
            ("Effects.localized", "特效"),
            ("Transitions.localized", "转场"),
            ("Generators.localized", "发生器")
        ]

        for (cat, displayName) in expectedCategories {
            assetHub.selectCategory(cat)
            check(assetHub.currentCategory == cat, "准确切换到分类: \(cat)")
            check(assetHub.categoryPopup.title.contains(cat), "分类下拉菜单同步选中: \(cat)")

            let stats = assetHub.tierStatsLabel.stringValue
            check(stats.contains(displayName), "统计条展示当前分类中文名: \(displayName)", stats)
            check(stats.contains("已启用"), "统计条展示已启用计数", stats)
            check(stats.contains("已休眠"), "统计条展示已休眠计数", stats)
        }

        // 验证表格「状态」列呈现与点击交互
        assetHub.selectCategory("Titles.localized")
        let colStatus = assetHub.pluginTableView.tableColumns.first { $0.identifier.rawValue == "status" }
        check(colStatus != nil, "表格中存在「状态」列 (status)")
        check(colStatus?.title == "状态", "状态列标题正确")

        let rowCount = assetHub.numberOfRows(in: assetHub.pluginTableView)
        check(rowCount >= 2, "当前分类正确包含测试模板项", "rowCount=\(rowCount)")

        // 获取第一个模板的 cell 视图
        if let cellView = assetHub.tableView(assetHub.pluginTableView, viewFor: colStatus, row: 0) {
            let btn = cellView.subviews.compactMap { $0 as? NSButton }.first
            check(btn != nil, "状态列成功渲染操作按钮")
            check(btn?.title.contains("已启用") == true || btn?.title.contains("已休眠") == true, "状态按钮文案符合规范", btn?.title ?? "")
        }

        // 验证通过 AssetHubView 切换状态
        // 1. 内置模板触发只读保护拦截
        if let builtinIdx = assetHub.plugins.firstIndex(where: { $0.tier == .builtin }) {
            var protected = false
            do {
                _ = try assetHub.toggleItem(at: builtinIdx)
            } catch let err as TemplateToggleError {
                if case .builtinProtected = err { protected = true }
            } catch {}
            check(protected, "AssetHubView 触发内置模板点击时受到只读保护拦截")
        }

        // 2. 用户模板成功一键翻转
        if let userIdx = assetHub.plugins.firstIndex(where: { $0.tier == .user }) {
            let initialEnabled = assetHub.plugins[userIdx].isEnabled
            do {
                let updated = try assetHub.toggleItem(at: userIdx)
                check(updated.isEnabled != initialEnabled, "通过 AssetHubView 一键切换用户模板状态成功", "now=\(updated.isEnabled)")
            } catch {
                check(false, "AssetHubView.toggleItem 失败: \(error.localizedDescription)")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：全量回归与构建产物一致性
    // ─────────────────────────────────────────────────────────────
    static func test6_AppBinaryAndSignature(rootDir: String) {
        print("\n── 判据 6：应用二进制与签名合规性 ──")

        let appPath = "\(rootDir)/FCPX Studio Pro.app"
        let binaryPath = "\(appPath)/Contents/MacOS/FCPXStudio"
        let fm = FileManager.default

        check(fm.fileExists(atPath: appPath), "FCPX Studio Pro.app 应用包存在")
        check(fm.fileExists(atPath: binaryPath), "原生 Mach-O 二进制存在", binaryPath)

        // 验证签名
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-v", "--verbose=2", appPath]
        let pipe = Pipe()
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()

        check(process.terminationStatus == 0, "codesign 校验签名有效 (Exit Code 0)")
    }
}
