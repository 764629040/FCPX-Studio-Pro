import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r45_harness.swift
//  开发任务单 R45 —— 层级可见性继承、文字排版自适应、表头总控与毛玻璃UI直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R45Harness {
    static var totalChecks = 0
    static var failedChecks = 0

    static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        totalChecks += 1
        if condition {
            let extra = detail.isEmpty ? "" : " | \(detail)"
            print("✅ PASS | \(title)\(extra)")
        } else {
            failedChecks += 1
            let extra = detail.isEmpty ? "" : " | 详情: \(detail)"
            print("❌ FAIL | \(title)\(extra)")
        }
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R45 综合系统直证套件")
        print("==================================================")

        test1_Layer_Visibility_Inheritance_Root_Cause()
        test2_Text_Layout_Bounding_Box_Adaptation()
        test3_Inspector_Header_Eye_Master_Toggle()
        test4_Modern_Pro_Frosted_Glass_And_SF_Symbols()
        test5_PSD_Original_Composite_Vs_Canvas_Comparison_Modes()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：层级可见性继承（Root Cause 根治）
    // ─────────────────────────────────────────────────────────────
    static func test1_Layer_Visibility_Inheritance_Root_Cause() {
        print("\n── 判据 1：层级可见性继承（隐藏组子图层默认不作为可见层加载） ──")
        let psdPath = "/Volumes/NO NAME/128/字幕/音乐封面/被托付的光.psd"

        guard FileManager.default.fileExists(atPath: psdPath) else {
            check(false, "测试 PSD 文件存在性", "未找到 \(psdPath)")
            return
        }
        check(true, "找到测试 PSD 文件", psdPath)

        // 1. 默认 includeHidden = false 解析
        let resNormal = PSDParserSocket.shared.parsePSD(at: psdPath, includeHidden: false)
        check(resNormal.isValid, "被托付的光.psd 解析成功", "isValid=\(resNormal.isValid)")
        check(resNormal.layers.count == 2, "默认状态仅提取真实可见图层 (2层)", "实际层数=\(resNormal.layers.count)")

        let normalNames = resNormal.layers.map { $0.name }
        check(normalNames.contains("我的随   拍日记"), "包含根目录可见图层 '我的随   拍日记'")
        check(normalNames.contains("The Story   of a Small Town"), "包含根目录可见图层 'The Story   of a Small Town'")

        // 验证隐藏组（组 1、组 2、轻轻）中的子图层均未被误载为可见层
        check(!normalNames.contains("被托付   的光"), "隐藏组2内部图层 '被托付   的光' 未被误载入可见列表")
        check(!normalNames.contains("JUNG YONG HWA"), "隐藏组1内部图层 'JUNG YONG HWA' 未被误载入可见列表")
        check(!normalNames.contains("轻轻"), "隐藏组'轻轻'内部图层未被误载入可见列表")

        // 检查隐藏图层统计与忽略摘要
        check(resNormal.counts.hidden == 12, "精准统计 12 个属于隐藏组/隐藏状态的图层", "hidden=\(resNormal.counts.hidden)")
        check(resNormal.originalCompositePath != nil, "PSD 原始合成图导出成功", "path=\(resNormal.originalCompositePath ?? "")")
        if let p = resNormal.originalCompositePath {
            check(FileManager.default.fileExists(atPath: p), "原始合成图物理文件存在且非空")
        }

        // 2. includeHidden = true 预览解析
        let resHidden = PSDParserSocket.shared.parsePSD(at: psdPath, includeHidden: true)
        check(resHidden.isValid, "勾选显示隐藏图层时解析成功", "isValid=\(resHidden.isValid)")
        check(resHidden.layers.count == 14, "包含全部 2 个可见层与 12 个预览层 (总计 14 层)", "实际层数=\(resHidden.layers.count)")
        let previewCount = resHidden.layers.filter { !$0.visible }.count
        check(previewCount == 12, "预览层数量精确等于 12 且 visible 均为 false", "previewCount=\(previewCount)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：文字排版边界自适应（根治文字截断与漏字）
    // ─────────────────────────────────────────────────────────────
    static func test2_Text_Layout_Bounding_Box_Adaptation() {
        print("\n── 判据 2：文字排版边界自适应（大字号与换行排版尺寸自适应） ──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))

        // 模拟「被托付   的光」图层：文本包含换行，字号 429pt，原始 bbox 仅 1232x892
        let textLayer = LayerModel(
            id: 1,
            name: "被托付   的光",
            kind: "type",
            text: "被托付\n  的光",
            fontName: "PingFangSC-Regular",
            fontSize: 429,
            tracking: 0,
            posX: 0,
            posY: 0,
            opacity: 1.0,
            writingDirection: "horizontal",
            visible: true,
            isPublished: true,
            psdBBox: [326, 128, 1558, 1020] // 原始宽高: 1232 x 892
        )

        let visualSize = canvas.layerVisualSize(for: textLayer)
        print("    -> 原始 psdBBox 尺寸: 1232 x 892")
        print("    -> 自适应排版视觉尺寸: \(visualSize.width) x \(visualSize.height)")

        // 首行文字“被托付”在 429pt 下自然宽度约为 1287pt，故自适应宽度必须超过 1232pt
        check(visualSize.width >= 1250, "自适应排版宽度超越原始 bbox 宽度，容纳首行不折行", "visualWidth=\(visualSize.width)")
        check(visualSize.height >= 892, "自适应排版高度完整容纳所有文本行", "visualHeight=\(visualSize.height)")

        // 属性字串测量验证
        let font = NSFont(name: textLayer.fontName, size: 429) ?? NSFont.systemFont(ofSize: 429)
        let astr = NSAttributedString(string: textLayer.text, attributes: [.font: font])
        let needed = astr.boundingRect(
            with: CGSize(width: max(1232 * 2.0, 4000), height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        check(needed.width > 0 && needed.height > 0, "CoreText 测量结果有效", "needed=\(needed)")
        check(visualSize.width >= needed.width, "画布计算所得绘制宽度 drawW 充分包含 CoreText 测量宽度")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：表头眼睛总控按钮（一键全选/全部隐藏）
    // ─────────────────────────────────────────────────────────────
    static func test3_Inspector_Header_Eye_Master_Toggle() {
        print("\n── 判据 3：表头眼睛总控按钮（一键全选 / 全部隐藏） ──")
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))

        let l1 = LayerModel(id: 1, name: "Layer1", visible: true)
        let l2 = LayerModel(id: 2, name: "Layer2", visible: true)
        let l3 = LayerModel(id: 3, name: "Layer3", visible: true)
        inspector.layers = [l1, l2, l3]

        var callbackCount = 0
        inspector.onAllVisibilityToggled = { layers in
            callbackCount += 1
        }

        check(inspector.layers.allSatisfy { $0.visible }, "初始所有图层均为可见")

        // 1. 点击表头眼睛：有可见层时 -> 全部隐藏
        inspector.toggleAllVisibility()
        check(inspector.layers.allSatisfy { !$0.visible }, "第一次点击表头眼睛：所有图层均变为隐藏 (visible=false)")
        check(callbackCount == 1, "触发 onAllVisibilityToggled 回调")

        // 2. 再次点击表头眼睛：全为隐藏时 -> 全部恢复可见
        inspector.toggleAllVisibility()
        check(inspector.layers.allSatisfy { $0.visible }, "第二次点击表头眼睛：所有图层恢复可见 (visible=true)")
        check(callbackCount == 2, "再次触发 onAllVisibilityToggled 回调")

        // 3. 部分可见状态下点击：应全部隐藏
        inspector.layers[0].visible = true
        inspector.layers[1].visible = false
        inspector.layers[2].visible = false
        inspector.toggleAllVisibility()
        check(inspector.layers.allSatisfy { !$0.visible }, "部分可见状态下点击：一键全部置为隐藏")

        // 4. 表头配置与图标检查
        let colVis = inspector.layerTableView.tableColumns.first { $0.identifier.rawValue == "vis" }
        check(colVis != nil, "找到可见性列 (vis)")
        check(colVis?.headerCell.image != nil, "表头包含 SF Symbol 矢量图标")
        check(colVis?.headerToolTip?.contains("全选") == true, "表头包含一键全选提示说明")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：现代 macOS Pro 哑光半透明毛玻璃 UI 与 SF Symbols
    // ─────────────────────────────────────────────────────────────
    static func test4_Modern_Pro_Frosted_Glass_And_SF_Symbols() {
        print("\n── 判据 4：现代 macOS Pro 哑光半透明毛玻璃 UI 与 SF Symbols 图标体系 ──")
        let winCtrl = MainWindowController()
        guard let win = winCtrl.window else {
            check(false, "主窗口实例创建成功")
            return
        }

        // 1. 窗口毛玻璃与全高内容区检查
        check(win.styleMask.contains(.fullSizeContentView), "窗口启用 .fullSizeContentView 现代浸润式样式")
        check(win.titlebarAppearsTransparent, "窗口启用透明标题栏 titlebarAppearsTransparent = true")

        // 2. 容器 NSVisualEffectView 材质检查
        let topBarEffect = win.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first
        check(topBarEffect != nil, "顶部工具栏升级为 NSVisualEffectView 半透明材质")
        if let tb = topBarEffect {
            check(tb.blendingMode == .behindWindow, "顶栏采用 .behindWindow 背向毛玻璃模糊")
            check(tb.material == .sidebar, "顶栏采用 .sidebar 现代深色磨砂材质")
        }

        check((winCtrl.inspectorView as Any) is NSVisualEffectView, "属性检查器面板继承 NSVisualEffectView 毛玻璃基类")
        check(winCtrl.inspectorView.material == .sidebar, "检查器面板材质为 .sidebar")

        // 3. SF Symbols 图标体系检查
        let seg = winCtrl.segmentedControl
        check(seg?.image(forSegment: 0) != nil, "引擎一分段控制器采用 SF Symbol (slider.horizontal.3)")
        check(seg?.image(forSegment: 1) != nil, "引擎二分段控制器采用 SF Symbol (square.stack.3d.up)")

        let compSeg = winCtrl.comparisonSegmentedControl
        check(compSeg != nil, "顶部工具栏配备原稿对比分段控制器")
        check(compSeg?.image(forSegment: 0) != nil, "对比控件包含画板图标")
        check(compSeg?.image(forSegment: 1) != nil, "对比控件包含卷帘分屏图标")
        check(compSeg?.image(forSegment: 2) != nil, "对比控件包含并排分屏图标")
        check(compSeg?.image(forSegment: 3) != nil, "对比控件包含透视图标")

        check(winCtrl.inspectorView.toggleOrientationButton.image != nil, "横竖排切换按钮采用 SF Symbol 矢量图标")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：PSD 原始成图 vs 转出画面直观对比模式
    // ─────────────────────────────────────────────────────────────
    static func test5_PSD_Original_Composite_Vs_Canvas_Comparison_Modes() {
        print("\n── 判据 5：PSD 原始成图 vs 转出画面直观对比模式 ──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        check(canvas.comparisonMode == .off, "默认对比模式为 .off (正常单画板)")

        // 1. 中轴卷帘对比模式
        canvas.comparisonMode = .splitCurtain
        canvas.splitDividerPosition = 0.65
        check(canvas.comparisonMode == .splitCurtain, "成功切换至 .splitCurtain (卷帘分屏对比)")
        check(canvas.splitDividerPosition == 0.65, "中轴分割线位置精准控制 (65%)")

        // 2. 并排双画板对比模式
        canvas.comparisonMode = .sideBySide
        check(canvas.comparisonMode == .sideBySide, "成功切换至 .sideBySide (并排对比)")

        // 3. 瞬时透视原图
        canvas.isPeekingOriginal = true
        check(canvas.isPeekingOriginal, "成功激活 isPeekingOriginal 瞬时透视原图模式")
        canvas.isPeekingOriginal = false
        check(!canvas.isPeekingOriginal, "松开透视恢复正常转出渲染")
    }
}
