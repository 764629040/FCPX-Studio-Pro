// ═══════════════════════════════════════════════════════════════════════════
// tools/tr023b/ui_evidence.swift
// TR-023-B：真机证据（真实 MainWindowController 窗口 → 真实解析链 → 真实窗口像素）
//
// 这不是生产开关，也不进 App 包：它只在本目录编译运行，作用是替手动点击取证。
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr023b/ui_evidence.swift -o /tmp/tr023b_ui
// 运行（cwd = 项目根）：
//   /tmp/tr023b_ui <输出目录> <psd 路径> <moti 路径>
// ═══════════════════════════════════════════════════════════════════════════

import AppKit

@main
struct UIEvidence {
    static var wc: MainWindowController!
    static var outDir = "/tmp/tr023b_shots"
    static var psdPath = "tests/data/wedding_with_decorations_23.psd"
    static var motiPath = ""
    static var finished = false

    static func log(_ s: String) {
        print("[TR-023-B] " + s)
        fflush(stdout)
    }

    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 { outDir = args[1] }
        if args.count > 2 { psdPath = args[2] }
        if args.count > 3 { motiPath = args[3] }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        wc = MainWindowController()
        wc.showWindow(nil)
        wc.window?.setFrame(NSRect(x: 60, y: 60, width: 1400, height: 920), display: true)
        app.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { loadPSD() }
        app.run()
    }

    // MARK: - 1. 编辑态：导入 PSD → 选中带样式的文字层 → 截图 + 改字号/颜色对照
    static func loadPSD() {
        log("导入 PSD: \(psdPath)")
        wc.onParseCompleted = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { editableShots() }
        }
        wc.importPsdPaths([psdPath])
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !finished { log("等待 PSD 解析超时"); exit(3) }
        }
    }

    static func editableShots() {
        guard let ins = wc.inspectorView else { log("没有 inspectorView"); exit(4) }
        log("解析完成，图层数 = \(ins.layers.count)")

        var picked = -1
        for (i, layer) in ins.layers.enumerated() where layer.fontSize > 0 && !layer.textColor.isEmpty {
            picked = i
            break
        }
        if picked < 0 {
            for (i, layer) in ins.layers.enumerated() where layer.fontSize > 0 {
                picked = i
                break
            }
        }
        if picked < 0 { picked = 0 }

        ins.layerTableView?.selectRowIndexes(IndexSet(integer: picked), byExtendingSelection: false)
        ins.selectLayer(at: picked)
        let layer = ins.layers[picked]
        log("选中 #\(picked) \(layer.name) kind=\(layer.kind) font=\(layer.fontName) "
            + "size=\(layer.fontSize) align=\(layer.alignment) color=\(layer.textColor.isEmpty ? "-" : layer.textColor)")
        log("控件状态: 字号=\(ins.fontSizeField.isEnabled) 对齐=\(ins.alignmentSegment.isEnabled) "
            + "颜色=\(ins.colorWell.isEnabled) 字体=\(ins.fontReplaceButton.isEnabled)")
        log("诊断: alignment=\(layer.alignment) selectedSegment=\(ins.alignmentSegment.selectedSegment) "
            + "标题hidden=\(ins.textStyleTitleLabel.isHidden) "
            + "标题frame=\(ins.textStyleTitleLabel.frame) "
            + "标题文字=\(ins.textStyleTitleLabel.stringValue)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            capture("tr023b_1_可编辑态新分组.png")
            log("改前 fontSize=\(layer.fontSize) textColor=\(layer.textColor)")
            // 改字号 + 改颜色（走与控件相同的赋值路径）
            layer.fontSize = 160
            layer.textColor = "#E5484D"
            ins.refreshTextStyleControls()
            wc.canvasView?.needsDisplay = true
            log("改后 fontSize=\(layer.fontSize) textColor=\(layer.textColor) "
                + "面板字号框=\(ins.fontSizeField.stringValue) 面板HEX=\(ins.colorHexField.stringValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                capture("tr023b_3b_改字号与颜色后.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { readonlyShot() }
            }
        }
    }

    // MARK: - 2. 只读态：.moti 预览（控件可见但全灰，发布列已移除）
    static func readonlyShot() {
        if motiPath.isEmpty {
            log("没给 moti 路径，跳过只读态")
            finish()
            return
        }
        log("进入只读预览: \(motiPath)")
        wc.previewMotiInDesigner(path: motiPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let ins = self.wc.inspectorView {
                let hasPublish = (ins.layerTableView?.tableColumns.contains { $0.identifier.rawValue == "pub" }) ?? false
                self.log("只读态: motiReadOnlyMode=\(ins.motiReadOnlyMode) 发布列存在=\(hasPublish) "
                         + "字号控件可见=\(!ins.fontSizeField.isHidden) 可编辑=\(ins.fontSizeField.isEnabled)")
                self.log("只读态面板: 字号=\(ins.fontSizeField.stringValue) 字体=\(ins.fontNameLabel.stringValue) "
                         + "HEX=\(ins.colorHexField.stringValue)")
            }
            self.capture("tr023b_2_只读态灰掉无发布列.png")
            self.finish()
        }
    }

    static func finish() {
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.wc?.close()
            exit(0)
        }
    }

    // MARK: - 截图（真实屏幕像素；失败时退回窗口自绘缓存）
    static func capture(_ name: String) {
        guard let window = wc.window else { return }
        let path = outDir + "/" + name
        let wid = window.windowNumber
        // 用系统 screencapture 抓指定窗口（真实屏幕像素，非离屏渲染）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(wid)", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("screencapture 启动失败: \(error.localizedDescription)")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 2_000 {
            log("截图 \(name)  \(size) B  (window id \(wid))")
            return
        }
        // 退回：窗口内容自绘缓存（仍在真实窗口坐标系内）
        if let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                log("截图 \(name)  \(data.count) B  (contentView 缓存回退)")
                return
            }
        }
        log("截图失败 \(name)")
    }
}
