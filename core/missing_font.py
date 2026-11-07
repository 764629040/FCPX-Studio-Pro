"""
缺字可见标记与不可降级告警 (R25 C-10)
====================================

原则（来自任务单 C-10）：
- 缺字用**可见标记**（tofu 方框 □ / 问号）替代，绝不留下空白或乱码；
- 诊断面板**必须高亮**缺字 / 缺字体风险；
- **绝不静默用默认字体顶替**原始字体——默认字体只能作为"推荐回退"记录在诊断中，
  下游输出仍引用原始字体，由人工决定是否替换。

本模块只负责"标记与判定"，不负责把标记写进像素图（那是渲染层的事）。
"""
from typing import List, Optional

# 可见 tofu 方框：渲染层遇到此字符应输出一个明显的缺字方块，而不是空白。
# 选 □(U+25A1) 而非替换符 �(U+FFFD)，避免与"解码错误"语义混淆。
MISSING_GLYPH_MARKER = "□"


def apply_missing_glyph_markers(text: str, missing_chars: List[str]) -> str:
    """
    把文本里确实缺失的字形替换为可见 tofu 标记。

    - missing_chars 为空（如整字体缺失 / 不可验证）时原样返回，不臆造缺字；
    - 只替换 listed 字符，保留文本长度与结构，便于下游定位。
    """
    if not text:
        return text
    if not missing_chars:
        return text
    marker_set = set(missing_chars)
    return "".join(MISSING_GLYPH_MARKER if ch in marker_set else ch for ch in text)


def should_highlight_missing_font(font_status: Optional[str], has_missing_risk: bool) -> bool:
    """
    诊断面板是否必须高亮该图层的缺字 / 缺字体风险。

    仅当 has_missing_risk 为真且字体状态属于需要人工关注的三态之一时高亮。
    complete（已安装且字形完整）不触发高亮。
    """
    if not has_missing_risk:
        return False
    return font_status in ("partial_missing", "font_missing", "unverifiable")


def missing_glyph_layer_state(info) -> dict:
    """
    R26-A47②：GUI 诊断面板高亮的纯判定逻辑（无 Qt 依赖，可 headless 单测）。

    输入：psd_parser 的图层信息对象（PSDLayerInfo 或鸭子类型）。
    输出：{
        "highlight":      bool,   是否需要高亮
        "marked_text":    str,    可见标记版文本（可能为空）
        "missing_chars":  list,   缺失字符清单
        "reason":         str,    风险类型摘要（"缺字形"/"字体风险"）
    }
    判定来源（一等字段，psd_parser 保证口径）：
      missing_glyph_visible_marker / font_info.has_glyph_risk /
      highlight_missing_font / marked_text / font_info.missing_chars

    R31 / A-59：`has_missing_glyphs` 已 deprecated，优先读 `has_glyph_risk`；
    `has_confirmed_missing_glyphs` 表示确证缺字（missing_chars 非空）。
    """
    font_info = getattr(info, "font_info", None) or {}
    has_marker = bool(getattr(info, "missing_glyph_visible_marker", False))
    # 兼容旧数据：没有新字段时回退到旧字段
    has_missing = bool(font_info.get("has_glyph_risk",
                                     font_info.get("has_missing_glyphs", False)))
    flagged = bool(getattr(info, "highlight_missing_font", False))
    marked = getattr(info, "marked_text", "") or ""
    highlight = has_marker or has_missing or flagged
    missing_chars = list(font_info.get("missing_chars", []) or [])
    confirmed = bool(font_info.get("has_confirmed_missing_glyphs", bool(missing_chars)))
    reasons = []
    if has_marker or has_missing:
        reasons.append("缺字形")
    if flagged:
        reasons.append("字体风险")
    return {
        "highlight": highlight,
        "confirmed_missing": confirmed,
        "marked_text": marked,
        "missing_chars": missing_chars,
        "reason": "/".join(reasons) or "缺字风险",
    }
