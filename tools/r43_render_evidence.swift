import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r43_render_evidence.swift
//  离屏渲染物证生成器：
//    r43_workspace_profiles_render.png (对标嘉星2.app多工作区情境隔离配置系统)
// ═══════════════════════════════════════════════════════════════

@main
final class R43RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r43_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderWorkspaceProfilesEvidence(outPath: "\(outDir)/r43_workspace_profiles_render.png")
    }

    static func waitOnMainRunLoop(timeout: TimeInterval = 6.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func renderWorkspaceProfilesEvidence(outPath: String) {
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_render_p_\(UUID().uuidString)"
        let tempTemplatesDir = NSTemporaryDirectory() + "fcpx_r43_render_t_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tempTemplatesDir, 1)

        let fm = FileManager.default
        let titlesDir = "\(tempTemplatesDir)/Titles.localized"
        let effectsDir = "\(tempTemplatesDir)/Effects.localized"
        let transDir = "\(tempTemplatesDir)/Transitions.localized"
        let genDir = "\(tempTemplatesDir)/Generators.localized"
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: effectsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: transDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: genDir, withIntermediateDirectories: true)

        // 创建一批具有代表性的高品质模板
        let templates = [
            ("\(titlesDir)/💍 唯美手写浪漫婚礼片头", true),
            ("\(titlesDir)/💍 PSD婚礼字幕与誓言条", true),
            ("\(titlesDir)/📺 科技感企业商业HUD字幕条.disabled", false),
            ("\(titlesDir)/📱 抖音爆款网感Vlog动态花字.disabled", false),
            ("\(effectsDir)/💍 婚礼柔光唯美胶片浪漫调色", true),
            ("\(effectsDir)/📺 赛博朋克商业广告故障特效.disabled", false),
            ("\(transDir)/💍 光晕唯美无缝柔和转场", true),
            ("\(transDir)/📺 极速推进商业快节奏转场.disabled", false),
            ("\(genDir)/📱 9比16竖版短视频自媒体卡点背景.disabled", false),
            ("\(genDir)/📺 粒子光斑企业宣传片背景.disabled", false)
        ]
        for (path, _) in templates {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? "mock".write(toFile: "\(path)/template.txt", atomically: true, encoding: .utf8)
        }

        let mgr = WorkspaceProfileManager.shared
        mgr.reload()

        let roots = TemplateTierRoots(builtin: nil, user: tempTemplatesDir, system: "/tmp/nonexistent", builtinNote: "测试环境")
        _ = try? mgr.activateProfileSync(id: WorkspaceProfile.weddingId, roots: roots)

        let frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        let hubView = AssetHubView(frame: frame)
        hubView.selectSidebarItem(at: 9) // 切换至工作区情境

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hubView
        win.layoutIfNeeded()
        hubView.layoutSubtreeIfNeeded()

        hubView.profileDashboardView.refreshData()
        hubView.layoutSubtreeIfNeeded()

        guard let rep = hubView.bitmapImageRepForCachingDisplay(in: hubView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for AssetHubView Workspace Profile")
            return
        }
        hubView.cacheDisplay(in: hubView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Workspace Profiles Dashboard to \(outPath) (\(data.count) bytes)")
        }

        try? fm.removeItem(atPath: tempProfilesDir)
        try? fm.removeItem(atPath: tempTemplatesDir)
    }
}
