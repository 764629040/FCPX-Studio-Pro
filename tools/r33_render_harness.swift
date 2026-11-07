// R33 直证 harness（A-68 / A-69 / A-70）
//
// 目的：不靠“看截图猜”，用产品源码本身的解析器 + 画布离屏渲染，
// 对每个 PSD 输出「非画板底色像素占比 / 亮度标准差」，证明位图稿
// 真的画出了画面，而不是全黑画板冒充成功。
//
// 编译：见 docs/r33_evidence/run_r33_harness.sh
// 运行：./docs/r33_evidence/r33_render_harness

import AppKit

@main
struct R33RenderHarness {
    static var pass = 0
    static var fail = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { pass += 1; print("PASS \(name)\(detail.isEmpty ? "" : " | \(detail)")") }
        else { fail += 1; print("FAIL \(name)\(detail.isEmpty ? "" : " | \(detail)")") }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let root = FileManager.default.currentDirectoryPath
        let ev = "\(root)/docs/r33_evidence"
        let socket = PSDParserSocket()

        print("== A-69 诊断判定（纯函数，先证规则本身）==")
        // 丢 1 层：绝不允许绿色
        let lost = ParseDiagnosticsState.resolve(
            isValid: true, failureReason: nil, warnings: [],
            width: 2848, height: 1600, aspectRatio: "16:9", layerCount: 1,
            counts: PSDLayerCounts(input: 13, preserved: 0, degraded: 1, ignored: 12,
                                   hidden: 11, background: 1, preview: 0,
                                   visibleEmitted: 1, conservationHolds: true,
                                   countSumHolds: true,
                                   ignoredSummary: "已忽略 12 层（11 个隐藏 + 1 个底板）"))
        check("A69 丢层不得绿色", lost.tone == .orange, "tone=\(lost.tone.rawValue)")
        check("A69 丢层文案含忽略数", lost.text.contains("12") && lost.text.contains("隐藏"),
              lost.text.replacingOccurrences(of: "\n", with: " ⏎ "))
        check("A69 丢层不再宣称完整提取", !lost.text.contains("完整提取"))

        let clean = ParseDiagnosticsState.resolve(
            isValid: true, failureReason: nil, warnings: [],
            width: 1920, height: 1080, aspectRatio: "16:9", layerCount: 4,
            counts: PSDLayerCounts(input: 4, preserved: 4, degraded: 0, ignored: 0,
                                   preview: 0, visibleEmitted: 4,
                                   conservationHolds: true, countSumHolds: true))
        check("A69 真干净才绿色", clean.tone == .green, "tone=\(clean.tone.rawValue)")

        let broken = ParseDiagnosticsState.resolve(
            isValid: true, failureReason: nil, warnings: [],
            width: 1920, height: 1080, aspectRatio: "16:9", layerCount: 2,
            counts: PSDLayerCounts(input: 5, preserved: 2, degraded: 0, ignored: 0,
                                   preview: 0, visibleEmitted: 2,
                                   conservationHolds: false, countSumHolds: false))
        check("A69 守恒破坏判红", broken.tone == .red, "tone=\(broken.tone.rawValue)")

        let noSummary = ParseDiagnosticsState.resolve(
            isValid: true, failureReason: nil, warnings: [],
            width: 1920, height: 1080, aspectRatio: "16:9", layerCount: 2,
            counts: PSDLayerCounts(summaryPresent: false))
        check("A69 无 summary 不得绿色", noSummary.tone == .orange, "tone=\(noSummary.tone.rawValue)")

        print("\n== A-68/A-69/A-70 主样本（镇雄结构等价）==")
        let zx = "\(ev)/zhenxiong_equivalent.psd"
        let r = socket.parsePSD(at: zx)
        check("主样本 解析成功", r.isValid, r.failureReason ?? "")
        check("主样本 画幅 2848×1600", Int(r.width) == 2848 && Int(r.height) == 1600,
              "\(Int(r.width))×\(Int(r.height))")
        check("A70 输入层数 13", r.counts.input == 13, "input=\(r.counts.input)")
        check("A70 不再静默丢隐藏层", r.counts.hidden == 11, "hidden=\(r.counts.hidden)")
        check("A70 底板单独计数", r.counts.background == 1, "bg=\(r.counts.background)")
        check("A70 忽略汇总可读", r.counts.ignoredSummary.contains("11 个隐藏")
              && r.counts.ignoredSummary.contains("1 个底板"), r.counts.ignoredSummary)
        check("A69 层数守恒", r.counts.conservationHolds && r.counts.countSumHolds,
              "cons=\(r.counts.conservationHolds) sum=\(r.counts.countSumHolds)")
        check("A69 忽略 12 层", r.counts.ignored == 12, "ignored=\(r.counts.ignored)")
        check("A68 位图层带贴图", r.layers.count == 1
              && r.layers[0].name == "镇雄夜色"
              && FileManager.default.fileExists(atPath: r.layers[0].fallbackPngPath ?? ""),
              "layers=\(r.layers.map { $0.name })")
        let bg = r.backgroundPreview
        check("A68 底板预览存在", bg != nil && FileManager.default.fileExists(atPath: bg?.fallbackPngPath ?? "")
              && bg?.psdBBox == [0, 0, 2848, 1600], "bbox=\(bg?.psdBBox ?? [])")

        let zxState = ParseDiagnosticsState.resolve(
            isValid: r.isValid, failureReason: r.failureReason, warnings: r.warnings,
            width: r.width, height: r.height, aspectRatio: r.aspectRatio,
            layerCount: r.layers.count, counts: r.counts)
        check("A69 主样本诊断=橙色", zxState.tone == .orange, "tone=\(zxState.tone.rawValue)")
        check("A69 主样本不显示绿色完整提取", !zxState.text.contains("完整提取"),
              zxState.text.replacingOccurrences(of: "\n", with: " ⏎ "))

        // ── 离屏渲染：同一画布，旧行为（无底图无位图）vs 新行为 ──
        let oldMetric = render(layers: [], background: nil, width: r.width, height: r.height)
        let newMetric = render(layers: r.layers, background: bg, width: r.width, height: r.height)
        print(String(format: "METRIC old_nonbg=%.4f old_stddev=%.1f new_nonbg=%.4f new_stddev=%.1f",
                     oldMetric.nonBg, oldMetric.stddev, newMetric.nonBg, newMetric.stddev))
        check("A68 旧路径画布接近空白", oldMetric.nonBg < 0.10,
              String(format: "nonBg=%.4f", oldMetric.nonBg))
        check("A68 新路径画布真实出画面", newMetric.nonBg > 0.50,
              String(format: "nonBg=%.4f stddev=%.1f", newMetric.nonBg, newMetric.stddev))
        save(layers: r.layers, background: bg, width: r.width, height: r.height,
             to: "\(ev)/a68_zhenxiong_render.png")

        print("\n== A-70 显示隐藏图层开关（include_hidden）==")
        let rh = socket.parsePSD(at: zx, includeHidden: true)
        check("A70 include_hidden 解析成功", rh.isValid, rh.failureReason ?? "")
        check("A70 预览层 11 个", rh.counts.preview == 11, "preview=\(rh.counts.preview)")
        check("A70 列表 12 层（1 可见 + 11 预览）", rh.layers.count == 12, "count=\(rh.layers.count)")
        check("A70 预览层默认不可见", rh.layers.filter { !$0.visible }.count == 11,
              "hiddenInList=\(rh.layers.filter { !$0.visible }.count)")
        check("A70 预览层都有贴图", rh.layers.filter { !$0.visible }
              .allSatisfy { FileManager.default.fileExists(atPath: $0.fallbackPngPath ?? "") })
        check("A70 开关不改变转换口径", rh.counts.ignored == 12 && rh.counts.preview == 11,
              "ignored=\(rh.counts.ignored) preview=\(rh.counts.preview)")
        check("A70 守恒仍成立", rh.counts.conservationHolds && rh.counts.countSumHolds)

        print("\n== 判据 7：3 个从未测过的 PSD ==")
        for i in 1...3 {
            let p = "\(ev)/unseen_random_\(i).psd"
            let u = socket.parsePSD(at: p)
            let m = render(layers: u.layers, background: u.backgroundPreview,
                           width: u.width, height: u.height)
            print(String(format: "UNSEEN %d canvas=%dx%d layers=%d ignored=%d nonbg=%.4f stddev=%.1f",
                         i, Int(u.width), Int(u.height), u.layers.count, u.counts.ignored,
                         m.nonBg, m.stddev))
            check("判据7 样本\(i) 解析成功", u.isValid, u.failureReason ?? "")
            check("判据7 样本\(i) 底板贴图存在",
                  FileManager.default.fileExists(atPath: u.backgroundPreview?.fallbackPngPath ?? ""))
            check("判据7 样本\(i) 画面可见", m.nonBg > 0.30 && m.stddev > 15,
                  String(format: "nonBg=%.4f stddev=%.1f（夜景照片大片接近底色，用双指标）", m.nonBg, m.stddev))
            let st = ParseDiagnosticsState.resolve(
                isValid: u.isValid, failureReason: u.failureReason, warnings: u.warnings,
                width: u.width, height: u.height, aspectRatio: u.aspectRatio,
                layerCount: u.layers.count, counts: u.counts)
            check("判据7 样本\(i) 有丢层则不得绿色", u.counts.ignored == 0 || st.tone != .green,
                  "tone=\(st.tone.rawValue)")
            save(layers: u.layers, background: u.backgroundPreview,
                 width: u.width, height: u.height, to: "\(ev)/a68_unseen_\(i)_render.png")
        }

        print("\n== 回归：纯文字稿不能被位图层改动弄坏 ==")
        let text = socket.parsePSD(at: "\(root)/tests/data/four_state.psd")
        check("文字稿 解析成功", text.isValid, text.failureReason ?? "")
        check("文字稿 8 个矢量层", text.layers.count == 8 && text.layers.allSatisfy { $0.kind == "type" },
              "count=\(text.layers.count) kinds=\(Set(text.layers.map { $0.kind }))")
        let tm = render(layers: text.layers, background: text.backgroundPreview,
                        width: text.width, height: text.height)
        check("文字稿 渲染非空", tm.nonBg > 0.01, String(format: "nonBg=%.4f", tm.nonBg))
        save(layers: text.layers, background: text.backgroundPreview,
             width: text.width, height: text.height, to: "\(ev)/a68_four_state_render.png")

        let complex = socket.parsePSD(at: "\(root)/tests/data/complex_layers.psd")
        check("混合稿 解析成功", complex.isValid, complex.failureReason ?? "")
        check("混合稿 仍有位图贴图层",
              complex.layers.contains { $0.isBitmapLayer && FileManager.default.fileExists(atPath: $0.fallbackPngPath ?? "") },
              "kinds=\(Set(complex.layers.map { $0.kind }))")

        print("\nRESULT pass=\(pass) fail=\(fail)")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: – 离屏渲染与像素统计

    struct Metric { let nonBg: Double; let stddev: Double }

    static func render(layers: [LayerModel], background: LayerModel?,
                       width: CGFloat, height: CGFloat) -> Metric {
        let view = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        view.wantsLayer = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.setResolution(width: width, height: height)
        view.layers = layers
        view.backgroundPreview = background
        view.fitArtboard()
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return Metric(nonBg: -1, stddev: -1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return measure(rep)
    }

    static func measure(_ rep: NSBitmapImageRep) -> Metric {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else {
            return Metric(nonBg: -1, stddev: -1)
        }
        let bpp = rep.bitsPerPixel / 8
        let rowBytes = rep.bytesPerRow
        // 画板底色 0.09/0.10/0.12 → 约 23/26/31；点阵与安全框占比很小。
        var nonBg = 0, total = 0
        var sum = 0.0, sumSq = 0.0
        for y in stride(from: 0, to: h, by: 1) {
            let row = data + y * rowBytes
            for x in stride(from: 0, to: w, by: 1) {
                let p = row + x * bpp
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                if abs(r - 23) > 16 || abs(g - 26) > 16 || abs(b - 31) > 16 { nonBg += 1 }
                let lum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                sum += lum; sumSq += lum * lum
                total += 1
            }
        }
        guard total > 0 else { return Metric(nonBg: -1, stddev: -1) }
        let mean = sum / Double(total)
        let variance = max(0, sumSq / Double(total) - mean * mean)
        return Metric(nonBg: Double(nonBg) / Double(total), stddev: variance.squareRoot())
    }

    static func save(layers: [LayerModel], background: LayerModel?,
                     width: CGFloat, height: CGFloat, to path: String) {
        let view = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        view.wantsLayer = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.setResolution(width: width, height: height)
        view.layers = layers
        view.backgroundPreview = background
        view.fitArtboard()
        window.layoutIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            FileManager.default.createFile(atPath: path, contents: png)
            print("WROTE \(path) bytes=\(png.count)")
        }
    }
}
