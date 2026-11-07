// ═══════════════════════════════════════════════════════════════
//  R39 引擎二对标嘉星：资源库深度安全瘦身与本地化重命名自动化直证 Harness
//  对标基准：/Applications/嘉星插件管理 2.app (com.FxXu.0412)
// ═══════════════════════════════════════════════════════════════

import AppKit
import Foundation

@main
struct R39CleanerRenameHarness {
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
        print("  FCPX Studio Pro —— R39 资源库瘦身与重命名 Harness 开始")
        print("==================================================")

        let rootDir = FileManager.default.currentDirectoryPath
        let evidenceDir = "\(rootDir)/docs/r39_evidence"
        try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        test1_RealLibraryScanAndDetection()
        test2_CacheClassificationAndOriginalMediaProtection()
        test3_SafeTrashingAndNoHardDelete()
        test4_TemplateFriendlyChineseRenameAndStringsMutation()
        test5_AssetHubViewFourSuperHubNavigation()
        test6_CleanerDashboardUIAndDragDrop()

        print("==================================================")
        print("  总计检查点: \(checks) | 失败: \(failures)")
        print("==================================================")
        exit(failures == 0 ? 0 : 1)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：真实 .fcpbundle 扫描与识别
    // ─────────────────────────────────────────────────────────────
    static func test1_RealLibraryScanAndDetection() {
        print("\n── 判据 1：真实 .fcpbundle 扫描与识别 ──")

        let cleaner = LibraryCleaner.shared
        let libraries = cleaner.scanLibraries()

        check(!libraries.isEmpty, "成功探测到本机真实 FCPX 资源库", "count=\(libraries.count)")

        if let first = libraries.first {
            check(first.name.hasSuffix(".fcpbundle"), "资源库扩展名合法 (.fcpbundle)", "name=\(first.name)")
            check(first.totalSizeBytes > 0, "资源库体积统计有效", "size=\(first.totalSizeFormatted)")
            check(first.eventsCount >= 1, "资源库包含有效事件计数", "events=\(first.eventsCount)")
            check(cleaner.isFCPXBundle(at: first.url), "isFCPXBundle 准确识别资源库包属性")
        }

        // 验证特定真实项目探测（如公租房、街拍、婚礼等）
        let knownKeywords = ["公租房", "街拍", "婚礼", "测试", "未命名"]
        let matched = libraries.filter { lib in
            knownKeywords.contains { lib.path.contains($0) || lib.name.contains($0) }
        }
        check(!matched.isEmpty, "成功命中用户真实工程关键词", "matchedCount=\(matched.count)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：缓存分类与体积统计（原始媒体 0 污染）
    // ─────────────────────────────────────────────────────────────
    static func test2_CacheClassificationAndOriginalMediaProtection() {
        print("\n── 判据 2：缓存分类与体积统计（原始媒体 0 污染） ──")

        let fm = FileManager.default
        let tempDir = NSTemporaryDirectory() + "r39_test_bundle_" + UUID().uuidString + ".fcpbundle"
        defer { try? fm.removeItem(atPath: tempDir) }

        // 构建符合 FCPX 规范的测试资源库结构
        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let flexoPath = tempDir + "/CurrentVersion.flexolibrary"
        fm.createFile(atPath: flexoPath, contents: Data(repeating: 0x41, count: 1024), attributes: nil)

        let eventPath = tempDir + "/2026-11-06-Event"
        try? fm.createDirectory(atPath: eventPath, withIntermediateDirectories: true)
        let fcpeventPath = eventPath + "/CurrentVersion.fcpevent"
        fm.createFile(atPath: fcpeventPath, contents: Data(repeating: 0x42, count: 2048), attributes: nil)

        // 1. 原始媒体（Original Media）: 50KB（绝对红线）
        let origDir = eventPath + "/Original Media"
        try? fm.createDirectory(atPath: origDir, withIntermediateDirectories: true)
        let origClip = origDir + "/A001_C001.mov"
        fm.createFile(atPath: origClip, contents: Data(repeating: 0x55, count: 50 * 1024), attributes: nil)

        // 2. 渲染缓存（Render Files）: 40KB HQ + 10KB Peaks
        let renderHQ = eventPath + "/Render Files/High Quality Media"
        let renderPeaks = eventPath + "/Render Files/Peaks Data"
        let renderThumbs = eventPath + "/Render Files/Thumbnail Media"
        try? fm.createDirectory(atPath: renderHQ, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: renderPeaks, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: renderThumbs, withIntermediateDirectories: true)
        fm.createFile(atPath: renderHQ + "/frame001.data", contents: Data(repeating: 0x66, count: 40 * 1024), attributes: nil)
        fm.createFile(atPath: renderPeaks + "/audio.peak", contents: Data(repeating: 0x77, count: 10 * 1024), attributes: nil)
        fm.createFile(atPath: renderThumbs + "/thumb.data", contents: Data(repeating: 0x88, count: 15 * 1024), attributes: nil)

        // 3. 代理媒体（Proxy Media）: 30KB
        let proxyDir = eventPath + "/Transcoded Media/Proxy Media"
        try? fm.createDirectory(atPath: proxyDir, withIntermediateDirectories: true)
        fm.createFile(atPath: proxyDir + "/proxy001.mov", contents: Data(repeating: 0x99, count: 30 * 1024), attributes: nil)

        // 4. 分析缓存（Analysis Files）: 12KB
        let analysisDir = eventPath + "/Analysis Files/Stabilization"
        try? fm.createDirectory(atPath: analysisDir, withIntermediateDirectories: true)
        fm.createFile(atPath: analysisDir + "/stab.data", contents: Data(repeating: 0xAA, count: 12 * 1024), attributes: nil)

        // 5. 共享导出残留（Shared Items）: 20KB
        let sharedDir = eventPath + "/Shared Items"
        try? fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        fm.createFile(atPath: sharedDir + "/export_temp.mov", contents: Data(repeating: 0xBB, count: 20 * 1024), attributes: nil)

        // 执行分析
        let bundleURL = URL(fileURLWithPath: tempDir)
        guard let item = LibraryCleaner.shared.analyzeBundle(at: bundleURL) else {
            check(false, "analyzeBundle 分析测试资源库失败")
            return
        }

        check(item.originalMediaSizeBytes == 50 * 1024, "原始媒体体积计算 100% 精确", "size=\(item.originalMediaSizeBytes) bytes")
        check(item.eventsCount == 1, "事件计数正确 (1)")

        // 校验各分类缓存
        let renderCat = item.cacheDetails.first { $0.category == .renderFiles }
        check(renderCat != nil && renderCat!.byteSize == 50 * 1024, "高画质渲染与波形缓存统计精准", "render=\(renderCat?.byteSize ?? 0)")

        let proxyCat = item.cacheDetails.first { $0.category == .proxyMedia }
        check(proxyCat != nil && proxyCat!.byteSize == 30 * 1024, "代理媒体缓存统计精准", "proxy=\(proxyCat?.byteSize ?? 0)")

        let thumbCat = item.cacheDetails.first { $0.category == .thumbnailMedia }
        check(thumbCat != nil && thumbCat!.byteSize == 15 * 1024, "缩略图缓存统计精准", "thumb=\(thumbCat?.byteSize ?? 0)")

        let analysisCat = item.cacheDetails.first { $0.category == .analysisFiles }
        check(analysisCat != nil && analysisCat!.byteSize == 12 * 1024, "防抖与光流分析缓存统计精准", "analysis=\(analysisCat?.byteSize ?? 0)")

        let sharedCat = item.cacheDetails.first { $0.category == .sharedItems }
        check(sharedCat != nil && sharedCat!.byteSize == 20 * 1024, "历史分享渲染残留统计精准", "shared=\(sharedCat?.byteSize ?? 0)")

        // 安全红线校验：清理候选路径绝不可包含 Original Media
        var safetyBreach = false
        for cat in item.cacheDetails {
            for p in cat.paths {
                if p.contains("Original Media") || p.hasSuffix(".fcpevent") || p.hasSuffix(".flexolibrary") {
                    safetyBreach = true
                }
            }
        }
        check(!safetyBreach, "最高安全红线达成：清理路径 0 污染，原始媒体完全隔离")
        check(item.cleanableSizeBytes == (50 + 30 + 15 + 12 + 20) * 1024, "可瘦身总容量累计精准", "cleanable=\(item.cleanableSizeFormatted)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：安全移入废纸篓瘦身（绝无 rm -rf）
    // ─────────────────────────────────────────────────────────────
    static func test3_SafeTrashingAndNoHardDelete() {
        print("\n── 判据 3：安全移入废纸篓瘦身（绝无 rm -rf） ──")

        let fm = FileManager.default
        let tempDir = NSTemporaryDirectory() + "r39_trash_test_" + UUID().uuidString + ".fcpbundle"
        defer { try? fm.removeItem(atPath: tempDir) }

        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let flexoPath = tempDir + "/CurrentVersion.flexolibrary"
        fm.createFile(atPath: flexoPath, contents: Data("flexo".utf8), attributes: nil)

        let eventPath = tempDir + "/Event1"
        try? fm.createDirectory(atPath: eventPath, withIntermediateDirectories: true)
        let fcpeventPath = eventPath + "/CurrentVersion.fcpevent"
        fm.createFile(atPath: fcpeventPath, contents: Data("fcpevent".utf8), attributes: nil)

        // 原始素材
        let origDir = eventPath + "/Original Media"
        try? fm.createDirectory(atPath: origDir, withIntermediateDirectories: true)
        let origClip = origDir + "/MasterFootage.mov"
        fm.createFile(atPath: origClip, contents: Data(repeating: 0x11, count: 32768), attributes: nil)

        // 可清理渲染缓存
        let renderHQ = eventPath + "/Render Files/High Quality Media"
        try? fm.createDirectory(atPath: renderHQ, withIntermediateDirectories: true)
        let cacheFile = renderHQ + "/render_block_01.data"
        fm.createFile(atPath: cacheFile, contents: Data(repeating: 0x22, count: 65536), attributes: nil)

        let bundleURL = URL(fileURLWithPath: tempDir)
        guard let item = LibraryCleaner.shared.analyzeBundle(at: bundleURL) else {
            check(false, "analyzeBundle 失败")
            return
        }

        // 执行安全瘦身
        let result = LibraryCleaner.shared.safeClean(item: item, categoriesToClean: [.renderFiles])

        check(result.isSuccess, "safeClean 执行成功且无拦截报错")
        check(result.bytesFreed == 65536, "释放空间与清理体积精确吻合 (64KB)", "freed=\(result.bytesFreed)")
        check(result.itemsTrashedCount > 0, "成功通过 FileManager.trashItem 移入废纸篓", "trashedCount=\(result.itemsTrashedCount)")

        // 废纸篓物理存在校验
        if let trashedURL = result.trashedURLs.first {
            check(fm.fileExists(atPath: trashedURL.path), "已清理缓存确实落入 macOS 废纸篓，用户可随时找回", "trashPath=\(trashedURL.path)")
            // 测试完成后清理废纸篓中的临时测试文件
            try? fm.removeItem(at: trashedURL)
        }

        // 验证原始素材安全
        check(fm.fileExists(atPath: origClip), "原始拍摄素材 MasterFootage.mov 安然无恙，未受丝毫触碰！")
        check(fm.fileExists(atPath: flexoPath), "资源库核心数据库 CurrentVersion.flexolibrary 完好无损！")
        check(fm.fileExists(atPath: fcpeventPath), "事件核心数据库 CurrentVersion.fcpevent 完好无损！")

        // 验证清理后资源库可瘦身体积变为 0
        if let updated = LibraryCleaner.shared.analyzeBundle(at: bundleURL) {
            check(updated.cleanableSizeBytes == 0, "瘦身后缓存体积降至 0")
            check(updated.originalMediaSizeBytes == 32768, "原始素材体积保持 32KB 不变")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：模板友好中文重命名（.strings 规范映射，杜绝红屏断链）
    // ─────────────────────────────────────────────────────────────
    static func test4_TemplateFriendlyChineseRenameAndStringsMutation() {
        print("\n── 判据 4：模板友好中文重命名（.strings 字典映射） ──")

        let fm = FileManager.default
        let tempTemplateDir = NSTemporaryDirectory() + "r39_template_" + UUID().uuidString + "/Titles.localized/Wedding/Modern_Title_01"
        defer { try? fm.removeItem(atPath: tempTemplateDir) }

        try? fm.createDirectory(atPath: tempTemplateDir, withIntermediateDirectories: true)
        let motiPath = tempTemplateDir + "/Modern_Title_01.moti"
        fm.createFile(atPath: motiPath, contents: Data("MotionXMLID_12345".utf8), attributes: nil)

        let item = TemplateItem(
            name: "Modern_Title_01",
            category: "Titles.localized",
            tier: .user,
            path: tempTemplateDir,
            targetPath: tempTemplateDir,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 1.2
        )

        let renameManager = TemplateRenameManager.shared

        // 初始状态下无别名，返回原名
        let initialName = renameManager.getDisplayName(for: item)
        check(initialName == "Modern_Title_01", "初始未设别名时显示原始文件名", "name=\(initialName)")

        // 写入中文友好别名
        let targetChineseName = "中式婚礼优雅字幕"
        do {
            let ok = try renameManager.setLocalizedName(newAlias: targetChineseName, for: item)
            check(ok, "成功写入本地化字典映射")
        } catch {
            check(false, "setLocalizedName 抛出异常: \(error)")
        }

        // 验证 .localized 目录与 zh_CN.strings / zh-Hans.strings 生成
        let zhCNPath = tempTemplateDir + "/.localized/zh_CN.strings"
        let zhHansPath = tempTemplateDir + "/.localized/zh-Hans.strings"
        check(fm.fileExists(atPath: zhCNPath), ".localized/zh_CN.strings 成功规范生成")
        check(fm.fileExists(atPath: zhHansPath), ".localized/zh-Hans.strings 成功规范生成")

        // 验证文件内容语法
        if let strContent = try? String(contentsOfFile: zhCNPath, encoding: .utf8) {
            check(strContent.contains("\"Modern_Title_01\" = \"中式婚礼优雅字幕\";"), ".strings 语法符合标准 Apple 字典规范")
        }

        // 验证读取引擎
        let displayName = renameManager.getDisplayName(for: item)
        check(displayName == targetChineseName, "getDisplayName 准确读取友好中文名", "displayName=\(displayName)")

        // 验证断链防护：Motion 物理文件绝对未变名
        check(fm.fileExists(atPath: motiPath), "底层 Modern_Title_01.moti 物理文件毫发无损，100% 杜绝红屏断链！")

        // 验证字典变更增量支持（追加第二条别名，保留前一条）
        _ = try? renameManager.setLocalizedName(newAlias: "极简毛笔标题", templatePath: tempTemplateDir, templateName: "Brush_Title_02")
        let dict = renameManager.parseStringsFile(at: URL(fileURLWithPath: zhCNPath))
        check(dict?["Modern_Title_01"] == "中式婚礼优雅字幕", "增量更新保留原有键值对")
        check(dict?["Brush_Title_02"] == "极简毛笔标题", "增量更新成功追加新键值对")

        // 验证别名移除恢复
        _ = try? renameManager.removeLocalizedName(templatePath: tempTemplateDir, templateName: "Modern_Title_01")
        let restoredName = renameManager.getDisplayName(for: item)
        check(restoredName == "Modern_Title_01", "清除别名后无缝恢复原始名称", "restored=\(restoredName)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：四大超级业务中心无缝流转
    // ─────────────────────────────────────────────────────────────
    static func test5_AssetHubViewFourSuperHubNavigation() {
        print("\n── 判据 5：四大超级业务中心无缝流转 ──")

        let hubView = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))

        check(hubView.hubSegmentedControl != nil, "hubSegmentedControl 存在")
        check(hubView.hubSegmentedControl.segmentCount == 4, "升级为四大业务中心 (4 segments)", "count=\(hubView.hubSegmentedControl.segmentCount)")

        check(hubView.hubSegmentedControl.label(forSegment: 0) == "🎨 模板插件管理", "Tab 0: 模板插件管理")
        check(hubView.hubSegmentedControl.label(forSegment: 1) == "🎞️ 3D LUT 调色与分屏", "Tab 1: 3D LUT 调色与分屏")
        check(hubView.hubSegmentedControl.label(forSegment: 2) == "🎵 影视级音效库", "Tab 2: 影视级音效库")
        check(hubView.hubSegmentedControl.label(forSegment: 3) == "🧹 工程瘦身清理", "Tab 3: 工程瘦身清理")

        // 测试 Tab 切换与容器隐藏逻辑
        hubView.switchHubTab(to: 3)
        check(hubView.currentHubTab == 3, "当前 Tab 切换至 3 (工程瘦身)")
        check(!hubView.cleanerContainerView.isHidden, "瘦身模块容器呈显示状态")
        check(hubView.templateContainerView.isHidden, "模板容器已隐藏")
        check(hubView.lutContainerView.isHidden, "LUT 容器已隐藏")
        check(hubView.audioContainerView.isHidden, "音效容器已隐藏")

        hubView.switchHubTab(to: 0)
        check(!hubView.templateContainerView.isHidden, "切回 Tab 0 模板插件呈显示状态")
        check(hubView.cleanerContainerView.isHidden, "瘦身模块已隐藏")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：CleanerDashboard 控制台与拖拽装载验证
    // ─────────────────────────────────────────────────────────────
    static func test6_CleanerDashboardUIAndDragDrop() {
        print("\n── 判据 6：CleanerDashboard 控制台交互与装载 ──")

        let dashboard = CleanerDashboardView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        check(dashboard.scanButton != nil, "扫描按钮初始化就绪")
        check(dashboard.cleanAllButton != nil, "一键安全瘦身按钮就绪")
        check(dashboard.cleanSelectedButton != nil, "清理所选按钮就绪")
        check(dashboard.storageBarView != nil, "容量可视化比例条就绪")

        // 模拟装载真实探测到的首个资源库
        let libraries = LibraryCleaner.shared.scanLibraries()
        if let first = libraries.first {
            dashboard.addLibrary(at: first.url)
            check(!dashboard.libraries.isEmpty, "成功向控制台装载资源库", "loaded=\(dashboard.libraries.count)")
            check(dashboard.selectedLibrary != nil, "自动选定首个资源库")
            check(!dashboard.detailTitleLabel.stringValue.isEmpty, "详情面板标题已更新", "title=\(dashboard.detailTitleLabel.stringValue)")
            check(!dashboard.detailOriginalMediaLabel.stringValue.isEmpty, "详情面板原始素材安全提示已更新")
        } else {
            check(true, "环境无资源库跳过首项装载")
        }
    }
}
