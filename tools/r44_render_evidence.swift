import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r44_render_evidence.swift
//  离屏渲染物证生成器：
//    r44_team_sync_render.png (团队资产免流量分发与环境克隆系统)
// ═══════════════════════════════════════════════════════════════

@main
final class R44RenderEvidence {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/r44_evidence"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        renderTeamSyncEvidence(outPath: "\(outDir)/r44_team_sync_render.png")
    }

    static func renderTeamSyncEvidence(outPath: String) {
        let mgr = TeamP2PSyncManager.shared
        mgr.clearPeers()
        mgr.clearTransferHistory()

        // 填充代表性局域网在线剪辑工作站
        mgr.addManualPeer(name: "Mac Studio M2 Ultra (主剪一号机)", host: "192.168.1.102", port: 52888)
        mgr.addManualPeer(name: "Mac Pro 电影调色台 (达芬奇/FCPX机房)", host: "192.168.1.108", port: 52888)
        mgr.addManualPeer(name: "MacBook Pro M3 Max (现场跟组剪辑)", host: "192.168.1.115", port: 52888)

        // 填充代表性传输历史记录
        let records = [
            SyncTransferRecord(
                direction: .send,
                targetDevice: "192.168.1.102:52888",
                itemName: "4K极速光效转场全套.fcpxpack",
                category: "环境克隆包",
                sizeBytes: 85_420_000,
                status: "直传成功 (SHA-256 校验一致)",
                durationMs: 780.0
            ),
            SyncTransferRecord(
                direction: .receive,
                targetDevice: "Mac Pro 电影调色台 (192.168.1.108)",
                itemName: "胶片感电影冷调3DLUT",
                category: "3D LUT",
                sizeBytes: 2_450_000,
                status: "成功部署 (已写入 Camera LUTs)",
                durationMs: 42.0
            ),
            SyncTransferRecord(
                direction: .receive,
                targetDevice: "MacBook Pro (192.168.1.115)",
                itemName: "商业大片科技感HUD字幕条",
                category: "Titles.localized",
                sizeBytes: 14_800_000,
                status: "成功部署 (已写入 Titles)",
                durationMs: 145.0
            )
        ]
        for r in records.reversed() {
            mgr.recordTransferEntry(r)
        }

        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let hubView = AssetHubView(frame: frame)
        hubView.selectSidebarItem(at: 10) // 切换至团队分发看板

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hubView
        win.layoutIfNeeded()
        hubView.layoutSubtreeIfNeeded()

        hubView.teamSyncDashboardView?.refreshData()
        hubView.layoutSubtreeIfNeeded()

        guard let rep = hubView.bitmapImageRepForCachingDisplay(in: hubView.bounds) else {
            print("ERROR: Failed to create bitmapImageRep for AssetHubView Team Sync")
            return
        }
        hubView.cacheDisplay(in: hubView.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("SUCCESS: Rendered Team Sync Dashboard to \(outPath) (\(data.count) bytes)")
        }
    }
}
