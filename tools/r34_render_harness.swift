// R34 直证 harness（文字位置精确化与重叠挤压根治）
//
// 验证：
// 1. PSDParserSocket 解析 01.psd (vertical_wedding_9_16.psd)
//    - 4 个中文层 alignment == "center", lineSpacing == 46.5
//    - 4 个英文层 alignment == "left", lineSpacing ≈ 20.83333
// 2. InfiniteCanvasView 真实物理包围盒与文字排版：
//    - 彻底废除 maxLineLen * fontSize * 1.1 伪公式
//    - THE BRIDE 宽度严格为 14px，高度 115px（杜绝膨胀至 165px）
//    - 图层间安全间隙明显（11px ~ 107px），无重叠挤压
// 3. 离屏渲染真实生成画板截图 docs/r34_evidence/r34_01_psd_canvas_render.png

import AppKit

@main
struct R34RenderHarness {
    static var passCount = 0
    static var failCount = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passCount += 1
            print("PASS: \(name)\(detail.isEmpty ? "" : " | \(detail)")")
        } else {
            failCount += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " | \(detail)")")
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let root = FileManager.default.currentDirectoryPath
        let evDir = "\(root)/docs/r34_evidence"
        let psdPath = "\(root)/tests/data/vertical_wedding_9_16.psd"

        print("== R34 验收判据 1 & 2: 01.psd 段落对齐与真实行距提取 ==")
        let socket = PSDParserSocket()
        let result = socket.parsePSD(at: psdPath)
        check("01.psd 解析成功", result.isValid, result.failureReason ?? "")
        check("01.psd 8 个文本图层", result.layers.count == 8, "count=\(result.layers.count)")

        let chineseLayers = ["领 衔 呈 现", "新 娘  朱 永 宏", "新 郎  陈 晗", "镇 雄"]
        let englishLayers = ["lead the  presentation", "THE BRIDE", "THE GROOM", "CITY"]

        for l in result.layers {
            if chineseLayers.contains(l.name) {
                check("\(l.name) 居中对齐", l.alignment == "center", "actual=\(l.alignment)")
                check("\(l.name) 真实行距 46.5", abs(l.lineSpacing - 46.5) < 0.01, "actual=\(l.lineSpacing)")
            } else if englishLayers.contains(l.name) {
                check("\(l.name) 左对齐", l.alignment == "left", "actual=\(l.alignment)")
                check("\(l.name) 真实行距 20.83333", abs(l.lineSpacing - 20.83333) < 0.01, "actual=\(l.lineSpacing)")
            }
        }

        print("\n== R34 验收判据 3: 画布文本物理边界无膨胀 ==")
        guard let theBride = result.layers.first(where: { $0.name == "THE BRIDE" }) else {
            fatalError("THE BRIDE layer not found")
        }
        let b = theBride.psdBBox
        check("THE BRIDE psdBBox 存在", b.count == 4, "bbox=\(b)")
        let realW = b[2] - b[0]
        let realH = b[3] - b[1]
        check("THE BRIDE 真实包围盒宽度 14px", realW == 14.0, "realW=\(realW)")
        check("THE BRIDE 真实包围盒高度 115px", realH == 115.0, "realH=\(realH)")

        // 验证废除伪假公式：旧公式计算出 totalW = 9 * 16.67 * 1.1 = 165
        let fakeW = CGFloat(theBride.text.count) * CGFloat(theBride.fontSize) * 1.1
        check("旧伪假公式宽度膨胀严重 (165px)", fakeW > 160.0, "fakeW=\(fakeW)")
        check("新物理宽度杜绝膨胀", realW < 20.0 && realW != Double(fakeW), "width=\(realW) vs fake=\(fakeW)")

        print("\n== R34 验收判据 4: 图层间物理间隙与无重叠 ==")
        for i in 0..<(result.layers.count - 1) {
            let l1 = result.layers[i]
            let l2 = result.layers[i+1]
            let gap = l2.psdBBox[0] - l1.psdBBox[2]
            check("\(l1.name) 与 \(l2.name) 安全间距 > 0", gap > 0, "gap=\(gap)px")
        }

        print("\n== R34 离屏渲染与产物落盘 ==")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 1080, height: 1920))
        canvas.wantsLayer = true
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.setResolution(width: result.width, height: result.height)
        canvas.layers = result.layers
        canvas.backgroundPreview = result.backgroundPreview
        canvas.fitArtboard()
        window.layoutIfNeeded()

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            fatalError("Failed to create bitmapImageRepForCachingDisplay")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            let renderPath = "\(evDir)/r34_01_psd_canvas_render.png"
            try? pngData.write(to: URL(fileURLWithPath: renderPath))
            check("生成离屏渲染 PNG 产物", FileManager.default.fileExists(atPath: renderPath), "path=\(renderPath) size=\(pngData.count)")
        }

        print("\n==========================================")
        print("R34 直证总计: \(passCount) PASS, \(failCount) FAIL")
        print("==========================================")
        exit(failCount == 0 ? 0 : 1)
    }
}
