// ═══════════════════════════════════════════════════════════════════════════
// TR-019 阶段一 / TR-019-R 返修：.moti (Apple Motion / ozml) 只读解析层
//
// 【阶段一范围】只把 .moti 解析进设计器做预览，不写回、不落盘、不生成中间文件。
//   · 本文件对目标文件只有一次 Data(contentsOf:) 读取 + XMLDocument 内存解析；
//     全程不修改 .moti，不改动任何现有文件。
//   · toLayerModels(_:) 产出的 LayerModel 一律 isLocked = true（防误拖拽），
//     diagnosticNotes 标注「只读，不可编辑」；阶段二再讨论授权写回。
//
// 【TR-019-R 返修重点】
//   1) 层数：旧版只取 <scene> 的【直接】layer 子节点，导致分组/嵌套模板只出
//      1~2 层。现改为自 <scene> 起递归展开【任意深度】的 layer 节点，
//      文档顺序保留，层数与源文件 layer 节点总数严格一致。
//      素材库实测 1247 个 .moti（XML 解析成功 1241）中 764 个的 layer 不是 scene 直接子节点，
//      最极端者 564 层里 559 层嵌套，旧版只出 5 层。
//   2) 诊断文案：旧版逐层刷「未找到 对象/文本(369)<text> 节点…posX 按 0 处理…」
//      这类含 XML 节点名的原始 warning，几十条拼成一整块红字把「幅面规格」顶掉。
//      现改为最多 4 条大白话汇总，不出现任何节点名 / 参数 id / 字段名。
//   3) 分组层（无文字、无位置）不再逐条告警，只在画布用占位框标出。
//
// 【格式事实】根 ozml version="5.14"，DOCTYPE ozxmlscene；
//   · 位置：layer/scenenode/parameter[属性,1]/parameter[变换,100]/parameter[位置,101]
//           /parameter[X,1]@value 与 /parameter[Y,2]@value
//   · 文本：layer/scenenode/parameter[对象,2]/parameter[文本,369]/text 的文本子节点
//   · 画布宽高：scene/sceneSettings/width|height（如 1920x1080）
//
// 【依赖】只用 Foundation；XMLDocument / XMLElement 属于 Foundation XML 家族，
//   与现有 GhostPluginDoctor.swift 的用法一致（options: []）。
//   DOCTYPE 没有 SYSTEM/PUBLIC 标识符，无外部实体，不会触发外部加载。
//
// 【防御】全文件无 force unwrap；任何 nil / 类型异常都走 guard + 默认值 + 中文说明。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

// MARK: - 快照模型（纯值类型，只读）

public struct MotiLayerSnapshot {
    public let index: Int
    public let id: String
    public let name: String
    public let text: String
    public let posX: Double
    public let posY: Double
    public let enabled: Bool
    public let locked: Bool
    public let fixedWidth: Double?
    public let fixedHeight: Double?
    /// TR-019-R：该层在源文件中的嵌套深度（0 = 顶层 layer）。供画布分层占位使用。
    public let depth: Int

    // MARK: - TR-023-B：文字样式只读取值（全部只读，不写回、不改既有字段）
    /// 字体名（style/Font|字体 下的 <font> 文本）。空串 = 没取到。
    public let fontName: String
    /// 字号（style/Size|大小 的 value）。0 = 没取到。
    public let fontSize: Double
    /// 段落水平对齐："left" / "right" / "center"。空串 = 没取到或不在三档内。
    public let alignment: String
    /// 文字填充色 "#RRGGBB"。空串 = 没取到（检查器显示禁用空态）。
    public let textColor: String
    /// 取色用到的 XML 路径（仅用于自检与统计，不进 UI 文案）。
    public let colorSourcePath: String
    /// TR-002-D BUG-4D-1：该层位置参数链的形态。只做检测，不读英文链的值、不加功能。
    ///   "zh" = 属性(1)/变换(100)（本工具可写）；"en" = Properties(1)/Transform(100)
    ///          （第三方英文链，X/Y 不可写，UI 置灰并提示）；"" = 两种都不是（同 en 处理）。
    /// 默认 "zh"：仅 parseLayer 会显式赋值，其余构造点保持既有可写行为零变化。
    public let positionChain: String

    /// TR-002-D-1 BUG-4D1-1：层可写性判定输出（纯查询，不改任何解析行为）。
    /// 与问题单口径一致：positionChain == "zh" 才可写，"en" 与 "" 一律不可写。
    public var isPositionChainWritable: Bool { positionChain == "zh" }

    public init(index: Int,
                id: String,
                name: String,
                text: String,
                posX: Double,
                posY: Double,
                enabled: Bool,
                locked: Bool,
                fixedWidth: Double?,
                fixedHeight: Double?,
                depth: Int = 0,
                fontName: String = "",
                fontSize: Double = 0,
                alignment: String = "",
                textColor: String = "",
                colorSourcePath: String = "",
                positionChain: String = "zh") {
        self.index = index
        self.id = id
        self.name = name
        self.text = text
        self.posX = posX
        self.posY = posY
        self.enabled = enabled
        self.locked = locked
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.depth = depth
        self.fontName = fontName
        self.fontSize = fontSize
        self.alignment = alignment
        self.textColor = textColor
        self.colorSourcePath = colorSourcePath
        self.positionChain = positionChain
    }
}

public struct MotiDocumentSnapshot {
    public let sourcePath: String
    public let ozmlVersion: String
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let layers: [MotiLayerSnapshot]
    /// 大白话提示，最多 4 条；不含任何 XML 节点名 / 参数 id / 英文字段名。
    public let warnings: [String]
    public let isValid: Bool
    public let failureReason: String?
    /// TR-019-R：包含嵌套（depth > 0）的 layer 数量，供 UI 展示「已展开 N 层」。
    public let nestedLayerCount: Int
    /// TR-019-R：没有可显示文字的层（分组/图形层）数量。
    public let containerLayerCount: Int

    public init(sourcePath: String,
                ozmlVersion: String,
                canvasWidth: Int,
                canvasHeight: Int,
                layers: [MotiLayerSnapshot],
                warnings: [String],
                isValid: Bool,
                failureReason: String?,
                nestedLayerCount: Int = 0,
                containerLayerCount: Int = 0) {
        self.sourcePath = sourcePath
        self.ozmlVersion = ozmlVersion
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.layers = layers
        self.warnings = warnings
        self.isValid = isValid
        self.failureReason = failureReason
        self.nestedLayerCount = nestedLayerCount
        self.containerLayerCount = containerLayerCount
    }

    /// 失败快照：绝不抛异常、绝不 crash，调用方只看 isValid / failureReason。
    public static func invalid(path: String, reason: String) -> MotiDocumentSnapshot {
        return MotiDocumentSnapshot(sourcePath: path,
                                    ozmlVersion: "",
                                    canvasWidth: 0,
                                    canvasHeight: 0,
                                    layers: [],
                                    warnings: [reason],
                                    isValid: false,
                                    failureReason: reason)
    }
}

// MARK: - 解析器

public final class MotiDocumentParser {

    private init() {}

    /// 只读解析一个 .moti 文件。任何失败都返回 isValid=false 的快照，不 throw、不 crash。
    public static func parse(path: String) -> MotiDocumentSnapshot {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "找不到这份模板文件，无法预览。")
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这份模板文件读不出来，可能已损坏或没有访问权限。")
        }
        guard !data.isEmpty else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这是一份空文件，没有内容可预览。")
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这份模板的内部格式无法识别，预览不了。")
        }

        guard let root = document.rootElement() else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这份模板是空的，找不到内容。")
        }
        guard root.name == "ozml" else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这份文件不是可用的 Motion 模板，无法预览。")
        }

        let scenes = root.elements(forName: "scene")
        guard !scenes.isEmpty else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "这份模板里没有可预览的画面内容。")
        }

        // ── TR-019-R 核心：递归展开任意深度的 layer ──────────────────────────
        // 旧版用 scene.elements(forName: "layer") 只拿直接子节点，分组模板全丢。
        // 现在从每个 scene 出发深度优先遍历全部后代，前序追加，保持源文件顺序。
        var found: [(element: XMLElement, depth: Int)] = []
        for scene in scenes {
            collectLayers(from: scene, depth: 0, into: &found)
        }

        var layers: [MotiLayerSnapshot] = []
        for entry in found {
            layers.append(parseLayer(entry.element,
                                     index: layers.count,
                                     depth: entry.depth))
        }

        let canvas = resolveCanvasSize(root: root, scenes: scenes, layers: layers)

        let nestedCount = layers.filter { $0.depth > 0 }.count
        let containerCount = layers.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count

        // 大白话汇总提示：最多 4 条，不含任何节点名 / 参数 id / 英文字段名。
        var notes: [String] = []
        notes.append(canvas.note)
        if nestedCount > 0 {
            notes.append("这份模板里有分组，已经把 \(nestedCount) 个分组里的图层全部展开，共 \(layers.count) 层。")
        } else if layers.count > 1 {
            notes.append("一共读到 \(layers.count) 层，全部列在右边了。")
        }
        if containerCount > 0 {
            notes.append("其中 \(containerCount) 层没有文字内容，画布上用占位框标出位置。")
        }
        if layers.isEmpty {
            notes.append("这份模板里没有找到图层，画布会是空的。")
        }
        notes.append("这是只读预览，不能编辑，也不会改动原文件。")

        return MotiDocumentSnapshot(sourcePath: path,
                                    ozmlVersion: attribute(root, "version") ?? "",
                                    canvasWidth: canvas.width,
                                    canvasHeight: canvas.height,
                                    layers: layers,
                                    warnings: notes,
                                    isValid: true,
                                    failureReason: nil,
                                    nestedLayerCount: nestedCount,
                                    containerLayerCount: containerCount)
    }

    /// 深度优先递归：收集 element 全部后代里名为 layer 的节点。
    /// 命中 layer 后仍继续下探，保证分组层内部的子层也能取出。
    private static func collectLayers(from element: XMLElement,
                                      depth: Int,
                                      into result: inout [(element: XMLElement, depth: Int)]) {
        guard let children = element.children else { return }
        for child in children {
            guard let el = child as? XMLElement else { continue }
            let isLayer = (el.name == "layer")
            if isLayer {
                result.append((el, depth))
            }
            // 无论是不是 layer 都继续下探（scenenode / 分组容器都可能再包一层）
            collectLayers(from: el, depth: isLayer ? depth + 1 : depth, into: &result)
        }
    }

    /// 阶段一只读映射：快照 -> 设计器模型。生成物一律锁定，禁止任何写回路径误用。
    public static func toLayerModels(_ snapshot: MotiDocumentSnapshot) -> [LayerModel] {
        guard snapshot.isValid else { return [] }
        let palette = ["#FF6B6B", "#4ECDC4", "#FFD166", "#A78BFA", "#7DD3FC", "#F9A8D4"]
        return snapshot.layers.map { layer in
            let trimmedID = layer.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let numericID = Int(trimmedID) ?? (layer.index + 1)
            var notes: [String] = []
            notes.append("只读，不可编辑")
            notes.append("第 \(layer.index + 1) 层，源文件名 \(layer.name)")
            if layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes.append("这一层没有文字，画布用占位框表示")
            }
            // 画布占位配色：按层序号轮换，分组层用灰。
            notes.append("占位配色 \(palette[layer.index % palette.count])")
            return LayerModel(id: numericID,
                              name: layer.name,
                              kind: "type",
                              text: layer.text,
                              // TR-023-B：只读取值。空串 / 0 表示「没取到」，检查器据此禁用。
                              fontName: layer.fontName,
                              fontSize: layer.fontSize,
                              posX: layer.posX,
                              posY: layer.posY,
                              visible: layer.enabled,
                              diagnosticNotes: notes,
                              alignment: layer.alignment,
                              isLocked: true,
                              textColor: layer.textColor)
        }
    }

    // MARK: - 图层解析（不再产生任何含节点名的告警）

    private static func parseLayer(_ layer: XMLElement,
                                   index: Int,
                                   depth: Int) -> MotiLayerSnapshot {
        let rawID = attribute(layer, "id") ?? ""
        let rawName = attribute(layer, "name") ?? ""
        let name = rawName.isEmpty ? "图层 \(index + 1)" : rawName

        // 参数树可能挂在 scenenode 下，也可能直接挂在 layer 下；两种都作为候选根。
        var roots: [XMLElement] = []
        roots.append(contentsOf: layer.elements(forName: "scenenode"))
        roots.append(layer)

        // 位置：属性(1) -> 变换(100) -> 位置(101) -> X(1) / Y(2)
        let transform = descend(roots, name: "属性", id: "1")
        let position = descend(transform, name: "变换", id: "100")
        let location = descend(position, name: "位置", id: "101")
        let xParam = descend(location, name: "X", id: "1").first
        let yParam = descend(location, name: "Y", id: "2").first
        let posX = numericValue(of: xParam) ?? 0.0
        let posY = numericValue(of: yParam) ?? 0.0

        // TR-002-D BUG-4D-1：只检测链形态，决定 X/Y 可不可写；
        // 英文链不读值（读回没有判据，读了就是假功能），保持 X/Y 置灰。
        let chainKind = positionChainKind(of: roots)

        // 文本：对象(2) -> 文本(369) -> <text> 的文本子节点（换行原样保留）
        let objects = descend(roots, name: "对象", id: "2")
        let textParameters = descend(objects, name: "文本", id: "369")
        var text = ""
        for parameter in textParameters {
            if let textElement = parameter.elements(forName: "text").first {
                text = textContent(of: textElement)
                break
            }
        }

        // 固定宽高：对象(2) -> 固定宽度(302) / 固定高度(303)
        let widthParameter = findLeafParameter(objects, name: "固定宽度", id: "302")
        let heightParameter = findLeafParameter(objects, name: "固定高度", id: "303")
        let fixedWidth = numericValue(of: widthParameter)
        let fixedHeight = numericValue(of: heightParameter)

        let enabled = boolAttribute(layer, "enabled", default: true)
        let locked = boolAttribute(layer, "locked", default: false)

        // TR-023-B：文字样式只读取值（优先级与阶段 1 实证一致，见 resolveTextColor）
        let styles = allStyleElements(in: layer)
        let styleInfo = resolveTextStyle(from: styles)

        return MotiLayerSnapshot(index: index,
                                 id: rawID,
                                 name: name,
                                 text: text,
                                 posX: posX,
                                 posY: posY,
                                 enabled: enabled,
                                 locked: locked,
                                 fixedWidth: fixedWidth,
                                 fixedHeight: fixedHeight,
                                 depth: depth,
                                 fontName: styleInfo.fontName,
                                 fontSize: styleInfo.fontSize,
                                 alignment: resolveAlignment(in: layer),
                                 textColor: styleInfo.textColor,
                                 colorSourcePath: styleInfo.colorSource,
                                 positionChain: chainKind)
    }

    /// TR-002-D BUG-4D-1：位置参数链形态检测（只看链存在与否，不读值、不改任何解析行为）。
    private static func positionChainKind(of roots: [XMLElement]) -> String {
        if let transform = descend(roots, name: "属性", id: "1").first,
           descend([transform], name: "变换", id: "100").first != nil {
            return "zh"
        }
        if let transform = descend(roots, name: "Properties", id: "1").first,
           descend([transform], name: "Transform", id: "100").first != nil {
            return "en"
        }
        return ""
    }

    // MARK: - TR-023-B：文字样式只读提取（不修改任何既有解析行为）

    /// layer 子树里的全部 <style>（多段文字会有多个），文档顺序。
    private static func allStyleElements(in layer: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let el = child as? XMLElement else { continue }
                if el.name == "style" { result.append(el) }
                walk(el)
            }
        }
        walk(layer)
        return result
    }

    /// 直接子 parameter 里按名字取第一个。
    private static func childParameter(_ parent: XMLElement?, names: [String]) -> XMLElement? {
        guard let parent else { return nil }
        for parameter in parent.elements(forName: "parameter") {
            if let name = attribute(parameter, "name"), names.contains(name) {
                return parameter
            }
        }
        return nil
    }

    /// 只认「参数自身 @value」或「子元素 <curve> 的 @value」（阶段 1 实证的两种写法）。
    /// 不退回 @default：缺实际值说明该参数没被写过，不能当数据。
    private static func explicitValue(_ element: XMLElement?) -> Double? {
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

    /// 在「参数自身 @value」→「子元素 <curve> 的 @value」→「@default」里取值。
    /// 只用于颜色三通道：Motion 允许只写部分通道（例如只写 绿/蓝），
    /// 缺失通道按 XML 自己声明的 @default 补齐，不是我们编造的颜色。
    private static func declaredValue(_ element: XMLElement?) -> Double? {
        if let value = explicitValue(element) { return value }
        guard let element,
              let raw = attribute(element, "default")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Double(raw)
    }

    /// 取 RGB 三通道。Motion 常只写发生变化的那一两个通道（例如只写「红色」），
    /// 缺失通道按同族参数自己声明的 @default 补齐（红/绿/蓝默认都是 1），
    /// 一个通道都没写才算「这一族没有颜色」，避免把 #FFFFFF 猜成 #FF0000。
    private static func rgbHex(_ parent: XMLElement?,
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

    /// 字号 / 字体 / 颜色三件套（都长在 style 下），取第一个有值的 style。
    private static func resolveTextStyle(from styles: [XMLElement])
        -> (fontName: String, fontSize: Double, textColor: String, colorSource: String) {
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

    /// 取色优先级（阶段 2 实证）：Face/Color → 面/颜色 → 表面/颜色 → 面/渐变首色标 → 表面/渐变首色标
    /// → Face/Gradient → style 直挂渐变。
    ///
    /// 三条口径（本次补「面/渐变」时定死，不许顺手加）：
    /// 1. 纯色优先于渐变：同一 style 里 `面/颜色` 能取到值时，不因 `面/渐变` 存在而改取首色标；
    ///    `面` 与 `表面` 同时带渐变时取 `面`（Motion 中文原生填充容器优先于 Surface 译名）。
    /// 2. 只认 `面` 子树里的 渐变→RGB→RGB1→颜色；`轮廓`/`拖放阴影`/`外框`/`纹理` 一律不参与，
    ///    描边色和投影色不是主色，图片填充没有"主色"可取。
    /// 3. 取不到就返回 nil，面板照旧显示「未取到」并禁用；绝不把空串当黑色补上。
    private static func resolveTextColor(style: XMLElement) -> (hex: String, source: String)? {
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
        // 渐变首色标兜底：面/渐变/RGB/RGB1/颜色（本次新增）、表面/渐变/RGB/RGB1/颜色、
        // Face/Gradient/RGB/RGB1/Color、顶层 渐变/RGB/RGB1/颜色。
        // 通道名三种写法都要认：面 子树下是 红/绿/蓝，表面 与 Face 下是 红色/Red。
        let gradientHosts: [(XMLElement?, [String], [String])] = [
            (childParameter(style, names: ["面"]), ["渐变"], ["颜色"]),
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
                                   red: ["红", "红色", "Red"],
                                   green: ["绿", "绿色", "Green"],
                                   blue: ["蓝", "蓝色", "Blue"])
            else { continue }
            return (hex, "渐变首色标")
        }
        return nil
    }

    /// 段落水平对齐：先 paragraphStyle，再 对象/段落/段落。数值按 AppKit 的
    /// NSTextAlignment 取值（0 左 / 1 右 / 2 居中，与 core/psd_parser.py 的
    /// justification 映射一致）；其余值不在三档内，返回空串让控件走空态。
    private static func resolveAlignment(in layer: XMLElement) -> String {
        if let paragraphStyle = firstDescendant(in: layer, tag: "paragraphStyle"),
           let parameter = childParameter(paragraphStyle, names: ["对齐", "Alignment"]),
           let raw = explicitValue(parameter) {
            return alignmentName(raw)
        }
        if let parameter = firstParameter(in: layer, names: ["对齐", "Alignment"]) {
            return alignmentName(explicitValue(parameter) ?? -1)
        }
        return ""
    }

    private static func alignmentName(_ raw: Double) -> String {
        switch Int(raw.rounded()) {
        case 0: return "left"
        case 1: return "right"
        case 2: return "center"
        default: return ""
        }
    }

    private static func firstDescendant(in element: XMLElement, tag: String) -> XMLElement? {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            if el.name == tag { return el }
            if let hit = firstDescendant(in: el, tag: tag) { return hit }
        }
        return nil
    }

    /// 全树第一个带 @value 的指定名字 parameter（用于 对象/段落/段落/对齐 这种深层路径）。
    private static func firstParameter(in element: XMLElement, names: [String]) -> XMLElement? {
        for child in element.children ?? [] {
            guard let el = child as? XMLElement else { continue }
            if el.name == "parameter",
               let name = attribute(el, "name"), names.contains(name),
               attribute(el, "value") != nil || el.elements(forName: "curve").first != nil {
                return el
            }
            if let hit = firstParameter(in: el, names: names) { return hit }
        }
        return nil
    }

    // MARK: - 画布尺寸（只返回一条大白话说明）

    private static func resolveCanvasSize(root: XMLElement,
                                          scenes: [XMLElement],
                                          layers: [MotiLayerSnapshot]) -> (width: Int, height: Int, note: String) {
        // 1) 先找根下的 canvas 宽高（多数模板这里没有尺寸）
        for canvas in root.elements(forName: "canvas") {
            let width = canvasInteger(canvas, tags: ["width"], names: ["宽度", "宽", "固定宽度"], ids: ["302"])
            let height = canvasInteger(canvas, tags: ["height"], names: ["高度", "高", "固定高度"], ids: ["303"])
            if let width = width, let height = height {
                return (width, height, "画布尺寸 \(width)×\(height)（模板里写明的）。")
            }
        }

        // 2) 真实画布尺寸通常在 scene 的画面设置（sceneSettings）里
        //    TR-022-2：文案按真实来源分档，sceneSettings = 「模板里的画面设置」。
        for scene in scenes {
            for settings in scene.elements(forName: "sceneSettings") {
                let width = parseInt(settings.elements(forName: "width").first?.stringValue)
                let height = parseInt(settings.elements(forName: "height").first?.stringValue)
                if let width = width, let height = height {
                    return (width, height, "画布尺寸 \(width)×\(height)（按模板里的画面设置）。")
                }
            }
        }

        // 3) 再退回首层的固定宽高（也属「模板里的画面设置」）
        if let first = layers.first,
           let fixedWidth = first.fixedWidth,
           let fixedHeight = first.fixedHeight {
            let width = Int(fixedWidth.rounded())
            let height = Int(fixedHeight.rounded())
            return (width, height, "画布尺寸 \(width)×\(height)（按模板里的画面设置）。")
        }

        // 4) 兜底：模板确实没写尺寸，按 1920×1080 处理
        return (1920, 1080, "这份模板没写尺寸，已按 1920×1080 处理")
    }

    private static func canvasInteger(_ parent: XMLElement,
                                      tags: [String],
                                      names: [String],
                                      ids: [String]) -> Int? {
        for tag in tags {
            if let element = parent.elements(forName: tag).first,
               let value = parseInt(element.stringValue) {
                return value
            }
        }
        for parameter in parent.elements(forName: "parameter") {
            let parameterName = attribute(parameter, "name") ?? ""
            let parameterID = attribute(parameter, "id") ?? ""
            guard names.contains(parameterName) || ids.contains(parameterID) else { continue }
            if let raw = attribute(parameter, "value") ?? attribute(parameter, "default"),
               let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return Int(number.rounded())
            }
        }
        return nil
    }

    // MARK: - 通用只读 helper（全部 guard，无 force unwrap）

    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        return element.attribute(forName: name)?.stringValue
    }

    /// 只在一组父节点的直接子节点里找 name+id 同时匹配的 parameter。
    private static func descend(_ parents: [XMLElement], name: String, id: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for parent in parents {
            for parameter in parent.elements(forName: "parameter") {
                if attribute(parameter, "name") == name && attribute(parameter, "id") == id {
                    result.append(parameter)
                }
            }
        }
        return result
    }

    /// 叶子参数：优先 name+id 双匹配，再仅按 id，最后仅按 name。
    private static func findLeafParameter(_ parents: [XMLElement], name: String, id: String) -> XMLElement? {
        let candidates = parents.flatMap { $0.elements(forName: "parameter") }
        if let hit = candidates.first(where: {
            attribute($0, "name") == name && attribute($0, "id") == id
        }) { return hit }
        if let hit = candidates.first(where: { attribute($0, "id") == id }) { return hit }
        return candidates.first(where: { attribute($0, "name") == name })
    }

    /// @value 优先，缺失时退回 @default；都不是合法 Double 就返回 nil。
    private static func numericValue(of parameter: XMLElement?) -> Double? {
        guard let parameter else { return nil }
        guard let raw = attribute(parameter, "value") ?? attribute(parameter, "default") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// text 节点的文本子节点拼接；拿不到子节点时退回 stringValue（Foundation 会保留换行）。
    private static func textContent(of element: XMLElement) -> String {
        if let children = element.children {
            var pieces: [String] = []
            for node in children where node.name == nil {
                if let value = node.stringValue {
                    pieces.append(value)
                }
            }
            if !pieces.isEmpty { return pieces.joined() }
        }
        return element.stringValue ?? ""
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let integer = Int(trimmed) { return integer }
        if let number = Double(trimmed) { return Int(number.rounded()) }
        return nil
    }

    private static func boolAttribute(_ element: XMLElement,
                                      _ name: String,
                                      default defaultValue: Bool) -> Bool {
        guard let raw = attribute(element, name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
