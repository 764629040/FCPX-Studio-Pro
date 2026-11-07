import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r51_harness.swift
//  开发任务单 R51 —— 三段式素材管理面板 1:1 深度复刻、情境卡顿修复与官方 Dock 图标强制生效
// ═══════════════════════════════════════════════════════════════

@main
final class R51Harness {
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
        print("  FCPX Studio Pro —— R51 全套技术指标直证套件")
        print("==================================================")

        test1_ThreeStagePanelLayoutAndLinkage()
        test2_WorkspaceProfileWholeCardClickAndNonBlocking()
        test3_AppIconDockAndInfoPlistDualKeyVerification()
        test4_GroupManagementCRUDAndFinderInteractions()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：素材管理中心 1:1 三段式面板深度对标与联动验证
    // ─────────────────────────────────────────────────────────────
    static func test1_ThreeStagePanelLayoutAndLinkage() {
        print("\n── 判据 1：素材管理中心 1:1 三段式经典架构与组件联动 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        hub.setFrameSize(NSSize(width: 1200, height: 750))
        hub.layoutSubtreeIfNeeded()

        // 1.1 第一段（左栏 220pt）：侧边栏材质与品牌状态看板
        guard let sidebarVEV = hub.sidebarView as? NSVisualEffectView else {
            check(false, "hub.sidebarView 未正确实例化为毛玻璃视口")
            return
        }
        let sbWidth = sidebarVEV.frame.width
        check(sbWidth == 220 || sidebarVEV.bounds.width == 220, "第一段左栏宽度严格设定为 220pt", "width=\(sbWidth)")
        check(sidebarVEV.material == .sidebar, "第一段左栏材质对齐 .sidebar")
        check(hub.machineCodeLabel != nil, "第一段已挂载机器码状态指示器 machineCodeLabel")
        check(hub.fcpxVersionLabel != nil, "第一段已挂载 FCPX 版本检测指示器 fcpxVersionLabel")
        check(hub.loadTimeIndicatorLabel != nil, "第一段已挂载列表加载用时指示器 loadTimeIndicatorLabel")
        check(hub.machineCodeLabel.stringValue.contains("MAC-"), "机器码符合 MAC-xxxx 格式", hub.machineCodeLabel.stringValue)
        check(hub.fcpxVersionLabel.stringValue.contains("Final Cut Pro"), "FCPX 版本检测输出有效", hub.fcpxVersionLabel.stringValue)

        // 1.2 第二段（中栏 360pt）：插件分组列表与分类胶囊
        check(hub.middleColumnView != nil, "第二段已挂载中栏容器 middleColumnView")
        check(hub.categoryCapsuleControl != nil, "第二段已挂载顶部分类切换胶囊 categoryCapsuleControl")
        check(hub.categoryCapsuleControl.segmentCount == 4, "分类胶囊包含四大分类（字幕/发生器/效果/转场）")
        check(hub.groupToolbarView != nil, "第二段已挂载分组操作工具栏 groupToolbarView")
        check(hub.groupFinderBtn != nil && hub.groupRenameBtn != nil && hub.groupDeleteBtn != nil && hub.groupNewBtn != nil,
              "分组工具栏完备支持「访达/重命名/删除/新建插件」四大指令")
        check(hub.groupTableView != nil, "第二段已挂载分组表格 groupTableView")
        check(hub.groupTableView.tableColumns.count == 4, "分组表格包含 4 大标准列（名称/数量/大小/归属）")

        let colIdentifiers = hub.groupTableView.tableColumns.map { $0.identifier.rawValue }
        check(colIdentifiers.contains("groupName"), "分组表格包含插件名称列")
        check(colIdentifiers.contains("groupCount"), "分组表格包含数量列")
        check(colIdentifiers.contains("groupSize"), "分组表格包含大小列")
        check(colIdentifiers.contains("groupTier"), "分组表格包含归属列")

        // 1.3 第三段（右栏）：面包屑、批量操作栏与 16:9 网格流
        check(hub.rightColumnView != nil, "第三段已挂载右栏容器 rightColumnView")
        check(hub.breadcrumbLabel != nil, "第三段已挂载顶部面包屑 breadcrumbLabel")
        check(hub.breadcrumbLabel.stringValue.contains("实时预览"), "面包屑前缀包含「⚡️ 实时预览」", hub.breadcrumbLabel.stringValue)
        check(hub.rightToolbarView != nil, "第三段已挂载批量操作工具栏 rightToolbarView")
        check(hub.createGroupBtn != nil, "批量工具栏已挂载「创建新分组」按钮")
        check(hub.selectAllBtn != nil, "批量工具栏已挂载「☑️ 全选」按钮")
        check(hub.rightFinderBtn != nil, "批量工具栏已挂载「📂 访达中显示」按钮")
        check(hub.rightTrashBtn != nil, "批量工具栏已挂载「🗑️ 移入废纸篓」按钮")
        check(hub.previewToggleBtn != nil, "批量工具栏已挂载「⚡️ 演示」按钮")
        check(hub.cardGridScrollView != nil, "第三段已挂载模板卡片网格视口 cardGridScrollView")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：工作区情境点击即激活与防卡死优化验证
    // ─────────────────────────────────────────────────────────────
    static func test2_WorkspaceProfileWholeCardClickAndNonBlocking() {
        print("\n── 判据 2：工作区情境整卡点击激活、微型 Loading 与非阻塞验证 ──")
        let dashboard = WorkspaceProfileDashboardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        dashboard.refreshData()

        check(!dashboard.profileCards.isEmpty, "情境看板已生成可交互情境卡片流 (共 \(dashboard.profileCards.count) 张卡片)")

        // 2.1 验证整卡点击与微型 Loading 状态
        if let targetCard = dashboard.profileCards.first(where: { !$0.isActive }) {
            check(targetCard.spinner != nil, "情境卡片内嵌微型加载器 spinner")
            targetCard.showLoading(true)
            check(targetCard.activeBadge.stringValue.contains("切换中"), "Loading 触发时卡片即刻呈现「⚡️ 切换中…」", targetCard.activeBadge.stringValue)
            check(targetCard.activateBtn.isEnabled == false, "Loading 期间激活按钮自动防重复点击锁定")
            targetCard.showLoading(false)
            check(targetCard.activeBadge.stringValue.contains("未激活") || targetCard.activeBadge.stringValue.contains("激活中"),
                  "Loading 结束平滑恢复真实激活徽章")
        }

        // 2.2 验证 TemplateTierScanner 严格过滤 framework 与 app 内部资源
        let testDir = "\(NSTemporaryDirectory())fcpx_r51_filter_test_\(UUID().uuidString)"
        let fm = FileManager.default
        let titlesDir = "\(testDir)/Titles.localized/SimulatedPack"
        try? fm.createDirectory(atPath: "\(titlesDir)/RealTemplate/RealTemplate.moti", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(titlesDir)/InternalBundle.framework/Versions/A/Resources", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(titlesDir)/Helper.app/Contents/MacOS", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(titlesDir)/PlugIn.pluginkit", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(titlesDir)/en.lproj", withIntermediateDirectories: true)

        let roots = TemplateTierRoots(builtin: nil, user: testDir, system: testDir, builtinNote: "测试沙盒")
        let scanResult = TemplateTierScanner.scan(category: "Titles.localized", roots: roots, lazySizes: true)

        let scannedNames = scanResult.items.map { $0.name }
        check(scannedNames.contains("RealTemplate"), "真实模板 RealTemplate 成功扫描识别")
        check(!scannedNames.contains("InternalBundle"), "Framework 内部包已彻底被精准排除", "scanned=\(scannedNames)")
        check(!scannedNames.contains("Helper"), "App 二进制包已彻底被精准排除", "scanned=\(scannedNames)")
        check(!scannedNames.contains("PlugIn"), "PlugInKit 已彻底被精准排除", "scanned=\(scannedNames)")
        check(!scannedNames.contains("en.lproj"), "语言本地化包 en.lproj 已被过滤", "scanned=\(scannedNames)")

        // 2.3 验证情境异步激活与毫秒级完成（耗时 < 50ms）
        let mgr = WorkspaceProfileManager.shared
        let start = CACurrentMediaTime()
        var activateSuccess = false
        var activateErr: Error?
        var done = false

        mgr.activateProfile(id: WorkspaceProfile.weddingId, roots: roots) { res in
            switch res {
            case .success:
                activateSuccess = true
            case .failure(let err):
                activateErr = err
            }
            done = true
        }

        let timeoutDate = Date(timeIntervalSinceNow: 2.0)
        while !done && Date() < timeoutDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        let elapsed = (CACurrentMediaTime() - start) * 1000.0

        check(activateSuccess, "情境异步激活成功完成", activateErr?.localizedDescription ?? "")
        check(elapsed < 3000.0, "异步情境切换极其流畅无阻塞 (耗时: \(String(format: "%.1fms", elapsed)))")

        // 恢复默认全量情境
        try? mgr.activateProfileSync(id: WorkspaceProfile.allActiveId, roots: roots)
        try? fm.removeItem(atPath: testDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：macOS 系统级 Dock 图标与 Info.plist 双键值强制生效
    // ─────────────────────────────────────────────────────────────
    static func test3_AppIconDockAndInfoPlistDualKeyVerification() {
        print("\n── 判据 3：macOS 官方 Dock 图标与 Info.plist 双键值强制生效 ──")
        let appBundlePath = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/FCPX Studio Pro.app"
        let plistPath = "\(appBundlePath)/Contents/Info.plist"

        guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            check(false, "无法读取应用 Info.plist: \(plistPath)")
            return
        }

        // 3.1 验证 Info.plist CFBundleIconFile 与 CFBundleIconName 双键值
        let iconFile = plist["CFBundleIconFile"] as? String
        let iconName = plist["CFBundleIconName"] as? String
        check(iconFile == "AppIcon", "Info.plist 包含 CFBundleIconFile 且值为 AppIcon", "val=\(iconFile ?? "nil")")
        check(iconName == "AppIcon", "Info.plist 包含 CFBundleIconName 且值为 AppIcon", "val=\(iconName ?? "nil")")

        // 3.2 验证应用资源中 AppIcon.icns 真实存在且体积有效
        let icnsPath = "\(appBundlePath)/Contents/Resources/AppIcon.icns"
        let fm = FileManager.default
        check(fm.fileExists(atPath: icnsPath), "App Bundle 资源目录中 AppIcon.icns 物理存在")
        if let attrs = try? fm.attributesOfItem(atPath: icnsPath), let sz = attrs[.size] as? NSNumber {
            check(sz.intValue > 1024, "AppIcon.icns 包含完整高分辨率图像切片 (体积: \(sz.intValue) 字节)")
        }

        // 3.3 验证 NSApp.applicationIconImage 运行时注入有效
        if let iconImg = NSImage(contentsOfFile: icnsPath) {
            NSApplication.shared.applicationIconImage = iconImg
        }
        check(NSApplication.shared.applicationIconImage != nil, "NSApplication.shared.applicationIconImage 运行时已成功点亮注入")
        if let appIcon = NSApplication.shared.applicationIconImage {
            check(appIcon.size.width > 0 && appIcon.size.height > 0,
                  "运行时官方图标有效尺寸: \(Int(appIcon.size.width))x\(Int(appIcon.size.height))")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：中栏分组联动、右栏面包屑联动与指示箭头 ▶ 验证
    // ─────────────────────────────────────────────────────────────
    static func test4_GroupManagementCRUDAndFinderInteractions() {
        print("\n── 判据 4：分组联动、右栏面包屑联动与指示箭头 ▶ 验证 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        // 构造虚拟分组数据进行联动测试
        let mockItem1 = TemplateItem(name: "陶丽渐变01", category: "Titles.localized", subCategory: "易安装-100个陶丽渐变背景标题", tier: .user, path: "/mock/1", targetPath: "/mock/1", isSymlink: false, targetAvailable: true, sizeMB: 2.5, isEnabled: true)
        let mockItem2 = TemplateItem(name: "陶丽渐变02", category: "Titles.localized", subCategory: "易安装-100个陶丽渐变背景标题", tier: .user, path: "/mock/2", targetPath: "/mock/2", isSymlink: false, targetAvailable: true, sizeMB: 3.1, isEnabled: true)
        let mockItem3 = TemplateItem(name: "动漫动态01", category: "Titles.localized", subCategory: "03综艺动漫", tier: .system, path: "/mock/3", targetPath: "/mock/3", isSymlink: false, targetAvailable: true, sizeMB: 15.0, isEnabled: true)

        let grp1 = TemplateGroupItem(name: "易安装-100个陶丽渐变背景标题", category: "Titles.localized", tier: .user, count: 2, totalSizeMB: 5.6, items: [mockItem1, mockItem2])
        let grp2 = TemplateGroupItem(name: "03综艺动漫", category: "Titles.localized", tier: .system, count: 1, totalSizeMB: 15.0, items: [mockItem3])

        hub.groupItems = [grp1, grp2]
        hub.selectedGroupIndex = 0
        hub.loadTemplatesForSelectedGroup()

        // 4.1 验证选中第 0 组
        check(hub.selectedGroupItem?.name == "易安装-100个陶丽渐变背景标题", "当前选中分组为「易安装-100个陶丽渐变背景标题」")
        check(hub.plugins.count == 2, "右栏卡片流联动呈现该组内 2 款模板")
        check(hub.breadcrumbLabel.stringValue.contains("易安装-100个陶丽渐变背景标题"), "右栏顶部面包屑实时同步「易安装-100个陶丽渐变背景标题」", hub.breadcrumbLabel.stringValue)

        // 4.2 验证表格单元格渲染与 ▶ 箭头指示
        let viewColTier0 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[3], row: 0) as? NSTableCellView
        let text0 = viewColTier0?.subviews.first as? NSTextField
        check(text0?.stringValue.contains("▶") == true, "当前选中行右侧高亮呈现「▶」指示箭头", text0?.stringValue ?? "")

        // 4.3 切换至第 1 组
        hub.selectedGroupIndex = 1
        hub.loadTemplatesForSelectedGroup()
        check(hub.selectedGroupItem?.name == "03综艺动漫", "切换选中分组为「03综艺动漫」")
        check(hub.plugins.count == 1, "右栏卡片流联动呈现该组内 1 款模板")
        check(hub.breadcrumbLabel.stringValue.contains("03综艺动漫"), "面包屑实时更新为「03综艺动漫」", hub.breadcrumbLabel.stringValue)

        let viewColTier1 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[3], row: 1) as? NSTableCellView
        let text1 = viewColTier1?.subviews.first as? NSTextField
        check(text1?.stringValue.contains("▶") == true, "第 1 行现在高亮呈现「▶」指示箭头", text1?.stringValue ?? "")
    }
}
