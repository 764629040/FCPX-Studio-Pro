import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r47_render_evidence.swift
//  离屏渲染物证生成器（R47）：
//    1. r47_settings_env_render.png (偏好设置与零依赖环境自检面板实证)
// ═══════════════════════════════════════════════════════════════

@main
final class R47RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r47_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderSettingsWindow(outPath: "\(outDir)/r47_settings_env_render.png")
    }

    static func renderSettingsWindow(outPath: String) {
        let ctrl = SettingsWindowController.shared
        guard let win = ctrl.window, let contentView = win.contentView else {
            print("ERROR: Settings window contentView is nil")
            return
        }

        win.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for settings window")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Settings Window Evidence to \(outPath) (\(data.count) bytes)")
        }
    }
}
