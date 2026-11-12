"""PNG 智能拆分（P1）输出目录 → 设计器层模型。

读入 ``pngp1/v1`` 的「分层清单.json」与 ``layers/*.png``，产出与
``core.psd_parser.parse_psd_file`` **同构**的 dict，让既有画布 / 检查器 /
``MotionBuilder`` 链路直接复用，不动 ``MotiWriteBack`` 的五值写回口径。

口径差异（必须写进界面，别让用户以为能改字）：

* PSD 链路的 ``kind="type"`` 是**真文字层**，能取到文本、字体、字号、颜色。
* PNG 链路所有层都是 ``kind="fallback_png"``，TEXT 也只是**文字的图片**：
  能整体挪、能显隐、能改位置，**改不了文字内容**。

本模块只读分层目录，不写回源图、不碰 .moti。
"""

from __future__ import annotations

import io
import json
import os
from typing import Any, Dict, List, Optional, Tuple

from core.psd_parser import PSDLayerInfo

SCHEMA_PREFIX = "pngp1/"
MANIFEST_NAME = "分层清单.json"
BITMAP_TEXT_NOTICE = "文字层是位图：能挪不能改"


class PngSplitParseError(Exception):
    """分层目录不可读 / 清单损坏。带文件名，供界面出可读提示。"""

    def __init__(self, file_name: str, file_path: str, original_error: BaseException):
        self.file_name = file_name
        self.file_path = file_path
        self.original_error = original_error
        super().__init__(f"{file_name}: {original_error}")


def is_png_split_dir(path: str) -> bool:
    """目录里是否有 pngp1 的分层清单（用来和 PSD 目录区分）。"""
    return os.path.isfile(os.path.join(path, MANIFEST_NAME))


def _aspect_str(w: int, h: int) -> str:
    if not w or not h:
        return "未知"
    from math import gcd

    g = gcd(int(w), int(h)) or 1
    return "%d:%d" % (int(w) // g, int(h) // g)


def _thumbnail_bytes(png_path: str, size: Tuple[int, int] = (48, 48)) -> Optional[bytes]:
    """检查器列表用的小图标；失败不影响主流程。"""
    try:
        from PIL import Image

        with Image.open(png_path) as im:
            im = im.convert("RGBA")
            im.thumbnail(size, Image.LANCZOS)
            canvas = Image.new("RGBA", size, (0, 0, 0, 0))
            canvas.paste(im, ((size[0] - im.width) // 2, (size[1] - im.height) // 2), im)
            buf = io.BytesIO()
            canvas.save(buf, format="PNG", optimize=True)
            return buf.getvalue()
    except Exception:
        return None


def _layer_note(layer_class: str, notes: List[str]) -> List[str]:
    out = list(notes or [])
    if layer_class == "TEXT":
        out.insert(0, BITMAP_TEXT_NOTICE)
        out.insert(1, "不做 OCR，不重建矢量文字")
    elif layer_class == "BACKGROUND":
        out.insert(0, "背景底图：已按延展填色补洞")
    return out


def build_layer_models(doc: Dict[str, Any], split_dir: str) -> List[PSDLayerInfo]:
    """清单 → PSDLayerInfo 列表（顺序即叠放顺序：底 → 顶）。"""
    W = int(doc["width"])
    H = int(doc["height"])
    cx0, cy0 = W / 2.0, H / 2.0
    models: List[PSDLayerInfo] = []

    # 清单 layers[0] 是 BACKGROUND，其余按 seq 递增；PSD 链路 layers_info 也是底 → 顶
    for i, layer in enumerate(doc["layers"], start=1):
        rel = layer.get("file") or ""
        png_path = os.path.join(split_dir, rel) if rel else ""
        if png_path and not os.path.isfile(png_path):
            png_path = ""
        bbox = [int(v) for v in layer.get("bbox") or [0, 0, W, H]]
        left, top, right, bottom = bbox[0], bbox[1], bbox[2], bbox[3]
        motion_pos = (round((left + right) / 2.0 - cx0, 2),
                      round(cy0 - (top + bottom) / 2.0, 2))
        cls = layer.get("class", "ELEMENT")
        name = layer.get("name") or ("%s_%02d" % (cls, i))
        low = bool(layer.get("low_confidence"))
        notes = _layer_note(cls, layer.get("notes") or [])
        if low:
            notes.append("低置信度：可能拆错，请在面板里手动合并/拆分")
        if doc.get("object_fallback") and cls == "OBJECT":
            notes.append("主体为保底选择（不是高置信主体）")

        info = PSDLayerInfo(
            index=i,
            name=name,
            kind="fallback_png",
            text="",
            font_name="",
            font_size=0.0,
            tracking=0.0,
            psd_bbox=(left, top, right, bottom),
            motion_pos=motion_pos,
            visible=True,
            is_published=True,
            rotation=0.0,
            scale_x=1.0,
            scale_y=1.0,
            opacity=1.0,
            writing_direction="horizontal",
            fallback_png_path=png_path or None,
            fallback_png_info={
                "source": "png_split",
                "layer_class": cls,
                "confidence": layer.get("confidence"),
                "low_confidence": low,
                "pixels": layer.get("pixels"),
                "mean_color": layer.get("mean_color"),
            },
            font_info={
                "original_font": "",
                "detection_status": "not_applicable_bitmap",
                "fallback_font": "",
                "glyph_coverage": None,
                "has_missing_glyphs": False,
                "has_glyph_risk": False,
                "has_confirmed_missing_glyphs": False,
                "missing_chars": [],
            },
            diagnostic_notes=notes,
            layer_path=name,
            layer_type="bitmap_text" if cls == "TEXT" else "bitmap_layer",
            has_thumbnail=bool(png_path),
            thumbnail_bytes=_thumbnail_bytes(png_path) if png_path else None,
            disposition="degraded" if cls == "TEXT" else "preserved",
            disposition_reason=(BITMAP_TEXT_NOTICE if cls == "TEXT" else "PNG 分层位图"),
            effects=[],
        )
        # 位图文字永远不当真文字层写回：五值里的「文本」不发布
        if cls == "TEXT":
            info.published_channels["text"] = False
            info.published_channels["font"] = False
            info.published_channels["size"] = False
            info.published_channels["tracking"] = False
            info.published_channels["alignment"] = False
        models.append(info)
    return models


def regenerate_thumbnails(parsed: Dict[str, Any], template_dir: str) -> Optional[str]:
    """用源成品图重生成模板缩略图。

    ``build_template_atomic`` 在没有 PSD 对象时会写一张全透明的占位缩略图
    （large.png 只有几百字节），模板在 FCPX 列表里就是一块空白。P1 没有 PSD，
    只能用源成品图当预览——这也正是用户手上那张图，看列表最直观。
    """
    src = parsed.get("original_composite_path")
    if not src or not os.path.isfile(src):
        return None
    try:
        from PIL import Image

        from core.thumbnail import generate_thumbnails_from_image

        with Image.open(src) as im:
            generate_thumbnails_from_image(im.convert("RGBA"), template_dir)
        return template_dir
    except Exception:
        return None


def _diagnosis_report(doc: Dict[str, Any], layers: List[PSDLayerInfo]) -> Dict[str, Any]:
    cls_count: Dict[str, int] = {}
    for layer in doc["layers"]:
        cls_count[layer["class"]] = cls_count.get(layer["class"], 0) + 1
    low = [l["name"] for l in doc["layers"] if l.get("low_confidence")]
    warnings = list(doc.get("warnings") or [])
    for n in low:
        warnings.append("低置信度层：%s" % n)
    summary = {
        # 结构必须与 core.psd_parser 的诊断报告一致：界面/导出都按
        # summary["source_file"]["name"] 取文件名，给字符串会直接抛 AttributeError
        "source_file": {
            "name": os.path.basename(str(doc.get("source", "")).rstrip(os.sep)) or "png_split",
            "path": str(doc.get("source", "")),
        },
        "total_layers": len(layers),
        "canvas": {
            "width": int(doc.get("width") or 0),
            "height": int(doc.get("height") or 0),
            "aspect_ratio": _aspect_str(int(doc.get("width") or 0), int(doc.get("height") or 0)),
            "resolution_spec": "%d×%d" % (int(doc.get("width") or 0), int(doc.get("height") or 0)),
        },
        "preserved_count": sum(1 for l in layers if l.disposition == "preserved"),
        "degraded_count": sum(1 for l in layers if l.disposition == "degraded"),
        "ignored_count": 0,
        "failed_count": 0,
        "missing_fonts_count": 0,
        "has_missing_risk": False,
        "risk_assessment": "PNG 分层：%s；%s" % (
            "、".join("%s×%d" % (k, cls_count[k]) for k in sorted(cls_count)) or "无层",
            BITMAP_TEXT_NOTICE),
        "bitmap_text_notice": BITMAP_TEXT_NOTICE,
        "low_confidence_layers": low,
    }
    return {"summary": summary, "layers": [], "warnings": warnings, "notes": []}


def parse_png_split_dir(split_dir: str) -> Dict[str, Any]:
    """读入 P1 输出目录，返回与 ``parse_psd_file`` 同构的 dict。"""
    split_dir = os.path.abspath(split_dir)
    manifest_path = os.path.join(split_dir, MANIFEST_NAME)
    name = os.path.basename(split_dir.rstrip(os.sep))
    if not os.path.isfile(manifest_path):
        raise PngSplitParseError(name, split_dir,
                                 FileNotFoundError("目录里没有 %s" % MANIFEST_NAME))
    try:
        with open(manifest_path, encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as err:  # 损坏的清单要能被界面读出文件名 + 原因
        raise PngSplitParseError(name, manifest_path, err) from err

    if not str(doc.get("schema", "")).startswith(SCHEMA_PREFIX):
        raise PngSplitParseError(name, manifest_path,
                                 ValueError("schema 不是 %s*，实际 %r"
                                            % (SCHEMA_PREFIX, doc.get("schema"))))
    try:
        W, H = int(doc["width"]), int(doc["height"])
    except Exception as err:
        raise PngSplitParseError(name, manifest_path, err) from err

    layers = build_layer_models(doc, split_dir)
    if not layers:
        raise PngSplitParseError(name, manifest_path, ValueError("清单里没有任何图层"))

    bg = next((l for l in layers if l.fallback_png_info.get("layer_class") == "BACKGROUND"), None)
    background_preview = None
    if bg and bg.fallback_png_path:
        background_preview = {
            "path": bg.fallback_png_path,
            "bbox": list(bg.psd_bbox),
            "name": bg.name,
        }

    return {
        "file_name": name,
        "file_path": split_dir,
        "source_kind": "png_split",
        "schema": doc.get("schema"),
        "source_image": doc.get("source"),
        "source_sha256": doc.get("source_sha256"),
        "width": W,
        "height": H,
        "aspect_ratio": _aspect_str(W, H),
        "aspect_ratio_str": _aspect_str(W, H),
        "resolution_spec": "%d×%d" % (W, H),
        "resolution_str": "%d×%d" % (W, H),
        "total_layers_count": len(doc["layers"]),
        "layer_count": len(layers),
        "input_layer_count": len(doc["layers"]),
        "output_layer_count": len(layers),
        "skipped_layer_count": 0,
        "layer_conservation": {"conserved": True, "detail": "PNG 分层：清单层数全部转成层模型"},
        "missing_media_refs": 0,
        "missing_glyph_layers": [],
        "background_preview": background_preview,
        "original_composite_path": doc.get("source"),
        "hidden_layer_count": 0,
        "hidden_layer_names": [],
        "preview_layer_count": 0,
        "ignored_summary": {},
        "include_hidden": False,
        "text_editable": False,
        "bitmap_text_notice": BITMAP_TEXT_NOTICE,
        "low_confidence_layers": [l["name"] for l in doc["layers"] if l.get("low_confidence")],
        "layers": layers,
        "layer_tree": None,  # 走检查器平铺模式：PNG 链路的层本来就是扁平的
        "diagnosis_report": _diagnosis_report(doc, layers),
        "diagnostics": {},
    }
