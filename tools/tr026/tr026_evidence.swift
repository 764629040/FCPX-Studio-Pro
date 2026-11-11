import AppKit

// ═══════════════════════════════════════════════════════════════════════════
// TR-026-B 取证工具（只读 .moti 预览态 / 锁定态 / 可编辑态回归）
//
// 编译（项目根，与 TR-025 同一批源文件）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr026/tr026_evidence.swift -o /tmp/tr026_evidence_bin
//
// 四条硬断言（问题单原文照抄）：
//   1. 只读 .moti 打开后：posX/posY/rotationField/scaleField/rotationSlider/scaleSlider
//      全部 isEnabled == false
//   2. 对该 field 直接投 mouseDown + 3 个 dragged + mouseUp 序列，layer.posX 前后相等
//   3. 锁定态（⌘L）同样全 false；解锁后回到 true
//   4. 可编辑态回归：TR-025 B 的 9→37→247 三步、松手前后相等、全程不进 field editor
//
// 另加一条「其它控件零顺带改动」旁证：只读态下发布复选框 / 文字编辑 /
// 横竖排按钮仍按 TR-025 原样（layer 未锁 → 仍 enabled = true）。
//
// 拖动探针沿用 TR-025 的确定性 NSEvent 序列（NSApp.postEvent + 直接 mouseDown），
// 不用 CGEvent 系统注入（本机沙盒 + main queue 同步 eventTracking loop 会死锁超时）。
// ═══════════════════════════════════════════════════════════════════════════

@main
final class TR026Evidence {
    static let outDir = "/tmp/tr026_shots"
    static var wc: MainWindowController!
    static var meta: [String] = []

    static func log(_ s: String) {
        print("[TR-026] " + s)
        fflush(stdout)
        meta.append(s)
    }

    static func fail(_ code: Int32, _ s: String) -> Never {
        log("!! " + s)
        try? meta.joined(separator: "\n").write(toFile: "\(outDir)/meta.txt", atomically: true, encoding: .utf8)
        exit(code)
    }

    static func main() {
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
        let png = "/tmp/tr025_src/black_text.png"
        let layer = LayerModel(id: 1, name: "TR026", kind: "fallback_png", text: "",
                               fallbackPngPath: png, psdBBox: [0, 0, 1200, 600])
        layer.posX = 0; layer.posY = 0
        layer.scaleX = 1.0; layer.scaleY = 1.0; layer.rotation = 0
        layer.isLocked = false
        wc.canvasView.layers = [layer]
        wc.canvasView.setResolution(width: 1200, height: 600)
        wc.canvasView.selectedLayerIndex = 0
        wc.inspectorView!.layers = [layer]
        wc.inspectorView!.selectLayer(at: 0)
        wc.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        log("窗口 windowNumber=\(wc.window?.windowNumber ?? -1)；layer.isLocked=\(layer.isLocked)")

        // ── 硬断言 1：只读 .moti 预览态 ──────────────────────────────────
        wc.inspectorView!.updateMotiReadOnlyInfo(canvasWidth: 1200, canvasHeight: 600,
                                                layerCount: 1,
                                                notes: ["TR-026 只读预览取证"])
        wc.inspectorView!.selectLayer(at: 0)      // 三个调用点之一：isLocked = false || true
        log("只读态 motiReadOnlyMode=\(wc.inspectorView!.motiReadOnlyMode)")
        assertGeometryDisabled(tag: "只读态")
        assertOtherControls(expected: true, tag: "只读态·按 TR-025 现状")

        // ── 硬断言 2：投 mouseDown + 3 dragged + mouseUp，posX 不许变 ─────
        assertReadOnlyDragNoop(layer: layer)

        // ── 硬断言 3：锁定态（⌘L 等价）全 false；解锁回 true ──────────────
        wc.inspectorView!.motiReadOnlyMode = false
        wc.inspectorView!.selectLayer(at: 0)
        wc.inspectorView!.toggleCurrentLayerLock()   // ⌘L 的 action 本体（performKeyEquivalent 也走它）
        log("锁定态 layer.isLocked=\(layer.isLocked)")
        assertGeometryDisabled(tag: "锁定态")
        assertOtherControls(expected: false, tag: "锁定态·按 TR-025 现状")
        wc.inspectorView!.toggleCurrentLayerLock()   // 解锁
        log("解锁后 layer.isLocked=\(layer.isLocked)")
        assertGeometryEnabled(tag: "解锁态")
        assertOtherControls(expected: true, tag: "解锁态·按 TR-025 现状")

        // ── 硬断言 4：可编辑态回归 TR-025 B ────────────────────────────────
        probeDragRegression(layer: layer)

        try? meta.joined(separator: "\n").write(toFile: "\(outDir)/meta.txt", atomically: true, encoding: .utf8)
        log("meta 写入 \(outDir)/meta.txt")
        log("TR-026-B 四条硬断言 + 其它控件零顺带改动旁证 → 全部 PASS")
        exit(0)
    }

    // MARK: - 六控件状态

    static func geometryStates() -> [(String, Bool)] {
        let v = wc.inspectorView!
        return [
            ("posXField",     v.posXField?.isEnabled ?? false),
            ("posYField",     v.posYField?.isEnabled ?? false),
            ("rotationField", v.rotationField?.isEnabled ?? false),
            ("scaleField",    v.scaleField?.isEnabled ?? false),
            ("rotationSlider",v.rotationSlider?.isEnabled ?? false),
            ("scaleSlider",   v.scaleSlider?.isEnabled ?? false),
        ]
    }

    static func assertGeometryDisabled(tag: String) {
        let s = geometryStates()
        log("\(tag) 六控件: " + s.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        if s.contains(where: { $0.1 }) {
            fail(20, "\(tag) 仍有几何控件 enabled=true（只读/锁定态必须全 false）")
        }
        log("\(tag) 断言 1/3 PASS：六控件全 false")
    }

    static func assertGeometryEnabled(tag: String) {
        let s = geometryStates()
        log("\(tag) 六控件: " + s.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        if s.contains(where: { !$0.1 }) {
            fail(21, "\(tag) 仍有几何控件 enabled=false（解锁后必须全 true）")
        }
        log("\(tag) 断言 3 PASS：六控件全 true")
    }

    /// 其它控件行为不许变：只读态（layer 未锁）按 TR-025 现状仍为 true；
    /// 锁定态按 TR-025 现状为 false；解锁后 true。
    static func assertOtherControls(expected: Bool, tag: String) {
        let v = wc.inspectorView!
        let s: [(String, Bool)] = [
            ("publishTextCheck",       v.publishTextCheck?.isEnabled ?? false),
            ("publishPosCheck",        v.publishPosCheck?.isEnabled ?? false),
            ("publishRotCheck",        v.publishRotCheck?.isEnabled ?? false),
            ("publishScaleCheck",      v.publishScaleCheck?.isEnabled ?? false),
            ("textEditor.isEditable",  v.textEditor?.isEditable ?? false),
            ("toggleOrientationButton",v.toggleOrientationButton?.isEnabled ?? false),
        ]
        log("\(tag) 其它控件(期望 \(expected)): " + s.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        if s.contains(where: { $0.1 != expected }) {
            fail(22, "\(tag) 其它控件被顺带改了（期望全 \(expected)）")
        }
        log("\(tag) 其它控件零顺带改动 PASS")
    }

    // MARK: - 硬断言 2：禁用态拖不动

    static func assertReadOnlyDragNoop(layer: LayerModel) {
        guard let field = wc.inspectorView!.posXField as? DraggableNumberField,
              let win = field.window else { fail(11, "拿不到 posXField/window") }
        let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let winNum = win.windowNumber
        var evNo = 0
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            evNo += 1
            return NSEvent.mouseEvent(with: type,
                location: NSPoint(x: center.x + dx, y: center.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: winNum, context: nil, eventNumber: evNo,
                clickCount: 1, pressure: type == .leftMouseUp ? 0.0 : 1.0)!
        }
        func post(_ e: NSEvent) { NSApp.postEvent(e, atStart: false) }

        layer.posX = 123.4
        field.stringValue = "123.4"
        win.makeFirstResponder(nil)
        let before = layer.posX

        // 问题单要求：mouseDown + 3 个 dragged + mouseUp
        let down = mouse(.leftMouseDown, 0)
        post(mouse(.leftMouseDragged, 12))
        post(mouse(.leftMouseDragged, 40))
        post(mouse(.leftMouseDragged, 250))
        post(mouse(.leftMouseUp, 250))
        field.mouseDown(with: down)      // isEnabled=false → guard 走 super，不进 8s tracking loop
        let after = layer.posX
        log("只读态拖动探针: layer.posX before=\(before) after=\(after)；posXField.isEnabled=\(field.isEnabled)")
        if field.isEnabled { fail(13, "只读态 posXField 仍 enabled") }
        if abs(before - after) > 0.0001 {
            fail(12, "只读态拖动改了 layer.posX（\(before) → \(after)）")
        }
        log("只读态断言 2 PASS：mouseDown + 3 dragged + mouseUp 后 posX 前后相等（\(before)）")

        // 排空残留事件，避免污染后面的可编辑态回归探针
        while let _ = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                                      until: Date().addingTimeInterval(0.05),
                                      inMode: .default, dequeue: true) {}
    }

    // MARK: - 硬断言 4：可编辑态回归（照抄 TR-025 B 的探针）

    static func probeDragRegression(layer: LayerModel) {
        guard let field = wc.inspectorView!.posXField as? DraggableNumberField,
              let win = field.window else { fail(11, "回归探针拿不到 posXField/window") }
        _ = field.scrollToVisible(field.bounds)
        win.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let winNum = win.windowNumber
        var evNo = 100
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            evNo += 1
            return NSEvent.mouseEvent(with: type,
                location: NSPoint(x: center.x + dx, y: center.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: winNum, context: nil, eventNumber: evNo,
                clickCount: 1, pressure: type == .leftMouseUp ? 0.0 : 1.0)!
        }
        func post(_ e: NSEvent) { NSApp.postEvent(e, atStart: false) }

        // 阶段 1：按下不动 = 进编辑态
        layer.posX = 0; field.stringValue = "0.0"
        win.makeFirstResponder(nil)
        let down1 = mouse(.leftMouseDown, 0)
        post(mouse(.leftMouseUp, 0))
        field.mouseDown(with: down1)
        let editorAfterClick = (field.currentEditor() != nil)
        log("回归 B1 按下不动 field.currentEditor() != nil → \(editorAfterClick)（应 true）")
        win.makeFirstResponder(nil)

        // 阶段 2：真拖动，逐帧采样
        layer.posX = 0; field.stringValue = "0.0"
        let origStep = field.onDragStep
        var steps: [(delta: CGFloat, posX: Double, text: String, editor: Bool)] = []
        field.onDragStep = { d, f in
            origStep?(d, f)
            steps.append((d, layer.posX, field.stringValue, field.currentEditor() != nil))
        }
        post(mouse(.leftMouseDragged, 2))
        post(mouse(.leftMouseDragged, 12))
        post(mouse(.leftMouseDragged, 40))
        post(mouse(.leftMouseDragged, 250))
        post(mouse(.leftMouseUp, 250))
        let down2 = mouse(.leftMouseDown, 0)
        field.mouseDown(with: down2)
        field.onDragStep = origStep

        for (i, s) in steps.enumerated() {
            log("  回归 B 拖动步 \(i + 1): delta=\(String(format: "%.1f", s.delta)) → layer.posX=\(s.posX) stringValue=\(s.text) 进编辑态=\(s.editor)")
        }
        let firstDelta = steps.first?.delta ?? -999
        let beforeMouseUp = steps.last?.posX ?? -999
        let afterMouseUp = layer.posX
        let editorDuringDrag = steps.contains { $0.editor }
        let deadZoneOK = abs(firstDelta - 9.0) < 0.001
        let threeSteps = steps.count >= 3
        let valuesOK = steps.count >= 3
            && abs(steps[0].posX - 9.0) < 0.001
            && abs(steps[1].posX - 37.0) < 0.001
            && abs(steps[2].posX - 247.0) < 0.001
        log("回归 B1 死区：首个回调 delta=\(String(format: "%.1f", firstDelta))（应 9.0）")
        log("回归 B3 松手前 layer.posX=\(beforeMouseUp)，松手后=\(afterMouseUp)（相等=不补刷新）")
        log("回归 B1/B3 拖动期间进编辑态=\(editorDuringDrag)（应 false）")

        // 阶段 3：松手后键入 77.7 + 回车
        field.stringValue = "77.7"
        if let action = field.action, let target = field.target {
            _ = NSApp.sendAction(action, to: target, from: field)
        }
        let typed = layer.posX
        log("回归 B5 松手后键入 77.7 + 回车 → layer.posX=\(typed)（应 77.7）")

        let pass = editorAfterClick && deadZoneOK && threeSteps && valuesOK
            && !editorDuringDrag
            && abs(afterMouseUp - beforeMouseUp) < 0.001
            && abs(typed - 77.7) < 0.001
        if !pass { fail(23, "可编辑态回归 TR-025 B 失败（把对的改坏了）") }
        log("可编辑态回归断言 4 PASS：9→37→247 三步 / 松手前后相等 / 全程不进 field editor / 回车 77.7")
        log("DraggableNumberField 的 3pt 死区与 8s 兜底本单未动（探针仍按原行为 PASS）")
    }
}
