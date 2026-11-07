import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r49_render_evidence.swift
//  离屏渲染物证生成器（R49）：
//    1. r49_frosted_canvas_render.png (无限画布磨砂半透明质感渲染图)
//    2. r49_virtual_asset_grid_render.png (素材库虚拟分块渲染与加载更多底栏渲染图)
//    3. r49_storage_migration_pro_render.png (外置搬家中心纯净 SF Symbols 与紧凑 Pro 按钮渲染图)
// ═══════════════════════════════════════════════════════════════

@main
final class R49RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r49_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderFrostedCanvas(outPath: "\(outDir)/r49_frosted_canvas_render.png")
        renderVirtualAssetGrid(outPath: "\(outDir)/r49_virtual_asset_grid_render.png")
        renderStorageMigrationPro(outPath: "\(outDir)/r49_storage_migration_pro_render.png")
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 1：无限画布磨砂半透明质感渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderFrostedCanvas(outPath: String) {
        let winCtrl = MainWindowController()
        guard let win = winCtrl.window, let contentView = win.contentView else {
            print("ERROR: Window contentView is nil")
            return
        }

        win.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 750), display: true)
        contentView.layoutSubtreeIfNeeded()

        guard let backdrop = winCtrl.canvasBackdropView else {
            print("ERROR: CanvasBackdropView is nil")
            return
        }

        backdrop.layoutSubtreeIfNeeded()
        winCtrl.canvasView?.layoutSubtreeIfNeeded()

        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for CanvasBackdrop")
            return
        }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Frosted Canvas Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 2：素材库虚拟分块渲染与加载更多底栏渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderVirtualAssetGrid(outPath: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        hub.currentCategory = "Titles.localized"
        hub.refreshList()
        hub.reloadCardGrid(resetPaging: true)

        // 模拟给前 8 款卡片装载缩略图
        for card in hub.cardViews.prefix(8) {
            let largeCandidate = "\(card.item.targetPath)/large.png"
            if FileManager.default.fileExists(atPath: largeCandidate), let image = NSImage(contentsOfFile: largeCandidate) {
                card.thumbnailImageView.image = image
                card.categoryIconLabel.isHidden = true
            }
        }

        guard let templateModule = hub.templateContainerView else {
            print("ERROR: TemplateContainerView is nil")
            return
        }

        templateModule.layoutSubtreeIfNeeded()
        hub.cardGridScrollView.layoutSubtreeIfNeeded()

        guard let rep = templateModule.bitmapImageRepForCachingDisplay(in: templateModule.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for VirtualAssetGrid")
            return
        }
        templateModule.cacheDisplay(in: templateModule.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Virtual Asset Grid Evidence to \(outPath) (\(data.count) bytes)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 物证 3：外置搬家中心纯净 SF Symbols 与紧凑 Pro 按钮渲染图
    // ─────────────────────────────────────────────────────────────
    static func renderStorageMigrationPro(outPath: String) {
        let migrationView = StorageMigrationDashboardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let mgr = StorageMigrationManager.shared
        let overview = mgr.scanStorage()
        let volumes = mgr.listMountedVolumes()
        migrationView.applyOverview(overview, volumes: volumes)

        migrationView.layoutSubtreeIfNeeded()
        migrationView.categoryTableView.layoutSubtreeIfNeeded()

        guard let rep = migrationView.bitmapImageRepForCachingDisplay(in: migrationView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for StorageMigrationView")
            return
        }
        migrationView.cacheDisplay(in: migrationView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Storage Migration Pro Evidence to \(outPath) (\(data.count) bytes)")
        }
    }
}
