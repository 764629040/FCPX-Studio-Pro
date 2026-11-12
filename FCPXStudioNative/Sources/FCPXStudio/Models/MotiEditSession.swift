// ═══════════════════════════════════════════════════════════════════════════
// TR-002-C：.moti 编辑态会话（只承载五类可写值，不改解析器 / 只读映射）
//
//   · 只读预览仍走 MotiDocumentParser.toLayerModels，一行未动；
//   · 编辑态用本文件生成「未锁死」的模型：isLocked / visible 直接取快照真值，
//     这样表格里的锁定 / 可见按钮就是 enabled / locked 的真值入口。
//   · edits() 只输出「相对写前快照确实变了」的字段，没改动 == 空数组，
//     UI 据此禁用保存，绝不产生空写。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation

/// 仅供验收硬断言使用的故障注入：模拟「写盘成功但读回不一致」，验证回填链路。
/// 生产调用不传（默认 nil），行为完全不变。
public enum MotiVerificationFault {
    case readbackMismatch
}

public final class MotiEditSession {

    public let path: String
    public private(set) var baseline: MotiDocumentSnapshot
    /// 与设计器画布 / 检查器共享同一批对象引用，UI 改动直接落到这里。
    public let models: [LayerModel]

    public init?(path: String) {
        let snap = MotiDocumentParser.parse(path: path)
        guard snap.isValid, !snap.layers.isEmpty else { return nil }
        self.path = path
        self.baseline = snap

        let built = MotiDocumentParser.toLayerModels(snap)
        for i in built.indices {
            // toLayerModels 为只读预览一律 isLocked=true；编辑态还原源真值。
            built[i].isLocked = snap.layers[i].locked
            built[i].visible  = snap.layers[i].enabled
            // TR-002-D-1-r2：只改每层首行文案，按层判（与 layerWritable 同一判据，不新增判定）。
            let chainWritableNow = snap.layers[i].positionChain == "zh"
            built[i].diagnosticNotes = [
                chainWritableNow
                    ? "编辑态：文本 / X / Y / 可见 / 锁定 可写回 .moti"
                    : "只读预览：参数链非本工具格式（Properties/Transform），本层不可写回",
                "字号 / 对齐 / 颜色 / 旋转 / 缩放本版不写回"
            ]
        }
        self.models = built
    }

    /// TR-002-D-1 BUG-4D1-1：层可写性查询。positionChain == "zh" 才可写；
    /// "en"（英文链）与 ""（两种都不是）一律不可写。索引越界按不可写处理（宁拒勿假）。
    public func layerWritable(index: Int) -> Bool {
        guard index >= 0, index < baseline.layers.count else { return false }
        return baseline.layers[index].positionChain == "zh"
    }

    /// TR-002-D-1 BUG-4D1-1：不可写层改动自检——edits() 里第一个落在不可写层
    /// 的层号；全部落在可写层时返回 nil。edits() 语义一行未动。
    public func firstUnwritableEditLayer() -> Int? {
        for edit in edits() where !layerWritable(index: edit.index) {
            return edit.index
        }
        return nil
    }

    /// TR-002-D-1 BUG-4D1-1：可写层总数（edit_moti_open 日志用：
    /// 文件可写 ≠ 这一层可写，564 层英文链模板应为 0）。
    public var editableLayerCount: Int {
        return baseline.layers.filter { $0.positionChain == "zh" }.count
    }

    /// 保存成功后把基线刷新为写后重解析结果，UI 立即回到「无改动」。
    public func refreshBaselineAfterSave() {
        let snap = MotiDocumentParser.parse(path: path)
        if snap.isValid { baseline = snap }
    }

    /// 相对写前快照的增量。X/Y 用数值比较，避免 "0" 与 "0.0" 被当成改动。
    public func edits() -> [MotiLayerEdit] {
        var result: [MotiLayerEdit] = []
        for i in models.indices {
            guard i < baseline.layers.count else { break }
            let m = models[i]
            let b = baseline.layers[i]
            var edit = MotiLayerEdit(index: i)
            if m.text != b.text { edit.text = m.text }
            if abs(m.posX - b.posX) > 1e-9 { edit.x = String(m.posX) }
            if abs(m.posY - b.posY) > 1e-9 { edit.y = String(m.posY) }
            if m.visible != b.enabled { edit.enabled = m.visible }
            if m.isLocked != b.locked { edit.locked = m.isLocked }
            if !edit.isEmpty { result.append(edit) }
        }
        return result
    }

    /// 确认弹窗里「将改几处」的数字：按字段数，不按层数。
    public var changeCount: Int {
        return edits().reduce(0) { total, e in
            var n = 0
            if e.text != nil { n += 1 }
            if e.x != nil { n += 1 }
            if e.y != nil { n += 1 }
            if e.enabled != nil { n += 1 }
            if e.locked != nil { n += 1 }
            return total + n
        }
    }

    public var writable: (Bool, String) {
        return MotiWriteBack.canWrite(path: path)
    }
}
