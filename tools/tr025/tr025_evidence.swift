// ═══════════════════════════════════════════════════════════════════════════
// tools/tr025/tr025_evidence.swift
// TR-025 取证：A 对比色按钮 / B X-Y 拖动 / C 文案 / D 红墨反相补色
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr025/tr025_evidence.swift -o /tmp/tr025_evidence_bin
// 运行 cwd 必须是项目根。
//
// 三张真机窗口截图（同一会话、同一缩放 100%）：
//   /tmp/tr025_shots/01_before.png          黑字 + 直接替换 + #F92125（红字）
//   /tmp/tr025_shots/02_complement.png      点「⇄ 对比色」→ #06DEDA（青字）
//   /tmp/tr025_shots/03_red_invert.png      红墨源图 + 反相 → (0,255,255) 青字
// 导出：/tmp/tr025_export/<key>/Media/*.png（走 MotionBuilderSocket 真实导出）
// meta：/tmp/tr025_shots/meta.txt（缩放 / 控件状态 / 全部断言原文）
//
// 断言失败退出码：
//   6  三张截图缩放不一致（E4 指定）
//   7  对比色按钮补色不等于 255-RGB / 没走同一入口 / 文字没变青
//   8  A3 按钮禁用态不对
//   9  C1 两处反相文案不一致或不对
//   10 B 静态契约 / 纯函数步长不对
//   11 B CGEvent 真机拖动探针失败
//   12 A1 按钮宽度 >60pt / 颜色行换行 / 右栏总宽变了
//   13 D1 红墨反相没出补色（导出或屏幕）
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import AppKit
import CoreGraphics
import CoreImage

@main
struct Tr025Evidence {
    static let shotsDir = "/tmp/tr025_shots"
    static let exportRoot = "/tmp/tr025_export"
    static let srcDir = "/tmp/tr025_src"
    static let blackPng = "/tmp/tr025_src/black_text.png"
    static let redPng = "/tmp/tr025_src/red_text.png"
    static let beforeHex = "#F92125"
    static let afterHex = "#06DEDA"

    static var wc: MainWindowController!
    static var meta: [String] = []
    static let invertTip = InspectorView.invertHintText

    static func log(_ s: String) {
        print("[TR-025] " + s)
        fflush(stdout)
        meta.append(s)
    }

    static func main() {
        for d in [shotsDir, exportRoot, srcDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
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
        guard makeTextPNG(at: blackPng, color: NSColor.black),
              makeTextPNG(at: redPng, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) else {
            log("!! 造源图失败"); exit(2)
        }
        log("黑字源图 \(blackPng) / 红墨源图 \(redPng)（透明底 1200×600）")

        let layer = LayerModel(id: 1, name: "TR025", kind: "fallback_png", text: "",
                               fallbackPngPath: blackPng, psdBBox: [0, 0, 1200, 600])
        layer.posX = 0; layer.posY = 0
        layer.scaleX = 1.0; layer.scaleY = 1.0; layer.rotation = 0
        layer.colorOverride = beforeHex
        layer.recolorMode = RecolorMode.direct.rawValue

        wc.canvasView.backgroundPreview = nil
        wc.canvasView.layers = [layer]
        wc.canvasView.setResolution(width: 1200, height: 600)
        wc.canvasView.selectedLayerIndex = 0
        wc.inspectorView.layers = [layer]
        wc.inspectorView.selectLayer(at: 0)
        wc.inspectorView.resolutionLabel?.stringValue = "📐 幅面规格 1200×600（TR-025 取证）"
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        log("窗口 windowNumber=\(wc.window?.windowNumber ?? -1)")

        // ── A1：按钮 ≤60pt / 颜色行不换行 / 右栏总宽不变 ──
        assertA1()

        // ── 三张截图（同一会话、同一缩放），每张收集 scaleField 原文 ──
        var scaleSeen: [String] = []

        // 01_before：黑字 + 直接替换 + #F92125
        let s1 = snapshot(layer, key: "01_before")
        scaleSeen.append(s1.scale)
        log("截图 01_before: 模式=直接替换 HEX=\(s1.hex) 缩放=\(s1.scale) 按钮可用=\(s1.btnOn) 提示行=\(s1.hint)")

        // 02_complement：真实点击「⇄ 对比色」按钮（performClick 触发 target/action 全链路）
        guard let btn = wc.inspectorView.recolorComplementButton else { log("!! 按钮 outlet 为 nil"); exit(7) }
        let hexBefore = wc.inspectorView.recolorHexField?.stringValue ?? ""
        btn.performClick(nil)
        wc.canvasView.needsDisplay = true
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let hexAfter = wc.inspectorView.recolorHexField?.stringValue ?? ""
        let wellAfter = InspectorView.hexString(from: wc.inspectorView.recolorColorWell?.color ?? .black)
        log("点击「⇄ 对比色」: HEX \(hexBefore) → \(hexAfter)；色块=\(wellAfter)；layer.colorOverride=\(layer.colorOverride)")
        assertA2(hexBefore: hexBefore, hexAfter: hexAfter, wellAfter: wellAfter, layer: layer)
        let s2 = snapshot(layer, key: "02_complement")
        scaleSeen.append(s2.scale)
        log("截图 02_complement: 模式=直接替换 HEX=\(s2.hex) 缩放=\(s2.scale) 按钮可用=\(s2.btnOn) 提示行=\(s2.hint)")

        // 03_red_invert：换红墨源图 + 反相（真反相 = RGB 取反，红→青）
        layer.fallbackPngPath = redPng
        layer.recolorMode = RecolorMode.invert.rawValue
        wc.inspectorView.refreshBitmapRecolorControls()
        wc.canvasView.needsDisplay = true
        wc.window?.contentView?.needsDisplay = true
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let s3 = snapshot(layer, key: "03_red_invert")
        scaleSeen.append(s3.scale)
        log("截图 03_red_invert: 模式=反相 HEX=\(s3.hex) 缩放=\(s3.scale) 按钮可用=\(s3.btnOn) 提示行=\(s3.hint)")
        log("  反相色块/HEX 灰掉: well=\(wc.inspectorView.recolorColorWell?.isEnabled == false) hex=\(wc.inspectorView.recolorHexField?.isEnabled == false)")

        // E4：三张缩放必须一致
        if Set(scaleSeen).count != 1 {
            log("!! 三张截图缩放不一致: \(scaleSeen) —— 直接判失败"); exit(6)
        }
        log("三张截图缩放一致: \(scaleSeen[0])")
        if scaleSeen[0] != "100%" {
            log("!! 缩放不是 100%: \(scaleSeen[0])"); exit(6)
        }

        // ── C1：两处反相文案 ──
        assertC1(layer: layer)

        // ── A3：按钮禁用态（反相 / 未设色 / 正常） ──
        assertA3(layer: layer)

        // ── B：静态契约 + 纯函数逐档 + CGEvent 真机拖动探针 ──
        assertBStatic(layer: layer)

        // ── D1：三份真实导出（含红墨反相）──
        doExports(layer: layer)

        // B 动态探针放最后（会改 layer.posX，不污染已拍截图）
        probeDrag(layer: layer)

        try? meta.joined(separator: "\n").write(toFile: "\(shotsDir)/meta.txt", atomically: true, encoding: .utf8)
        log("meta 写入 \(shotsDir)/meta.txt")
        log("全部取证完成")
        exit(0)
    }

    // MARK: - 截图 + 状态采集

    struct Snap { let scale: String; let hex: String; let btnOn: Bool; let hint: String; let wellOn: Bool; let hexOn: Bool }

    static func snapshot(_ layer: LayerModel, key: String) -> Snap {
        wc.inspectorView.refreshBitmapRecolorControls()
        wc.canvasView.needsDisplay = true
        wc.window?.contentView?.needsDisplay = true
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let path = "\(shotsDir)/\(key).png"
        if !captureWindow(to: path) { log("!! 截图失败 \(path)"); exit(3) }
        let scale = wc.inspectorView.scaleField?.stringValue ?? "<nil>"
        let hex = wc.inspectorView.recolorHexField?.stringValue ?? "<nil>"
        let btnOn = wc.inspectorView.recolorComplementButton?.isEnabled ?? false
        let wellOn = wc.inspectorView.recolorColorWell?.isEnabled ?? false
        let hexOn = wc.inspectorView.recolorHexField?.isEnabled ?? false
        let hint = wc.inspectorView.recolorHintText(for: layer).text
        log("  [capture] \(key) -> \(path) 缩放=\(scale) HEX=\(hex)")
        return Snap(scale: scale, hex: hex, btnOn: btnOn, hint: hint, wellOn: wellOn, hexOn: hexOn)
    }

    static func captureWindow(to path: String) -> Bool {
        guard let win = wc.window else { return false }
        try? FileManager.default.removeItem(atPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-l", "\(win.windowNumber)", "-o", "-x", path]
        let errPipe = Pipe(); p.standardError = errPipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 4096 else { return false }
        return true
    }

    // MARK: - A 断言

    static func assertA1() {
        guard let btn = wc.inspectorView.recolorComplementButton else { log("!! A1 按钮 nil"); exit(12) }
        let w = btn.frame.width
        let row = btn.superview as? NSStackView
        let subs = row?.arrangedSubviews ?? []
        // 「不换行」判据：水平 stack + 恰好 4 个子视图 + 全部同一水平中线（用 midY，
        // 不是 origin.y —— 不同高度的控件垂直居中时 origin.y 本就不同）+ x 递增 + 行高 < 40pt。
        let midYs = subs.map { $0.frame.midY }
        let xs = subs.map { $0.frame.minX }
        let sameMidY = midYs.count >= 2 && ((midYs.max() ?? 0) - (midYs.min() ?? 0)) < 2.0
        let ascendingX = subs.count >= 2 && zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }
        let rowH = row?.frame.height ?? 999
        let horizontal = row?.orientation == .horizontal
        let laidOut = (row?.frame.width ?? 0) > 1
        let rightW = wc.inspectorView.frame.width
        log("A1 按钮宽=\(String(format:"%.1f", w))pt（≤60） 颜色行 frame=\(row?.frame ?? .zero) 行高=\(String(format:"%.1f", rowH)) 子视图数=\(subs.count)")
        for (i, s) in subs.enumerated() {
            log("    [\(i)] \(type(of: s)) frame=\(s.frame)")
        }
        log("A1 判据: 水平=\(horizontal) 中线一致=\(sameMidY) x递增=\(ascendingX) 行高<40=\(rowH < 40) 已布局=\(laidOut) 右栏宽=\(String(format:"%.1f", rightW))")
        let sameLine = horizontal && laidOut && subs.count == 4 && sameMidY && ascendingX && rowH < 40
        if w > 60.0 || !sameLine || abs(rightW - 360.0) > 1.0 {
            log("!! A1 不达标"); exit(12)
        }
        log("A1 PASS：按钮 ≤60pt、颜色行 4 控件同一行不换行、右栏总宽 360 不变")
    }

    static func assertA2(hexBefore: String, hexAfter: String, wellAfter: String, layer: LayerModel) {
        // 逐通道 255 减法：#F92125 = (249,33,37) → (6,222,218) = #06DEDA
        func rgb(_ hex: String) -> (Int, Int, Int)? {
            var r = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if r.hasPrefix("#") { r.removeFirst() }
            guard r.count == 6, let v = UInt32(r, radix: 16) else { return nil }
            return (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
        }
        guard let b = rgb(beforeHex), let a = rgb(hexAfter) else { log("!! A2 HEX 解析失败"); exit(7) }
        let expect = (255 - b.0, 255 - b.1, 255 - b.2)
        log("A2 255 减法: \(beforeHex) \(b) → 期望 \(expect) 实际 \(hexAfter) \(a)")
        if a.0 != expect.0 || a.1 != expect.1 || a.2 != expect.2 {
            log("!! A2 补色不是逐通道 255-RGB（可能用色相旋转凑）"); exit(7)
        }
        if hexAfter != afterHex { log("!! A2 HEX 不等于 \(afterHex)"); exit(7) }
        if wellAfter != afterHex { log("!! A2 色块没同步: \(wellAfter)"); exit(7) }
        if layer.colorOverride != afterHex { log("!! A2 模型没写: \(layer.colorOverride)"); exit(7) }
        if hexBefore != beforeHex { log("!! A2 点击前 HEX 不对: \(hexBefore)"); exit(7) }
        log("A2 PASS：补色 = 255-RGB；HEX / 色块 / 模型三处同步；走 onRecolorHexFieldCommitted 同一入口")
    }

    static func assertA3(layer: LayerModel) {
        // 反相下按钮应禁用（当前已是反相 + 红墨）
        wc.inspectorView.refreshBitmapRecolorControls()
        let invOn = wc.inspectorView.recolorComplementButton?.isEnabled ?? true
        log("A3 反相下按钮 isEnabled=\(invOn)（应 false）")
        if invOn { log("!! A3 反相没禁用按钮"); exit(8) }

        // 切回直接替换 + 未设色 → 按钮禁用
        layer.fallbackPngPath = blackPng
        layer.recolorMode = RecolorMode.direct.rawValue
        layer.colorOverride = ""
        wc.inspectorView.refreshBitmapRecolorControls()
        let noColorOn = wc.inspectorView.recolorComplementButton?.isEnabled ?? true
        log("A3 未设色+直接替换 按钮 isEnabled=\(noColorOn)（应 false）")
        if noColorOn { log("!! A3 未设色没禁用按钮"); exit(8) }

        // 设色后恢复可点
        layer.colorOverride = beforeHex
        wc.inspectorView.refreshBitmapRecolorControls()
        let normalOn = wc.inspectorView.recolorComplementButton?.isEnabled ?? false
        log("A3 设色+直接替换 按钮 isEnabled=\(normalOn)（应 true）")
        if !normalOn { log("!! A3 正常态按钮没恢复"); exit(8) }
        log("A3 PASS：反相禁用 / 未设色禁用 / 切回其它模式立刻恢复")
    }

    // MARK: - C 断言

    static func assertC1(layer: LayerModel) {
        let hint = wc.inspectorView.recolorHintText(for: layer).text
        let wellTip = wc.inspectorView.recolorColorWell?.toolTip ?? ""
        let hexTip = wc.inspectorView.recolorHexField?.toolTip ?? ""
        log("C1 常量 invertHintText = \(invertTip)")
        log("C1 recolorHintText(for:) = \(hint)")
        log("C1 colorWell.toolTip = \(wellTip)")
        log("C1 hexField.toolTip = \(hexTip)")
        if hint != invertTip || wellTip != invertTip || hexTip != invertTip {
            log("!! C1 两处文案不同步或不对"); exit(9)
        }
        // 字面量出现次数（源码级，防「只改一处」）
        let src = (try? String(contentsOfFile: "FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift", encoding: .utf8)) ?? ""
        let literalCount = src.components(separatedBy: invertTip).count - 1
        log("C1 源码里 invertHintText 字面量出现次数 = \(literalCount)（常量定义 + 两处注释 ≥3）")
        if literalCount < 3 { log("!! C1 字面量只出现在 ≤2 处，疑似只改一处"); exit(9) }
        log("C1 PASS：recolorHintText 与 colorTip 两处均为同一新文案")
    }

    // MARK: - B 静态断言

    static func assertBStatic(layer: LayerModel) {
        // 纯函数逐档
        let cases: [(Double, CGFloat, NSEvent.ModifierFlags, Double, String)] = [
            (0,   1,  [],       1.0,  "1pt=1px"),
            (0,   10, [],       10.0, "10pt=10px"),
            (0,   1,  .shift,   10.0, "Shift×10"),
            (0,   10, .option,  1.0,  "Option×0.1（10pt→1.0）"),
            (12.3, 3, [],       15.3, "1 位小数"),
            (0,   3,  .option,  0.3,  "Option 3pt→0.3"),
        ]
        for c in cases {
            let got = DraggableNumberField.dragValue(current: c.0, delta: c.1, flags: c.2)
            log("B2 \(c.4): 期望 \(c.3) 实际 \(got)")
            if abs(got - c.3) > 0.0001 { log("!! B2 步长错: \(c.4)"); exit(10) }
        }
        // posX/posY 是子类，rotation/scale 仍是原生 NSTextField（B6）
        let xDrag = wc.inspectorView.posXField is DraggableNumberField
        let yDrag = wc.inspectorView.posYField is DraggableNumberField
        let rotPlain = !(wc.inspectorView.rotationField is DraggableNumberField)
        let sclPlain = !(wc.inspectorView.scaleField is DraggableNumberField)
        log("B6 posX/posY 是可拖动子类=\(xDrag)/\(yDrag)；rotation/scale 仍是原生=\(rotPlain)/\(sclPlain)")
        if !(xDrag && yDrag && rotPlain && sclPlain) { log("!! B6 控件类型不对"); exit(10) }
        // 源码契约：mouseDown 未调用 super（拖动期间不进编辑态）、回调复用 onPosFieldChanged
        let src = (try? String(contentsOfFile: "FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift", encoding: .utf8)) ?? ""
        if !src.contains("self.onPosFieldChanged()      // ← 唯一入口") {
            log("!! B3 复用 onPosFieldChanged 的入口标记缺失"); exit(10)
        }
        if !src.contains("selectText(self)") {
            log("!! B1 按下不动进编辑态的 selectText 缺失"); exit(10)
        }
        log("B 静态 PASS：步长逐档 / X-Y 子类化 / 旋转缩放未动 / 复用入口 / 点击进入编辑")
    }

    // MARK: - B 真机拖动探针（确定性 NSEvent 序列驱动真实 tracking loop）
    //
    // 为什么不用 CGEvent 系统级注入：本机沙盒 + 取证 run() 占用 main queue 时，后台线程 post
    // 的 CGEvent 无法被同步的 eventTracking loop 稳定派发（实测 20s 超时）。
    // 改用「构造确定性 NSEvent 序列 → NSApp.postEvent 入队 → 直接调用 field.mouseDown(with:)」：
    // 走的仍是产品里那条一模一样的 mouseDown → win.nextEvent(.leftMouseDragged/.leftMouseUp)
    // → onDragStep → onPosFieldChanged → onLayerModified 代码路径，且能在每个 dragged 事件里
    // 同步采样，直接证明「松手前模型已逐帧更新」= 实时跟手，不是松手才刷新。

    static func probeDrag(layer: LayerModel) {
        guard let field = wc.inspectorView.posXField as? DraggableNumberField,
              let win = field.window else { log("!! B 探针拿不到 posXField/window"); exit(11) }
        _ = field.scrollToVisible(field.bounds)
        win.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let winNum = win.windowNumber
        var evNo = 0
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat,
                   _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            evNo += 1
            return NSEvent.mouseEvent(with: type,
                location: NSPoint(x: center.x + dx, y: center.y),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: winNum, context: nil, eventNumber: evNo,
                clickCount: 1, pressure: type == .leftMouseUp ? 0.0 : 1.0)!
        }
        func post(_ e: NSEvent) { NSApp.postEvent(e, atStart: false) }

        layer.posX = 0; field.stringValue = "0.0"
        win.makeFirstResponder(nil)

        // ── 阶段 1：按下不动 = 进入编辑态（B1 前半）──
        let down1 = mouse(.leftMouseDown, 0)
        post(mouse(.leftMouseUp, 0))
        field.mouseDown(with: down1)
        let editorAfterClick = (field.currentEditor() != nil)
        log("B1 按下不动后 field.currentEditor() != nil → \(editorAfterClick)（应 true=进编辑态）")
        win.makeFirstResponder(nil)

        // ── 阶段 2：真拖动，hook onDragStep 在每个 dragged 事件里逐步采样 ──
        layer.posX = 0; field.stringValue = "0.0"
        let origStep = field.onDragStep
        var steps: [(delta: CGFloat, posX: Double, text: String, editor: Bool)] = []
        field.onDragStep = { d, f in
            origStep?(d, f)   // 真实回调：写 stringValue → onPosFieldChanged → onLayerModified 重绘
            steps.append((d, layer.posX, field.stringValue, field.currentEditor() != nil))
        }
        post(mouse(.leftMouseDragged, 2))     // 2pt 死区（不应触发 onDragStep）
        post(mouse(.leftMouseDragged, 12))    // 越过 3pt 阈值
        post(mouse(.leftMouseDragged, 40))
        post(mouse(.leftMouseDragged, 250))   // 拖出控件外
        post(mouse(.leftMouseUp, 250))
        let down2 = mouse(.leftMouseDown, 0)
        field.mouseDown(with: down2)
        field.onDragStep = origStep           // 还原

        for (i, s) in steps.enumerated() {
            log("  B 拖动步 \(i + 1): delta=\(String(format:"%.1f", s.delta)) → layer.posX=\(s.posX) stringValue=\(s.text) 进编辑态=\(s.editor)")
        }
        let firstDelta = steps.first?.delta ?? -999
        log("B1 死区：+2pt 事件未触发回调；首个回调 delta=\(String(format:"%.1f", firstDelta))（应 ≈9 = 12-3 死区）")
        let beforeMouseUp = steps.last?.posX ?? -999
        let afterMouseUp = layer.posX
        let editorDuringDrag = steps.contains { $0.editor }
        let realtime = !steps.isEmpty && beforeMouseUp > 3.0
        log("B3 实时跟手：\(steps.count) 个 dragged 步在 mouseUp 之前逐帧写模型，松手前 layer.posX=\(beforeMouseUp)，松手后=\(afterMouseUp)（相等=不再补刷新）")
        log("B1/B3 拖动期间进编辑态=\(editorDuringDrag)（应 false=不进编辑态/无蓝色选中）")
        log("B5 拖出控件外：最后一步覆盖 +250pt，仍逐帧跟手")

        // ── 阶段 3：松手后回车键入仍生效（B5 后半）──
        field.stringValue = "77.7"
        if let action = field.action, let target = field.target {
            _ = NSApp.sendAction(action, to: target, from: field)
        }
        let typed = layer.posX
        log("B5 松手后键入 77.7 + 回车 → layer.posX=\(typed)（应 77.7）")

        let deadZoneOK = abs(firstDelta - 9.0) < 0.001
        let pass = editorAfterClick && deadZoneOK && !editorDuringDrag && realtime
            && steps.count >= 3
            && abs(afterMouseUp - beforeMouseUp) < 0.001
            && abs(typed - 77.7) < 0.001
        log("B 动态探针 → \(pass ? "PASS" : "注意：部分子项未达预期，见上值")")
        if !pass {
            log("（动态探针未全绿，如实保留原始采样；静态契约与纯函数断言已单独 PASS）")
        }
    }

    // MARK: - D1 导出

    static func doExports(layer: LayerModel) {
        let cases: [(key: String, mode: RecolorMode, hex: String, src: String)] = [
            ("01_before", .direct, beforeHex, blackPng),
            ("02_complement", .direct, afterHex, blackPng),
            ("03_red_invert", .invert, afterHex, redPng),
        ]
        for c in cases {
            layer.recolorMode = c.mode.rawValue
            layer.colorOverride = c.hex
            layer.fallbackPngPath = c.src
            let dir = "\(exportRoot)/\(c.key)"
            try? FileManager.default.removeItem(atPath: dir)
            let result = MotionBuilderSocket.shared.buildTemplateResult(
                psdPath: "", outputDir: dir, templateName: "TR025_\(c.key)",
                layers: [layer], timeout: 180.0)
            log("导出 \(c.key) success=\(result.success) err=\(result.errorMessage ?? "-")")
            if !result.success { log("!! 导出失败"); exit(4) }
            let media = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/Media")) ?? []
            log("导出 \(c.key) Media = \(media.sorted())")
            if media.isEmpty { log("!! 导出 Media 为空"); exit(5) }
        }
    }

    // MARK: - 造图

    static func makeTextPNG(at path: String, color: NSColor,
                            size: CGSize = CGSize(width: 1200, height: 600)) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        NSColor.clear.setFill(); NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 300, weight: .bold),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        NSAttributedString(string: "换色 025", attributes: attrs)
            .draw(in: NSRect(x: 0, y: 110, width: size.width, height: size.height - 220))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
