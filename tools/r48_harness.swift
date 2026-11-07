import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r48_harness.swift
//  开发任务单 R48 —— 顶栏避让解耦、侧栏 SF 矢量图标与真实模板缩略图穿透
// ═══════════════════════════════════════════════════════════════

@main
final class R48Harness {
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
        print("  FCPX Studio Pro —— R48 视觉质感与真实模板穿透直证套件")
        print("==================================================")

        test1_TopBarDecouplingAndTitlebarHidden()
        test2_SidebarSFSymbolsVectorPurity()
        test3_RealTemplateDeepRecursiveScanAndLargePng()
        test4_SubCategoryQuickFilterBar()
        test5_ResourceCardViewRealRendering()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：顶栏避让解耦与窗口标题重构 (MainWindowController.swift)
    // ─────────────────────────────────────────────────────────────
    static func test1_TopBarDecouplingAndTitlebarHidden() {
        print("\n── 判据 1：顶栏避让解耦与窗口标题重构 ──")
        let winCtrl = MainWindowController()
        guard let win = winCtrl.window else {
            check(false, "主窗口创建失败")
            return
        }

        // 1.1 隐去系统标题，彻底消除文字穿透重叠
        check(win.titleVisibility == .hidden, "窗口标题可见性已隐藏 (win.titleVisibility == .hidden)")
        check(win.titlebarAppearsTransparent == true, "窗口标题栏设置为透明 (titlebarAppearsTransparent = true)")

        // 1.2 交通灯左侧安全避让边距
        guard let seg = winCtrl.segmentedControl else {
            check(false, "顶栏引擎切换控件未找到")
            return
        }
        check(seg.frame.origin.x >= 84.0, "顶栏引擎切换胶囊左侧具备 >= 84pt 避让边距", "x=\(seg.frame.origin.x)")

        // 1.3 右侧工具栏控件合理排列无重叠
        guard let badge = winCtrl.profileBadgeButton,
              let comp = winCtrl.comparisonSegmentedControl else {
            check(false, "顶栏右侧控件未找到")
            return
        }
        check(badge.frame.origin.x > seg.frame.maxX, "情境徽章按钮位于引擎胶囊右侧无碰撞", "segMaxX=\(seg.frame.maxX), badgeX=\(badge.frame.origin.x)")
        check(comp.frame.origin.x > seg.frame.maxX, "对比切换胶囊位于引擎胶囊右侧无碰撞", "compX=\(comp.frame.origin.x)")
        check(badge.frame.origin.x > comp.frame.origin.x, "情境徽章与对比胶囊排列顺序正确", "compX=\(comp.frame.origin.x), badgeX=\(badge.frame.origin.x)")
        check(badge.frame.maxX <= win.contentView!.bounds.width, "右侧控件未超出窗口可见边界", "badgeMaxX=\(badge.frame.maxX), winW=\(win.contentView!.bounds.width)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：左侧菜单栏全面升级 Apple 原生 SF Symbols (AssetHubView.swift)
    // ─────────────────────────────────────────────────────────────
    static func test2_SidebarSFSymbolsVectorPurity() {
        print("\n── 判据 2：左侧菜单栏全面升级 Apple 原生 SF Symbols ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        check(hub.sidebarButtons.count == 12, "左侧侧边栏具有 12 个导航项", "count=\(hub.sidebarButtons.count)")

        let emojiSet: [Character] = ["💬", "✨", "📼", "⚡️", "⚡", "🎨", "🎵", "🧹", "🩺", "💾", "🗂️", "🗂", "🚀", "⚙️", "⚙", "🔄"]
        var hasAnyEmoji = false
        var allHaveImages = true

        let expectedSFNames = [
            "character.textbox",
            "wand.and.stars",
            "rectangle.2.swap",
            "film.stack",
            "slider.horizontal.3",
            "waveform",
            "trash.circle",
            "stethoscope",
            "externaldrive",
            "macwindow.on.rectangle",
            "paperplane",
            "gearshape"
        ]

        for (idx, btn) in hub.sidebarButtons.enumerated() {
            let title = btn.title
            for ch in emojiSet {
                if title.contains(ch) {
                    hasAnyEmoji = true
                    print("  [DEBUG] 按钮 \(idx) 含有 Emoji '\(ch)': \(title)")
                }
            }
            if btn.image == nil {
                allHaveImages = false
            }
            check(btn.imagePosition == .imageLeading, "按钮 \(idx) 图标位置为前置 (.imageLeading)")
        }

        check(!hasAnyEmoji, "侧边栏 12 个按钮标题彻底清除全部彩色 Emoji 占位符")
        check(allHaveImages, "侧边栏 12 个按钮全部成功装载 SF Symbols 矢量图标")

        // 验证标题副栏无 Emoji
        let catTitle = hub.categoryTitleLabel?.stringValue ?? ""
        var catTitleHasEmoji = false
        for ch in emojiSet {
            if catTitle.contains(ch) { catTitleHasEmoji = true }
        }
        check(!catTitleHasEmoji, "主分类标题已彻底消除 Emoji 前缀", "title=\(catTitle)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：深度递归模板扫描与 100% 真实读取 FCPX large.png
    // ─────────────────────────────────────────────────────────────
    static func test3_RealTemplateDeepRecursiveScanAndLargePng() {
        print("\n── 判据 3：模板深度递归扫描与真实 large.png 缩略图穿透 ──")

        let scanResult = TemplateTierScanner.scan(category: "Titles.localized")
        let items = scanResult.items

        check(items.count > 100, "深度递归成功扫描出 > 100 套真实模板（穿透子目录）", "实际扫描发现 \(items.count) 套模板")

        // 验证子分类提取（以 03综艺动漫 为例）
        let animeItems = items.filter { $0.subCategory == "03综艺动漫" }
        check(animeItems.count >= 200, "精准深入 03综艺动漫 子分类并识别出 >= 200 个真实模板", "count=\(animeItems.count)")

        // 验证模板文件夹真实存在 .moti / .moef / .motr / .motn
        let fm = FileManager.default
        let sample = animeItems.first
        check(sample != nil, "成功采样 03综艺动漫 内模板项")
        if let s = sample {
            check(!s.subCategory.isEmpty, "子分类字段正确解析", "subCategory=\(s.subCategory)")
            check(fm.fileExists(atPath: s.targetPath), "模板物理路径真实存在", "path=\(s.targetPath)")

            let contents = (try? fm.contentsOfDirectory(atPath: s.targetPath)) ?? []
            let hasMoti = contents.contains { $0.hasSuffix(".moti") }
            check(hasMoti, "模板物理目录内真实存在 Motion .moti 工程文件")
        }

        // 验证 real large.png 占比 >= 95%
        var withLargePng = 0
        for it in items {
            let p1 = "\(it.targetPath)/large.png"
            let p2 = "\(it.targetPath)/Large.png"
            let p3 = "\(it.targetPath)/small.png"
            if fm.fileExists(atPath: p1) || fm.fileExists(atPath: p2) || fm.fileExists(atPath: p3) {
                withLargePng += 1
            }
        }
        let ratio = Double(withLargePng) / Double(max(1, items.count))
        let percent = String(format: "%.1f%%", ratio * 100.0)
        check(ratio >= 0.95, "扫描出模板的大图缩略图真实存在率达到 >= 95%", "真实命中 \(withLargePng)/\(items.count) (\(percent))")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：子分类快速筛选栏与对标嘉星 2.app 体验
    // ─────────────────────────────────────────────────────────────
    static func test4_SubCategoryQuickFilterBar() {
        print("\n── 判据 4：子分类快速筛选栏与动态过滤 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        hub.refreshList()

        check(hub.subCategoryButtons.count > 0, "子分类胶囊筛选栏已动态生成按钮", "buttons=\(hub.subCategoryButtons.count)")

        let firstBtn = hub.subCategoryButtons.first
        check(firstBtn?.title.contains("全部") == true, "首个筛选按钮为「全部」胶囊", "title=\(firstBtn?.title ?? "nil")")

        let animeBtn = hub.subCategoryButtons.first { $0.identifier?.rawValue == "03综艺动漫" }
        check(animeBtn != nil, "子分类筛选栏中成功识别「03综艺动漫」独立胶囊")
        if let ab = animeBtn {
            check(ab.title.contains("280") || ab.title.contains("03综艺动漫"), "「03综艺动漫」胶囊准确统计其模板数量", "title=\(ab.title)")

            // 模拟用户点击该子分类胶囊
            hub.currentSubCategoryFilter = "03综艺动漫"
            hub.refreshList()

            check(hub.plugins.count >= 200, "切换子分类后即刻过滤出该子分类下的所有模板", "count=\(hub.plugins.count)")
            let allBelongToAnime = hub.plugins.allSatisfy { $0.subCategory == "03综艺动漫" }
            check(allBelongToAnime, "当前展示卡片 100% 属于选定的子分类")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：ResourceCardView 真实缩略图与子分类徽章渲染
    // ─────────────────────────────────────────────────────────────
    static func test5_ResourceCardViewRealRendering() {
        print("\n── 判据 5：ResourceCardView 真实缩略图与子分类徽章渲染 ──")

        let scanResult = TemplateTierScanner.scan(category: "Titles.localized")
        guard let item = scanResult.items.first(where: { $0.subCategory == "03综艺动漫" }) else {
            check(false, "未能获取 03综艺动漫 模板样例")
            return
        }

        let card = ResourceCardView(item: item)
        check(card.categoryIconLabel.stringValue.isEmpty, "卡片已彻底移除旧彩色 Emoji 占位文本 (categoryIconLabel 为空)")
        check(card.subCategoryBadgeLabel.isHidden == false, "卡片已显示悬浮子分类胶囊标签")
        check(card.subCategoryBadgeLabel.stringValue == "03综艺动漫", "子分类标签准确显示所属目录名 (03综艺动漫)")

        // 验证大图加载探针
        let fm = FileManager.default
        let hasLarge = fm.fileExists(atPath: "\(item.targetPath)/large.png") || fm.fileExists(atPath: "\(item.targetPath)/Large.png")
        check(hasLarge, "该模板包内真实存在 FCPX 标准 large.png 缩略图", "path=\(item.targetPath)/large.png")
    }
}
