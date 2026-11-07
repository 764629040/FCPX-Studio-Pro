// ═══════════════════════════════════════════════════════════════
//  R36 原生图层属性锁定与隐藏交互闭环（D-74）自动化直证 Harness
// ═══════════════════════════════════════════════════════════════

import AppKit
import Foundation

@main
struct R36LockHarness {
    static var failures = 0
    static var checks = 0

    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        let status = cond ? "✅ PASS" : "❌ FAIL"
        print("\(status) | \(name)\(detail.isEmpty ? "" : " | " + detail)")
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R36 原生图层锁定与隐藏 Harness 开始")
        print("==================================================")

        let rootDir = FileManager.default.currentDirectoryPath
        let evidenceDir = "\(rootDir)/docs/r36_evidence"
        try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        test1_LayerModelAndDeepCopy()
        test2_LockPenetrationAndDragBlocking()
        test3_CanvasLockedVisualRendering(evidenceDir: evidenceDir)
        test4_InspectorReadOnlyAndLockBanner()
        test5_ShortcutKeyLinkage()
        test6_AppBinaryAndSignature(rootDir: rootDir)

        print("==================================================")
        print("  总计检查点: \(checks) | 失败: \(failures)")
        print("==================================================")
        exit(failures == 0 ? 0 : 1)
    }

    // ─────────────────────────────────────────────────────────────
    // 1. LayerModel 扩展字段、深拷贝与状态同步验证
    // ─────────────────────────────────────────────────────────────
    static func test1_LayerModelAndDeepCopy() {
        print("\n── 1. LayerModel isLocked 字段与深拷贝/状态同步 ──")
        let layer = LayerModel(id: 10, name: "标题文字", text: "百年好合", isLocked: false)
        check(layer.isLocked == false, "LayerModel 默认 isLocked 为 false", "")

        layer.isLocked = true
        check(layer.isLocked == true, "LayerModel 成功置为 isLocked = true", "")

        // 深拷贝验证
        let copied = layer.copyModel()
        check(copied.id == layer.id, "深拷贝 ID 一致", "")
        check(copied.name == layer.name, "深拷贝 名称一致", "")
        check(copied.text == layer.text, "深拷贝 文字一致", "")
        check(copied.isLocked == true, "深拷贝 isLocked 属性一致", "")

        // 独立性验证：修改原对象不应影响副本
        layer.isLocked = false
        check(copied.isLocked == true, "原对象修改不影响深拷贝副本", "")

        // 状态同步验证
        let syncTarget = LayerModel(id: 99, name: "临时", text: "临时", isLocked: false)
        syncTarget.sync(from: copied)
        check(syncTarget.isLocked == true, "sync(from:) 准确同步 isLocked 状态", "")
        check(syncTarget.text == "百年好合", "sync(from:) 准确同步内容", "")
    }

    // ─────────────────────────────────────────────────────────────
    // 2. 画布锁定防误触穿透拾取与拖拽阻断验证（判据 1）
    // ─────────────────────────────────────────────────────────────
    static func test2_LockPenetrationAndDragBlocking() {
        print("\n── 2. 画布防误触穿透拾取与拖拽阻断（判据 1）──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.zoomScale = 1.0
        canvas.panOffset = .zero

        // Layer 0: 顶层（在 PSD 数组最前面），处于中心 (0,0)，已被用户锁定
        let topLayer = LayerModel(id: 1, name: "顶层锁定装饰", text: "装饰边框",
                                  posX: 0, posY: 0, psdBBox: [-50, -25, 50, 25], isLocked: true)

        // Layer 1: 底层，同样处于中心 (0,0)，范围更大，未锁定
        let bottomLayer = LayerModel(id: 2, name: "底层未锁定主标题", text: "新郎新娘",
                                     posX: 0, posY: 0, psdBBox: [-100, -50, 100, 50], isLocked: false)

        canvas.layers = [topLayer, bottomLayer]

        // 屏幕中心点 (400, 300) 对应图层中心 (0, 0)
        let centerPoint = CGPoint(x: 400, y: 300)

        // 2.1 穿透验证：顶层锁定，点击中心应穿透 topLayer，成功拾取底部的 bottomLayer (index 1)
        let hitIdx1 = canvas.hitTestLayer(at: centerPoint)
        check(hitIdx1 == 1, "点击锁定图层时自动穿透，命中下方未锁定图层 (index 1)", "hitIdx=\(hitIdx1)")

        // 2.2 全锁定验证：若底层也锁定，则均无法拾取，返回 -1
        bottomLayer.isLocked = true
        let hitIdx2 = canvas.hitTestLayer(at: centerPoint)
        check(hitIdx2 == -1, "所有图层均锁定时，拾取返回 -1，彻底防误触", "hitIdx=\(hitIdx2)")

        // 2.3 解锁顶层验证：若顶层解锁，优先拾取顶层 (index 0)
        topLayer.isLocked = false
        bottomLayer.isLocked = false
        let hitIdx3 = canvas.hitTestLayer(at: centerPoint)
        check(hitIdx3 == 0, "顶层未锁定时优先拾取顶层 (index 0)", "hitIdx=\(hitIdx3)")

        // 2.4 拖拽阻断验证：选中的图层若是锁定图层，绝对不启动拖拽
        topLayer.isLocked = true
        canvas.selectedLayerIndex = 0
        topLayer.posX = 100.0
        topLayer.posY = 50.0

        // 模拟鼠标拖拽事件调用
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 450, y: 350),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )
        if let ev = dragEvent {
            canvas.mouseDragged(with: ev)
        }
        check(topLayer.posX == 100.0, "锁定图层坐标未发生位移（X 保持原值）", "posX=\(topLayer.posX)")
        check(topLayer.posY == 50.0, "锁定图层坐标未发生位移（Y 保持原值）", "posY=\(topLayer.posY)")
    }

    // ─────────────────────────────────────────────────────────────
    // 3. 画布锁定视觉标识与离屏渲染验证（判据 2）
    // ─────────────────────────────────────────────────────────────
    static func test3_CanvasLockedVisualRendering(evidenceDir: String) {
        print("\n── 3. 画布锁定视觉标识与离屏渲染（判据 2）──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.zoomScale = 1.0
        canvas.panOffset = .zero

        let lockedLayer = LayerModel(id: 1, name: "定稿图层", text: "百年好合 永结同心",
                                     posX: 0, posY: 0, psdBBox: [-100, -30, 100, 30], isLocked: true)
        canvas.layers = [lockedLayer]
        canvas.selectedLayerIndex = 0 // 选中处于锁定状态的图层

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            check(false, "无法创建离屏 BitmapImageRep")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        let outPng = "\(evidenceDir)/r36_lock_badge_render.png"
        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: outPng))
            check(FileManager.default.fileExists(atPath: outPng), "画布锁定视觉渲染图导出成功", outPng)
        } else {
            check(false, "PNG 编码失败")
        }

        // 检查渲染像素：右上角区域应存在 🔒 LOCKED 徽标深色背景与灰色边框
        var foundBadgeBackground = false
        var foundGrayBorder = false
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        for x in 0..<w {
            for y in 0..<h {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = c.redComponent
                    let g = c.greenComponent
                    let b = c.blueComponent
                    // 灰色边框 (systemGray: r≈g≈b, 0.4~0.7)
                    if abs(r - g) < 0.08 && abs(g - b) < 0.08 && r > 0.4 && r < 0.75 {
                        foundGrayBorder = true
                    }
                    // 徽标深色胶囊背景 (0.12~0.25)
                    if abs(r - g) < 0.05 && abs(g - b) < 0.05 && r > 0.12 && r < 0.25 {
                        foundBadgeBackground = true
                    }
                }
            }
        }
        check(foundGrayBorder, "离屏图像中检测到专属锁定细点灰色边框", "")
        check(foundBadgeBackground, "离屏图像中检测到 🔒 LOCKED 徽标背景像素", "")
    }

    // ─────────────────────────────────────────────────────────────
    // 4. 检查器属性只读置灰与锁定提示条（判据 3）
    // ─────────────────────────────────────────────────────────────
    static func test4_InspectorReadOnlyAndLockBanner() {
        print("\n── 4. 检查器属性只读置灰与锁定提示条（判据 3）──")
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 360, height: 750))
        let layerUnlocked = LayerModel(id: 1, name: "正常图层", text: "自由编辑", isLocked: false)
        let layerLocked = LayerModel(id: 2, name: "锁定图层", text: "已定稿只读", isLocked: true)

        inspector.layers = [layerUnlocked, layerLocked]

        // 4.1 表格列结构核查
        let colLock = inspector.layerTableView.tableColumns.first { $0.identifier.rawValue == "lock" }
        let colVis  = inspector.layerTableView.tableColumns.first { $0.identifier.rawValue == "vis" }
        check(colLock != nil, "图层表格已增加「锁定」列 (lock)", "")
        check(colVis != nil, "图层表格具有「显示」列 (vis)", "")

        // 4.2 选中未锁定图层时的状态断言
        inspector.selectLayer(at: 0)
        check(inspector.lockBannerBox.isHidden == true, "未锁定图层选中时，锁定提示横幅保持隐藏", "")
        check(inspector.textEditor.isEditable == true, "未锁定图层选中时，文本编辑器可编辑", "")
        check(inspector.toggleOrientationButton.isEnabled == true, "未锁定图层选中时，版式切换按钮可用", "")
        check(inspector.rotationSlider.isEnabled == true, "未锁定图层选中时，旋转控制滑动条可用", "")
        check(inspector.scaleSlider.isEnabled == true, "未锁定图层选中时，缩放控制滑动条可用", "")
        check(inspector.posXField.isEnabled == true, "未锁定图层选中时，X 坐标输入框可用", "")
        check(inspector.posYField.isEnabled == true, "未锁定图层选中时，Y 坐标输入框可用", "")
        check(inspector.publishTextCheck.isEnabled == true, "未锁定图层选中时，发布复选框可用", "")

        // 4.3 选中锁定图层时的智能置灰与提示横幅断言
        inspector.selectLayer(at: 1)
        check(inspector.lockBannerBox.isHidden == false, "锁定图层选中时，显式展示黄色锁定提示横幅", "")
        check(inspector.lockBannerLabel.stringValue.contains("图层已锁定"), "提示横幅文本包含「图层已锁定」", inspector.lockBannerLabel.stringValue)
        check(inspector.textEditor.isEditable == false, "锁定图层选中时，文本编辑器自动禁用只读 (isEditable=false)", "")
        check(inspector.toggleOrientationButton.isEnabled == false, "锁定图层选中时，版式切换按钮自动禁用 (isEnabled=false)", "")
        check(inspector.rotationSlider.isEnabled == false, "锁定图层选中时，旋转控制自动禁用", "")
        check(inspector.scaleSlider.isEnabled == false, "锁定图层选中时，缩放控制自动禁用", "")
        check(inspector.posXField.isEnabled == false, "锁定图层选中时，X 坐标框自动禁用", "")
        check(inspector.posYField.isEnabled == false, "锁定图层选中时，Y 坐标框自动禁用", "")
        check(inspector.publishTextCheck.isEnabled == false, "锁定图层选中时，发布复选框自动禁用", "")

        // 4.4 点击列表锁定按钮交互测试
        let mockLockBtn = NSButton()
        mockLockBtn.tag = 0 // 针对 layerUnlocked
        inspector.onLockToggled(mockLockBtn)
        check(layerUnlocked.isLocked == true, "点击锁定按钮成功将图层由未锁定转为锁定", "")
        check(mockLockBtn.title == "🔒", "按钮状态图标即时变为 🔒", "")

        inspector.onLockToggled(mockLockBtn)
        check(layerUnlocked.isLocked == false, "再次点击锁定按钮恢复为未锁定", "")
        check(mockLockBtn.title == "🔓", "按钮状态图标即时变为 🔓", "")

        // 4.5 可见性眼睛按钮交互测试
        let mockVisBtn = NSButton()
        mockVisBtn.tag = 0
        check(layerUnlocked.visible == true, "默认图层可见性为 true", "")
        inspector.onVisibilityToggled(mockVisBtn)
        check(layerUnlocked.visible == false, "点击可见性按钮成功隐藏图层 (visible=false)", "")
        check(mockVisBtn.title == "🚫", "按钮状态图标切换为隐藏符号 🚫", "")
        inspector.onVisibilityToggled(mockVisBtn)
        check(layerUnlocked.visible == true, "再次点击可见性按钮成功恢复显示 (visible=true)", "")
        check(mockVisBtn.title == "👁", "按钮状态图标恢复为眼睛 👁", "")
    }

    // ─────────────────────────────────────────────────────────────
    // 5. 快捷键联动验证（⌘L 锁定 / ⌘H 隐藏）（判据 4）
    // ─────────────────────────────────────────────────────────────
    static func test5_ShortcutKeyLinkage() {
        print("\n── 5. 快捷键联动验证 ⌘L 与 ⌘H（判据 4）──")
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 360, height: 750))
        let layer = LayerModel(id: 1, name: "快捷键测试层", text: "快捷操作", isLocked: false)
        inspector.layers = [layer]
        inspector.selectLayer(at: 0)

        // 5.1 直接方法联动验证
        inspector.toggleCurrentLayerLock()
        check(layer.isLocked == true, "toggleCurrentLayerLock() 成功切换为锁定", "")
        check(inspector.lockBannerBox.isHidden == false, "方法触发后属性控件与横幅同步响应", "")

        inspector.toggleCurrentLayerLock()
        check(layer.isLocked == false, "toggleCurrentLayerLock() 再次调用恢复未锁定", "")
        check(inspector.lockBannerBox.isHidden == true, "方法触发后横幅隐去", "")

        inspector.toggleCurrentLayerVisibility()
        check(layer.visible == false, "toggleCurrentLayerVisibility() 成功切换为隐藏", "")
        inspector.toggleCurrentLayerVisibility()
        check(layer.visible == true, "toggleCurrentLayerVisibility() 再次调用恢复显示", "")

        // 5.2 performKeyEquivalent 事件驱动联动验证 (⌘L / ⌘H)
        if let eventCmdL = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ) {
            let handled = inspector.performKeyEquivalent(with: eventCmdL)
            check(handled == true, "performKeyEquivalent 准确拦截并处理 ⌘L 事件", "")
            check(layer.isLocked == true, "⌘L 快捷键成功将当前图层切换为锁定", "isLocked=\(layer.isLocked)")
        } else {
            check(false, "未能构造 ⌘L 测试事件")
        }

        if let eventCmdH = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "h",
            charactersIgnoringModifiers: "h",
            isARepeat: false,
            keyCode: 4
        ) {
            let handled = inspector.performKeyEquivalent(with: eventCmdH)
            check(handled == true, "performKeyEquivalent 准确拦截并处理 ⌘H 事件", "")
            check(layer.visible == false, "⌘H 快捷键成功将当前图层切换为隐藏", "visible=\(layer.visible)")
        } else {
            check(false, "未能构造 ⌘H 测试事件")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 6. 原生构建二进制与代码签名验证（判据 5）
    // ─────────────────────────────────────────────────────────────
    static func test6_AppBinaryAndSignature(rootDir: String) {
        print("\n── 6. 原生构建二进制与代码签名验证（判据 5）──")
        let appBinary = "\(rootDir)/FCPX Studio Pro.app/Contents/MacOS/FCPXStudio"
        let appBundle = "\(rootDir)/FCPX Studio Pro.app"

        check(FileManager.default.fileExists(atPath: appBinary), "原生 Mach-O 二进制文件存在", appBinary)

        // 运行 codesign 校验
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-v", appBundle]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        proc.waitUntilExit()

        check(proc.terminationStatus == 0, "codesign -v 签名验证通过，具有有效代码签名", "status=\(proc.terminationStatus)")
    }
}
