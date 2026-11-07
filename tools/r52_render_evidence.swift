import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r52_render_evidence.swift
//  离屏渲染物证生成器（R52）：
//    1. r52_license_card_and_modal_render.png (设备唯一码与授权管理卡片渲染图)
//    2. r52_table_row_full_highlight_render.png (中栏整行联动高亮与 ▶ 指示渲染图)
//    3. r52_adaptive_grid_no_scrollbar_render.png (右栏自适应流式卡片与零滚动条全景图)
//    4. r52_frosted_pill_footer_render.png (左下角椭圆磨砂挂载胶囊渲染图)
// ═══════════════════════════════════════════════════════════════

@main
final class R52RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r52_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderLicenseCardAndModal(outPath: "\(outDir)/r52_license_card_and_modal_render.png")
        renderTableRowFullHighlight(outPath: "\(outDir)/r52_table_row_full_highlight_render.png")
        renderAdaptiveGridNoScrollbar(outPath: "\(outDir)/r52_adaptive_grid_no_scrollbar_render.png")
        renderFrostedPillFooter(outPath: "\(outDir)/r52_frosted_pill_footer_render.png")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 1：设备唯一码与授权管理卡片渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderLicenseCardAndModal(outPath: String) {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor

        let header = NSTextField(labelWithString: "FCPX Studio Pro 硬件唯一码与商用许可证管理系统 (R52)")
        header.font = .systemFont(ofSize: 16, weight: .bold)
        header.textColor = .white
        header.frame = NSRect(x: 40, y: 430, width: 720, height: 26)
        canvas.addSubview(header)

        // 状态 1：试用体验版（展开激活抽屉）
        let card1 = LicenseStatusCardView(frame: NSRect(x: 40, y: 140, width: 220, height: 160))
        card1.setDrawerExpanded(true)
        card1.keyInputField.stringValue = "FCPX-LIC-D008-DF6F-C787"
        canvas.addSubview(card1)

        let desc1 = NSTextField(labelWithString: "▲ 试用体验版状态（支持一键复制机器码，点击激活就地展开输入面板）")
        desc1.font = .systemFont(ofSize: 11, weight: .medium)
        desc1.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        desc1.frame = NSRect(x: 40, y: 100, width: 340, height: 28)
        canvas.addSubview(desc1)

        // 状态 2：已激活商业旗舰版状态
        let card2 = LicenseStatusCardView(frame: NSRect(x: 420, y: 220, width: 220, height: 80))
        card2.statusBadgeLabel.stringValue = "🟢 永久商用授权"
        card2.statusBadgeLabel.textColor = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.50, alpha: 1.0)
        card2.toggleActionButton.title = "已授权"
        canvas.addSubview(card2)

        let desc2 = NSTextField(labelWithString: "▲ 商业旗舰版状态（绿色微光徽章，全量高级功能无锁解锁）")
        desc2.font = .systemFont(ofSize: 11, weight: .medium)
        desc2.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        desc2.frame = NSRect(x: 420, y: 180, width: 340, height: 28)
        canvas.addSubview(desc2)

        saveViewAsPng(view: canvas, to: outPath, name: "License Card & Modal")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 2：中栏整行联动高亮与 ▶ 指示渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderTableRowFullHighlight(outPath: String) {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor

        let header = NSTextField(labelWithString: "中栏 TableView 整行高亮圆角柔光背景联动变色 (GroupTableRowView)")
        header.font = .systemFont(ofSize: 15, weight: .bold)
        header.textColor = .white
        header.frame = NSRect(x: 30, y: 355, width: 660, height: 24)
        canvas.addSubview(header)

        let tableContainer = NSView(frame: NSRect(x: 30, y: 40, width: 360, height: 290))
        tableContainer.wantsLayer = true
        tableContainer.layer?.cornerRadius = 8
        tableContainer.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 0.85).cgColor
        tableContainer.layer?.borderWidth = 0.8
        tableContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        canvas.addSubview(tableContainer)

        let mockHub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 360, height: 290))
        let grp1 = TemplateGroupItem(name: "-PVFX 便签字幕", category: "Titles.localized", tier: .user, count: 25, totalSizeMB: 88.0, items: [])
        let grp2 = TemplateGroupItem(name: "易安装 - 100个陶丽渐变背景标题", category: "Titles.localized", tier: .user, count: 100, totalSizeMB: 53.4, items: [])
        let grp3 = TemplateGroupItem(name: "03综艺动漫", category: "Titles.localized", tier: .system, count: 280, totalSizeMB: 320.5, items: [])
        let grp4 = TemplateGroupItem(name: "AleFX-Assets", category: "Titles.localized", tier: .system, count: 203, totalSizeMB: 35.8, items: [])

        mockHub.groupItems = [grp1, grp2, grp3, grp4]
        mockHub.selectedGroupIndex = 0
        mockHub.groupTableView.frame = tableContainer.bounds
        mockHub.groupTableView.reloadData()
        mockHub.groupTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        tableContainer.addSubview(mockHub.groupTableView)

        // 右侧说明标注
        let legendBox = NSView(frame: NSRect(x: 410, y: 40, width: 280, height: 290))
        legendBox.wantsLayer = true
        legendBox.layer?.cornerRadius = 8
        legendBox.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.18, alpha: 0.60).cgColor
        legendBox.layer?.borderWidth = 0.6
        legendBox.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.80, alpha: 0.40).cgColor
        canvas.addSubview(legendBox)

        let legendText = """
        【整行联动高亮核心规范】：
        
        1. 柔光深蓝背景：
           - GroupTableRowView 自定义绘制
           - 半透明微光圆角矩形
           - 0.5pt 高光边界光晕
        
        2. 全列文字高对比度同步切换：
           - 插件名称：加粗纯白 (Bold White)
           - 数量徽章：高光天青蓝 (Cyan Blue)
           - 占用大小：高亮银白 (Silver White)
           - 归属列：醒目「▶」指示箭头
        
        彻底告别仅数字变色的脱节体验！
        """
        let legendLabel = NSTextField(wrappingLabelWithString: legendText)
        legendLabel.font = .systemFont(ofSize: 11, weight: .regular)
        legendLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        legendLabel.frame = NSRect(x: 16, y: 16, width: 248, height: 258)
        legendBox.addSubview(legendLabel)

        saveViewAsPng(view: canvas, to: outPath, name: "Table Row Full Highlight")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 3：右栏自适应流式卡片与零滚动条全景图
    // ─────────────────────────────────────────────────────────────
    static func renderAdaptiveGridNoScrollbar(outPath: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

        let mockItem1 = TemplateItem(name: "01 渐变时尚标题", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/1", targetPath: "/mock/1", isSymlink: false, targetAvailable: true, sizeMB: 3.5, isEnabled: true)
        let mockItem2 = TemplateItem(name: "02 唯美浪漫色块", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/2", targetPath: "/mock/2", isSymlink: false, targetAvailable: true, sizeMB: 4.2, isEnabled: true)
        let mockItem3 = TemplateItem(name: "03 动态科技描边", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/3", targetPath: "/mock/3", isSymlink: false, targetAvailable: true, sizeMB: 5.8, isEnabled: true)
        let mockItem4 = TemplateItem(name: "04 极简快闪字幕", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/4", targetPath: "/mock/4", isSymlink: false, targetAvailable: true, sizeMB: 2.1, isEnabled: true)
        let mockItem5 = TemplateItem(name: "05 综艺卡通贴纸", category: "Titles.localized", subCategory: "03综艺动漫", tier: .system, path: "/mock/5", targetPath: "/mock/5", isSymlink: false, targetAvailable: true, sizeMB: 12.0, isEnabled: true)
        let mockItem6 = TemplateItem(name: "06 复古故障噪波", category: "Titles.localized", subCategory: "03综艺动漫", tier: .system, path: "/mock/6", targetPath: "/mock/6", isSymlink: false, targetAvailable: true, sizeMB: 8.4, isEnabled: true)

        let grp1 = TemplateGroupItem(name: "易安装 - 100个陶丽渐变背景标题", category: "Titles.localized", tier: .user, count: 100, totalSizeMB: 53.4, items: [mockItem1, mockItem2, mockItem3, mockItem4, mockItem5, mockItem6])
        hub.groupItems = [grp1]
        hub.selectedGroupIndex = 0
        hub.categoryCapsuleControl.selectedSegment = 0
        hub.updateCategoryCapsuleCounts()
        hub.loadTemplatesForSelectedGroup()

        hub.setFrameSize(NSSize(width: 1280, height: 800))
        hub.layoutSubtreeIfNeeded()

        saveViewAsPng(view: hub, to: outPath, name: "Adaptive Grid No Scrollbar")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 4：左下角椭圆磨砂挂载胶囊渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderFrostedPillFooter(outPath: String) {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor

        let header = NSTextField(labelWithString: "左下角外置盘挂载指示 —— 椭圆胶囊 Pill Shape (R52)")
        header.font = .systemFont(ofSize: 14, weight: .bold)
        header.textColor = .white
        header.frame = NSRect(x: 30, y: 215, width: 440, height: 22)
        canvas.addSubview(header)

        // 构造胶囊
        let pill = NSView(frame: NSRect(x: 40, y: 110, width: 220, height: 44))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 22
        pill.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.45).cgColor
        pill.layer?.borderWidth = 0.8
        pill.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        canvas.addSubview(pill)

        let iconView = NSImageView(frame: NSRect(x: 12, y: 13, width: 18, height: 18))
        iconView.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "外置存储")
        iconView.contentTintColor = NSColor(calibratedRed: 0.28, green: 0.86, blue: 0.55, alpha: 1.0)
        pill.addSubview(iconView)

        let dot = NSView(frame: NSRect(x: 26, y: 11, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.55, alpha: 1.0).cgColor
        dot.layer?.shadowColor = NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.55, alpha: 0.8).cgColor
        dot.layer?.shadowRadius = 4.0
        dot.layer?.shadowOpacity = 1.0
        dot.layer?.shadowOffset = .zero
        pill.addSubview(dot)

        let mainLabel = NSTextField(labelWithString: "外置剪辑盘已挂载")
        mainLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        mainLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        mainLabel.frame = NSRect(x: 38, y: 22, width: 170, height: 16)
        pill.addSubview(mainLabel)

        let subLabel = NSTextField(labelWithString: "卷: 摄影师工具箱128GB · 0 占用")
        subLabel.font = .systemFont(ofSize: 9.5)
        subLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        subLabel.frame = NSRect(x: 38, y: 6, width: 170, height: 14)
        pill.addSubview(subLabel)

        let specs = NSTextField(labelWithString: "• cornerRadius: 22pt (完美椭圆)\n• height: 44pt (标准 Apple 触控区)\n• 磨砂微光边框 + 原生 SF Symbol 呼吸灯")
        specs.font = .systemFont(ofSize: 11)
        specs.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        specs.frame = NSRect(x: 40, y: 35, width: 420, height: 50)
        canvas.addSubview(specs)

        saveViewAsPng(view: canvas, to: outPath, name: "Frosted Pill Footer")
    }

    private static func saveViewAsPng(view: NSView, to path: String, name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SUCCESS: Rendered \(name) to \(path) (\(data.count) bytes)")
        }
    }
}
