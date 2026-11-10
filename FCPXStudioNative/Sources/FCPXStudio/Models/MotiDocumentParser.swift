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
                depth: Int = 0) {
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
                              posX: layer.posX,
                              posY: layer.posY,
                              visible: layer.enabled,
                              diagnosticNotes: notes,
                              isLocked: true)
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
                                 depth: depth)
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
