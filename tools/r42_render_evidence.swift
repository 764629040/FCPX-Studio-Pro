import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r42_render_evidence.swift
//  离屏渲染物证生成器：
//    1. r42_hidden_layers_toggled_render.png (A-72 隐藏层展开 12 层)
//    2. r42_storage_migration_render.png (对标嘉星外置存储与搬家中心)
// ═══════════════════════════════════════════════════════════════

@main
final class R42RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r42_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderHiddenLayersToggledEvidence(outPath: "\(outDir)/r42_hidden_layers_toggled_render.png")
        renderStorageMigrationEvidence(outPath: "\(outDir)/r42_storage_migration_render.png")
    }

    static func waitOnMainRunLoop(timeout: TimeInterval = 10.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func renderHiddenLayersToggledEvidence(outPath: String) {
        let zxPath = "docs/r33_evidence/zhenxiong_equivalent.psd"
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        let mwc = MainWindowController()
        mwc.window?.setFrame(frame, display: true)
        mwc.psdFiles = [zxPath]
        mwc.psdTableView?.reloadData()

        var done = false
        mwc.onParseCompleted = { _ in
            done = true
        }

        mwc.selectPsdFile(at: 0)
        waitOnMainRunLoop(timeout: 15.0) { done }

        // 翻转开关：展开隐藏图层 (1 -> 12 层)
        done = false
        mwc.setIncludeHiddenLayers(true)
        waitOnMainRunLoop(timeout: 15.0) { done }

        mwc.window?.layoutIfNeeded()
        guard let contentView = mwc.window?.contentView else { return }
        contentView.layoutSubtreeIfNeeded()

        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for MainWindow")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Hidden Layers Toggled to \(outPath) (\(data.count) bytes)")
        }
    }

    static func renderStorageMigrationEvidence(outPath: String) {
        let frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        let hubView = AssetHubView(frame: frame)

        // 模拟外置数据
        let mockOverview = StorageOverview(
            localMotionRoot: "~/Movies/Movies/Motion Templates.localized",
            isEntireRootSymlinked: true,
            symlinkTarget: "/Volumes/摄影师工具箱128GB/Motion Templates.localized",
            totalPhysicalSizeBytes: 0,
            totalPhysicalSizeFormatted: "0 B (零占用)",
            savedDiskSizeBytes: 6_240_000_000,
            savedDiskSizeFormatted: "6.24 GB",
            categories: [
                StorageCategoryInfo(
                    category: "Titles.localized",
                    displayName: "💬 标题字幕",
                    path: "~/Movies/Movies/Motion Templates.localized/Titles.localized",
                    isSymlink: true,
                    targetPath: "/Volumes/摄影师工具箱128GB/Motion Templates.localized/Titles.localized",
                    sizeBytes: 2_450_000_000,
                    sizeFormatted: "2.45 GB"
                ),
                StorageCategoryInfo(
                    category: "Effects.localized",
                    displayName: "✨ 视频特效",
                    path: "~/Movies/Movies/Motion Templates.localized/Effects.localized",
                    isSymlink: true,
                    targetPath: "/Volumes/摄影师工具箱128GB/Motion Templates.localized/Effects.localized",
                    sizeBytes: 1_820_000_000,
                    sizeFormatted: "1.82 GB"
                ),
                StorageCategoryInfo(
                    category: "Transitions.localized",
                    displayName: "🔄 视频转场",
                    path: "~/Movies/Movies/Motion Templates.localized/Transitions.localized",
                    isSymlink: true,
                    targetPath: "/Volumes/摄影师工具箱128GB/Motion Templates.localized/Transitions.localized",
                    sizeBytes: 1_250_000_000,
                    sizeFormatted: "1.25 GB"
                ),
                StorageCategoryInfo(
                    category: "Generators.localized",
                    displayName: "⚡️ 视频发生器",
                    path: "~/Movies/Movies/Motion Templates.localized/Generators.localized",
                    isSymlink: true,
                    targetPath: "/Volumes/摄影师工具箱128GB/Motion Templates.localized/Generators.localized",
                    sizeBytes: 720_000_000,
                    sizeFormatted: "720 MB"
                )
            ]
        )

        let mockVolumes = [
            MountedVolumeInfo(
                name: "摄影师工具箱128GB",
                path: "/Volumes/摄影师工具箱128GB",
                totalBytes: 128_000_000_000,
                freeBytes: 78_400_000_000,
                isWritable: true
            ),
            MountedVolumeInfo(
                name: "Extreme PRO 2TB SSD",
                path: "/Volumes/Extreme PRO 2TB SSD",
                totalBytes: 2_000_000_000_000,
                freeBytes: 1_450_000_000_000,
                isWritable: true
            )
        ]

        hubView.selectSidebarItem(at: 8) // 💾 存储与搬家
        hubView.storageMigrationDashboardView.applyOverview(mockOverview, volumes: mockVolumes)

        hubView.layoutSubtreeIfNeeded()

        guard let rep = hubView.bitmapImageRepForCachingDisplay(in: hubView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for AssetHubView")
            return
        }
        hubView.cacheDisplay(in: hubView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Storage Migration Dashboard to \(outPath) (\(data.count) bytes)")
        }
    }
}
