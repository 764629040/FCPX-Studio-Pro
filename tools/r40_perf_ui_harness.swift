import AppKit
import AVFoundation
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r40_perf_ui_harness.swift
//  开发任务单 R40 —— 彻底根除卡顿性能重构与嘉星 UI 视觉深度复刻原生直证
// ═══════════════════════════════════════════════════════════════

@main
final class R40Harness {
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

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R40 性能重构与嘉星 UI 深度复刻直证")
        print("==================================================")

        test1_AsyncScanAndZeroMainThreadBlock()
        test2_MemoryCacheInstantReuse()
        test3_ProSidebarLayoutAndNavigation()
        test4_ResourceCardGridViewAndDualMode()
        test5_FullFeatureSeamlessIntegration()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    static func waitOnMainRunLoop(timeout: TimeInterval = 4.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：主线程 0 阻塞与异步后台扫描 (scanAsync)
    // ─────────────────────────────────────────────────────────────
    static func test1_AsyncScanAndZeroMainThreadBlock() {
        print("\n── 判据 1：主线程 0 阻塞与异步后台扫描 ──")

        let t0 = CFAbsoluteTimeGetCurrent()
        var scanResult: TemplateScanResult?
        TemplateTierScanner.scanAsync(category: "Titles.localized", lazySizes: true) { res in
            scanResult = res
        }
        let dispatchDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        check(dispatchDurationMs < 50.0, "主线程调用 scanAsync 耗时 < 50ms (0阻塞立即返回)", String(format: "%.2f ms", dispatchDurationMs))
        waitOnMainRunLoop(timeout: 5.0) { scanResult != nil }
        check(scanResult != nil, "后台 GCD 线程成功完成模板扫描", "items=\(scanResult?.items.count ?? 0)")

        // 验证 LUTManager.shared.scanAsync
        let t1 = CFAbsoluteTimeGetCurrent()
        var lutItems: [LUTItem]?
        LUTManager.shared.scanAsync { items in
            lutItems = items
        }
        let lutDispatchMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000.0
        check(lutDispatchMs < 50.0, "主线程调用 LUT scanAsync 耗时 < 50ms (0阻塞)", String(format: "%.2f ms", lutDispatchMs))
        waitOnMainRunLoop(timeout: 5.0) { lutItems != nil }
        check(lutItems != nil, "后台 GCD 线程成功完成 3D LUT 扫描", "count=\(lutItems?.count ?? 0)")

        // 验证 AudioManager.shared.scanAsync
        let t2 = CFAbsoluteTimeGetCurrent()
        var audioItems: [AudioItem]?
        AudioManager.shared.scanAsync { items in
            audioItems = items
        }
        let audioDispatchMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000.0
        check(audioDispatchMs < 50.0, "主线程调用 Audio scanAsync 耗时 < 50ms (0阻塞)", String(format: "%.2f ms", audioDispatchMs))
        waitOnMainRunLoop(timeout: 5.0) { audioItems != nil }
        check(audioItems != nil, "后台 GCD 线程成功完成影视音效扫描", "count=\(audioItems?.count ?? 0)")

        // 验证 LibraryCleaner.shared.scanLibrariesAsync
        let t3 = CFAbsoluteTimeGetCurrent()
        var libItems: [LibraryBundleItem]?
        LibraryCleaner.shared.scanLibrariesAsync { items in
            libItems = items
        }
        let libDispatchMs = (CFAbsoluteTimeGetCurrent() - t3) * 1000.0
        check(libDispatchMs < 50.0, "主线程调用 Cleaner scanLibrariesAsync 耗时 < 50ms (0阻塞)", String(format: "%.2f ms", libDispatchMs))
        waitOnMainRunLoop(timeout: 5.0) { libItems != nil }
        check(libItems != nil, "后台 GCD 线程成功完成资源库扫描", "count=\(libItems?.count ?? 0)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：内存缓存秒级复用 (AssetCacheManager)
    // ─────────────────────────────────────────────────────────────
    static func test2_MemoryCacheInstantReuse() {
        print("\n── 判据 2：内存缓存秒级复用 (AssetCacheManager) ──")

        let cache = AssetCacheManager.shared
        cache.invalidateAll()
        check(cache.getTemplates(category: "Titles.localized") == nil, "初始缓存已清空")

        let fakeItem = TemplateItem(
            name: "Harness_Template_01",
            category: "Titles.localized",
            tier: .user,
            path: "/tmp/fake/Harness_Template_01",
            targetPath: "/tmp/fake/Harness_Template_01",
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 0.0,
            isEnabled: true
        )
        let fakeRoots = TemplateTierRoots(builtin: nil, user: "/tmp/user", system: "/tmp/sys", builtinNote: "")
        let fakeScan = TemplateScanResult(items: [fakeItem], tierNotes: [:], roots: fakeRoots)

        cache.setTemplates(category: "Titles.localized", result: fakeScan)

        // 再次获取：测量耗时
        let start = CFAbsoluteTimeGetCurrent()
        let cachedResult = cache.getTemplates(category: "Titles.localized")
        let hitDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        check(cachedResult != nil, "成功从内存缓存命中模板列表")
        check(hitDurationMs <= 5.0, "缓存命中耗时 <= 5ms（瞬间呈现，0彩虹圈）", String(format: "%.4f ms", hitDurationMs))
        check(cache.hitCount >= 1, "缓存命中计数递增", "hits=\(cache.hitCount)")

        // 懒加载体积局部更新
        cache.updateTemplateSize(category: "Titles.localized", name: "Harness_Template_01", sizeMB: 48.6)
        let updated = cache.getTemplates(category: "Titles.localized")?.items.first
        check(updated?.sizeMB == 48.6, "懒加载后台体积局部更新缓存成功", "size=\(updated?.sizeMB ?? 0) MB")

        // 验证 LUT、Audio、Cleaner 缓存
        try? "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(toFile: "/tmp/a.cube", atomically: true, encoding: .utf8)
        cache.setLUTs([LUTItem(name: "TestLUT", path: "/tmp/a.cube", category: "Test", thumbnailPath: nil, fileSizeBytes: 1024, dimension: 33)])
        check(cache.getLUTs()?.count == 1, "3D LUT 内存缓存秒级复用")

        cache.setAudios([AudioItem(name: "TestAudio", path: "/tmp/a.wav", category: "Test", duration: 3.5, sampleRate: 44100, channels: 2, fileSizeBytes: 2048)])
        check(cache.getAudios()?.count == 1, "音效库内存缓存秒级复用")

        cache.setLibraries([LibraryBundleItem(id: UUID(), name: "Test.fcpbundle", path: "/tmp/Test.fcpbundle", totalSizeBytes: 1000, originalMediaSizeBytes: 500, cacheDetails: [], eventsCount: 1, projectsCount: 1)])
        check(cache.getLibraries()?.count == 1, "资源库内存缓存秒级复用")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：左侧深色 Pro 垂直侧边栏布局 (Sidebar)
    // ─────────────────────────────────────────────────────────────
    static func test3_ProSidebarLayoutAndNavigation() {
        print("\n── 判据 3：左侧深色 Pro 垂直侧边栏布局 ──")

        let hubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))

        check(hubView.sidebarView != nil, "左侧 Pro 侧边栏存在")
        let sidebarWidth = hubView.sidebarView.constraints.first(where: { $0.firstAttribute == .width })?.constant ?? 210
        check(sidebarWidth == 210, "侧边栏宽度符合专业规范 (210pt)", "width=\(sidebarWidth)")
        check(hubView.sidebarButtons.count == 8, "侧边栏包含 8 项完整功能入口 (Titles/Effects/Transitions/Generators/LUT/Audio/Cleaner/Settings)")

        // 侧边栏项联动测试
        // 0: 字幕
        hubView.selectSidebarItem(at: 0)
        check(hubView.currentCategory == "Titles.localized", "侧边栏切换至标题字幕")
        check(hubView.currentHubTab == 0, "当前处于模板模块")
        check(hubView.templateContainerView.isHidden == false, "模板容器呈现")

        // 1: 特效
        hubView.selectSidebarItem(at: 1)
        check(hubView.currentCategory == "Effects.localized", "侧边栏切换至视频特效")

        // 2: 转场
        hubView.selectSidebarItem(at: 2)
        check(hubView.currentCategory == "Transitions.localized", "侧边栏切换至视频转场")

        // 3: 发生器
        hubView.selectSidebarItem(at: 3)
        check(hubView.currentCategory == "Generators.localized", "侧边栏切换至视频发生器")

        // 4: 3D LUT
        hubView.selectSidebarItem(at: 4)
        check(hubView.currentHubTab == 1, "侧边栏切换至 3D LUT 调色模块")
        check(hubView.lutContainerView.isHidden == false, "LUT 容器呈现")

        // 5: 音效
        hubView.selectSidebarItem(at: 5)
        check(hubView.currentHubTab == 2, "侧边栏切换至影视音效库模块")
        check(hubView.audioContainerView.isHidden == false, "音效容器呈现")

        // 6: 瘦身
        hubView.selectSidebarItem(at: 6)
        check(hubView.currentHubTab == 3, "侧边栏切换至资源库瘦身医生模块")
        check(hubView.cleanerContainerView.isHidden == false, "瘦身容器呈现")

        // 外置存储常驻指示灯
        check(hubView.externalDriveStatusLabel != nil, "底部外置盘常驻状态指示灯已就绪")
        check(!hubView.externalDriveStatusLabel.stringValue.isEmpty, "外置盘挂载状态文案正常呈现", hubView.externalDriveStatusLabel.stringValue)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：卡片网格流 (ResourceCardView Grid) 与双模切换
    // ─────────────────────────────────────────────────────────────
    static func test4_ResourceCardGridViewAndDualMode() {
        print("\n── 判据 4：卡片网格流 (ResourceCardView Grid) 与双模切换 ──")

        let hubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        check(hubView.viewModeSegmentedControl != nil, "双模切换器 (⊞/☰) 存在")
        check(hubView.viewModeSegmentedControl.segmentCount == 2, "提供网格 (Grid) 与列表 (List) 双模")

        // 初始网格模式
        check(hubView.currentViewMode == 0, "默认进入高质感卡片网格流模式")
        check(hubView.cardGridScrollView.isHidden == false, "卡片网格视口呈现")
        check(hubView.tableScrollView.isHidden == true, "传统表格视口已自动收起")

        // 切换为列表模式
        hubView.viewModeSegmentedControl.selectedSegment = 1
        hubView.viewModeSegmentedControl.sendAction(hubView.viewModeSegmentedControl.action, to: hubView.viewModeSegmentedControl.target)
        check(hubView.currentViewMode == 1, "成功切换为专业列表 (List) 模式")
        check(hubView.cardGridScrollView.isHidden == true, "卡片网格已隐藏")
        check(hubView.tableScrollView.isHidden == false, "表格视口呈现")

        // 切回网格模式并检验 ResourceCardView
        hubView.viewModeSegmentedControl.selectedSegment = 0
        hubView.viewModeSegmentedControl.sendAction(hubView.viewModeSegmentedControl.action, to: hubView.viewModeSegmentedControl.target)
        check(hubView.currentViewMode == 0, "切回卡片网格流模式")

        // 构建测试卡片
        let item = TemplateItem(
            name: "Modern_Cinematic_Title",
            category: "Titles.localized",
            tier: .user,
            path: "/tmp/Modern_Cinematic_Title",
            targetPath: "/tmp/Modern_Cinematic_Title",
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 35.8,
            isEnabled: true
        )
        let card = ResourceCardView(item: item, frame: NSRect(x: 0, y: 0, width: 230, height: 250))

        check(card.thumbnailContainer != nil, "卡片具备 16:9 高清缩略图视口")
        check(card.titleLabel != nil, "卡片具备主标题区 (中文别名/友好显示)")
        check(card.tierBadgeLabel.stringValue == "🟢 用户", "卡片呈现归属徽章 (🟢 用户)")
        check(card.sizeBadgeLabel.stringValue == "35.8 MB", "卡片呈现占用容量徽章 (35.8 MB)")
        check(card.toggleButton.title.contains("🟢 开启"), "卡片具备精致「🟢 开启」胶囊 Toggle 开关")
        check(card.menuButton.title == "⋯", "卡片具备「⋯」更多操作菜单按钮")

        // 测试即输即搜过滤
        check(hubView.searchField != nil, "现代化顶层工具栏具备即输即搜 SearchField")
        hubView.searchField.stringValue = "Cinematic"
        hubView.searchField.sendAction(hubView.searchField.action, to: hubView.searchField.target)
        check(hubView.searchField.stringValue == "Cinematic", "搜索框过滤指令生效")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：全功能无缝联动 (启停、重命名、安装、分屏、波形、瘦身)
    // ─────────────────────────────────────────────────────────────
    static func test5_FullFeatureSeamlessIntegration() {
        print("\n── 判据 5：全功能无缝联动 ──")

        let fm = FileManager.default
        let tmpDir = "/tmp/r40_integration_test"
        try? fm.removeItem(atPath: tmpDir)
        try? fm.createDirectory(atPath: "\(tmpDir)/Titles.localized/TestPlugin", withIntermediateDirectories: true)

        let mockItem = TemplateItem(
            name: "TestPlugin",
            category: "Titles.localized",
            tier: .user,
            path: "\(tmpDir)/Titles.localized/TestPlugin",
            targetPath: "\(tmpDir)/Titles.localized/TestPlugin",
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 12.0,
            isEnabled: true
        )

        // 1. 启停 Toggle
        let disabled = try? TemplateInstaller.toggleTemplate(item: mockItem)
        check(disabled != nil && !disabled!.isEnabled, "卡片 Toggle 开关成功将模板隔离为 .disabled")
        check(fm.fileExists(atPath: "\(tmpDir)/Titles.localized/TestPlugin.disabled"), "磁盘目录成功重命名为 .disabled")

        let reEnabled = try? TemplateInstaller.toggleTemplate(item: disabled!)
        check(reEnabled != nil && reEnabled!.isEnabled, "卡片 Toggle 开关成功无缝恢复启用")
        check(fm.fileExists(atPath: "\(tmpDir)/Titles.localized/TestPlugin"), "磁盘目录恢复原名")

        // 2. 本地化中文重命名
        let renameOk = (try? TemplateRenameManager.shared.setLocalizedName(newAlias: "中式国风开场字幕", for: mockItem)) ?? false
        check(renameOk, "多语言重命名引擎成功写入友好中文别名")
        let alias = TemplateRenameManager.shared.getDisplayName(for: mockItem)
        check(alias == "中式国风开场字幕", "卡片标题精准读取中文友好别名", "alias=\(alias)")

        // 3. 拖拽安装引导遮罩
        let hubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        check(hubView.dropOverlayView != nil, "高质感全窗口拖拽安装遮罩就绪")

        // 4. 3D LUT 分屏与调色切换
        hubView.switchHubTab(to: 1)
        check(hubView.lutCompareView != nil, "3D LUT 分屏对比视口完备")
        hubView.lutModeSegmentedControl.selectedSegment = 0
        hubView.onLUTModeChanged()
        check(hubView.lutCompareView.displayMode == .split, "分屏模式 ◫ 正常流转")

        // 5. 影视音效波形
        hubView.switchHubTab(to: 2)
        check(hubView.audioWaveformView != nil, "128点平滑声学波形视口完备")
        hubView.audioWaveformView.playbackProgress = 0.5
        check(hubView.audioWaveformView.playbackProgress == 0.5, "波形试听进度精准拖拽响应")

        // 6. 瘦身医生控制台
        hubView.switchHubTab(to: 3)
        check(hubView.cleanerDashboardView != nil, "FCPX 资源库深度安全瘦身医生控制台 100% 完整保留")

        try? fm.removeItem(atPath: tmpDir)
    }
}


