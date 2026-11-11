// ═══════════════════════════════════════════════════════════════════════════
// tools/tr023b/style_coverage.swift
// TR-023-B：全库文字样式取到率统计（只读，用于验收「每个属性实际取到哪个路径」）
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr023b/style_coverage.swift -o /tmp/tr023b_coverage
// 运行：/tmp/tr023b_coverage > reports/verify_tr023b/style_coverage.txt
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

@main
struct StyleCoverage {

    static func main() {
        let root = (NSString(string: "~/Movies/Motion Templates.localized/Titles.localized")
            .expandingTildeInPath as NSString)
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root as String) else {
            print("目录读不到: \(root)")
            exit(2)
        }
        var files: [String] = []
        for case let rel as String in en where rel.hasSuffix(".moti") {
            files.append((root as String) + "/" + rel)
        }
        files.sort()

        var templates = 0
        var parseOK = 0
        var totalLayers = 0

        var fontTemplates = 0, fontLayers = 0
        var sizeTemplates = 0, sizeLayers = 0
        var alignTemplates = 0, alignLayers = 0
        var alignCounts: [String: Int] = [:]
        var colorTemplates = 0, colorLayers = 0
        var colorBySourceTemplates: [String: Int] = [:]
        var colorBySourceLayers: [String: Int] = [:]
        var sizeValues: [Double] = []

        let started = Date()
        for (i, path) in files.enumerated() {
            templates += 1
            if i % 100 == 0 {
                FileHandle.standardError.write("[\(i)/\(files.count)]\r".data(using: .utf8)!)
            }
            let snapshot = MotiDocumentParser.parse(path: path)
            guard snapshot.isValid else { continue }
            parseOK += 1

            var tplHasFont = false, tplHasSize = false, tplHasAlign = false
            var tplColorSource: String?
            for layer in snapshot.layers {
                totalLayers += 1
                if !layer.fontName.isEmpty { fontLayers += 1; tplHasFont = true }
                if layer.fontSize > 0 {
                    sizeLayers += 1; tplHasSize = true; sizeValues.append(layer.fontSize)
                }
                if !layer.alignment.isEmpty {
                    alignLayers += 1; tplHasAlign = true
                    alignCounts[layer.alignment, default: 0] += 1
                }
                if !layer.textColor.isEmpty {
                    colorLayers += 1
                    colorBySourceLayers[layer.colorSourcePath, default: 0] += 1
                    // 模板级按优先级只记第一个命中的源
                    if tplColorSource == nil { tplColorSource = layer.colorSourcePath }
                }
            }
            if tplHasFont { fontTemplates += 1 }
            if tplHasSize { sizeTemplates += 1 }
            if tplHasAlign { alignTemplates += 1 }
            if let src = tplColorSource {
                colorTemplates += 1
                colorBySourceTemplates[src, default: 0] += 1
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        func pct(_ n: Int, _ d: Int) -> String {
            guard d > 0 else { return "0.0%" }
            return String(format: "%.1f%%", Double(n) * 100.0 / Double(d))
        }

        var out: [String] = []
        out.append("TR-023-B 文字样式取到率（全库只读统计）")
        out.append(String(repeating: "=", count: 72))
        out.append("生成时间      \(ISO8601DateFormatter().string(from: Date()))")
        out.append("库根目录      \(root as String)")
        out.append("模板文件      \(templates) 个（解析成功 \(parseOK)）")
        out.append("层总数        \(totalLayers)（MotiDocumentParser 展开后的 layer 数）")
        out.append(String(format: "耗时          %.1f s（单次墙钟）", elapsed))
        out.append("")
        out.append("■ 模板级取到率（分母 = 解析成功的 \(parseOK) 个模板）")
        out.append(String(repeating: "-", count: 72))
        out.append("属性        命中模板    取到率")
        out.append("字体名      \(pad(fontTemplates))    \(pct(fontTemplates, parseOK))")
        out.append("字号        \(pad(sizeTemplates))    \(pct(sizeTemplates, parseOK))")
        out.append("对齐        \(pad(alignTemplates))    \(pct(alignTemplates, parseOK))")
        out.append("文字颜色    \(pad(colorTemplates))    \(pct(colorTemplates, parseOK))")
        out.append("")
        out.append("■ 层级取到率（分母 = \(totalLayers) 层）")
        out.append(String(repeating: "-", count: 72))
        out.append("字体名      \(pad(fontLayers))    \(pct(fontLayers, totalLayers))")
        out.append("字号        \(pad(sizeLayers))    \(pct(sizeLayers, totalLayers))")
        out.append("对齐        \(pad(alignLayers))    \(pct(alignLayers, totalLayers))")
        out.append("文字颜色    \(pad(colorLayers))    \(pct(colorLayers, totalLayers))")
        out.append("")
        out.append("■ 每个属性实际取自哪条路径")
        out.append(String(repeating: "-", count: 72))
        out.append("字体名  style/Font（<font> 文本） 或 style/字体")
        out.append("字号    style/Size 或 style/大小（@value，缺则 <curve>@value）")
        out.append("对齐    paragraphStyle/Alignment|对齐 → 再退 对象/段落/段落/对齐")
        out.append("颜色    按下列优先级，命中即停（禁止 物质/颜色 与 Object/Basic/Substance/Color）")
        let order = ["Face/Color", "面/颜色", "表面/颜色", "渐变首色标"]
        for name in order {
            let t = colorBySourceTemplates[name] ?? 0
            let l = colorBySourceLayers[name] ?? 0
            out.append("        \(padCJK(name, 12)) 模板 \(pad(t, 5))  层 \(pad(l, 6))")
        }
        out.append("")
        out.append("■ 颜色禁用态（按优先级一条都没命中 → 面板禁用 + 空态）")
        out.append(String(repeating: "-", count: 72))
        let disabled = parseOK - colorTemplates
        out.append("禁用模板数  \(pad(disabled))    \(pct(disabled, parseOK))")
        out.append("禁用层数    \(pad(totalLayers - colorLayers))    \(pct(totalLayers - colorLayers, totalLayers))")
        out.append("")
        out.append("■ 对齐三档分布（层级，仅统计有值的层）")
        out.append(String(repeating: "-", count: 72))
        for key in ["left", "center", "right"] {
            let n = alignCounts[key] ?? 0
            out.append("\(padCJK(key, 8))  \(pad(n))    \(pct(n, alignLayers))")
        }
        out.append("")
        out.append("■ 字号值域（仅统计取到值的层）")
        out.append(String(repeating: "-", count: 72))
        if sizeValues.isEmpty {
            out.append("（无）")
        } else {
            let sorted = sizeValues.sorted()
            out.append(String(format: "最小 %.1f   中位 %.1f   最大 %.1f",
                              sorted.first ?? 0,
                              sorted[sorted.count / 2],
                              sorted.last ?? 0))
        }
        out.append("")
        out.append("说明：本表是 Swift 侧实际取到的值（UI 显示什么就统计什么），")
        out.append("      与阶段 1（tools/tr023/attr_coverage.py，scenenode 级）口径不同：")
        out.append("      阶段 1 数「最内层文字对象」，本表数「MotiDocumentParser 展开的 layer」。")
        out.append("      两者分母相同（库内模板），数字接近但不要求逐位相等。")
        print(out.joined(separator: "\n"))
    }

    static func pad(_ n: Int, _ width: Int = 6) -> String {
        let s = String(n)
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }

    /// 按东亚宽度补空格，让中文路径在等宽终端里对齐。
    static func padCJK(_ s: String, _ width: Int) -> String {
        var w = 0
        for ch in s.unicodeScalars {
            w += (ch.value >= 0x1100 && (ch.value <= 0x115F || ch.value >= 0x2E80)) ? 2 : 1
        }
        return s + String(repeating: " ", count: max(0, width - w))
    }
}
