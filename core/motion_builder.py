"""
Motion 模板生成核心模块 (全属性增强与原子写入稳健版)
严格按照 Apple ozml 5.14 XML 规范，完整写入旋转、缩放、透明度、横竖排版文本与细粒度发布参数。
核心保障：
1. 采用临时目录原子级写入（Atomic Write），杜绝直接向 FCPX 正在使用的活动模板目录写入半成品。
2. 写入完成后执行完整性校验（校验 .moti >= 1KB 且 XML 语法合法，large.png / small.png 完整有效）。
3. 自动对现有模板执行时间戳备份（<output_dir>_bak_<timestamp>）。
4. 任何阶段发生异常时，自动清理临时目录并回滚，保证活动目录绝不受污染。
"""
import os
import math
import xml.etree.ElementTree as ET
import copy
import shutil
import time
import urllib.parse
from typing import List, Dict, Any, Optional, Tuple, Callable
from PIL import Image

# ── R21 数据安全与可恢复性 ─────────────────────────────────────────────
# T1 磁盘空间预检常量：最小可用余量（200MB）+ 估算量的安全系数
MIN_FREE_MARGIN_BYTES = 200 * 1024 * 1024  # 200MB 基础余量
FREE_MARGIN_SAFETY_FACTOR = 1.5  # 估算量乘以该系数作为安全余量


class StorageNotReadyError(IOError):
    """外置存储卷未就绪或未挂载异常"""
    pass


class StoragePermissionError(PermissionError):
    """目标目录缺乏写权限或只读异常"""
    pass


class StorageSpaceError(OSError):
    """目标存储可用空间不足异常（R21-T1）"""
    pass


class TemplateConflictError(ValueError):
    """目标模板目录已存在且非空，冲突预检阻断（R21-T2）"""
    pass

def find_reference_template(custom_path: Optional[str] = None) -> str:
    """
    动态级联探测（Cascade Detection）Apple Motion 基准模板路径，按严格优先级：
    ① 显式入参指定路径 (custom_path)
    ② 环境变量 FCPX_MOTION_REFERENCE_PATH
    ③ 项目内 assets 基准模板 (PROJECT_ROOT/assets/reference_base.moti)
    ④ 用户主目录动态标准路径 (~/Movies/Motion Templates.localized/Titles.localized/...)
    """
    candidates = []

    # ① 显式入参路径
    if custom_path and str(custom_path).strip():
        candidates.append(os.path.expanduser(str(custom_path).strip()))

    # ② 环境变量指定路径
    env_path = os.environ.get("FCPX_MOTION_REFERENCE_PATH")
    if env_path and env_path.strip():
        candidates.append(os.path.expanduser(env_path.strip()))

    # ③ 项目内部 assets 或模块相对基准模板路径
    current_module_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(current_module_dir)
    candidates.extend([
        os.path.join(project_root, "assets", "reference_base.moti"),
        os.path.join(project_root, "templates", "reference_base.moti"),
        os.path.join(current_module_dir, "reference_base.moti")
    ])

    # ④ 用户主目录动态标准路径 (自适应任意 macOS 用户名)
    candidates.extend([
        os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/PSD婚礼字幕/1/1.moti"),
        os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/FCPX_Studio婚礼字幕测试/01_领衔呈现/01_领衔呈现.moti")
    ])

    for path in candidates:
        if path and os.path.isfile(path):
            return os.path.abspath(path)

    raise FileNotFoundError(
        "未能探测到有效的 Apple Motion 基准模板 (.moti) 文件！\n"
        "已依次尝试级联探测以下候选路径：\n" +
        "\n".join(f"  - {c}" for c in candidates) +
        "\n请设置环境变量 FCPX_MOTION_REFERENCE_PATH 或在初始化 MotionBuilder 时显式指定 base_moti_path。"
    )

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFERENCE_TEMPLATE_PATH = os.path.join(PROJECT_ROOT, "assets", "reference_base.moti")

# ── TR-009：备份与分类路径安全基线 ──────────────────────────────────────────
# 备份一律落在用户资源目录，绝不允许出现在 FCPX 扫描树（Motion Templates）内；
# 分类路径拼接禁止重复拼 Templates/Titles.localized 一层。
APP_SUPPORT_BACKUPS_ROOT = os.path.expanduser(
    "~/Library/Application Support/FCPXStudio/backups"
)
MOTION_TEMPLATES_ROOT = os.path.expanduser("~/Movies/Motion Templates.localized")
KNOWN_CATEGORIES = ["Titles.localized", "Effects.localized",
                   "Transitions.localized", "Generators.localized"]
BACKUP_KEEP_COUNT = 3


def _is_inside_motion_templates(path: str) -> bool:
    """判断 path 是否位于 FCPX 扫描树（Motion Templates.localized）内。"""
    try:
        real = os.path.realpath(path)
    except OSError:
        real = os.path.abspath(path)
    mt = os.path.realpath(MOTION_TEMPLATES_ROOT)
    return real == mt or real.startswith(mt + os.sep)


def _category_of(output_dir: str) -> str:
    """从 output_dir 中解析所属分类（Titles.localized 等），找不到返回 'unknown'。"""
    real = os.path.realpath(os.path.abspath(output_dir))
    parts = real.split(os.sep)
    for cat in KNOWN_CATEGORIES:
        if cat in parts:
            return cat
    return "unknown"


def _normalize_output_dir(output_dir: str) -> str:
    """
    TR-009 #2：分类路径拼接禁止重复拼 Templates/Titles.localized 一层。
    将 output_dir 中多余的已知分类段折叠为单一分类层，确保结构为
    <MotionRoot>/<category>/<group...>/<template>。
    """
    real = os.path.realpath(os.path.abspath(output_dir))
    parts = real.split(os.sep)
    norm: List[str] = []
    seen_category = False
    for p in parts:
        if p in KNOWN_CATEGORIES:
            if seen_category:
                continue  # 折叠重复分类段
            seen_category = True
        norm.append(p)
    return os.sep.join(norm)


def _safe_backup_path(category: str, name: str, ts: str) -> str:
    """TR-009 #1：备份落 ~/Library/Application Support/FCPXStudio/backups/<分类>/<时间戳>_<模板名>。"""
    return os.path.join(APP_SUPPORT_BACKUPS_ROOT, category, f"{ts}_{name}")


def _prune_backups(category: str, keep: int = BACKUP_KEEP_COUNT) -> List[str]:
    """
    TR-009 #1：每个分类仅保留最近 keep 份备份，超出者移入回收目录（不直接删）。
    返回被移走的备份路径列表。
    """
    cat_dir = os.path.join(APP_SUPPORT_BACKUPS_ROOT, category)
    if not os.path.isdir(cat_dir):
        return []
    entries = []
    for nm in os.listdir(cat_dir):
        fp = os.path.join(cat_dir, nm)
        if os.path.isdir(fp) and not nm.startswith("."):
            entries.append((os.path.getmtime(fp), fp))
    entries.sort(reverse=True)  # 新→旧
    removed = []
    if len(entries) > keep:
        ts = time.strftime("%Y%m%d_%H%M%S")
        trash = os.path.join(cat_dir, f"._trash_{ts}")
        os.makedirs(trash, exist_ok=True)
        for _, fp in entries[keep:]:
            dest = os.path.join(trash, os.path.basename(fp))
            if os.path.exists(dest):
                dest = f"{dest}_{int(time.time() * 1000)}"
            try:
                os.rename(fp, dest)
                removed.append(dest)
            except OSError:
                pass
    return removed


class MotionBuilder:
    def __init__(self, base_moti_path: Optional[str] = None):
        self.resolved_template_path = find_reference_template(base_moti_path)
        self.tree = ET.parse(self.resolved_template_path)
        self.root = self.tree.getroot()
        self.scene = self.root.find("scene")
        
        layers = self.scene.findall("layer")
        if not layers:
            raise ValueError(f"基准模板中缺少有效图层: {self.resolved_template_path}")
        self.layer_prototypes = [copy.deepcopy(l) for l in layers]
        self.layer_prototype = copy.deepcopy(self.layer_prototypes[0])

    def build_moti(self, layers_info: List[Any], output_file_path: str,
                   template_title: str = "Title",
                   canvas_size: Optional[Tuple[int, int]] = None) -> str:
        """
        根据图层列表组装并输出全新的 .moti 文件（单文件原子写入保护）
        支持纯矢量文字图层与含 Media/ 贴图的装饰/形状图层（ozml footage + scenenode factoryID=5）
        """
        # FCPX-028: 严格拦截空图层列表，杜绝生成废模板
        if not layers_info:
            raise ValueError("layers_info 列表为空，无法构建无图层的空白废模板")

        new_tree = copy.deepcopy(self.tree)
        new_root = new_tree.getroot()
        new_scene = new_root.find("scene")

        # A-24：写入真实画布尺寸，覆盖基准模板的硬编码值
        if canvas_size:
            cw, ch = int(canvas_size[0]), int(canvas_size[1])
            settings = new_scene.find("sceneSettings")
            if settings is None:
                settings = ET.SubElement(new_scene, "sceneSettings")
            for tag, val in (("width", cw), ("height", ch)):
                node = settings.find(tag)
                if node is None:
                    node = ET.SubElement(settings, tag)
                node.text = str(val)

        # 1. 移除旧的 layer 与 footage 节点
        for l in new_scene.findall("layer"):
            new_scene.remove(l)
        for ft in new_scene.findall("footage"):
            new_scene.remove(ft)

        # 2. 准备全新的 publishSettings
        pub_settings = new_scene.find("publishSettings")
        if pub_settings is not None:
            new_scene.remove(pub_settings)
        
        pub_settings = ET.Element("publishSettings")
        v_elem = ET.SubElement(pub_settings, "version")
        v_elem.text = "2"
        # 默认保留 HDR Level 控制
        ET.SubElement(pub_settings, "target", {
            "object": "999166629",
            "channel": "./1/103",
            "name": "Graphics HDR Level"
        })

        # 0. 查找或注册 图像 Factory (uuid="66fc0d6af6a911d6a7a7000393670732")
        image_factory_id = None
        existing_fids = set()
        for f in new_root.findall("factory"):
            fid = f.attrib.get("id")
            if fid:
                try:
                    existing_fids.add(int(fid))
                except ValueError:
                    pass
            if f.attrib.get("uuid") == "66fc0d6af6a911d6a7a7000393670732":
                image_factory_id = fid
                break

        if image_factory_id is None:
            new_fid = max(existing_fids, default=19) + 1
            image_factory_id = str(new_fid)
            factory_elem = ET.Element("factory", {
                "id": image_factory_id,
                "uuid": "66fc0d6af6a911d6a7a7000393670732"
            })
            ET.SubElement(factory_elem, "description").text = "图像"
            ET.SubElement(factory_elem, "manufacturer").text = "Apple"
            ET.SubElement(factory_elem, "version").text = "1"
            scene_pos = list(new_root).index(new_scene) if new_scene in list(new_root) else len(new_root)
            new_root.insert(scene_pos, factory_elem)

        footage_elem = None
        proto_timing = self.layer_prototype.find("timing")

        # 3. 遍历图层，组装并追加
        for i, info in enumerate(layers_info, start=1):
            layer_id = f"3000{i}00"
            scenenode_id = f"3000{i}02"
            style_id = f"3000{i}05"
            para_id = f"3000{i}07"
            clip_id = f"3000{i}09"

            is_media = (getattr(info, "kind", "type") != "type") or bool(getattr(info, "fallback_png_path", None))

            if is_media:
                # ── 非文本装饰图层 (Media Layer) ──
                if footage_elem is None:
                    footage_elem = ET.Element("footage", {"name": "媒体层", "id": "3076024531"})

                png_path = getattr(info, "fallback_png_path", None)
                png_name = os.path.basename(png_path) if png_path else f"element_{i:02d}.png"
                quoted_rel_url = f"Media/{urllib.parse.quote(png_name)}"

                img_w = 1920
                img_h = 1080
                png_info = getattr(info, "fallback_png_info", {}) or {}
                if png_info.get("width") and png_info.get("height"):
                    img_w = int(png_info["width"])
                    img_h = int(png_info["height"])
                elif png_path and os.path.exists(png_path):
                    try:
                        with Image.open(png_path) as im:
                            img_w, img_h = im.size
                    except Exception:
                        pass
                elif getattr(info, "psd_bbox", None):
                    l, t, r, b = info.psd_bbox
                    img_w = max(1, int(r - l))
                    img_h = max(1, int(b - t))

                # clip 节点 (仅存放 clip，标准静态图片 timing)
                clip_elem = ET.SubElement(footage_elem, "clip", {"name": info.name, "id": clip_id})
                ET.SubElement(clip_elem, "relativeURL").text = quoted_rel_url
                ET.SubElement(clip_elem, "missingWidth").text = str(img_w)
                ET.SubElement(clip_elem, "missingHeight").text = str(img_h)
                ET.SubElement(clip_elem, "missingDuration").text = "0.033333333333333333"
                ET.SubElement(clip_elem, "missingDynamicRangeType").text = "0"
                ET.SubElement(clip_elem, "creationDuration").text = "1"
                ET.SubElement(clip_elem, "mediaID")
                ET.SubElement(clip_elem, "flags").text = "0"
                ET.SubElement(clip_elem, "timing", {"in": "0 1 1 0", "out": "0 153600 1 0", "offset": "0 1 1 0"})
                ET.SubElement(clip_elem, "foldFlags").text = "0"
                ET.SubElement(clip_elem, "baseFlags").text = "524304"
                ET.SubElement(clip_elem, "parameter", {"name": "属性", "id": "1", "flags": "8589938704"})
                clip_obj = ET.SubElement(clip_elem, "parameter", {"name": "对象", "id": "2", "flags": "8589938704"})
                alpha_p = ET.SubElement(clip_obj, "parameter", {"name": "Alpha 类型", "id": "100", "flags": "8589938704"})
                ET.SubElement(alpha_p, "parameter", {"name": "Alpha 类型", "id": "101", "flags": "8590000128", "default": "0", "value": "1"})
                ET.SubElement(clip_obj, "parameter", {"name": "像素宽高比", "id": "104", "flags": "12884901888", "default": "1", "value": "1"})
                ET.SubElement(clip_obj, "parameter", {"name": "帧速率", "id": "107", "flags": "8589934592", "default": "0", "value": "60"})
                ET.SubElement(clip_obj, "parameter", {"name": "固定宽度", "id": "114", "flags": "12884901888", "default": str(img_w), "value": str(img_w)})
                ET.SubElement(clip_obj, "parameter", {"name": "固定高度", "id": "115", "flags": "12884901888", "default": str(img_h), "value": str(img_h)})
                ET.SubElement(clip_obj, "parameter", {"name": "使用背景颜色", "id": "116", "flags": "8589934594", "default": "0", "value": "0"})
                ET.SubElement(clip_obj, "parameter", {"name": "Missing Is Still", "id": "128", "flags": "8589934610", "default": "0", "value": "1"})

                # layer 节点与 factoryID 指向图像 factory 的 scenenode
                layer_proto = self.layer_prototypes[i - 1] if i <= len(self.layer_prototypes) else self.layer_prototypes[-1]
                layer_elem = copy.deepcopy(layer_proto)
                layer_elem.attrib["name"] = f"Media {i:02d} ({info.name})"
                layer_elem.attrib["id"] = layer_id

                old_sn = layer_elem.find("scenenode")
                if old_sn is not None:
                    layer_elem.remove(old_sn)

                sn_elem = ET.Element("scenenode", {
                    "name": info.name,
                    "id": scenenode_id,
                    "factoryID": image_factory_id,
                    "version": "5"
                })
                ET.SubElement(sn_elem, "validTracks").text = "1"
                ET.SubElement(sn_elem, "aspectRatio").text = "1"
                ET.SubElement(sn_elem, "flags").text = "0"
                if proto_timing is not None:
                    sn_elem.append(copy.deepcopy(proto_timing))
                else:
                    ET.SubElement(sn_elem, "timing", {"in": "0 1 1 0", "out": "1533440 153600 1 0", "offset": "0 1 1 0"})
                ET.SubElement(sn_elem, "foldFlags").text = "16384"
                ET.SubElement(sn_elem, "baseFlags").text = "524304"

                p_attr = ET.SubElement(sn_elem, "parameter", {"name": "属性", "id": "1", "flags": "8589938704"})
                p_trans = ET.SubElement(p_attr, "parameter", {"name": "变换", "id": "100", "flags": "8589938704"})
                # FCPX-027: 断言校验 motion_pos 长度，防越界崩溃
                raw_mpos = getattr(info, "motion_pos", (0, 0)) or (0, 0)
                mpos = raw_mpos if isinstance(raw_mpos, (list, tuple)) and len(raw_mpos) >= 2 else (0.0, 0.0)
                mx = float(mpos[0])
                my = float(mpos[1])
                p_pos = ET.SubElement(p_trans, "parameter", {"name": "位置", "id": "101", "flags": "8589938704"})
                ET.SubElement(p_pos, "parameter", {"name": "X", "id": "1", "flags": "8606711824", "default": "0", "value": str(round(mx, 2))})
                ET.SubElement(p_pos, "parameter", {"name": "Y", "id": "2", "flags": "8606711824", "default": "0", "value": str(round(my, 2))})

                rot_val = str(round(getattr(info, "rotation", 0.0), 2))
                p_rot = ET.SubElement(p_trans, "parameter", {"name": "旋转", "id": "102", "flags": "8589938704"})
                ET.SubElement(p_rot, "parameter", {"name": "Z", "id": "3", "flags": "8606711824", "default": "0", "value": rot_val})

                scale_x = str(round(getattr(info, "scale_x", 1.0), 3))
                scale_y = str(round(getattr(info, "scale_y", 1.0), 3))
                p_scale = ET.SubElement(p_trans, "parameter", {"name": "缩放", "id": "105", "flags": "8589938704"})
                ET.SubElement(p_scale, "parameter", {"name": "X", "id": "1", "flags": "8606711824", "default": "1", "value": scale_x})
                ET.SubElement(p_scale, "parameter", {"name": "Y", "id": "2", "flags": "8606711824", "default": "1", "value": scale_y})

                # FCPX-019: 写入媒体层透明度 (0.0 ~ 1.0)
                media_op = float(getattr(info, "opacity", 1.0) or 1.0)
                media_op = max(0.0, min(1.0, media_op))
                ET.SubElement(p_attr, "parameter", {"name": "不透明度", "id": "108", "flags": "8606711824", "default": "1", "value": str(round(media_op, 4))})

                p_media = ET.SubElement(p_attr, "parameter", {"name": "媒体", "id": "324", "flags": "8589938704"})
                ET.SubElement(p_media, "parameter", {
                    "name": "源媒体", "id": "300", "flags": "81604444176",
                    "default": clip_id, "value": clip_id
                })
                ET.SubElement(p_media, "parameter", {"name": "源媒体", "id": "325", "flags": "8590000146"})

                ET.SubElement(p_attr, "parameter", {"name": "页码", "id": "301", "flags": "8589934610", "default": "1", "value": "1"})
                ET.SubElement(p_attr, "parameter", {"name": "重新定时值", "id": "304", "flags": "8590066066", "default": "1", "value": "1"})
                ET.SubElement(p_attr, "parameter", {"name": "重新定时值缓存", "id": "319", "flags": "8590065810", "default": "1", "value": "1"})

                p_obj = ET.SubElement(sn_elem, "parameter", {"name": "对象", "id": "2", "flags": "8589938704"})
                ET.SubElement(p_obj, "parameter", {"name": "宽度", "id": "313", "flags": "8589934610", "default": "1", "value": str(img_w)})
                ET.SubElement(p_obj, "parameter", {"name": "高度", "id": "314", "flags": "8589934610", "default": "1", "value": str(img_h)})

                layer_elem.insert(0, sn_elem)

                if not getattr(info, "visible", True):
                    flags_elem = layer_elem.find("flags")
                    if flags_elem is not None:
                        flags_elem.text = "8589938688"
                    base_flags = layer_elem.find("baseFlags")
                    if base_flags is not None:
                        base_flags.text = "8589938688"

                channels = getattr(info, "published_channels", {})
                if getattr(info, "visible", True) and getattr(info, "is_published", False):
                    if channels.get("position", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/101", "name": f"Position {i:02d} ({info.name})"
                        })
                    if channels.get("rotation", False):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/102", "name": f"Rotation {i:02d} ({info.name})"
                        })
                    if channels.get("scale", False):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/105", "name": f"Scale {i:02d} ({info.name})"
                        })

                new_scene.append(layer_elem)
            else:
                # ── 纯矢量文本图层 ──
                layer_proto = self.layer_prototypes[i - 1] if i <= len(self.layer_prototypes) else self.layer_prototypes[-1]
                layer_elem = copy.deepcopy(layer_proto)
                layer_elem.attrib["name"] = f"Text {i:02d}"
                layer_elem.attrib["id"] = layer_id

                sn = layer_elem.find("scenenode")
                if sn is not None:
                    sn.attrib["name"] = f"Title {i:02d}"
                    sn.attrib["id"] = scenenode_id

                pstyle = layer_elem.find(".//paragraphStyle")
                if pstyle is not None:
                    pstyle.attrib["id"] = para_id

                style = layer_elem.find(".//style")
                if style is not None:
                    style.attrib["id"] = style_id

                    # 确保全部大写 (id="12") 参数无条件完整存在，杜绝 Motion TXTextLayout::applyAllCaps 段错误崩溃
                    all_caps_p = style.find("parameter[@id=\"12\"]")
                    if all_caps_p is None:
                        all_caps_p = ET.Element("parameter", {
                            "name": "全部大写",
                            "id": "12",
                            "flags": "8589934608",
                            "default": "0",
                            "value": "0"
                        })
                        p81_idx = None
                        for s_idx, sp in enumerate(style):
                            if sp.tag == "parameter" and sp.attrib.get("id") == "81":
                                p81_idx = s_idx
                                break
                        if p81_idx is not None:
                            style.insert(p81_idx + 1, all_caps_p)
                        else:
                            style.append(all_caps_p)

                    # FCPX-022: 将描边/投影/发光参数真实写进 style
                    style_entries = getattr(info, "style_entries", None)
                    if not style_entries and getattr(info, "layer_styles", None):
                        from core.motion_param_writer import build_layer_style_motion_entries
                        style_entries = build_layer_style_motion_entries(info.layer_styles)
                    if style_entries:
                        from core.motion_param_writer import apply_style_effects_to_ozml
                        apply_style_effects_to_ozml(style, style_entries)

                # 字体 (优先使用经过回退诊断后的安全字体)
                font_elem = layer_elem.find(".//parameter[@id=\"83\"]/font")
                if font_elem is not None:
                    font_elem.text = getattr(info, "font_name", None) or "Helvetica"

                # 字号
                size_elem = layer_elem.find(".//parameter[@id=\"3\"]")
                if size_elem is not None:
                    size_elem.attrib["value"] = str(round(info.font_size, 2))

                # 字距
                track_elem = layer_elem.find(".//parameter[@id=\"81\"]/parameter[@id=\"79\"]")
                if track_elem is not None:
                    track_elem.attrib["value"] = str(round(info.tracking, 4))

                # 文本内容
                # R26-A47：缺字可见标记接进 .moti 输出层。
                # 仅当解析层携带非空 marked_text（含 □ tofu 标记，与原文逐字 1:1 等长）
                # 时用标记版文本；否则保持原始 text（未缺字/旧调用路径零变化）。
                # 本改动只触碰文本值写出（text_elem.text / styleRun length），
                # 不触碰 scenenode id、参数结构、id 编号（深层 id 红线依旧）。
                out_text = getattr(info, "marked_text", "") or info.text
                text_elem = layer_elem.find(".//parameter[@id=\"369\"]/text")
                if text_elem is not None:
                    text_elem.text = out_text

                # 同步更新 styleRun 样式指针与文本字符长度 length
                style_runs = layer_elem.findall(".//styleRun")
                if style_runs:
                    style_runs[0].attrib["style"] = style_id
                    style_runs[0].attrib["offset"] = "0"
                    style_runs[0].attrib["length"] = str(len(out_text or ""))
                    sn_node = layer_elem.find("scenenode")
                    if sn_node is not None:
                        for extra_sr in style_runs[1:]:
                            try:
                                sn_node.remove(extra_sr)
                            except Exception:
                                pass

                # 同步更新段落参数节点 id
                p354 = layer_elem.find(".//parameter[@id=\"354\"]")
                if p354 is not None:
                    for p_child in p354.findall("parameter"):
                        if p_child.attrib.get("name") == "段落" and p_child.attrib.get("id", "").startswith("3000"):
                            p_child.attrib["id"] = para_id
                            break

                # 同步更新段落对齐 parameter id="401" (1=Left, 2=Center, 3=Right)
                align_str = getattr(info, "alignment", "center") or "center"
                align_str = str(align_str).lower()
                align_val = "2"
                if align_str == "left":
                    align_val = "1"
                elif align_str == "right":
                    align_val = "3"
                elif align_str == "center":
                    align_val = "2"

                p401_list = layer_elem.findall(".//parameter[@id=\"401\"]")
                for p401 in p401_list:
                    p401.attrib["value"] = align_val
                if not p401_list:
                    for ps in layer_elem.findall(".//paragraphStyle"):
                        ET.SubElement(ps, "parameter", {
                            "name": "对齐",
                            "id": "401",
                            "flags": "8606777360",
                            "default": "0",
                            "value": align_val
                        })

                # 坐标 Position X, Y (中心笛卡尔坐标 + 非居中锚点坐标补偿)
                # FCPX-027: 断言校验 motion_pos 长度，防越界崩溃
                raw_mpos = getattr(info, "motion_pos", (0, 0)) or (0, 0)
                mpos = raw_mpos if isinstance(raw_mpos, (list, tuple)) and len(raw_mpos) >= 2 else (0.0, 0.0)
                mx = float(mpos[0])
                my = float(mpos[1])
                rot_deg = float(getattr(info, "rotation", 0.0) or 0.0)
                comp_x, comp_y = mx, my
                if align_str in ("left", "right"):
                    rot_rad = math.radians(rot_deg)
                    bbox = getattr(info, "psd_bbox", None)
                    if bbox and isinstance(bbox, (list, tuple)) and len(bbox) == 4:
                        bw = max(1.0, float(bbox[2] - bbox[0]))
                        bh = max(1.0, float(bbox[3] - bbox[1]))
                        if abs(math.sin(rot_rad)) > 0.7:
                            line_len = bh
                        else:
                            line_len = bw
                    else:
                        char_count = max(1, len(str(getattr(info, "text", "") or "").replace("\n", "").replace("\r", "")))
                        fs = float(getattr(info, "font_size", 36.0) or 36.0)
                        line_len = char_count * fs

                    half_len = line_len / 2.0
                    dx = half_len * math.cos(rot_rad)
                    dy = half_len * math.sin(rot_rad)
                    if align_str == "left":
                        comp_x = mx - dx
                        comp_y = my - dy
                    elif align_str == "right":
                        comp_x = mx + dx
                        comp_y = my + dy

                pos_x = layer_elem.find(".//parameter[@id=\"101\"]/parameter[@id=\"1\"]")
                if pos_x is not None:
                    pos_x.attrib["value"] = str(round(comp_x, 2))
                pos_y = layer_elem.find(".//parameter[@id=\"101\"]/parameter[@id=\"2\"]")
                if pos_y is not None:
                    pos_y.attrib["value"] = str(round(comp_y, 2))

                # 旋转 Rotation
                rot_elem = layer_elem.find(".//parameter[@id=\"102\"]")
                if rot_elem is not None:
                    rot_elem.attrib["value"] = str(round(getattr(info, "rotation", 0.0), 2))

                # 缩放 Scale X, Y
                scale_x_elem = layer_elem.find(".//parameter[@id=\"105\"]/parameter[@id=\"1\"]")
                if scale_x_elem is not None:
                    scale_x_elem.attrib["value"] = str(round(getattr(info, "scale_x", 1.0), 3))
                scale_y_elem = layer_elem.find(".//parameter[@id=\"105\"]/parameter[@id=\"2\"]")
                if scale_y_elem is not None:
                    scale_y_elem.attrib["value"] = str(round(getattr(info, "scale_y", 1.0), 3))

                # FCPX-019: 写入透明度 Opacity (0.0 ~ 1.0)
                txt_op = float(getattr(info, "opacity", 1.0) or 1.0)
                txt_op = max(0.0, min(1.0, txt_op))
                txt_op_str = str(round(txt_op, 4))
                for p2 in layer_elem.findall(".//parameter[@id='2000']//parameter[@id='2']"):
                    p2.attrib["value"] = txt_op_str
                sn_attr = layer_elem.find(".//scenenode/parameter[@id='1']")
                if sn_attr is not None:
                    p108 = sn_attr.find("parameter[@id='108']")
                    if p108 is None:
                        p108 = ET.SubElement(sn_attr, "parameter", {
                            "name": "不透明度", "id": "108", "flags": "8606711824",
                            "default": "1", "value": txt_op_str
                        })
                    else:
                        p108.attrib["value"] = txt_op_str

                # FCPX-020: 写入行距 (line_spacing)
                l_spacing = getattr(info, "line_spacing", None)
                if l_spacing is not None:
                    l_val = str(round(float(l_spacing), 2))
                    for ps in layer_elem.findall(".//paragraphStyle"):
                        lsp = ps.find("parameter[@id='402']")
                        if lsp is None:
                            ET.SubElement(ps, "parameter", {
                                "name": "行距", "id": "402", "flags": "8606777360",
                                "default": "0", "value": l_val
                            })
                        else:
                            lsp.attrib["value"] = l_val

                # FCPX-021: 写入排版方向 writing_direction
                w_dir = getattr(info, "writing_direction", "horizontal") or "horizontal"
                dir_val = "1" if str(w_dir).lower() in ("vertical", "v", "竖排") else "0"
                for ps in layer_elem.findall(".//paragraphStyle"):
                    pdir = ps.find("parameter[@id='405']")
                    if pdir is None:
                        ET.SubElement(ps, "parameter", {
                            "name": "文字方向", "id": "405", "flags": "8606777360",
                            "default": "0", "value": dir_val
                        })
                    else:
                        pdir.attrib["value"] = dir_val

                # 处理显示/隐藏
                if not info.visible:
                    flags_elem = layer_elem.find("flags")
                    if flags_elem is not None:
                        flags_elem.text = "8589938688"
                    base_flags = layer_elem.find("baseFlags")
                    if base_flags is not None:
                        base_flags.text = "8589938688"

                # 4. 发布参数配置 (根据细粒度勾选通道)
                channels = getattr(info, "published_channels", {})
                if info.visible and info.is_published:
                    if channels.get("text", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./2/369", "name": f"Text {i:02d}"
                        })
                    if channels.get("font", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": style_id, "channel": "./83", "name": f"Font {i:02d}"
                        })
                    if channels.get("size", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": style_id, "channel": "./3", "name": f"Size {i:02d}"
                        })
                    if channels.get("tracking", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": style_id, "channel": "./81/79", "name": f"Tracking {i:02d}"
                        })
                    if channels.get("alignment", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": f"./2/354/{para_id}/401", "name": f"Alignment {i:02d}"
                        })
                    if channels.get("position", True):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/101", "name": f"Position {i:02d}"
                        })
                    if channels.get("rotation", False):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/102", "name": f"Rotation {i:02d}"
                        })
                    if channels.get("scale", False):
                        ET.SubElement(pub_settings, "target", {
                            "object": scenenode_id, "channel": "./1/100/105", "name": f"Scale {i:02d}"
                        })

                new_scene.append(layer_elem)

        if footage_elem is not None and len(footage_elem) > 0:
            new_scene.append(footage_elem)

        new_scene.insert(1, pub_settings)
        target_dir = os.path.dirname(os.path.abspath(output_file_path))
        os.makedirs(target_dir, exist_ok=True)

        # 单文件原子写入：先写临时文件，校验通过后再 replace
        tmp_file_path = f"{output_file_path}.tmp_moti_{os.getpid()}_{int(time.time()*1000)}"
        try:
            xml_declaration = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE ozxmlscene>\n'
            raw_xml = ET.tostring(new_root, encoding="utf-8").decode()
            with open(tmp_file_path, "w", encoding="utf-8") as f:
                f.write(xml_declaration + raw_xml)

            # 校验临时文件
            file_sz = os.path.getsize(tmp_file_path)
            if file_sz < 1024:
                raise ValueError(f"生成的 .moti 文件体积异常过小 ({file_sz} 字节 < 1024 字节)")

            os.replace(tmp_file_path, output_file_path)
        except Exception as e:
            if os.path.exists(tmp_file_path):
                try:
                    os.remove(tmp_file_path)
                except Exception:
                    pass
            raise e

        return output_file_path

    def build_template_atomic(
        self,
        layers_info: List[Any],
        output_dir: str,
        template_name: str,
        psd_path: Optional[str] = None,
        backup_existing: bool = True,
        _inject_failure_stage: Optional[str] = None,
        canvas_size: Optional[Tuple[int, int]] = None,
        on_conflict: str = "backup",
        conflict_callback: Optional[Callable[[str], bool]] = None,
        backup_root: Optional[str] = None,
        extra_aliases: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """
        原子构建完整的 Motion 模板目录包（包括 .moti、Media 资源、large.png 与 small.png 缩略图）

        A-24：`canvas_size=(w, h)` 必须传入 PSD 真实画布尺寸，
        否则模板会沿用基准模板的 1920×1080，竖版 PSD 会生成横版 comp。
        
        流程与保障：
        1. 在目标父目录下创建独占临时构建目录 `<output_dir>_tmp_build_<pid>_<timestamp>`
        2. 在临时目录内完整生成 .moti、large.png、small.png 与降级 PNG 资源
        3. 严谨校验所有必需文件完整性与最小尺寸约束
        4. 若原活动目录已存在，将其安全备份至 `<output_dir>_bak_<timestamp>`
        5. 通过原子级文件系统重命名（os.replace）替换为正式活动目录
        6. 发生任何异常时，自动清理临时目录并从备份回滚，确保活动目录零污染
        """
        from core.thumbnail import generate_thumbnails_from_psd, generate_thumbnails_from_image
        from psd_tools import PSDImage
        from core.template_dedup import (
            dedup_before_install,
            verify_unique_after_install,
            derive_template_aliases,
            _sha256_of_file,
            _media_count,
        )

        # FCPX-028: 严格拦截空图层列表，杜绝生成废模板
        if not layers_info:
            raise ValueError("layers_info 列表为空，无法构建无图层的空白废模板")

        if not output_dir or not str(output_dir).strip():
            raise ValueError("output_dir 不能为空")

        if not template_name or any(bad in template_name for bad in ["/", "\\", ".."]) or len(template_name) > 255:
            raise ValueError(f"非法的模板名称「{template_name}」：名称禁止包含路径字符（/、\\、..）且长度不得超过 255 字符")

        # TR-009 #2：先折叠可能重复的分类层（如 .../Titles.localized/PSD婚礼字幕/Titles.localized/...）
        output_dir = _normalize_output_dir(output_dir)
        norm_dir = os.path.realpath(output_dir)
        cwd_dir = os.path.realpath(os.getcwd())

        # FCPX-005 (a): 检查是否为敏感系统路径或当前工作目录
        sensitive_roots = {"/", "/System", "/Library", "/Applications", "/Users", "/bin", "/sbin", "/usr", "/var", "/tmp"}
        if norm_dir in sensitive_roots or norm_dir == cwd_dir:
            raise ValueError(f"output_dir 指向受保护的敏感路径或当前工作目录，已安全拦截: {output_dir}")

        # FCPX-005 (b): 目标目录若已存在，必须验证是否是有效 Motion 模板目录
        if os.path.exists(output_dir):
            if not os.path.isdir(output_dir):
                raise ValueError(f"目标路径已存在且为普通文件，禁止移走覆盖: {output_dir}")
            existing_files = os.listdir(output_dir)
            if existing_files:
                has_motion = any(f.endswith((".moti", ".motn", ".mofd", ".motr")) for f in existing_files)
                if not has_motion:
                    raise ValueError(f"目标目录已存在但未检测到任何 Motion 模板文件 (.moti/.motn)，禁止静默移走非模板目录: {output_dir}")

        # ── Pre-flight 检查 1: 验证外置存储卷就绪状态 ──
        if output_dir.startswith("/Volumes/"):
            parts = output_dir.split(os.sep)
            if len(parts) >= 3:
                vol_mount = os.sep + os.path.join(parts[1], parts[2])
                if not os.path.exists(vol_mount):
                    raise StorageNotReadyError(
                        f"外置存储就绪检查失败: 目标卷 '{vol_mount}' 未挂载或不可用，已先行阻断写入"
                    )

        # ── Pre-flight 检查 2: 验证路径可写性与权限 ──
        ancestor = output_dir
        while ancestor and not os.path.exists(ancestor):
            ancestor = os.path.dirname(ancestor)

        if ancestor and os.path.exists(ancestor):
            if not os.access(ancestor, os.W_OK):
                raise StoragePermissionError(f"目标存储路径只读或缺乏写权限: {ancestor}")

        if os.path.exists(output_dir) and not os.access(output_dir, os.W_OK):
            raise StoragePermissionError(f"目标模板目录只读或缺乏修改权限: {output_dir}")

        # ── Pre-flight 检查 3: 磁盘空间预检（R21-T1）──
        if ancestor and os.path.exists(ancestor):
            est_bytes = 0
            if psd_path and os.path.exists(psd_path):
                est_bytes += os.path.getsize(psd_path)
            if canvas_size:
                cw, ch = canvas_size
            else:
                cw, ch = 1920, 1080
            est_bytes += cw * ch * 4  # 缩略图 RGBA 像素粗估
            required = MIN_FREE_MARGIN_BYTES + int(est_bytes * FREE_MARGIN_SAFETY_FACTOR)
            try:
                free = shutil.disk_usage(ancestor).free
            except OSError:
                free = 0
            if free < required:
                raise StorageSpaceError(
                    f"磁盘空间不足: 需要约 {required / 1024 / 1024:.1f} MB / "
                    f"可用 {free / 1024 / 1024:.1f} MB (目标: {ancestor})"
                )

        # ── Pre-flight 检查 4: 重名模板冲突预检（R21-T2）──
        # 检测 output_dir 是否已存在且非空。
        # on_conflict="abort"：直接抛错，不写任何东西
        # on_conflict="ask"：调用回调决定；返回 False 则抛错
        # on_conflict="backup"（默认）：放行，走既有备份覆盖逻辑
        if on_conflict not in ("backup", "abort", "ask"):
            raise ValueError(f"on_conflict 取值非法: {on_conflict}")
        if os.path.isdir(output_dir) and os.listdir(output_dir):
            if on_conflict == "abort":
                raise TemplateConflictError(
                    f"目标模板目录已存在且非空: {output_dir}（on_conflict='abort'）"
                )
            elif on_conflict == "ask":
                if conflict_callback is None:
                    raise ValueError(
                        "on_conflict='ask' 需注入 conflict_callback，core 层不弹 GUI"
                    )
                proceed = conflict_callback(output_dir)
                if not proceed:
                    raise TemplateConflictError(
                        f"目标模板目录已存在且非空，用户取消覆盖: {output_dir}"
                    )

        parent_dir = os.path.dirname(output_dir)
        os.makedirs(parent_dir, exist_ok=True)

        # 临时工作目录位于同一文件系统卷下，以保证后续原子移动的零拷贝与强一致性
        tmp_build_dir = f"{output_dir}_tmp_build_{os.getpid()}_{int(time.time()*1000)}"
        media_dir = os.path.join(tmp_build_dir, "Media")
        backup_dir = None
        backed_up_by_rename = False

        try:
            # 阶段故障注入: before_build
            if _inject_failure_stage == "before_build":
                raise RuntimeError("测试故障注入: before_build 在构建开始前抛出异常")

            # 1. 建立临时构建沙箱目录
            if os.path.exists(tmp_build_dir):
                shutil.rmtree(tmp_build_dir, ignore_errors=True)
            os.makedirs(media_dir, exist_ok=True)

            # 2. UI-G063: 循环外 open 一次复用，消除多图层重复解包 PSD 导致的严重耗时
            cached_psd_obj = None
            if psd_path and os.path.exists(psd_path):
                try:
                    cached_psd_obj = PSDImage.open(psd_path)
                except Exception:
                    cached_psd_obj = None

            for idx, info in enumerate(layers_info, start=1):
                src_png = getattr(info, "fallback_png_path", None)
                if not src_png and getattr(info, "kind", "type") != "type" and cached_psd_obj is not None:
                    try:
                        for pl in cached_psd_obj.descendants():
                            if pl.name == info.name:
                                safe_name = "".join(c for c in pl.name if c.isalnum() or c in ('_', '-')).strip() or f"layer_{idx}"
                                extracted_png = os.path.join(media_dir, f"element_{idx:02d}_{safe_name}.png")
                                limg = pl.composite()
                                if limg:
                                    if limg.mode != "RGBA":
                                        limg = limg.convert("RGBA")
                                    limg.save(extracted_png, "PNG")
                                    info.fallback_png_path = extracted_png
                                break
                    except Exception:
                        pass
                elif src_png and os.path.exists(src_png):
                    dst_png = os.path.join(media_dir, os.path.basename(src_png))
                    if os.path.abspath(src_png) != os.path.abspath(dst_png):
                        shutil.copy2(src_png, dst_png)
                    info.fallback_png_path = dst_png

            # 阶段故障注入: after_media
            if _inject_failure_stage == "after_media":
                raise RuntimeError("测试故障注入: after_media 媒体资源准备完成后抛出异常")

            # 3. 组装并生成 .moti
            tmp_moti_path = os.path.join(tmp_build_dir, f"{template_name}.moti")
            self.build_moti(layers_info, tmp_moti_path, template_name,
                            canvas_size=canvas_size)

            # 阶段故障注入: after_xml (兼容 after_moti)
            if _inject_failure_stage in ("after_xml", "after_moti"):
                raise RuntimeError("测试故障注入: after_xml .moti XML 生成完成后抛出异常")

            # 4. 渲染并生成双规格缩略图 (large.png 640x360, small.png 192x108)
            if cached_psd_obj is not None:
                try:
                    generate_thumbnails_from_psd(cached_psd_obj, tmp_build_dir)
                except Exception:
                    # 合成失败时生成标准透明缩略图垫底
                    blank_img = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
                    generate_thumbnails_from_image(blank_img, tmp_build_dir)
            else:
                blank_img = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
                generate_thumbnails_from_image(blank_img, tmp_build_dir)

            # 阶段故障注入: after_thumbnails
            if _inject_failure_stage == "after_thumbnails":
                raise RuntimeError("测试故障注入: after_thumbnails 缩略图生成完成后抛出异常")

            # 5. 严格完整性校验 (Integrity Verification)
            self._validate_template_bundle(tmp_build_dir, template_name, layers_info)

            # 阶段故障注入: after_validation
            if _inject_failure_stage in ("after_validation", "before_replace"):
                raise RuntimeError("测试故障注入: after_validation 校验完成但在提交替换前抛出异常")

            # 6a. A-40 ① 安装前去重：扫描并处置同源历史模板目录
            built_moti_path = os.path.join(tmp_build_dir, f"{template_name}.moti")
            built_moti_sha = _sha256_of_file(built_moti_path)
            built_media_count = _media_count(tmp_build_dir)
            _aliases = extra_aliases or derive_template_aliases(template_name)
            dedup_report = dedup_before_install(
                output_dir,
                built_moti_sha,
                built_media_count,
                trash_root=None,
                extra_aliases=_aliases,
            )

            # 6. 原模板安全备份（TR-009：一律移出 FCPX 扫描树，写
            #    ~/Library/Application Support/FCPXStudio/backups/<分类>/<时间戳>_<名>，仅保留最近 3 份）
            if os.path.exists(output_dir):
                if backup_existing:
                    ts = time.strftime("%Y%m%d_%H%M%S")
                    category = _category_of(output_dir)
                    backup_dir = _safe_backup_path(category, os.path.basename(output_dir), ts)
                    # 硬性断言：备份绝不可落在 Motion Templates 扫描树内（TR-009 #1/#2）
                    if _is_inside_motion_templates(backup_dir):
                        raise ValueError(
                            f"备份目标误落在 FCPX 扫描树内，已中止以防污染: {backup_dir}"
                        )
                    os.makedirs(os.path.dirname(backup_dir), exist_ok=True)
                    os.rename(output_dir, backup_dir)
                    backed_up_by_rename = True
                    _prune_backups(category, keep=BACKUP_KEEP_COUNT)
                else:
                    trash_dir = os.path.join(
                        parent_dir, f".{template_name}_trash_{os.getpid()}_{int(time.time()*1000)}"
                    )
                    os.rename(output_dir, trash_dir)
                    shutil.rmtree(trash_dir, ignore_errors=True)

            # 阶段故障注入: during_replace
            if _inject_failure_stage == "during_replace":
                raise RuntimeError("测试故障注入: during_replace 在原子替换过程中抛出异常")

            # 7. 原子替换提交到目标活动目录
            os.replace(tmp_build_dir, output_dir)

            # 7b. A-40 ② 安装后唯一性校验（多版本残留 = 闪退风险，必须唯一）
            verify_unique_after_install(
                output_dir,
                built_moti_sha,
                built_media_count,
                extra_aliases=_aliases,
            )

            final_moti_path = os.path.join(output_dir, f"{template_name}.moti")
            final_large_path = os.path.join(output_dir, "large.png")
            final_small_path = os.path.join(output_dir, "small.png")

            return {
                "status": "ok",
                "output_dir": output_dir,
                "moti_path": final_moti_path,
                "large_png": final_large_path,
                "small_png": final_small_path,
                "backup_path": backup_dir,
                "dedup_report": dedup_report,
            }

        except Exception as exc:
            # 异常发生：坚决清理临时沙箱目录，杜绝半成品残留
            if os.path.exists(tmp_build_dir):
                shutil.rmtree(tmp_build_dir, ignore_errors=True)
            
            # 若原活动目录已被移至备份且尚未完成替换，立刻安全回滚还原
            if backed_up_by_rename and backup_dir and os.path.exists(backup_dir) and not os.path.exists(output_dir):
                try:
                    os.rename(backup_dir, output_dir)
                except Exception:
                    pass

            raise exc

    def _validate_template_bundle(self, bundle_dir: str, template_name: str, layers_info: List[Any]):
        """
        全面校验模板包完整性：
        1. .moti 存在且体积必须 > 1KB (1024 字节)
        2. .moti 必须符合 XML 标准且拥有 scene 根结构
        3. large.png 与 small.png 必须存在且尺寸合法
        4. 所有标记了 fallback_png 的图层资源必须存在于 Media 目录中
        """
        # 1. 检查 .moti 文件
        moti_path = os.path.join(bundle_dir, f"{template_name}.moti")
        if not os.path.isfile(moti_path):
            raise FileNotFoundError(f"完整性校验失败: 未找到 Motion 文件 {moti_path}")
        
        moti_sz = os.path.getsize(moti_path)
        if moti_sz < 1024:
            raise ValueError(f"完整性校验失败: {template_name}.moti 文件大小仅 {moti_sz} 字节，小于最小安全阈值 1024 字节")

        try:
            tree = ET.parse(moti_path)
            root = tree.getroot()
            if root.tag != "ozml" or root.find("scene") is None:
                raise ValueError("完整性校验失败: .moti XML 缺少标准 ozml 或 scene 根节点")
        except Exception as e:
            raise ValueError(f"完整性校验失败: .moti 文件 XML 语法损坏: {str(e)}")

        # 2. 检查缩略图
        large_path = os.path.join(bundle_dir, "large.png")
        if not os.path.isfile(large_path) or os.path.getsize(large_path) == 0:
            raise FileNotFoundError(f"完整性校验失败: 缺少有效的大预览缩略图 {large_path}")

        small_path = os.path.join(bundle_dir, "small.png")
        if not os.path.isfile(small_path) or os.path.getsize(small_path) == 0:
            raise FileNotFoundError(f"完整性校验失败: 缺少有效的小预览缩略图 {small_path}")

        # 3. 检查降级 PNG 资源
        for info in layers_info:
            png_p = getattr(info, "fallback_png_path", None)
            if png_p and not os.path.isfile(png_p):
                raise FileNotFoundError(f"完整性校验失败: 降级图层 '{info.name}' 所需贴图不存在: {png_p}")
