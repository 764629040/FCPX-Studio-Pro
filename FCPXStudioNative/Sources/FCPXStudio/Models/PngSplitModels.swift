import Foundation

// MARK: - TR-020 PNG 智能拆图层：候选文档 / 人工批准文档

/// candidates.json 的一个 8 邻域原始连通块（拆分操作的最小单位）。
public struct PngSplitComponent: Codable {
    public let id: Int
    public let bbox: [Int]
    public let pixels: Int
    public let rgb: [Double]
    public let hex: String
}

/// 预切候选块：一个「元素」由若干原始连通块组成。
public struct PngSplitCandidate: Codable {
    public let id: Int
    public let componentIds: [Int]
    public let bbox: [Int]
    public let pixels: Int
    public let rgb: [Double]
    public let hex: String
    public let thumb: String
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case componentIds = "component_ids"
        case bbox, pixels, rgb, hex, thumb, warnings
    }
}

public struct PngSplitAdaptive: Codable {
    public let radiusPx: Int
    public let kernelPx: Int
    public let radiusSearchCapPx: Int
    public let plateauStartPx: Int
    public let plateauEndPx: Int
    public let plateauLength: Int
    public let minGapBetweenFinalGroupsPx: Double?

    enum CodingKeys: String, CodingKey {
        case radiusPx = "radius_px"
        case kernelPx = "kernel_px"
        case radiusSearchCapPx = "radius_search_cap_px"
        case plateauStartPx = "plateau_start_px"
        case plateauEndPx = "plateau_end_px"
        case plateauLength = "plateau_length"
        case minGapBetweenFinalGroupsPx = "min_gap_between_final_groups_px"
    }
}

/// analyze 产物（只解码 UI 与批准文档需要的字段）。
public struct PngSplitDocument: Codable {
    public let source: String
    public let sourceSha256: String
    public let width: Int
    public let height: Int
    public let foregroundPixels: Int
    public let rawComponentCount: Int
    public let candidateCount: Int
    public let adaptive: PngSplitAdaptive
    public let warnings: [String]
    public let components: [PngSplitComponent]
    public let candidates: [PngSplitCandidate]

    enum CodingKeys: String, CodingKey {
        case source
        case sourceSha256 = "source_sha256"
        case width, height
        case foregroundPixels = "foreground_pixels"
        case rawComponentCount = "raw_component_count"
        case candidateCount = "candidate_count"
        case adaptive, warnings, components, candidates
    }
}

/// UI 里的可变工作块。层数由用户点「确认」时的这个数组长度决定，程序不自动增减。
public struct PngSplitBlock {
    public var name: String
    public var componentIds: [Int]
    public var bbox: [Int]
    public var pixels: Int
    public var rgb: [Double]
    public var hex: String
    public var thumbPath: String
    public var warnings: [String]

    public init(candidate: PngSplitCandidate, workDir: String) {
        self.name = String(format: "图层 %02d · %@", candidate.id, candidate.hex)
        self.componentIds = candidate.componentIds
        self.bbox = candidate.bbox
        self.pixels = candidate.pixels
        self.rgb = candidate.rgb
        self.hex = candidate.hex
        self.thumbPath = (workDir as NSString).appendingPathComponent(candidate.thumb)
        self.warnings = candidate.warnings
    }

    public init(component: PngSplitComponent, workDir: String, index: Int) {
        self.name = String(format: "拆分 %02d · %@", index, component.hex)
        self.componentIds = [component.id]
        self.bbox = component.bbox
        self.pixels = component.pixels
        self.rgb = component.rgb
        self.hex = component.hex
        self.thumbPath = ""          // 拆分后无独立缩略图，UI 用色块代替
        self.warnings = []
    }
}

// MARK: - approved.json（人工签字）

public struct PngSplitApprovedBlock: Codable {
    public let name: String
    public let componentIds: [Int]
    public let hex: String
    public let rgb: [Double]
    public let bbox: [Int]

    enum CodingKeys: String, CodingKey {
        case name
        case componentIds = "component_ids"
        case hex, rgb, bbox
    }
}

public struct PngSplitAction: Codable {
    public let action: String
    public let source: String
    public let note: String
}

public struct PngSplitApproved: Codable {
    public let schema: String
    public let source: String
    public let sourceSha256: String
    public let approvedLayerCount: Int
    public let blocks: [PngSplitApprovedBlock]
    public let operatorActions: [PngSplitAction]
    public let confirmedAt: String
    public let approvalSource: String

    enum CodingKeys: String, CodingKey {
        case schema, source
        case sourceSha256 = "source_sha256"
        case approvedLayerCount = "approved_layer_count"
        case blocks
        case operatorActions = "operator_actions"
        case confirmedAt = "confirmed_at"
        case approvalSource = "approval_source"
    }
}

public extension PngSplitApproved {
    static func make(document: PngSplitDocument,
                     blocks: [PngSplitBlock],
                     actions: [PngSplitAction],
                     approvalSource: String) -> PngSplitApproved {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return PngSplitApproved(
            schema: "tr020/v1",
            source: document.source,
            sourceSha256: document.sourceSha256,
            approvedLayerCount: blocks.count,
            blocks: blocks.map {
                PngSplitApprovedBlock(name: $0.name, componentIds: $0.componentIds,
                                      hex: $0.hex, rgb: $0.rgb, bbox: $0.bbox)
            },
            operatorActions: actions,
            confirmedAt: df.string(from: Date()),
            approvalSource: approvalSource)
    }

    func write(to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
