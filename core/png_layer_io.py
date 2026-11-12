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
    elif layer_class == "BACKGROUND" and not out:
        # 背景补洞方式随源图模式不同（实体底延展补 / 透明底保持透明），
        # 清单 notes 已按实际分支写好；只有清单没写时才补一句中性说明，
        # 不在这里写死结论，避免和清单自身口径打架。
        out.append("背景底图")
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


# ── 层编辑：合并 / 拆分（像素工具，只做像素，不改业务判定）───────────────
#
# 设计器里用户手动纠错的两件事：
#   · 合并：算法把一件东西拆成了几层 → 多选后并回一层
#   · 拆分：一层里其实躺着几件不相连的东西 → 按连通块拆开
#
# 像素结果写到输出目录下的 ``_edit/``，**不覆盖**原 ``layers/*.png``，
# 原有分层随时可回退。调用方负责更新层模型与界面。

EDIT_SUBDIR = "_edit"
# 与 P1 的碎渣阈值同口径：小于它的连通块不单独成层
SPLIT_MIN_AREA_RATIO = 0.0008


def _open_layer_rgba(path: str) -> Optional[Any]:
    from PIL import Image

    try:
        with Image.open(path) as im:
            return im.convert("RGBA")
    except Exception:
        return None


def merge_layer_pngs(paths: List[str], bboxes: List[Tuple[int, int, int, int]],
                     canvas: Tuple[int, int], out_path: str) -> bool:
    """按叠放顺序（底层在前）把多层像素 alpha over 合成一张，写到 ``out_path``。

    ``bboxes[i]`` 是第 i 层在画布上的位置；层 PNG 可能是裁剪尺寸也可能是全画幅，
    两种都按 bbox 对齐贴回，不靠猜。
    """
    from PIL import Image

    W, H = int(canvas[0]), int(canvas[1])
    acc = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    used = False
    for path, bbox in zip(paths, bboxes):
        im = _open_layer_rgba(path)
        if im is None:
            continue
        if im.size == (W, H):
            layer_img = im
        else:
            x0, y0, x1, y1 = [int(v) for v in bbox]
            layer_img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            layer_img.paste(im, (x0, y0))
        acc = Image.alpha_composite(acc, layer_img)
        used = True
    if not used:
        return False

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    acc.save(out_path, optimize=True)
    return True


def _layer_full_rgba(path: str, bbox: Tuple[int, int, int, int],
                     canvas: Tuple[int, int]) -> Tuple[Optional[Any], Optional[Any]]:
    """把层图按 bbox 贴回整幅画布，返回 (整幅 RGBA 图, alpha 数组)；读不回来给 (None, None)。"""
    import numpy as np
    from PIL import Image

    im = _open_layer_rgba(path)
    if im is None:
        return None, None
    W, H = int(canvas[0]), int(canvas[1])
    if im.size == (W, H):
        full = im
    else:
        x0, y0 = int(bbox[0]), int(bbox[1])
        full = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        full.paste(im, (x0, y0))
    return full, np.asarray(full.getchannel("A"))


def _write_mask_png(full, mask_group, out_dir: str, name: str) -> Dict[str, Any]:
    """把整幅图里 mask_group 覆盖的像素单独存一张 png，返回路径/画布 bbox/像素数。"""
    import numpy as np
    from PIL import Image

    alpha = np.asarray(full.getchannel("A"))
    a = np.where(mask_group, alpha, 0).astype(np.uint8)
    rgb = np.asarray(full.convert("RGB"))
    arr = np.dstack([rgb, a])
    ys, xs = np.where(mask_group)
    bx = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]
    os.makedirs(out_dir, exist_ok=True)
    p = os.path.join(out_dir, name)
    Image.fromarray(arr).save(p, optimize=True)
    return {"path": p, "bbox": bx, "pixels": int(mask_group.sum())}


def split_layer_png(path: str, bbox: Tuple[int, int, int, int], canvas: Tuple[int, int],
                    out_dir: str) -> List[Dict[str, Any]]:
    """把一层按「不相连的连通块」拆成多层，返回每块的 png 路径与画布 bbox。

    只按像素连通性拆，不猜语义：不相连才拆，相连的不动。
    面积小于阈值的碎块并进最后一块，不制造几十个碎层。

    阈值随层自身像素自适应：既用画布 0.08% 的绝对下限（对齐 P1 碎渣口径），
    又不让它超过本层像素的 1/8 —— 否则本身就很小的层永远拆不开。
    """
    import numpy as np
    from scipy import ndimage

    W, H = int(canvas[0]), int(canvas[1])
    full, alpha = _layer_full_rgba(path, bbox, (W, H))
    if full is None:
        return []
    mask = alpha > 8
    if not mask.any():
        return []

    layer_pixels = int(mask.sum())
    min_area = max(12, min(int(SPLIT_MIN_AREA_RATIO * W * H), layer_pixels // 8))

    lab, n = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    sizes = np.bincount(lab.ravel())
    keep = [i for i in range(1, n + 1) if sizes[i] >= min_area]
    if len(keep) <= 1:
        return []  # 只有一块（或全是碎渣）:没什么可拆的

    groups: List[tuple] = []
    for cid in keep:
        groups.append((lab == cid))
    small = [i for i in range(1, n + 1) if sizes[i] < min_area]
    if small:
        tail = np.zeros_like(mask)
        for cid in small:
            tail |= (lab == cid)
        groups.append(tail)

    m = mask.sum()
    base = os.path.splitext(os.path.basename(path))[0]
    out_imgs = []
    for g in groups:
        ent = _write_mask_png(full, g, out_dir, "%s_拆%d.png" % (base, len(out_imgs) + 1))
        ent["ratio"] = float(ent["pixels"]) / float(max(1, m))
        out_imgs.append(ent)
    return out_imgs


def split_layer_png_region(path: str, bbox: Tuple[int, int, int, int],
                           canvas: Tuple[int, int], out_dir: str,
                           region: Tuple[int, int, int, int]
                           ) -> Tuple[List[Dict[str, Any]], Optional[Dict[str, Any]]]:
    """只把框选区域内的像素拆成独立层，框外留在原层。

    return (blocks, rest):
      blocks —— 框内每个「够大」的连接块各一条。同一连接块被框切开时，只取框内那部分，
                框外那部分回原层，所以拆前后像素并集不变。
      rest   —— 原层剩余（框外像素）；框内像素被整块拿走时为 None。

    框里只有碎渣或空的，返回 ([], None)，由上层如实拒绝。
    """
    import numpy as np
    from scipy import ndimage

    W, H = int(canvas[0]), int(canvas[1])
    full, alpha = _layer_full_rgba(path, bbox, (W, H))
    if full is None:
        return [], None
    mask = alpha > 8
    if not mask.any():
        return [], None

    rx0, ry0, rx1, ry1 = (int(region[0]), int(region[1]), int(region[2]), int(region[3]))
    rx0 = max(0, min(W, rx0)); rx1 = max(0, min(W, rx1))
    ry0 = max(0, min(H, ry0)); ry1 = max(0, min(H, ry1))
    if rx1 <= rx0 or ry1 <= ry0:
        return [], None

    in_region = np.zeros_like(mask)
    in_region[ry0:ry1, rx0:rx1] = True
    picked = mask & in_region
    if not picked.any():
        return [], None

    layer_pixels = int(mask.sum())
    min_area = max(12, min(int(SPLIT_MIN_AREA_RATIO * W * H), layer_pixels // 8))

    lab, _n = ndimage.label(mask, structure=np.ones((3, 3), dtype=np.uint8))
    takeable = []
    for cid in np.unique(lab[picked]):
        if cid == 0:
            continue
        part = (lab == cid) & in_region
        if int(part.sum()) >= min_area:
            takeable.append(part)
    if not takeable:
        return [], None

    base = os.path.splitext(os.path.basename(path))[0]
    blocks = []
    for g in takeable:
        ent = _write_mask_png(full, g, out_dir, "%s_框拆%d.png" % (base, len(blocks) + 1))
        ent["ratio"] = float(ent["pixels"]) / float(max(1, layer_pixels))
        blocks.append(ent)

    taken = np.zeros_like(mask)
    for g in takeable:
        taken |= g
    rest_mask = mask & ~taken
    rest = None
    if rest_mask.any():
        rest = _write_mask_png(full, rest_mask, out_dir, base + "_余.png")
    return blocks, rest


# ── 层编辑入口：合并 / 拆分（给设计器面板调用）───────────────────────────
#
# 只对 PNG 分层链路（source_kind == "png_split"）开放。返回**全新的层模型列表**，
# 由调用方整体替换后重刷画布与面板；失败返回 (None, 原因)，界面据此提示。

def _relayer(layers: List[PSDLayerInfo], canvas: Tuple[int, int]) -> List[PSDLayerInfo]:
    """重排 1-based 索引、重算居中位移、按类别恢复发布通道。整表复用。"""
    W, H = int(canvas[0]), int(canvas[1])
    cx0, cy0 = W / 2.0, H / 2.0
    for i, info in enumerate(layers, start=1):
        info.index = i
        left, top, right, bottom = info.psd_bbox
        info.motion_pos = (round((left + right) / 2.0 - cx0, 2),
                           round(cy0 - (top + bottom) / 2.0, 2))
        if info.kind == "fallback_png" and info.layer_type in ("bitmap_text", "bitmap_layer"):
            is_text = info.layer_type == "bitmap_text"
            for ch in ("text", "font", "size", "tracking", "alignment"):
                info.published_channels[ch] = not is_text
    return layers


def _edit_dir(split_dir: str) -> str:
    d = os.path.join(split_dir, EDIT_SUBDIR)
    os.makedirs(d, exist_ok=True)
    return d


def _png_bbox(info: PSDLayerInfo) -> Tuple[int, int, int, int]:
    return tuple(int(v) for v in (info.psd_bbox or (0, 0, 0, 0)))


def _model_from(info: PSDLayerInfo, png_path: str, bbox: Tuple[int, int, int, int],
                name: str, notes: List[str], layer_type: str) -> PSDLayerInfo:
    """以既有层模型为模板造一层新的位图层（只改像素来源相关字段）。"""
    import copy

    new = copy.copy(info)
    new.name = name
    new.psd_bbox = tuple(int(v) for v in bbox)
    new.fallback_png_path = png_path
    new.layer_path = name
    new.diagnostic_notes = list(notes)
    new.layer_type = layer_type
    new.thumbnail_bytes = _thumbnail_bytes(png_path) if png_path else None
    new.has_thumbnail = bool(new.thumbnail_bytes)
    fi = dict(new.fallback_png_info or {})
    fi.update({"source": "png_split_edit", "layer_class": info.fallback_png_info.get("layer_class")
               if info.fallback_png_info else None})
    new.fallback_png_info = fi
    new.disposition = "degraded" if layer_type == "bitmap_text" else "preserved"
    new.disposition_reason = BITMAP_TEXT_NOTICE if layer_type == "bitmap_text" else "PNG 分层位图（手动编辑后）"
    return new


def merge_layer_models(parsed: Dict[str, Any], split_dir: str,
                      indexes: List[int]) -> Tuple[Optional[List[PSDLayerInfo]], str]:
    """把 indexes 指定的层合并成一层（按叠放顺序 alpha over），返回新层模型表。

    背景层不允许参与合并：背景的洞是分层的语义基础，合进去就说不清了。
    """
    W, H = int(parsed["width"]), int(parsed["height"])
    layers = list(parsed["layers"])
    idxs = sorted(set(int(i) for i in indexes))
    if len(idxs) < 2:
        return None, "至少选两层才能合并"
    by_index = {l.index: l for l in layers}
    missing = [i for i in idxs if i not in by_index]
    if missing:
        return None, "选中的层已不存在（第 %s 层）" % ",".join(str(i) for i in missing)

    picked = [by_index[i] for i in idxs]  # 已按叠放顺序（下 → 上）
    bad = [p.name for p in picked
           if (p.layer_type not in ("bitmap_text", "bitmap_layer")) or not p.fallback_png_path]
    if bad:
        return None, "这几层没有位图可取，不能合并：%s" % "、".join(bad)
    if any("BACKGROUND" == ((p.fallback_png_info or {}).get("layer_class") or "") for p in picked):
        return None, "背景层不能参与合并（背景的洞是分层的基础）"

    base = picked[0]
    classes = [((p.fallback_png_info or {}).get("layer_class") or "ELEMENT") for p in picked]
    cls = "OBJECT" if "OBJECT" in classes else max(zip(classes, picked), key=lambda kv: int(
        (kv[1].fallback_png_info or {}).get("pixels") or 0))[0]

    edit = _edit_dir(split_dir)
    seq = len([f for f in os.listdir(edit) if f.startswith("合并")]) + 1
    out_name = "合并_%s_%02d" % (cls, seq)
    out_path = os.path.join(edit, out_name + ".png")

    ok = merge_layer_pngs([p.fallback_png_path for p in picked],
                          [_png_bbox(p) for p in picked], (W, H), out_path)
    if not ok:
        return None, "合并失败：层图读不出来"

    box = (min(_png_bbox(p)[0] for p in picked), min(_png_bbox(p)[1] for p in picked),
           max(_png_bbox(p)[2] for p in picked), max(_png_bbox(p)[3] for p in picked))
    notes = ["手动合并：%s 共 %d 层" % ("、".join(p.name for p in picked), len(picked))]
    layer_type = "bitmap_text" if cls == "TEXT" else "bitmap_layer"
    merged = _model_from(base, out_path, box, out_name, notes, layer_type)
    fi = dict(merged.fallback_png_info or {})
    fi.update({"layer_class": cls, "low_confidence": False,
               "pixels": int(sum(int((p.fallback_png_info or {}).get("pixels") or 0) for p in picked))})
    merged.fallback_png_info = fi

    # 合并层落在最底层的位置（保持叠放稳定），其余层原序保留
    first = idxs[0]
    rest = [l for i, l in enumerate(layers, start=1) if i not in idxs]
    pos = sum(1 for l in layers[:layers.index(by_index[first])] if l.index not in idxs)
    rest.insert(pos, merged)
    return _relayer(rest, (W, H)), "已合并 %d 层 → %s" % (len(picked), out_name)


def split_layer_model(parsed: Dict[str, Any], split_dir: str, index: int,
                     region: Optional[Tuple[int, int, int, int]] = None
                     ) -> Tuple[Optional[List[PSDLayerInfo]], str]:
    """把一层拆成多层，返回新层模型表。

    region=None：按「不相连的连通块」全层拆，连在一起的不会动，只有一块就如实拒绝。
    region=(x0,y0,x1,y1)（画布像素坐标）：只拆框内像素，框外留在原层（原名原位）。
    同一块被框切成两半时，框内那半单独成层，框外那半回原层 —— 拆前后像素总量不变。
    """
    W, H = int(parsed["width"]), int(parsed["height"])
    layers = list(parsed["layers"])
    target = next((l for l in layers if l.index == int(index)), None)
    if target is None:
        return None, "选中的层已不存在"
    if not target.fallback_png_path:
        return None, "这层没有位图可取，不能拆分"
    if (target.fallback_png_info or {}).get("layer_class") == "BACKGROUND":
        return None, "背景层不拆（拆开没有意义）"

    orig_cls = (target.fallback_png_info or {}).get("layer_class") or "ELEMENT"
    layer_type = "bitmap_text" if orig_cls == "TEXT" else "bitmap_layer"
    edit = _edit_dir(split_dir)

    if region is None:
        blocks = split_layer_png(target.fallback_png_path, _png_bbox(target), (W, H), edit)
        if not blocks:
            return None, "这层是连成一片的，拆不开（没有不相连的块）"
        remain = None
        remain_note = None
        msg_ok = "已把 %s 拆成 %d 层" % (target.name, len(blocks))
    else:
        blocks, remain = split_layer_png_region(
            target.fallback_png_path, _png_bbox(target), (W, H), edit, region)
        if not blocks:
            return None, "框里没有可拆的东西（空，或只有碎渣）"
        remain_note = "框选拆出 %d 块，框外留在这层" % len(blocks)
        msg_ok = "已从 %s 框选出 %d 块" % (target.name, len(blocks))
        if remain is None:
            msg_ok += "（这层整块都被框走了，原层已移除）"

    made: List[PSDLayerInfo] = []
    for n, b in enumerate(blocks, start=1):
        name = "%s_%s%d" % (target.name, "框拆" if region is not None else "拆", n)
        notes = ["手动拆分自 %s（共 %d 块）" % (target.name, len(blocks))]
        m = _model_from(target, b["path"], tuple(b["bbox"]), name, notes, layer_type)
        fi = dict(m.fallback_png_info or {})
        fi.update({"layer_class": orig_cls, "pixels": b["pixels"], "low_confidence": False})
        m.fallback_png_info = fi
        made.append(m)

    pos = layers.index(target)
    if region is None or remain is None:
        rest = layers[:pos] + made + layers[pos + 1:]
    else:
        # 原层改成「框外剩余」：名字不变，用户在面板里看到还是这层，只是少了一块
        keep = _model_from(target, remain["path"], tuple(remain["bbox"]), target.name,
                           list(target.diagnostic_notes or []) + [remain_note], layer_type)
        fi = dict(keep.fallback_png_info or {})
        fi.update({"layer_class": orig_cls, "pixels": remain["pixels"]})
        keep.fallback_png_info = fi
        rest = layers[:pos] + [keep] + made + layers[pos + 1:]
    return _relayer(rest, (W, H)), msg_ok


# ── 写回：让合并/拆分永久生效 ────────────────────────────────────────────────
#
# 上面的合并/拆分只改内存层表、像素落到 ``_edit/``，关掉重开就回到原样。
# 用户要「永久生效、相当于 FCPX 的模板」，所以这里把新层表落到 ``layers/``
# 并重写清单，下次打开就是编辑后的样子。
#
# 外置卷不允许 rm，旧文件一律同卷改名进备份目录，不删。

PERSIST_BACKUP_DIR = "_backup_edit"


def _safe_stem(name: str) -> str:
    """层名 → 安全文件名主干：去空格/全角/emoji/标点，只留中英文数字与连字符。"""
    import re as _re

    s = _re.sub(r"[^\w\u4e00-\u9fff\-]+", "_", (name or "").strip())
    return (s.strip("_") or "layer")[:80]


def _png_stats(path: str) -> Tuple[int, int, str]:
    """实测层的可见像素数、alpha 总和、可见区平均色，供清单记录。"""
    import numpy as np

    im = _open_layer_rgba(path)
    if im is None:
        return 0, 0, "#000000"
    a = np.asarray(im)
    alpha = a[:, :, 3]
    vis = alpha > 8
    px = int(vis.sum())
    asum = int(alpha.sum())
    if px:
        mc = a[:, :, :3][vis].mean(axis=0)
        mean = "#%02X%02X%02X" % tuple(int(round(float(v))) for v in mc)
    else:
        mean = "#000000"
    return px, asum, mean


def _layer_full(info: PSDLayerInfo, W: int, H: int):
    """层图统一成整幅，便于叠图。"""
    from PIL import Image

    if not info.fallback_png_path:
        return None
    im = _open_layer_rgba(info.fallback_png_path)
    if im is None:
        return None
    if im.size != (W, H):
        full = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        bb = _png_bbox(info)
        full.paste(im, (int(bb[0]), int(bb[1])))
        return full
    return im


def _repaint_previews(split_dir: str, layers: List[PSDLayerInfo], W: int, H: int) -> Dict[str, str]:
    """层结构变了，预览图必须跟着重画，否则预览和层对不上。"""
    from PIL import Image

    order = {"BACKGROUND": 0, "OBJECT": 1, "ELEMENT": 2, "TEXT": 3}
    scale = min(1.0, 720.0 / max(W, H))
    tw, th = max(1, int(round(W * scale))), max(1, int(round(H * scale)))

    def cls_of(l: PSDLayerInfo) -> str:
        return (l.fallback_png_info or {}).get("layer_class") or "ELEMENT"

    comp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for l in sorted(layers, key=lambda x: order.get(cls_of(x), 9)):
        im = _layer_full(l, W, H)
        if im is not None:
            comp = Image.alpha_composite(comp, im)
    comp.resize((tw, th), Image.LANCZOS).save(os.path.join(split_dir, "预览_重合成.png"))

    bg = next((l for l in layers if cls_of(l) == "BACKGROUND"), None)
    if bg is not None:
        im = _layer_full(bg, W, H)
        if im is not None:
            im.resize((tw, th), Image.LANCZOS).save(os.path.join(split_dir, "预览_背景补洞.png"))

    cell = 16
    n = min(12, len(layers))
    cols = min(4, max(1, n))
    rows = int((n + cols - 1) // cols)
    board = Image.new("RGBA", (tw * cols, th * rows), (24, 26, 32, 255))
    for y in range(0, th * rows, cell):
        for x in range(0, tw * cols, cell):
            if (x // cell + y // cell) % 2 == 0:
                board.paste((38, 41, 49, 255), (x, y, x + cell, y + cell))
    for idx, l in enumerate(layers[:n]):
        im = _layer_full(l, W, H)
        if im is None:
            continue
        board.alpha_composite(im.resize((tw, th), Image.LANCZOS),
                              ((idx % cols) * tw, (idx // cols) * th))
    board.convert("RGB").save(os.path.join(split_dir, "预览_分层检查板.png"))

    return {"background_filled": "预览_背景补洞.png",
            "checkerboard": "预览_分层检查板.png",
            "recomposite": "预览_重合成.png"}


def persist_layer_edit(parsed: Dict[str, Any], split_dir: str,
                       layers: List[PSDLayerInfo]
                       ) -> Tuple[Optional[List[PSDLayerInfo]], str]:
    """把编辑后的层表写回分层目录，永久生效。

    1. 先把旧 ``layers/*.png`` 与清单整体备份到 ``_backup_edit/<时间戳>/``；
    2. 各层落盘到 ``layers/``，层模型路径回填为新文件；
    3. 不再被引用的旧 png 同卷改名进备份的 ``removed/``（外置卷不许删）；
    4. 重写清单（层序、像素、类别、体积、编辑次数），并重画预览图。

    任何一步失败都返回 ``(None, 原因)``，调用方据此保持界面不变。
    """
    import shutil
    import time

    if not layers:
        return None, "没有层可写回"
    manifest_path = os.path.join(split_dir, MANIFEST_NAME)
    if not os.path.exists(manifest_path):
        return None, "找不到分层清单，不能写回（这个目录不是 PNG 分层目录）"
    layers_dir = os.path.join(split_dir, "layers")
    os.makedirs(layers_dir, exist_ok=True)

    ts = time.strftime("%Y%m%d_%H%M%S")
    bak = os.path.join(split_dir, PERSIST_BACKUP_DIR, ts)
    bak_layers = os.path.join(bak, "layers")
    removed = os.path.join(bak, "removed")
    try:
        os.makedirs(bak_layers, exist_ok=True)
        os.makedirs(removed, exist_ok=True)
        shutil.copy2(manifest_path, os.path.join(bak, MANIFEST_NAME))
        for fn in sorted(os.listdir(layers_dir)):
            if fn.lower().endswith(".png"):
                shutil.copy2(os.path.join(layers_dir, fn), os.path.join(bak_layers, fn))
    except Exception as e:
        return None, "备份失败，未做任何改动：%s" % e

    # 落盘：同名先占用，重名自动加序号，避免把两层写成同一个文件
    used = set()
    new_layers: List[PSDLayerInfo] = []
    for info in layers:
        src = info.fallback_png_path
        if not src or not os.path.exists(src):
            return None, "层「%s」没有像素文件，写回中止（磁盘未变）" % info.name
        stem = _safe_stem(info.name)
        fn = stem + ".png"
        k = 2
        while fn in used:
            fn = "%s_%d.png" % (stem, k)
            k += 1
        used.add(fn)
        dst = os.path.join(layers_dir, fn)
        if os.path.abspath(src) != os.path.abspath(dst):
            try:
                shutil.copy2(src, dst)
            except Exception as e:
                return None, "写入 %s 失败：%s" % (fn, e)
        info.fallback_png_path = dst
        new_layers.append(info)

    for fn in sorted(os.listdir(layers_dir)):
        if not fn.lower().endswith(".png") or fn in used:
            continue
        try:
            shutil.move(os.path.join(layers_dir, fn), os.path.join(removed, fn))
        except Exception:
            pass  # 移不动不阻断：清单已不再引用它

    try:
        with open(manifest_path, encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as e:
        return None, "分层清单读不出来：%s" % e

    rows = []
    for i, info in enumerate(new_layers, start=1):
        fi = info.fallback_png_info or {}
        path = info.fallback_png_path
        px, asum, mean = _png_stats(path)
        rows.append({
            "class": fi.get("layer_class") or "ELEMENT",
            "seq": i,
            "name": info.name,
            "file": "layers/" + os.path.basename(path),
            "bbox": [int(v) for v in _png_bbox(info)],
            "pixels": px,
            "alpha_sum": asum,
            "confidence": fi.get("confidence", 1.0),
            "low_confidence": bool(fi.get("low_confidence", False)),
            "mean_color": mean,
            "notes": list(info.diagnostic_notes or []),
        })
    doc["layers"] = rows
    doc["layer_count"] = len(rows)
    doc["classes_present"] = sorted({r["class"] for r in rows})
    total = sum(os.path.getsize(os.path.join(split_dir, r["file"])) for r in rows)
    src_bytes = int(doc.get("source_bytes") or 0)
    doc["sizes"] = {"layers_bytes": total,
                    "layer_total_mb": round(total / 1048576.0, 2),
                    "ratio_to_source": (round(total / float(src_bytes), 2) if src_bytes else None)}
    hist = doc.get("edited") if isinstance(doc.get("edited"), dict) else {}
    doc["edited"] = {"edited": True, "last_edit": ts,
                     "edit_count": int(hist.get("edit_count", 0)) + 1}
    pv = dict(doc.get("previews") or {})
    pv.update(_repaint_previews(split_dir, new_layers, int(doc["width"]), int(doc["height"])))
    pv.setdefault("source", "预览_原图.png")
    doc["previews"] = pv

    try:
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
    except Exception as e:
        return None, "写清单失败：%s" % e

    return new_layers, "已写回分层目录（备份在 %s/）" % PERSIST_BACKUP_DIR
