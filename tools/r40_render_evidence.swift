import AppKit
import Foundation

@main
final class R40RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        let hubView = AssetHubView(frame: frame)
        window.contentView = hubView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        // 模拟/加载模板
        let items: [TemplateItem] = [
            TemplateItem(
                name: "01_Cinematic_Title",
                category: "Titles.localized",
                tier: .builtin,
                path: "/Volumes/摄影师工具箱128GB/未命名文件夹/01_Motion真实运行渲染截图.png",
                targetPath: "/Volumes/摄影师工具箱128GB/未命名文件夹/01_Motion真实运行渲染截图.png",
                isSymlink: false,
                targetAvailable: true,
                sizeMB: 38.5,
                isEnabled: true
            ),
            TemplateItem(
                name: "23_Wedding_Decor",
                category: "Titles.localized",
                tier: .user,
                path: "/Volumes/摄影师工具箱128GB/未命名文件夹/03_Motion真实运行23号含装饰模板截图.png",
                targetPath: "/Volumes/摄影师工具箱128GB/未命名文件夹/03_Motion真实运行23号含装饰模板截图.png",
                isSymlink: false,
                targetAvailable: true,
                sizeMB: 124.0,
                isEnabled: true
            ),
            TemplateItem(
                name: "Retro_Film_Burn",
                category: "Titles.localized",
                tier: .user,
                path: "/tmp/retro",
                targetPath: "/tmp/retro",
                isSymlink: true,
                targetAvailable: true,
                sizeMB: 0.0,
                isEnabled: false
            ),
            TemplateItem(
                name: "System_Lower_Third",
                category: "Titles.localized",
                tier: .system,
                path: "/tmp/system",
                targetPath: "/tmp/system",
                isSymlink: false,
                targetAvailable: true,
                sizeMB: 12.8,
                isEnabled: true
            )
        ]

        // 写入缓存并展示
        AssetCacheManager.shared.setTemplates(category: "Titles.localized", result: TemplateScanResult(items: items, tierNotes: [:], roots: .resolve()))
        hubView.selectSidebarItem(at: 0) // Titles
        hubView.refreshList()
        window.layoutIfNeeded()
        hubView.layoutSubtreeIfNeeded()

        guard let rep = hubView.bitmapImageRepForCachingDisplay(in: hubView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep")
            exit(1)
        }
        hubView.cacheDisplay(in: hubView.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            print("ERROR: Failed to convert to PNG")
            exit(1)
        }

        let outPath = "docs/r40_evidence/r40_dark_sidebar_card_render.png"
        do {
            try pngData.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered R40 UI to \(outPath) (\(pngData.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            print("ERROR: Failed to write PNG: \(error)")
            exit(1)
        }
    }
}
