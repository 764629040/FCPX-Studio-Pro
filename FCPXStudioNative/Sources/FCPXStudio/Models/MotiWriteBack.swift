// ═══════════════════════════════════════════════════════════════════════════
// TR-002-C：.moti 五值单点字节写回（文本 / X / Y / enabled / locked）
//
// 【硬口径】
//   · 只做单点字节替换：数值改 @value 引号内、文本改 <text> 内容区间、
//     布尔改 layer 开标签的 enabled/locked 引号内；
//     属性缺失时在该 layer 的 `>` 前【单点插入】，同一插入点合并为一个 op。
//   · 绝不调用 XMLDocument.xmlData 整树重写。注释 / DOCTYPE / tab 缩进 /
//     属性顺序 / @default / LF / 无 BOM 全部零变化（非目标字节由构造式保证）。
//   · 定位严格按祖先链尾段（属性1/变换100/位置101）+ 内层归属，禁止全局按
//     id 或 name 搜：样本里 id="1" 出现 16 次，全局搜索必然误伤缩放链的 X/Y。
//   · 层边界按 </layer> 配对，不用「下一层起点」，兼容 564 层嵌套模板。
//   · 文本 XML 转义 & < >，换行原样保留。
//
// 【安全口径】
//   · 备份：~/Library/Application Support/FCPXStudioPro/moti_backups/
//           <原名去扩展名>.<YYYYMMDDHHMMSS>.moti.bak（扩展名是 .bak，不在模板目录）。
//   · 备份写完 fsync，且备份 sha256 必须 == 写前 sha256，否则中止、不写回。
//   · 写入：同卷临时文件 → FileHandle 写 → fsync → chmod/chown 还原 → rename 原子替换。
//   · 写后 MotiDocumentParser.parse 重解析，五值逐项比对；任一不一致或任何异常
//     → 从备份原子回填，原文件 sha256 必须回到写前值，并抛出明确错误。
//
// 【不做】字号 / 对齐 / 颜色 / 旋转 / 缩放 / 图层结构 / 时间线 / 整树重写。
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import CryptoKit
import Darwin

// MARK: - 数据模型

/// 一层的写回请求。nil 表示「这一项不改」，绝不会被写盘。
public struct MotiLayerEdit {
    public let index: Int
    public var text: String?
    public var x: String?
    public var y: String?
    public var enabled: Bool?
    public var locked: Bool?

    public init(index: Int, text: String? = nil, x: String? = nil, y: String? = nil,
                enabled: Bool? = nil, locked: Bool? = nil) {
        self.index = index
        self.text = text
        self.x = x
        self.y = y
        self.enabled = enabled
        self.locked = locked
    }

    public var isEmpty: Bool {
        return text == nil && x == nil && y == nil && enabled == nil && locked == nil
    }
}

/// 一次单点替换的描述（供验收脚本逐项自证、算 delta、列命中行）。
public struct MotiReplaceOpInfo {
    public let label: String
    public let range: Range<Int>
    public let replacement: [UInt8]

    public init(label: String, range: Range<Int>, replacement: [UInt8]) {
        self.label = label
        self.range = range
        self.replacement = replacement
    }
}

/// 重解析读回表的一行。
public struct MotiReadbackRow: CustomStringConvertible {
    public let layerIndex: Int
    public let field: String
    public let expected: String
    public let actual: String
    public let matched: Bool

    public init(layerIndex: Int, field: String, expected: String, actual: String,
                matched: Bool? = nil) {
        self.layerIndex = layerIndex
        self.field = field
        self.expected = expected
        self.actual = actual
        self.matched = matched ?? (expected == actual)
    }

    public var description: String {
        return "L\(layerIndex) \(field) expect=\(expected) actual=\(actual) \(matched ? "OK" : "MISMATCH")"
    }
}

/// 已计划写回的字段值（供写后 parse 读回比对）。
public struct MotiPlannedValue {
    public let index: Int
    public let field: String
    public let expected: String
    /// X/Y 用数值容差比对，避免「写 100.25、读回按 %.1f 显示 100.2」被误判为不一致。
    public let expectedNumber: Double?

    public init(index: Int, field: String, expected: String, expectedNumber: Double? = nil) {
        self.index = index
        self.field = field
        self.expected = expected
        self.expectedNumber = expectedNumber
    }
}

public struct MotiWriteOutcome {
    public let beforeSHA: String
    public let afterSHA: String
    public let backupPath: String
    public let backupSHA: String
    public let beforeBytes: Int
    public let afterBytes: Int
    public let expectedDelta: Int
    public let actualDelta: Int
    public let changedCount: Int
    public let changedLines: [Int]
    public let readback: [MotiReadbackRow]
}

public enum MotiWriteError: LocalizedError {
    case fileNotFound(String)
    case unreadable(String)
    case notWritable(String)
    case backupFailed(String)
    case backupHashMismatch(expected: String, actual: String)
    case landingFailed(String)
    case noChange
    case writeFailed(String)
    case parseAfterWrite(String)
    case readbackMismatch([MotiReadbackRow])
    case rollbackFailed(before: String, after: String)
    case emptyLayerList
    case invalidNumber(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "找不到模板文件：\(p)"
        case .unreadable(let p): return "模板文件读不出来：\(p)"
        case .notWritable(let w): return "目标不可写（只读卷或无写权限），已禁用保存：\(w)"
        case .backupFailed(let w): return "备份失败，已中止写回：\(w)"
        case .backupHashMismatch(let e, let a): return "备份 sha 不等于写前 sha（\(e) / \(a)），已中止写回"
        case .landingFailed(let w): return "XML 落点定位失败：\(w)"
        case .noChange: return "没有任何改动，不允许保存"
        case .writeFailed(let w): return "写回失败，已回填：\(w)"
        case .parseAfterWrite(let w): return "写后重解析失败：\(w)"
        case .readbackMismatch(let rows):
            let bad = rows.filter { !$0.matched }.map(\.description).joined(separator: "; ")
            return "写后读回不一致，已回填：\(bad)"
        case .rollbackFailed(let b, let a): return "回填失败！写前 sha=\(b) 当前 sha=\(a)，请立即从备份手工恢复"
        case .emptyLayerList: return "模板没有解析出任何图层"
        case .invalidNumber(let v): return "非法数值：\(v)"
        }
    }
}

// MARK: - 字节级标签节点

private struct TagKey: Equatable {
    let tag: String
    let id: String
    let name: String
}

private struct AttrSpan {
    let value: String
    let range: Range<Int>       // 引号内的字节区间（不含引号）
}

private struct TagNode {
    let tag: String
    let start: Int              // '<' 的字节偏移
    let end: Int                // '>' 之后的字节偏移
    let attributes: [String: AttrSpan]
    let selfClosing: Bool
    let path: [TagKey]          // 开标签时的祖先链（不含自己）
    let layerIndex: Int         // 该 layer 是文档里第几个（从 0）；非 layer 节点为 -1
    let enclosingLayer: Int     // 所在的最内层 layer 序号；-1 = 不在任何 layer 内
}

private struct ReplaceOp {
    let range: Range<Int>
    let replacement: [UInt8]
    let label: String
}

// MARK: - 主实现

public final class MotiWriteBack {

    private init() {}

    // MARK: 公开：可写性预检

    /// 只读卷 / 无写权限判定。返回 (可写, 说明)。用于 UI 直接禁用保存按钮。
    public static func canWrite(path: String) -> (Bool, String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return (false, "文件不存在") }
        guard fm.isReadableFile(atPath: path) else { return (false, "文件不可读") }
        guard fm.isWritableFile(atPath: path) else { return (false, "文件没有写权限") }
        let dir = (path as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: dir) else { return (false, "所在目录不可写，无法原子替换") }
        // 卷只读标志：st.f_flags 是 UInt32，MNT_RDONLY 在 Darwin 下是 Int32
        var st = statfs()
        if statfs((dir as NSString).fileSystemRepresentation, &st) == 0,
           (st.f_flags & UInt32(MNT_RDONLY)) != 0 {
            return (false, "所在卷为只读挂载")
        }
        return (true, "可写")
    }

    /// 本次保存会用到的备份完整路径（UI 在确认弹窗里显示同一个路径）。
    public static func backupPath(for sourcePath: String, date: Date = Date()) -> String {
        let home = NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(
            "Library/Application Support/FCPXStudioPro/moti_backups")
        let base = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (dir as NSString).appendingPathComponent("\(base).\(fmt.string(from: date)).moti.bak")
    }

    // MARK: 公开：字节替换（纯函数，可单独取证）

    /// 只做「原始字节 → 新字节」的单点替换，不落盘、不备份。
    /// 返回 (新字节, ops 描述)。供 harness 与验收脚本逐项自证。
    public static func transformedBytes(_ original: Data,
                                        edits: [MotiLayerEdit])
        -> (data: Data, ops: [MotiReplaceOpInfo]) {
        let bytes = [UInt8](original)
        guard let scanned = try? scan(bytes), !scanned.layers.isEmpty,
              let built = try? buildOps(bytes: bytes, scanned: scanned, edits: edits),
              !built.ops.isEmpty else {
            return (original, [])
        }
        let (data, infos) = construct(bytes: bytes, ops: built.ops)
        return (data, infos)
    }

    /// 构造式替换：从原始字节出发，倒序套用 ops；非目标字节逐段零变化。
    private static func construct(bytes: [UInt8], ops: [ReplaceOp])
        -> (Data, [MotiReplaceOpInfo]) {
        var out = bytes
        for op in ops.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(op.range, with: op.replacement)
        }
        let infos = ops.map { MotiReplaceOpInfo(label: $0.label,
                                                range: $0.range,
                                                replacement: $0.replacement) }
        return (Data(out), infos)
    }

    /// 验收用：用 (写前字节 + ops) 重建，必须逐字节等于写后字节。
    public static func constructedEquals(before: Data, ops: [MotiReplaceOpInfo],
                                          after: Data) -> Bool {
        let rebuilt: [ReplaceOp] = ops.map {
            ReplaceOp(range: $0.range, replacement: $0.replacement, label: $0.label)
        }
        let (data, _) = construct(bytes: [UInt8](before), ops: rebuilt)
        return data == after
    }

    // MARK: 公开：完整写回

    /// 完整写回：备份 → 原子替换 → parse 重解析五值比对 → 失败回填。
    /// 成功时 outcome 内含三组 sha、delta、命中行号与读回表。
    public static func apply(path: String, edits: [MotiLayerEdit],
                             plannedBackupPath: String? = nil,
                             fault: MotiVerificationFault? = nil) throws -> MotiWriteOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw MotiWriteError.fileNotFound(path) }
        let before: Data
        do { before = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw MotiWriteError.unreadable(path) }
        let beforeSHA = sha256(before)

        let (writable, why) = canWrite(path: path)
        guard writable else { throw MotiWriteError.notWritable(why) }

        // ── 1. 落点扫描（严格祖先链 + 内层归属） ──────────────────────────
        let bytes = [UInt8](before)
        let scanned = try scan(bytes)
        guard !scanned.layers.isEmpty else { throw MotiWriteError.emptyLayerList }
        let baseline = MotiDocumentParser.parse(path: path)
        guard baseline.isValid, baseline.layers.count == scanned.layers.count else {
            throw MotiWriteError.landingFailed("parse 层数与字节扫描层数不一致")
        }

        // ── 2. 构造单点 ops ───────────────────────────────────────────────
        let built = try buildOps(bytes: bytes, scanned: scanned, edits: edits)
        let ops = built.ops
        guard !ops.isEmpty else { throw MotiWriteError.noChange }

        let (after, opInfos) = construct(bytes: bytes, ops: ops)
        let expectedDelta = ops.reduce(0) { $0 + $1.replacement.count - $1.range.count }
        let actualDelta = after.count - before.count
        guard expectedDelta == actualDelta else {
            throw MotiWriteError.landingFailed("delta 不守恒 \(expectedDelta)/\(actualDelta)")
        }
        let afterSHA = sha256(after)

        // ── 3. 备份（先写完 + fsync + sha 校验） ────────────────────────────
        // plannedBackupPath 由确认弹窗先算好并显示给用户，保证「弹窗里写的」就是「实际用的」。
        let backup = plannedBackupPath ?? backupPath(for: path)
        let backupDir = (backup as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        } catch {
            throw MotiWriteError.backupFailed("建备份目录失败 \(error.localizedDescription)")
        }
        do {
            try writeAtomicallyPreservingMetadata(data: before, to: backup,
                                                  referencePath: path, isNew: true)
        } catch {
            throw MotiWriteError.backupFailed(error.localizedDescription)
        }
        let backupData: Data
        do { backupData = try Data(contentsOf: URL(fileURLWithPath: backup)) }
        catch { throw MotiWriteError.backupFailed("备份回读失败 \(error.localizedDescription)") }
        let backupSHA = sha256(backupData)
        guard backupSHA == beforeSHA else {
            throw MotiWriteError.backupHashMismatch(expected: beforeSHA, actual: backupSHA)
        }

        // ── 4. 原子替换原文件 ─────────────────────────────────────────────
        do {
            try writeAtomicallyPreservingMetadata(data: after, to: path,
                                                  referencePath: path, isNew: false)
        } catch {
            try? rollback(from: backup, to: path, referencePath: path)
            throw MotiWriteError.writeFailed(error.localizedDescription)
        }

        // ── 5. 写后自检：parse 重解析五值逐项比对 ──────────────────────────
        do {
            let rows = try verifyReadback(path: path, baseline: baseline, planned: built.planned)
            // 验收故障注入：模拟「写盘成功但读回不一致」，走与真实不一致完全相同的回填链路。
            if fault == .readbackMismatch {
                try rollback(from: backup, to: path, referencePath: path)
                let injected = MotiReadbackRow(layerIndex: 0, field: "FAULT",
                                               expected: "inject", actual: "inject",
                                               matched: false)
                throw MotiWriteError.readbackMismatch([injected])
            }
            let mismatches = rows.filter { !$0.matched }
            if !mismatches.isEmpty {
                try rollback(from: backup, to: path, referencePath: path)
                throw MotiWriteError.readbackMismatch(rows)
            }
            let changedLines = targetLineNumbers(before: before, ops: opInfos)
            return MotiWriteOutcome(beforeSHA: beforeSHA,
                                    afterSHA: afterSHA,
                                    backupPath: backup,
                                    backupSHA: backupSHA,
                                    beforeBytes: before.count,
                                    afterBytes: after.count,
                                    expectedDelta: expectedDelta,
                                    actualDelta: actualDelta,
                                    changedCount: built.planned.count,
                                    changedLines: changedLines,
                                    readback: rows)
        } catch let e as MotiWriteError {
            throw e
        } catch {
            try? rollback(from: backup, to: path, referencePath: path)
            throw MotiWriteError.parseAfterWrite(error.localizedDescription)
        }
    }

    // MARK: 公开：只读验证（不落盘，用于验收）

    public static func verifyReadback(path: String,
                                      baseline: MotiDocumentSnapshot,
                                      planned: [MotiPlannedValue]) throws -> [MotiReadbackRow] {
        let snap = MotiDocumentParser.parse(path: path)
        guard snap.isValid else {
            throw MotiWriteError.parseAfterWrite(snap.failureReason ?? "XML 无法解析")
        }
        guard snap.layers.count == baseline.layers.count else {
            throw MotiWriteError.parseAfterWrite("层数变化 \(baseline.layers.count)→\(snap.layers.count)")
        }
        var rows: [MotiReadbackRow] = []
        for p in planned {
            guard p.index >= 0, p.index < snap.layers.count else {
                rows.append(MotiReadbackRow(layerIndex: p.index, field: p.field,
                                            expected: p.expected, actual: "层越界",
                                            matched: false))
                continue
            }
            let layer = snap.layers[p.index]
            let actual: String
            var matched: Bool? = nil
            switch p.field {
            case "text":
                actual = layer.text
            case "X":
                actual = String(layer.posX)
                if let e = p.expectedNumber { matched = abs(layer.posX - e) < 1e-9 }
            case "Y":
                actual = String(layer.posY)
                if let e = p.expectedNumber { matched = abs(layer.posY - e) < 1e-9 }
            case "enabled":
                actual = layer.enabled ? "true" : "false"
            case "locked":
                actual = layer.locked ? "true" : "false"
            default:
                actual = "?"
            }
            rows.append(MotiReadbackRow(layerIndex: p.index, field: p.field,
                                        expected: p.expected, actual: actual,
                                        matched: matched))
        }
        return rows
    }

    /// 写后文件的实际 changed 行数（按 LF 分行，逐行比对）。
    /// 注意：文本节点若改变了 LF 行数，逐行比对会把后续所有行都算成差异；
    /// 验收「只命中目标行」请用 targetLineNumbers(before:ops:)。
    public static func changedLineNumbers(before: Data, after: Data) -> [Int] {
        let lo = before.split(separator: 0x0A, omittingEmptySubsequences: false)
        let ln = after.split(separator: 0x0A, omittingEmptySubsequences: false)
        var result: [Int] = []
        for i in 0..<min(lo.count, ln.count) where lo[i] != ln[i] { result.append(i + 1) }
        return result
    }

    /// 按「单点替换的整个字节区间」反查写前文件的行号：目标行清单。
    /// 多行 <text> 节点会让 4 行都算目标行；与文本换行数变化无关。
    public static func targetLineNumbers(before: Data, ops: [MotiReplaceOpInfo]) -> [Int] {
        let b = [UInt8](before)
        var lineStarts: [Int] = [0]
        for (i, c) in b.enumerated() where c == 0x0A { lineStarts.append(i + 1) }
        func lineIndex(_ offset: Int) -> Int {
            var l = 0
            var r = lineStarts.count - 1
            while l < r {
                let m = (l + r + 1) / 2
                if lineStarts[m] <= offset { l = m } else { r = m - 1 }
            }
            return l
        }
        var lines = Set<Int>()
        for op in ops {
            let first = lineIndex(op.range.lowerBound)
            let last = lineIndex(max(op.range.lowerBound, op.range.upperBound))
            for n in first...last { lines.insert(n + 1) }
        }
        return lines.sorted()
    }

    // MARK: - 内部：落点扫描

    private struct Scanned {
        let nodes: [TagNode]
        let layers: [TagNode]
        /// layer 序号 → 该层 `</layer>` 的起始字节偏移（自闭合层为开标签 end）。
        let layerEnds: [Int: Int]
    }

    private static func scan(_ b: [UInt8]) throws -> Scanned {
        var nodes: [TagNode] = []
        var stack: [TagKey] = []
        var layerStack: [Int] = []
        var layerEnds: [Int: Int] = [:]
        var layerCounter = -1
        var i = 0
        let n = b.count
        while i < n {
            guard b[i] == 0x3C else { i += 1; continue }   // '<'

            // 注释 / CDATA / PI / DOCTYPE：整段跳过，内部出现的 <layer 一律不算
            if let skip = ignorableEnd(b, at: i) {
                i = skip
                continue
            }

            // 找匹配的 '>'（跳过引号内部）
            var j = i + 1
            var quote: UInt8 = 0
            while j < n {
                let c = b[j]
                if quote != 0 {
                    if c == quote { quote = 0 }
                } else if c == 0x22 || c == 0x27 {   // " '
                    quote = c
                } else if c == 0x3E {                 // '>'
                    break
                }
                j += 1
            }
            guard j < n else { break }
            let end = j + 1

            if i + 1 < n, b[i + 1] == 0x2F {           // '</...>'
                let nm = asciiString(b, from: i + 2, to: end - 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if nm == "layer", let ordinal = layerStack.popLast() {
                    layerEnds[ordinal] = i
                }
                if let k = stack.lastIndex(where: { $0.tag == nm }) {
                    stack.removeSubrange(k...)
                }
                i = end
                continue
            }

            var cursor = i + 1
            while cursor < end - 1, isSpace(b[cursor]) { cursor += 1 }
            let nameStart = cursor
            while cursor < end - 1, isNameChar(b[cursor]) { cursor += 1 }
            let tag = asciiString(b, from: nameStart, to: cursor)
            guard !tag.isEmpty else { i = end; continue }

            var attrs: [String: AttrSpan] = [:]
            var k = cursor
            while k < end - 1 {
                while k < end - 1, isSpace(b[k]) { k += 1 }
                guard k < end - 1, isNameChar(b[k]) else { k += 1; continue }
                let aStart = k
                while k < end - 1, isNameChar(b[k]) { k += 1 }
                let aName = asciiString(b, from: aStart, to: k)
                while k < end - 1, isSpace(b[k]) { k += 1 }
                guard k < end - 1, b[k] == 0x3D else { continue }  // '='
                k += 1
                while k < end - 1, isSpace(b[k]) { k += 1 }
                guard k < end - 1, b[k] == 0x22 || b[k] == 0x27 else { continue }
                let q = b[k]
                k += 1
                let vStart = k
                while k < end - 1, b[k] != q { k += 1 }
                let vEnd = k
                if k < end - 1 { k += 1 }
                attrs[aName] = AttrSpan(value: utf8String(b, from: vStart, to: vEnd),
                                        range: vStart..<vEnd)
            }

            let selfClosing = (end >= 2 && b[end - 2] == 0x2F)   // '/>'
            let enclosing = layerStack.last ?? -1
            if tag == "layer" { layerCounter += 1 }
            let key = TagKey(tag: tag,
                             id: attrs["id"]?.value ?? "",
                             name: attrs["name"]?.value ?? "")
            nodes.append(TagNode(tag: tag, start: i, end: end, attributes: attrs,
                                 selfClosing: selfClosing, path: stack,
                                 layerIndex: tag == "layer" ? layerCounter : -1,
                                 enclosingLayer: enclosing))
            if !selfClosing {
                stack.append(key)
                if tag == "layer" { layerStack.append(layerCounter) }
            } else if tag == "layer" {
                layerEnds[layerCounter] = end
            }
            i = end
        }
        return Scanned(nodes: nodes,
                       layers: nodes.filter { $0.tag == "layer" },
                       layerEnds: layerEnds)
    }

    /// 返回「可忽略块」的结束偏移（整块跳过），非忽略块返回 nil。
    private static func ignorableEnd(_ b: [UInt8], at i: Int) -> Int? {
        let n = b.count
        if match(b, i, "<!--") {
            var q = i + 4
            while q + 2 < n {
                if b[q] == 0x2D && b[q + 1] == 0x2D && b[q + 2] == 0x3E { return q + 3 }
                q += 1
            }
            return n
        }
        if match(b, i, "<![CDATA[") {
            var q = i + 9
            while q + 2 < n {
                if b[q] == 0x5D && b[q + 1] == 0x5D && b[q + 2] == 0x3E { return q + 3 }
                q += 1
            }
            return n
        }
        if match(b, i, "<?") {
            var q = i + 2
            while q + 1 < n {
                if b[q] == 0x3F && b[q + 1] == 0x3E { return q + 2 }
                q += 1
            }
            return n
        }
        if match(b, i, "<!") {
            var q = i + 2
            while q < n, b[q] != 0x3E { q += 1 }
            return min(n, q + 1)
        }
        return nil
    }

    private static func match(_ b: [UInt8], _ i: Int, _ s: String) -> Bool {
        let a = Array(s.utf8)
        guard i + a.count <= b.count else { return false }
        return Array(b[i..<(i + a.count)]) == a
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }
    private static func isNameChar(_ c: UInt8) -> Bool {
        return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x3A
            || c == 0x2D || c == 0x2E || c >= 0x80
    }
    private static func asciiString(_ b: [UInt8], from: Int, to: Int) -> String {
        guard from < to, from >= 0, to <= b.count else { return "" }
        return String(decoding: b[from..<to], as: UTF8.self)
    }
    private static func utf8String(_ b: [UInt8], from: Int, to: Int) -> String {
        return asciiString(b, from: from, to: to)
    }

    // MARK: - 内部：构造 ops

    /// 位置链两套写法：中文模板（属性/变换/位置）与英文模板
    /// （Properties/Transform/Position，564 层大模板实测）。id 仍严格 1/100/101，
    /// 禁止只按 id 全局搜——样本里 id="1" 出现 16 次。
    private static let positionChainZH: [TagKey] = [
        TagKey(tag: "parameter", id: "1",   name: "属性"),
        TagKey(tag: "parameter", id: "100", name: "变换"),
        TagKey(tag: "parameter", id: "101", name: "位置")
    ]
    private static let positionChainEN: [TagKey] = [
        TagKey(tag: "parameter", id: "1",   name: "Properties"),
        TagKey(tag: "parameter", id: "100", name: "Transform"),
        TagKey(tag: "parameter", id: "101", name: "Position")
    ]

    private static func buildOps(bytes: [UInt8], scanned: Scanned,
                                 edits: [MotiLayerEdit]) throws
        -> (ops: [ReplaceOp], planned: [MotiPlannedValue]) {
        var ops: [ReplaceOp] = []
        var planned: [MotiPlannedValue] = []
        var insertions: [Int: [(String, String)]] = [:]   // 插入点 → (attr, value)
        let nodes = scanned.nodes
        let layers = scanned.layers

        for e in edits where !e.isEmpty {
            guard e.index >= 0, e.index < layers.count else { continue }
            let L = layers[e.index]
            // 层边界用本层 </layer>，嵌套子层不会被算进父层；节点再按 enclosingLayer 归属过滤
            let hi = scanned.layerEnds[e.index]
                ?? ((e.index + 1 < layers.count) ? layers[e.index + 1].start : bytes.count)
            let subtree = nodes.filter {
                $0.start > L.start && $0.start < hi && $0.enclosingLayer == e.index
            }

            // X / Y：严格祖先链尾段 == 属性1/变换100/位置101
            for (field, pname, pid, value) in [
                ("X", "X", "1", e.x), ("Y", "Y", "2", e.y)
            ] as [(String, String, String, String?)] {
                guard let raw = value else { continue }
                guard let normalized = normalizeNumber(raw) else {
                    throw MotiWriteError.invalidNumber(raw)
                }
                guard let target = subtree.first(where: { node in
                    node.tag == "parameter"
                        && node.attributes["name"]?.value == pname
                        && node.attributes["id"]?.value == pid
                        && (chainMatches(node.path, positionChainZH)
                            || chainMatches(node.path, positionChainEN))
                }), let span = target.attributes["value"] else {
                    throw MotiWriteError.landingFailed("L\(e.index) \(field) 落点未找到")
                }
                ops.append(ReplaceOp(range: span.range,
                                     replacement: Array(normalized.utf8),
                                     label: "L\(e.index) \(field)"))
                planned.append(MotiPlannedValue(index: e.index, field: field,
                                                expected: normalized,
                                                expectedNumber: Double(normalized)))
            }

            // 文本：parameter[文本,369] 之后的第一个 <text>…</text> 内容区间
            if let t = e.text {
                if let tp = subtree.first(where: { $0.tag == "parameter"
                    && $0.attributes["name"]?.value == "文本"
                    && $0.attributes["id"]?.value == "369" }),
                   let span = textContentSpan(bytes: bytes, from: tp.end, to: hi) {
                    let escaped = escapeXML(t)
                    ops.append(ReplaceOp(range: span,
                                         replacement: Array(escaped.utf8),
                                         label: "L\(e.index) text"))
                    planned.append(MotiPlannedValue(index: e.index, field: "text",
                                                    expected: t))
                } else {
                    throw MotiWriteError.landingFailed("L\(e.index) text 落点未找到")
                }
            }

            // enabled / locked：属性存在→替换；缺失→ layer `>` 前单点插入
            for (field, raw) in [("enabled", e.enabled), ("locked", e.locked)] {
                guard let v = raw else { continue }
                let text = v ? "1" : "0"
                if let span = L.attributes[field] {
                    ops.append(ReplaceOp(range: span.range,
                                         replacement: Array(text.utf8),
                                         label: "L\(e.index) \(field)"))
                } else {
                    insertions[L.end - 1, default: []].append((field, text))
                }
                planned.append(MotiPlannedValue(index: e.index, field: field,
                                                expected: v ? "true" : "false"))
            }
        }

        // 同一插入点合并成一个 op，顺序固定 enabled → locked
        for (pos, pairs) in insertions {
            let ordered = pairs.sorted { $0.0 == "enabled" && $1.0 != "enabled" }
            let text = ordered.map { " \($0.0)=\"\($0.1)\"" }.joined()
            ops.append(ReplaceOp(range: pos..<pos, replacement: Array(text.utf8),
                                 label: "insert@\(pos)"))
        }

        // 区间不重叠断言（同位置插入已合并）
        let sorted = ops.sorted { $0.range.lowerBound < $1.range.lowerBound }
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                if sorted[i].range.lowerBound < sorted[i - 1].range.upperBound {
                    // 定位异常：宁可不写，也不写坏文件
                    throw MotiWriteError.landingFailed("落点区间重叠，已中止")
                }
            }
        }
        return (ops, planned)
    }

    private static func chainMatches(_ path: [TagKey], _ chain: [TagKey]) -> Bool {
        guard path.count >= chain.count else { return false }
        return Array(path.suffix(chain.count)) == chain
    }

    private static func textContentSpan(bytes: [UInt8], from: Int, to: Int) -> Range<Int>? {
        let open = Array("<text".utf8)
        let close = Array("</text>".utf8)
        var i = from
        while i + open.count <= to {
            if Array(bytes[i..<(i + open.count)]) == open {
                // 找到开标签的 '>'
                var j = i + open.count
                while j < to, bytes[j] != 0x3E { j += 1 }
                guard j < to else { return nil }
                let contentStart = j + 1
                var k = contentStart
                while k + close.count <= to {
                    if Array(bytes[k..<(k + close.count)]) == close {
                        return contentStart..<k
                    }
                    k += 1
                }
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(ch)
            }
        }
        return out
    }

    /// 只做合法性校验与去空白，绝不改写用户数值（写进去什么就是什么）。
    private static func normalizeNumber(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
        return t.replacingOccurrences(of: ",", with: ".")
    }

    /// 只用于显示 / 读回表，不改变写盘数值。
    public static func fmt(_ d: Double) -> String {
        let s = String(format: "%.1f", d)
        return s.contains(",") ? s.replacingOccurrences(of: ",", with: ".") : s
    }

    // MARK: - 内部：原子写 / 回填 / sha

    /// 同卷临时文件 + fsync + 权限属主还原 + rename 原子替换。
    private static func writeAtomicallyPreservingMetadata(data: Data, to path: String,
                                                          referencePath: String,
                                                          isNew: Bool) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(
            ".tr002c_tmp_\(UUID().uuidString)")

        var mode: mode_t = 0o644
        var uid: uid_t = 0
        var gid: gid_t = 0
        var hasMeta = false
        var st = stat()
        if stat((referencePath as NSString).fileSystemRepresentation, &st) == 0 {
            mode = st.st_mode & 0o7777
            uid = st.st_uid
            gid = st.st_gid
            hasMeta = true
        }

        guard FileManager.default.createFile(atPath: tmp, contents: nil) else {
            throw NSError(domain: "MotiWriteBack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件"])
        }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
        do {
            try fh.write(contentsOf: data)
            if #available(macOS 10.15, *) { try fh.synchronize() }
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
        // 目录项 fsync，保证 rename 落盘
        let dfd = open((dir as NSString).fileSystemRepresentation, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }

        if hasMeta {
            _ = chmod((tmp as NSString).fileSystemRepresentation, mode)
            _ = chown((tmp as NSString).fileSystemRepresentation, uid, gid)
        }
        if isNew {
            // 备份文件：目标可能已存在（同一秒内重复保存），先移除再 rename
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        guard rename((tmp as NSString).fileSystemRepresentation,
                     (path as NSString).fileSystemRepresentation) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "MotiWriteBack", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "rename 失败 errno=\(errno)"])
        }
    }

    private static func rollback(from backup: String, to path: String,
                                 referencePath: String) throws {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: backup)) else { return }
        try? writeAtomicallyPreservingMetadata(data: d, to: path,
                                               referencePath: referencePath, isNew: false)
        let now = (try? Data(contentsOf: URL(fileURLWithPath: path))).map(sha256) ?? ""
        if now != sha256(d) {
            throw MotiWriteError.rollbackFailed(before: sha256(d), after: now)
        }
    }

    public static func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
