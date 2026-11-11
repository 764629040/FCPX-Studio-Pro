// ═══════════════════════════════════════════════════════════════════════════
// tools/tr024/recolor_evidence.swift
// TR-024：PNG 像素文字换色 —— 真机证据
//
// 这不是生产开关，也不进 App 包：只在本目录编译运行，替手动点击取证。
// 全程抓【真实窗口像素】（screencapture -l <windowID>），不用离屏渲染顶替。
//
// 编译（zsh 用 ${=FILES}，cwd 必须是项目根）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr024/recolor_evidence.swift -o /tmp/tr024_evidence
// 运行（cwd 必须是项目根）：
//   /tmp/tr024_evidence [输出目录]
//   默认输出目录 /tmp/tr024_shots
//
// 产物：
//   01_direct.png / 02_luminance.png / 03_invert.png / 04_hueRotate.png  真实窗口截图
//   /tmp/tr024_export/<mode>/Media/*.png                                 真实导出（走 buildTemplateResult）
// ═══════════════════════════════════════════════════════════════════════════

import AppKit

@main
struct RecolorEvidence {
    static var wc: MainWindowController!
    static var outDir = "/tmp/tr024_shots"
    static let srcPng = "/tmp/tr024_src/black_text.png"
    static let targetHex = "#29D1FF"
    static let exportRoot = "/tmp/tr024_export"

    /// 截图顺序 / 文件名 / 模式
    static let steps: [(key: String, mode: RecolorMode)] = [
        ("01_direct", .direct),
        ("02_luminance", .luminance),
        ("03_invert", .invert),
        ("04_hueRotate", .hueRotate)
    ]

    static func log(_ s: String) {
        print("[TR-024] " + s)
        fflush(stdout)
    }

    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 { outDir = args[1] }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

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
        log("黑字源图: \(srcPng)")

        // 一个真位图层模型，走画布真实的位图渲染分支（kind=fallback_png → drawBitmap）
        let layer = LayerModel(id: 1,
                               name: "TR024黑字",
                               kind: "fallback_png",
                               text: "",
                               fallbackPngPath: srcPng,
                               psdBBox: [0, 0, 1200, 600])
        layer.posX = 0
        layer.posY = 0
        layer.colorOverride = targetHex
        layer.recolorMode = RecolorMode.direct.rawValue

        wc.canvasView.backgroundPreview = nil
        wc.canvasView.layers = [layer]
        wc.canvasView.setResolution(width: 1200, height: 600)   // 内部 fitArtboard
        wc.canvasView.selectedLayerIndex = 0
        // 检查器也挂上同一条数据：截图里能看到「位图换色」组的真值
        wc.inspectorView.layers = [layer]
        wc.inspectorView.selectLayer(at: 0)
        wc.inspectorView.resolutionLabel?.stringValue = "📐 幅面规格 1200×600（TR-024 取证：黑字 PNG 位图层）"
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        log("窗口 windowNumber=\(wc.window?.windowNumber ?? -1) zoom=\(String(format: "%.2f", wc.canvasView.zoomScale))")

        // ── 1. 四张真实窗口截图 ──
        for step in steps {
            layer.recolorMode = step.mode.rawValue
            wc.inspectorView.refreshBitmapRecolorControls()
            wc.canvasView.needsDisplay = true
            wc.window?.contentView?.needsDisplay = true
            wc.window?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))

            let path = "\(outDir)/\(step.key).png"
            let ok = captureWindow(to: path)
            log("截图 \(step.key) mode=\(step.mode.title) -> \(ok ? "OK" : "失败") \(path)")
            if !ok {
                log("窗口截图失败，停止（不可用离屏渲染顶替）")
                exit(3)
            }
        }

        // ── 2. 多色原图提示的独立取证（换色必然把多色压成单色）──
        let multiPng = "/tmp/tr024_src/multicolor.png"
        if makeMultiColorPNG(at: multiPng) {
            layer.fallbackPngPath = multiPng
            layer.recolorMode = RecolorMode.luminance.rawValue
            wc.canvasView.layers = [layer]
            wc.inspectorView.layers = [layer]
            wc.inspectorView.selectLayer(at: 0)
            wc.canvasView.needsDisplay = true
            wc.window?.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            let path = "\(outDir)/05_multicolor_hint.png"
            log("截图 05_multicolor_hint -> \(captureWindow(to: path) ? "OK" : "失败") \(path)")
            log("提示行文案: \(wc.inspectorView.recolorHintText(for: layer).text)")
            layer.fallbackPngPath = srcPng
            wc.canvasView.layers = [layer]
            wc.inspectorView.layers = [layer]
        } else {
            log("多色取证图生成失败，跳过 05")
        }

        // ── 3. 四种模式各走一次真实导出（buildTemplateResult） ──
        for step in steps {
            layer.recolorMode = step.mode.rawValue
            let dir = "\(exportRoot)/\(step.key)"
            try? FileManager.default.removeItem(atPath: dir)
            let result = MotionBuilderSocket.shared.buildTemplateResult(
                psdPath: "",
                outputDir: dir,
                templateName: "TR024_\(step.key)",
                layers: [layer],
                timeout: 180.0
            )
            log("导出 \(step.key) success=\(result.success) err=\(result.errorMessage ?? "-")")
            if !result.success {
                log("导出失败，停止")
                exit(4)
            }
            let media = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/Media")) ?? []
            log("导出 \(step.key) Media = \(media.sorted())")
            if media.isEmpty {
                log("导出 Media 为空，换色 PNG 没进包")
                exit(5)
            }
        }

        // ── 4. 补充取证：带明暗梯度的墨（黑→灰渐变）
        // 纯黑墨在 direct 与 luminance 下必然收敛到同一个值（RGB 里没有梯度可用），
        // 这一组用「黑→灰渐变墨」证明 luminance 真的保住了亮度梯度，direct 则拍平。
        let gradPng = "/tmp/tr024_src/gradient_text.png"
        if makeGradientTextPNG(at: gradPng) {
            layer.fallbackPngPath = gradPng
            layer.colorOverride = targetHex
            wc.canvasView.layers = [layer]
            wc.inspectorView.layers = [layer]
            wc.inspectorView.selectLayer(at: 0)
            for (key, mode) in [("06_direct_gradient", RecolorMode.direct),
                                ("07_luminance_gradient", RecolorMode.luminance)] {
                layer.recolorMode = mode.rawValue
                wc.inspectorView.refreshBitmapRecolorControls()
                wc.canvasView.needsDisplay = true
                wc.window?.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.7))
                let path = "\(outDir)/\(key).png"
                log("截图 \(key) mode=\(mode.title) -> \(captureWindow(to: path) ? "OK" : "失败") \(path)")

                let dir = "\(exportRoot)/\(key)"
                try? FileManager.default.removeItem(atPath: dir)
                let r = MotionBuilderSocket.shared.buildTemplateResult(
                    psdPath: "", outputDir: dir, templateName: "TR024_\(key)",
                    layers: [layer], timeout: 180.0)
                log("导出 \(key) success=\(r.success) err=\(r.errorMessage ?? "-")")
            }
            layer.fallbackPngPath = srcPng
            wc.canvasView.layers = [layer]
            wc.inspectorView.layers = [layer]
        } else {
            log("梯度取证图生成失败，跳过 06/07")
        }

        // ── 5. 打印每个模式的滤镜落点（报告用） ──
        for step in steps {
            log("模式 \(step.mode.title) → RecolorMode.rawValue=\(step.mode.rawValue)")
        }
        log("DONE")
        exit(0)
    }

    /// 多色原图（红/绿/蓝三块高饱和色），用于验证「原图含多色，换色后变单色」提示行。
    static func makeMultiColorPNG(at path: String, size: CGSize = CGSize(width: 1200, height: 600)) -> Bool {
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
        let colors: [NSColor] = [
            NSColor(srgbRed: 0.92, green: 0.16, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.85, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)
        ]
        let w = size.width / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            c.setFill()
            NSRect(x: CGFloat(i) * w, y: 0, width: w, height: size.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 带明暗梯度的墨：字形内从左到右 黑 → 中灰，用来区分「明暗上色」与「直接替换」。
    static func makeGradientTextPNG(at path: String, size: CGSize = CGSize(width: 1200, height: 600)) -> Bool {
        guard let maskRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let maskCtx = NSGraphicsContext(bitmapImageRep: maskRep) else { return false }
        // 1) 白字 mask
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = maskCtx
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(string: "换色 024", attributes: [
            .font: NSFont.systemFont(ofSize: 300, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]).draw(in: NSRect(x: 0, y: 110, width: size.width, height: size.height - 220))
        NSGraphicsContext.restoreGraphicsState()
        guard let maskCG = maskRep.cgImage else { return false }

        // 2) 全画布渐变 + destinationIn 只留字形
        guard let outRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let outCtx = NSGraphicsContext(bitmapImageRep: outRep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = outCtx
        let cg = outCtx.cgContext
        let colors = [NSColor.black.cgColor, NSColor(white: 0.62, alpha: 1.0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                 locations: [0, 1]) {
            cg.drawLinearGradient(grad,
                                  start: CGPoint(x: 0, y: 0),
                                  end: CGPoint(x: size.width, y: 0),
                                  options: [])
        }
        cg.setBlendMode(.destinationIn)
        cg.draw(maskCG, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = outRep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - 真机窗口截图

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
        // 必须真拿到像素：文件存在且非空
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 4096 else { return false }
        return true
    }

    // MARK: - 生成黑字 PNG（透明底 + 纯黑字，和 PSD 文字层拆分产物同构）

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
