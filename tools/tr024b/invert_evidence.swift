// ═══════════════════════════════════════════════════════════════════════════
// tools/tr024b/invert_evidence.swift
// TR-024-2 取证：真反相（RGB 取反、alpha 原样、不吃目标色）+ 屏幕/导出一致性
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr024b/invert_evidence.swift -o /tmp/tr024b_evidence_bin
// 运行 cwd 必须是项目根。
//
// 产出：
//   /tmp/tr024b_shots/01_direct.png              直接替换（屏幕）
//   /tmp/tr024b_shots/02_invert.png              反相（屏幕）
//   /tmp/tr024b_shots/03_invert_nocolor.png      反相 + 没设目标色（闸门取证）
//   /tmp/tr024b_export/<key>/Media/*.png         三种情况的真实导出
//   /tmp/tr024b_shots/meta.txt                   缩放 / 控件可用性 / 提示行 原文
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import AppKit
import CoreGraphics

@main
struct InvertEvidence {
    static let shotsDir = "/tmp/tr024b_shots"
    static let exportRoot = "/tmp/tr024b_export"
    static let srcDir = "/tmp/tr024b_src"
    static let srcPng = "/tmp/tr024b_src/black_text.png"
    static let targetHex = "#1BFF93"

    static var wc: MainWindowController!
    static var meta: [String] = []

    static func log(_ s: String) {
        print("[TR-024-2] " + s)
        fflush(stdout)
    }

    static func main() {
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: exportRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        wc = MainWindowController()
        wc.showWindow(nil)
        wc.window?.setFrame(NSRect(x: 80, y: 80, width: 1400, height: 900), display: true)
        app.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { run() }
        app.run()
    }

    // MARK: - 主流程

    static func run() {
        guard makeBlackTextPNG(at: srcPng) else {
            log("生成黑字 PNG 失败: \(srcPng)")
            exit(2)
        }
        log("黑字源图: \(srcPng)（透明底 + 纯黑墨，与 PSD 文字层拆分产物同构）")

        // 一个真位图层模型，走画布真实的位图渲染分支（kind=fallback_png → drawBitmap）
        let layer = LayerModel(id: 1,
                               name: "TR0242黑字",
                               kind: "fallback_png",
                               text: "",
                               fallbackPngPath: srcPng,
                               psdBBox: [0, 0, 1200, 600])
        layer.posX = 0
        layer.posY = 0
        // 缩放固定 100%：两张验收图一律不碰这个值，保证尺寸可比
        layer.scaleX = 1.0
        layer.scaleY = 1.0
        layer.rotation = 0
        layer.colorOverride = targetHex
        layer.recolorMode = RecolorMode.direct.rawValue

        wc.canvasView.backgroundPreview = nil
        wc.canvasView.layers = [layer]
        wc.canvasView.setResolution(width: 1200, height: 600)
        wc.canvasView.selectedLayerIndex = 0
        wc.inspectorView.layers = [layer]
        wc.inspectorView.selectLayer(at: 0)
        wc.inspectorView.resolutionLabel?.stringValue = "📐 幅面规格 1200×600（TR-024-2 取证：黑墨 PNG 位图层）"
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        log("窗口 windowNumber=\(wc.window?.windowNumber ?? -1) canvasZoom=\(String(format: "%.3f", wc.canvasView.zoomScale))")

        // ── 1. 两张验收截图：同一会话、同一缩放，只切模式 ──
        let steps: [(key: String, mode: RecolorMode)] = [
            ("01_direct", .direct),
            ("02_invert", .invert)
        ]
        var scaleSeen: [String] = []
        for step in steps {
            layer.recolorMode = step.mode.rawValue
            wc.inspectorView.refreshBitmapRecolorControls()
            wc.canvasView.needsDisplay = true
            wc.window?.contentView?.needsDisplay = true
            wc.window?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))

            let scaleText = wc.inspectorView.scaleField?.stringValue ?? "<nil>"
            let hint = wc.inspectorView.recolorHintText(for: layer).text
            let wellOn = wc.inspectorView.recolorColorWell?.isEnabled ?? false
            let hexOn = wc.inspectorView.recolorHexField?.isEnabled ?? false
            let hexText = wc.inspectorView.recolorHexField?.stringValue ?? "<nil>"
            let comboOn = wc.inspectorView.recolorModePopup?.isEnabled ?? false
            scaleSeen.append(scaleText)

            let path = "\(shotsDir)/\(step.key).png"
            let ok = captureWindow(to: path)
            log("截图 \(step.key) mode=\(step.mode.title) -> \(ok ? "OK" : "失败") \(path)")
            let line = "step=\(step.key) mode=\(step.mode.title) 缩放=\(scaleText) "
                + "modePopup.isEnabled=\(comboOn) colorWell.isEnabled=\(wellOn) "
                + "hexField.isEnabled=\(hexOn) hexText=\(hexText) 提示行=\(hint)"
            log(line)
            meta.append(line)
            if !ok {
                log("窗口截图失败，停止（不允许离屏渲染顶替）")
                exit(3)
            }
        }
        if Set(scaleSeen).count != 1 {
            log("!! 两张截图缩放不一致: \(scaleSeen) —— 直接判失败")
            exit(6)
        }
        log("两张截图缩放一致: \(scaleSeen[0])")
        meta.append("两张截图缩放一致: \(scaleSeen[0])")

        // ── 2. 闸门取证：反相 + 完全没设目标色 ──
        layer.colorOverride = ""
        layer.recolorMode = RecolorMode.invert.rawValue
        wc.inspectorView.refreshBitmapRecolorControls()
        wc.canvasView.needsDisplay = true
        wc.window?.contentView?.needsDisplay = true
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let nScale = wc.inspectorView.scaleField?.stringValue ?? "<nil>"
        let nHint = wc.inspectorView.recolorHintText(for: layer).text
        let nWell = wc.inspectorView.recolorColorWell?.isEnabled ?? false
        let nHexOn = wc.inspectorView.recolorHexField?.isEnabled ?? false
        let nHexText = wc.inspectorView.recolorHexField?.stringValue ?? "<nil>"
        let nPath = "\(shotsDir)/03_invert_nocolor.png"
        let nOk = captureWindow(to: nPath)
        log("截图 03_invert_nocolor -> \(nOk ? "OK" : "失败") \(nPath)")
        let nLine = "step=03_invert_nocolor mode=反相 colorOverride=\"\" 缩放=\(nScale) "
            + "colorWell.isEnabled=\(nWell) hexField.isEnabled=\(nHexOn) hexText=\(nHexText) 提示行=\(nHint)"
        log(nLine)
        meta.append(nLine)
        if !nOk { exit(3) }

        // 控件可用性断言：反相下色块 + HEX 必须灰掉，模式下拉必须可点
        if nWell || nHexOn {
            log("!! 反相下颜色控件没灰掉（colorWell=\(nWell) hexField=\(nHexOn)）")
            exit(7)
        }
        if !(wc.inspectorView.recolorModePopup?.isEnabled ?? false) {
            log("!! 反相下模式下拉也被灰掉了，切不回其它模式")
            exit(8)
        }

        // 提示行断言：反相下不许出现多色提示
        if nHint.contains("多色") {
            log("!! 反相下仍出现多色提示: \(nHint)")
            exit(9)
        }

        // ── 3. 三份真实导出（走 MotionBuilderSocket.buildTemplateResult，和保存/批量导出同一条路）──
        let exportCases: [(key: String, mode: RecolorMode, hex: String)] = [
            ("01_direct", .direct, targetHex),
            ("02_invert", .invert, targetHex),
            ("03_invert_nocolor", .invert, "")
        ]
        for c in exportCases {
            layer.recolorMode = c.mode.rawValue
            layer.colorOverride = c.hex
            let dir = "\(exportRoot)/\(c.key)"
            try? FileManager.default.removeItem(atPath: dir)
            let result = MotionBuilderSocket.shared.buildTemplateResult(
                psdPath: "",
                outputDir: dir,
                templateName: "TR0242_\(c.key)",
                layers: [layer],
                timeout: 180.0
            )
            log("导出 \(c.key) success=\(result.success) err=\(result.errorMessage ?? "-")")
            if !result.success {
                log("导出失败，停止")
                exit(4)
            }
            let media = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/Media")) ?? []
            log("导出 \(c.key) Media = \(media.sorted())")
            if media.isEmpty {
                log("导出 Media 为空，换色 PNG 没进包")
                exit(5)
            }
        }

        // ── 4. 顺带打印三种落点的滤镜名，便于报告引用 ──
        log("落点：direct = CIConstantColorGenerator + CIBlendWithAlphaMask；"
            + "invert = 单条 CIColorInvert（不吃目标色）")

        try? meta.joined(separator: "\n").write(toFile: "\(shotsDir)/meta.txt",
                                                atomically: true, encoding: .utf8)
        log("meta 写入 \(shotsDir)/meta.txt")
        log("全部取证完成")
        exit(0)
    }

    // MARK: - 真机窗口截图（screencapture -l，真实窗口像素）

    static func captureWindow(to path: String) -> Bool {
        guard let win = wc.window else { return false }
        try? FileManager.default.removeItem(atPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-l", "\(win.windowNumber)", "-o", "-x", path]
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("screencapture 退出码 \(p.terminationStatus) stderr=\(e)")
            return false
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 4096 else { return false }
        return true
    }

    // MARK: - 生成黑墨 PNG（透明底 + 纯黑字）

    static func makeBlackTextPNG(at path: String, size: CGSize = CGSize(width: 1200, height: 600)) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 300, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ]
        NSAttributedString(string: "换色 024", attributes: attrs)
            .draw(in: NSRect(x: 0, y: 110, width: size.width, height: size.height - 220))

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
