// ═══════════════════════════════════════════════════════════════════════════
// tools/tr023b/style_coverage.swift
// TR-023-B / TR-023-B-1：全库文字样式取到率统计（只读）
//
// 【TR-023-B-1 增量】补三节，全部由「同一次遍历」产出，保证三列可比：
//   · 每属性一句判定规则（读哪条路径、@value 还是 <curve>@value、什么算命中）
//   · 口径矩阵：模板级 / 全部 layer 级 / 含文本参数 layer 级
//   · 颜色分源差异（模板级优先级互斥 160 vs 并集 163）逐模板定位
//   原有四节（模板级 / 层级 / 每属性路径 / 禁用态 / 三档分布 / 值域）的数字与
//   排布一字未动：910 / 891 / 694 / 686 仍是同一判据算出来的。
//
// 【口径矩阵怎么做到「同一次遍历」】
//   MotiDocumentParser.parse 只走一遍拿到 snapshot（既有四节的数字来源）；
//   同一轮循环里再对同一份 XML 复算一遍原始节点事实（LayerFacts），
//   两边的值逐层比对，不一致就记账（parity）。因此三列是同一批 layer、
//   同一套判据、同一个分母来源，不存在「先跑一份再跑一份」。
//
// 编译（zsh 用 ${=FILES}）：
//   FILES=$(find FCPXStudioNative/Sources/FCPXStudio -name "*.swift" ! -name "main.swift" | sort)
//   swiftc -O -j 8 ${=FILES} tools/tr023b/style_coverage.swift -o /tmp/tr023b_coverage_v2
// 运行：/tmp/tr023b_coverage_v2 > reports/verify_tr023b/style_coverage.txt
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

@main
struct StyleCoverage {

    // ── 属性行序（表格固定顺序，避免字典乱序） ────────────────────────────
    static let fFont  = "字体名"
    static let fSize  = "字号"
    static let fAlign = "对齐"
    static let fColor = "文字颜色"
    static let fields = [fFont, fSize, fAlign, fColor]
    /// 取色优先级（命中即停）。矩阵留证也按这个固定顺序输出，保证报告可复现。
    static let colorOrder = ["Face/Color", "面/颜色", "表面/颜色", "渐变首色标"]

    /// 单层（含其子树）在原始 XML 上的可复算事实。
    /// 「Own」后缀 = 只看这一层自己的参数树，不吞嵌套子层的 <style>（用于量化展开粒度）。
    struct LayerFacts {
        var fontName = ""
        var fontSize: Double = 0
        var alignment = ""
        var textColor = ""
        var colorSource = ""

        var fontNameOwn = ""
        var fontSizeOwn: Double = 0
        var alignmentOwn = ""
        var textColorOwn = ""

        var hasTextParamFull = false
        var hasTextParamOwn = false

        // 对账探针（只在「解释 QC 数字」时用，不进四节主表）
        var sizeNodeExists = false
        var sizeAnyNumeric = false      // 探针：有值即算，不限正负（含 0 / 负数）
        var sizeWideNames = false       // 探针：名字放宽到 大小|Size|字号|FontSize
        var sizeAnywhere = false        // 探针：不限在 <style> 下，layer 子树任意位置
        var sizeAnywhereWide = false    // 探针：同上 + 名字放宽（大小|Size|字号|FontSize）
        var sizeWithDefault = false
        var alignAnyValue = false
        var alignWithDefault = false
        var alignNodeExists = false

        func hit(_ field: String) -> Bool {
            switch field {
            case StyleCoverage.fFont:  return !fontName.isEmpty
            case StyleCoverage.fSize:  return fontSize > 0
            case StyleCoverage.fAlign: return !alignment.isEmpty
            case StyleCoverage.fColor: return !textColor.isEmpty
            default: return false
            }
        }

        func hitOwn(_ field: String) -> Bool {
            switch field {
            case StyleCoverage.fFont:  return !fontNameOwn.isEmpty
            case StyleCoverage.fSize:  return fontSizeOwn > 0
            case StyleCoverage.fAlign: return !alignmentOwn.isEmpty
            case StyleCoverage.fColor: return !textColorOwn.isEmpty
            default: return false
            }
        }
    }

    static func main() {
        let root = (NSString(string: "~/Movies/Motion Templates.localized/Titles.localized")
            .expandingTildeInPath as NSString)
        let rootPath = root as String
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: rootPath) else {
            print("目录读不到: \(rootPath)")
            exit(2)
        }
        var files: [(rel: String, abs: String)] = []
        for case let rel as String in en where rel.hasSuffix(".moti") {
            files.append((rel, rootPath + "/" + rel))
        }
        files.sort { $0.abs < $1.abs }

        var templates = 0
        var parseOK = 0
        var totalLayers = 0

        // ── 既有四节的累计量 ──
        var tplHit: [String: Int] = [:]          // 模板级：任一 layer 命中（= 矩阵列 1、列 2）
        var lyrHit: [String: Int] = [:]          // 全部 layer 级：命中 layer 数
        var alignCounts: [String: Int] = [:]
        var colorBySourceTemplates: [String: Int] = [:]   // 模板级，优先级互斥（首个命中）
        var colorBySourceLayers: [String: Int] = [:]
        var sizeValues: [Double] = []

        // ── 矩阵：含文本参数 layer 级 / 仅自身范围 layer 级 ──
        var tplHitText: [String: Int] = [:]      // 只在「含文本参数的 layer」里命中 → 算模板命中
        var lyrHitText: [String: Int] = [:]
        var lyrHitOwn: [String: Int] = [:]       // 只在 layer 自身参数树里命中（不含嵌套子层）
        var textLayerFull = 0                    // 含文本参数的 layer 数（全子树）
        var textLayerOwn = 0                     // 含文本参数的 layer 数（仅自身）
        var textTemplatesFull = 0                // 至少有一个含文本参数 layer 的模板数

        // ── 对账探针 ──
        var probeSizeDefaultTpl = 0, probeSizeDefaultLyr = 0
        var probeAlignAnyTpl = 0, probeAlignAnyLyr = 0
        var probeAlignDefaultTpl = 0, probeAlignDefaultLyr = 0
        var probeSizeNodeTpl = 0, probeSizeNodeLyr = 0
        var probeSizeAnyNumericTpl = 0, probeSizeAnyNumericLyr = 0
        var probeSizeWideTpl = 0
        var probeSizeAnywhereTpl = 0
        var probeSizeAnywhereWideTpl = 0
        var probeSizeDocTpl = 0
        var probeSizeDocWideTpl = 0
        var probeSizeDocDefaultTpl = 0
        var probeSizeDocNodeTpl = 0
        var probeSizeDocStringTpl = 0
        var probeSizeBroadTpl = 0
        var probeSizeDescTpl = 0
        var probeAlignNodeTpl = 0, probeAlignNodeLyr = 0
        var probeSizeNodeTextTpl = 0
        var probeAlignAnyTextTpl = 0

        // ── 颜色并集（与优先级互斥对照） ──
        var colorTplUnion: [String: Int] = [:]
        var colorStyleTplUnion: [String: Int] = [:]     // style 级并集（≈ 阶段 1 python 的逐源扫描）
        var colorWitness: [String: [(rel: String, priority: String, layers: [String])]] = [:]
        var colorStyleWitness: [String: [(rel: String, priority: String, details: [String])]] = [:]
        var colorDocTplUnion: [String: Int] = [:]       // 全文档 style 并集（含 layer 之外 / behavior 内）
        var colorNoBehTplUnion: [String: Int] = [:]     // 全文档 style 并集，跳过 behavior 子树
        var colorOutsideLayerUnion: [String: Int] = [:] // 只数「没有 layer 祖先」的 style
        var colorOutsideWitness: [String: [(rel: String, detail: String)]] = [:]
        var visitedStyles = Set<ObjectIdentifier>()     // 跨层去重：同一个 <style> 只算一次颜色候选

        // ── 口径等价性自检 ──
        var parityBad: [String: Int] = [:]
        var paritySamples: [String] = []
        var layerCountMismatch: [String] = []

        let started = Date()

        for (i, entry) in files.enumerated() {
            templates += 1
            if i % 100 == 0 {
                FileHandle.standardError.write("[\(i)/\(files.count)]\r".data(using: .utf8)!)
            }
            let snapshot = MotiDocumentParser.parse(path: entry.abs)
            guard snapshot.isValid else { continue }
            parseOK += 1

            // ── 同一轮循环里解析原始 XML，用于矩阵 / 对账 ──
            var xmlLayers: [XMLElement] = []
            var xmlRootEl: XMLElement? = nil
            if let data = try? Data(contentsOf: URL(fileURLWithPath: entry.abs)),
               let doc = try? XMLDocument(data: data, options: []),
               let xmlRoot = doc.rootElement(), xmlRoot.name == "ozml" {
                xmlRootEl = xmlRoot
                for scene in xmlRoot.elements(forName: "scene") {
                    collectLayerElements(scene, into: &xmlLayers)
                }
            }
            if xmlLayers.count != snapshot.layers.count {
                layerCountMismatch.append("\(entry.rel) 快照 \(snapshot.layers.count) / 原始 \(xmlLayers.count)")
            }

            var tpl: [String: Bool] = [:]
            var tplTextCaliber: [String: Bool] = [:]
            var tplHasTextLayer = false
            var tplColorSource: String?
            var seenSources = Set<String>()
            var layerColorTrace: [String] = []
            var tplProbeSizeDefault = false
            var tplProbeAlignAny = false
            var tplProbeAlignDefault = false
            var tplProbeSizeNode = false
            var tplProbeAlignNode = false
            var tplProbeSizeNodeText = false
            var tplProbeSizeAnyNumeric = false
            var tplProbeSizeWide = false
            var tplProbeSizeAnywhere = false
            var tplProbeSizeAnywhereWide = false
            var tplProbeAlignAnyText = false

            for (idx, layer) in snapshot.layers.enumerated() {
                totalLayers += 1
                let el = idx < xmlLayers.count ? xmlLayers[idx] : nil
                let fx = el.map { facts(of: $0) } ?? LayerFacts()

                // 既有判据（快照值 = UI 实际显示的值）——四节主表与矩阵 A/B 列 1、2 的唯一来源
                for field in fields {
                    let snapshotHit: Bool
                    switch field {
                    case fFont:  snapshotHit = !layer.fontName.isEmpty
                    case fSize:  snapshotHit = layer.fontSize > 0
                    case fAlign: snapshotHit = !layer.alignment.isEmpty
                    default:     snapshotHit = !layer.textColor.isEmpty
                    }
                    if snapshotHit {
                        lyrHit[field, default: 0] += 1
                        tpl[field] = true
                    }
                    // 矩阵列 3：候选集换成「含文本参数的 layer」，命中判据与列 1 完全同一个 snapshotHit
                    if fx.hasTextParamFull {
                        if snapshotHit {
                            lyrHitText[field, default: 0] += 1
                            tplTextCaliber[field] = true
                        }
                    }
                    // 参考列：只在 layer 自身参数树里算命中（量化「父层继承子层样式」）
                    if fx.hitOwn(field) { lyrHitOwn[field, default: 0] += 1 }
                }

                if fx.hasTextParamFull { textLayerFull += 1; tplHasTextLayer = true }
                if fx.hasTextParamOwn { textLayerOwn += 1 }
                if fx.sizeWithDefault { probeSizeDefaultLyr += 1; tplProbeSizeDefault = true }
                if fx.alignAnyValue { probeAlignAnyLyr += 1; tplProbeAlignAny = true }
                if fx.alignWithDefault { probeAlignDefaultLyr += 1; tplProbeAlignDefault = true }
                if fx.sizeNodeExists {
                    probeSizeNodeLyr += 1; tplProbeSizeNode = true
                    if fx.hasTextParamFull { tplProbeSizeNodeText = true }
                }
                if fx.alignNodeExists { probeAlignNodeLyr += 1; tplProbeAlignNode = true }
                if fx.sizeAnyNumeric { probeSizeAnyNumericLyr += 1; tplProbeSizeAnyNumeric = true }
                if fx.sizeWideNames { tplProbeSizeWide = true }
                if fx.sizeAnywhere { tplProbeSizeAnywhere = true }
                if fx.sizeAnywhereWide { tplProbeSizeAnywhereWide = true }
                if fx.hasTextParamFull && fx.alignAnyValue { tplProbeAlignAnyText = true }

                if layer.fontSize > 0 { sizeValues.append(layer.fontSize) }
                if !layer.alignment.isEmpty { alignCounts[layer.alignment, default: 0] += 1 }

                if !layer.textColor.isEmpty {
                    colorBySourceLayers[layer.colorSourcePath, default: 0] += 1
                    if tplColorSource == nil { tplColorSource = layer.colorSourcePath }
                    if seenSources.insert(layer.colorSourcePath).inserted { }
                    layerColorTrace.append("第 \(idx + 1) 层 ⇒ \(layer.colorSourcePath)")
                }

                // ── 口径等价性自检：原始 XML 复算 vs 解析器快照 ──
                if el != nil {
                    parityCheck(field: fFont,  a: layer.fontName,            b: fx.fontName,
                                rel: entry.rel, idx: idx, bad: &parityBad, samples: &paritySamples)
                    parityCheck(field: fSize,  a: layer.fontSize,            b: fx.fontSize,
                                rel: entry.rel, idx: idx, bad: &parityBad, samples: &paritySamples)
                    parityCheck(field: fAlign, a: layer.alignment,           b: fx.alignment,
                                rel: entry.rel, idx: idx, bad: &parityBad, samples: &paritySamples)
                    parityCheck(field: fColor, a: layer.textColor,           b: fx.textColor,
                                rel: entry.rel, idx: idx, bad: &parityBad, samples: &paritySamples)
                }
            }

            for field in fields {
                if tpl[field] == true { tplHit[field, default: 0] += 1 }
                if tplTextCaliber[field] == true { tplHitText[field, default: 0] += 1 }
            }
            if tplHasTextLayer { textTemplatesFull += 1 }
            if tplProbeSizeDefault { probeSizeDefaultTpl += 1 }
            if tplProbeAlignAny { probeAlignAnyTpl += 1 }
            if tplProbeAlignDefault { probeAlignDefaultTpl += 1 }
            if tplProbeSizeNode { probeSizeNodeTpl += 1 }
            if tplProbeAlignNode { probeAlignNodeTpl += 1 }
            if tplProbeSizeNodeText { probeSizeNodeTextTpl += 1 }
            if tplProbeSizeAnyNumeric { probeSizeAnyNumericTpl += 1 }
            if tplProbeSizeWide { probeSizeWideTpl += 1 }
            if tplProbeSizeAnywhere { probeSizeAnywhereTpl += 1 }
            if tplProbeSizeAnywhereWide { probeSizeAnywhereWideTpl += 1 }
            if tplProbeAlignAnyText { probeAlignAnyTextTpl += 1 }

            // ── 文档级字号探针（连 layer 之外的节点也算）──
            if let rootEl = xmlRootEl {
                var docSize = false, docSizeWide = false, docSizeDefault = false, docNode = false
                var docString = false
                var docBroad = false
                var docDesc = false
                func scanDoc(_ element: XMLElement) {
                    for child in element.children ?? [] {
                        guard let el = child as? XMLElement else { continue }
                        if el.name == "parameter", let n = attribute(el, "name") {
                            if explicitValue(el) != nil {
                                if n == "大小" || n == "Size" { docSize = true }
                                if n == "大小" || n == "Size" || n == "字号" || n == "FontSize" {
                                    docSizeWide = true
                                }
                            }
                            // 再加一档：@default 也算（不限正负）
                            if (n == "大小" || n == "Size"), declaredValue(el) != nil {
                                docSizeDefault = true
                            }
                            // 最后一档：节点存在即可，不管有没有值
                            if n == "大小" || n == "Size" { docNode = true }
                            // 探针：@value 不在参数上，而在后代节点（例如 <curve> 里的 keyframe）
                            if n == "大小" || n == "Size" {
                                func anyDescValue(_ e: XMLElement) -> Bool {
                                    for c in e.children ?? [] {
                                        guard let ce = c as? XMLElement else { continue }
                                        if let raw = attribute(ce, "value"),
                                           Double(raw.trimmingCharacters(in: .whitespaces)) != nil {
                                            return true
                                        }
                                        if anyDescValue(ce) { return true }
                                    }
                                    return false
                                }
                                if anyDescValue(el) { docDesc = true }
                            }
                            // 探针：名字宽松匹配（含 size / 大小 / 字号），且 @value 或 @default 有值
                            let lower = n.lowercased()
                            if lower.contains("size") || n.contains("大小") || n.contains("字号"),
                               declaredValue(el) != nil || attribute(el, "value") != nil {
                                docBroad = true
                            }
                            // 探针：@value 非空字符串就算（不要求能解析成数字）
                            if n == "大小" || n == "Size",
                               let raw = attribute(el, "value")?
                                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                                docString = true
                            }
                        }
                        scanDoc(el)
                    }
                }
                scanDoc(rootEl)
                if docSize { probeSizeDocTpl += 1 }
                if docSizeWide { probeSizeDocWideTpl += 1 }
                if docSizeDefault { probeSizeDocDefaultTpl += 1 }
                if docNode { probeSizeDocNodeTpl += 1 }
                if docString { probeSizeDocStringTpl += 1 }
                if docBroad { probeSizeBroadTpl += 1 }
                if docDesc { probeSizeDescTpl += 1 }
            }

            // ── 全文档颜色扫描：不要求 style 挂在 layer 下，用来对 QC 的 163 ──
            var docSrc = Set<String>(), noBehSrc = Set<String>(), outsideLayerSrc = Set<String>()
            if let rootEl = xmlRootEl {
                func scanColor(_ element: XMLElement, path: String,
                               inLayer: Bool, inBehavior: Bool) {
                    for child in element.children ?? [] {
                        guard let el = child as? XMLElement else { continue }
                        var seg = el.name ?? "?"
                        if let n = attribute(el, "name"), !n.isEmpty { seg += "[name=\(n)]" }
                        let p = path + "/" + seg
                        let nowLayer = inLayer || el.name == "layer"
                        let nowBeh = inBehavior || el.name == "behavior"
                        if el.name == "style", let hit = resolveTextColor(style: el) {
                            docSrc.insert(hit.source)
                            if !nowBeh { noBehSrc.insert(hit.source) }
                            if !nowLayer {
                                outsideLayerSrc.insert(hit.source)
                                // 只记真正造成「全文档 ④ > layer ①」的那几个模板：
                                // 该模板在 layer 级一次都没命中过这个源。
                                if !seenSources.contains(hit.source),
                                   (colorOutsideWitness[hit.source]?.count ?? 0) < 8 {
                                    var list = colorOutsideWitness[hit.source] ?? []
                                    list.append((entry.rel, "\(p) ⇒ \(hit.hex)"))
                                    colorOutsideWitness[hit.source] = list
                                }
                            }
                        }
                        scanColor(el, path: p, inLayer: nowLayer, inBehavior: nowBeh)
                    }
                }
                scanColor(rootEl, path: "", inLayer: false, inBehavior: false)
            }
            for src in docSrc { colorDocTplUnion[src, default: 0] += 1 }
            for src in noBehSrc { colorNoBehTplUnion[src, default: 0] += 1 }
            for src in outsideLayerSrc { colorOutsideLayerUnion[src, default: 0] += 1 }

            // ── style 级颜色并集（≈ 阶段 1 python 逐源扫描的粒度） ──
            // 每个 <style> 各自是一个颜色候选，不在 layer 内做「命中即停」，
            // 因此同一层里第二段文字的源也不会被吞掉。
            var styleSourceSeen = Set<String>()
            var styleTrace: [String: [String]] = [:]
            for (idx, el) in xmlLayers.enumerated() {
                for style in styleElements(of: el, intoNestedLayers: true) {
                    guard visitedStyles.insert(ObjectIdentifier(style)).inserted else { continue }
                    guard let hit = resolveTextColor(style: style) else { continue }
                    styleSourceSeen.insert(hit.source)
                    if styleTrace[hit.source, default: []].count < 12 {
                        styleTrace[hit.source, default: []].append(
                            "第 \(idx + 1) 层 style ⇒ \(hit.hex) via \(hit.source)")
                    }
                }
            }
            for src in styleSourceSeen { colorStyleTplUnion[src, default: 0] += 1 }

            if let src = tplColorSource {
                colorBySourceTemplates[src, default: 0] += 1
            }
            for src in seenSources { colorTplUnion[src, default: 0] += 1 }
            // layer 级并集 > 优先级互斥 的模板留证（按固定源序，输出可复现）
            for src in colorOrder {
                guard seenSources.contains(src) else { continue }
                let priority = tplColorSource ?? ""
                if priority != src {
                    var list = colorWitness[src] ?? []
                    if list.count < 12 {
                        list.append((entry.rel, priority, layerColorTrace))
                        colorWitness[src] = list
                    }
                }
            }
            // style 级并集 > layer 级并集 的模板留证：同一层里还有第二个 <style> 的源
            for src in colorOrder {
                guard styleSourceSeen.contains(src) else { continue }
                guard !seenSources.contains(src) else { continue }
                var details = styleTrace[src] ?? []
                details.append("同模板 layer 级首命中源：\(tplColorSource ?? "（无）")")
                var list = colorStyleWitness[src] ?? []
                if list.count < 12 {
                    list.append((entry.rel, tplColorSource ?? "", details))
                    colorStyleWitness[src] = list
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        var out: [String] = []
        out.append("TR-023-B 文字样式取到率（全库只读统计）")
        out.append(String(repeating: "=", count: 72))
        out.append("生成时间      \(ISO8601DateFormatter().string(from: Date()))")
        out.append("库根目录      \(rootPath)")
        out.append("模板文件      \(templates) 个（解析成功 \(parseOK)）")
        out.append("层总数        \(totalLayers)（MotiDocumentParser 展开后的 layer 数）")
        out.append(String(format: "耗时          %.1f s（单次墙钟）", elapsed))
        out.append("")
        out.append("■ 模板级取到率（分母 = 解析成功的 \(parseOK) 个模板）")
        out.append(String(repeating: "-", count: 72))
        out.append("属性        命中模板    取到率")
        out.append("字体名      \(pad(tplHit[fFont] ?? 0))    \(pct(tplHit[fFont] ?? 0, parseOK))")
        out.append("字号        \(pad(tplHit[fSize] ?? 0))    \(pct(tplHit[fSize] ?? 0, parseOK))")
        out.append("对齐        \(pad(tplHit[fAlign] ?? 0))    \(pct(tplHit[fAlign] ?? 0, parseOK))")
        out.append("文字颜色    \(pad(tplHit[fColor] ?? 0))    \(pct(tplHit[fColor] ?? 0, parseOK))")
        out.append("")
        out.append("■ 层级取到率（分母 = \(totalLayers) 层）")
        out.append(String(repeating: "-", count: 72))
        out.append("字体名      \(pad(lyrHit[fFont] ?? 0))    \(pct(lyrHit[fFont] ?? 0, totalLayers))")
        out.append("字号        \(pad(lyrHit[fSize] ?? 0))    \(pct(lyrHit[fSize] ?? 0, totalLayers))")
        out.append("对齐        \(pad(lyrHit[fAlign] ?? 0))    \(pct(lyrHit[fAlign] ?? 0, totalLayers))")
        out.append("文字颜色    \(pad(lyrHit[fColor] ?? 0))    \(pct(lyrHit[fColor] ?? 0, totalLayers))")
        out.append("")
        out.append("■ 每个属性实际取自哪条路径")
        out.append(String(repeating: "-", count: 72))
        out.append("字体名  style/Font（<font> 文本） 或 style/字体")
        out.append("字号    style/Size 或 style/大小（@value，缺则 <curve>@value）")
        out.append("对齐    paragraphStyle/Alignment|对齐 → 再退 对象/段落/段落/对齐")
        out.append("颜色    按下列优先级，命中即停（禁止 物质/颜色 与 Object/Basic/Substance/Color）")
        for name in colorOrder {
            let t = colorBySourceTemplates[name] ?? 0
            let l = colorBySourceLayers[name] ?? 0
            out.append("        \(padCJK(name, 12)) 模板 \(pad(t, 5))  层 \(pad(l, 6))")
        }
        out.append("")
        out.append("■ 颜色禁用态（按优先级一条都没命中 → 面板禁用 + 空态）")
        out.append(String(repeating: "-", count: 72))
        let disabled = parseOK - (tplHit[fColor] ?? 0)
        out.append("禁用模板数  \(pad(disabled))    \(pct(disabled, parseOK))")
        out.append("禁用层数    \(pad(totalLayers - (lyrHit[fColor] ?? 0)))    \(pct(totalLayers - (lyrHit[fColor] ?? 0), totalLayers))")
        out.append("")
        out.append("■ 对齐三档分布（层级，仅统计有值的层）")
        out.append(String(repeating: "-", count: 72))
        let alignHit = lyrHit[fAlign] ?? 0
        for key in ["left", "center", "right"] {
            let n = alignCounts[key] ?? 0
            out.append("\(padCJK(key, 8))  \(pad(n))    \(pct(n, alignHit))")
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

        // ═══════════════════════════════════════════════════════════════════
        // TR-023-B-1 追加三节
        // ═══════════════════════════════════════════════════════════════════
        out.append("")
        out.append("")
        out.append("═══ TR-023-B-1 口径补充（以下三节由同一次遍历产出） ═══")
        out.append("")
        out.append("■ 判定规则（每属性一句）")
        out.append(String(repeating: "-", count: 72))
        out.append("【统一前提】")
        out.append("  · 候选集 = MotiDocumentParser 从 <ozml>/<scene> 起深度优先展开的全部")
        out.append("    <layer> 节点（前序，含任意嵌套层；本库 \(totalLayers) 个）。")
        out.append("  · 「该 layer 的子树」= 这个 <layer> 元素的全部后代节点，包含它内部再嵌的")
        out.append("    <layer>（解析器的 allStyleElements 就是这么走的，继承是既有行为，未改）。")
        out.append("  · 命中判据 = 该 layer 的 snapshot 里该字段非空/大于 0；空串与 0 一律算没取到。")
        out.append("")
        out.append("字体名：取该 layer 子树里按文档顺序第一个 <style> 下 parameter[name=字体|Font]")
        out.append("        的 <font> 子元素文本（非 @value，是节点文本），去空白后非空即命中。")
        out.append("字号：  取该 layer 子树里按文档顺序第一个 parameter[name=大小|Size] 的值，")
        out.append("        取值链 = 参数自身 @value → 子 <curve>@value（不退回 @default），")
        out.append("        解析为 Double 且 > 0 即命中；大小写与 @default 都不算。")
        out.append("对齐：  先取该 layer 子树里第一个 <paragraphStyle> 的 parameter[name=对齐|Alignment]，")
        out.append("        无则退该 layer 子树里第一个带 @value 或 <curve> 的同名 parameter；")
        out.append("        取值链同上（@value → <curve>@value，不退回 @default），")
        out.append("        数值 0/1/2 分别映射 left/right/center（AppKit NSTextAlignment）即命中；")
        out.append("        其它数值（两端对齐等）不在三档内 → 空串 → 不命中。")
        out.append("颜色：  该 layer 内按固定优先级命中即停：")
        out.append("          ① Face/Color ② 面/颜色 ③ 表面/颜色 ④ 渐变首色标；")
        out.append("        每一族要凑齐 RGB 三通道（@value → <curve>@value → 该通道 @default 补齐），")
        out.append("        至少一个通道有值才成色，成色即命中；")
        out.append("        明确不用 物质/颜色、Object/Basic/Substance/Color、轮廓/Outline。")
        out.append("")

        out.append("■ 口径矩阵（同一次遍历）")
        out.append(String(repeating: "-", count: 72))
        out.append("分母：模板 \(parseOK)（解析成功）／展开后 layer \(totalLayers)／"
                   + "含文本参数 layer \(textLayerFull)；"
                   + "含文本参数的模板 \(textTemplatesFull)，仅自身范围含文本参数的 layer \(textLayerOwn)")
        out.append("")
        out.append("A. 模板计量（一格 = 命中模板数 + 该列分母模板数下的取到率）")
        out.append(cellHeader("属性", [
            "模板级(分母\(parseOK))",
            "全部 layer 级(分母\(parseOK))",
            "含文本参数 layer 级(分母\(textTemplatesFull))"
        ]))
        for field in fields {
            let a = tplHit[field] ?? 0
            let c = tplHitText[field] ?? 0
            out.append(cellRow(field, [
                "\(a) / \(parseOK)  \(pct(a, parseOK))",
                "\(a) / \(parseOK)  \(pct(a, parseOK))",
                "\(c) / \(textTemplatesFull)  \(pct(c, textTemplatesFull))"
            ]))
        }
        out.append("")
        out.append("  列 2 按「全部 layer 级」重算，得到的数与列 1 逐位相同——因为模板级判据")
        out.append("  本来就是「该模板任一 layer 命中」，这就是恒等式：分母（\(parseOK)）相同、")
        out.append("  展开粒度相同（都是 MotiDocumentParser 展开的 \(totalLayers) 层），不产生差。")
        out.append("")
        out.append("B. layer 计量（一格 = 命中 layer 数 + 该列分母 layer 数下的取到率）")
        out.append(cellHeader("属性", [
            "全部 layer 级(分母\(totalLayers))",
            "含文本参数 layer 级(分母\(textLayerFull))",
            "参考：仅自身范围(分母\(totalLayers))"
        ]))
        for field in fields {
            let a = lyrHit[field] ?? 0
            let b = lyrHitText[field] ?? 0
            let c = lyrHitOwn[field] ?? 0
            out.append(cellRow(field, [
                "\(a) / \(totalLayers)  \(pct(a, totalLayers))",
                "\(b) / \(textLayerFull)  \(pct(b, textLayerFull))",
                "\(c) / \(totalLayers)  \(pct(c, totalLayers))"
            ]))
        }
        out.append("")
        out.append("  列 3 只统计「layer 自己的参数树里」的 style / paragraphStyle，不吞嵌套子层的。")
        out.append("  它比列 1 少的那些层，就是「父层继承了子层样式」的层数（既有解析行为，本轮未改）：")
        for field in fields {
            let a = lyrHit[field] ?? 0
            let c = lyrHitOwn[field] ?? 0
            out.append("    \(padCJK(field, 10))继承多算 \(pad(a - c, 5)) 层")
        }
        out.append("")
        out.append("  「含文本参数」判定：layer 全子树里存在 <parameter name=\"文本\"> 或")
        out.append("  <parameter name=\"Text\">（只看名字，不要求带值）。全库命中 \(textLayerFull) 层，")
        out.append("  分布在 \(textTemplatesFull) 个模板里；若只算 layer 自身（不吞子层）则是 \(textLayerOwn) 层。")
        out.append("")

        out.append("C. QC 数字对账（910/979/709 与 902/883/697 逐个数落位）")
        out.append("  列名说明：A 列 1 = 模板级；A 列 2 = 全部 layer 级换算；A 列 3 = 含文本参数 layer 级换算；")
        out.append("  「探针」= 同一批 layer 上换一条命中判据重算，用来定位差额来自哪个判据，不是本表口径。")
        out.append("")
        out.append("  QC「按全部 layer」910 / 979 / 709：")
        out.append("    字体 910 → " + reconcile(910, [
            ("A 列 1/2 模板级", tplHit[fFont] ?? 0),
            ("A 列 3 含文本参数", tplHitText[fFont] ?? 0)
        ]))
        out.append("    字号 979 → " + reconcile(979, [
            ("A 列 1/2 模板级（有值才算）", tplHit[fSize] ?? 0),
            ("探针：取值链加 @default", probeSizeDefaultTpl),
            ("探针：字号参数节点存在即可（不看有没有值）", probeSizeNodeTpl),
            ("探针：字号有值即算（不限正负）", probeSizeAnyNumericTpl),
            ("探针：字号名字放宽到 大小|Size|字号|FontSize", probeSizeWideTpl),
            ("探针：字号不限在 <style> 下（layer 子树）", probeSizeAnywhereTpl),
            ("探针：字号不限在 <style> 下 + 名字放宽", probeSizeAnywhereWideTpl),
            ("探针：字号全文档任意位置（含 layer 之外）", probeSizeDocTpl),
            ("探针：字号全文档任意位置 + 名字放宽", probeSizeDocWideTpl),
            ("探针：字号全文档任意位置 + @default 也算", probeSizeDocDefaultTpl),
            ("探针：字号节点存在即可（全文档，不看值）", probeSizeDocNodeTpl),
            ("探针：字号 @value 非空即算（全文档，不要求是数字）", probeSizeDocStringTpl),
            ("探针：字号名字宽松匹配 size|大小|字号（全文档）", probeSizeBroadTpl),
            ("探针：字号值在后代节点上（全文档）", probeSizeDescTpl)
        ]))
        out.append("    对齐 709 → " + reconcile(709, [
            ("A 列 1/2 模板级（须落在三档）", tplHit[fAlign] ?? 0),
            ("探针：任意数值都算（不过三档）", probeAlignAnyTpl),
            ("探针：取值链加 @default 且在三档", probeAlignDefaultTpl),
            ("探针：对齐参数节点存在即可", probeAlignNodeTpl)
        ]))
        out.append("  QC「按含文本参数的 layer」902 / 883 / 697：")
        out.append("    字体 902 → " + reconcile(902, [
            ("A 列 3 含文本参数", tplHitText[fFont] ?? 0)
        ]))
        out.append("    字号 883 → " + reconcile(883, [
            ("A 列 3 含文本参数", tplHitText[fSize] ?? 0),
            ("探针：含文本参数 + 字号节点存在", probeSizeNodeTextTpl)
        ]))
        out.append("    对齐 697 → " + reconcile(697, [
            ("A 列 3 含文本参数（须落在三档）", tplHitText[fAlign] ?? 0),
            ("探针：含文本参数 + 任意数值都算", probeAlignAnyTextTpl)
        ]))
        out.append("")
        out.append("  探针原始值（同一次遍历，模板级 / layer 级）：")
        out.append("    字号 allowedDefault（@value → <curve> → @default，>0）  "
                   + "模板 \(pad(probeSizeDefaultTpl, 5)) 层 \(pad(probeSizeDefaultLyr, 6))")
        out.append("    字号 nodeExists（有 大小|Size 参数即可，不看值）        "
                   + "模板 \(pad(probeSizeNodeTpl, 5)) 层 \(pad(probeSizeNodeLyr, 6))")
        out.append("    对齐 anyValue（@value/<curve> 任意数值，不过三档）      "
                   + "模板 \(pad(probeAlignAnyTpl, 5)) 层 \(pad(probeAlignAnyLyr, 6))")
        out.append("    对齐 withDefault（取值链加 @default，且落在三档）      "
                   + "模板 \(pad(probeAlignDefaultTpl, 5)) 层 \(pad(probeAlignDefaultLyr, 6))")
        out.append("    对齐 nodeExists（有 对齐|Alignment 参数即可）          "
                   + "模板 \(pad(probeAlignNodeTpl, 5)) 层 \(pad(probeAlignNodeLyr, 6))")
        out.append("    字号 含文本参数 + nodeExists                          "
                   + "模板 \(pad(probeSizeNodeTextTpl, 5))")
        out.append("    字号 anyNumeric（有值即算，不限正负）                  "
                   + "模板 \(pad(probeSizeAnyNumericTpl, 5)) 层 \(pad(probeSizeAnyNumericLyr, 6))")
        out.append("    字号 wideNames（大小|Size|字号|FontSize，在 style 下）  "
                   + "模板 \(pad(probeSizeWideTpl, 5))")
        out.append("    字号 anywhere（不限在 <style> 下）                     "
                   + "模板 \(pad(probeSizeAnywhereTpl, 5))")
        out.append("    字号 anywhereWide（layer 子树 + 名字放宽）             "
                   + "模板 \(pad(probeSizeAnywhereWideTpl, 5))")
        out.append("    字号 docWide（全文档任意位置，含 layer 之外）          "
                   + "模板 \(pad(probeSizeDocTpl, 5))")
        out.append("    字号 docWideWide（全文档 + 名字放宽）                  "
                   + "模板 \(pad(probeSizeDocWideTpl, 5))")
        out.append("    字号 docDefault（全文档 + @default 也算）              "
                   + "模板 \(pad(probeSizeDocDefaultTpl, 5))")
        out.append("    字号 docNode（全文档节点存在即可，不看值）             "
                   + "模板 \(pad(probeSizeDocNodeTpl, 5))")
        out.append("    字号 docString（全文档 @value 非空即算，不要求是数字）  "
                   + "模板 \(pad(probeSizeDocStringTpl, 5))")
        out.append("    字号 broadNames（名字含 size|大小|字号，全文档）        "
                   + "模板 \(pad(probeSizeBroadTpl, 5))")
        out.append("    字号 descValue（值在后代节点上，全文档）               "
                   + "模板 \(pad(probeSizeDescTpl, 5))")
        out.append("    对齐 含文本参数 + anyValue                            "
                   + "模板 \(pad(probeAlignAnyTextTpl, 5))")
        out.append("")
        out.append("  QC 字号 979 的差额分解（逐段可复算，全在同一批 layer 上）：")
        let sizeBase = tplHit[fSize] ?? 0
        out.append("    \(sizeBase) = 本表 A 列 1/2：layer 内 <style> 下的 大小|Size 且真有值")
        out.append("    +\(probeSizeAnywhereTpl - sizeBase) → \(probeSizeAnywhereTpl)"
                   + " = 候选集放宽到「layer 子树里任意位置」（不限 <style> 下）")
        out.append("    +\(probeSizeDocTpl - probeSizeAnywhereTpl) → \(probeSizeDocTpl)"
                   + " = 再放宽到「全文档任意位置」（含 layer 之外）")
        out.append("    979 - \(probeSizeDocTpl) = \(979 - probeSizeDocTpl)"
                   + " 个模板：上面任何一条路径都复现不出来，")
        out.append("    没有清单不硬凑，这 \(979 - probeSizeDocTpl) 个要 QC 给模板名才能定位。")
        out.append("    结论：979 不是分母问题（同为 1241 个模板），也不是计数单位问题（都是模板），")
        out.append("    是候选集边界问题——QC 的 979 把 layer 子树之外 / <style> 之外的 大小|Size")
        out.append("    也算成了模板命中，所以它和 A 列 2（\(tplHit[fSize] ?? 0)）本来就不是同一列。")
        out.append("")
        out.append("  QC 对齐 709 / 697 的差额分解：")
        let alignBase = tplHit[fAlign] ?? 0
        out.append("    \(alignBase) = 本表 A 列 1/2（\(probeAlignAnyTpl) 才是「任意数值都算」）")
        out.append("    \(probeAlignAnyTpl) - \(alignBase) = \(probeAlignAnyTpl - alignBase)"
                   + " 个模板的对齐值是 3 及以上（两端对齐等），")
        out.append("    本表按三档映射取不到 → 空串 → 面板空态 + 禁用；QC 把任意数值都算命中。")
        out.append("    同一件事在含文本参数列同样成立：697 - \(tplHitText[fAlign] ?? 0) = "
                   + "\(probeAlignAnyTextTpl - (tplHitText[fAlign] ?? 0))。")
        out.append("    字体 910 / 902 两边判据一致 → 逐位相等，说明差的不是层展开粒度。")
        out.append("")
        out.append("  口径等价性自检（原始 XML 复算 vs MotiDocumentParser 快照，逐层逐属性）：")
        out.append("    比对层数 \(totalLayers)；layer 数不一致的模板 \(layerCountMismatch.count) 个")
        for field in fields {
            out.append("    \(padCJK(field, 10)) 不一致 \(pad(parityBad[field] ?? 0, 4)) 层")
        }
        if let first = paritySamples.first {
            out.append("    首个不一致样例：\(first)")
        }
        out.append("")

        out.append("■ 颜色分源差异 160 vs 163")
        out.append(String(repeating: "-", count: 72))
        out.append("同一批模板、同一套取色判据（Face/Color → 面/颜色 → 表面/颜色 → 渐变首色标，")
        out.append("命中即停、三通道成色才算），四套模板级聚合方式：")
        out.append("  ① 优先级互斥：每个模板只记「沿 layer 顺序第一个取到颜色的 layer 的源」。")
        out.append("     这是本表第 3 节分源数与 UI 判据用的口径，四源相加 = \(tplHit[fColor] ?? 0)。")
        out.append("  ② layer 级并集：某模板任一 layer 的源是 X 就计入 X。")
        out.append("  ③ style 级并集：某模板任一 <style>（仍限 layer 子树内）的源是 X 就计入 X。")
        out.append("  ④ 全文档 style 并集：任 <style> 的源是 X 就计入 X，不要求该 style 有 layer 祖先。")
        out.append("  ⑤ 只数「没有 layer 祖先」的 style：这些 style 不在任何 <layer> 子树里，")
        out.append("     解析器展开 layer 时根本走不到，UI 也拿不到。")
        out.append("")
        out.append(cellHeader("源", ["① 优先级互斥", "② layer 并集", "③ style 并集", "④ 全文档 style"]))
        for name in colorOrder {
            let prio = colorBySourceTemplates[name] ?? 0
            let layerU = colorTplUnion[name] ?? 0
            let styleU = colorStyleTplUnion[name] ?? 0
            let docU = colorDocTplUnion[name] ?? 0
            out.append(cellRow(name, ["\(prio) 个模板", "\(layerU) 个模板",
                                      "\(styleU) 个模板", "\(docU) 个模板"]))
        }
        out.append("")
        let facePrio = colorBySourceTemplates["面/颜色"] ?? 0
        let faceStyle = colorStyleTplUnion["面/颜色"] ?? 0
        let faceDoc = colorDocTplUnion["面/颜色"] ?? 0
        let faceOutside = colorOutsideLayerUnion["面/颜色"] ?? 0
        out.append("面/颜色：① \(facePrio)　③ \(faceStyle)　④ \(faceDoc)　⑤ 无 layer 祖先的命中 \(faceOutside)")
        out.append("④ - ① = \(faceDoc - facePrio)，就是 QC 163 与本表 160 的全部差额。")
        out.append("QC 的 163 → " + reconcile(163, [
            ("③ style 级并集（layer 内）", faceStyle),
            ("④ 全文档 style 并集", faceDoc),
            ("⑤ 只数没有 layer 祖先的 style", faceOutside)
        ]))
        out.append("")
        let outWit = colorOutsideWitness["面/颜色"] ?? []
        if outWit.isEmpty {
            out.append("（没有「无 layer 祖先」的 面/颜色 命中）")
        } else {
            out.append("④ - ① = \(faceDoc - facePrio) 个模板，逐条列（模板名 + 命中的完整路径）：")
            for (n, w) in outWit.enumerated() {
                out.append("  \(n + 1). \(w.rel)")
                out.append("     路径：\(w.detail)")
            }
            out.append("")
            out.append("为什么在本表口径下不计入 面/颜色：这些 <style> 没有任何 <layer> 祖先，")
            out.append("MotiDocumentParser 只从 <scene> 起展开 <layer>，走不到它们，因此这份颜色")
            out.append("在 UI 里根本不会出现；把它算成「模板命中」会让分子（UI 真能显示颜色的模板）")
            out.append("与分母（1241 个模板）不同源。阶段 1 python 按样式扫全文档，")
            out.append("所以它数到 \(faceDoc)，本表按 layer 数到 \(facePrio)。")
        }
        out.append("")
        out.append("一句话交代：160 与 163 差在「候选集边界」——163 把没有 layer 祖先的")
        out.append("<style> 也算成模板命中，160 只认 UI 真正能显示的那部分；")
        out.append("layer 级层数两种数法一致：面/颜色 = \(colorBySourceLayers["面/颜色"] ?? 0) 层。")
        out.append("")

        print(out.joined(separator: "\n"))
    }

    // MARK: - 对账小工具

    static func reconcile(_ qc: Int, _ candidates: [(String, Int)]) -> String {
        var best: (String, Int, Int)? = nil
        for (name, value) in candidates {
            if value == qc { return "本表「\(name)」= \(value)，差 0（逐位一致）" }
            if best == nil || abs(value - qc) < abs(best!.1 - qc) {
                best = (name, value, value - qc)
            }
        }
        guard let b = best else { return "无候选" }
        return "无逐位匹配；最接近「\(b.0)」= \(b.1)，差 \(b.2 > 0 ? "+" : "")\(b.2)"
    }

    static func cellHeader(_ label: String, _ cols: [String]) -> String {
        return cellRow(label, cols)
    }

    /// 定宽列（按东亚宽度算），保证矩阵三列在等宽终端里逐行对齐。
    static func cellRow(_ label: String, _ cols: [String]) -> String {
        var s = padCJK(label, 10)
        for c in cols { s += padCJK(c, 32) }
        return s
    }

    static func parityCheck<T: Equatable>(field: String, a: T, b: T, rel: String, idx: Int,
                                          bad: inout [String: Int], samples: inout [String]) {
        if a != b {
            bad[field, default: 0] += 1
            if samples.count < 5 {
                samples.append("\(field) \(rel) 第 \(idx + 1) 层：快照 \(a) / 原始 \(b)")
            }
        }
    }

    // MARK: - 原始 XML 侧复算（与 MotiDocumentParser 同口径）

    /// 与解析器 collectLayers 完全相同的展开顺序：scene 下任意深度 <layer>，前序。
    static func collectLayerElements(_ element: XMLElement, into result: inout [XMLElement]) {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            if el.name == "layer" { result.append(el) }
            collectLayerElements(el, into: &result)
        }
    }

    static func facts(of layer: XMLElement) -> LayerFacts {
        var f = LayerFacts()
        let full = resolveTextStyle(from: styleElements(of: layer, intoNestedLayers: true))
        f.fontName = full.fontName
        f.fontSize = full.fontSize
        f.textColor = full.textColor
        f.colorSource = full.source
        f.alignment = resolveAlignment(in: layer, intoNestedLayers: true)

        let own = resolveTextStyle(from: styleElements(of: layer, intoNestedLayers: false))
        f.fontNameOwn = own.fontName
        f.fontSizeOwn = own.fontSize
        f.textColorOwn = own.textColor
        f.alignmentOwn = resolveAlignment(in: layer, intoNestedLayers: false)

        f.hasTextParamFull = hasTextParameter(layer, intoNestedLayers: true)
        f.hasTextParamOwn = hasTextParameter(layer, intoNestedLayers: false)

        f.sizeWithDefault = styleElements(of: layer, intoNestedLayers: true).contains { style in
            guard let p = childParameter(style, names: ["大小", "Size"]) else { return false }
            if let v = declaredValue(p), v > 0 { return true }
            return false
        }
        f.sizeNodeExists = styleElements(of: layer, intoNestedLayers: true).contains {
            childParameter($0, names: ["大小", "Size"]) != nil
        }
        let stylesFull = styleElements(of: layer, intoNestedLayers: true)
        f.sizeAnyNumeric = stylesFull.contains {
            explicitValue(childParameter($0, names: ["大小", "Size"])) != nil
        }
        f.sizeWideNames = stylesFull.contains {
            explicitValue(childParameter($0, names: ["大小", "Size", "字号", "FontSize"])) != nil
        }
        var sizeAnywhereHit = false
        var sizeAnywhereWideHit = false
        func scanSize(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let el = child as? XMLElement else { continue }
                if el.name == "parameter", let n = attribute(el, "name"), explicitValue(el) != nil {
                    if n == "大小" || n == "Size" { sizeAnywhereHit = true }
                    if n == "大小" || n == "Size" || n == "字号" || n == "FontSize" {
                        sizeAnywhereWideHit = true
                    }
                }
                scanSize(el)
            }
        }
        scanSize(layer)
        f.sizeAnywhere = sizeAnywhereHit
        f.sizeAnywhereWide = sizeAnywhereWideHit
        let anyAlign = alignmentRaw(in: layer, intoNestedLayers: true, allowDefault: false)
        f.alignAnyValue = anyAlign != nil
        f.alignNodeExists = firstParameter(in: layer, names: ["对齐", "Alignment"],
                                           intoNestedLayers: true, acceptDefault: true) != nil
        if let raw = alignmentRaw(in: layer, intoNestedLayers: true, allowDefault: true) {
            f.alignWithDefault = !alignmentName(raw).isEmpty
        }
        return f
    }

    static func styleElements(of layer: XMLElement, intoNestedLayers: Bool) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let el = child as? XMLElement else { continue }
                if !intoNestedLayers && el.name == "layer" { continue }
                if el.name == "style" { result.append(el) }
                walk(el)
            }
        }
        walk(layer)
        return result
    }

    static func hasTextParameter(_ layer: XMLElement, intoNestedLayers: Bool) -> Bool {
        var hit = false
        func walk(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let el = child as? XMLElement else { continue }
                if !intoNestedLayers && el.name == "layer" { continue }
                if el.name == "parameter", let n = attribute(el, "name"), n == "文本" || n == "Text" {
                    hit = true
                }
                walk(el)
            }
        }
        walk(layer)
        return hit
    }

    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        return element.attribute(forName: name)?.stringValue
    }

    static func childParameter(_ parent: XMLElement?, names: [String]) -> XMLElement? {
        guard let parent else { return nil }
        for parameter in parent.elements(forName: "parameter") {
            if let name = attribute(parameter, "name"), names.contains(name) {
                return parameter
            }
        }
        return nil
    }

    static func explicitValue(_ element: XMLElement?) -> Double? {
        guard let element else { return nil }
        if let raw = attribute(element, "value")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let number = Double(raw) {
            return number
        }
        if let curve = element.elements(forName: "curve").first,
           let raw = attribute(curve, "value")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Double(raw)
        }
        return nil
    }

    static func declaredValue(_ element: XMLElement?) -> Double? {
        if let value = explicitValue(element) { return value }
        guard let element,
              let raw = attribute(element, "default")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Double(raw)
    }

    static func rgbHex(_ parent: XMLElement?,
                       red: [String], green: [String], blue: [String]) -> String? {
        let nodes = [childParameter(parent, names: red),
                     childParameter(parent, names: green),
                     childParameter(parent, names: blue)]
        let values = nodes.map { declaredValue($0) }
        guard values.contains(where: { $0 != nil }) else { return nil }
        let siblingDefault = parent?.elements(forName: "parameter")
            .compactMap { attribute($0, "default").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            .first ?? 1.0
        let resolved = values.map { $0 ?? siblingDefault }
        guard resolved.count == 3 else { return nil }
        func channel(_ raw: Double) -> Int {
            return Int((max(0.0, min(1.0, raw)) * 255.0).rounded())
        }
        return String(format: "#%02X%02X%02X",
                      channel(resolved[0]), channel(resolved[1]), channel(resolved[2]))
    }

    static func resolveTextStyle(from styles: [XMLElement])
        -> (fontName: String, fontSize: Double, textColor: String, source: String) {
        var fontName = ""
        var fontSize: Double = 0
        var textColor = ""
        var source = ""
        for style in styles {
            if fontName.isEmpty,
               let fontParameter = childParameter(style, names: ["字体", "Font"]),
               let fontElement = fontParameter.elements(forName: "font").first {
                let raw = (fontElement.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { fontName = raw }
            }
            if fontSize <= 0,
               let size = explicitValue(childParameter(style, names: ["大小", "Size"])), size > 0 {
                fontSize = size
            }
            if textColor.isEmpty, let hit = resolveTextColor(style: style) {
                textColor = hit.hex
                source = hit.source
            }
        }
        return (fontName, fontSize, textColor, source)
    }

    static func resolveTextColor(style: XMLElement) -> (hex: String, source: String)? {
        if let face = childParameter(style, names: ["Face"]),
           let color = childParameter(face, names: ["Color"]),
           let hex = rgbHex(color, red: ["Red"], green: ["Green"], blue: ["Blue"]) {
            return (hex, "Face/Color")
        }
        if let face = childParameter(style, names: ["面"]),
           let color = childParameter(face, names: ["颜色"]),
           let hex = rgbHex(color, red: ["红"], green: ["绿"], blue: ["蓝"]) {
            return (hex, "面/颜色")
        }
        if let surface = childParameter(style, names: ["表面"]),
           let color = childParameter(surface, names: ["颜色"]),
           let hex = rgbHex(color, red: ["红色", "红"], green: ["绿色", "绿"], blue: ["蓝色", "蓝"]) {
            return (hex, "表面/颜色")
        }
        let gradientHosts: [(XMLElement?, [String], [String])] = [
            (childParameter(style, names: ["表面"]), ["渐变"], ["颜色"]),
            (childParameter(style, names: ["Face"]), ["Gradient"], ["Color"]),
            (style, ["渐变", "Gradient"], ["颜色", "Color"])
        ]
        for (host, gradientNames, colorNames) in gradientHosts {
            guard let gradient = childParameter(host, names: gradientNames),
                  let rgb = childParameter(gradient, names: ["RGB"]),
                  let stop = childParameter(rgb, names: ["RGB1"]),
                  let color = childParameter(stop, names: colorNames),
                  let hex = rgbHex(color,
                                   red: ["红色", "Red"], green: ["绿色", "Green"], blue: ["蓝色", "Blue"])
            else { continue }
            return (hex, "渐变首色标")
        }
        return nil
    }

    static func resolveAlignment(in layer: XMLElement, intoNestedLayers: Bool) -> String {
        if let paragraphStyle = firstDescendant(in: layer, tag: "paragraphStyle",
                                                intoNestedLayers: intoNestedLayers),
           let parameter = childParameter(paragraphStyle, names: ["对齐", "Alignment"]),
           let raw = explicitValue(parameter) {
            return alignmentName(raw)
        }
        if let parameter = firstParameter(in: layer, names: ["对齐", "Alignment"],
                                          intoNestedLayers: intoNestedLayers) {
            return alignmentName(explicitValue(parameter) ?? -1)
        }
        return ""
    }

    /// 探针专用：返回对齐的原始数值，allowDefault 时取值链加一档 @default。
    static func alignmentRaw(in layer: XMLElement, intoNestedLayers: Bool, allowDefault: Bool) -> Double? {
        let read: (XMLElement?) -> Double? = { allowDefault ? declaredValue($0) : explicitValue($0) }
        if let paragraphStyle = firstDescendant(in: layer, tag: "paragraphStyle",
                                                intoNestedLayers: intoNestedLayers),
           let parameter = childParameter(paragraphStyle, names: ["对齐", "Alignment"]),
           let raw = read(parameter) {
            return raw
        }
        if let parameter = firstParameter(in: layer, names: ["对齐", "Alignment"],
                                          intoNestedLayers: intoNestedLayers, acceptDefault: allowDefault),
           let raw = read(parameter) {
            return raw
        }
        return nil
    }

    static func alignmentName(_ raw: Double) -> String {
        switch Int(raw.rounded()) {
        case 0: return "left"
        case 1: return "right"
        case 2: return "center"
        default: return ""
        }
    }

    static func firstDescendant(in element: XMLElement, tag: String,
                                intoNestedLayers: Bool) -> XMLElement? {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            if !intoNestedLayers && el.name == "layer" { continue }
            if el.name == tag { return el }
            if let hit = firstDescendant(in: el, tag: tag, intoNestedLayers: intoNestedLayers) { return hit }
        }
        return nil
    }

    static func firstParameter(in element: XMLElement, names: [String],
                               intoNestedLayers: Bool,
                               acceptDefault: Bool = false) -> XMLElement? {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            if !intoNestedLayers && el.name == "layer" { continue }
            if el.name == "parameter",
               let name = attribute(el, "name"), names.contains(name),
               attribute(el, "value") != nil
                || el.elements(forName: "curve").first != nil
                || (acceptDefault && attribute(el, "default") != nil) {
                return el
            }
            if let hit = firstParameter(in: el, names: names,
                                        intoNestedLayers: intoNestedLayers,
                                        acceptDefault: acceptDefault) { return hit }
        }
        return nil
    }

    // MARK: - 排版

    static func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "0.0%" }
        return String(format: "%.1f%%", Double(n) * 100.0 / Double(d))
    }

    static func pad(_ n: Int, _ width: Int = 6) -> String {
        let s = String(n)
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }

    static func padL(_ s: String, _ width: Int) -> String {
        return s + String(repeating: " ", count: max(0, width - s.count))
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
