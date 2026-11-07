import AppKit
import Foundation

@main
final class R41RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
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

        // 模拟体检报告注入
        let mockIssues: [GhostIssue] = [
            GhostIssue(
                templateName: "01_Cinematic_Title_Dangling",
                category: "Titles.localized",
                symptom: .danglingSymlink,
                path: "~/Movies/Movies/Motion Templates.localized/Titles.localized/Cinematic/01_Cinematic_Title_Dangling",
                targetPath: "/Volumes/Unplugged_SSD/Projects/Templates/01_Cinematic_Title_Dangling",
                detail: "软链接指向目标不存在: /Volumes/Unplugged_SSD/Projects/Templates/01_Cinematic_Title_Dangling",
                suggestedFix: "探测到新挂载卷相同路径，支持一键自愈重连",
                canAutoRelink: true,
                relinkCandidatePath: "/Volumes/摄影师工具箱128GB/Projects/Templates/01_Cinematic_Title_Dangling"
            ),
            GhostIssue(
                templateName: "Broken_Glitch_Transition",
                category: "Transitions.localized",
                symptom: .corruptedXML,
                path: "~/Movies/Movies/Motion Templates.localized/Transitions.localized/Glitch/Broken_Glitch_Transition.motr",
                targetPath: nil,
                detail: "XML 模板文件尺寸为 0 字节，无法解析",
                suggestedFix: "一键安全隔离至 _Quarantine 避免红屏",
                canAutoRelink: false
            ),
            GhostIssue(
                templateName: "Cyberpunk_Overlay_Gen",
                category: "Generators.localized",
                symptom: .missingMedia,
                path: "~/Movies/Movies/Motion Templates.localized/Generators.localized/SciFi/Cyberpunk_Overlay_Gen.motn",
                targetPath: "Texture_Grid_4K.png",
                detail: "引用的 1 项媒体贴图缺失: Texture_Grid_4K.png",
                suggestedFix: "媒体资源缺失，建议补齐 Media/ 或一键隔离",
                canAutoRelink: false
            )
        ]

        let mockReport = DoctorReport(
            scanDate: Date(),
            totalScanned: 24,
            healthyCount: 21,
            issues: mockIssues
        )

        hubView.selectSidebarItem(at: 7) // 🩺 幽灵插件医生
        hubView.doctorDashboardView.applyReport(mockReport)

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

        let outPath = "docs/r41_evidence/r41_doctor_dashboard_render.png"
        do {
            try pngData.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered R41 Doctor Dashboard to \(outPath) (\(pngData.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            print("ERROR: Failed to write PNG: \(error)")
            exit(1)
        }
    }
}
