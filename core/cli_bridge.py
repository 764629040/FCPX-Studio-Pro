#!/usr/bin/env python3
"""
CLI 桥接模块 (Socket Bridge - 稳健原子版)
为 macOS 原生工程提供极速 JSON 协议通信接口：
1. parse <psd_file>: 解析并返回图层 JSON、画幅规格与详尽诊断报告 (包含字体三元组诊断与降级信息)
2. build <config_json_file>: 执行完整的临时目录沙箱构建、严格完整性校验、时间戳备份与原子级替换提交流程
"""
import sys
import os
import json
import time
import shutil
import hashlib
import tempfile
import traceback

# UI-O026: 增加日志落盘能力，确保错误堆栈与执行全过程可查
def _write_build_log(content: str) -> str:
    log_dir = os.path.expanduser("~/Library/Logs/FCPXStudio")
    os.makedirs(log_dir, exist_ok=True)
    ts = int(time.time())
    log_path = os.path.join(log_dir, f"build_{ts}.log")
    try:
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(content)
        return log_path
    except Exception:
        return ""

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

from core.psd_parser import parse_psd_file, PSDLayerInfo
from core.motion_builder import MotionBuilder


def media_output_dir(psd_path: str) -> str:
    """R33 / A-68 / UI-G054：为一次解析准备稳定的贴图输出目录。

    目录键由「绝对路径 + mtime + 大小 + 进程 PID」决定，保证并发解析同一 PSD 时
    各个进程拥有独立的贴图目录，互不覆盖冲撞。放在系统临时目录下，
    不会污染用户素材目录。
    """
    try:
        st = os.stat(psd_path)
        key_src = f"{os.path.abspath(psd_path)}|{st.st_mtime_ns}|{st.st_size}|{os.getpid()}"
    except OSError:
        key_src = f"{os.path.abspath(psd_path)}|{os.getpid()}"
    key = hashlib.sha1(key_src.encode("utf-8", "replace")).hexdigest()[:16]
    base = os.path.join(tempfile.gettempdir(), "FCPXStudioPSDMedia")
    os.makedirs(base, exist_ok=True)
    # 顺手清理 7 天前的旧目录（失败不影响解析）
    now = time.time()
    try:
        for name in os.listdir(base):
            old = os.path.join(base, name)
            if os.path.isdir(old) and now - os.path.getmtime(old) > 7 * 86400:
                shutil.rmtree(old, ignore_errors=True)
    except OSError:
        pass
    out = os.path.join(base, key)
    os.makedirs(out, exist_ok=True)
    return out


def handle_parse(psd_path: str, include_hidden: bool = False):
    if not os.path.exists(psd_path):
        print(json.dumps({"status": "error", "message": f"文件不存在: {psd_path}"}, ensure_ascii=False))
        sys.exit(1)
    
    try:
        # R33 / A-68：桥接层必须显式启用 PNG 导出并给出目录。
        # R32 之前这里只传 psd_path，导致 extract_fallback_pngs=False、
        # png_output_dir=None，所有位图层都没有贴图，画布自然全黑。
        parsed = parse_psd_file(
            psd_path,
            extract_fallback_pngs=True,
            png_output_dir=media_output_dir(psd_path),
            include_hidden=include_hidden,
            # R33：原生壳的 LayerModel 不消费缩略图，而逐层缩略图对 2848×1600
            # 的 13 层照片稿要花 44s（实测 61s → 17s）。桥接显式关闭，避免
            # 大 PSD 在 60s 超时线附近被误判为“解析超时”。
            extract_thumbnails=False,
        )
        layers_data = [l.to_dict() for l in parsed["layers"]]
        summary = parsed.get("diagnosis_report", {}).get("summary", {})
        result = {
            "status": "ok",
            "width": parsed["width"],
            "height": parsed["height"],
            "aspect_ratio": parsed["aspect_ratio"],
            "resolution_spec": parsed["resolution_spec"],
            "layer_count": parsed["layer_count"],
            "input_layer_count": parsed.get("input_layer_count", 0),
            "output_layer_count": parsed.get("output_layer_count", 0),
            "skipped_layer_count": parsed.get("skipped_layer_count", 0),
            "preview_layer_count": parsed.get("preview_layer_count", 0),
            "hidden_layer_count": parsed.get("hidden_layer_count", 0),
            "ignored_summary": parsed.get("ignored_summary", ""),
            "include_hidden": parsed.get("include_hidden", include_hidden),
            "layer_conservation": parsed.get("layer_conservation", {}),
            "summary": summary,
            "background_preview": parsed.get("background_preview"),
            "original_composite_path": parsed.get("original_composite_path"),
            "layers": layers_data,
            "diagnostics": parsed["diagnostics"]
        }
        print(json.dumps(result, ensure_ascii=False))
    except Exception as e:
        tb = traceback.format_exc()
        log_path = _write_build_log(f"parse error: {str(e)}\n\n{tb}")
        err_resp = {"status": "error", "message": f"解析 PSD 异常: {str(e)}"}
        if log_path:
            err_resp["log_path"] = log_path
        print(json.dumps(err_resp, ensure_ascii=False))
        sys.exit(1)

def handle_build(payload_json_file: str):
    if not os.path.exists(payload_json_file):
        print(json.dumps({"status": "error", "message": f"构建配置 JSON 不存在: {payload_json_file}"}, ensure_ascii=False))
        sys.exit(1)

    try:
        with open(payload_json_file, "r", encoding="utf-8") as f:
            data = json.load(f)

        psd_path = data.get("psd_path", "")
        if "output_dir" not in data or not str(data["output_dir"]).strip():
            print(json.dumps({"status": "error", "message": "构建配置缺少必填字段 output_dir"}, ensure_ascii=False))
            sys.exit(1)
        output_dir = str(data["output_dir"]).strip()

        if "template_name" not in data or not str(data["template_name"]).strip():
            print(json.dumps({"status": "error", "message": "构建配置缺少必填字段 template_name"}, ensure_ascii=False))
            sys.exit(1)
        template_name = str(data["template_name"]).strip()

        # UI-G052: 校验 template_name 不得包含 /、\、.. 或超过 255 字符
        if any(bad in template_name for bad in ["/", "\\", ".."]) or len(template_name) > 255:
            print(json.dumps({"status": "error", "message": f"非法的模板名称「{template_name}」：名称禁止包含路径字符（/、\\、..）且长度不得超过 255 字符"}, ensure_ascii=False))
            sys.exit(1)

        layers_raw = data.get("layers", [])
        if not layers_raw:
            print(json.dumps({"status": "error", "message": "layers 列表为空，无法构建无图层的空白模板"}, ensure_ascii=False))
            sys.exit(1)

        layers_info = []
        for d in layers_raw:
            raw_bbox = d.get("psd_bbox", (0, 0, 0, 0))
            if isinstance(raw_bbox, (list, tuple)) and len(raw_bbox) == 4:
                psd_bbox = tuple(float(x) for x in raw_bbox)
            else:
                psd_bbox = (0.0, 0.0, 0.0, 0.0)

            raw_pos = d.get("motion_pos", (0, 0))
            if isinstance(raw_pos, (list, tuple)) and len(raw_pos) >= 2:
                motion_pos = (float(raw_pos[0]), float(raw_pos[1]))
            elif isinstance(raw_pos, (list, tuple)) and len(raw_pos) == 1:
                motion_pos = (float(raw_pos[0]), 0.0)
            else:
                motion_pos = (0.0, 0.0)

            info = PSDLayerInfo(
                index=d.get("index", 1),
                name=d.get("name", ""),
                kind=d.get("kind", "type"),
                text=d.get("text", ""),
                font_name=d.get("font_name", "Helvetica"),
                font_size=float(d.get("font_size", 36.0)),
                tracking=float(d.get("tracking", 0.0)),
                psd_bbox=psd_bbox,
                motion_pos=motion_pos,
                visible=bool(d.get("visible", True)),
                is_published=bool(d.get("is_published", True)),
                rotation=float(d.get("rotation", 0.0)),
                scale_x=float(d.get("scale_x", 1.0)),
                scale_y=float(d.get("scale_y", 1.0)),
                opacity=float(d.get("opacity", 1.0)),
                writing_direction=d.get("writing_direction", "vertical"),
                fallback_png_path=d.get("fallback_png_path", None),
                fallback_png_info=d.get("fallback_png_info", None),
                font_info=d.get("font_info", None),
                diagnostic_notes=d.get("diagnostic_notes", []),
                alignment=d.get("alignment", "center"),
                line_spacing=float(d.get("line_spacing", 1.0))
            )
            if "published_channels" in d:
                info.published_channels = d["published_channels"]
            layers_info.append(info)

        # 调用原子构建流程 (包含临时沙箱构建、校验、备份、原子移动及异常自动回滚)
        builder = MotionBuilder()
        build_result = builder.build_template_atomic(
            layers_info=layers_info,
            output_dir=output_dir,
            template_name=template_name,
            psd_path=psd_path if (psd_path and os.path.exists(psd_path)) else None,
            backup_existing=True
        )

        resp = {
            "status": "ok",
            "moti_path": build_result["moti_path"],
            "large_png": build_result["large_png"],
            "small_png": build_result["small_png"],
            "backup_path": build_result.get("backup_path"),
            "output_dir": output_dir
        }
        print(json.dumps(resp, ensure_ascii=False))
    except KeyError as e:
        field = str(e).strip("'\"")
        tb = traceback.format_exc()
        log_path = _write_build_log(f"KeyError: {field}\n\n{tb}")
        err_resp = {"status": "error", "message": f"构建配置缺少必填字段 {field}"}
        if log_path:
            err_resp["log_path"] = log_path
        print(json.dumps(err_resp, ensure_ascii=False))
        sys.exit(1)
    except Exception as e:
        tb = traceback.format_exc()
        log_path = _write_build_log(f"Exception: {str(e)}\n\n{tb}")
        err_resp = {"status": "error", "message": f"生成模板失败: {str(e)}"}
        if log_path:
            err_resp["log_path"] = log_path
        print(json.dumps(err_resp, ensure_ascii=False))
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: cli_bridge.py parse <psd_file> OR cli_bridge.py build <json_file>")
        sys.exit(1)

    cmd = sys.argv[1]
    arg = sys.argv[2]
    flags = set(sys.argv[3:])
    if cmd == "parse":
        # R33 / A-70：--include-hidden 只影响「预览列表」，不改变转换口径。
        handle_parse(arg, include_hidden=("--include-hidden" in flags))
    elif cmd == "build":
        handle_build(arg)
    else:
        print(json.dumps({"status": "error", "message": f"未知命令: {cmd}"}, ensure_ascii=False))
        sys.exit(1)
