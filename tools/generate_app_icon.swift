import AppKit
import Foundation
import CoreGraphics

// ═══════════════════════════════════════════════════════════════
//  generate_app_icon.swift
//  FCPX Studio Pro 官方 macOS HIG 高清矢量图标生成器 (1024x1024)
//  设计语言：
//    1. 暗夜曜石钛金渐变底座 (#181b22 → #0d0f13)
//    2. macOS 标准 Squircle 连续平滑圆角 (824x824 @ 1024x1024, r=185)
//    3. 悬浮立体柔和投影 (blur=36, y=-22, alpha=0.5)
//    4. 环形微光金属高光边框 (2.0pt, white 32% → 8%)
//    5. 双色霓虹动感光轨 (Electric Cyan #00e5ff & Magenta Rose #ff2a6d)
//    6. ✦ Studio 专业星标与胶片时间线切刀徽标
// ═══════════════════════════════════════════════════════════════

final class IconGenerator {
    static func generateMasterImage() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let img = NSImage(size: size)
        img.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus()
            return img
        }

        // 1. 背景透明
        ctx.clear(CGRect(origin: .zero, size: size))

        // 2. macOS HIG 标准 Squircle 几何尺寸
        // 1024 画布下，图标主体推荐 824x824，留白 100pt，圆角 185pt
        let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let cornerRadius: CGFloat = 185.0
        let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // 3. 悬浮柔和深邃投影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -24),
            blur: 40,
            color: NSColor.black.withAlphaComponent(0.55).cgColor
        )
        ctx.addPath(squirclePath)
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 4. 裁剪至 Squircle 内部绘制主体
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()

        // 4.1 曜石钛金双阶渐变底座 (#1d212b -> #0c0d11)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let baseColors = [
            NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0).cgColor
        ] as CFArray
        let baseLocations: [CGFloat] = [0.0, 1.0]
        if let baseGradient = CGGradient(colorsSpace: colorSpace, colors: baseColors, locations: baseLocations) {
            ctx.drawLinearGradient(
                baseGradient,
                start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
                end: CGPoint(x: iconRect.midX, y: iconRect.minY),
                options: []
            )
        }

        // 4.2 细腻科技点阵网格纹理 (Dot Matrix Texture)
        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.035).cgColor)
        let step: CGFloat = 32.0
        for x in stride(from: iconRect.minX + 16, to: iconRect.maxX, by: step) {
            for y in stride(from: iconRect.minY + 16, to: iconRect.maxY, by: step) {
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3.5, height: 3.5))
            }
        }

        // 4.3 影视调色光圈同心环 (Cinematic Aperture Rings)
        ctx.saveGState()
        let center = CGPoint(x: iconRect.midX - 20, y: iconRect.midY + 20)
        let radii: [CGFloat] = [120, 210, 300]
        for (i, r) in radii.enumerated() {
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: CGFloat(0.04 + Double(i) * 0.02)).cgColor)
            ctx.setLineWidth(1.5)
            if i % 2 == 1 {
                ctx.setLineDash(phase: 0, lengths: [12, 12])
            } else {
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()

        // 4.4 霓虹动感光轨 (Neon Dynamic Velocity Ribbon)
        // 轨迹 1：科技电光蓝 (Electric Cyan #00e5ff)
        ctx.saveGState()
        let cyanPath = CGMutablePath()
        cyanPath.move(to: CGPoint(x: iconRect.minX + 80, y: iconRect.minY + 220))
        cyanPath.addCurve(
            to: CGPoint(x: iconRect.maxX - 90, y: iconRect.maxY - 180),
            control1: CGPoint(x: iconRect.minX + 320, y: iconRect.midY + 180),
            control2: CGPoint(x: iconRect.midX + 80, y: iconRect.midY - 120)
        )
        ctx.setShadow(offset: .zero, blur: 32, color: NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.9).cgColor)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.0, green: 0.90, blue: 1.0, alpha: 0.95).cgColor)
        ctx.setLineWidth(16.0)
        ctx.setLineCap(.round)
        ctx.addPath(cyanPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 轨迹 2：炽热品红流光 (Vivid Magenta Rose #ff2a6d)
        ctx.saveGState()
        let rosePath = CGMutablePath()
        rosePath.move(to: CGPoint(x: iconRect.minX + 140, y: iconRect.maxY - 160))
        rosePath.addCurve(
            to: CGPoint(x: iconRect.maxX - 100, y: iconRect.minY + 240),
            control1: CGPoint(x: iconRect.midX - 100, y: iconRect.midY + 80),
            control2: CGPoint(x: iconRect.midX + 260, y: iconRect.midY + 200)
        )
        ctx.setShadow(offset: .zero, blur: 28, color: NSColor(calibratedRed: 1.0, green: 0.16, blue: 0.43, alpha: 0.85).cgColor)
        ctx.setStrokeColor(NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.48, alpha: 0.95).cgColor)
        ctx.setLineWidth(14.0)
        ctx.setLineCap(.round)
        ctx.addPath(rosePath)
        ctx.strokePath()
        ctx.restoreGState()

        // 4.5 核心时间线胶片切刀几何徽章 (Central Blade / Motion Prism)
        let prismCenter = CGPoint(x: iconRect.midX, y: iconRect.midY + 10)
        let prismW: CGFloat = 260
        let prismH: CGFloat = 260
        let prismRect = CGRect(x: prismCenter.x - prismW / 2, y: prismCenter.y - prismH / 2, width: prismW, height: prismH)

        // 玻璃棱镜底板
        let prismPath = CGPath(roundedRect: prismRect, cornerWidth: 48, cornerHeight: 48, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.22, alpha: 0.82).cgColor)
        ctx.addPath(prismPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 棱镜高光边框
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.28).cgColor)
        ctx.setLineWidth(2.0)
        ctx.addPath(prismPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 绘制 FCPX 标志性矢量几何：动感播放三角与剪辑切刀
        ctx.saveGState()
        let playPath = CGMutablePath()
        let pOffset: CGFloat = 16
        playPath.move(to: CGPoint(x: prismCenter.x - 45 + pOffset, y: prismCenter.y - 65))
        playPath.addLine(to: CGPoint(x: prismCenter.x + 65 + pOffset, y: prismCenter.y))
        playPath.addLine(to: CGPoint(x: prismCenter.x - 45 + pOffset, y: prismCenter.y + 65))
        playPath.closeSubpath()

        ctx.setShadow(offset: .zero, blur: 24, color: NSColor(calibratedRed: 0.4, green: 0.75, blue: 1.0, alpha: 0.8).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(playPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 4.6 ✦ Studio 专业星标 (Diamond Flare)
        let starCenter = CGPoint(x: iconRect.maxX - 190, y: iconRect.maxY - 200)
        drawStudioSparkle(at: starCenter, ctx: ctx)

        // 4.7 底部 Studio Pro 钛金专业铭刻
        let proAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .black),
            .foregroundColor: NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.98, alpha: 0.95),
            .kern: 7.0
        ]
        let proText = NSAttributedString(string: "FCPX STUDIO", attributes: proAttrs)
        let textSize = proText.size()
        proText.draw(at: CGPoint(x: iconRect.midX - textSize.width / 2, y: iconRect.minY + 95))

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 0.90),
            .kern: 9.0
        ]
        let subText = NSAttributedString(string: "PRO EDITION", attributes: subAttrs)
        let subSize = subText.size()
        subText.draw(at: CGPoint(x: iconRect.midX - subSize.width / 2, y: iconRect.minY + 62))

        ctx.restoreGState() // 恢复 Squircle 裁剪

        // 5. 环形微光金属边框 (Beveled Rim 2.0pt)
        ctx.saveGState()
        let rimColors = [
            NSColor(white: 1.0, alpha: 0.36).cgColor,
            NSColor(white: 1.0, alpha: 0.08).cgColor
        ] as CFArray
        if let rimGradient = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 1.0]) {
            ctx.addPath(squirclePath)
            ctx.setLineWidth(2.5)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(
                rimGradient,
                start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
                end: CGPoint(x: iconRect.midX, y: iconRect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        img.unlockFocus()
        return img
    }

    private static func drawStudioSparkle(at center: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20, color: NSColor(calibratedRed: 0.5, green: 0.85, blue: 1.0, alpha: 1.0).cgColor)

        // 四角菱形星芒
        let starPath = CGMutablePath()
        let rL: CGFloat = 52.0
        let rS: CGFloat = 10.0
        starPath.move(to: CGPoint(x: center.x, y: center.y + rL))
        starPath.addLine(to: CGPoint(x: center.x + rS, y: center.y + rS))
        starPath.addLine(to: CGPoint(x: center.x + rL, y: center.y))
        starPath.addLine(to: CGPoint(x: center.x + rS, y: center.y - rS))
        starPath.addLine(to: CGPoint(x: center.x, y: center.y - rL))
        starPath.addLine(to: CGPoint(x: center.x - rS, y: center.y - rS))
        starPath.addLine(to: CGPoint(x: center.x - rL, y: center.y))
        starPath.addLine(to: CGPoint(x: center.x - rS, y: center.y + rS))
        starPath.closeSubpath()

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(starPath)
        ctx.fillPath()

        // 中心聚光亮点
        ctx.setFillColor(NSColor(calibratedRed: 0.7, green: 0.95, blue: 1.0, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))

        ctx.restoreGState()
    }

    static func exportIconset(from image: NSImage, targetDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let specs: [(name: String, pixelSize: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for spec in specs {
            let outPath = "\(targetDir)/\(spec.name)"
            let s = CGFloat(spec.pixelSize)
            let resized = NSImage(size: NSSize(width: s, height: s))
            resized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: s, height: s),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
            resized.unlockFocus()

            if let tiff = resized.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outPath))
            }
        }
    }
}

// 执行生成流程
let master = IconGenerator.generateMasterImage()
let iconsetDir = "build_staging/AppIcon.iconset"
IconGenerator.exportIconset(from: master, targetDir: iconsetDir)

// 也保存一张高保真预览大图到 docs/r49_evidence
try? FileManager.default.createDirectory(atPath: "docs/r49_evidence", withIntermediateDirectories: true)
if let tiff = master.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "docs/r49_evidence/r49_app_icon_1024x1024.png"))
}

print("Iconset generated at \(iconsetDir)")
