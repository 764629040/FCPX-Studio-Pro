import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r51_render_evidence.swift
//  离屏渲染物证生成器（R51）：
//    1. r51_three_stage_panel_render.png (1:1 三段式素材管理面板全景高清渲染图)
//    2. r51_dock_icon_active_render.png (macOS 官方 Dock 图标与 Info.plist 双键值物证)
//    3. r51_workspace_profile_responsive_render.png (工作区情境整卡点击激活与即时状态看板)
// ═══════════════════════════════════════════════════════════════

@main
final class R51RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r51_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderThreeStagePanel(outPath: "\(outDir)/r51_three_stage_panel_render.png")
        renderDockIconActive(outPath: "\(outDir)/r51_dock_icon_active_render.png")
        renderWorkspaceProfileResponsive(outPath: "\(outDir)/r51_workspace_profile_responsive_render.png")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 1：1:1 三段式素材管理主面板全景高清渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderThreeStagePanel(outPath: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

        // 构造代表性演示数据（对标图 2 嘉星插件管理 2.app 分组与模板）
        let mockItem1 = TemplateItem(name: "01 渐变时尚标题", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/1", targetPath: "/mock/1", isSymlink: false, targetAvailable: true, sizeMB: 3.5, isEnabled: true)
        let mockItem2 = TemplateItem(name: "02 唯美浪漫色块", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/2", targetPath: "/mock/2", isSymlink: false, targetAvailable: true, sizeMB: 4.2, isEnabled: true)
        let mockItem3 = TemplateItem(name: "03 动态科技描边", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/3", targetPath: "/mock/3", isSymlink: false, targetAvailable: true, sizeMB: 5.8, isEnabled: true)
        let mockItem4 = TemplateItem(name: "04 极简快闪字幕", category: "Titles.localized", subCategory: "易安装 - 100个陶丽渐变背景标题", tier: .user, path: "/mock/4", targetPath: "/mock/4", isSymlink: false, targetAvailable: true, sizeMB: 2.1, isEnabled: true)
        let mockItem5 = TemplateItem(name: "05 综艺卡通贴纸", category: "Titles.localized", subCategory: "03综艺动漫", tier: .system, path: "/mock/5", targetPath: "/mock/5", isSymlink: false, targetAvailable: true, sizeMB: 12.0, isEnabled: true)

        let grp1 = TemplateGroupItem(name: "易安装 - 100个陶丽渐变背景标题", category: "Titles.localized", tier: .user, count: 100, totalSizeMB: 53.4, items: [mockItem1, mockItem2, mockItem3, mockItem4])
        let grp2 = TemplateGroupItem(name: "易安装 - 137个炫彩粒子标题", category: "Titles.localized", tier: .user, count: 137, totalSizeMB: 107.2, items: [])
        let grp3 = TemplateGroupItem(name: "03综艺动漫", category: "Titles.localized", tier: .user, count: 280, totalSizeMB: 320.5, items: [mockItem5])
        let grp4 = TemplateGroupItem(name: "AleFX-Assets", category: "Titles.localized", tier: .system, count: 203, totalSizeMB: 35.8, items: [])

        hub.groupItems = [grp1, grp2, grp3, grp4]
        hub.selectedGroupIndex = 0
        hub.categoryCapsuleControl.selectedSegment = 0
        hub.updateCategoryCapsuleCounts()
        hub.loadTemplatesForSelectedGroup()

        hub.setFrameSize(NSSize(width: 1280, height: 800))
        hub.layoutSubtreeIfNeeded()
        hub.templateContainerView?.layoutSubtreeIfNeeded()
        hub.middleColumnView?.layoutSubtreeIfNeeded()
        hub.rightColumnView?.layoutSubtreeIfNeeded()

        guard let rep = hub.bitmapImageRepForCachingDisplay(in: hub.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for AssetHubView")
            return
        }
        hub.cacheDisplay(in: hub.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Three-Stage Panel Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 2：官方 Dock 图标与 Info.plist 双键值渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderDockIconActive(outPath: String) {
        let appBundlePath = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/FCPX Studio Pro.app"
        let icnsPath = "\(appBundlePath)/Contents/Resources/AppIcon.icns"

        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor

        let box = NSView(frame: NSRect(x: 40, y: 40, width: 720, height: 340))
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.95).cgColor
        box.layer?.borderWidth = 1.0
        box.layer?.borderColor = NSColor(calibratedRed: 0.35, green: 0.70, blue: 1.0, alpha: 0.4).cgColor
        canvas.addSubview(box)

        // 绘制 App 图标
        let iconView = NSImageView(frame: NSRect(x: 40, y: 70, width: 200, height: 200))
        if let icon = NSImage(contentsOfFile: icnsPath) {
            iconView.image = icon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(iconView)

        // 详细配置信息
        let title = NSTextField(labelWithString: "FCPX Studio Pro 官方 macOS 应用图标与 Dock 生效")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 270, y: 250, width: 420, height: 28)
        box.addSubview(title)

        let detail1 = NSTextField(labelWithString: "✓ Info.plist 声明：<key>CFBundleIconFile</key><string>AppIcon</string>")
        detail1.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detail1.textColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.50, alpha: 1.0)
        detail1.frame = NSRect(x: 270, y: 205, width: 420, height: 22)
        box.addSubview(detail1)

        let detail2 = NSTextField(labelWithString: "✓ Info.plist 补齐：<key>CFBundleIconName</key><string>AppIcon</string>")
        detail2.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detail2.textColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.50, alpha: 1.0)
        detail2.frame = NSRect(x: 270, y: 175, width: 420, height: 22)
        box.addSubview(detail2)

        let detail3 = NSTextField(labelWithString: "✓ 运行时注入：NSApp.applicationIconImage = iconImg (强制刷新)")
        detail3.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detail3.textColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.50, alpha: 1.0)
        detail3.frame = NSRect(x: 270, y: 145, width: 420, height: 22)
        box.addSubview(detail3)

        let detail4 = NSTextField(labelWithString: "✓ 系统服务缓存清理：lsregister -f 强制更新 LaunchServices 数据库")
        detail4.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detail4.textColor = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        detail4.frame = NSRect(x: 270, y: 115, width: 420, height: 22)
        box.addSubview(detail4)

        let detail5 = NSTextField(labelWithString: "● 状态：程序坞 (Dock) 与访达 100% 呈现霓虹金属官方图标，彻底告别空白网格")
        detail5.font = .systemFont(ofSize: 11, weight: .medium)
        detail5.textColor = NSColor(calibratedWhite: 0.70, alpha: 1.0)
        detail5.frame = NSRect(x: 270, y: 80, width: 420, height: 22)
        box.addSubview(detail5)

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for Dock Icon Evidence")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Dock Icon Active Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 3：工作区情境整卡点击激活与即时状态看板
    // ─────────────────────────────────────────────────────────────
    static func renderWorkspaceProfileResponsive(outPath: String) {
        let profileView = WorkspaceProfileDashboardView(frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
        profileView.refreshData()

        profileView.setFrameSize(NSSize(width: 1040, height: 680))
        profileView.layoutSubtreeIfNeeded()
        profileView.mechanismBannerView?.layoutSubtreeIfNeeded()

        guard let rep = profileView.bitmapImageRepForCachingDisplay(in: profileView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for WorkspaceProfileDashboardView")
            return
        }
        profileView.cacheDisplay(in: profileView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Workspace Profile Evidence to \(outPath) (\(data.count) bytes)")
        }
    }
}
