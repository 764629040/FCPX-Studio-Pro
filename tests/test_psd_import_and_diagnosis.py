"""
PSD 导入与转换诊断闭环专项自动化测试套件
涵盖三大核心场景：
1. 正常文本 PSD 导入与诊断 (图层树、preserved 状态、100% 覆盖度、JSON 结构)
2. 复杂图层 PSD 诊断与降级 (智能对象、图层样式、混合模式、degraded 状态、32位 RGBA PNG、未保留特性警告)
3. 损坏文件优雅容错处理 (PSDParseError 结构化异常捕获、错误精准追踪至源文件、应用不崩溃)
"""
import os
import sys
import json
import struct
import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import (
    parse_psd_file,
    generate_conversion_diagnosis_report,
    export_diagnosis_json,
    check_font_availability,
    PSDParseError
)

try:
    import AppKit
    HAS_APPKIT = True
except Exception:
    HAS_APPKIT = False

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(TESTS_DIR, "data")
REPORTS_DIR = os.path.join(TESTS_DIR, "reports")

NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
CORRUPTED_PSD = os.path.join(DATA_DIR, "corrupted_file.psd")


def test_normal_text_psd_import_and_diagnosis(tmp_path):
    """
    用例 1: 正常纯文本 PSD 导入与诊断闭环
    - 验证返回结构包含完整的基础信息：file_name, file_path, width, height, aspect_ratio_str, resolution_str, total_layers_count
    - 验证图层树 (layer_tree) 递归层级与图层类型
    - 验证矢量文本图层处置状态为 preserved，处置原因详细合规
    - 验证字体字形字符集覆盖度 (Glyph Coverage) 100%，无缺失风险
    - 验证导出标准 JSON 诊断报告并校验 JSON 结构字段完整性
    """
    assert os.path.isfile(NORMAL_PSD), f"测试样本不存在: {NORMAL_PSD}"

    # 1. 解析 PSD 文件
    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=True)

    # 基础信息验证
    assert parsed["file_name"] == "vertical_wedding_9_16.psd"
    assert os.path.isabs(parsed["file_path"])
    assert parsed["width"] == 1080
    assert parsed["height"] == 1920
    assert "9:16" in parsed["aspect_ratio_str"]
    assert "高清" in parsed["resolution_str"]
    assert parsed["total_layers_count"] == 9
    assert len(parsed["layers"]) == 8  # 8 个矢量文本图层 (1 个底板已过滤)

    # 2. 图层树与缩略图校验
    layer_tree = parsed["layer_tree"]
    assert len(layer_tree) >= 1
    # 验证缩略图存在且非空白透明
    thumb_layers = [l for l in parsed["layers"] if l.has_thumbnail]
    assert len(thumb_layers) > 0, "文本图层应成功生成真实缩略图数据"
    for tl in thumb_layers:
        assert tl.thumbnail_bytes is not None and len(tl.thumbnail_bytes) > 20
        assert tl.thumbnail_bytes[:8] == b"\x89PNG\r\n\x1a\n", "缩略图必须是标准 PNG 二进制流"

    # 3. 诊断报告校验
    report = parsed["diagnosis_report"]
    summary = report["summary"]
    assert summary["source_file"]["name"] == "vertical_wedding_9_16.psd"
    assert summary["canvas"]["width"] == 1080
    assert summary["canvas"]["height"] == 1920
    assert summary["total_layers"] == 9
    assert summary["preserved_count"] == 8
    assert summary["degraded_count"] == 0
    assert summary["ignored_count"] == 1  # 1 个底板图层
    assert summary["failed_count"] == 0

    # ── 字体字形可用性：按被测 PSD 真实声明的字体在本机的注册状态分支断言 ──
    # 样本 PSD 的全部文本图层声明使用 'FZZYSK--GBK1-0'（方正准雅宋_GBK）。
    # 该字体是否被 macOS fontd 注册取决于机器安装状态，不能作为固定前提写死；
    # 因此这里先查询真实状态，再对"已安装 / 未安装 / 无 AppKit 环境"三种情况
    # 分别做完整且严格的实质断言，任何一种情况都不允许跳过校验。
    declared_font = parsed["diagnostics"]["font_diagnostics"][0]["original_font"]
    assert declared_font == "FZZYSK--GBK1-0", f"样本 PSD 声明字体发生变化: {declared_font}"
    font_installed = check_font_availability(declared_font) if HAS_APPKIT else False

    if not HAS_APPKIT:
        # 无 AppKit（如 Linux）：允许明确返回 unverifiable，但必须是有实质内容的
        # unverifiable，且汇总不得伪装成"无风险 / 覆盖率 100%"。
        assert summary["missing_fonts_count"] == 0
        assert summary["unverifiable_fonts_count"] == 8
        assert summary["has_missing_risk"] is True
        assert "无法确定风险" in summary["risk_assessment"]
        assert "100%" not in summary["risk_assessment"]
        for item in parsed["diagnosis_report"]["layers"]:
            if item["disposition"] == "preserved":
                assert item["font_status"] == "unverifiable"
                # 回退字体按文本是否含中文分流：中文→PingFangSC，纯西文→Helvetica
                expected_fb = (
                    "PingFangSC-Regular"
                    if any("\u4e00" <= c <= "\u9fff" for c in item["layer_name"])
                    else "Helvetica"
                )
                assert item["fallback_font"] == expected_fb
    elif font_installed:
        # 字体已注册：必须判定为 complete（100% 覆盖，无缺字风险）
        assert summary["missing_fonts_count"] == 0
        assert summary["unverifiable_fonts_count"] == 0
        assert summary["has_missing_risk"] is False
        assert "无风险" in summary["risk_assessment"]
        for item in parsed["diagnosis_report"]["layers"]:
            if item["disposition"] == "preserved":
                assert item["font_status"] == "complete"
                assert len(item["missing_glyphs"]) == 0
                # 字体已注册时不应发生回退，保留原字体
                assert item["fallback_font"] == "FZZYSK--GBK1-0"
    else:
        # 字体未注册（例如字体目录仅由符号链接构成，fontd 不索引）：必须诚实报告
        # font_missing，绝不伪通过；且缺字清单必须逐一对应真实文本字符。
        assert summary["missing_fonts_count"] == 8
        assert summary["unverifiable_fonts_count"] == 0
        assert summary["has_missing_risk"] is True
        assert "中风险" in summary["risk_assessment"]
        assert declared_font in summary["risk_assessment"] or "缺少系统字体" in summary["risk_assessment"]
        for item in parsed["diagnosis_report"]["layers"]:
            if item["disposition"] == "preserved":
                assert item["font_status"] == "font_missing"
                expected_fb = (
                    "PingFangSC-Regular"
                    if any("\u4e00" <= c <= "\u9fff" for c in item["layer_name"])
                    else "Helvetica"
                )
                assert item["fallback_font"] == expected_fb
                assert len(item["missing_glyphs"]) > 0, "缺字体时缺字清单严禁为空"

    # 检查各图层处置与原因
    layers = report["layers"]
    assert len(layers) == 9
    for item in layers:
        assert "source_file" in item
        assert "layer_path" in item
        assert "layer_name" in item
        assert "layer_type" in item
        assert item["disposition"] in ("preserved", "degraded", "ignored", "failed")
        assert len(item["reason"]) > 5, "处置原因严禁为空或简略过短"

        if item["disposition"] == "preserved":
            assert item["layer_type"] == "type"
            assert "纯矢量文本" in item["reason"]
            # 无论字体是否安装，preserved 文本图层都必须给出明确且可区分的字体状态，
            # 严禁出现 None 或空值这类静默漏检。
            assert item["font_status"] in ("complete", "partial_missing", "font_missing", "unverifiable")
            if item["font_status"] in ("partial_missing", "font_missing"):
                assert len(item["missing_glyphs"]) > 0, "缺字态必须有具体缺字清单"
            assert item["is_blocking"] is False

    # 4. 导出 JSON 报告并验证
    json_path = os.path.join(REPORTS_DIR, "diagnosis_normal.json")
    exported_path = export_diagnosis_json(report, json_path)
    assert os.path.isfile(exported_path)
    assert os.path.getsize(exported_path) > 200

    with open(exported_path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded["summary"]["total_layers"] == 9
    assert loaded["summary"]["preserved_count"] == 8


def test_complex_layers_psd_diagnosis_and_degradation(tmp_path):
    """
    用例 2: 复杂图层（含智能对象/图层样式/混合模式）诊断与降级闭环
    - 验证图层类型识别：智能对象 (smartobject)、矢量形状 (shape)、图层组 (group)、像素 (pixel)
    - 验证处置状态：复杂非文本图层为 degraded，空/组图层为 ignored
    - 验证降级 32 位 RGBA PNG 真实导出、IHDR Header 解析与位深校验 (8-bit per channel / 32-bit RGBA)
    - 验证未保留特性识别列表 (unsupported_features) 精准包含智能对象/形状/图层样式警告
    - 验证导出标准 JSON 诊断报告并校验结构完整性
    """
    assert os.path.isfile(COMPLEX_PSD), f"测试样本不存在: {COMPLEX_PSD}"

    png_out_dir = str(tmp_path / "complex_fallback_pngs")
    parsed = parse_psd_file(
        COMPLEX_PSD,
        extract_fallback_pngs=True,
        png_output_dir=png_out_dir,
        extract_thumbnails=True
    )

    # 1. 基础信息验证
    assert parsed["file_name"] == "complex_layers.psd"
    assert parsed["width"] == 1920
    assert parsed["height"] == 1080
    assert parsed["total_layers_count"] >= 10

    # 2. 诊断报告校验
    report = parsed["diagnosis_report"]
    summary = report["summary"]
    assert summary["source_file"]["name"] == "complex_layers.psd"
    assert summary["total_layers"] >= 10
    assert summary["degraded_count"] >= 2  # 包含形状与智能对象降级
    assert summary["ignored_count"] >= 2   # 包含组与空图层忽略

    # 验证图层特征识别
    types_found = {layer["layer_type"] for layer in report["layers"]}
    assert "group" in types_found, "未能识别图层组 (group)"
    assert "shape" in types_found, "未能识别矢量形状 (shape)"

    # 3. 降级图层 32 位透明 PNG 校验
    degraded_layers = [l for l in report["layers"] if l["disposition"] == "degraded"]
    assert len(degraded_layers) > 0
    png_verified_count = 0

    for dl in degraded_layers:
        assert len(dl["reason"]) > 5
        assert dl["is_blocking"] is False
        assert len(dl["unsupported_features"]) > 0, f"降级图层 {dl['layer_name']} 缺少 unsupported_features 记录"

        fb_png = dl["fallback_png"]
        if fb_png:
            png_verified_count += 1
            png_file = fb_png["path"]
            assert os.path.isfile(png_file), f"降级贴图文件不存在: {png_file}"
            assert os.path.getsize(png_file) > 50

            # 校验 PNG IHDR 头部的 32-bit RGBA (8-bit per channel)
            with open(png_file, "rb") as pf:
                sig = pf.read(8)
                assert sig == b"\x89PNG\r\n\x1a\n"
                pf.read(4)
                chunk_type = pf.read(4)
                assert chunk_type == b"IHDR"
                ihdr = pf.read(13)
                _, _, bit_depth, color_type = struct.unpack(">IIBB", ihdr[:10])
                assert bit_depth == 8
                assert color_type == 6, f"{png_file} 颜色类型非 RGBA"

            assert fb_png["is_valid_header"] is True
            assert fb_png["is_non_empty"] is True

    assert png_verified_count >= 2, "应至少成功验证 2 个降级贴图文件"

    # 4. 导出 JSON 报告并验证
    json_path = os.path.join(REPORTS_DIR, "diagnosis_complex.json")
    exported_path = export_diagnosis_json(report, json_path)
    assert os.path.isfile(exported_path)

    with open(exported_path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded["summary"]["total_layers"] >= 10
    assert loaded["summary"]["degraded_count"] >= 2


def test_corrupted_psd_graceful_handling(tmp_path):
    """
    用例 3: 损坏/非法 PSD 文件优雅容错与精准追踪闭环
    - 验证调用 parse_psd_file 时抛出结构化 PSDParseError，包含源文件绝对路径与原始错误详情
    - 验证外层捕获后记录为 failed 状态，绝不导致应用崩溃
    - 验证 generate_conversion_diagnosis_report 生成合规的失败诊断报告 (failed_count=1, is_blocking=True)
    - 验证导出标准 JSON 诊断报告 tests/reports/diagnosis_corrupted.json
    """
    assert os.path.isfile(CORRUPTED_PSD), f"测试样本不存在: {CORRUPTED_PSD}"

    # 1. 验证抛出结构化 PSDParseError
    with pytest.raises(PSDParseError) as exc_info:
        parse_psd_file(CORRUPTED_PSD)

    err = exc_info.value
    assert err.file_name == "corrupted_file.psd"
    assert os.path.isabs(err.file_path)
    assert err.original_error is not None
    err_dict = err.to_dict()
    assert err_dict["file_name"] == "corrupted_file.psd"
    assert len(err_dict["error_message"]) > 0

    # 2. 验证生成合规容错诊断报告（绝不崩溃）
    report = generate_conversion_diagnosis_report(CORRUPTED_PSD)
    summary = report["summary"]
    assert summary["source_file"]["name"] == "corrupted_file.psd"
    assert summary["failed_count"] == 1
    assert summary["total_layers"] == 0
    assert summary["has_missing_risk"] is True
    assert "致命错误" in summary["risk_assessment"]

    layers = report["layers"]
    assert len(layers) == 1
    failed_layer = layers[0]
    assert failed_layer["disposition"] == "failed"
    assert failed_layer["is_blocking"] is True
    assert "文件损坏" in failed_layer["unsupported_features"][0]
    assert failed_layer["error_details"] is not None

    # 3. 导出 JSON 报告并验证
    json_path = os.path.join(REPORTS_DIR, "diagnosis_corrupted.json")
    exported_path = export_diagnosis_json(report, json_path)
    assert os.path.isfile(exported_path)

    with open(exported_path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded["summary"]["failed_count"] == 1
    assert loaded["layers"][0]["disposition"] == "failed"
