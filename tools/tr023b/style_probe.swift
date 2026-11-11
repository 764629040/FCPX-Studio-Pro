// ═══════════════════════════════════════════════════════════════════════════
// tools/tr023b/style_probe.swift
// TR-023-B：文字样式四项（字号 / 对齐 / 颜色 / 字体名）只读取值探针
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr023b/style_probe.swift -o /tmp/tr023b_probe
// 运行：/tmp/tr023b_probe <a.moti> [b.moti ...]
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

@main
struct StyleProbe {
    static func main() {
        let files = Array(CommandLine.arguments.dropFirst())
        guard !files.isEmpty else {
            print("用法: tr023b_probe <a.moti> [...]")
            exit(2)
        }
        for path in files {
            let snapshot = MotiDocumentParser.parse(path: path)
            print("== \(path)")
            print("   valid=\(snapshot.isValid) layers=\(snapshot.layers.count)")
            let models = MotiDocumentParser.toLayerModels(snapshot)
            var printed = 0
            for layer in snapshot.layers {
                let hasText = !layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasStyle = !layer.fontName.isEmpty || layer.fontSize > 0
                    || !layer.alignment.isEmpty || !layer.textColor.isEmpty
                guard hasText || hasStyle else { continue }
                print("   #\(layer.index) \(layer.name) text=\(hasText ? "Y" : "N")"
                      + " | font=\(layer.fontName.isEmpty ? "-" : layer.fontName)"
                      + " | size=\(layer.fontSize) | align=\(layer.alignment.isEmpty ? "-" : layer.alignment)"
                      + " | color=\(layer.textColor.isEmpty ? "-" : layer.textColor)"
                      + " | src=\(layer.colorSourcePath.isEmpty ? "-" : layer.colorSourcePath)")
                printed += 1
                if printed >= 12 { break }
            }
            if printed == 0 { print("   （没有任何层取到文字样式）") }
            if let first = models.first {
                print("   → LayerModel[0] font=\(first.fontName.isEmpty ? "-" : first.fontName)"
                      + " size=\(first.fontSize) align=\(first.alignment.isEmpty ? "-" : first.alignment)"
                      + " color=\(first.textColor.isEmpty ? "-" : first.textColor) locked=\(first.isLocked)")
            }
        }
    }
}
