// R32 / A-66 UI 离屏渲染直证：不依赖锁屏/用户会话可见性。
// 用假三级根目录渲染 AssetHubView，导出 PNG 供人工核对列布局。
//
// 编译：见 docs/r32_evidence/run_a66_ui_harness.sh

import AppKit

@main
struct R32UIHarness {
    static func main() {
        let fm = FileManager.default
        let root = fm.currentDirectoryPath
        let tmp = NSTemporaryDirectory() + "r32_ui_harness_\(getpid())"
        try? fm.createDirectory(atPath: tmp + "/Titles.localized", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: tmp + "/builtin_root/Titles.localized", withIntermediateDirectories: true)

        // 扫描对象是 Titles.localized 下的一级目录（= 模板组）
        makeDirWithFile("\(tmp)/Titles.localized/UserTemplateA", marker: "a")
        makeDirWithFile("\(tmp)/Titles.localized/UserTemplateB", marker: "b")
        let extDir = "\(tmp)/external/UserTemplateC"
        try? fm.createDirectory(atPath: extDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: "\(tmp)/Titles.localized/UserTemplateC",
                                   withDestinationPath: extDir)
        makeDirWithFile("\(tmp)/builtin_root/Titles.localized/BuiltinTemplateX", marker: "x")

        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tmp, 1)
        setenv("FCPXSTUDIO_SYSTEM_TEMPLATES_ROOT", "\(tmp)/system_missing", 1)
        setenv("FCPXSTUDIO_BUILTIN_TEMPLATES_ROOT", "\(tmp)/builtin_root", 1)

        let view = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1180, height: 520))
        view.wantsLayer = true

        // NSTableView 只有挂在 window 上才会生成行视图；用不显示的离屏 window
        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.layoutIfNeeded()
        view.refreshList()
        view.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("FAIL bitmapImageRepForCachingDisplay")
            exit(2)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = "\(root)/docs/r32_evidence/a66_engine2_offscreen.png"
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL png encode")
            exit(2)
        }
        fm.createFile(atPath: out, contents: png)
        print("WROTE \(out) bytes=\(png.count) items=\(view.plugins.count)")

        // 结构断言：列宽与统计条
        for col in view.pluginTableView.tableColumns {
            let id = col.identifier.rawValue
            print("COL \(id) width=\(Int(col.width))")
            if id == "tier" { assert(col.width >= 120, "归属列必须加宽") }
            if id == "action" { assert(col.width <= 80, "操作列必须收窄") }
        }
        print("STATS \(view.tierStatsLabel.stringValue)")
        for it in view.allItems {
            print("ITEM \(it.name) tier=\(it.tier.rawValue) symlink=\(it.isSymlink) sizeMB=\(it.sizeMB)")
        }
        try? fm.removeItem(atPath: tmp)
        exit(0)
    }

    static func makeDirWithFile(_ path: String, marker: Character) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        let data = Data(repeating: marker.utf8.first ?? UInt8(ascii: "x"), count: 8192)
        fm.createFile(atPath: "\(path)/\(marker).dat", contents: data)
        // 放大到 ~2MB 让体积列有内容
        let big = Data(count: 2 * 1024 * 1024)
        fm.createFile(atPath: "\(path)/payload.bin", contents: big)
    }
}
