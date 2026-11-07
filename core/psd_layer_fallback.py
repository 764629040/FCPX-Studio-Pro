"""
PSD 非文本图层降级与图层样式提取 (R25 C-2 / C-9 / C-3 / C-4)
============================================================

集中处理：
- C-9  PNG 位图降级：render_layer_to_png_bytes —— 把任意可 composite 的图层渲染为
         32 位透明 RGBA PNG 字节流，并做 IHDR 头校验；
- C-2  智能对象 / 非文本图层分类处置：classify_non_text_layer；
- C-3/C-4 图层样式结构化提取：extract_layer_styles（描边 / 投影 / 内阴影 /
         外发光 / 内发光等），并尽力抽取 size / color / position / blur / opacity 等字段。
"""
import io
import struct
from typing import Any, Dict, List, Optional, Tuple

from PIL import Image


# 图层样式 effect 类名 -> 中文名（与 psd_parser.extract_layer_effects 的映射保持一致）
EFFECT_CN_NAME = {
    "Stroke": "描边",
    "DropShadow": "投影",
    "InnerShadow": "内阴影",
    "OuterGlow": "外发光",
    "InnerGlow": "内发光",
    "BevelEmboss": "斜面和浮雕",
    "ColorOverlay": "颜色叠加",
    "GradientOverlay": "渐变叠加",
    "PatternOverlay": "图案叠加",
    "Satin": "光泽",
}


def _unwrap(v: Any) -> Any:
    """UnitFloat / Enumerated 等 psd_tools 描述符类型通常带 .value；其余原样返回。"""
    if v is None:
        return None
    if hasattr(v, "value") and not isinstance(v, (list, tuple, dict, str, bytes)):
        try:
            return v.value
        except Exception:
            return v
    return v


def _color_to_rgb(c: Any) -> Optional[List[float]]:
    """尽力把 psd_tools 颜色对象转为 [r, g, b]（0-255）。失败返回 None。

    psd_tools 的图层效果颜色有三种形态，必须全部覆盖：
    1. 原始描述符 dict：{b'Rd  ': 255.0, b'Grn ': 255.0, b'Bl  ': 255.0}
       （如 Stroke / DropShadow 等效果的 .color 属性）；
    2. Color 包装对象：.value 为 (r, g, b) 元组；
    3. 带 .r / .g / .b 属性的对象。
    """
    if c is None:
        return None
    try:
        # 形态 1：原始描述符（bytes 键，0-255 float 值）。
        # 注意 psd_tools 的 .color 可能是纯 dict，也可能是
        # psd_tools.psd.descriptor.Descriptor（不是 dict 子类但有 .get），
        # 这里统一按 Mapping 协议处理。
        if isinstance(c, dict) or hasattr(c, "get"):
            rd = c.get(b'Rd  ')
            gr = c.get(b'Grn ')
            bl = c.get(b'Bl  ')
            if rd is None:
                rd = c.get('Rd')
            if gr is None:
                gr = c.get('Grn')
            if bl is None:
                bl = c.get('Bl')
            if rd is not None and gr is not None and bl is not None:
                return [float(rd), float(gr), float(bl)]
            return None
        # 形态 2：Color 包装对象
        if hasattr(c, "value") and isinstance(c.value, (list, tuple)):
            vals = [float(x) for x in c.value[:3]]
            if len(vals) >= 3:
                return vals
        # 形态 3：r/g/b 属性
        if hasattr(c, "r") and hasattr(c, "g") and hasattr(c, "b"):
            return [float(c.r), float(c.g), float(c.b)]
    except Exception:
        return None
    return None


def render_layer_to_png_bytes(layer: Any) -> Tuple[bool, Optional[bytes], Optional[Dict[str, Any]]]:
    """
    C-9：把图层渲染为 32 位透明 RGBA PNG 字节流。
    返回 (ok, png_bytes, info)。
    - ok=True 时 png_bytes 为标准 PNG 二进制，info 含 IHDR 校验结果；
    - ok=False 时 png_bytes=None，info 含 error 说明（如缺少 scipy 导致 composite 失败）。

    R25 SA-2b（SA-4 问题 2 修复）：composite() 因缺 scipy（描边等效果渲染依赖）
    抛错时，不再直接放弃，而是尽力用 PIL 原始像素回退（layer.topil()，
    不依赖 scipy，丢效果但保图层本体）。回退成功时 info["render_method"]
    = "pil_topil_fallback"（诚实标注降级路径）；回退也失败才返回错误，
    由调用方（psd_parser）大声记录，绝不静默。
    """
    try:
        layer_img = layer.composite()
        if layer_img is None and hasattr(layer, "topil"):
            layer_img = layer.topil()
        if layer_img is None:
            return False, None, {"error": "composite() 返回空，无法渲染 PNG"}
        render_method = "psd_composite"
    except Exception as exc:
        # composite 失败（典型：缺 scipy 时带描边/效果的图层）。
        # 尽力回退 1：直接解码图层原始像素（PIL，无 scipy 依赖）。
        try:
            layer_img = layer.topil() if hasattr(layer, "topil") else None
        except Exception as exc2:
            return False, None, {
                "error": f"composite 失败: {exc}；PIL 原始像素回退也失败: {exc2}"
            }
        if layer_img is None:
            return False, None, {
                "error": f"composite 失败: {exc}；且图层无原始像素数据 (topil 返回空)"
            }
        render_method = "pil_topil_fallback"
    if layer_img.mode != "RGBA":
        layer_img = layer_img.convert("RGBA")
    buf = io.BytesIO()
    layer_img.save(buf, format="PNG")
    raw = buf.getvalue()
    info = _validate_png_header(raw, layer_img)
    info["file_size"] = len(raw)
    info["render_method"] = render_method
    if render_method == "pil_topil_fallback":
        # 诚实标注：该 PNG 来自原始像素回退，图层效果（描边等）未包含。
        info["fallback_note"] = "composite 失败后用 PIL 原始像素回退渲染，图层效果未包含"
    return True, raw, info


def _validate_png_header(raw: bytes, img: Image.Image) -> Dict[str, Any]:
    """校验 PNG 签名与 IHDR（位深 / 颜色类型 / 通道），返回结构信息。"""
    bit_depth = 8
    color_type = 6
    is_png_sig_valid = False
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        is_png_sig_valid = True
        try:
            chunk_type = raw[12:16]
            if chunk_type == b"IHDR":
                ihdr = raw[16:29]
                _, _, bit_depth, color_type = struct.unpack(">IIBB", ihdr[:10])
        except Exception:
            pass
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type, 4)
    extrema = img.getextrema()
    max_alpha = extrema[3][1] if len(extrema) >= 4 else 255
    is_non_empty = (max_alpha > 0 and img.getbbox() is not None)
    return {
        "is_valid_header": is_png_sig_valid,
        "width": img.width,
        "height": img.height,
        "mode": img.mode,
        "channels": channels,
        "bit_depth": bit_depth,
        "color_type": color_type,
        "total_bpp": bit_depth * channels,
        "pixel_format": f"{bit_depth}-bit per channel / {bit_depth * channels}-bit RGBA",
        "is_non_empty": is_non_empty,
        "max_alpha": max_alpha,
    }


def classify_non_text_layer(real_type: str) -> Tuple[str, str]:
    """返回 (中文描述, 处置) 用于降级原因描述。"""
    if real_type == "smartobject":
        return "智能对象", "degraded"
    if real_type == "shape":
        return "矢量形状", "degraded"
    if real_type == "adjustment":
        return "调整图层", "degraded"
    return "位图装饰", "degraded"


def extract_layer_styles(layer: Any) -> Dict[str, Any]:
    """
    C-3/C-4：结构化提取图层样式（描边 / 投影 / 内阴影 / 外发光 / 内发光等）。
    返回：
        {
          "has_styles": bool,
          "styles": { "描边": {effect, size, color, position, opacity, ...}, ... },
          "unsupported": ["描边", ...]   # 无法在 Motion 矢量规范中 1:1 还原的样式名
        }
    抽取尽力而为：能拿到 size/color/position/opacity 就记录，拿不到记 None。
    """
    result: Dict[str, Any] = {"has_styles": False, "styles": {}, "unsupported": []}
    effects = getattr(layer, "effects", None)
    if not effects:
        return result
    for eff in effects:
        if not getattr(eff, "enabled", True):
            continue
        name = type(eff).__name__
        cn = EFFECT_CN_NAME.get(name, name)
        result["unsupported"].append(cn)
        result["styles"][cn] = _extract_effect_params(eff)
    result["has_styles"] = bool(result["styles"])
    return result


def _plain_value(v: Any) -> Any:
    """把 Enum / bytes / 包装类型转为 JSON 可序列化纯量。

    psd_tools 的枚举常继承 bytes（如 StrokePosition(b'InsF')），_unwrap 不会展开它们；
    而诊断报告要经 export_diagnosis_json 导出，任何非 JSON 类型都会让整份报告序列化失败。
    这里统一压成 str / 数字 / 嵌套纯量：
    - bytes(-Enum) → 解码为 str（如 b'InsF' → 'InsF'）；
    - 普通 Enum → .name；
    - UnitFloat 等包装 → 递归展开 .value；
    - 其余 → str() 兜底（绝不抛异常、绝不返回非可序列化对象）。
    """
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, bytes):
        try:
            return v.decode("utf-8")
        except UnicodeDecodeError:
            return v.decode("latin-1", "replace")
    if isinstance(v, (list, tuple)):
        return [_plain_value(x) for x in v]
    if isinstance(v, dict):
        return {str(k): _plain_value(x) for k, x in v.items()}
    name = getattr(v, "name", None)
    if isinstance(name, str):
        return name
    inner = getattr(v, "value", None)
    if inner is not None:
        return _plain_value(inner)
    return str(v)


def _extract_effect_params(eff: Any) -> Dict[str, Any]:
    """从单个 effect 对象抽取常用参数；拿不到的字段为 None。

    所有输出值经 _plain_value 规整，保证诊断报告可直接 JSON 导出。
    """
    params: Dict[str, Any] = {"effect": type(eff).__name__}
    try:
        for attr, out in (
            ("size", "size"),
            ("opacity", "opacity"),
            ("angle", "angle"),
            ("distance", "distance"),
            ("choke", "choke"),
            ("spread", "spread"),
            ("position", "position"),
            ("blur", "blur"),
            ("color", "color"),
        ):
            if hasattr(eff, attr):
                val = _unwrap(getattr(eff, attr))
                if attr == "color":
                    params[out] = _color_to_rgb(val)
                else:
                    params[out] = _plain_value(val)
    except Exception:
        pass
    return params
