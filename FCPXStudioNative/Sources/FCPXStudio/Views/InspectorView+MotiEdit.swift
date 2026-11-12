// ═══════════════════════════════════════════════════════════════════════════
// TR-002-C：.moti 编辑态 UI 配置（扩展，不改动 TR-019-R / TR-025 / TR-026 代码）
//
//   · applyMotiReadOnlyText() 一行未动，只读预览截图基线保持逐字节相同；
//   · 编辑态走 motiReadOnlyMode = false + 本扩展的 applyMotiEditMode()；
//   · 只放行文本 / X / Y / 可见 / 锁定；其余控件置灰并标「本版不写回 .moti」，
//     避免「UI 能改但没写回」的假功能；
//   · 发布列（表头）与发布勾选组整块隐藏，.moti 没有发布概念。
// ═══════════════════════════════════════════════════════════════════════════

import AppKit

/// 文本编辑桥：把 NSTextView 的用户输入同步回 LayerModel.text。
/// 由 MainWindowController 持有，只在编辑态挂到 textEditor.delegate；
/// 程序化 textEditor.string = ... 不会触发 textDidChange，不会误写。
public final class MotiTextEditBridge: NSObject, NSTextViewDelegate {
    public var onChange: ((String) -> Void)?

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        // 只有用户正在这个输入框里编辑时才同步回 model。
        // 程序化 textEditor.string = …、Auto Layout 重排、窗口首次显示时
        // NSTextView 也可能抛 textDidChange；若照单全收会把当时的空串写回
        // LayerModel.text，导致保存时把文本清空（真机取证实测到过）。
        guard tv.window?.firstResponder === tv else { return }
        onChange?(tv.string)
    }
}

extension InspectorView {

    private static let motiEditToolTip = "本版不写回 .moti"
    /// TR-002-D BUG-4D-1：非中文链时的固定提示文案（与问题单逐字一致，不许改字）。
    private static let motiChainUnsupportedTip =
        "该模板参数链非本工具格式（Properties/Transform/Position），X/Y 不可写"

    /// TR-002-D BUG-4D-1：当前选中层的位置链形态。读会话快照，不改会话。
    /// 拿不到会话 / 对不上索引时按 "zh" 处理（与既有行为零变化，不误伤中文链模板）。
    private var motiEditPositionChain: String {
        guard let controller = window?.windowController as? MainWindowController,
              let session = controller.motiEditSession,
              let layer = currentSelectedLayer,
              let idx = session.models.firstIndex(where: { $0 === layer }),
              idx < session.baseline.layers.count else { return "zh" }
        return session.baseline.layers[idx].positionChain
    }

    /// 编辑态配置。幂等；每次切图层 / 控件状态刷新后由主控制器再调一次。
    public func applyMotiEditMode() {
        guard motiEditMode else { return }
        let tip = InspectorView.motiEditToolTip

        // ── 发布列 + 发布勾选组：整块隐藏（含表头） ──────────────────────
        if let table = layerTableView,
           let col = table.tableColumns.first(where: { $0.identifier.rawValue == "pub" }) {
            table.removeTableColumn(col)
        }
        for v in motiPublishGroupViews { v.isHidden = true }

        // ── 只放行五类值；非中文链层 X/Y 置灰并显示「—」（BUG-4D-1） ─────
        textEditor?.isEditable = true
        textEditor?.textColor = .white
        let chainWritable = motiEditPositionChain == "zh"
        let chainTip = InspectorView.motiChainUnsupportedTip
        if chainWritable {
            posXField?.isEnabled = true
            posYField?.isEnabled = true
            posXField?.toolTip = nil
            posYField?.toolTip = nil
        } else {
            // 不许把解析器读不到的 0.0 当真实值显示（那是假数）。
            posXField?.isEnabled = false
            posYField?.isEnabled = false
            posXField?.stringValue = "—"
            posYField?.stringValue = "—"
            posXField?.toolTip = chainTip
            posYField?.toolTip = chainTip
        }

        // ── 明确不写回的一律置灰 + tooltip ──────────────────────────────
        let blocked: [NSControl?] = [
            rotationSlider, rotationField, scaleSlider, scaleField,
            toggleOrientationButton,
            fontSizeField, fontSizeStepper, alignmentSegment,
            colorWell, colorHexField, fontReplaceButton
        ]
        for control in blocked {
            control?.isEnabled = false
            control?.toolTip = tip
        }
        textStyleTitleLabel?.stringValue = "文字样式（本版不写回）"
        textStyleTitleLabel?.toolTip = tip
        bitmapRecolorGroup?.isHidden = true
        // 右栏高度有限：文字样式组（四项全不写回）与横竖排按钮整块收起，
        // 把「保存回 .moti」按钮顶进可视区，避免用户根本看不到保存入口。
        textStyleGroup?.isHidden = true
        toggleOrientationButton?.isHidden = true
        for v in [publishTextCheck, publishPosCheck, publishRotCheck, publishScaleCheck] {
            v?.isEnabled = false
            v?.toolTip = tip
        }

        // ── 标识 / 横幅 / 按钮文案 ───────────────────────────────────────
        readOnlyBadgeLabel?.isHidden = true
        lockBannerLabel?.stringValue = chainWritable
            ? "编辑态：仅 文本 / X / Y / 可见 / 锁定 写回 .moti"
            : chainTip
        lockBannerLabel?.toolTip = chainWritable ? nil : chainTip
        lockBannerBox?.isHidden = false
        // BUG-4D-1：固定提示文案比原「图层已锁定」长一倍，单行必然被省略号截断，
        // 逐字判定就过不了。非中文链时横幅临时改两行（文案一字不改），退出/中文链复原。
        if let box = lockBannerBox, let label = lockBannerLabel {
            label.lineBreakMode = chainWritable ? .byTruncatingTail : .byCharWrapping
            label.maximumNumberOfLines = chainWritable ? 1 : 2
            label.cell?.wraps = !chainWritable
            label.cell?.isScrollable = false
            for c in box.constraints where c.firstAttribute == .height {
                c.constant = chainWritable ? 26 : 42
            }
        }

        saveButton?.title = " 保存回 .moti"
        saveButton?.isEnabled = motiEditHasChanges && motiEditWritable
        saveButton?.toolTip = motiEditWritable
            ? (motiEditHasChanges ? "写回当前 .moti 原文件" : "没有改动，不允许保存")
            : "目标不可写（只读卷或无写权限），已禁用保存"
        batchExportButton?.isEnabled = false
        batchExportButton?.toolTip = tip

        // ── 右栏滚动区紧凑化：把「保存回 .moti」顶进首屏 ─────────────────
        // 右栏是 NSScrollView + 固定 820pt 的 documentView，mainStack 底锚钉在
        // documentView 底部。编辑态放开属性区后，NSStackView(.fill) 把剩余高度
        // 拉伸分配给弹性子视图，底部按钮被推到可视区之外。
        // 编辑态收起两块 PSD 专用提示、spacing 减半、documentView 贴合
        // mainStack.fittingSize 消除拉伸；图层表维持 180pt，8 行仍全可见。
        // 只读态一行不走，退出时逐项复原。
        fontDropPromptBox?.isHidden = true
        hiddenLayersCheckbox?.isHidden = true
        // TR-002-D BUG-4D-4：文字内容框加高到 ≥6 行（55 -> 100pt），
        // 上下 inset 各 6pt，4 行文本末行不再被框底压住；超高内容内部滚动。
        if let scroll = textEditor?.enclosingScrollView {
            for c in scroll.constraints
            where c.firstAttribute == .height && c.firstItem === scroll {
                c.constant = 100
            }
        }
        textEditor?.textContainerInset = NSSize(width: 0, height: 6)
        if let stack = saveButton?.superview as? NSStackView {
            stack.spacing = 5
            if let clip = stack.superview {
                let want = max(stack.fittingSize.height + 34, 320)
                if abs(clip.frame.height - want) > 1 {
                    clip.setFrameSize(NSSize(width: clip.frame.width, height: want))
                }
            }
        }
    }

    /// 退出编辑态：复位按钮与 tooltip；发布列由 applyMotiReadOnlyText() 加回。
    public func leaveMotiEditMode() {
        motiEditMode = false
        motiEditHasChanges = false
        motiEditWritable = true
        for v in motiPublishGroupViews { v.isHidden = false }
        saveButton?.title = " 保存当前模板至 FCPX"
        saveButton?.isEnabled = true
        saveButton?.toolTip = nil
        batchExportButton?.isEnabled = true
        batchExportButton?.toolTip = nil
        textStyleTitleLabel?.stringValue = "文字样式"
        textStyleTitleLabel?.toolTip = nil
        textStyleGroup?.isHidden = false
        toggleOrientationButton?.isHidden = false
        bitmapRecolorGroup?.isHidden = false
        let controls: [NSControl?] = [
            rotationSlider, rotationField, scaleSlider, scaleField,
            toggleOrientationButton,
            fontSizeField, fontSizeStepper, alignmentSegment,
            colorWell, colorHexField, fontReplaceButton,
            publishTextCheck, publishPosCheck, publishRotCheck, publishScaleCheck
        ]
        for control in controls { control?.isEnabled = true; control?.toolTip = nil }
        // BUG-4D-1 复原：清掉非中文链层的「—」占位与提示，值由
        // updateControlStates 在下一次选层时按模型真值刷新。
        posXField?.toolTip = nil
        posYField?.toolTip = nil
        lockBannerLabel?.toolTip = nil
        // 横幅回单行 26pt（TR-019-R 锁定提示的原始形态）。
        if let box = lockBannerBox, let label = lockBannerLabel {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.isScrollable = true
            for c in box.constraints where c.firstAttribute == .height {
                c.constant = 26
            }
        }
        textEditor?.delegate = nil

        // BUG-4D-4 复原：文字框回到 TR-019-R 基线高度 55pt / 默认 inset (0,2)。
        if let scroll = textEditor?.enclosingScrollView {
            for c in scroll.constraints
            where c.firstAttribute == .height && c.firstItem === scroll {
                c.constant = 55
            }
        }
        textEditor?.textContainerInset = NSSize(width: 0, height: 2)

        // 复原右栏滚动区到 TR-019-R 基线：spacing 10、documentView 820、两块提示恢复。
        fontDropPromptBox?.isHidden = false
        hiddenLayersCheckbox?.isHidden = false
        if let stack = saveButton?.superview as? NSStackView {
            stack.spacing = 10
            if let clip = stack.superview, abs(clip.frame.height - 820) > 1 {
                clip.setFrameSize(NSSize(width: clip.frame.width, height: 820))
            }
        }
    }
}
