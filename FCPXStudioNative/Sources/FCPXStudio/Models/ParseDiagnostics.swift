import Foundation

// ═══════════════════════════════════════════════════════════════
//  ParseDiagnostics —— 解析诊断文案的纯逻辑（R32 / A-65，R33 / A-69 收紧）
//
//  R31 的病根：warnings.isEmpty → 绿色成功（失败被伪装成成功）。
//  R32 只修了「解析失败」路径；R33 又发现「解析成功但丢层」仍显示绿色
//  「✓ 矢量文字层完整提取」。
//
//  铁律（R33 / A-69）：
//    绿色「✓ 完整提取」必须同时满足：
//      1. isValid == true
//      2. warnings.isEmpty == true
//      3. counts.ignored == 0            ← 硬条件，丢 1 层也不许绿
//      4. counts.conservationHolds == true
//      5. counts.countSumHolds == true
//      6. preserved + degraded >= visibleEmitted
//      7. 桥接确实返回了 summary（旧桥接不得冒充完整）
//    任何单一条件（尤其 layers.count > 0）都不足以判成功。
// ═══════════════════════════════════════════════════════════════

public struct ParseDiagnosticsState: Equatable {
    public enum Tone: String {
        case red      // 失败 / 守恒破坏：必须显式报错
        case orange   // 成功但有忽略层、警告或数据不完整
        case green    // 真正干净、层数守恒的成功
    }

    public let resolutionText: String
    public let text: String
    public let tone: Tone

    public static func resolve(isValid: Bool,
                               failureReason: String?,
                               warnings: [String],
                               width: CGFloat,
                               height: CGFloat,
                               aspectRatio: String,
                               layerCount: Int,
                               counts: PSDLayerCounts = .empty) -> ParseDiagnosticsState {
        guard isValid else {
            let reason = failureReason ?? warnings.first ?? "未知错误"
            return ParseDiagnosticsState(
                resolutionText: "📐 画幅规格: 未知（解析失败，未采用兜底尺寸）",
                text: "✗ 解析失败：\(reason)\n请把该 PSD 反馈给开发者以便定位；本次未提取任何图层。",
                tone: .red
            )
        }

        let resolution = "📐 画幅规格: \(Int(width))×\(Int(height)) (\(aspectRatio))"

        // 层数守恒被破坏 = 有图层凭空消失，结果不可信 → 红色。
        if !counts.conservationHolds || !counts.countSumHolds {
            return ParseDiagnosticsState(
                resolutionText: resolution,
                text: "✗ 层数守恒被破坏：输入 \(counts.input) 层，"
                    + "输出 \(counts.preserved + counts.degraded) 层 + 忽略 \(counts.ignored) 层。\n"
                    + "本次结果不可信，请把该 PSD 反馈给开发者（禁止用兜底数据掩盖）。",
                tone: .red
            )
        }

        // 有图层被忽略：必须橙色明示，绝不允许再出现绿色「完整提取」。
        if counts.ignored > 0 {
            let head = counts.ignoredSummary.isEmpty
                ? "已忽略 \(counts.ignored) 层"
                : counts.ignoredSummary
            var detail = ""
            if counts.preview > 0 {
                detail = "当前列表已展开 \(layerCount) 层（含 \(counts.preview) 个隐藏预览层）。"
            } else {
                detail = "当前列表仅显示 \(layerCount) 个可见层。"
            }
            var msg = "⚠️ \(head)。\(detail)"
            if counts.hidden > 0 && counts.preview == 0 {
                msg += "\n本文件含 \(counts.hidden) 个隐藏图层，已按规范跳过；勾选「显示隐藏图层」可查看。"
            }
            if !warnings.isEmpty {
                msg += "\n提示: " + warnings.prefix(2).joined(separator: "; ")
            }
            return ParseDiagnosticsState(resolutionText: resolution, text: msg, tone: .orange)
        }

        // 桥接未返回 summary：无法证明没有丢层 → 不得绿色。
        if !counts.summaryPresent {
            return ParseDiagnosticsState(
                resolutionText: resolution,
                text: "⚠️ 解析完成，但桥接未返回层数统计，无法判定是否丢失图层；"
                    + "当前仅显示 \(layerCount) 层，请更新桥接脚本后重试。",
                tone: .orange
            )
        }

        if layerCount == 0 {
            let detail = warnings.isEmpty ? "该 PSD 可能只有背景层或全部图层被隐藏" : warnings.joined(separator: "; ")
            return ParseDiagnosticsState(
                resolutionText: resolution,
                text: "⚠️ 解析成功，但未识别到任何图层：\(detail)",
                tone: .orange
            )
        }

        if counts.preserved + counts.degraded < counts.visibleEmitted {
            return ParseDiagnosticsState(
                resolutionText: resolution,
                text: "⚠️ 层数不闭合：可见层 \(counts.visibleEmitted) 个，"
                    + "实际保留 \(counts.preserved + counts.degraded) 个，可能有图层丢失。",
                tone: .orange
            )
        }

        if !warnings.isEmpty {
            return ParseDiagnosticsState(
                resolutionText: resolution,
                text: "⚠️ 诊断提示: " + warnings.joined(separator: "; "),
                tone: .orange
            )
        }

        return ParseDiagnosticsState(
            resolutionText: resolution,
            text: "✓ 全部图层已保留（\(layerCount) 层），画幅适配正常",
            tone: .green
        )
    }
}
