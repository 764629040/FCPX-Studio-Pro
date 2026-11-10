// ═══════════════════════════════════════════════════════════════════════════
// TR-019 阶段一：.moti (Apple Motion / ozml) 只读解析层
//
// 【阶段一范围】只把 .moti 解析进设计器做预览，不写回、不落盘、不生成中间文件。
//   · 本文件对目标文件只有一次 Data(contentsOf:) 读取 + XMLDocument 内存解析；
//     全程不修改 .moti，不改动任何现有文件、不触碰 MainWindowController / InspectorView。
//   · toLayerModels(_:) 产出的 LayerModel 一律 isLocked = true（防误拖拽），
//     diagnosticNotes 标注「TR-019 只读预览：不可写回」；阶段二再讨论授权写回。
//
// 【格式事实】根 <ozml version="5.14">，<!DOCTYPE ozxmlscene>；
//   <scene><layer name="Text 01" id="3000100"> ... </layer></scene> 共 8 层。
//   · 位置：layer/scenenode/parameter[属性,1]/parameter[变换,100]/parameter[位置,101]
//           /parameter[X,1]@value 与 /parameter[Y,2]@value
//   · 文本：layer/scenenode/parameter[对象,2]/parameter[文本,369]/<text> 的文本子节点
//   · 固定宽高：layer/parameter[对象,2]/parameter[固定宽度,302|固定高度,303]@value
//     （注意：与文本所在的 scenenode/对象 不是同一个 parameter 节点）
//   · 画布宽高：<ozml>/<canvas> 只有 layout/activeView，样本里没有尺寸；
//     真实尺寸在 <scene>/<sceneSettings>/<width|height> = 1080x1920。
//   · 扩展属性：layer@enabled (缺省 true)、layer@locked (缺省 false)
//
// 【依赖】只用 Foundation；XMLDocument / XMLElement 属于 Foundation XML 家族，
//   与现有 GhostPluginDoctor.swift:330-334 的用法一致（options: []）。
//   DOCTYPE 没有 SYSTEM/PUBLIC 标识符，无外部实体，用 options: [] 不会触发外部加载。
//   options: [.nodeLoadExternalEntitiesNever] 在各 SDK 上可用性不稳，故不采用。
//
// 【防御】全文件无 force unwrap；任何 nil / 类型异常都走 guard + 默认值 + 中文 warning。
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

    public init(index: Int,
                id: String,
                name: String,
                text: String,
                posX: Double,
                posY: Double,
                enabled: Bool,
                locked: Bool,
                fixedWidth: Double?,
                fixedHeight: Double?) {
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
    }
}

public struct MotiDocumentSnapshot {
    public let sourcePath: String
    public let ozmlVersion: String
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let layers: [MotiLayerSnapshot]
    public let warnings: [String]
    public let isValid: Bool
    public let failureReason: String?

    public init(sourcePath: String,
                ozmlVersion: String,
                canvasWidth: Int,
                canvasHeight: Int,
                layers: [MotiLayerSnapshot],
                warnings: [String],
                isValid: Bool,
                failureReason: String?) {
        self.sourcePath = sourcePath
        self.ozmlVersion = ozmlVersion
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.layers = layers
        self.warnings = warnings
        self.isValid = isValid
        self.failureReason = failureReason
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
        var warnings: [String] = []

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：文件不存在：\(path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：读取 .moti 失败：\(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：.moti 是 0 字节空文件：\(path)")
        }

        // 与 GhostPluginDoctor.swift 一致：options: []。DOCTYPE 无外部实体声明，安全。
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：XML 解析失败：\(error.localizedDescription)")
        }

        guard let root = document.rootElement() else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：XML 缺少根节点")
        }
        guard root.name == "ozml" else {
            return MotiDocumentSnapshot.invalid(path: path,
                                                reason: "TR-019：根节点应为 <ozml>，实际为 <\(root.name ?? "(nil)")>")
        }

        let version = attribute(root, "version") ?? ""
        if version.isEmpty {
            warnings.append("TR-019：<ozml> 缺少 version 属性，ozmlVersion 置空")
        }

        let scenes = root.elements(forName: "scene")
        guard !scenes.isEmpty else {
            return MotiDocumentSnapshot.invalid(path: path, reason: "TR-019：<ozml> 下未找到 <scene> 节点，无法解析图层")
        }

        // 用 elements(forName:) 逐层遍历，不用 XPath，避开 namespace 坑。
        var layers: [MotiLayerSnapshot] = []
        for scene in scenes {
            for layerElement in scene.elements(forName: "layer") {
                layers.append(parseLayer(layerElement, index: layers.count, warnings: &warnings))
            }
        }
        if layers.isEmpty {
            warnings.append("TR-019：<scene> 下未找到任何 <layer>，layers 为空数组")
        }

        let canvas = resolveCanvasSize(root: root,
                                       scenes: scenes,
                                       layers: layers,
                                       warnings: &warnings)

        return MotiDocumentSnapshot(sourcePath: path,
                                    ozmlVersion: version,
                                    canvasWidth: canvas.width,
                                    canvasHeight: canvas.height,
                                    layers: layers,
                                    warnings: warnings,
                                    isValid: true,
                                    failureReason: nil)
    }

    /// 阶段一只读映射：快照 -> 设计器模型。生成物一律锁定，禁止任何写回路径误用。
    public static func toLayerModels(_ snapshot: MotiDocumentSnapshot) -> [LayerModel] {
        guard snapshot.isValid else { return [] }
        return snapshot.layers.map { layer in
            let trimmedID = layer.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let numericID = Int(trimmedID) ?? (layer.index + 1)
            var notes: [String] = []
            notes.append("TR-019 只读预览：不可写回")
            notes.append("来源 .moti 图层 id=\(layer.id)，源 locked=\(layer.locked)")
            // 注意：LayerModel 的 init 参数必须按声明顺序给出（跳过的都有默认值）。
            // 阶段一强制 isLocked = true；snapshot.locked 只保留在快照与 notes 里。
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

    // MARK: - 图层解析

    private static func parseLayer(_ layer: XMLElement,
                                   index: Int,
                                   warnings: inout [String]) -> MotiLayerSnapshot {
        let rawID = attribute(layer, "id") ?? ""
        let rawName = attribute(layer, "name") ?? ""
        let label = "图层[\(index)] \(rawName.isEmpty ? "(未命名)" : rawName)"

        if rawID.isEmpty {
            warnings.append("TR-019：\(label) 缺少 id 属性，id 保留空字符串")
        }
        let name = rawName.isEmpty ? "Layer \(index + 1)" : rawName
        if rawName.isEmpty {
            warnings.append("TR-019：\(label) 缺少 name 属性，使用默认名称 \(name)")
        }

        // 参数树可能挂在 scenenode 下（样本），也可能直接挂在 layer 下（变体）；
        // 两种都作为候选根，按 name+id 逐层下探，不会误命中「缩放」里的 X/Y。
        var roots: [XMLElement] = []
        roots.append(contentsOf: layer.elements(forName: "scenenode"))
        roots.append(layer)

        // 位置：属性(1) -> 变换(100) -> 位置(101) -> X(1) / Y(2)
        let transform = descend(roots, name: "属性", id: "1")
        let position = descend(transform, name: "变换", id: "100")
        let location = descend(position, name: "位置", id: "101")
        let xParam = descend(location, name: "X", id: "1").first
        let yParam = descend(location, name: "Y", id: "2").first

        var posX = 0.0
        var posY = 0.0
        if let value = numericValue(of: xParam) {
            posX = value
        } else {
            warnings.append("TR-019：\(label) 未找到 属性/变换/位置/X 的 value，posX 按 0 处理")
        }
        if let value = numericValue(of: yParam) {
            posY = value
        } else {
            warnings.append("TR-019：\(label) 未找到 属性/变换/位置/Y 的 value，posY 按 0 处理")
        }

        // 文本：对象(2) -> 文本(369) -> <text> 的文本子节点（换行原样保留）
        let objects = descend(roots, name: "对象", id: "2")
        let textParameters = descend(objects, name: "文本", id: "369")
        var text = ""
        var foundTextNode = false
        for parameter in textParameters {
            if let textElement = parameter.elements(forName: "text").first {
                text = textContent(of: textElement)
                foundTextNode = true
                break
            }
        }
        if !foundTextNode {
            warnings.append("TR-019：\(label) 未找到 对象/文本(369)/<text> 节点，text 置空字符串")
        }

        // 固定宽高：对象(2) -> 固定宽度(302) / 固定高度(303)
        let widthParameter = findLeafParameter(objects, name: "固定宽度", id: "302")
        let heightParameter = findLeafParameter(objects, name: "固定高度", id: "303")
        let fixedWidth = numericValue(of: widthParameter)
        let fixedHeight = numericValue(of: heightParameter)
        if fixedWidth == nil {
            warnings.append("TR-019：\(label) 未找到 固定宽度(302)，fixedWidth 置 nil")
        }
        if fixedHeight == nil {
            warnings.append("TR-019：\(label) 未找到 固定高度(303)，fixedHeight 置 nil")
        }

        // 扩展属性：enabled 缺省 true，locked 缺省 false（core/moti_layer_io.py 可选写入）
        let enabled = boolAttribute(layer, "enabled", default: true, label: label, warnings: &warnings)
        let locked = boolAttribute(layer, "locked", default: false, label: label, warnings: &warnings)

        return MotiLayerSnapshot(index: index,
                                 id: rawID,
                                 name: name,
                                 text: text,
                                 posX: posX,
                                 posY: posY,
                                 enabled: enabled,
                                 locked: locked,
                                 fixedWidth: fixedWidth,
                                 fixedHeight: fixedHeight)
    }

    // MARK: - 画布尺寸

    private static func resolveCanvasSize(root: XMLElement,
                                          scenes: [XMLElement],
                                          layers: [MotiLayerSnapshot],
                                          warnings: inout [String]) -> (width: Int, height: Int) {
        // 1) 先按需求找 <ozml>/<canvas> 下的宽高（样本里只有 layout/activeView，命中不了）
        for canvas in root.elements(forName: "canvas") {
            let width = canvasInteger(canvas,
                                      tags: ["width"],
                                      names: ["宽度", "宽", "固定宽度"],
                                      ids: ["302"])
            let height = canvasInteger(canvas,
                                       tags: ["height"],
                                       names: ["高度", "高", "固定高度"],
                                       ids: ["303"])
            if let width = width, let height = height {
                return (width, height)
            }
        }
        warnings.append("TR-019：<ozml>/<canvas> 未声明宽高（样本仅有 layout/activeView），回退其他尺寸来源")

        // 2) 真实画布尺寸其实在 <scene>/<sceneSettings>/<width|height>（样本 1080x1920）
        for scene in scenes {
            for settings in scene.elements(forName: "sceneSettings") {
                let width = parseInt(settings.elements(forName: "width").first?.stringValue)
                let height = parseInt(settings.elements(forName: "height").first?.stringValue)
                if let width = width, let height = height {
                    warnings.append("TR-019：采用 <scene>/<sceneSettings> 的画布尺寸 \(width)x\(height)")
                    return (width, height)
                }
            }
        }

        // 3) 再退回首层的 固定宽度/固定高度（样本 1920x1080，是文本框包围盒，不是真画布）
        if let first = layers.first,
           let fixedWidth = first.fixedWidth,
           let fixedHeight = first.fixedHeight {
            let width = Int(fixedWidth.rounded())
            let height = Int(fixedHeight.rounded())
            warnings.append("TR-019：sceneSettings 缺失，退回首层 固定宽度/固定高度 \(width)x\(height)（仅为文本框尺寸）")
            return (width, height)
        }

        // 4) 兜底
        warnings.append("TR-019：未找到任何画布尺寸来源，按默认 1920x1080 处理")
        return (1920, 1080)
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

    /// 只在一组父节点的**直接子节点**里找 name+id 同时匹配的 <parameter>。
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
        guard let parameter = parameter else { return nil }
        guard let raw = attribute(parameter, "value") ?? attribute(parameter, "default") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// <text> 的文本子节点拼接；拿不到子节点时退回 stringValue（Foundation 会保留换行）。
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
                                      default defaultValue: Bool,
                                      label: String,
                                      warnings: inout [String]) -> Bool {
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
            warnings.append("TR-019：\(label) 的 \(name)='\(raw)' 无法识别，按默认值 \(defaultValue) 处理")
            return defaultValue
        }
    }
}
