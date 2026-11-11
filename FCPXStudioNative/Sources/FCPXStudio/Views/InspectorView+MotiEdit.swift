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

        // ── 只放行五类值 ────────────────────────────────────────────────
        textEditor?.isEditable = true
        textEditor?.textColor = .white
        posXField?.isEnabled = true
        posYField?.isEnabled = true

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
        lockBannerLabel?.stringValue = "编辑态：仅 文本 / X / Y / 可见 / 锁定 写回 .moti"
        lockBannerBox?.isHidden = false

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
        textEditor?.delegate = nil

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
