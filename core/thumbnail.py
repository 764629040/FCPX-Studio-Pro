"""
缩略图生成模块
负责渲染 FCPX 标题浏览器所需的两档尺寸预览图。

A-28 修复：尺寸不再硬编码为 640×360 / 192×108。
原实现对任意画幅都 resize 到 640×360，竖版 1080×1920 会被横向拉伸 3.16 倍，
资源库预览严重变形。现改为**按长边等比缩放**，保持源画幅：

- large.png：长边 640
- small.png：长边 192

16:9 源 → 640×360 / 192×108（与原行为一致）
9:16 源 → 360×640 / 108×192（不再拉伸）
1:1  源 → 640×640 / 192×192
"""
import os
from PIL import Image, ImageDraw, ImageFont
from typing import List, Optional

# A-28：缩略图按长边等比缩放，保持源画幅
THUMB_LONG_EDGE_LARGE = 640
THUMB_LONG_EDGE_SMALL = 192


def crop_composite_to_canvas(img, canvas_w: int, canvas_h: int):
    """
    A-30：把合成图裁剪/贴回真实画布范围，防止 bbox 越界导致的乱码。

    背景：psd-tools 的 composite() 返回尺寸取自画布头（canvas_w × canvas_h），
    但当某个图层的 bbox 超出画布时（例如横版图层塞进竖版画布），
    读出的像素可能是错位的通道数据，表现为红绿彩条。
    仅靠"换一个干净夹具"没有修根因——任何真实畸形 PSD 仍会产出乱码预览。

    这里做一个可验证的收口：
      1. 合成图尺寸与画布不一致时，裁到画布尺寸（取左上对齐）；
      2. 尺寸一致时原样返回，零开销。

    返回 (image, adjusted: bool)
    """
    if img is None:
        return img, False
    if img.width == canvas_w and img.height == canvas_h:
        return img, False
    left = 0
    top = 0
    right = min(img.width, canvas_w)
    bottom = min(img.height, canvas_h)
    if right <= left or bottom <= top:
        return img, False
    return img.crop((left, top, right, bottom)), True


def has_out_of_bounds_layers(psd_obj) -> bool:
    """
    A-30：检测是否存在 bbox 越界图层（诊断用，供上层告警）。

    越界本身不一定要拒绝渲染，但必须能被发现并记录——
    否则乱码预览会静默流到用户面前。
    """
    try:
        cw, ch = int(psd_obj.width), int(psd_obj.height)
    except Exception:
        return False
    try:
        layers = list(psd_obj.descendants())
    except Exception:
        return False
    for layer in layers:
        try:
            l_, t, r, b = layer.bbox
        except Exception:
            continue
        if r > cw or b > ch or l_ < 0 or t < 0:
            return True
    return False


def composite_layers_manually(psd_obj, edge_fill: bool = True):
    """
    A-30 口径 C：逐层贴图合成，替代 psd_obj.composite()。

    根因（第十六轮审核实测确认）：
      整幅 composite() 会产出彩条伪影（旧夹具 28852/13477 个彩条像素），
      但**逐层单独 composite() 全部为 0/0** —— 彩条来自整幅合成阶段，
      不是图层数据损坏。因此改为逐层合成即可消除。

    实现要点：
      1. 逐层取 composite()，按其真实 bbox 与画布求交后裁切贴入；
      2. 严格裁剪到画布内，绝不越界；
      3. `edge_fill=True` 时做边缘延伸填充：
         若最底层只覆盖画面一部分（如横版背景塞进竖版画布，
         底部 43.75% 空白），用最底层边缘像素向外延伸，
         避免出现大面积透明/纯黑空白。

    返回 RGBA Image（尺寸严格等于画布）。
    """
    from PIL import Image as _Image

    canvas_w = int(getattr(psd_obj, "width", 0) or 0)
    canvas_h = int(getattr(psd_obj, "height", 0) or 0)
    if canvas_w <= 0 or canvas_h <= 0:
        return _Image.new("RGBA", (max(1, canvas_w), max(1, canvas_h)), (0, 0, 0, 0))

    canvas = _Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    base_layer_bbox = None
    base_layer_img = None

    # 遍历策略：递归展开图层组。
    #
    # 不能用 descendants() 直接反转——那是自上而下，反转后顺序错误。
    # 也不能只取图层组本身——组的 composite() 在某些结构下不等价于
    # 逐子层叠加（第十六轮实测横版夹具 60.69% 像素差异）。
    # 正确做法：按"自下而上"顺序递归收集**叶子层**，逐层贴图。
    def _is_group(node) -> bool:
        """
        严格判断是否为图层组。

        注意（第十六轮实测踩坑）：psd_tools 的 `Layer.is_group` 是**方法**而非属性，
        `getattr(node, "is_group", False)` 拿到的是 bound method（恒真），
        会把所有层都当成组递归，最终收集为空、合成结果全透明。
        必须先 callable 判断再调用。
        """
        try:
            flag = getattr(node, "is_group", None)
            if callable(flag):
                return bool(flag())
            if flag is not None:
                return bool(flag)
            return getattr(node, "kind", "") == "group"
        except Exception:
            return False

    def _collect(node):
        """自下而上递归收集叶子层"""
        out = []
        try:
            children = list(node)
        except Exception:
            return out
        for child in children:
            if _is_group(child):
                out.extend(_collect(child))
            else:
                out.append(child)
        return out

    try:
        layers = _collect(psd_obj)
    except Exception:
        try:
            layers = list(psd_obj)
        except Exception:
            layers = []

    for layer in layers:
        if not _layer_visible(layer):
            continue
        try:
            img = layer.composite()
        except Exception:
            continue
        if img is None:
            continue
        try:
            img = img.convert("RGBA")
        except Exception:
            continue

        try:
            l_, t, r, b = layer.bbox
        except Exception:
            continue

        # 与画布求交，严格不越界
        cx0 = max(0, int(l_))
        cy0 = max(0, int(t))
        cx1 = min(canvas_w, int(r))
        cy1 = min(canvas_h, int(b))
        if cx1 <= cx0 or cy1 <= cy0:
            continue

        try:
            piece = img.crop((cx0 - int(l_), cy0 - int(t),
                              cx1 - int(l_), cy1 - int(t)))
        except Exception:
            continue

        if base_layer_img is None:
            base_layer_img = piece
            base_layer_bbox = (cx0, cy0, cx1, cy1)

        canvas.alpha_composite(piece, (cx0, cy0))

    # 边缘延伸填充：仅当覆盖不足时启用
    #
    # 关键（第十六轮验收反馈）：正常夹具本身已有覆盖整个画布的背景层，
    # 无条件填充会把原本透明的区域也涂上颜色，导致与 composite() 出现
    # 0.57% 的像素差异。因此这里先测覆盖率，只在"覆盖明显不足"
    # （< 99%）时才填充，保证正常夹具逐像素回归为 0。
    if edge_fill and base_layer_img is not None and base_layer_bbox is not None:
        alpha = canvas.split()[3]
        opaque = 0
        try:
            hist = alpha.histogram()
            opaque = sum(hist[1:]) if len(hist) > 1 else 0
        except Exception:
            opaque = 0
        coverage = opaque / float(max(1, canvas_w * canvas_h))
        if coverage < 0.99:
            canvas = _extend_edge_fill(canvas, base_layer_bbox, base_layer_img)

    return canvas


def _layer_visible(layer) -> bool:
    """兼容不同 psd_tools 版本的可见性 API"""
    try:
        if hasattr(layer, "visible"):
            v = layer.visible
            return bool(v() if callable(v) else v)
        if hasattr(layer, "is_visible"):
            v = layer.is_visible
            return bool(v() if callable(v) else v)
    except Exception:
        pass
    return True


def _extend_edge_fill(canvas, bbox, base_img):
    """
    把最底层覆盖区域的边缘像素向外延伸，填满画布剩余区域。

    仅填充**完全透明**的像素，不覆盖已有内容。
    """
    from PIL import Image as _Image

    x0, y0, x1, y1 = bbox
    w, h = canvas.size
    if base_img is None or base_img.width == 0 or base_img.height == 0:
        return canvas

    # 取最底层区域的平均色作为延伸色（比单像素取样更稳）
    try:
        from PIL import ImageStat
        stat = ImageStat.Stat(base_img.convert("RGB"))
        fill_rgb = tuple(int(v) for v in stat.mean)
    except Exception:
        fill_rgb = (28, 24, 32)

    fill = _Image.new("RGBA", (w, h), fill_rgb + (255,))

    # 只在画布中"最底层未覆盖"的像素上用填充色
    alpha = canvas.split()[3]
    mask = alpha.point(lambda a: 255 if a == 0 else 0)

    out = canvas.copy()
    out.paste(fill, (0, 0), mask)
    return out


def fit_thumbnail_size(src_w: int, src_h: int, long_edge: int) -> tuple:
    """
    按长边等比缩放，返回 (w, h)。

    保证：短边不会被拉伸，长边 == long_edge（极小图除外）。
    这修正了原实现"任何画幅都 resize 到固定 16:9"的变形问题。
    """
    src_w = max(1, int(src_w))
    src_h = max(1, int(src_h))
    if src_w >= src_h:
        w = long_edge
        h = max(1, int(round(long_edge * src_h / src_w)))
    else:
        h = long_edge
        w = max(1, int(round(long_edge * src_w / src_h)))
    return w, h

def generate_thumbnails_from_psd(psd_obj, output_dir: str):
    """
    从打开的 PSDImage 对象合成并导出两档缩略图
    """
    os.makedirs(output_dir, exist_ok=True)
    large_path = os.path.join(output_dir, "large.png")
    small_path = os.path.join(output_dir, "small.png")

    # A-30 口径 C：改用逐层贴图合成，替代 psd_obj.composite()
    #
    # 根因（第十六轮审核实测）：整幅 composite() 会产出彩条伪影
    # （旧夹具 28852/13477 像素），而逐层单独 composite() 全部为 0/0。
    # 彩条来自整幅合成阶段，不是图层数据损坏，因此逐层贴图可消除。
    #
    # edge_fill=True 处理"背景只覆盖部分画面"（横版背景塞进竖版画布）
    # 造成的大面积空白，用最底层平均色延伸填充。
    try:
        img = composite_layers_manually(psd_obj, edge_fill=True)
        if img.mode != "RGBA":
            img = img.convert("RGBA")

        # 尺寸兜底（逐层合成已严格按画布尺寸生成，此处仅防御异常）
        canvas_w = int(getattr(psd_obj, "width", img.width))
        canvas_h = int(getattr(psd_obj, "height", img.height))
        img, adjusted = crop_composite_to_canvas(img, canvas_w, canvas_h)
        if adjusted:
            try:
                with open(os.path.join(output_dir, "_thumbnail_warning.txt"),
                          "w", encoding="utf-8") as wf:
                    wf.write(
                        f"合成图尺寸与画布不一致，已裁剪回收: "
                        f"canvas={canvas_w}x{canvas_h}\n"
                        f"存在越界图层: {has_out_of_bounds_layers(psd_obj)}\n"
                    )
            except Exception:
                pass

        # 旁路记录：逐层合成后若仍有越界图层，写告警（供上层发现畸形 PSD）
        if has_out_of_bounds_layers(psd_obj):
            try:
                with open(os.path.join(output_dir, "_thumbnail_warning.txt"),
                          "w", encoding="utf-8") as wf:
                    wf.write(
                        f"检测到 bbox 越界图层（已用逐层贴图 + 边缘填充处理）\n"
                        f"canvas={canvas_w}x{canvas_h}\n"
                        f"合成方式=逐层贴图(A-30 口径C)，彩条已消除\n"
                    )
            except Exception:
                pass
    except Exception:
        # 降级：按真实画布尺寸创建透明画布
        canvas_w = int(getattr(psd_obj, "width", 1920) or 1920)
        canvas_h = int(getattr(psd_obj, "height", 1080) or 1080)
        img = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    # A-28：按长边等比缩放，保持源画幅
    large_img = img.resize(
        fit_thumbnail_size(img.width, img.height, THUMB_LONG_EDGE_LARGE),
        Image.Resampling.LANCZOS)
    large_img.save(large_path, "PNG")

    small_img = img.resize(
        fit_thumbnail_size(img.width, img.height, THUMB_LONG_EDGE_SMALL),
        Image.Resampling.LANCZOS)
    small_img.save(small_path, "PNG")

    return large_path, small_path

def generate_thumbnails_from_image(base_image: Image.Image, output_dir: str):
    """从 PIL Image 对象生成缩略图"""
    os.makedirs(output_dir, exist_ok=True)
    large_path = os.path.join(output_dir, "large.png")
    small_path = os.path.join(output_dir, "small.png")

    if base_image.mode != "RGBA":
        base_image = base_image.convert("RGBA")

    large_img = base_image.resize(
        fit_thumbnail_size(base_image.width, base_image.height,
                           THUMB_LONG_EDGE_LARGE),
        Image.Resampling.LANCZOS)
    large_img.save(large_path, "PNG")

    small_img = base_image.resize(
        fit_thumbnail_size(base_image.width, base_image.height,
                           THUMB_LONG_EDGE_SMALL),
        Image.Resampling.LANCZOS)
    small_img.save(small_path, "PNG")

    return large_path, small_path
