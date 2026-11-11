"""
PSD 解析核心模块 (专业诊断与降级增强版 - 支持层级树与完整转换诊断报告)
功能：
1. 动态画幅与分辨率换算 (横竖屏/4K/1080P/自适应) 与笛卡尔坐标系统换算
2. 安全区域 (Action Safe 90% 与 Title Safe 80%) 边界合法性分析
3. 矢量文字层全属性提取 (文本、字号、字距、坐标、旋转、缩放、透明度、横竖排版)
4. 多维字体回退检测报告：记录三元组 (原字体名称、检测状态、回退采用字体)，
   深度检查目标文本字符集字形覆盖度 (Glyph Coverage)，杜绝静默乱码与替换
5. 递归提取 PSD 图层树 (Layer Hierarchy)，记录父子层级、图层路径、图层类型、真实 32x32 微缩缩略图
6. 结构化 PSD 转换诊断闭环体系 (generate_conversion_diagnosis_report / export_diagnosis_json)，
   精准判定每图层处置方案 (preserved / degraded / ignored / failed) 与详尽处置原因
7. 异常边界防护：单文件损坏或格式非法时抛出结构化 PSDParseError，外层捕获后记录 failed 状态并精准追踪源文件
"""
import os
import math
import re
import io
import json
import base64
import struct
from datetime import datetime
from typing import List, Dict, Any, Optional, Tuple
from PIL import Image
from psd_tools import PSDImage

# R25 C 域新增模块（支持矩阵 / 缺字标记 / PNG 降级 / Motion 参数写出就绪）。
# 用 try/except 兼容「以 core 包导入」与「以顶层模块导入」两种上下文。
try:
    from core.psd_support_matrix import (
        PSD_SUPPORT_MATRIX,
        LAYER_TYPES_HANDLED,
        get_support_entry,
        validate_support_matrix_complete,
    )
    from core.missing_font import (
        MISSING_GLYPH_MARKER,
        apply_missing_glyph_markers,
        should_highlight_missing_font,
    )
    from core.psd_layer_fallback import (
        render_layer_to_png_bytes,
        classify_non_text_layer,
        extract_layer_styles,
    )
    from core.motion_param_writer import (
        format_blend_mode_for_motion,
        build_layer_style_motion_entries,
        serialize_motion_param_block,
    )
except ImportError:  # 作为顶层模块直接运行时回退
    from psd_support_matrix import (  # type: ignore
        PSD_SUPPORT_MATRIX,
        LAYER_TYPES_HANDLED,
        get_support_entry,
        validate_support_matrix_complete,
    )
    from missing_font import (  # type: ignore
        MISSING_GLYPH_MARKER,
        apply_missing_glyph_markers,
        should_highlight_missing_font,
    )
    from psd_layer_fallback import (  # type: ignore
        render_layer_to_png_bytes,
        classify_non_text_layer,
        extract_layer_styles,
    )
    from motion_param_writer import (  # type: ignore
        format_blend_mode_for_motion,
        build_layer_style_motion_entries,
        serialize_motion_param_block,
    )


class PSDParseError(Exception):
    """
    PSD 解析异常类，封装源文件路径与底层错误，
    确保外层能够精准追踪到源文件，记录 failed 状态，绝不导致应用崩溃。
    """
    def __init__(self, file_path: str, original_error: Exception):
        self.file_path = os.path.abspath(file_path) if file_path else ""
        self.file_name = os.path.basename(file_path) if file_path else ""
        self.original_error = original_error
        super().__init__(f"解析 PSD 失败 [{self.file_name}]: {str(original_error)}")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "file_name": self.file_name,
            "file_path": self.file_path,
            "error_type": type(self.original_error).__name__,
            "error_message": str(self.original_error)
        }


def _extract_string_value(val: Any) -> str:
    """安全提取 psd_tools String 对象或其它类型的字符串值"""
    if val is None:
        return ""
    if hasattr(val, "value") and isinstance(val.value, str):
        return val.value.strip()
    return str(val).strip("'\"\r\n\t ")


def layer_is_effectively_visible(layer: Any) -> bool:
    """
    递归检查图层及其所有祖先节点的可见性（层级可见性继承）。
    若图层本身隐藏，或任何一级祖先图层组被隐藏，则图层在画布与最终渲染中判定为隐藏。
    优先调用 psd-tools 的 layer.is_visible()；若环境或对象不具备该方法则手动沿 parent 链追溯。
    """
    if hasattr(layer, "is_visible") and callable(layer.is_visible):
        try:
            return bool(layer.is_visible())
        except Exception:
            pass
    cur = layer
    while cur is not None:
        if hasattr(cur, "visible") and not cur.visible:
            return False
        cur = getattr(cur, "parent", None)
    return True


def appkit_available() -> bool:
    """
    当前环境是否具备字体检测能力（可导入 AppKit）。

    这是"检测能力"判定，与"某个字体是否已安装"是两件事。
    A-10 修复要点：二者不得混同，否则无 AppKit 平台（Linux 等）会把
    "无法检测"误报成"字体未安装"。
    """
    try:
        import AppKit  # noqa: F401
        return True
    except Exception:
        return False


def check_font_availability_status(font_name: str) -> str:
    """
    字体可用性三态判定，供上层区分"未安装"与"无法检测"。

    返回：
    - "available"    字体在系统中可用
    - "missing"      环境可检测，且该字体确实未安装
    - "unverifiable" 当前环境不具备字体检测能力（如无 AppKit）

    关键契约（A-10）：无检测能力时**必须**返回 "unverifiable"，
    绝不能返回 "missing" —— 那会把平台缺陷伪装成字体缺失。
    """
    if not font_name or not font_name.strip():
        return "missing"
    clean_name = font_name.strip()

    # 过滤 Adobe 占位字体：这是确定性的"不可用"，与环境无关
    if any(placeholder in clean_name for placeholder in ["AdobeInvis", "Unknown", "Myriad-Placeholder"]):
        return "missing"

    if not appkit_available():
        # 无检测能力：绝不断言字体缺失
        return "unverifiable"

    try:
        import AppKit
        # 缓存系统字体表提高多次匹配速度
        if not hasattr(check_font_availability_status, "_cache"):
            fm = AppKit.NSFontManager.sharedFontManager()
            check_font_availability_status._cache = set(fm.availableFonts())

        cache = check_font_availability_status._cache
        if clean_name in cache:
            return "available"

        # 尝试通过 NSFont 查询实例
        f = AppKit.NSFont.fontWithName_size_(clean_name, 12.0)
        if f is not None:
            return "available"
        # AppKit 可用且明确查不到该字体 -> 确实未安装
        return "missing"
    except Exception:
        # AppKit 存在但调用异常：无法得出可用性结论，按不可验证处理
        return "unverifiable"


def check_font_availability(font_name: str) -> bool:
    """
    利用 macOS AppKit 检查指定 PostScript 字体名或字体族名是否在系统中可用。

    返回值语义（注意与 check_font_availability_status 的区别）：
    - True  : 字体确认可用
    - False : 字体不可用（含"无法检测"这一保守结果）

    需要区分"未安装"与"无法检测"时，请使用 check_font_availability_status()。
    """
    return check_font_availability_status(font_name) == "available"


def check_font_glyph_coverage(font_name: str, text: str) -> Dict[str, Any]:
    """
    基于 macOS AppKit 检查指定字体对目标文本字符集的覆盖度 (Glyph Coverage)
    
    返回状态体系:
    - "complete": 字体已安装且目标文本字形覆盖度 100%
    - "partial_missing": 字体已安装但存在部分字形缺失 (coverage_rate < 1.0)
    - "font_missing": 字体在系统中未安装 (coverage_rate = 0.0, 绝不伪通过)
    - "unverifiable": AppKit/系统环境异常或不支持物理字形检测 (coverage_rate = None, 绝不静默返回 1.0)
    """
    clean_chars = [c for c in text if not c.isspace()]
    if not clean_chars:
        return {
            "status": "complete",
            "coverage_rate": 1.0,
            "covered_count": 0,
            "total_count": 0,
            "missing_chars": [],
            "has_missing_risk": False,
            "warning": None
        }

    try:
        import AppKit
        font = AppKit.NSFont.fontWithName_size_(font_name, 12.0)
        if font is None:
            # 字体在系统中未安装：明确返回 font_missing，坚决禁止伪通过！
            #
            # A-4 修复要点：字体文件不存在时，无法枚举其字形，
            # 因此 **不得** 把全部文本字符当作"缺字"列出。
            # 否则会出现「Helvetica / CormorantInfant 缺字: W, E, N」这类
            # 误导性结论——字母本身并不缺，缺的是整个字体。
            # 缺字清单此时必须为空，由 font_missing 状态本身表达问题。
            return {
                "status": "font_missing",
                "coverage_rate": 0.0,
                "covered_count": 0,
                "total_count": len(clean_chars),
                "missing_chars": [],
                "has_missing_risk": True,
                "warning": f"字体 '{font_name}' 在当前 macOS 系统中未安装，无法枚举其字形"
            }
        
        cset = font.coveredCharacterSet()
        if cset is None:
            # 字符集无法提取
            return {
                "status": "unverifiable",
                "coverage_rate": None,
                "covered_count": None,
                "total_count": len(clean_chars),
                "missing_chars": [],
                "has_missing_risk": True,
                "warning": f"字体 '{font_name}' 无法获取 coveredCharacterSet 字符集对象"
            }

        missing = []
        covered = 0
        for ch in clean_chars:
            if cset.characterIsMember_(ord(ch)):
                covered += 1
            else:
                if ch not in missing:
                    missing.append(ch)

        cov_rate = round(covered / len(clean_chars), 4)
        has_risk = len(missing) > 0
        status = "partial_missing" if has_risk else "complete"

        return {
            "status": status,
            "coverage_rate": cov_rate,
            "covered_count": covered,
            "total_count": len(clean_chars),
            "missing_chars": missing,
            "has_missing_risk": has_risk,
            "warning": f"字体 '{font_name}' 缺少 {len(missing)} 个字符的字形" if has_risk else None
        }
    except Exception as exc:
        # AppKit 调用异常，明确返回 unverifiable，绝不静默返回 1.0！
        return {
            "status": "unverifiable",
            "coverage_rate": None,
            "covered_count": None,
            "total_count": len(clean_chars),
            "missing_chars": [],
            "has_missing_risk": True,
            "warning": f"字形检测环境调用异常: {str(exc)}"
        }


def build_preserved_reason(font_status: str, missing_glyphs, fallback_font: str) -> str:
    """
    按字体/字形四态生成 preserved 文本图层的处置原因。

    四态定义（与 check_font_glyph_coverage 保持一致）：
      complete       字体与字形均完整
      partial_missing 字体已安装但部分字形缺失
      font_missing    字体在系统中未安装
      unverifiable    当前平台无法枚举字形（如无 AppKit、字符集对象不可用）

    约束：
    - 四态文案必须两两不同，便于诊断表逐行区分；
    - 缺字态严禁出现"元数据完整"这类自相矛盾表述；
    - 缺字数量从 missing_glyphs 实时统计，不写死。
    """
    miss_n = len(missing_glyphs or [])
    if font_status == "complete":
        return "纯矢量文本，字体与字形均完整，保留为可发布标题"
    if font_status == "partial_missing":
        return f"纯矢量文本，字体已安装但缺 {miss_n} 个字形，已标记待替换"
    if font_status == "font_missing":
        return (
            f"纯矢量文本，原始字体未安装、缺 {miss_n} 字，"
            f"已降级为回退字体 '{fallback_font}' 并标记待处理"
        )
    # unverifiable 及其它未知状态：诚实标注风险不可确定
    return (
        "纯矢量文本，当前平台无法枚举字体字形，缺字风险无法确定，"
        "已保留矢量并标记待复核"
    )


def detect_layer_rotation(layer) -> float:
    """
    从 PSD 图层仿射变换矩阵计算旋转角（单位：度，归一到 [0, 360)）。

    psd_tools 的 layer.transform 返回 6 元仿射矩阵 (a, b, c, d, tx, ty)，
    对应 2x3 矩阵：
        | a  b  tx |
        | c  d  ty |
    线性部分 [[a, b], [c, d]] 决定旋转与缩放，旋转角 = atan2(b, a)。

    典型正交旋转：
        0°   -> ( 1,  0,  0,  1)   横排（原样）
        90°  -> ( 0,  1, -1,  0)   竖排文字
        180° -> (-1,  0,  0, -1)
        270° -> ( 0, -1,  1,  0)

    设计约束：
    - 仅在接近 0/90/180/270（容差 ±2°）时吸附到标准角度，避免把微小倾斜
      误判成正交旋转；
    - 其余角度保留精确角度，不做量化；
    - transform 缺失 / 长度不足 / 线性部分退化时安全返回 0.0。
    """
    transform = getattr(layer, "transform", None)
    if not transform or len(transform) < 4:
        return 0.0

    try:
        a, b = float(transform[0]), float(transform[1])
    except (TypeError, ValueError):
        return 0.0

    # 线性部分退化（全零）无法确定旋转，按未旋转处理
    if abs(a) < 1e-9 and abs(b) < 1e-9:
        return 0.0

    angle = math.degrees(math.atan2(b, a)) % 360.0

    # ±2° 容差吸附到正交角度
    for cardinal in (0.0, 90.0, 180.0, 270.0, 360.0):
        if abs(angle - cardinal) <= 2.0:
            return cardinal % 360.0

    return round(angle, 4)


def calculate_safe_area_status(canvas_w: int, canvas_h: int, bbox: tuple, motion_pos: tuple) -> Dict[str, Any]:
    """
    计算图层在 Motion 画布下的安全区域合规性：
    - Action Safe 90%: 边界在 [0.05 * W, 0.95 * W] 与 [0.05 * H, 0.95 * H] 范围内
    - Title Safe 80%: 边界在 [0.10 * W, 0.90 * W] 与 [0.10 * H, 0.90 * H] 范围内
    """
    left, top, right, bottom = bbox
    mx, my = motion_pos

    # 笛卡尔中心限制
    max_title_x = 0.40 * canvas_w
    max_title_y = 0.40 * canvas_h
    max_action_x = 0.45 * canvas_w
    max_action_y = 0.45 * canvas_h

    center_in_title_safe = (abs(mx) <= max_title_x and abs(my) <= max_title_y)
    center_in_action_safe = (abs(mx) <= max_action_x and abs(my) <= max_action_y)

    # 整个包围盒完整边界限制 (PSD 坐标系)
    box_in_action_safe = (
        left >= 0.05 * canvas_w and right <= 0.95 * canvas_w and
        top >= 0.05 * canvas_h and bottom <= 0.95 * canvas_h
    )
    box_in_title_safe = (
        left >= 0.10 * canvas_w and right <= 0.90 * canvas_w and
        top >= 0.10 * canvas_h and bottom <= 0.90 * canvas_h
    )

    return {
        "center_in_title_safe": center_in_title_safe,
        "center_in_action_safe": center_in_action_safe,
        "box_in_title_safe": box_in_title_safe,
        "box_in_action_safe": box_in_action_safe,
        "action_safe_rect": (0.05 * canvas_w, 0.05 * canvas_h, 0.95 * canvas_w, 0.95 * canvas_h),
        "title_safe_rect": (0.10 * canvas_w, 0.10 * canvas_h, 0.90 * canvas_w, 0.90 * canvas_h)
    }


def detect_aspect_ratio(width: int, height: int) -> Tuple[str, str]:
    """检测画幅比与常用分辨率规格"""
    ratio_val = width / max(1, height)
    if abs(ratio_val - 16 / 9) < 0.05:
        ratio_str = "16:9 (横版宽屏)"
    elif abs(ratio_val - 9 / 16) < 0.05:
        ratio_str = "9:16 (竖屏短视频)"
    elif abs(ratio_val - 4 / 3) < 0.05:
        ratio_str = "4:3 (经典标清)"
    elif abs(ratio_val - 1.0) < 0.05:
        ratio_str = "1:1 (方形画幅)"
    elif abs(ratio_val - 2.35) < 0.1:
        ratio_str = "2.35:1 (宽银幕电影)"
    else:
        ratio_str = f"{width}:{height} (定制比例)"

    if width >= 3840 or height >= 2160:
        res_str = "4K 超高清"
    elif width >= 2560 or height >= 1440:
        res_str = "2K 高清"
    elif width >= 1920 or height >= 1080:
        res_str = "1080P 全高清"
    elif width >= 1280 or height >= 720:
        res_str = "720P 标清"
    else:
        res_str = f"{width}×{height}"

    return ratio_str, res_str


def get_layer_path(layer) -> str:
    """提取图层的完整层级路径（如 '装饰组/箭头_01'）"""
    parts = [layer.name or "Unnamed"]
    curr = getattr(layer, "parent", None)
    while curr is not None and hasattr(curr, "name") and curr.name and not isinstance(curr, PSDImage):
        parts.append(curr.name)
        curr = getattr(curr, "parent", None)
    return "/".join(reversed(parts))


def get_parent_path(layer) -> str:
    """提取图层的父级层级路径"""
    parts = []
    curr = getattr(layer, "parent", None)
    while curr is not None and hasattr(curr, "name") and curr.name and not isinstance(curr, PSDImage):
        parts.append(curr.name)
        curr = getattr(curr, "parent", None)
    return "/".join(reversed(parts)) if parts else ""


def extract_layer_effects(layer) -> List[str]:
    """提取图层启用的 Photoshop 复杂图层样式（描边、投影、发光等）"""
    effects_list = []
    if hasattr(layer, "effects") and layer.effects:
        try:
            eff_map = {
                "Stroke": "描边",
                "DropShadow": "投影",
                "InnerShadow": "内阴影",
                "OuterGlow": "外发光",
                "InnerGlow": "内发光",
                "BevelEmboss": "斜面和浮雕",
                "ColorOverlay": "颜色叠加",
                "GradientOverlay": "渐变叠加",
                "PatternOverlay": "图案叠加",
                "Satin": "光泽"
            }
            for eff in layer.effects:
                is_en = getattr(eff, "enabled", True)
                if is_en:
                    name = type(eff).__name__
                    cn_name = eff_map.get(name, name)
                    effects_list.append(f"图层样式: {cn_name}")
        except Exception:
            effects_list.append("图层样式")
    return effects_list


def extract_layer_blend_mode(layer) -> Optional[str]:
    """检测非 Normal / Pass Through 的混合模式"""
    bm = getattr(layer, "blend_mode", None)
    if bm is not None:
        name = str(bm).split(".")[-1].lower()
        if name not in ("normal", "pass_through"):
            bm_map = {
                "multiply": "正片叠底",
                "screen": "滤色",
                "overlay": "叠加",
                "darken": "变暗",
                "lighten": "变亮",
                "color_dodge": "颜色减淡",
                "color_burn": "颜色加深",
                "hard_light": "强光",
                "soft_light": "柔光",
                "difference": "差值",
                "exclusion": "排除",
                "hue": "色相",
                "saturation": "饱和度",
                "color": "颜色",
                "luminosity": "明度"
            }
            cn_bm = bm_map.get(name, name)
            return f"混合模式: {cn_bm}"
    return None


def detect_warp(layer) -> Optional[str]:
    """
    R25 C-6：检测 PSD 文字图层是否含变形文字 (Warp)。
    返回 WarpStyle 字符串（如 'warpArc'）；无变形或不可检测时返回 None。
    """
    try:
        ed = getattr(layer, "engine_dict", None)
        if not ed:
            return None
        warp = ed.get("Warp")
        if warp and str(warp.get("WarpStyle", "warpNone")) != "warpNone":
            return str(warp.get("WarpStyle"))
    except Exception:
        return None
    return None


def build_warp_warning(layer_name: str, warp_style: str) -> str:
    """
    R25 C-6：生成变形文字告警文案。强调"保留文本内容并告警，未静默降级为位图"。
    """
    return (
        f"图层 '{layer_name}' 含 PSD 文字变形 ({warp_style})，"
        f"弧形/波浪布局无法在 Motion 矢量文本中还原；"
        f"已保留文本内容并告警，未静默降级为位图"
    )


def generate_layer_thumbnail(layer, size: Tuple[int, int] = (32, 32)) -> Tuple[bool, Optional[bytes], Optional[str], Optional[bytes]]:
    """
    为非空非组图层生成 32x32 微缩缩略图与原始图层切片字节流。
    对空图层或组明确标记 has_thumbnail=False，绝不以空白透明图冒充。
    返回: (has_thumbnail, thumbnail_bytes, thumbnail_base64, original_slice_bytes)
    """
    if layer.is_group():
        return False, None, None, None

    bbox = layer.bbox
    if not bbox or (bbox[2] - bbox[0] <= 0) or (bbox[3] - bbox[1] <= 0):
        return False, None, None, None

    try:
        im = layer.composite()
        if im is None and hasattr(layer, "topil"):
            im = layer.topil()
        if im is None:
            return False, None, None, None

        if im.mode != "RGBA":
            im = im.convert("RGBA")

        ext = im.getextrema()
        # Alpha 全为 0 时判定为全透明空图，不作为有效缩略图
        if len(ext) >= 4 and ext[3][1] == 0:
            return False, None, None, None

        # 原始高清切片字节
        orig_buf = io.BytesIO()
        im.save(orig_buf, format="PNG")
        orig_bytes = orig_buf.getvalue()

        # 微缩 32x32 缩略图
        thumb = im.copy()
        thumb.thumbnail(size, Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        thumb.save(buf, format="PNG")
        raw_bytes = buf.getvalue()
        b64_str = base64.b64encode(raw_bytes).decode("ascii")
        return True, raw_bytes, b64_str, orig_bytes
    except Exception:
        return False, None, None, None


class PSDLayerInfo:
    def __init__(self, index: int, name: str, kind: str, text: str, 
                 font_name: str, font_size: float, tracking: float,
                 psd_bbox: tuple, motion_pos: tuple, visible: bool = True,
                 is_published: bool = True,
                 rotation: float = 0.0,
                 scale_x: float = 1.0, scale_y: float = 1.0,
                 opacity: float = 1.0, line_spacing: float = 1.0,
                 writing_direction: str = "vertical",
                 fallback_png_path: Optional[str] = None,
                 fallback_png_info: Optional[Dict[str, Any]] = None,
                 font_info: Optional[Dict[str, Any]] = None,
                 safe_area: Optional[Dict[str, Any]] = None,
                 diagnostic_notes: Optional[List[str]] = None,
                 layer_path: str = "",
                 layer_type: str = "",
                 has_thumbnail: bool = False,
                 thumbnail_bytes: Optional[bytes] = None,
                 thumbnail_base64: Optional[str] = None,
                 original_slice_bytes: Optional[bytes] = None,
                 disposition: str = "preserved",
                 disposition_reason: str = "",
                 unsupported_features: Optional[List[str]] = None,
                 effects: Optional[List[str]] = None,
                 layer_styles: Optional[Dict[str, Any]] = None,
                 motion_blend_mode: Optional[Dict[str, Any]] = None,
                 motion_blend_mode_xml: str = "",
                 warp_detected: bool = False,
                 warp_warning: str = "",
                 highlight_missing_font: bool = False,
                 marked_text: str = "",
                 missing_glyph_visible_marker: bool = False,
                 smart_object_policy: str = "flatten",
                 alignment: str = "center",
                 text_color: str = ""):
        self.index = index
        self.name = name
        self.kind = kind  # "type" (文字) 或 "fallback_png" (降级贴图)
        self.text = text
        self.font_name = font_name
        self.font_size = font_size
        self.tracking = tracking
        self.line_spacing = line_spacing
        self.psd_bbox = psd_bbox        # (left, top, right, bottom)
        self.motion_pos = motion_pos    # (motion_x, motion_y)
        self.visible = visible          # True=显示，False=隐藏
        self.is_published = is_published # True=发布至 FCPX 检查器
        
        # Motion 属性
        self.rotation = rotation
        self.scale_x = scale_x
        self.scale_y = scale_y
        self.opacity = opacity
        self.writing_direction = writing_direction # "horizontal" 或 "vertical"
        self.fallback_png_path = fallback_png_path
        self.fallback_png_info = fallback_png_info or {}
        
        # 多维字体三元组与字形覆盖度
        self.font_info = font_info or {
            "original_font": font_name or "Helvetica",
            "detection_status": "detected" if font_name else "missing_fallback",
            "fallback_font": font_name or "PingFangSC-Regular",
            "glyph_coverage": 1.0,
            # R31 / A-59：has_missing_glyphs 是风险语义（含未验证），已 deprecated；
            # 确证缺字用 has_confirmed_missing_glyphs，任何风险用 has_glyph_risk。
            "has_missing_glyphs": False,
            "has_glyph_risk": False,
            "has_confirmed_missing_glyphs": False,
            "missing_chars": []
        }
        self.safe_area = safe_area or {}
        self.diagnostic_notes = diagnostic_notes or []

        # 增强诊断与层级元数据
        self.layer_path = layer_path or name
        self.layer_type = layer_type or kind
        self.has_thumbnail = has_thumbnail
        self.thumbnail_bytes = thumbnail_bytes
        self.thumbnail_base64 = thumbnail_base64
        self.original_slice_bytes = original_slice_bytes
        self.disposition = disposition
        self.disposition_reason = disposition_reason
        self.unsupported_features = unsupported_features or []
        self.effects = effects or []

        # R25 C 域增强字段
        self.layer_styles = layer_styles or {}
        self.motion_blend_mode = motion_blend_mode or {}
        self.motion_blend_mode_xml = motion_blend_mode_xml
        self.warp_detected = warp_detected
        self.warp_warning = warp_warning
        self.highlight_missing_font = highlight_missing_font
        self.marked_text = marked_text
        self.missing_glyph_visible_marker = missing_glyph_visible_marker
        self.smart_object_policy = smart_object_policy
        self.alignment = alignment
        # TR-023-B：文字填充色 HEX（"#RRGGBB"），空串 = 未取到
        self.text_color = text_color

        # 详细发布参数清单
        self.published_channels = {
            "text": (kind == "type"),
            "font": (kind == "type"),
            "size": (kind == "type"),
            "tracking": (kind == "type"),
            "position": True,
            "rotation": False,
            "scale": False,
            "opacity": False,
            "alignment": (kind == "type")
        }

    def convert_to_horizontal(self):
        lines = self.text.split("\n")
        if all(len(l.strip()) <= 1 for l in lines if l.strip()):
            self.text = "".join(lines)
        else:
            self.text = " ".join(lines)
        self.writing_direction = "horizontal"

    def convert_to_vertical(self):
        chars = [c for c in self.text.replace("\n", "").replace("\r", "")]
        self.text = "\n".join(chars)
        self.writing_direction = "vertical"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "index": self.index,
            "name": self.name,
            "kind": self.kind,
            "layer_path": self.layer_path,
            "layer_type": self.layer_type,
            "text": self.text,
            "font_name": self.font_name,
            "font_info": self.font_info,
            "font_size": self.font_size,
            "tracking": self.tracking,
            "line_spacing": self.line_spacing,
            "alignment": self.alignment,
            "text_color": self.text_color,
            "psd_bbox": self.psd_bbox,
            "motion_pos": self.motion_pos,
            "safe_area": self.safe_area,
            "visible": self.visible,
            "is_published": self.is_published,
            "rotation": self.rotation,
            "scale_x": self.scale_x,
            "scale_y": self.scale_y,
            "opacity": self.opacity,
            "writing_direction": self.writing_direction,
            "fallback_png_path": self.fallback_png_path,
            "fallback_png_info": self.fallback_png_info,
            "has_thumbnail": self.has_thumbnail,
            "thumbnail_base64": self.thumbnail_base64,
            "disposition": self.disposition,
            "disposition_reason": self.disposition_reason,
            "unsupported_features": self.unsupported_features,
            "effects": self.effects,
            "diagnostic_notes": self.diagnostic_notes,
            "published_channels": self.published_channels,
            "layer_styles": self.layer_styles,
            "motion_blend_mode": self.motion_blend_mode,
            "motion_blend_mode_xml": self.motion_blend_mode_xml,
            "warp_detected": self.warp_detected,
            "warp_warning": self.warp_warning,
            "highlight_missing_font": self.highlight_missing_font,
            "marked_text": self.marked_text,
            "missing_glyph_visible_marker": self.missing_glyph_visible_marker,
            "smart_object_policy": self.smart_object_policy
        }


def export_diagnosis_json(report: Dict[str, Any], output_path: str) -> str:
    """
    导出标准格式的 JSON 转换诊断报告到指定文件路径。
    自动创建父级目录，使用 UTF-8 编码与良好缩进。
    """
    abs_path = os.path.abspath(output_path)
    os.makedirs(os.path.dirname(abs_path), exist_ok=True)
    with open(abs_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    return abs_path


def _export_layer_png(
    layer: Any,
    png_output_dir: str,
    filename: str
) -> Tuple[Optional[str], Optional[Dict[str, Any]], Optional[str]]:
    """R33 / A-68：把图层渲染为 PNG 并落盘，返回 (path, info, error)。

    统一封装，避免「解析器说已降级为贴图、实际却没生成文件」的分裂。
    error 非空时调用方必须如实记录，绝不宣称已生成贴图。
    """
    try:
        ok, png_bytes, png_info = render_layer_to_png_bytes(layer)
        if not ok or not png_bytes:
            err = (png_info or {}).get("error", "未知错误")
            return None, png_info, f"Media 资产生成失败: {err}"
        out_path = os.path.join(png_output_dir, filename)
        with open(out_path, "wb") as pf:
            pf.write(png_bytes)
        info = dict(png_info or {})
        info["path"] = os.path.abspath(out_path)
        info["filename"] = filename
        info["file_size"] = os.path.getsize(out_path)
        return out_path, info, None
    except Exception as exc:  # 绝不静默：任何异常都带回调用方记录
        return None, None, f"Media 资产生成失败: {exc}"


def parse_psd_file(
    psd_path: str,
    extract_fallback_pngs: bool = False,
    png_output_dir: Optional[str] = None,
    extract_thumbnails: bool = True,
    smart_object_policy: str = "flatten",
    include_hidden: bool = False
) -> Dict[str, Any]:
    """
    解析指定路径的 PSD 文件，提取全属性图层信息，生成图层树与转换诊断报告。
    
    返回字段涵盖：
    - 基础信息: file_name, file_path, width, height, aspect_ratio_str, resolution_str, total_layers_count
    - 导出图层: layers (List[PSDLayerInfo]), layer_count
    - 层级树: layer_tree
    - 诊断报告: diagnosis_report
    - 兼容字段: aspect_ratio, resolution_spec, diagnostics

    R33 / A-68：extract_fallback_pngs=True + png_output_dir 时，可见的位图/装饰
    图层与底板图层会真实生成 PNG（画布据此显示画面），并把路径写入返回值。
    R33 / A-70：include_hidden=True 时，隐藏图层以 visible=False 的预览层进入
    layers（仅用于界面「显示隐藏图层」预览），不改变转换口径与层数守恒。
    """
    if not os.path.exists(psd_path):
        raise FileNotFoundError(f"PSD 文件不存在: {psd_path}")

    try:
        psd = PSDImage.open(psd_path)
        canvas_w, canvas_h = psd.size
    except Exception as exc:
        raise PSDParseError(psd_path, exc) from exc

    file_name = os.path.basename(psd_path)
    file_path = os.path.abspath(psd_path)
    center_x = canvas_w / 2.0
    center_y = canvas_h / 2.0

    ratio_str, res_str = detect_aspect_ratio(canvas_w, canvas_h)

    layers_info: List[PSDLayerInfo] = []
    diagnostics_warnings: List[str] = []
    diagnostics_notes: List[str] = []
    font_diagnostics: List[Dict[str, Any]] = []
    fallback_layers: List[Dict[str, Any]] = []
    diagnosis_layers: List[Dict[str, Any]] = []
    layer_tree_nodes: List[Dict[str, Any]] = []
    layer_map_by_path: Dict[str, Dict[str, Any]] = {}

    layer_idx = 1
    total_layers_scanned = 0
    text_layers_count = 0
    fallback_layers_count = 0
    # R33 / A-70：被忽略图层的分项计数（全部必须可解释、可透出到诊断）。
    hidden_layers_count = 0
    hidden_layer_names: List[str] = []
    background_layers_count = 0
    group_layers_count = 0
    empty_layers_count = 0
    # R33 / A-70：include_hidden=True 时进入 layers 的预览层数量
    # （它们不计入转换 output，只供画布/列表预览）。
    preview_layer_count = 0
    # R33 / A-68：底板图层本身按规范不参与转换，但画布需要它才能看见完整画面。
    background_preview: Optional[Dict[str, Any]] = None
    # R25 SA-2b（SA-4 问题 2 修复）：机器可核查计数器——
    # 应产出 Media/element_XX.png 却生成失败的降级层数量。
    # > 0 时整体诊断不得宣称完整成功（risk_assessment 必须显式示警）。
    missing_media_refs_count = 0

    original_composite_path: Optional[str] = None
    if extract_fallback_pngs and png_output_dir:
        os.makedirs(png_output_dir, exist_ok=True)
        # R45：导出 PSD 完整成图（用于画布直观对比功能：卷帘/并排/按住对比）
        try:
            comp_img = None
            if hasattr(psd, "composite"):
                comp_img = psd.composite()
            elif hasattr(psd, "topil"):
                comp_img = psd.topil()
            if comp_img is not None:
                comp_file = os.path.join(png_output_dir, "original_composite.png")
                comp_img.save(comp_file, format="PNG")
                if os.path.exists(comp_file) and os.path.getsize(comp_file) > 0:
                    original_composite_path = comp_file
                    diagnostics_notes.append(f"已导出 PSD 原始完整合成图: {os.path.basename(comp_file)}")
        except Exception as comp_err:
            diagnostics_notes.append(f"PSD 原始合成图导出跳过: {comp_err}")

    # R33 / A-68（兜底）：纯照片稿往往没有名为「背景」的底板层，而是一张铺满整幅的
    # 像素照片置于栈底。这类层被旧规则当作普通位图降级输出，转换口径没问题，但
    # 画布一旦只画文字就会全黑。因此在主循环前先确定「最底部整幅像素层」作为画布
    # 自动底板（background_preview 的来源）。descendants() 自上而下遍历，最后迭代到的
    # 整幅像素层即栈底那张。
    auto_bg_path: Optional[str] = None
    for _lp in psd.descendants():
        if _lp.kind == "pixel" and not _lp.is_group() and layer_is_effectively_visible(_lp):
            _bbox = _lp.bbox
            if _bbox == (0, 0, canvas_w, canvas_h):
                auto_bg_path = get_layer_path(_lp)  # 持续覆盖 -> 落到底部那张

    # 深度优先遍历所有图层（包含组、空图层、隐藏图层）
    for layer in psd.descendants():
        total_layers_scanned += 1
        name = layer.name or f"Layer_{total_layers_scanned}"
        layer_path = get_layer_path(layer)
        parent_path = get_parent_path(layer)
        
        is_grp = layer.is_group()
        if is_grp:
            real_type = "group"
        elif layer.kind == "type":
            real_type = "type"
        elif layer.kind == "smartobject":
            real_type = "smartobject"
        elif layer.kind == "shape":
            real_type = "shape"
        elif layer.kind == "pixel":
            real_type = "pixel"
        elif layer.kind == "adjustment":
            real_type = "adjustment"
        else:
            real_type = str(layer.kind)

        # 缩略图生成
        has_thumb, thumb_bytes, thumb_b64, orig_bytes = (
            generate_layer_thumbnail(layer) if extract_thumbnails else (False, None, None, None)
        )

        # 特性与效果分析
        layer_effects = extract_layer_effects(layer)
        blend_feature = extract_layer_blend_mode(layer)
        # R25 C-3/C-4/C-5：结构化提取图层样式 + 混合模式 Motion 写出就绪表示
        layer_styles = extract_layer_styles(layer)
        motion_blend = format_blend_mode_for_motion(blend_feature)
        unsupported_features: List[str] = []
        if layer_effects:
            unsupported_features.extend(layer_effects)
        if blend_feature:
            unsupported_features.append(blend_feature)
        # 判定图层包围盒与空状态
        bbox = layer.bbox
        is_empty_box = (bbox is None or (bbox[2] - bbox[0] <= 0) or (bbox[3] - bbox[1] <= 0))
        is_bg = (
            real_type == "pixel" and (
                name.strip() in ("图层 0", "背景", "Background", "图层0", "bg", "BG", "Layer 0") or
                (bbox == (0, 0, canvas_w, canvas_h) and name.strip() in ("图层 1", "图层 2", "Layer 1", "Layer 2", "BG")) or
                # R33 / A-68 兜底：底部整幅像素层即画布主体，无论中文名如何
                (layer_path == auto_bg_path)
            )
        )

        if real_type == "smartobject":
            unsupported_features.append("智能对象 (SmartObject)")
        if real_type == "shape":
            unsupported_features.append("矢量形状 (Shape)")
        if real_type == "pixel" and not is_bg:
            unsupported_features.append("位图像素图层 (Pixel)")

        # 初始化诊断字段
        disposition = "ignored"
        reason = ""
        font_status = None
        missing_glyphs = []
        fallback_font = None
        fallback_png_info = None
        error_details = None
        is_blocking = False
        this_layer_idx = None
        # R25 C 域诊断字段默认值（type 分支会按需覆盖）
        warp_detected = False
        warp_warning = ""
        highlight_missing_font = False
        marked_text = ""
        missing_glyph_visible_marker = False
        # R25 SA-2b（SA-4 问题 1/2 修复）新增逐层状态：
        #   skip_layer_output: True 时该层不进入 layers_info（如 skip 策略的智能对象），
        #                       但诊断条目与树节点照常记录（disposition='ignored'），
        #                       保证 input == output + skipped 对所有策略 × 可见性恒成立；
        #   png_path / media_error / severity: 降级层媒体资产生成状态与失败详情。
        skip_layer_output = False
        png_path = None
        media_error = None
        severity = None

        # ── 处置决策逻辑 ──
        if is_grp:
            disposition = "ignored"
            reason = "图层组容器，仅保留层级结构，无需独立渲染"
            group_layers_count += 1
        elif is_bg:
            disposition = "ignored"
            reason = f"背景底板图层 ('{name}')，已按规范过滤忽略"
            background_layers_count += 1
            diagnostics_notes.append(f"跳过默认底板图层: '{name}'")
            # R33 / A-68：底板不参与转换，但它是画布画面的主体。
            # 有 PNG 导出能力时必须真实生成预览贴图，否则纯照片稿画布只能全黑。
            if extract_fallback_pngs and png_output_dir and not is_empty_box and layer_is_effectively_visible(layer):
                safe_bg = "".join(c for c in name if c.isalnum() or c in ('_', '-')).strip() or "background"
                bg_path, bg_info, bg_err = _export_layer_png(
                    layer, png_output_dir, f"background_{layer_idx:02d}_{safe_bg}.png"
                )
                if bg_path:
                    background_preview = {
                        "name": name,
                        "png_path": bg_path,
                        "psd_bbox": list(bbox),
                        "width": bg_info.get("width"),
                        "height": bg_info.get("height"),
                        "opacity": round(layer.opacity / 255.0, 2) if hasattr(layer, "opacity") else 1.0,
                    }
                    diagnostics_notes.append(
                        f"底板图层 '{name}' 已生成画布预览贴图: {bg_info.get('filename')}"
                        f"（{bg_info.get('width')}x{bg_info.get('height')}，{bg_info.get('file_size')} 字节）"
                    )
                else:
                    diagnostics_notes.append(f"底板图层 '{name}' 预览贴图生成失败: {bg_err}")
        elif is_empty_box:
            disposition = "ignored"
            reason = f"空图层（尺寸为0或无有效像素边界: '{name}'），自动忽略"
            empty_layers_count += 1
            if not is_grp:
                diagnostics_notes.append(f"跳过空图层: '{name}'（无有效像素边界）")
        elif not layer_is_effectively_visible(layer):
            disposition = "ignored"
            reason = f"隐藏未激活图层 ('{name}')，按设计规范忽略不导出"
            # R33 / A-70：隐藏层必须与底板层对称地写入 notes，禁止静默丢弃。
            hidden_layers_count += 1
            hidden_layer_names.append(name)
            diagnostics_notes.append(
                f"跳过隐藏图层: '{name}'（按设计规范不参与转换；"
                f"勾选「显示隐藏图层」可预览）"
            )
            # R25 C-2：隐藏的智能对象在 skip 策略下同样必须显式写明"跳过"，
            # 原因文案须指明是智能对象且策略为 skip，绝不静默。
            if real_type == "smartobject" and smart_object_policy == "skip":
                reason += (
                    f"；智能对象策略=skip: 该隐藏图层为智能对象，"
                    f"已按 smart_object_policy='skip' 显式跳过并记录原因（非静默丢失）"
                )
            # R33 / A-70 / R42 / A-73：可选预览——把隐藏层渲染为 visible=False 的贴图层
            if include_hidden and extract_fallback_pngs and png_output_dir:
                safe_hidden = "".join(c for c in name if c.isalnum() or c in ('_', '-')).strip() or "hidden"
                hid_path, hid_info, hid_err = _export_layer_png(
                    layer, png_output_dir, f"hidden_{layer_idx:02d}_{safe_hidden}.png"
                )
                if hid_path:
                    left, top, right, bottom = bbox
                    hid_cx = (left + right) / 2.0
                    hid_cy = (top + bottom) / 2.0
                    this_layer_idx = layer_idx
                    # R42 / A-73：在 include_hidden=True 下，已提取输出的隐藏层
                    # 处置口径归正为 degraded（位图贴图输出），纳入有效输出层统计
                    disposition = "degraded"
                    reason = f"隐藏图层已作为预览贴图输出 ('{name}')"
                    layers_info.append(PSDLayerInfo(
                        index=this_layer_idx,
                        name=name,
                        kind="fallback_png",
                        text="",
                        font_name="",
                        font_size=0.0,
                        tracking=0.0,
                        psd_bbox=bbox,
                        motion_pos=(round(hid_cx - center_x, 2), round(center_y - hid_cy, 2)),
                        visible=False,
                        is_published=False,
                        rotation=detect_layer_rotation(layer),
                        opacity=round(layer.opacity / 255.0, 2) if hasattr(layer, "opacity") else 1.0,
                        fallback_png_path=hid_path,
                        fallback_png_info=hid_info,
                        diagnostic_notes=[
                            f"类型: 隐藏图层预览 ({real_type})",
                            f"处置: {reason}",
                        ],
                        layer_path=layer_path,
                        layer_type=real_type,
                        has_thumbnail=has_thumb,
                        thumbnail_bytes=thumb_bytes,
                        thumbnail_base64=thumb_b64,
                        original_slice_bytes=orig_bytes,
                        disposition="degraded",
                        disposition_reason=reason,
                        unsupported_features=unsupported_features,
                        effects=layer_effects,
                        layer_styles=layer_styles,
                        smart_object_policy=smart_object_policy,
                    ))
                    preview_layer_count += 1
                    layer_idx += 1
                    diagnostics_notes.append(
                        f"隐藏图层 '{name}' 已生成预览贴图: {hid_info.get('filename')}"
                    )
                else:
                    diagnostics_notes.append(f"隐藏图层 '{name}' 预览贴图生成失败: {hid_err}")
        elif real_type == "type":
            # ── 纯矢量文本图层 ──
            raw_text = layer.text or ""
            text_content = raw_text.replace("\r\n", "\n").replace("\r", "\n")

            # 检查变形文字 (R25 C-6：检测到必须告警，绝不静默降级)
            warp_detected = False
            warp_warning = ""
            warp_style = detect_warp(layer)
            if warp_style:
                warp_detected = True
                warp_label = f"变形文字 ({warp_style})"
                unsupported_features.append(warp_label)
                warp_warning = build_warp_warning(name, warp_style)
                diagnostics_warnings.append(warp_warning)

            # 提取原始字体
            original_font = "Helvetica"
            try:
                font_set = layer.resource_dict.get("FontSet", [])
                if not font_set and hasattr(layer, "engine_dict") and layer.engine_dict:
                    rd = layer.engine_dict.get("ResourceDict", {})
                    font_set = rd.get("FontSet", [])

                if font_set:
                    for f in font_set:
                        fname = _extract_string_value(f.get("Name", ""))
                        if fname and "AdobeInvis" not in fname and "AdobeHeiti" not in fname:
                            original_font = fname
                            break
                        elif fname and original_font == "Helvetica":
                            original_font = fname
            except Exception as e:
                diagnostics_notes.append(f"未能解析特定字体元数据({e})，已回退为系统标准字体")

            # 字体可用性与字形覆盖度深度检测
            # A-10 修复要点：用三态而非布尔值。
            #   布尔 check_font_availability() 会把"无检测能力"与"未安装"都压成 False，
            #   导致无 AppKit 平台（Linux 等）把"无法检测"误报为"字体未安装"。
            font_availability = check_font_availability_status(original_font)
            is_font_available = (font_availability == "available")
            has_chinese = any('\u4e00' <= char <= '\u9fff' for char in text_content)
            fallback_target = "PingFangSC-Regular" if has_chinese else "Helvetica"
            glyph_cov = check_font_glyph_coverage(original_font, text_content)

            font_status = glyph_cov["status"]
            missing_glyphs = glyph_cov["missing_chars"]

            if is_font_available and not glyph_cov["has_missing_risk"]:
                detection_status = "detected"
                fallback_font = original_font
                active_font = original_font
                diagnostics_notes.append(f"图层 '{name}' 字体检测通过: '{original_font}' (字形覆盖率 100%)")
            else:
                # 按真实原因区分检测状态，禁止把三种语义混为一谈：
                #   font_missing   —— 环境可检测，且字体确实未安装
                #   unverifiable   —— 环境无法检测（无 AppKit / 字形枚举失败），风险未知
                #   missing_fallback —— 字体已安装，但字符集确实缺字形
                # A-10 修复要点：只有 font_availability == "missing" 才允许归 font_missing；
                # 无检测能力时必须归 unverifiable，否则跨平台会把"无法检测"谎报为"未安装"。
                if font_availability == "unverifiable" or glyph_cov["status"] == "unverifiable":
                    detection_status = "unverifiable"
                elif font_availability == "missing":
                    detection_status = "font_missing"
                else:
                    detection_status = "missing_fallback"
                fallback_font = fallback_target
                active_font = fallback_target

                if detection_status == "unverifiable":
                    warning_msg = (
                        f"图层 '{name}' 原始字体 '{original_font}' 的可用性与字形覆盖度"
                        f"在当前平台无法检测（缺少 AppKit 或字形枚举失败），"
                        f"缺字风险未知，已回退采用 '{fallback_font}' 并标记待复核"
                    )
                elif detection_status == "font_missing":
                    warning_msg = (
                        f"图层 '{name}' 原始字体 '{original_font}' 在系统中未安装，"
                        f"已自动推荐并回退采用 '{fallback_font}'"
                    )
                else:
                    cov_str = (
                        f"（覆盖率 {glyph_cov['coverage_rate']*100:.1f}%）"
                        if glyph_cov.get("coverage_rate") is not None else "（无法验证字形覆盖率）"
                    )
                    warning_msg = (
                        f"图层 '{name}' 原始字体 '{original_font}' 缺少字符 {missing_glyphs} 的字形"
                        f"{cov_str}，已自动回退采用 '{fallback_font}'"
                    )
                diagnostics_warnings.append(warning_msg)

            font_info_dict = {
                "original_font": original_font,
                "detection_status": detection_status,
                "fallback_font": fallback_font,
                "glyph_coverage": glyph_cov["coverage_rate"],
                # R31 / A-59：把两种语义拆开，避免「unverifiable → has_missing_glyphs=True 但
                # missing_chars=[]」的自相矛盾。
                #   has_confirmed_missing_glyphs —— 确证缺字（missing_chars 非空）
                #   has_glyph_risk               —— 任何风险（含无法验证）
                #   has_missing_glyphs           —— 旧字段，保留兼容，语义等同 has_glyph_risk
                "has_confirmed_missing_glyphs": bool(missing_glyphs),
                "has_glyph_risk": glyph_cov["has_missing_risk"],
                "has_missing_glyphs": glyph_cov["has_missing_risk"],
                "has_missing_glyphs_deprecated": True,
                "missing_chars": missing_glyphs
            }

            # R25 C-10：缺字可见标记 + 不可降级告警（绝不静默用默认字体顶替）
            # 设计：输出字体仍引用原始字体；fallback_font 仅作为"推荐回退"记录在诊断中。
            # 真正缺字形时，用可见 tofu 标记替换缺失字符（marked_text），并由 highlight_missing_font
            # 驱动诊断面板高亮。font_substituted 显式记录是否发生了默认字体替换，绝不静默。
            highlight_missing_font = should_highlight_missing_font(
                font_status, glyph_cov["has_missing_risk"]
            )
            marked_text = apply_missing_glyph_markers(text_content, missing_glyphs)
            missing_glyph_visible_marker = bool(missing_glyphs)
            # R28 / A-56：font_substituted 必须描述「实际是否替换」——
            # fallback_font 在字体可用且字形完整时被回填为 original_font（未替换），
            # 只有走了回退分支才会是 fallback_target。旧实现比较 fallback_target 与
            # original_font，导致真机 macOS（AppKit 可用、字体完整）下每个中文层都被
            # 误报为「已替换」，属诊断口径错误（无 AppKit 环境恰好掩盖了它）。
            font_substituted = (fallback_font != original_font)
            font_info_dict["highlight_missing_font"] = highlight_missing_font
            font_info_dict["marked_text"] = marked_text
            font_info_dict["missing_glyph_visible_marker"] = missing_glyph_visible_marker
            font_info_dict["font_substituted"] = font_substituted
            if highlight_missing_font:
                diagnostics_warnings.append(
                    f"图层 '{name}' 存在缺字/缺字体风险 ({font_status})，"
                    f"已用可见缺字标记并高亮，未静默替换默认字体"
                )

            font_diagnostics.append({
                "layer_index": layer_idx,
                "layer_name": name,
                "layer_path": layer_path,
                "original_font": original_font,
                "detection_status": detection_status,
                "fallback_font": fallback_font,
                "glyph_coverage": glyph_cov["coverage_rate"],
                # R31 / A-59：同上，风险与确证缺字分开
                "has_confirmed_missing_glyphs": bool(missing_glyphs),
                "has_glyph_risk": glyph_cov["has_missing_risk"],
                "has_missing_glyphs": glyph_cov["has_missing_risk"],
                "missing_chars": missing_glyphs
            })

            # 判定文字处置
            # 处置原因必须按字体/字形四态分化，禁止四态共用同一句文案，
            # 否则会出现「缺 1 字」与「字体元数据完整」同行的自相矛盾。
            disposition = "preserved"
            reason = build_preserved_reason(font_status, missing_glyphs, fallback_font)

            # 坐标换算与 MotionLayerInfo 组装
            left, top, right, bottom = bbox
            layer_cx = (left + right) / 2.0
            layer_cy = (top + bottom) / 2.0
            motion_x = round(layer_cx - center_x, 2)
            motion_y = round(center_y - layer_cy, 2)
            opacity = round(layer.opacity / 255.0, 2) if hasattr(layer, "opacity") else 1.0
            safe_area_info = calculate_safe_area_status(canvas_w, canvas_h, bbox, (motion_x, motion_y))

            lines = [l for l in text_content.split("\n") if l.strip()]
            direction = "vertical" if (len(lines) > 1 and all(len(l) <= 2 for l in lines)) else "horizontal"

            font_size = 36.0
            tracking = 0.0
            line_spacing = round(font_size * 1.2, 5)
            alignment = "left"
            # TR-023-B：文字填充色（PSD 文字层 StyleSheetData.FillColor，0..1 浮点）。
            # 取不到就留空串，Swift 侧据此显示禁用空态，不填假色。
            text_color = ""
            try:
                engine_data = layer.engine_dict
                style_runs = engine_data.get("StyleRun", {}).get("RunArray", [])
                if style_runs and "StyleSheet" in style_runs[0]:
                    sheet_data = style_runs[0]["StyleSheet"].get("StyleSheetData", {})
                    font_size = float(sheet_data.get("FontSize", 36.0))
                    tracking = float(sheet_data.get("Tracking", 0.0)) / 1000.0

                    # TR-023-B：FillColor.Values = [r, g, b, a]（0..1）。缺项/越界一律丢弃。
                    fill_values = (sheet_data.get("FillColor") or {}).get("Values") or []
                    if len(fill_values) >= 3:
                        channels = []
                        for raw_channel in fill_values[:3]:
                            try:
                                channels.append(max(0.0, min(1.0, float(raw_channel))))
                            except (TypeError, ValueError):
                                channels = []
                                break
                        if len(channels) == 3:
                            text_color = "#%02X%02X%02X" % tuple(
                                int(round(c * 255)) for c in channels
                            )

                    auto_leading = sheet_data.get("AutoLeading", True)
                    leading_val = sheet_data.get("Leading")
                    if not auto_leading and leading_val is not None:
                        line_spacing = float(leading_val)
                    else:
                        line_spacing = round(float(font_size * 1.2), 5)
                else:
                    line_spacing = round(float(font_size * 1.2), 5)

                paragraph_runs = engine_data.get("ParagraphRun", {}).get("RunArray", [])
                if paragraph_runs and "ParagraphSheet" in paragraph_runs[0]:
                    p_props = paragraph_runs[0]["ParagraphSheet"].get("Properties", {})
                    justification = p_props.get("Justification", 0)
                    if justification == 1:
                        alignment = "right"
                    elif justification == 2:
                        alignment = "center"
                    else:
                        alignment = "left"
            except Exception:
                char_count = max(1, len(text_content.replace("\n", "")))
                box_h = bottom - top
                font_size = round(box_h / char_count, 1)
                line_spacing = round(font_size * 1.2, 5)
                alignment = "left"

            this_layer_idx = layer_idx
            # 从仿射变换矩阵还原真实旋转角（竖排文本 90°/270° 必须保留，不得硬编码 0.0）
            layer_rotation = detect_layer_rotation(layer)
            # C-5：混合模式 Motion 写出就绪片段
            motion_blend_xml = serialize_motion_param_block(motion_blend) if motion_blend.get("supported") else ""
            # 诊断备注：把告警类信息显式沉淀下来，便于诊断面板高亮
            diag_notes = [f"字体: {original_font}", f"处置: {reason}"]
            if highlight_missing_font:
                diag_notes.append(f"缺字/缺字体高亮: {font_status}，已用可见缺字标记")
            if warp_detected:
                diag_notes.append(warp_warning)
            layer_info = PSDLayerInfo(
                index=this_layer_idx,
                name=name,
                kind="type",
                text=text_content,
                font_name=original_font,
                font_size=font_size,
                tracking=tracking,
                psd_bbox=bbox,
                motion_pos=(motion_x, motion_y),
                safe_area=safe_area_info,
                visible=layer_is_effectively_visible(layer),
                is_published=True,
                rotation=layer_rotation,
                scale_x=1.0,
                scale_y=1.0,
                opacity=opacity,
                line_spacing=line_spacing,
                writing_direction=direction,
                font_info=font_info_dict,
                diagnostic_notes=diag_notes,
                layer_path=layer_path,
                layer_type=real_type,
                has_thumbnail=has_thumb,
                thumbnail_bytes=thumb_bytes,
                thumbnail_base64=thumb_b64,
                original_slice_bytes=orig_bytes,
                disposition=disposition,
                disposition_reason=reason,
                unsupported_features=unsupported_features,
                effects=layer_effects,
                layer_styles=layer_styles,
                motion_blend_mode=motion_blend,
                motion_blend_mode_xml=motion_blend_xml,
                warp_detected=warp_detected,
                warp_warning=warp_warning,
                highlight_missing_font=highlight_missing_font,
                marked_text=marked_text,
                missing_glyph_visible_marker=missing_glyph_visible_marker,
                smart_object_policy=smart_object_policy,
                alignment=alignment,
                text_color=text_color
            )
            layers_info.append(layer_info)
            text_layers_count += 1
            layer_idx += 1

        else:
            # ── 复杂/非文本图层（智能对象、装饰图案、图形形状）──
            kind_desc, _ = classify_non_text_layer(real_type)
            style_desc = f"，包含样式: {', '.join(layer_effects)}" if layer_effects else ""

            # R25 C-2：智能对象二选一处置，绝不静默丢弃
            #   - 默认 flatten：展平为嵌入 PNG 位图；
            #   - skip 策略：显式跳过并记录原因（仍计入 skipped_layer_count，绝不消失）。
            # R25 SA-2b（SA-4 问题 1 修复）：skip 策略下该层【不得】进入 layers_info——
            # 之前这里缺少 continue/守卫，被"显式跳过"的层仍被 append 进输出层列表，
            # 同时又被 ignored_count 统计，双重计数导致 input != output + skipped
            #（SA-4 实测 input=12 output=7 skipped=7，差 -2）。现在 skip 层只保留
            # 诊断条目（disposition='ignored'，reason 含"跳过"）与树节点，不产出
            # layer_info，守恒式对所有 smart_object_policy × 可见性组合恒成立。
            if real_type == "smartobject" and smart_object_policy == "skip":
                disposition = "ignored"
                reason = (
                    f"智能对象图层{style_desc}，按 smart_object_policy='skip' 策略"
                    f"显式跳过并记录原因，未参与转换（非静默丢失）"
                )
                diagnostics_notes.append(f"智能对象跳过: '{name}'")
                fallback_png_info = None
                skip_layer_output = True
            else:
                disposition = "degraded"
                # R33 / A-68：先只说「需要降级」，是否真的生成贴图在下方按事实追加。
                # 绝不能在贴图未生成时仍宣称「已降级为 32 位透明 RGBA 贴图」。
                reason = f"{kind_desc}图层{style_desc}，矢量引擎不支持直接渲染，按设计降级为位图贴图层"
                fallback_layers_count += 1

                # R25 C-9：降级为嵌入 PNG 位图（集中到 render_layer_to_png_bytes，含 IHDR 校验）
                # R25 SA-2b（SA-4 问题 2 修复）：
                #   - png_path 仅在 PNG 真正落盘成功后才赋值，失败时保持 None，
                #     杜绝 layer_info / .moti 引用不存在的 Media/element_XX.png；
                #   - 生成失败必须大声记录：诊断条目带 severity='error' 与
                #     "Media 资产生成失败: <原因>"，并计入 missing_media_refs 计数器；
                #   - 失败层仍以 degraded 计入 output（绝不静默丢弃，守恒不变）。
                if extract_fallback_pngs and png_output_dir:
                    safe_name = "".join(c for c in name if c.isalnum() or c in ('_', '-')).strip() or f"layer_{layer_idx}"
                    png_filename = f"element_{layer_idx:02d}_{safe_name}.png"
                    png_path, png_info, media_error = _export_layer_png(
                        layer, png_output_dir, png_filename
                    )
                    if png_path:
                        fallback_png_info = png_info
                        diagnostics_notes.append(
                            f"图层 '{name}' ({kind_desc}) 成功导出 32 位透明 PNG: {png_filename} "
                            f"(尺寸: {png_info['width']}x{png_info['height']}, "
                            f"{png_info['bit_depth']}-bit per channel, {png_info['file_size']} 字节)"
                        )
                        reason += (
                            f"；已生成 32 位透明 RGBA 贴图 {png_filename}"
                            f"（{png_info['width']}x{png_info['height']}）"
                        )
                    if media_error:
                        # 媒体缺失是硬错误：绝不静默放行、绝不让整体诊断宣称完整成功。
                        severity = "error"
                        error_details = media_error
                        reason += (
                            f"；{media_error}"
                            f"（该层降级保留并计入 output，但无可用媒体文件，"
                            f"下游不得为它引用不存在的 PNG；画布无法显示该层）"
                        )
                        diagnostics_warnings.append(f"图层 '{name}' {media_error}")
                        missing_media_refs_count += 1
                        fallback_png_info = {
                            "error": media_error,
                            "missing_media_ref": True,
                        }
                else:
                    # R33 / A-68 / 红线 3：没有导出能力时必须如实说明，
                    # 禁止用「已安全降级为贴图」掩盖「画布根本画不出来」。
                    reason += "；未生成贴图（PNG 导出未启用），画布无法显示该层"
                    diagnostics_notes.append(
                        f"图层 '{name}' ({kind_desc}) 未生成贴图：PNG 导出未启用，画布无法显示该层"
                    )

                if fallback_png_info and fallback_png_info.get("path"):
                    fallback_layers.append({
                        "layer_index": layer_idx,
                        "layer_name": name,
                        "layer_path": layer_path,
                        "kind": kind_desc,
                        "png_info": fallback_png_info
                    })

                left, top, right, bottom = bbox
                layer_cx = (left + right) / 2.0
                layer_cy = (top + bottom) / 2.0
                motion_x = round(layer_cx - center_x, 2)
                motion_y = round(center_y - layer_cy, 2)
                opacity = round(layer.opacity / 255.0, 2) if hasattr(layer, "opacity") else 1.0
                safe_area_info = calculate_safe_area_status(canvas_w, canvas_h, bbox, (motion_x, motion_y))

                this_layer_idx = layer_idx
                layer_info = PSDLayerInfo(
                    index=this_layer_idx,
                    name=name,
                    kind="fallback_png",
                    text="",
                    font_name="",
                    font_size=0.0,
                    tracking=0.0,
                    psd_bbox=bbox,
                    motion_pos=(motion_x, motion_y),
                    safe_area=safe_area_info,
                    visible=layer_is_effectively_visible(layer),
                    is_published=False,
                    rotation=detect_layer_rotation(layer),
                    scale_x=1.0,
                    scale_y=1.0,
                    opacity=opacity,
                    writing_direction="horizontal",
                    fallback_png_path=png_path,
                    fallback_png_info=fallback_png_info,
                    diagnostic_notes=[f"类型: {kind_desc} (降级贴图)", f"处置: {reason}"],
                    layer_path=layer_path,
                    layer_type=real_type,
                    has_thumbnail=has_thumb,
                    thumbnail_bytes=thumb_bytes,
                    thumbnail_base64=thumb_b64,
                    original_slice_bytes=orig_bytes,
                    disposition=disposition,
                    disposition_reason=reason,
                    unsupported_features=unsupported_features,
                    effects=layer_effects,
                    layer_styles=layer_styles,
                    motion_blend_mode=motion_blend,
                    motion_blend_mode_xml=serialize_motion_param_block(motion_blend) if motion_blend.get("supported") else "",
                    smart_object_policy=smart_object_policy
                )
                layers_info.append(layer_info)
                layer_idx += 1
            # skip_layer_output=True 的层到此为止：不构造 layer_info、不进入
            # layers_info、不消耗 layer_idx；下方的诊断条目与树节点照常记录。

        # 记录每层诊断条目
        diag_item = {
            "source_file": {
                "name": file_name,
                "path": file_path
            },
            "layer_index": this_layer_idx,
            "layer_path": layer_path,
            # R25 C-7：诊断条目必须记录父级层级路径（顶层图层为空串），
            # 供诊断面板还原组层级，与 layer_tree 的 parent_path 口径一致。
            "parent_path": parent_path,
            "layer_name": name,
            "layer_type": real_type,
            "disposition": disposition,
            "reason": reason,
            "font_status": font_status,
            "missing_glyphs": missing_glyphs,
            "fallback_font": fallback_font,
            "fallback_png": fallback_png_info,
            "unsupported_features": unsupported_features,
            "error_details": error_details,
            "is_blocking": is_blocking,
            # R25 SA-2b（SA-4 问题 2 修复）：severity='error' 表示该层存在
            # 必须人工介入的硬问题（如媒体资产生成失败），绝非静默；
            # media_error 携带 "Media 资产生成失败: <原因>" 的确切失败原因。
            "severity": severity,
            "media_error": media_error,
            # R25 C 域增强诊断字段
            "layer_styles": layer_styles,
            "motion_blend_mode": motion_blend,
            "warp_detected": warp_detected,
            "warp_warning": warp_warning,
            "highlight_missing_font": highlight_missing_font,
            "marked_text": marked_text,
            "missing_glyph_visible_marker": missing_glyph_visible_marker,
            "smart_object_policy": smart_object_policy
        }
        diagnosis_layers.append(diag_item)

        # 记录树状结构节点
        tree_node = {
            "name": name,
            "layer_index": this_layer_idx,
            "layer_path": layer_path,
            "parent_path": parent_path,
            "layer_type": real_type,
            "is_group": is_grp,
            "visible": layer_is_effectively_visible(layer),
            "raw_visible": bool(layer.visible),
            "effective_visible": layer_is_effectively_visible(layer),
            "depth": layer_path.count("/") + 1,
            "bbox": bbox,
            "has_thumbnail": has_thumb,
            "thumbnail_bytes": thumb_bytes,
            "thumbnail_base64": thumb_b64,
            "original_slice_bytes": orig_bytes,
            "disposition": disposition,
            "reason": reason,
            "font_status": font_status,
            "unsupported_features": unsupported_features,
            "children": []
        }
        layer_map_by_path[layer_path] = tree_node
        if parent_path and parent_path in layer_map_by_path:
            layer_map_by_path[parent_path]["children"].append(tree_node)
        else:
            layer_tree_nodes.append(tree_node)

    # 统计诊断汇总指标
    preserved_count = sum(1 for d in diagnosis_layers if d["disposition"] == "preserved")
    degraded_count = sum(1 for d in diagnosis_layers if d["disposition"] == "degraded")
    ignored_count = sum(1 for d in diagnosis_layers if d["disposition"] == "ignored")
    failed_count = sum(1 for d in diagnosis_layers if d["disposition"] == "failed")
    missing_fonts_count = sum(
        1 for d in diagnosis_layers if d.get("font_status") in ("font_missing", "partial_missing")
    )
    # unverifiable 代表字体环境无法校验（如 Linux 无 AppKit、字符集对象缺失、AppKit 调用异常），
    # 此时既不能宣称"字体覆盖率 100%"，也不能宣称"无风险"，必须单列并计入风险。
    unverifiable_fonts_count = sum(
        1 for d in diagnosis_layers if d.get("font_status") == "unverifiable"
    )
    # R25 SA-2b（SA-4 问题 3 修复）：缺字图层数——存在真实缺字形并用 □ 可见
    # 标记替换的文本层数（marked_text 与原文不同）。机器可核查计数器，
    # 供 GUI/测试断言；GUI 侧徽章/悬浮提示的接线归 SA-3 的 gui/ 域。
    missing_glyph_layers = sum(
        1 for d in diagnosis_layers if d.get("missing_glyph_visible_marker")
    )

    # R33 / A-69 / R42 / A-73：被忽略图层的分项必须能解释总和
    # 在 include_hidden=True 下，已渲染输出的隐藏层不属于被忽略层
    effective_hidden_ignored = hidden_layers_count - (preview_layer_count if include_hidden else 0)
    other_ignored_count = max(
        0,
        ignored_count - effective_hidden_ignored - background_layers_count
        - group_layers_count - empty_layers_count,
    )
    ignored_parts: List[str] = []
    if effective_hidden_ignored:
        ignored_parts.append(f"{effective_hidden_ignored} 个隐藏")
    if background_layers_count:
        ignored_parts.append(f"{background_layers_count} 个底板")
    if group_layers_count:
        ignored_parts.append(f"{group_layers_count} 个组容器")
    if empty_layers_count:
        ignored_parts.append(f"{empty_layers_count} 个空层")
    if other_ignored_count:
        ignored_parts.append(f"{other_ignored_count} 个其他")
    # R33 / A-69：只有「非底板」的被忽略层（隐藏/空/组/其他）才构成需要警示的
    # 信息损耗；底板按规范过滤是正常预期，不应把纯文字+底板稿误判成「注意/有风险」。
    non_bg_ignored = max(0, ignored_count - background_layers_count)
    if ignored_count:
        ignored_summary = f"已忽略 {ignored_count} 层（" + " + ".join(ignored_parts) + "）"
    else:
        ignored_summary = "无图层被忽略"

    # R33 / A-69 / R42 / A-73：层数守恒断言（两条都必须成立）
    #   ① input == preserved + degraded + ignored + failed   （每个被遍历层都有处置）
    #   ② input == output(转换产出) + ignored                （被忽略层不凭空消失）
    input_layer_count = total_layers_scanned
    if include_hidden:
        output_layer_count = len(layers_info)
    else:
        output_layer_count = len(layers_info) - preview_layer_count
    skipped_layer_count = ignored_count
    conservation_holds = (input_layer_count == output_layer_count + skipped_layer_count)
    count_sum_holds = (
        preserved_count + degraded_count + ignored_count + failed_count == input_layer_count
    )
    if not conservation_holds:
        # 守恒被破坏属于硬错误：明确告警，绝不静默放行（供诊断与回归捕获）
        diagnostics_warnings.append(
            f"图层守恒被破坏: input={input_layer_count} "
            f"output={output_layer_count} skipped={skipped_layer_count}"
        )
    if not count_sum_holds:
        diagnostics_warnings.append(
            f"图层处置计数不闭合: input={input_layer_count} preserved={preserved_count} "
            f"degraded={degraded_count} ignored={ignored_count} failed={failed_count}"
        )
    layer_conservation = {
        "holds": conservation_holds,
        "count_sum_holds": count_sum_holds,
        "input_layer_count": input_layer_count,
        "output_layer_count": output_layer_count,
        "skipped_layer_count": skipped_layer_count,
        "preserved_count": preserved_count,
        "degraded_count": degraded_count,
        "ignored_count": ignored_count,
        "invariant": "input_layer_count == output_layer_count + skipped_layer_count",
        "count_invariant": "input_layer_count == preserved + degraded + ignored + failed",
    }
    # 可见且真正进入转换产出的层数：A-69 的绿色判定要求
    # preserved + degraded >= visible_emitted_count。
    visible_emitted_count = sum(
        1 for li in layers_info if li.visible and li.disposition in ("preserved", "degraded")
    )
    has_missing_risk = (
        missing_fonts_count > 0
        or unverifiable_fonts_count > 0
        or any(len(d.get("missing_glyphs", [])) > 0 for d in diagnosis_layers)
    )

    if failed_count > 0:
        risk_assessment = f"高风险：存在 {failed_count} 个图层解析失败，可能导致模板视觉缺失"
    elif missing_media_refs_count > 0:
        # R25 SA-2b（SA-4 问题 2 修复）：有应产出却生成失败的媒体资产时，
        # 整体诊断绝不允许宣称"完整成功/低风险"。
        risk_assessment = (
            f"高风险：存在 {missing_media_refs_count} 个图层的媒体资产 (Media/*.png) "
            f"生成失败，转换产物不完整（对应层已降级保留并逐条记录失败原因，"
            f"详见 severity='error' 的诊断条目），必须先修复环境（如安装 scipy）再导出"
        )
    elif missing_fonts_count > 0:
        risk_assessment = f"中风险：存在 {missing_fonts_count} 个文本图层缺少系统字体或字形，已自动推荐回退字体"
    elif unverifiable_fonts_count > 0:
        risk_assessment = (
            f"无法确定风险：存在 {unverifiable_fonts_count} 个文本图层字体环境不可验证"
            f"（当前环境无法检测字形覆盖度），缺失情况未知，需在 macOS 目标机复核"
        )
    elif non_bg_ignored > 0:
        # R33 / A-69：有「非底板」图层被忽略（隐藏/空/组等）时，绝不允许总结论
        # 写成「无风险 / 全部符合 / 低风险」。底板过滤属于正常预期，不在此升级。
        # 这一分支优先级高于 degraded 的「低风险」，确保大面积丢层时不被降级措辞掩盖。
        risk_assessment = (
            f"注意：{ignored_summary}；本次转换产出 {output_layer_count} 层，"
            f"被忽略层不参与转换（明细见诊断 layers）"
        )
    elif degraded_count > 0:
        risk_assessment = (
            f"低风险：{preserved_count} 个矢量文本保留，{degraded_count} 个复杂/装饰图层已降级为位图贴图"
        )
        if background_layers_count:
            risk_assessment += f"；{ignored_summary}，本次转换产出 {output_layer_count} 层"
    else:
        risk_assessment = "无风险：所有图层均符合 Motion 矢量规范，字体覆盖率 100%"

    diagnosis_report = {
        "summary": {
            "source_file": {
                "name": file_name,
                "path": file_path
            },
            "canvas": {
                "width": canvas_w,
                "height": canvas_h,
                "aspect_ratio": ratio_str,
                "resolution_spec": res_str
            },
            "total_layers": total_layers_scanned,
            "preserved_count": preserved_count,
            "degraded_count": degraded_count,
            "ignored_count": ignored_count,
            "failed_count": failed_count,
            "missing_fonts_count": missing_fonts_count,
            "unverifiable_fonts_count": unverifiable_fonts_count,
            # R25 SA-2b：机器可核查计数器（SA-4 问题 2/3 修复）
            #   missing_media_refs —— 应产出 Media/element_XX.png 却失败的层数，>0 即不完整；
            #   missing_glyph_layers —— 存在真实缺字形（□ 可见标记）的文本层数。
            "missing_media_refs": missing_media_refs_count,
            "missing_glyph_layers": missing_glyph_layers,
            # R33 / A-69 / A-70：忽略层分项 + 层数守恒 + 隐藏层清单。
            # 绿色「完整提取」的硬条件在 Swift ParseDiagnosticsState 中执行：
            # ignored_count == 0 且两条守恒均成立，单一条件不得判成功。
            "hidden_layer_count": hidden_layers_count,
            "hidden_layer_names": hidden_layer_names[:200],
            "background_layer_count": background_layers_count,
            "group_layer_count": group_layers_count,
            "empty_layer_count": empty_layers_count,
            "other_ignored_count": other_ignored_count,
            "preview_layer_count": preview_layer_count,
            "visible_emitted_count": visible_emitted_count,
            "ignored_summary": ignored_summary,
            "count_sum_holds": count_sum_holds,
            "include_hidden": include_hidden,
            "background_preview_present": background_preview is not None,
            "original_composite_path": original_composite_path,
            "has_missing_risk": has_missing_risk,
            "risk_assessment": risk_assessment,
            "layer_conservation": layer_conservation,
            "generated_at": datetime.now().isoformat()
        },
        "layers": diagnosis_layers,
        # R31 / A-59：字段语义说明（机器可读），避免下游继续误用旧字段
        "schema": {
            "font_info_fields": {
                "has_confirmed_missing_glyphs": "确证缺字：missing_chars 非空",
                "has_glyph_risk": "任何缺字风险，含环境不可验证（unverifiable）",
                "has_missing_glyphs": "DEPRECATED：等同于 has_glyph_risk，仅为向后兼容保留"
            }
        }
    }

    legacy_diagnostics = {
        "aspect_ratio": ratio_str,
        "resolution_spec": res_str,
        "width": canvas_w,
        "height": canvas_h,
        "total_scanned": total_layers_scanned,
        "text_layers_count": text_layers_count,
        "fallback_layers_count": fallback_layers_count,
        "fonts_detected_count": sum(1 for f in font_diagnostics if f["detection_status"] == "detected"),
        "fonts_fallback_count": sum(1 for f in font_diagnostics if f["detection_status"] == "missing_fallback"),
        "font_diagnostics": font_diagnostics,
        "fallback_layers": fallback_layers,
        "warnings": diagnostics_warnings,
        "notes": diagnostics_notes
    }

    return {
        "file_name": file_name,
        "file_path": file_path,
        "width": canvas_w,
        "height": canvas_h,
        "aspect_ratio": ratio_str,
        "aspect_ratio_str": ratio_str,
        "resolution_spec": res_str,
        "resolution_str": res_str,
        "total_layers_count": total_layers_scanned,
        "layer_count": len(layers_info),
        "input_layer_count": input_layer_count,
        "output_layer_count": output_layer_count,
        "skipped_layer_count": skipped_layer_count,
        "layer_conservation": layer_conservation,
        # R25 SA-2b：顶层快捷字段（与 diagnosis_report.summary 同源）
        "missing_media_refs": missing_media_refs_count,
        "missing_glyph_layers": missing_glyph_layers,
        # R33 / A-68：底板预览贴图（转换仍忽略底板，但画布需要它显示完整画面）
        "background_preview": background_preview,
        # R45：PSD 原始完整成图路径（供画布直观对比）
        "original_composite_path": original_composite_path,
        # R33 / A-69 / A-70：忽略层分项与隐藏层清单（顶层快捷字段）
        "hidden_layer_count": hidden_layers_count,
        "hidden_layer_names": hidden_layer_names[:200],
        "preview_layer_count": preview_layer_count,
        "ignored_summary": ignored_summary,
        "include_hidden": include_hidden,
        "layers": layers_info,
        "layer_tree": layer_tree_nodes,
        "diagnosis_report": diagnosis_report,
        "diagnostics": legacy_diagnostics
    }


def verify_layer_conservation(parsed_result: Dict[str, Any]) -> Dict[str, Any]:
    """
    R25 C-8：验证图层守恒硬约束。

        input_layer_count == output_layer_count + skipped_layer_count

    返回 {holds, input_layer_count, output_layer_count, skipped_layer_count, detail}。
    任何图层若既不在 output 也不在 skipped，此约束即被违反（说明有图层被静默丢弃）。
    """
    inp = parsed_result.get("input_layer_count", 0)
    out = parsed_result.get("output_layer_count", 0)
    skip = parsed_result.get("skipped_layer_count", 0)
    holds = (inp == out + skip)
    return {
        "holds": holds,
        "input_layer_count": inp,
        "output_layer_count": out,
        "skipped_layer_count": skip,
        "invariant": "input_layer_count == output_layer_count + skipped_layer_count",
        "detail": (
            "OK" if holds
            else f"守恒被破坏: input={inp} output={out} skipped={skip} (差 {inp - out - skip})"
        ),
    }


def generate_conversion_diagnosis_report(
    psd_path: str,
    extract_fallback_pngs: bool = False,
    png_output_dir: Optional[str] = None,
    extract_thumbnails: bool = True
) -> Dict[str, Any]:
    """
    生成 PSD 转档全项诊断报告。
    支持正常文件、复杂图层文件与损坏文件（高容错处理，绝不崩溃）。

    A-9 修正：`extract_thumbnails` 与 parse_psd_file 默认值保持一致（True）。
    此前固定 False 造成产品内部两条链路开关口径不一致——诊断链路不产切片，
    而画布链路产切片，同一份 PSD 在两条路径下图层可呈现性不同。
    """
    file_name = os.path.basename(psd_path) if psd_path else "unknown.psd"
    file_path = os.path.abspath(psd_path) if psd_path else ""

    try:
        parsed = parse_psd_file(
            psd_path,
            extract_fallback_pngs=extract_fallback_pngs,
            png_output_dir=png_output_dir,
            extract_thumbnails=extract_thumbnails
        )
        return parsed["diagnosis_report"]
    except PSDParseError as err:
        err_msg = str(err.original_error)
        return {
            "summary": {
                "source_file": {
                    "name": file_name,
                    "path": file_path
                },
                "canvas": {
                    "width": 0,
                    "height": 0,
                    "aspect_ratio": "未知画幅",
                    "resolution_spec": "损坏文件"
                },
                "total_layers": 0,
                "preserved_count": 0,
                "degraded_count": 0,
                "ignored_count": 0,
                "failed_count": 1,
                "missing_fonts_count": 0,
                "unverifiable_fonts_count": 0,
                "has_missing_risk": True,
                "risk_assessment": f"致命错误：源文件已损坏或格式非法无法解析 ({err_msg})",
                "generated_at": datetime.now().isoformat()
            },
            "layers": [
                {
                    "source_file": {
                        "name": file_name,
                        "path": file_path
                    },
                    "layer_index": None,
                    "layer_path": file_name,
                    "layer_name": file_name,
                    "layer_type": "unknown",
                    "disposition": "failed",
                    "reason": f"源文件解析失败: {err_msg}",
                    "font_status": None,
                    "missing_glyphs": [],
                    "fallback_font": None,
                    "fallback_png": None,
                    "unsupported_features": ["文件损坏 / 非法 PSD 结构"],
                    "error_details": err_msg,
                    "is_blocking": True
                }
            ]
        }
    except Exception as exc:
        err_msg = str(exc)
        return {
            "summary": {
                "source_file": {
                    "name": file_name,
                    "path": file_path
                },
                "canvas": {
                    "width": 0,
                    "height": 0,
                    "aspect_ratio": "未知画幅",
                    "resolution_spec": "解析异常"
                },
                "total_layers": 0,
                "preserved_count": 0,
                "degraded_count": 0,
                "ignored_count": 0,
                "failed_count": 1,
                "missing_fonts_count": 0,
                "unverifiable_fonts_count": 0,
                "has_missing_risk": True,
                "risk_assessment": f"系统异常：{err_msg}",
                "generated_at": datetime.now().isoformat()
            },
            "layers": [
                {
                    "source_file": {
                        "name": file_name,
                        "path": file_path
                    },
                    "layer_index": None,
                    "layer_path": file_name,
                    "layer_name": file_name,
                    "layer_type": "unknown",
                    "disposition": "failed",
                    "reason": f"未捕获解析异常: {err_msg}",
                    "font_status": None,
                    "missing_glyphs": [],
                    "fallback_font": None,
                    "fallback_png": None,
                    "unsupported_features": ["系统环境或 IO 异常"],
                    "error_details": err_msg,
                    "is_blocking": True
                }
            ]
        }
