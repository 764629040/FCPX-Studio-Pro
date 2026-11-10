// ═══════════════════════════════════════════════════════════════════════════
// tools/tr019_harness.swift
// TR-019 阶段一：.moti 只读解析层验证（解析正确性 + 不写回硬断言 + 坏文件容错）
//
// 编译（zsh 必须用 ${=FILES} 拆分，全量源码 + 本 harness，排除 main.swift 防止双 @main）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr019_harness.swift -o /tmp/tr019_harness 2>&1 | head -60
//
// 运行：
//   /tmp/tr019_harness
//
// 【运行 cwd 必须是项目根】
//   /Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro
//   原因：源码字符串只读检查用相对路径 FCPXStudioNative/.../MotiDocumentParser.swift，
//   以及兜底样本路径也相对 cwd。样本主路径用外置卷绝对路径常量，见 kSamplePath。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import Darwin

@main
struct TR019Harness {

    /// 样本 .moti（外置卷绝对路径）。若卷路径失效，main() 会按 cwd 相对路径兜底。
    static let kSamplePath = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/build_staging/T01_领衔呈现_竖版/T01_领衔呈现_竖版.moti"
    static let kParserSourcePath = "FCPXStudioNative/Sources/FCPXStudio/Models/MotiDocumentParser.swift"

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

    static func main() {
        let fm = FileManager.default

        // 样本路径：绝对路径常量优先，cwd 相对路径兜底
        var samplePath = kSamplePath
        if !fm.fileExists(atPath: samplePath) {
            let fallback = fm.currentDirectoryPath
                + "/build_staging/T01_领衔呈现_竖版/T01_领衔呈现_竖版.moti"
            if fm.fileExists(atPath: fallback) {
                samplePath = fallback
            }
        }
        check(fm.fileExists(atPath: samplePath), "样本 .moti 存在", samplePath)

        // ── 只读硬断言基线：解析前先取一份字节 ──
        let before = try? Data(contentsOf: URL(fileURLWithPath: samplePath))
        let snapshot = MotiDocumentParser.parse(path: samplePath)
        let after = try? Data(contentsOf: URL(fileURLWithPath: samplePath))

        // 1. 基本解析
        check(snapshot.isValid, "parse 返回 isValid=true", snapshot.failureReason ?? "无 failureReason")
        check(snapshot.ozmlVersion == "5.14", "ozmlVersion == 5.14", "实际=\(snapshot.ozmlVersion)")
        check(snapshot.layers.count == 8, "layers.count == 8", "实际=\(snapshot.layers.count)")

        // 2. 首层断言
        if let first = snapshot.layers.first {
            check(first.name == "Text 01", "layers[0].name == Text 01", "实际=\(first.name)")
            check(first.id == "3000100", "layers[0].id == 3000100", "实际=\(first.id)")
            check(first.text.contains("领") && first.text.contains("现") && first.text.contains("\n"),
                  "layers[0].text 含「领」「现」且保留换行",
                  "实际=\(first.text.debugDescription)")
            check(abs(first.posX - (-213.0)) <= 0.01, "layers[0].posX ≈ -213.0", "实际=\(first.posX)")
            check(abs(first.posY - 484.5) <= 0.01, "layers[0].posY ≈ 484.5", "实际=\(first.posY)")
        } else {
            check(false, "layers[0] 可读", "layers 为空")
        }

        // 3. 第二层英文文本
        if snapshot.layers.count > 1 {
            let second = snapshot.layers[1]
            check(second.text.contains("presentation"), "layers[1].text 含 presentation",
                  "实际=\(second.text.debugDescription)")
        } else {
            check(false, "layers[1] 可读", "layers 不足 2 个")
        }

        // 4. 映射 LayerModel：数量 / 强制锁定 / 只读标记
        let models = MotiDocumentParser.toLayerModels(snapshot)
        check(models.count == 8, "toLayerModels(snapshot).count == 8", "实际=\(models.count)")
        check(models.allSatisfy { $0.isLocked }, "所有 LayerModel 的 isLocked == true")
        check(models.allSatisfy { model in
            model.diagnosticNotes.contains { $0.contains("只读") }
        }, "所有 LayerModel 的 diagnosticNotes 含「只读」")

        // 5. 只读性硬断言：字节不变 + 文件仍存在
        check(before != nil && before == after, "解析前后 .moti 字节完全一致（只读）",
              "before=\(before?.count ?? -1) after=\(after?.count ?? -1)")
        check(fm.fileExists(atPath: samplePath), "解析后 .moti 文件仍存在", samplePath)

        // 6. 不写回断言：parser 源码里不得出现任何写文件调用
        if let sourceData = try? Data(contentsOf: URL(fileURLWithPath: kParserSourcePath)),
           let source = String(data: sourceData, encoding: .utf8) {
            let forbidden = ["write(", "removeItem", "createFile", "FileHandle(forWriting"]
            for token in forbidden {
                check(!source.contains(token), "parser 源码不含 \(token)")
            }
        } else {
            check(false, "能读取 parser 源码做静态检查", kParserSourcePath)
        }

        // 7. 坏文件容错：不存在的路径，必须 isValid=false 且不 crash
        let missingPath = fm.currentDirectoryPath + "/__tr019_no_such_file__.moti"
        let bad = MotiDocumentParser.parse(path: missingPath)
        check(!bad.isValid, "不存在路径 -> isValid=false", missingPath)
        check(bad.failureReason != nil, "不存在路径 -> failureReason 非空")
        check(bad.layers.isEmpty, "不存在路径 -> layers 为空")

        // 8. TR-019 接线静态断言：解析器必须真的接进设计器，且写回被硬阻断
        let mwcPath = "FCPXStudioNative/Sources/FCPXStudio/Views/MainWindowController.swift"
        let hubPath = "FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift"
        if let mwcData = try? Data(contentsOf: URL(fileURLWithPath: mwcPath)),
           let mwc = String(data: mwcData, encoding: .utf8),
           let hubData = try? Data(contentsOf: URL(fileURLWithPath: hubPath)),
           let hub = String(data: hubData, encoding: .utf8) {
            check(mwc.contains("onPreviewMotiInDesigner"), "MainWindowController 接线 onPreviewMotiInDesigner")
            check(mwc.contains("MotiDocumentParser.toLayerModels"), "设计器注入 MotiDocumentParser.toLayerModels")
            check(mwc.contains("motiReadOnlyMode"), "设计器维护 motiReadOnlyMode 只读态")
            check(mwc.contains("!self.motiReadOnlyMode"), "保存/导出入口有只读态硬阻断")
            check(mwc.contains("--preview-moti"), "提供 --preview-moti 自动化入口")
            check(hub.contains("在设计器中只读预览"), "素材库提供「在设计器中只读预览」菜单项")
            check(hub.contains("onPreviewMotiInDesigner?(path)"), "素材库把 .moti 路径传给设计器")
        } else {
            check(false, "能读取设计器 / 素材库源码做接线静态检查", "\(mwcPath) / \(hubPath)")
        }

        print("PASS = \(pass)   FAIL = \(fail)")
        print(fail == 0 ? "TR-019 VERDICT: PASS" : "TR-019 VERDICT: FAIL")
        exit(fail == 0 ? 0 : 1)
    }
}
