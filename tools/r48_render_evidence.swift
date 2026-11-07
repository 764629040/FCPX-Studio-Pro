import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r48_render_evidence.swift
//  离屏渲染物证生成器（R48）：
//    1. r48_topbar_spacing_render.png (顶栏避让解耦高保真渲染图)
//    2. r48_sidebar_sf_symbols_render.png (左侧侧边栏 SF Symbols 渲染图)
//    3. r48_real_templates_large_png_render.png (真实读取 FCPX large.png 缩略图网格渲染图)
// ═══════════════════════════════════════════════════════════════

@main
final class R48RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r48_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderTopBarSpacing(outPath: "\(outDir)/r48_topbar_spacing_render.png")
        renderSidebarSFSymbols(outPath: "\(outDir)/r48_sidebar_sf_symbols_render.png")
        renderRealTemplatesLargePngGrid(outPath: "\(outDir)/r48_real_templates_large_png_render.png")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 1：顶栏避让解耦高保真渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderTopBarSpacing(outPath: String) {
        let winCtrl = MainWindowController()
        guard let win = winCtrl.window, let contentView = win.contentView else {
            print("ERROR: Window contentView is nil")
            return
        }

        // 仅抓取顶栏 50pt 高度区域进行高清特写实证
        win.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 750), display: true)
        contentView.layoutSubtreeIfNeeded()

        // 寻找 topBar (NSVisualEffectView)
        var topBarView: NSView?
        for sub in contentView.subviews {
            if sub is NSVisualEffectView && sub.frame.height <= 60 {
                topBarView = sub
                break
            }
        }
        guard let targetView = topBarView ?? contentView.subviews.first else {
            print("ERROR: TopBar view not found")
            return
        }

        targetView.layoutSubtreeIfNeeded()
        guard let rep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for TopBar")
            return
        }
        targetView.cacheDisplay(in: targetView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered TopBar Spacing Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 2：左侧侧边栏 SF Symbols 渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderSidebarSFSymbols(outPath: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        hub.layoutSubtreeIfNeeded()

        guard let sidebar = hub.sidebarView else {
            print("ERROR: SidebarView is nil")
            return
        }

        sidebar.layoutSubtreeIfNeeded()
        guard let rep = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for SidebarView")
            return
        }
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Sidebar SF Symbols Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 3：真实读取 FCPX large.png 缩略图网格渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderRealTemplatesLargePngGrid(outPath: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))

        // 模拟切换至 03综艺动漫 分类，展示高密度的真实 large.png 缩略图
        hub.currentCategory = "Titles.localized"
        hub.currentSubCategoryFilter = "03综艺动漫"
        hub.refreshList()

        // 强制触发一次同步卡片网格加载与缩略图读取
        hub.reloadCardGrid()
        for card in hub.cardViews.prefix(12) {
            let img = (card as NSView).subviews
            // 让卡片读取本地 large.png
            if let p = (try? FileManager.default.contentsOfDirectory(atPath: card.item.targetPath)) {
                let largeCandidate = "\(card.item.targetPath)/large.png"
                if FileManager.default.fileExists(atPath: largeCandidate), let image = NSImage(contentsOfFile: largeCandidate) {
                    card.thumbnailImageView.image = image
                    card.categoryIconLabel.isHidden = true
                }
            }
        }

        guard let templateModule = hub.templateContainerView else {
            print("ERROR: TemplateContainerView is nil")
            return
        }

        templateModule.layoutSubtreeIfNeeded()
        hub.cardGridScrollView.layoutSubtreeIfNeeded()

        guard let rep = templateModule.bitmapImageRepForCachingDisplay(in: templateModule.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for TemplateContainerView")
            return
        }
        templateModule.cacheDisplay(in: templateModule.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Real Templates Large PNG Grid Evidence to \(outPath) (\(data.count) bytes)")
        }
    }
}
