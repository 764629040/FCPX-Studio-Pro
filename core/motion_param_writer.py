"""
Motion 参数序列化（R25 C-3 / C-4 / C-5 写出就绪层与 FCPX-022 真实 XML 写入）
====================================================

本模块交付：
1. 正确、结构化的 Motion 参数表示 + 序列化方法。
2. FCPX-022: 提供 apply_style_effects_to_ozml 函数，将 PSD 描边/投影/发光真实写入 Motion XML <style> 节点。
"""
import math
import xml.etree.ElementTree as ET
from typing import Any, Dict, Optional

# PSD 混合模式中文名 -> Motion 混合模式（近似映射，供写出）
# key 与 psd_parser.extract_layer_blend_mode 产出的中文名一致。
BLEND_MODE_MOTION_MAP = {
    "正片叠底": "multiply",
    "滤色": "screen",
    "叠加": "overlay",
    "变暗": "darken",
    "变亮": "lighten",
    "颜色减淡": "add",
    "颜色加深": "subtract",
    "强光": "hardlight",
    "柔光": "softlight",
    "差值": "difference",
    "排除": "exclusion",
    "色相": "hue",
    "饱和度": "saturation",
    "颜色": "color",
    "明度": "luminosity",
}


def format_blend_mode_for_motion(blend_feature: Optional[str]) -> Dict[str, Any]:
    """
    C-5：把 extract_layer_blend_mode 返回的 '混合模式: 正片叠底'
    转换为 Motion 写出参数。

    返回：
        {supported, param_name, motion_value, original_cn, note}
    - 不支持的 PSD 混合模式 -> motion_value='normal' 并写明降级原因；
    - 无混合模式（Normal/PassThrough）-> supported=False，motion_value='normal'。
    """
    if not blend_feature or "混合模式" not in blend_feature:
        return {
            "supported": False,
            "param_name": "blendMode",
            "motion_value": "normal",
            "original_cn": None,
            "note": "未检出非 Normal 混合模式，无需写入。",
        }
    cn = blend_feature.split(":", 1)[1].strip()
    mv = BLEND_MODE_MOTION_MAP.get(cn)
    return {
        "supported": mv is not None,
        "param_name": "blendMode",
        "motion_value": mv if mv else "normal",
        "original_cn": cn,
        "note": (
            "Motion 不支持该混合模式，已降级为 normal。"
            if mv is None
            else "可映射到 Motion blendMode。"
        ),
    }


def format_stroke_for_motion(stroke_params: Dict[str, Any]) -> Dict[str, Any]:
    """C-3：描边 -> Motion 描边参数。"""
    return {
        "supported": True,
        "params": {
            "strokeEnabled": True,
            "strokeWidth": stroke_params.get("size"),
            "strokeColor": stroke_params.get("color"),
            "strokePosition": stroke_params.get("position"),
            "strokeOpacity": stroke_params.get("opacity"),
        },
        "note": "映射为 Motion 描边；Motion 若不支持描边位置，取 inside/outside 近似。",
    }


def format_shadow_for_motion(shadow_params: Dict[str, Any], inner: bool = False) -> Dict[str, Any]:
    """C-4：投影 / 内阴影 -> Motion Drop Shadow 近似。"""
    offset_x = _project_offset_x(shadow_params)
    offset_y = _project_offset_y(shadow_params)
    return {
        "supported": True,
        "params": {
            "dropShadow": True,
            "inner": inner,
            "blur": shadow_params.get("blur") or shadow_params.get("size"),
            "offsetX": offset_x,
            "offsetY": offset_y,
            "color": shadow_params.get("color"),
            "opacity": shadow_params.get("opacity"),
        },
        "note": "投影/内阴影映射为 Motion Drop Shadow（近似）。",
    }


def format_glow_for_motion(glow_params: Dict[str, Any], inner: bool = False) -> Dict[str, Any]:
    """C-4：外发光 / 内发光 -> Motion Glow 近似。"""
    return {
        "supported": True,
        "params": {
            "glow": True,
            "inner": inner,
            "blur": glow_params.get("blur") or glow_params.get("size"),
            "color": glow_params.get("color"),
            "opacity": glow_params.get("opacity"),
        },
        "note": "外发光/内发光映射为 Motion Glow（近似）。",
    }


def build_layer_style_motion_entries(layer_styles: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """
    把 extract_layer_styles 的结果转换为 Motion 写出就绪的样式条目集合。
    key 为样式中文名（描边/投影/...），value 为 format_*_for_motion 的返回。
    未包含具体参数的样式（如斜面和浮雕、叠加类）也会被显式标出 unsupported 供诊断。
    """
    entries: Dict[str, Dict[str, Any]] = {}
    styles = layer_styles.get("styles", {})
    for cn, params in styles.items():
        if cn == "描边":
            entries[cn] = format_stroke_for_motion(params)
        elif cn == "投影":
            entries[cn] = format_shadow_for_motion(params, inner=False)
        elif cn == "内阴影":
            entries[cn] = format_shadow_for_motion(params, inner=True)
        elif cn == "外发光":
            entries[cn] = format_glow_for_motion(params, inner=False)
        elif cn == "内发光":
            entries[cn] = format_glow_for_motion(params, inner=True)
        else:
            entries[cn] = {
                "supported": False,
                "params": params,
                "note": "该图层样式无 Motion 近似映射，已记入诊断供人工处理。",
            }
    return entries


def _project_offset_x(params: Dict[str, Any]) -> float:
    dist = float(params.get("distance") or 0)
    ang = float(params.get("angle") or 0)
    return round(dist * math.cos(math.radians(ang)), 2)


def _project_offset_y(params: Dict[str, Any]) -> float:
    dist = float(params.get("distance") or 0)
    ang = float(params.get("angle") or 0)
    return round(dist * math.sin(math.radians(ang)), 2)


def serialize_motion_param_block(param_dict: Dict[str, Any]) -> str:
    """
    把 Motion 参数 dict 序列化为可读 XML 片段（近似 .moti 结构）。
    不依赖 motion_builder；仅作为"写出就绪"的占位实现，便于复核与后续集成。
    """
    lines = ["<motionParamBlock>"]
    for k, v in param_dict.items():
        if isinstance(v, dict):
            lines.append(f'  <param name="{_xml_escape(k)}">')
            for ik, iv in v.items():
                lines.append(f'    <field name="{_xml_escape(ik)}">{_xml_escape(iv)}</field>')
            lines.append("  </param>")
        else:
            lines.append(f'  <field name="{_xml_escape(k)}">{_xml_escape(v)}</field>')
    lines.append("</motionParamBlock>")
    return "\n".join(lines)


def _xml_escape(v: Any) -> str:
    s = "" if v is None else str(v)
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def apply_style_effects_to_ozml(style_elem: Any, style_entries: Dict[str, Any]) -> None:
    """
    FCPX-022: 将描边、投影、发光参数真实写入 Motion <style> 节点
    """
    if not style_entries or style_elem is None:
        return

    # 1. 描边 / 外框 (id="30")
    if "描边" in style_entries and style_entries["描边"].get("supported"):
        p_stroke = style_elem.find("parameter[@id='30']")
        if p_stroke is not None:
            params = style_entries["描边"].get("params", {})
            size = params.get("size", 1.0)
            p_size = p_stroke.find(".//parameter[@id='31']")
            if p_size is not None:
                p_size.attrib["value"] = str(round(float(size), 2))

    # 2. 投影 (id="21")
    if "投影" in style_entries and style_entries["投影"].get("supported"):
        p_shadow = style_elem.find("parameter[@id='21']")
        if p_shadow is not None:
            params = style_entries["投影"].get("params", {})
            p_dist = p_shadow.find(".//parameter[@id='22']")
            if p_dist is not None:
                p_dist.attrib["value"] = str(round(float(params.get("distance", 5.0)), 2))

    # 3. 发光 (id="38")
    if "外发光" in style_entries and style_entries["外发光"].get("supported"):
        p_glow = style_elem.find("parameter[@id='38']")
        if p_glow is not None:
            params = style_entries["外发光"].get("params", {})
            p_blur = p_glow.find(".//parameter[@id='39']")
            if p_blur is not None:
                p_blur.attrib["value"] = str(round(float(params.get("blur", 10.0)), 2))
