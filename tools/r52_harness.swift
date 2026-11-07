import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r52_harness.swift
//  开发任务单 R52 —— 机器唯一码与商用授权分级体系、中栏整行高亮、无滚动条自适应卡片流与全局磨砂质感跃迁
// ═══════════════════════════════════════════════════════════════

@main
final class R52Harness {
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
        print("  FCPX Studio Pro —— R52 全套技术指标直证套件")
        print("==================================================")

        test1_MachineCodeAndHardwareBinding()
        test2_LicenseSignatureValidationAndPersistence()
        test3_FeatureGatingAndInterceptions()
        test4_MiddleColumnGroupTableRowViewAndFullHighlight()
        test5_AdaptiveFluidGridAndZeroTruncation()
        test6_InvisibleScrollerAndSmoothScrolling()
        test7_PillFooterAndFrostedGlassTexture()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：机器唯一硬件特征码生成与确定性匹配
    // ─────────────────────────────────────────────────────────────
    static func test1_MachineCodeAndHardwareBinding() {
        print("\n── 判据 1：Mac 硬件唯一特征码生成与确定性匹配 ──")
        let code1 = LicenseManager.generateMachineCode()
        let code2 = LicenseManager.generateMachineCode()
        check(!code1.isEmpty, "机器特征码成功生成且非空", code1)
        check(code1 == code2, "连续两次调用硬件特征码具有 100% 确定性幂等输出", "code=\(code1)")
        check(code1.hasPrefix("MAC-"), "机器码以前缀「MAC-」规范开头")

        let parts = code1.split(separator: "-")
        check(parts.count == 4, "机器码由 4 段构成 (MAC-XXXX-XXXX-XXXX)", "parts=\(parts.count)")
        if parts.count == 4 {
            check(parts[1].count == 4 && parts[2].count == 4 && parts[3].count == 4,
                  "每段十六进制均为 4 字符", "\(parts[1])-\(parts[2])-\(parts[3])")
        }

        let mgr = LicenseManager.shared
        check(mgr.machineCode == code1, "LicenseManager 实例持有并同步当前机器码", mgr.machineCode)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：商用授权防伪签名校验、激活持久化与注销验证
    // ─────────────────────────────────────────────────────────────
    static func test2_LicenseSignatureValidationAndPersistence() {
        print("\n── 判据 2：商用许可证防伪签名校验与生命周期管理 ──")
        let mgr = LicenseManager.shared
        let machine = mgr.machineCode

        // 2.1 确保初始可控状态：先注销
        mgr.deactivate()
        check(!mgr.isProLicensed, "初始注销状态下 isProLicensed 为 false")

        // 2.2 验证签名生成与匹配
        let validKey = LicenseManager.computeLicenseKey(forMachine: machine)
        check(validKey.hasPrefix("FCPX-LIC-"), "许可证代码包含 FCPX-LIC- 规范前缀", validKey)
        check(mgr.verifyLicense(key: validKey, forMachine: machine), "合法许可证代码通过签名校验")

        // 2.3 验证非法授权码被坚决拒绝
        let fakeKey = "FCPX-LIC-9999-8888-7777"
        check(!mgr.verifyLicense(key: fakeKey, forMachine: machine), "篡改授权码被签名校验拒绝")
        check(!mgr.verifyLicense(key: "INVALID-CODE", forMachine: machine), "随机非法字符串被签名校验拒绝")

        // 2.4 验证激活与持久化
        let res = mgr.activate(key: validKey)
        check(res.success, "执行激活操作返回 success=true", res.message)
        check(mgr.isProLicensed, "激活后 isProLicensed 切换为 true")
        check(mgr.activeLicenseKey == validKey, "activeLicenseKey 准确持久化当前授权代码")

        // 2.5 验证开发者免密激活用于测试
        mgr.deactivate()
        check(!mgr.isProLicensed, "再次注销成功")
        mgr.setDeveloperProOverride(true)
        check(mgr.isProLicensed, "开发者免密测试覆盖 (setDeveloperProOverride) 激活成功")
        mgr.setDeveloperProOverride(false)
        check(!mgr.isProLicensed, "开发者免密覆盖关闭恢复未授权体验版")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：未授权体验版严格分级拦截与商业旗舰版全量解锁
    // ─────────────────────────────────────────────────────────────
    static func test3_FeatureGatingAndInterceptions() {
        print("\n── 判据 3：未授权体验版严格分级拦截与全量解锁 ──")
        let mgr = LicenseManager.shared
        mgr.deactivate()

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        hub.suppressAlertsForTesting = true

        // 3.1 模板移入废纸篓拦截
        let testDir = "\(NSTemporaryDirectory())fcpx_r52_del_test_\(UUID().uuidString)"
        let fm = FileManager.default
        let sampleFile = "\(testDir)/Sample.moti"
        try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        try? "dummy".write(toFile: sampleFile, atomically: true, encoding: .utf8)

        let item = TemplateItem(name: "Sample", category: "Titles.localized", subCategory: "TestSub", tier: .user, path: sampleFile, targetPath: sampleFile, isSymlink: false, targetAvailable: true, sizeMB: 1.0, isEnabled: true)
        hub.plugins = [item]
        hub.allItems = [item]

        hub.deleteTemplateItem(item, skipConfirmation: true)
        check(fm.fileExists(atPath: sampleFile), "未授权体验版下，模板删除被坚决拦截，源文件完好无损")

        // 3.2 情境隔离快速切换拦截
        var profileSwitchBlocked = false
        do {
            _ = try WorkspaceProfileManager.shared.activateProfileSync(id: WorkspaceProfile.weddingId, roots: .resolve(), enforceLicense: true)
        } catch {
            profileSwitchBlocked = true
        }
        check(profileSwitchBlocked, "未授权体验版下，多工作区情境隔离快速切换被拦截并抛出受限异常")

        // 3.3 激活商业授权后，功能解锁验证
        let validKey = LicenseManager.computeLicenseKey(forMachine: mgr.machineCode)
        mgr.activate(key: validKey)
        check(mgr.isProLicensed, "正式激活商业旗舰版")

        hub.deleteTemplateItem(item, skipConfirmation: true)
        check(!fm.fileExists(atPath: sampleFile), "商业旗舰版下，模板安全移入废纸篓操作成功解锁并执行")

        try? fm.removeItem(atPath: testDir)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：中栏 TableView 自定义 GroupTableRowView 与整行联动高亮
    // ─────────────────────────────────────────────────────────────
    static func test4_MiddleColumnGroupTableRowViewAndFullHighlight() {
        print("\n── 判据 4：中栏 TableView 自定义整行高亮与文字联动变色 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        let mockItem = TemplateItem(name: "便签字幕01", category: "Titles.localized", subCategory: "-PVFX 便签字幕", tier: .user, path: "/mock/p1", targetPath: "/mock/p1", isSymlink: false, targetAvailable: true, sizeMB: 3.5, isEnabled: true)
        let grp1 = TemplateGroupItem(name: "-PVFX 便签字幕", category: "Titles.localized", tier: .user, count: 25, totalSizeMB: 88.0, items: [mockItem])
        let grp2 = TemplateGroupItem(name: "综艺动漫标题", category: "Titles.localized", tier: .system, count: 40, totalSizeMB: 120.0, items: [])

        hub.groupItems = [grp1, grp2]
        hub.selectedGroupIndex = 0

        // 4.1 验证自定义 GroupTableRowView 存在且被 TableView 正确返回
        let rowView = hub.tableView(hub.groupTableView, rowViewForRow: 0)
        check(rowView is GroupTableRowView, "groupTableView rowView 为自定义 GroupTableRowView", String(describing: type(of: rowView)))

        // 4.2 验证各列文字在选中态下的高对比联动变色
        // 列 0：名称 (groupName) -> 加粗纯白
        let cell0 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[0], row: 0) as? NSTableCellView
        let lbl0 = cell0?.subviews.first as? NSTextField
        check(lbl0?.textColor == .white, "选中行 groupName 文本切换为加粗纯白")

        // 列 1：数量 (groupCount) -> 高光天青蓝
        let cell1 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[1], row: 0) as? NSTableCellView
        let lbl1 = cell1?.subviews.first as? NSTextField
        let col1 = lbl1?.textColor?.usingColorSpace(.sRGB)
        check((col1?.blueComponent ?? 0) > 0.8, "选中行 groupCount 数字切换为高光天青蓝", "blue=\(col1?.blueComponent ?? 0)")

        // 列 2：大小 (groupSize) -> 高亮银白
        let cell2 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[2], row: 0) as? NSTableCellView
        let lbl2 = cell2?.subviews.first as? NSTextField
        let col2 = lbl2?.textColor?.usingColorSpace(.sRGB)
        let isHighWhite = (col2?.redComponent ?? 0) > 0.85 && (col2?.greenComponent ?? 0) > 0.85 && (col2?.blueComponent ?? 0) > 0.85
        check(isHighWhite, "选中行 groupSize 切换为高亮银白", "rgb=\(col2?.redComponent ?? 0)")

        // 列 3：归属 (groupTier) -> 醒目 ▶ 指示箭头与高光蓝
        let cell3 = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[3], row: 0) as? NSTableCellView
        let lbl3 = cell3?.subviews.first as? NSTextField
        check(lbl3?.stringValue.contains("▶") == true, "选中行 groupTier 醒目渲染「▶」指示箭头", lbl3?.stringValue ?? "")

        // 4.3 验证非选中行未带 ▶ 且颜色不同
        let unselTier = hub.tableView(hub.groupTableView, viewFor: hub.groupTableView.tableColumns[3], row: 1) as? NSTableCellView
        let unselLbl = unselTier?.subviews.first as? NSTextField
        check(unselLbl?.stringValue.contains("▶") == false, "非选中行未呈现「▶」指示箭头")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：右栏卡片流在不同宽度下自适应列宽且无截断溢出
    // ─────────────────────────────────────────────────────────────
    static func test5_AdaptiveFluidGridAndZeroTruncation() {
        print("\n── 判据 5：右栏卡片流自适应弹性布局与零截断 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        var mockItems: [TemplateItem] = []
        for i in 1...12 {
            mockItems.append(TemplateItem(name: "测试模板_\(i)", category: "Titles.localized", subCategory: "Sub", tier: .user, path: "/mock/\(i)", targetPath: "/mock/\(i)", isSymlink: false, targetAvailable: true, sizeMB: 2.0, isEnabled: true))
        }
        hub.plugins = mockItems

        // 模拟 700pt 视口宽度
        hub.cardGridScrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        hub.cardGridScrollView.contentView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        hub.reloadCardGrid(resetPaging: true)

        let rightmostCardX = hub.cardViews.map { $0.frame.maxX }.max() ?? 0
        let availableW: CGFloat = 700
        let rightMargin = availableW - rightmostCardX
        check(rightmostCardX <= availableW, "卡片未超出右栏容器右边界 (MaxX: \(rightmostCardX) <= \(availableW))")
        check(rightMargin >= 14.0, "右侧严格保留至少 14pt 呼吸安全边距 (实际边距: \(rightMargin)pt)，彻底消除截断")

        // 模拟拉大到 1000pt 视口宽度
        hub.cardGridScrollView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        hub.cardGridScrollView.contentView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        hub.reloadCardGrid(resetPaging: false)

        let newRightmost = hub.cardViews.map { $0.frame.maxX }.max() ?? 0
        let newRightMargin = 1000.0 - newRightmost
        check(newRightmost <= 1000.0, "大窗口下卡片未超出边界 (MaxX: \(newRightmost) <= 1000)")
        check(newRightMargin >= 14.0, "大窗口下右侧安全边距保留充分 (实际边距: \(newRightMargin)pt)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：InvisibleScroller 零原生可见滚动条但保持平滑滚动
    // ─────────────────────────────────────────────────────────────
    static func test6_InvisibleScrollerAndSmoothScrolling() {
        print("\n── 判据 6：InvisibleScroller 零可见滑轨滑块与平滑滚动契约 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        check(hub.groupScrollView.verticalScroller is InvisibleScroller,
              "中栏 groupScrollView 已替换为 InvisibleScroller")
        check(hub.cardGridScrollView.verticalScroller is InvisibleScroller,
              "右栏 cardGridScrollView 已替换为 InvisibleScroller")

        let scroller = InvisibleScroller()
        check(InvisibleScroller.isCompatibleWithOverlayScrollers,
              "InvisibleScroller 声明兼容 Overlay Scroller 规范")

        // 验证 draw 不抛异常、不产生脏区域绘制
        scroller.draw(NSRect(x: 0, y: 0, width: 16, height: 200))
        scroller.drawKnob()
        scroller.drawKnobSlot(in: NSRect(x: 0, y: 0, width: 16, height: 200), highlight: false)
        check(true, "InvisibleScroller 空绘制方法执行平稳无异常")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 7：外置盘底部椭圆胶囊、磨砂质感与品牌授权卡片
    // ─────────────────────────────────────────────────────────────
    static func test7_PillFooterAndFrostedGlassTexture() {
        print("\n── 判据 7：外置盘椭圆胶囊、磨砂玻璃与品牌授权卡片 ──")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        // 7.1 验证品牌授权卡片
        check(hub.licenseCardView != nil, "左侧栏已挂载 LicenseStatusCardView")
        check(hub.licenseCardView.machineCodeLabel != nil, "授权卡片包含机器码展示标签")
        check(hub.licenseCardView.copyButton != nil, "授权卡片包含一键复制按钮")
        check(hub.licenseCardView.statusBadgeLabel != nil, "授权卡片包含授权状态徽章")
        check(hub.licenseCardView.toggleActionButton != nil, "授权卡片包含激活交互按钮")
        check(hub.licenseCardView.drawerBox != nil, "授权卡片包含内嵌轻量激活面板")

        hub.licenseCardView.setDrawerExpanded(true)
        check(hub.licenseCardView.isDrawerExpanded, "授权抽屉支持展开输入面板")
        check(hub.licenseCardView.keyInputField != nil, "激活面板包含许可证输入框")
        hub.licenseCardView.setDrawerExpanded(false)
        check(!hub.licenseCardView.isDrawerExpanded, "授权抽屉支持平滑折叠收起")

        // 7.2 验证底部外置挂载胶囊 (Pill shape, cornerRadius = 22, height = 44)
        if let footer = hub.sidebarView.subviews.first(where: { ($0.layer?.cornerRadius ?? 0) >= 20 }) {
            check(footer.layer?.cornerRadius == 22, "外置挂载指示框采用 cornerRadius = 22 椭圆胶囊 (Pill Shape)")
            let h = footer.constraints.first(where: { $0.firstAttribute == .height })?.constant ?? footer.frame.height
            check(h == 44, "外置挂载胶囊高度严格为 44pt", "height=\(h)")
        } else {
            check(false, "未找到 cornerRadius >= 20 的椭圆胶囊底栏")
        }

        // 7.3 验证中栏与右栏移除死黑背景
        let midBg = hub.middleColumnView.layer?.backgroundColor
        check(midBg != nil, "中栏中置背景 Layer 存在")
        if let bg = midBg {
            let col = NSColor(cgColor: bg)
            check((col?.alphaComponent ?? 1.0) < 0.70, "中栏背景已从纯黑降级为半透明磨砂质感 (alpha=\(col?.alphaComponent ?? 1.0))")
        }
    }
}
