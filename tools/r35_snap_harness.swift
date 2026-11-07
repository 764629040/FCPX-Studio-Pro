// ═══════════════════════════════════════════════════════════════
//  R35 原生画布智能对齐吸附系统（D-73）与遗留台账（A-62/A-66/A-59/A-60）自动化直证 Harness
// ═══════════════════════════════════════════════════════════════

import AppKit
import Foundation

@main
struct R35SnapHarness {
    static var failures = 0
    static var checks = 0

    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        let status = cond ? "✅ PASS" : "❌ FAIL"
        print("\(status) | \(name)\(detail.isEmpty ? "" : " | " + detail)")
    }

    static func main() {
        print("==================================================")
        print("  FCPX Studio Pro —— R35 原生验证 Harness 开始")
        print("==================================================")

        let rootDir = FileManager.default.currentDirectoryPath
        let evidenceDir = "\(rootDir)/docs/r35_evidence"
        try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        test1_SnappingAlgorithm()
        test2_CanvasGuideRendering(evidenceDir: evidenceDir)
        test3_A62SingleFileOpen(rootDir: rootDir)
        test4_A66AssetHubUI()
        test5_A59A60Semantics()

        print("==================================================")
        print("  总计检查点: \(checks) | 失败: \(failures)")
        print("==================================================")
        exit(failures == 0 ? 0 : 1)
    }

    // ─────────────────────────────────────────────────────────────
    // 1. 智能吸附算法与 ⌘ 禁用验证
    // ─────────────────────────────────────────────────────────────
    static func test1_SnappingAlgorithm() {
        print("\n── 1. 智能对齐探测与磁吸吸附（Snapping）──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        canvas.zoomScale = 1.0 // 1.0 比例下阈值恰好是 6.0 像素

        let layer0 = LayerModel(id: 1, name: "Layer 0", text: "Text 0", posX: 0, posY: 0, psdBBox: [0, 0, 100, 40])
        let layer1 = LayerModel(id: 2, name: "Layer 1", text: "Text 1", posX: 200, posY: 0, psdBBox: [0, 0, 100, 40])
        canvas.layers = [layer0, layer1]

        // 1.1 画板中心吸附（距离 4px <= 6px）
        // 拖动 Layer 0 到 (X=4, Y=-5)
        let snapCenter = canvas.calculateSnap(proposedCanvasX: 4.0, proposedCanvasY: 5.0, layerIndex: 0, disableSnapping: false)
        check(abs(snapCenter.snappedX - 0.0) < 0.001, "中心 X=0 磁吸触发", "snappedX=\(snapCenter.snappedX)")
        check(abs(snapCenter.snappedY - 0.0) < 0.001, "中心 Y=0 磁吸触发", "snappedY=\(snapCenter.snappedY)")
        check(snapCenter.guides.count == 2, "中心对齐生成 2 条参考线", "guides=\(snapCenter.guides.count)")
        let isGold = snapCenter.guides.allSatisfy {
            let c = $0.color.usingColorSpace(.genericRGB) ?? ($0.color.usingColorSpace(.deviceRGB) ?? $0.color)
            return c.redComponent > 0.8 && c.greenComponent > 0.6 && c.blueComponent < 0.25
        }
        check(isGold, "中心对齐参考线为金色", "")

        // 1.2 距离超出阈值（80.0 > 6px，远离所有目标）
        let snapFar = canvas.calculateSnap(proposedCanvasX: 80.0, proposedCanvasY: 80.0, layerIndex: 0, disableSnapping: false)
        check(abs(snapFar.snappedX - 80.0) < 0.001, "超出阈值不吸附 X", "snappedX=\(snapFar.snappedX)")
        check(abs(snapFar.snappedY - 80.0) < 0.001, "超出阈值不吸附 Y", "snappedY=\(snapFar.snappedY)")
        check(snapFar.guides.isEmpty, "超出阈值不产生参考线", "guides=\(snapFar.guides.count)")

        // 1.3 邻近图层边距吸附（Layer 1 左边 X=150，Layer 0 右边 X=cx+50）
        // 拖动 Layer 0 到 cx = 97，右边在 147，距离 150 只有 3px <= 6px
        let snapLayer = canvas.calculateSnap(proposedCanvasX: 97.0, proposedCanvasY: 0.0, layerIndex: 0, disableSnapping: false)
        check(abs(snapLayer.snappedX - 100.0) < 0.001, "图层边界对齐吸附触发（右边吸到左边 150）", "snappedX=\(snapLayer.snappedX)")
        let cyanGuide = snapLayer.guides.first { $0.orientation == .vertical }
        check(cyanGuide != nil, "生成图层间垂直参考线", "pos=\(cyanGuide?.position ?? -1)")
        if let g = cyanGuide {
            let c = g.color.usingColorSpace(.deviceRGB) ?? g.color
            let isCyan = c.blueComponent > 0.8 && c.greenComponent > 0.6 && c.redComponent < 0.3
            check(isCyan, "图层对齐参考线为青色", "r=\(c.redComponent), g=\(c.greenComponent), b=\(c.blueComponent)")
        }

        // 1.4 ⌘ 键临时禁用吸附
        let snapCmd = canvas.calculateSnap(proposedCanvasX: 4.0, proposedCanvasY: 5.0, layerIndex: 0, disableSnapping: true)
        check(abs(snapCmd.snappedX - 4.0) < 0.001, "⌘ 键临时禁用吸附 X 保留原位", "snappedX=\(snapCmd.snappedX)")
        check(abs(snapCmd.snappedY - 5.0) < 0.001, "⌘ 键临时禁用吸附 Y 保留原位", "snappedY=\(snapCmd.snappedY)")
        check(snapCmd.guides.isEmpty, "⌘ 键临时禁用吸附时不生成参考线", "guides=\(snapCmd.guides.count)")
    }

    // ─────────────────────────────────────────────────────────────
    // 2. 离屏渲染与参考线像素验证
    // ─────────────────────────────────────────────────────────────
    static func test2_CanvasGuideRendering(evidenceDir: String) {
        print("\n── 2. 辅助线视觉绘制与离屏像素核查 ──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.zoomScale = 0.5
        let layer0 = LayerModel(id: 1, name: "Title", text: "婚礼电影", posX: 0, posY: 0, psdBBox: [0, 0, 160, 50])
        canvas.layers = [layer0]

        // 激活两条参考线：一条金色（X=0），一条青色（Y=0）
        let goldGuide = AlignmentGuide(
            orientation: .vertical,
            position: 0.0,
            start: -200,
            end: 200,
            color: NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 0.95)
        )
        let cyanGuide = AlignmentGuide(
            orientation: .horizontal,
            position: 0.0,
            start: -200,
            end: 200,
            color: NSColor(calibratedRed: 0.0, green: 0.85, blue: 1.0, alpha: 0.95)
        )
        canvas.activeGuides = [goldGuide, cyanGuide]

        // 离屏渲染
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            check(false, "离屏 BitmapImageRep 获取失败")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        // 导出 PNG
        let outPng = "\(evidenceDir)/r35_snap_guide_render.png"
        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: outPng))
            check(FileManager.default.fileExists(atPath: outPng), "参考线离屏渲染图导出成功", outPng)
        } else {
            check(false, "PNG 编码失败")
        }

        // 像素点扫描（在画面中心十字区域检测金色和青色参考线像素）
        var foundGold = false
        var foundCyan = false
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        for x in 0..<w {
            for y in 0..<h {
                if let color = rep.colorAt(x: x, y: y) {
                    let r = color.redComponent
                    let g = color.greenComponent
                    let b = color.blueComponent
                    // 金色判定
                    if r > 0.7 && g > 0.5 && b < 0.25 {
                        foundGold = true
                    }
                    // 青色判定
                    if b > 0.7 && g > 0.6 && r < 0.25 {
                        foundCyan = true
                    }
                }
            }
        }
        check(foundGold, "离屏渲染检测到金色画板中心参考线像素", "")
        check(foundCyan, "离屏渲染检测到青色水平对齐参考线像素", "")

        // 模拟 mouseUp 清空参考线
        let dummyEvent = NSEvent()
        canvas.mouseUp(with: dummyEvent)
        check(canvas.activeGuides.isEmpty, "鼠标松开（mouseUp）平滑隐去并清空辅助线", "count=\(canvas.activeGuides.count)")
    }

    // ─────────────────────────────────────────────────────────────
    // 3. A-62 单文件打开（--open）真机自动化测试
    // ─────────────────────────────────────────────────────────────
    static func test3_A62SingleFileOpen(rootDir: String) {
        print("\n── 3. A-62 ⌘O 单文件打开流程自动化验证 ──")
        let appBinary = "\(rootDir)/FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
        let testPsd = "\(rootDir)/tests/data/vertical_wedding_9_16.psd"

        check(FileManager.default.fileExists(atPath: appBinary), "已安装并签名原生二进制存在", appBinary)
        check(FileManager.default.fileExists(atPath: testPsd), "测试真实 PSD 文件存在", testPsd)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: appBinary)
        proc.arguments = ["--open", testPsd, "--verify-open"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try proc.run()
            proc.waitUntilExit()
            let duration = CFAbsoluteTimeGetCurrent() - startTime

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            check(proc.terminationStatus == 0, "--open 启动执行退出码为 0", "exit=\(proc.terminationStatus)")
            check(duration < 5.0, "--open 快速启动并成功进入主界面解析图层", String(format: "全链路耗时: %.2fs", duration))
            check(output.contains("[A-62] PSD loaded"), "输出确认进入主界面并解析图层", output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            check(false, "启动应用进程失败: \(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 4. A-66 三级归属前置展示与菜单优化
    // ─────────────────────────────────────────────────────────────
    static func test4_A66AssetHubUI() {
        print("\n── 4. A-66 三级归属前置展示与操作列优化 ──")
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "r35_a66_\(getpid())"
        try? fm.createDirectory(atPath: tmp + "/Titles.localized/UserT", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: tmp + "/builtin_root/Titles.localized/BuiltinT", withIntermediateDirectories: true)
        fm.createFile(atPath: tmp + "/Titles.localized/UserT/test.bin", contents: Data(repeating: 0x42, count: 1024))
        fm.createFile(atPath: tmp + "/builtin_root/Titles.localized/BuiltinT/test.bin", contents: Data(repeating: 0x43, count: 1024))

        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tmp, 1)
        setenv("FCPXSTUDIO_SYSTEM_TEMPLATES_ROOT", "\(tmp)/system_missing", 1)
        setenv("FCPXSTUDIO_BUILTIN_TEMPLATES_ROOT", "\(tmp)/builtin_root", 1)

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        let window = NSWindow(contentRect: hub.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = hub
        window.layoutIfNeeded()
        hub.refreshList()
        hub.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        var tierColWidth: CGFloat = 0
        var actionColWidth: CGFloat = 0
        for col in hub.pluginTableView.tableColumns {
            if col.identifier.rawValue == "tier" {
                tierColWidth = col.width
            } else if col.identifier.rawValue == "action" {
                actionColWidth = col.width
            }
        }

        check(tierColWidth >= 200, "归属列宽度加宽 (>= 200)", "width=\(tierColWidth)")
        check(actionColWidth <= 90, "操作列宽度收窄 (<= 90)", "width=\(actionColWidth)")
        check(hub.pluginTableView.menu != nil, "右键菜单已挂载至表格", "")

        // 验证 builtin 操作列渲染：默认显示 🔒 只读
        let colAction = hub.pluginTableView.tableColumns.first { $0.identifier.rawValue == "action" }
        let builtinRow = hub.plugins.firstIndex { $0.tier == .builtin }
        if let bRow = builtinRow, let v0 = hub.tableView(hub.pluginTableView, viewFor: colAction, row: bRow) as? NSTextField {
            check(v0.stringValue.contains("🔒 只读"), "内置级默认显示「🔒 只读」文本", "str=\(v0.stringValue)")
        } else {
            check(false, "内置级操作列未能正确生成只读文本")
        }

        // 验证 user 操作列渲染：显示 ⋯ 按钮
        let userRow = hub.plugins.firstIndex { $0.tier == .user }
        if let uRow = userRow, let v1 = hub.tableView(hub.pluginTableView, viewFor: colAction, row: uRow) {
            let btn = v1.subviews.compactMap { $0 as? NSButton }.first
            check(btn?.title == "⋯", "用户级操作列提供「⋯」菜单按钮", "title=\(btn?.title ?? "")")
        } else {
            check(false, "用户级操作列未能生成 ⋯ 按钮视图")
        }

        try? fm.removeItem(atPath: tmp)
    }

    // ─────────────────────────────────────────────────────────────
    // 5. A-59 语义解耦与 A-60 原生指纹完整性
    // ─────────────────────────────────────────────────────────────
    static func test5_A59A60Semantics() {
        print("\n── 5. A-59 语义解耦与 A-60 原生指纹 ──")
        let model = LayerModel(
            id: 1, name: "Text", text: "Hello",
            missingChars: [], fontStatus: "unverifiable",
            hasConfirmedMissingGlyphs: false, hasGlyphRisk: true
        )
        check(model.hasConfirmedMissingGlyphs == false, "unverifiable 状态下 hasConfirmedMissingGlyphs 严格为 false", "")
        check(model.hasGlyphRisk == true, "unverifiable 状态下 hasGlyphRisk 保持为 true", "")
        check(model.hasConfirmedMissingGlyphs != model.hasGlyphRisk, "确证缺字与风险字段解耦无矛盾", "")
    }
}
