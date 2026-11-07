import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r42_harness.swift
//  开发任务单 R42 —— 隐藏图层即时重析与外置存储搬家系统直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R42Harness {
    static var totalChecks = 0
    static var failedChecks = 0

    static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        totalChecks += 1
        if condition {
            let extra = detail.isEmpty ? "" : " | \(detail)"
            print("✅ PASS | \(title)\(extra)")
        } else {
            failedChecks += 1
            let extra = detail.isEmpty ? "" : " | 详情: \(detail)"
            print("❌ FAIL | \(title)\(extra)")
        }
    }

    static func waitOnMainRunLoop(timeout: TimeInterval = 6.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R42 隐藏图层即时重析与外置存储搬家直证")
        print("==================================================")

        test1_A72_InstantReparseOnHiddenToggle()
        test2_A72_ResourceCardViewToggleAndBadge()
        test3_A73_HiddenLayersConservationAndNoFalseWarnings()
        test4_StorageMigration_FullMoveAndSymlink()
        test5_StorageMigration_RestoreToInternal()
        test6_StorageMigration_CategoryMoveAndRestore()
        test7_StorageMigrationDashboardAndSidebar()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：A-72 UI「显示隐藏图层」开关即时重析 (1层 -> 12层 -> 1层可逆动态改变)
    // ─────────────────────────────────────────────────────────────
    static func test1_A72_InstantReparseOnHiddenToggle() {
        print("\n── 判据 1：A-72 UI 开关即时重析 (MainWindowController) ──")
        let zxPath = "docs/r33_evidence/zhenxiong_equivalent.psd"
        guard FileManager.default.fileExists(atPath: zxPath) else {
            check(false, "主样本存在", "缺少 \(zxPath)")
            return
        }

        let mwc = MainWindowController()
        mwc.psdFiles = [zxPath]
        mwc.psdTableView?.reloadData()

        var parseDone = false
        var lastLayersCount = 0
        mwc.onParseCompleted = { result in
            parseDone = true
            lastLayersCount = result.layers.count
        }

        // 1. 初始加载：默认 includeHiddenLayers = false
        parseDone = false
        mwc.selectPsdFile(at: 0)
        waitOnMainRunLoop(timeout: 30.0) { parseDone }

        check(mwc.currentPsdPath == zxPath, "当前选中文件路径正确", "\(mwc.currentPsdPath ?? "")")
        check(mwc.includeHiddenLayers == false, "初始开关为关")
        check(lastLayersCount == 1, "初始解析层数为 1（仅可见层）", "count=\(lastLayersCount)")
        check(mwc.canvasView.layers.count == 1, "画布层数为 1", "canvas=\(mwc.canvasView.layers.count)")
        check(mwc.inspectorView.layers.count == 1, "属性栏层数为 1", "inspector=\(mwc.inspectorView.layers.count)")

        // 2. 翻转开关为 true：必须无需切换文件，立即触发重析，且层数动态变 12
        parseDone = false
        mwc.setIncludeHiddenLayers(true)
        waitOnMainRunLoop(timeout: 30.0) { parseDone }

        check(mwc.includeHiddenLayers == true, "开关翻转为开启")
        check(lastLayersCount == 12, "即时重析后层数展开为 12（1可见+11隐藏）", "count=\(lastLayersCount)")
        check(mwc.canvasView.layers.count == 12, "画布层数即时更新为 12", "canvas=\(mwc.canvasView.layers.count)")
        check(mwc.inspectorView.layers.count == 12, "属性栏层数即时更新为 12", "inspector=\(mwc.inspectorView.layers.count)")

        // 3. 翻转开关回 false：层数立即恢复为 1
        parseDone = false
        mwc.setIncludeHiddenLayers(false)
        waitOnMainRunLoop(timeout: 30.0) { parseDone }

        check(mwc.includeHiddenLayers == false, "开关翻转回关闭")
        check(lastLayersCount == 1, "再次重析后层数收拢为 1", "count=\(lastLayersCount)")
        check(mwc.canvasView.layers.count == 1, "画布层数恢复为 1", "canvas=\(mwc.canvasView.layers.count)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：A-72 ResourceCardView 启停 Toggle 直连与 .disabled 徽章即时更新
    // ─────────────────────────────────────────────────────────────
    static func test2_A72_ResourceCardViewToggleAndBadge() {
        print("\n── 判据 2：A-72 ResourceCardView 启停 Toggle 与徽章 ──")
        let tmpDir = "\(NSTemporaryDirectory())r42_card_test_\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let tplDir = "\(tmpDir)/TestWeddingTitle"
        try? fm.createDirectory(atPath: tplDir, withIntermediateDirectories: true)
        let motiFile = "\(tplDir)/TestWeddingTitle.moti"
        try? "test motion xml".write(toFile: motiFile, atomically: true, encoding: .utf8)

        let item = TemplateItem(
            name: "TestWeddingTitle",
            category: "Titles.localized",
            tier: .user,
            path: tplDir,
            targetPath: tplDir,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 1.5,
            isEnabled: true
        )

        let card = ResourceCardView(item: item)
        check(card.toggleButton.title.contains("开启"), "初始卡片按钮显示开启", card.toggleButton.title)
        check(card.disabledBadgeLabel.isHidden == true, "初始卡片 .disabled 徽章隐藏")

        // 模拟用户点击 Toggle 开关（直连 TemplateInstaller.shared.toggleTemplate）
        card.toggleButton.performClick(nil)

        let disabledPath = "\(tmpDir)/TestWeddingTitle.disabled"
        check(fm.fileExists(atPath: disabledPath), "磁盘目录重命名添加 .disabled", disabledPath)
        check(card.item.isEnabled == false, "卡片内部 item 状态变为 disabled")
        check(card.toggleButton.title.contains("禁用"), "卡片按钮文字变为禁用", card.toggleButton.title)
        check(card.disabledBadgeLabel.isHidden == false, "卡片 .disabled 徽章即时显现")
        check(card.disabledBadgeLabel.stringValue.contains("已停用"), "徽章文案正确", card.disabledBadgeLabel.stringValue)

        // 再次点击恢复启用
        card.toggleButton.performClick(nil)

        check(fm.fileExists(atPath: tplDir), "磁盘目录恢复原名", tplDir)
        check(card.item.isEnabled == true, "卡片内部 item 恢复 enabled")
        check(card.toggleButton.title.contains("开启"), "卡片按钮文字恢复开启", card.toggleButton.title)
        check(card.disabledBadgeLabel.isHidden == true, "卡片 .disabled 徽章恢复隐藏")

        try? fm.removeItem(atPath: tmpDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：A-73 include_hidden=True 守恒口径收紧与假告警消除
    // ─────────────────────────────────────────────────────────────
    static func test3_A73_HiddenLayersConservationAndNoFalseWarnings() {
        print("\n── 判据 3：A-73 守恒口径归正与消除假告警 ──")
        let zxPath = "docs/r33_evidence/zhenxiong_equivalent.psd"
        let socket = PSDParserSocket.shared

        // 1. includeHidden: false
        let r0 = socket.parsePSD(at: zxPath, includeHidden: false)
        check(r0.isValid, "includeHidden=false 解析成功")
        check(r0.counts.input == 13, "输入图层为 13 层", "input=\(r0.counts.input)")
        check(r0.counts.ignored == 12, "关闭时忽略 12 层（11隐藏+1底板）", "ignored=\(r0.counts.ignored)")
        check(r0.layers.count == 1, "输出图层为 1", "output=\(r0.layers.count)")
        check(r0.counts.conservationHolds, "A-69 守恒成立 (13 == 1 + 12)")
        check(r0.counts.countSumHolds, "A-69 处置计数闭合")

        let state0 = ParseDiagnosticsState.resolve(
            isValid: r0.isValid, failureReason: r0.failureReason, warnings: r0.warnings,
            width: r0.width, height: r0.height, aspectRatio: r0.aspectRatio,
            layerCount: r0.layers.count, counts: r0.counts
        )
        check(state0.tone == .orange, "关隐藏层时诊断为橙色警告")
        check(state0.text.contains("已忽略 12 层"), "正确提示忽略 12 层")
        check(state0.text.contains("勾选「显示隐藏图层」可查看"), "引导勾选隐藏图层")

        // 2. includeHidden: true (A-73 核心修复验收)
        let r1 = socket.parsePSD(at: zxPath, includeHidden: true)
        check(r1.isValid, "includeHidden=true 解析成功")
        check(r1.counts.input == 13, "输入图层依然为 13 层", "input=\(r1.counts.input)")
        check(r1.layers.count == 12, "实际输出图层为 12 层", "layers=\(r1.layers.count)")
        check(r1.counts.ignored == 1, "仅底板 1 层被忽略", "ignored=\(r1.counts.ignored)")
        check(r1.counts.degraded == 12, "12 层均作为有效位图贴图输出", "degraded=\(r1.counts.degraded)")
        check(r1.counts.preview == 11, "其中 11 层为隐藏图层", "preview=\(r1.counts.preview)")
        check(r1.counts.conservationHolds, "A-73 守恒成立 (13 == 12 + 1)", "holds=\(r1.counts.conservationHolds)")
        check(r1.counts.countSumHolds, "A-73 处置闭合 (13 == 0 + 12 + 1 + 0)", "sumHolds=\(r1.counts.countSumHolds)")

        let state1 = ParseDiagnosticsState.resolve(
            isValid: r1.isValid, failureReason: r1.failureReason, warnings: r1.warnings,
            width: r1.width, height: r1.height, aspectRatio: r1.aspectRatio,
            layerCount: r1.layers.count, counts: r1.counts
        )
        check(!state1.text.contains("已忽略 12 层"), "已消除假告警：不再谎称忽略 12 层")
        check(state1.text.contains("已忽略 1 层（1 个底板）"), "精确陈述仅忽略底板 1 层", state1.text)
        check(state1.text.contains("当前列表已展开 12 层（含 11 个隐藏预览层）"), "准确反映列表包含 12 层", state1.text)
        check(!state1.text.contains("勾选「显示隐藏图层」可查看"), "已开启时不再冗余提示用户去勾选")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：StorageMigrationManager 全量一键搬家与透明符号链接建立
    // ─────────────────────────────────────────────────────────────
    static func test4_StorageMigration_FullMoveAndSymlink() {
        print("\n── 判据 4：StorageMigrationManager 全量搬家至外置卷 ──")
        let sandboxDir = "\(NSTemporaryDirectory())r42_storage_test_\(UUID().uuidString)"
        let mockInternalRoot = "\(sandboxDir)/InternalMovies/Motion Templates.localized"
        let mockExternalVol = "\(sandboxDir)/ExternalSSD"

        let fm = FileManager.default
        try? fm.createDirectory(atPath: mockExternalVol, withIntermediateDirectories: true)

        // 构造本地数据
        let catDir = "\(mockInternalRoot)/Titles.localized/WeddingPack"
        try? fm.createDirectory(atPath: catDir, withIntermediateDirectories: true)
        try? "dummy title data 1234567890".write(toFile: "\(catDir)/WeddingPack.moti", atomically: true, encoding: .utf8)

        let mgr = StorageMigrationManager.shared
        let beforeOverview = mgr.scanStorage(motionRoot: mockInternalRoot)
        check(beforeOverview.isEntireRootSymlinked == false, "初始为本地实体目录")
        check(beforeOverview.totalPhysicalSizeBytes > 0, "初始本地物理占用 > 0")

        // 执行全量搬家
        do {
            let target = try mgr.migrateEntireLibrary(toVolumePath: mockExternalVol, motionRoot: mockInternalRoot)
            check(target == "\(mockExternalVol)/Motion Templates.localized", "返回外置目标路径正确", target)

            let afterOverview = mgr.scanStorage(motionRoot: mockInternalRoot)
            check(afterOverview.isEntireRootSymlinked == true, "搬家后本地根目录变为软链接")
            check(afterOverview.symlinkTarget == "\(mockExternalVol)/Motion Templates.localized", "软链接目标指向外置卷", afterOverview.symlinkTarget ?? "")
            check(afterOverview.totalPhysicalSizeBytes == 0, "搬家后本地系统盘物理占用降为 0 字节", "phys=\(afterOverview.totalPhysicalSizeBytes)")
            check(afterOverview.savedDiskSizeBytes > 0, "成功节省系统盘空间", afterOverview.savedDiskSizeFormatted)

            // 验证外置物理文件完整可读
            let extFile = "\(mockExternalVol)/Motion Templates.localized/Titles.localized/WeddingPack/WeddingPack.moti"
            check(fm.fileExists(atPath: extFile), "外置卷目标文件物理落盘", extFile)

            // 验证通过本地透明软链接无感读取
            let readThruLink = "\(mockInternalRoot)/Titles.localized/WeddingPack/WeddingPack.moti"
            let content = try? String(contentsOfFile: readThruLink, encoding: .utf8)
            check(content == "test motion xml" || content?.contains("dummy") == true, "FCPX 通过透明软链接无感读取成功")
        } catch {
            check(false, "全量搬家成功执行", error.localizedDescription)
        }

        try? fm.removeItem(atPath: sandboxDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：StorageMigrationManager 一键原路还原至内置系统盘
    // ─────────────────────────────────────────────────────────────
    static func test5_StorageMigration_RestoreToInternal() {
        print("\n── 判据 5：StorageMigrationManager 原路还原至内置盘 ──")
        let sandboxDir = "\(NSTemporaryDirectory())r42_restore_test_\(UUID().uuidString)"
        let mockInternalRoot = "\(sandboxDir)/InternalMovies/Motion Templates.localized"
        let mockExternalVol = "\(sandboxDir)/ExternalSSD"

        let fm = FileManager.default
        try? fm.createDirectory(atPath: mockExternalVol, withIntermediateDirectories: true)
        let catDir = "\(mockInternalRoot)/Titles.localized/RetroPack"
        try? fm.createDirectory(atPath: catDir, withIntermediateDirectories: true)
        try? "retro title motion".write(toFile: "\(catDir)/RetroPack.moti", atomically: true, encoding: .utf8)

        let mgr = StorageMigrationManager.shared
        _ = try? mgr.migrateEntireLibrary(toVolumePath: mockExternalVol, motionRoot: mockInternalRoot)

        check((try? fm.destinationOfSymbolicLink(atPath: mockInternalRoot)) != nil, "先完成外置软链状态")

        // 执行原路还原
        do {
            let restored = try mgr.restoreEntireLibraryToInternal(motionRoot: mockInternalRoot)
            check(restored == mockInternalRoot, "还原成功并返回本地路径", restored)

            let overview = mgr.scanStorage(motionRoot: mockInternalRoot)
            check(overview.isEntireRootSymlinked == false, "还原后不再是软链接")
            check(overview.totalPhysicalSizeBytes > 0, "物理数据成功迁回本地系统盘")

            let localFile = "\(mockInternalRoot)/Titles.localized/RetroPack/RetroPack.moti"
            check(fm.fileExists(atPath: localFile), "本地文件实体存在", localFile)
        } catch {
            check(false, "原路还原成功执行", error.localizedDescription)
        }

        try? fm.removeItem(atPath: sandboxDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：StorageMigrationManager 分类级别搬迁与回迁
    // ─────────────────────────────────────────────────────────────
    static func test6_StorageMigration_CategoryMoveAndRestore() {
        print("\n── 判据 6：StorageMigrationManager 分类级外置搬迁 ──")
        let sandboxDir = "\(NSTemporaryDirectory())r42_cat_test_\(UUID().uuidString)"
        let mockInternalRoot = "\(sandboxDir)/InternalMovies/Motion Templates.localized"
        let mockExternalVol = "\(sandboxDir)/ExternalSSD"
        let fm = FileManager.default

        try? fm.createDirectory(atPath: "\(mockInternalRoot)/Titles.localized/Demo", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(mockInternalRoot)/Effects.localized/Demo", withIntermediateDirectories: true)
        try? "titles data".write(toFile: "\(mockInternalRoot)/Titles.localized/Demo/Demo.moti", atomically: true, encoding: .utf8)
        try? "effects data".write(toFile: "\(mockInternalRoot)/Effects.localized/Demo/Demo.moef", atomically: true, encoding: .utf8)

        let mgr = StorageMigrationManager.shared

        // 仅搬迁 Titles.localized
        do {
            _ = try mgr.migrateCategory(category: "Titles.localized", toVolumePath: mockExternalVol, motionRoot: mockInternalRoot)

            let ov = mgr.scanStorage(motionRoot: mockInternalRoot)
            let titlesCat = ov.categories.first(where: { $0.category == "Titles.localized" })
            let effectsCat = ov.categories.first(where: { $0.category == "Effects.localized" })

            check(titlesCat?.isSymlink == true, "Titles 分类已建立外置软链接")
            check(effectsCat?.isSymlink == false, "Effects 分类保持内置状态")

            // 还原 Titles
            _ = try mgr.restoreCategory(category: "Titles.localized", motionRoot: mockInternalRoot)
            let ov2 = mgr.scanStorage(motionRoot: mockInternalRoot)
            let titlesCat2 = ov2.categories.first(where: { $0.category == "Titles.localized" })
            check(titlesCat2?.isSymlink == false, "Titles 分类成功还原回本地")
        } catch {
            check(false, "分类级迁移执行", error.localizedDescription)
        }

        try? fm.removeItem(atPath: sandboxDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 7：StorageMigrationDashboardView 仪表盘与侧边栏接入
    // ─────────────────────────────────────────────────────────────
    static func test7_StorageMigrationDashboardAndSidebar() {
        print("\n── 判据 7：StorageMigrationDashboardView 与侧边栏接入 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        check(hub.sidebarButtons.count >= 9, "侧边栏按钮包含 9 项以上", "count=\(hub.sidebarButtons.count)")

        let storageBtn = hub.sidebarButtons.first(where: { $0.tag == 8 })
        check(storageBtn != nil, "侧边栏已挂载【💾 存储与搬家】按钮")
        check(storageBtn?.title.contains("存储与搬家") == true, "按钮文案正确", storageBtn?.title ?? "")

        // 切换到存储管理中心
        hub.selectSidebarItem(at: 8)
        check(hub.currentSidebarIndex == 8, "当前选中侧边栏索引为 8")
        check(hub.storageContainerView.isHidden == false, "存储中心容器显示")
        check(hub.templateContainerView.isHidden == true, "其他模块容器隐去")

        let dash = hub.storageMigrationDashboardView!
        waitOnMainRunLoop(timeout: 5.0) { dash.currentOverview != nil }
        check(dash.categoryTableView.numberOfRows == 4, "分类明细表格包含 4 个 Motion 分类", "rows=\(dash.categoryTableView.numberOfRows)")
        check(dash.refreshButton != nil && dash.migrateAllButton != nil && dash.restoreAllButton != nil, "主操作按钮完备")
        check(!dash.physicalSizeValueLabel.stringValue.isEmpty, "物理占用指标卡已填充", dash.physicalSizeValueLabel.stringValue)

        // MainWindowController 跳转测试
        let mwc = MainWindowController()
        mwc.showStorageMigration()
        check(mwc.segmentedControl.selectedSegment == 1, "主窗口控制器切换至引擎二")
        check(mwc.assetHubView.currentSidebarIndex == 8, "主窗口联动侧边栏切换至存储与搬家中心")
    }
}
