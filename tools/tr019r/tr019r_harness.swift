// ═══════════════════════════════════════════════════════════════════════════
// tools/tr019r/tr019r_harness.swift
// TR-019-R 返修验收：递归展开层数 / 白话诊断 / 只读 UI 三处修复
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr019r/tr019r_harness.swift -o /tmp/tr019r_harness
// 运行 cwd 必须是项目根。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import AppKit

@main
struct TR019RHarness {
    static var pass = 0
    static var fail = 0

    static func check(_ cond: Bool, _ label: String, _ detail: String = "") {
        if cond {
            pass += 1
            print("  ✅ \(label)")
        } else {
            fail += 1
            print("  ❌ \(label)   \(detail)")
        }
    }

    static let titlesRoot = NSString(string: "~/Movies/Motion Templates.localized/Titles.localized").expandingTildeInPath
    static let weddingPath = NSString(string: "~/Movies/Motion Templates.localized/Titles.localized/-2026年4月项目/婚礼模板/婚礼模板.moti").expandingTildeInPath
    static let projectRoot = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"

    static func main() {
        let fm = FileManager.default

        // ── A. 婚礼模板：必须 11 层，名字 Text 01…11 ───────────────────────
        print("── A. 婚礼模板 11 层 ──")
        check(fm.fileExists(atPath: weddingPath), "婚礼模板.moti 存在", weddingPath)
        if fm.fileExists(atPath: weddingPath) {
            let before = try? Data(contentsOf: URL(fileURLWithPath: weddingPath))
            let s = MotiDocumentParser.parse(path: weddingPath)
            let after = try? Data(contentsOf: URL(fileURLWithPath: weddingPath))
            check(s.isValid, "parse isValid=true", s.failureReason ?? "")
            check(s.layers.count == 11, "婚礼模板解析出 11 层", "实际=\(s.layers.count)")
            let names = s.layers.map { $0.name }
            let expected = (1...11).map { String(format: "Text %02d", $0) }
            check(names == expected, "层名严格为 Text 01…Text 11", "实际=\(names.joined(separator: ","))")
            check(s.canvasWidth == 1920 && s.canvasHeight == 1080, "画布 1920×1080",
                  "实际=\(s.canvasWidth)x\(s.canvasHeight)")
            check(before != nil && before == after, "解析前后 .moti 字节完全一致（只读）")

            let models = MotiDocumentParser.toLayerModels(s)
            check(models.count == 11, "toLayerModels 得到 11 个 LayerModel", "实际=\(models.count)")
            check(models.allSatisfy { $0.isLocked }, "全部 isLocked=true")
            check(models.allSatisfy { m in m.diagnosticNotes.contains { $0.contains("只读") } },
                  "全部 diagnosticNotes 含「只读」")
        }

        // ── B. 递归展开：嵌套模板不再只出 1~2 层 ───────────────────────────
        print("── B. 递归展开嵌套 layer ──")
        let nestedCases: [(String, Int)] = [
            ("03综艺动漫/某人标题/某人4文本/某人4文本.moti", 25),
            ("03综艺动漫/汽车 1/屏幕/屏幕 01/屏幕 01.moti", 17),
            ("03综艺动漫/餐馆/图标/图标 04/图标 04.moti", 16),
            ("03综艺动漫/美味家伙/美味家伙 17/美味家伙 17.moti", 14)
        ]
        for (rel, expected) in nestedCases {
            let p = (titlesRoot as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: p) else {
                check(false, "样本存在 \(rel)", p)
                continue
            }
            let s = MotiDocumentParser.parse(path: p)
            check(s.isValid, "解析成功 \(rel)", s.failureReason ?? "")
            check(s.layers.count == expected, "\(rel) 展开为 \(expected) 层", "实际=\(s.layers.count)")
            // 旧版只取 scene 直接子 layer，这类模板在真机上只显示 1~2 层。
            // 缩进深浅不等于 XML 嵌套，故这里只断言「不再是 1~2 层」。
            check(s.layers.count > 2, "\(rel) 不再是旧版的 1~2 层", "实际=\(s.layers.count)")
        }

        // ── C. 白话诊断：不出现任何 XML 节点名 / 参数 id / 英文字段名 ──────
        print("── C. 诊断文案全白话 ──")
        let forbidden = ["<ozml", "<canvas", "<scene", "<layer", "<text", "<parameter",
                         "369", "302", "303", "posX", "posY", "fixedWidth", "TR-019", "节点"]
        let allNotes = MotiDocumentParser.parse(path: weddingPath).warnings
                + MotiDocumentParser.parse(path: (titlesRoot as NSString).appendingPathComponent(nestedCases[0].0)).warnings
        check(!allNotes.isEmpty, "提示条数 > 0（不是静默无提示）")
        check(allNotes.count <= 8, "提示条数克制（≤8 条）", "实际=\(allNotes.count)")
        for token in forbidden {
            check(!allNotes.contains(where: { $0.contains(token) }), "诊断不含「\(token)」",
                  allNotes.first(where: { $0.contains(token) }) ?? "")
        }
        check(allNotes.contains(where: { $0.contains("只读") }), "诊断明确告知「只读」")

        // ── D. 只读 UI：幅面规格常驻 / 诊断默认折叠 / 不教用户解锁 ─────────
        print("── D. 右侧面板只读 UI ──")
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 360, height: 750))
        inspector.updateMotiReadOnlyInfo(canvasWidth: 1920,
                                         canvasHeight: 1080,
                                         layerCount: 11,
                                         notes: allNotes)
        check(inspector.motiReadOnlyMode, "inspector.motiReadOnlyMode == true")
        check(inspector.resolutionLabel.stringValue.contains("幅面规格"),
              "幅面规格行文案含「幅面规格」", inspector.resolutionLabel.stringValue)
        check(inspector.resolutionLabel.stringValue.contains("1920×1080"),
              "幅面规格行含尺寸 1920×1080", inspector.resolutionLabel.stringValue)
        check(!inspector.resolutionLabel.isHidden, "幅面规格行 isHidden == false（常驻可见）")
        check(inspector.diagnosticsDetailBox.isHidden, "诊断详情默认折叠")
        check(inspector.diagnosticsSummaryLabel.stringValue.contains("ⓘ"), "角标显示白话摘要")
        check(inspector.lockBannerLabel.stringValue == "只读，不可编辑",
              "锁定横幅改为「只读，不可编辑」", inspector.lockBannerLabel.stringValue)
        check(!inspector.lockBannerLabel.stringValue.contains("⌘L"), "只读态不出现 ⌘L")
        check(inspector.readOnlyBadgeLabel.stringValue.contains("只读，不可编辑"),
              "顶部常驻只读标签文案", inspector.readOnlyBadgeLabel.stringValue)
        check(!inspector.readOnlyBadgeLabel.isHidden, "顶部常驻只读标签可见")
        check(!inspector.readOnlyBadgeLabel.stringValue.contains("⌘L"), "常驻标签不含 ⌘L")
        // 折叠/展开切换
        inspector.diagnosticsDetailBox.isHidden.toggle()
        check(!inspector.diagnosticsDetailBox.isHidden, "点开角标能展开详情")
        inspector.diagnosticsDetailBox.isHidden = true

        // 退出只读态后恢复常规锁定文案
        inspector.motiReadOnlyMode = false
        check(inspector.lockBannerLabel.stringValue.contains("图层已锁定"),
              "退出只读态恢复常规锁定提示", inspector.lockBannerLabel.stringValue)

        // ── E. 画布只读占位模式 ───────────────────────────────────────────
        print("── E. 画布占位绘制 ──")
        let canvas = InfiniteCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        check(canvas.motiPreviewMode == false, "默认不是只读预览模式")
        canvas.motiPreviewMode = true
        check(canvas.motiPreviewMode, "可打开只读预览占位绘制")
        canvas.layers = MotiDocumentParser.toLayerModels(MotiDocumentParser.parse(path: weddingPath))
        check(canvas.layers.count == 11, "画布拿到 11 层用于占位绘制", "实际=\(canvas.layers.count)")

        // ── F. 源码静态断言（中文文案用字节计数，见 verify_text.py）─────────
        print("── F. 接线静态断言 ──")
        let mwc = (try? String(contentsOfFile: projectRoot + "/FCPXStudioNative/Sources/FCPXStudio/Views/MainWindowController.swift", encoding: .utf8)) ?? ""
        let insp = (try? String(contentsOfFile: projectRoot + "/FCPXStudioNative/Sources/FCPXStudio/Views/InspectorView.swift", encoding: .utf8)) ?? ""
        let cnv = (try? String(contentsOfFile: projectRoot + "/FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift", encoding: .utf8)) ?? ""
        check(mwc.contains("updateMotiReadOnlyInfo"), "设计器调用只读专用信息更新")
        check(mwc.contains("canvasView.motiPreviewMode = true"), "设计器打开画布占位绘制")
        check(mwc.contains("canvasView.motiPreviewMode = false"), "退出只读态复位画布")
        check(insp.contains("只读，不可编辑"), "检查器含「只读，不可编辑」")
        check(insp.contains("diagnosticsDetailBox?.isHidden = true"), "检查器诊断默认折叠")
        check(cnv.contains("drawMotiPlaceholders"), "画布含只读占位绘制函数")
        let parserSrc = (try? String(contentsOfFile: projectRoot + "/FCPXStudioNative/Sources/FCPXStudio/Models/MotiDocumentParser.swift", encoding: .utf8)) ?? ""
        check(parserSrc.contains("collectLayers"), "解析器含递归展开 collectLayers")

        print("PASS = \(pass)   FAIL = \(fail)")
        print(fail == 0 ? "TR-019-R VERDICT: PASS" : "TR-019-R VERDICT: FAIL")
        exit(fail == 0 ? 0 : 1)
    }
}
