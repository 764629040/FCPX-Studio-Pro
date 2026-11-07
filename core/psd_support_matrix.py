"""
PSD 图层类型支持边界矩阵 (R25 C-1)
=================================

描述 `core/psd_parser.parse_psd_file` 实际会遇到的每种图层类型：

    layer_type × 是否支持(supported) × 不支持时的行为(behavior_when_unsupported)

本矩阵是**单一事实来源**：
- `docs/psd_support_matrix_R25.md` 直接引用本模块导出的 `PSD_SUPPORT_MATRIX`；
- `tests/test_r25_c_01_support_matrix.py` 校验本矩阵覆盖了 parser 处理到的所有图层类型，
  且每个条目都给出了"不支持时的行为"，不得留空。

设计约束（来自 R25 任务单 C-1）：
- 支持矩阵必须覆盖 parser 实际处理的全部图层类型；
- 不支持的类型**必须**写明"不支持时行为"，且绝不能是"静默丢弃"。
"""
from typing import Any, Dict, List, Optional

# parser 中 real_type 可能取到的全部值（与 parse_psd_file 保持一致）
LAYER_TYPES_HANDLED: List[str] = [
    "type",          # 文字图层（纯矢量文本）
    "smartobject",   # 智能对象 (SmartObject)
    "shape",         # 矢量形状 (Shape)
    "pixel",         # 位图像素图层
    "adjustment",    # 调整图层
    "group",         # 图层组（容器）
    "unknown",       # 其它未归类图层（psd_tools 的 kind 不在上述集合时）
]

SUPPORTED_TRUE = "true"
SUPPORTED_CONDITIONAL = "conditional"      # 部分支持（如像素层：底板忽略，普通降级）
SUPPORTED_STRUCTURE_ONLY = "structure_only"  # 仅保留结构，不独立渲染
SUPPORTED_FALSE = "false"


PSD_SUPPORT_MATRIX: List[Dict[str, str]] = [
    {
        "layer_type": "type",
        "supported": SUPPORTED_TRUE,
        "behavior_when_unsupported": "n/a（本类型即受支持）",
        "disposition": "preserved",
        "description": (
            "纯矢量文本，保留为可发布标题。字体/字形缺失时在诊断中高亮并标记缺字，"
            "绝不静默用默认字体顶替。"
        ),
    },
    {
        "layer_type": "smartobject",
        "supported": SUPPORTED_FALSE,
        "behavior_when_unsupported": (
            "默认展平为 32 位透明 RGBA PNG 位图嵌入；"
            "亦可显式按 smart_object_policy='skip' 跳过——但必须记录 skipped 原因，"
            "二者必居其一，绝不静默丢弃。"
        ),
        "disposition": "degraded_or_skipped",
        "description": "智能对象无法直接矢量渲染；默认展平为嵌入 PNG，或显式跳过并留痕。",
    },
    {
        "layer_type": "shape",
        "supported": SUPPORTED_FALSE,
        "behavior_when_unsupported": "展平为 32 位透明 RGBA PNG 位图嵌入；描边/填充若无法映射则记入诊断。",
        "disposition": "degraded",
        "description": "矢量形状降级为 PNG 贴图；图层样式（描边等）结构化提取后入诊断。",
    },
    {
        "layer_type": "pixel",
        "supported": SUPPORTED_CONDITIONAL,
        "behavior_when_unsupported": (
            "普通像素图层展平为 PNG 位图嵌入；被识别为底板（Background）的像素层按规范忽略并记入 notes。"
        ),
        "disposition": "degraded_or_ignored",
        "description": "位图按不支持处理并降级为 PNG；底板图层显式忽略。",
    },
    {
        "layer_type": "adjustment",
        "supported": SUPPORTED_FALSE,
        "behavior_when_unsupported": "展平为 PNG 位图嵌入（保留视觉效果近似），色彩校正语义不在 Motion 矢量规范内。",
        "disposition": "degraded",
        "description": "调整图层降级为 PNG 贴图；原色彩校正语义丢失但显式记录。",
    },
    {
        "layer_type": "group",
        "supported": SUPPORTED_STRUCTURE_ONLY,
        "behavior_when_unsupported": (
            "仅保留层级结构（layer_tree / layer_path / depth），不独立渲染；"
            "作为 skipped 计入图层守恒，不计为 output。"
        ),
        "disposition": "ignored",
        "description": "图层组为容器，保留父子层级，不单独输出图层。",
    },
    {
        "layer_type": "unknown",
        "supported": SUPPORTED_FALSE,
        "behavior_when_unsupported": "按非文本图层保守处理，展平为 PNG 位图嵌入，并记入 unsupported_features，绝不静默丢弃。",
        "disposition": "degraded",
        "description": "未知类型按保守降级处理，显式记录类型未知。",
    },
]


def get_support_entry(layer_type: str) -> Optional[Dict[str, str]]:
    """返回某图层类型的支持矩阵条目；未知类型返回 None。"""
    for entry in PSD_SUPPORT_MATRIX:
        if entry["layer_type"] == layer_type:
            return entry
    return None


def is_layer_type_handled(layer_type: str) -> bool:
    return layer_type in LAYER_TYPES_HANDLED


def validate_support_matrix_complete(found_layer_types: List[str]) -> Dict[str, Any]:
    """
    校验支持矩阵完整性（供测试调用）：

    - 所有 parser 实际遇到的图层类型都必须在 LAYER_TYPES_HANDLED 中；
    - 矩阵每个条目都必须给出非空的 behavior_when_unsupported。
    """
    missing = [t for t in found_layer_types if t not in LAYER_TYPES_HANDLED]
    incomplete = [
        e["layer_type"]
        for e in PSD_SUPPORT_MATRIX
        if not (e.get("behavior_when_unsupported") or "").strip()
    ]
    return {
        "all_found_covered": len(missing) == 0,
        "missing_types": missing,
        "matrix_entry_count": len(PSD_SUPPORT_MATRIX),
        "incomplete_entries": incomplete,
        "handled_type_count": len(LAYER_TYPES_HANDLED),
    }
