import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  render_github_screenshots.swift
//  GitHub 公开展品全界面高保真脱敏视网膜渲染器
//  100% 遵守绝对隐私安全准则：无个人路径、无真人肖像、无私钥
// ═══════════════════════════════════════════════════════════════

final class PublicScreenshotRenderer {
    static let winW: CGFloat = 1360
    static let winH: CGFloat = 850
    static let topBarH: CGFloat = 46

    // 包装为带 macOS 经典红黄绿交通灯与磨砂暗黑顶栏的精致视网膜窗口
    static func createMacWindowFrame(contentView: NSView, title: String, subtitle: String = "") -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.0
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor

        // 顶栏磨砂条
        let topBar = NSVisualEffectView(frame: NSRect(x: 0, y: winH - topBarH, width: winW, height: topBarH))
        topBar.material = .sidebar
        topBar.blendingMode = .behindWindow
        topBar.state = .active
        topBar.appearance = NSAppearance(named: .darkAqua)
        topBar.wantsLayer = true
        topBar.layer?.borderWidth = 0.5
        topBar.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        // 交通灯
        let lightsX: CGFloat = 18
        let lightY: CGFloat = (topBarH - 12) / 2.0
        let redLight = NSView(frame: NSRect(x: lightsX, y: lightY, width: 12, height: 12))
        redLight.wantsLayer = true
        redLight.layer?.cornerRadius = 6
        redLight.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.35, alpha: 1.0).cgColor
        topBar.addSubview(redLight)

        let yellowLight = NSView(frame: NSRect(x: lightsX + 20, y: lightY, width: 12, height: 12))
        yellowLight.wantsLayer = true
        yellowLight.layer?.cornerRadius = 6
        yellowLight.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1.0).cgColor
        topBar.addSubview(yellowLight)

        let greenLight = NSView(frame: NSRect(x: lightsX + 40, y: lightY, width: 12, height: 12))
        greenLight.wantsLayer = true
        greenLight.layer?.cornerRadius = 6
        greenLight.layer?.backgroundColor = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0).cgColor
        topBar.addSubview(greenLight)

        // 标题与副标题
        let titleLabel = NSTextField(labelWithString: "FCPX Studio Pro  —  \(title)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        titleLabel.frame = NSRect(x: 100, y: (topBarH - 18) / 2.0, width: 600, height: 18)
        topBar.addSubview(titleLabel)

        // 右侧全量模式胶囊
        let modePill = NSTextField(labelWithString: "🌟 [商业旗舰版已激活 · Metal 3 硬件加速]")
        modePill.font = .systemFont(ofSize: 11, weight: .semibold)
        modePill.textColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 1.0, alpha: 1.0)
        modePill.alignment = .right
        modePill.frame = NSRect(x: winW - 360, y: (topBarH - 18) / 2.0, width: 340, height: 18)
        topBar.addSubview(modePill)

        container.addSubview(topBar)

        // 内容区
        let contentRect = NSRect(x: 0, y: 0, width: winW, height: winH - topBarH)
        contentView.frame = contentRect
        container.addSubview(contentView)

        return container
    }

    static func saveViewAsPng(view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("❌ Failed bitmapImageRep for \(path)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("❌ Failed png data for \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("✅ Rendered: \(path) (\(data.count / 1024) KB)")
        } catch {
            print("❌ Write error: \(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 1. 设计器 (PSD → Motion) 原生画布模式
    // ─────────────────────────────────────────────────────────────
    static func renderDesignerCanvas(to path: String) {
        let win = MainWindowController()
        win.segmentedControl.selectedSegment = 0
        win.engine1Container?.isHidden = false
        win.assetHubView?.isHidden = true

        // 模拟加载标准宣传工程图层
        win.canvasView.artboardWidth = 1920
        win.canvasView.artboardHeight = 1080
        win.canvasView.zoomScale = 0.55

        guard let content = win.engine1Container else { return }
        let winView = createMacWindowFrame(contentView: content, title: "设计器 (PSD → Motion 矢量排版引擎)")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 2. 素材库与管理中心（三段式磨砂工作台）
    // ─────────────────────────────────────────────────────────────
    static func renderAssetHubThreeStage(to path: String) {
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))

        // 构造脱敏公共模板组
        let t1 = TemplateItem(name: "01 电影感开场标题", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/1", targetPath: "/Public/1", isSymlink: false, targetAvailable: true, sizeMB: 4.8, isEnabled: true)
        let t2 = TemplateItem(name: "02 唯美浪漫婚礼花纹", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/2", targetPath: "/Public/2", isSymlink: false, targetAvailable: true, sizeMB: 6.2, isEnabled: true)
        let t3 = TemplateItem(name: "03 动态赛博朋克字幕", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/3", targetPath: "/Public/3", isSymlink: false, targetAvailable: true, sizeMB: 3.9, isEnabled: true)
        let t4 = TemplateItem(name: "04 极简快节奏综述条", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/4", targetPath: "/Public/4", isSymlink: false, targetAvailable: true, sizeMB: 2.7, isEnabled: true)
        let t5 = TemplateItem(name: "05 商业宣传光效副标", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/5", targetPath: "/Public/5", isSymlink: false, targetAvailable: true, sizeMB: 5.1, isEnabled: true)
        let t6 = TemplateItem(name: "06 竖屏短视频吸睛浮标", category: "Titles.localized", subCategory: "Cinematic Titles", tier: .user, path: "/Public/6", targetPath: "/Public/6", isSymlink: false, targetAvailable: true, sizeMB: 1.8, isEnabled: true)

        let g1 = TemplateGroupItem(name: "Cinematic Titles (电影感字幕)", category: "Titles.localized", tier: .user, count: 24, totalSizeMB: 128.5, items: [t1, t2, t3, t4, t5, t6])
        let g2 = TemplateGroupItem(name: "Wedding Luxury (婚礼奢华系列)", category: "Titles.localized", tier: .user, count: 18, totalSizeMB: 94.2, items: [])
        let g3 = TemplateGroupItem(name: "Broadcast News (新闻与资讯播报)", category: "Titles.localized", tier: .system, count: 42, totalSizeMB: 215.0, items: [])
        let g4 = TemplateGroupItem(name: "Social Media Vibes (自媒体快剪)", category: "Titles.localized", tier: .user, count: 36, totalSizeMB: 88.6, items: [])

        hub.groupItems = [g1, g2, g3, g4]
        hub.selectedGroupIndex = 0
        hub.categoryCapsuleControl.selectedSegment = 0
        hub.updateCategoryCapsuleCounts()
        hub.loadTemplatesForSelectedGroup()

        hub.licenseCardView?.machineCodeLabel.stringValue = "MAC-8A4F-9C21"
        hub.licenseCardView?.statusBadgeLabel.stringValue = "🟢 商业旗舰版"

        let winView = createMacWindowFrame(contentView: hub, title: "素材库与管理中心 (三段式工作台 · 自适应流式网格)")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 3. 商业授权与独一无二机器硬件码体系
    // ─────────────────────────────────────────────────────────────
    static func renderCommercialLicenseSystem(to path: String) {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor

        // 左侧卡片
        let card1 = LicenseStatusCardView(frame: NSRect(x: 60, y: winH - topBarH - 320, width: 260, height: 110))
        card1.machineCodeLabel.stringValue = "MAC-8A4F-9C21"
        card1.statusBadgeLabel.stringValue = "🟡 免费体验版 (只读保护)"
        card1.statusBadgeLabel.textColor = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1.0)
        card1.toggleActionButton.title = "输入激活码"
        canvas.addSubview(card1)

        let desc1 = NSTextField(labelWithString: "【模式 A：未授权体验版】\n· 独一无二机器硬件码（IOKit 硬件锚定，防篡改防串号）\n· 开放模板浏览与即时查看\n· 严格锁死物理删除与搬家等高危操作，保障新手安全")
        desc1.font = .systemFont(ofSize: 13, weight: .medium)
        desc1.textColor = NSColor(white: 0.75, alpha: 1.0)
        desc1.frame = NSRect(x: 60, y: winH - topBarH - 430, width: 480, height: 80)
        canvas.addSubview(desc1)

        // 右侧激活抽屉
        let card2 = LicenseStatusCardView(frame: NSRect(x: 620, y: winH - topBarH - 320, width: 260, height: 110))
        card2.machineCodeLabel.stringValue = "MAC-8A4F-9C21"
        card2.statusBadgeLabel.stringValue = "🟢 商业旗舰版 (永久授权)"
        card2.statusBadgeLabel.textColor = NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.50, alpha: 1.0)
        card2.toggleActionButton.title = "已授权"
        canvas.addSubview(card2)

        let desc2 = NSTextField(labelWithString: "【模式 B：商业旗舰版】\n· HMAC-SHA256 离线安全签名授权协议 (FCPX-LIC-XXXX-XXXX-XXXX)\n· 全量解锁模板物理删除、批量导出、外置高速搬家、局域网克隆与情境隔离")
        desc2.font = .systemFont(ofSize: 13, weight: .medium)
        desc2.textColor = NSColor(white: 0.75, alpha: 1.0)
        desc2.frame = NSRect(x: 620, y: winH - topBarH - 430, width: 560, height: 80)
        canvas.addSubview(desc2)

        // 示例授权代码展示盒
        let box = NSView(frame: NSRect(x: 60, y: 120, width: winW - 120, height: 150))
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        box.layer?.borderWidth = 1.0
        box.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.45, blue: 0.75, alpha: 0.4).cgColor

        let boxTitle = NSTextField(labelWithString: "🔐 商业授权生成与自动化验证机制 (CLI & Native)")
        boxTitle.font = .systemFont(ofSize: 15, weight: .bold)
        boxTitle.textColor = NSColor(calibratedRed: 0.40, green: 0.85, blue: 1.0, alpha: 1.0)
        boxTitle.frame = NSRect(x: 20, y: 105, width: 600, height: 24)
        box.addSubview(boxTitle)

        let boxCode = NSTextField(labelWithString: "$ python3 tools/generate_license.py --machine MAC-8A4F-9C21\n[Success] License Key: FCPX-LIC-7B21-9E40-F8D2\n[Status] Verified: HMAC-SHA256 Signature Match · Permanent Commercial Grant")
        boxCode.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        boxCode.textColor = NSColor(calibratedRed: 0.60, green: 0.95, blue: 0.70, alpha: 1.0)
        boxCode.frame = NSRect(x: 20, y: 25, width: 900, height: 60)
        box.addSubview(boxCode)
        canvas.addSubview(box)

        let winView = createMacWindowFrame(contentView: canvas, title: "机器唯一码与商用授权分级体系")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 4. 多工作区情境隔离配置系统
    // ─────────────────────────────────────────────────────────────
    static func renderWorkspaceIsolation(to path: String) {
        let view = WorkspaceProfileDashboardView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))
        let winView = createMacWindowFrame(contentView: view, title: "多工作区情境隔离配置系统 (Workspace Context Isolation)")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 5. 外置移动存储与一键搬家管理中心
    // ─────────────────────────────────────────────────────────────
    static func renderStorageMigration(to path: String) {
        let view = StorageMigrationDashboardView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))
        let winView = createMacWindowFrame(contentView: view, title: "外置移动存储与一键搬家管理中心 (零占用系统盘 · 透明符号链接)")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 6. 团队资产免流量分发与环境克隆
    // ─────────────────────────────────────────────────────────────
    static func renderTeamSync(to path: String) {
        let view = TeamSyncDashboardView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))
        let winView = createMacWindowFrame(contentView: view, title: "团队资产免流量分发与环境克隆 (Bonjour P2P 点对点传输)")
        saveViewAsPng(view: winView, to: path)
    }

    // ─────────────────────────────────────────────────────────────
    // 7. 资源库瘦身医生与偏好设置自检
    // ─────────────────────────────────────────────────────────────
    static func renderCleanerAndDiagnostics(to path: String) {
        let view = CleanerDashboardView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarH))
        let winView = createMacWindowFrame(contentView: view, title: "Final Cut Pro 资源库瘦身医生 (安全清理代理/分析缓存/临时渲染)")
        saveViewAsPng(view: winView, to: path)
    }
}

@main
final class ScreenshotMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = "docs/screenshots"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        PublicScreenshotRenderer.renderDesignerCanvas(to: "\(outDir)/01_designer_canvas.png")
        PublicScreenshotRenderer.renderAssetHubThreeStage(to: "\(outDir)/02_asset_hub_three_stage.png")
        PublicScreenshotRenderer.renderCommercialLicenseSystem(to: "\(outDir)/03_commercial_license_system.png")
        PublicScreenshotRenderer.renderWorkspaceIsolation(to: "\(outDir)/04_workspace_context_isolation.png")
        PublicScreenshotRenderer.renderStorageMigration(to: "\(outDir)/05_storage_migration_manager.png")
        PublicScreenshotRenderer.renderTeamSync(to: "\(outDir)/06_team_p2p_sync.png")
        PublicScreenshotRenderer.renderCleanerAndDiagnostics(to: "\(outDir)/07_cleaner_and_diagnostics.png")
        print("🎉 All 7 public screenshots generated successfully!")
    }
}
