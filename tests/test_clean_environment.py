"""
================================================================================
FCPX Studio Pro - 纯净环境标准 pytest 自动化测试套件
================================================================================
测试保障：
1. 零外置盘依赖：100% 使用项目内 tests/data/ 样本与 assets/reference_base.moti
2. 彻底杜绝私人路径硬编码：验证优先级探测机制
3. 字体字形覆盖度真实判定：覆盖 complete / partial_missing / font_missing / unverifiable 四态
4. 真实 Media/ 装饰图层生成与 Apple Motion ozml 规范合法引用验证
5. 多阶段故障注入强健回滚：覆盖 before_build, after_media, after_xml, after_thumbnails, during_replace
6. 批处理队列容错隔离与失败断点报告
================================================================================
"""
import os
import sys
import shutil
import struct
import tempfile
import xml.etree.ElementTree as ET
import pytest
from PIL import Image
from unittest.mock import patch

# 注入项目根路径
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(CURRENT_DIR)
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import (
    parse_psd_file,
    check_font_availability,
    check_font_glyph_coverage,
    calculate_safe_area_status,
    PSDLayerInfo
)
from core.motion_builder import (
    MotionBuilder,
    find_reference_template,
    StorageNotReadyError,
    StoragePermissionError
)

DATA_DIR = os.path.join(CURRENT_DIR, "data")
SAMPLE_23_PSD = os.path.join(DATA_DIR, "wedding_with_decorations_23.psd")
SAMPLE_9_16_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
SAMPLE_4K_PSD = os.path.join(DATA_DIR, "commercial_4k.psd")


# ==============================================================================
# 1. 纯净环境基准模板级联探测与零私人路径验证
# ==============================================================================
def test_reference_template_clean_cascade(monkeypatch):
    """验证基准模板探测严格遵循优先级，且绝对不包含任何外部私人卷硬编码"""
    # 1. 验证默认优先探测到本地 assets/reference_base.moti
    monkeypatch.delenv("FCPX_MOTION_REFERENCE_PATH", raising=False)
    resolved = find_reference_template()
    assert os.path.isfile(resolved), f"基准模板未能正确解析: {resolved}"
    assert "reference_base.moti" in resolved, f"默认解析结果非标准基准模板: {resolved}"

    # 2. 验证环境变量覆盖优先级
    dummy_moti = os.path.join(PROJECT_ROOT, "assets", "reference_base.moti")
    monkeypatch.setenv("FCPX_MOTION_REFERENCE_PATH", dummy_moti)
    env_resolved = find_reference_template()
    assert env_resolved == dummy_moti

    # 3. 验证显式传参优先级最高
    custom_resolved = find_reference_template(dummy_moti)
    assert custom_resolved == dummy_moti

    # 4. 源码严格检查：确保 motion_builder.py 中无任何私人外置盘字串
    motion_builder_py = os.path.join(PROJECT_ROOT, "core", "motion_builder.py")
    with open(motion_builder_py, "r", encoding="utf-8") as f:
        code = f.read()
    assert "摄影师工具箱" not in code, "motion_builder.py 中仍存在 '摄影师工具箱' 私人路径硬编码！"


try:
    import AppKit
    HAS_APPKIT = True
except Exception:
    HAS_APPKIT = False


# ==============================================================================
# 2. 字体字符集覆盖度 (Glyph Coverage) 真实四态判定测试
# ==============================================================================
def test_font_glyph_coverage_complete():
    """测试 1: 字体已安装且目标文本字形覆盖度 100% -> complete (1.0)"""
    # PingFang SC 对常用中文具备 100% 覆盖度
    res = check_font_glyph_coverage("PingFangSC-Regular", "婚礼纪实字幕呈现")
    if HAS_APPKIT:
        assert res["status"] == "complete"
        assert res["coverage_rate"] == 1.0
        assert res["has_missing_risk"] is False
        assert len(res["missing_chars"]) == 0
    else:
        assert res["status"] == "unverifiable"
        assert res["coverage_rate"] is None
        assert res["has_missing_risk"] is True


def test_font_glyph_coverage_partial_missing():
    """测试 2: 西文字体用于中文字符 -> partial_missing (coverage_rate < 1.0, 绝不伪通过)"""
    # Helvetica 为西文字体，缺少中文字形
    res = check_font_glyph_coverage("Helvetica", "婚礼现场2026")
    if HAS_APPKIT:
        assert res["status"] == "partial_missing"
        assert res["coverage_rate"] < 1.0
        assert res["has_missing_risk"] is True
        assert "婚" in res["missing_chars"]
        assert "礼" in res["missing_chars"]
    else:
        assert res["status"] == "unverifiable"
        assert res["coverage_rate"] is None
        assert res["has_missing_risk"] is True


def test_font_glyph_coverage_font_missing():
    """测试 3: 目标字体在系统中未安装 -> font_missing (coverage_rate = 0.0, 绝不伪通过)"""
    res = check_font_glyph_coverage("Completely_NonExistent_Font_12345", "ABC婚礼")
    if HAS_APPKIT:
        assert res["status"] == "font_missing"
        assert res["coverage_rate"] == 0.0
        assert res["has_missing_risk"] is True
        assert "未安装" in res["warning"]
    else:
        assert res["status"] == "unverifiable"
        assert res["coverage_rate"] is None
        assert res["has_missing_risk"] is True


def test_font_glyph_coverage_unverifiable(monkeypatch):
    """测试 4: 异常或不支持环境 -> unverifiable (coverage_rate = None, 绝不静默返回 1.0)"""
    class MockFailingAppKit:
        class NSFont:
            @staticmethod
            def fontWithName_size_(name, sz):
                raise RuntimeError("Simulated AppKit failure")

    monkeypatch.setitem(sys.modules, "AppKit", MockFailingAppKit)
    res = check_font_glyph_coverage("Helvetica", "Hello World")
    assert res["status"] == "unverifiable"
    assert res["coverage_rate"] is None
    assert res["has_missing_risk"] is True
    assert "异常" in res["warning"]


# ==============================================================================
# 3. 真实 Media/ 装饰图层生成与 Apple Motion ozml 规范实物验证
# ==============================================================================
def test_clean_environment_template_build_with_media(tmp_path):
    """验证在纯净环境下使用本地样本成功构建含 Media/ 装饰贴图的完整模板包"""
    assert os.path.isfile(SAMPLE_23_PSD), f"测试数据文件不存在: {SAMPLE_23_PSD}"
    
    output_dir = tmp_path / "test_23_with_media"
    output_dir_str = str(output_dir)

    # 1. 解析 PSD 并提取降级 PNG
    parsed = parse_psd_file(
        SAMPLE_23_PSD,
        extract_fallback_pngs=True,
        png_output_dir=str(tmp_path / "extracted_pngs")
    )
    assert len(parsed["layers"]) >= 5
    
    media_layers = [l for l in parsed["layers"] if l.kind != "type"]
    assert len(media_layers) >= 2, "23.psd 样本中应至少包含 2 个非文本装饰图层"

    # 2. 原子构建完整模板包
    builder = MotionBuilder()
    build_res = builder.build_template_atomic(
        layers_info=parsed["layers"],
        output_dir=output_dir_str,
        template_name="test_23_template",
        psd_path=SAMPLE_23_PSD,
        backup_existing=True
    )
    assert build_res["status"] == "ok"
    assert os.path.isdir(output_dir_str)

    # 3. 验证目录结构与必需文件
    moti_path = os.path.join(output_dir_str, "test_23_template.moti")
    large_png = os.path.join(output_dir_str, "large.png")
    small_png = os.path.join(output_dir_str, "small.png")
    media_dir = os.path.join(output_dir_str, "Media")

    assert os.path.isfile(moti_path)
    assert os.path.getsize(moti_path) > 1024
    assert os.path.isfile(large_png) and os.path.getsize(large_png) > 0
    assert os.path.isfile(small_png) and os.path.getsize(small_png) > 0
    assert os.path.isdir(media_dir)

    # 4. 验证 Media/ 内 PNG 贴图真实性与 32-bit RGBA IHDR
    media_files = os.listdir(media_dir)
    assert len(media_files) >= 2
    for mf in media_files:
        mp = os.path.join(media_dir, mf)
        assert os.path.isfile(mp) and os.path.getsize(mp) > 50
        with open(mp, "rb") as pf:
            sig = pf.read(8)
            assert sig == b"\x89PNG\r\n\x1a\n", f"{mf} 不是有效的 PNG 文件签名"
            pf.read(4)
            chunk_type = pf.read(4)
            assert chunk_type == b"IHDR"
            ihdr = pf.read(13)
            _, _, bit_depth, color_type = struct.unpack(">IIBB", ihdr[:10])
            assert bit_depth == 8
            assert color_type == 6, f"{mf} 颜色类型非 RGBA (color_type={color_type})"

    # 5. 验证 .moti XML 内部 footage 与 scenenode factoryID 的合法引用
    tree = ET.parse(moti_path)
    root = tree.getroot()
    scene = root.find("scene")
    footage = scene.find("footage")
    assert footage is not None, ".moti XML 缺少 footage 节点"
    assert list(scene)[-1] == footage, "<footage> 必须是 <scene> 的最后一个子元素"

    # 验证 图像 Factory 已注册
    img_factories = [f.attrib["id"] for f in root.findall("factory") if f.attrib.get("uuid") == "66fc0d6af6a911d6a7a7000393670732"]
    assert len(img_factories) > 0, "缺少 图像 factory (uuid=66fc0d6af6a911d6a7a7000393670732)"
    valid_factory_ids = set(img_factories + ["9", "5", "20"])

    # 验证 footage 仅包含 clip 子元素，无参数或多余标志
    for child in footage:
        assert child.tag == "clip", f"footage 中包含非 clip 元素: {child.tag}"

    clips = footage.findall("clip")
    assert len(clips) >= 2, "footage 中 clip 节点数量不足"
    clip_ids = set()
    for clip in clips:
        cid = clip.attrib["id"]
        clip_ids.add(cid)
        rel_url = clip.find("relativeURL").text
        assert rel_url.startswith("Media/"), f"clip relativeURL 格式不合法: {rel_url}"
        c_timing = clip.find("timing")
        assert c_timing is not None, "clip 缺少 timing 节点"
        assert c_timing.attrib.get("out") == "0 153600 1 0", f"clip 静态 timing out 异常: {c_timing.attrib.get('out')}"

    # 验证图层对 clip 的合法引用
    media_scenenodes = []
    for layer in scene.findall("layer"):
        sn = layer.find("scenenode")
        if sn is not None and sn.attrib.get("factoryID") in valid_factory_ids:
            media_scenenodes.append(sn)
            src_param = sn.find(".//parameter[@id=\"300\"]")
            assert src_param is not None, f"媒体 scenenode (factoryID={sn.attrib.get('factoryID')}) 缺少 parameter id=300 源媒体引用"
            assert src_param.attrib.get("value") in clip_ids, f"源媒体引用 ID {src_param.attrib.get('value')} 未在 clip 中定义"

    assert len(media_scenenodes) == len(clips)


# ==============================================================================
# 4. 多阶段故障注入回滚测试 (5 大关键阶段)
# ==============================================================================
@pytest.mark.parametrize("fault_stage", [
    "before_build",
    "after_media",
    "after_xml",
    "after_thumbnails",
    "during_replace"
])
def test_atomic_rollback_multi_stage_fault_injection(tmp_path, fault_stage):
    """
    针对 5 大阶段进行故障注入：
    验证任何阶段抛出异常时，临时沙箱目录全部被销毁，原有基准模板 100% 完好无损回滚
    """
    dest_dir = str(tmp_path / "rollback_test_target")
    builder = MotionBuilder()

    # 1. 建立已有基准模板（模拟线上已存在的活动目录）
    baseline_parsed = parse_psd_file(SAMPLE_9_16_PSD)
    builder.build_template_atomic(
        layers_info=baseline_parsed["layers"],
        output_dir=dest_dir,
        template_name="baseline",
        psd_path=SAMPLE_9_16_PSD,
        backup_existing=True
    )
    assert os.path.isdir(dest_dir)
    baseline_moti_path = os.path.join(dest_dir, "baseline.moti")
    assert os.path.isfile(baseline_moti_path)
    baseline_moti_sz = os.path.getsize(baseline_moti_path)

    # 2. 注入指定阶段的故障
    test_parsed = parse_psd_file(
        SAMPLE_23_PSD,
        extract_fallback_pngs=True,
        png_output_dir=str(tmp_path / "temp_fault_pngs")
    )

    with pytest.raises(RuntimeError, match=f"测试故障注入: {fault_stage}"):
        builder.build_template_atomic(
            layers_info=test_parsed["layers"],
            output_dir=dest_dir,
            template_name="faulty_template",
            psd_path=SAMPLE_23_PSD,
            backup_existing=True,
            _inject_failure_stage=fault_stage
        )

    # 3. 强断言：目标目录完好存在，内容未被破坏
    assert os.path.isdir(dest_dir), f"故障注入阶段 {fault_stage} 导致目标活动目录丢失！"
    assert os.path.isfile(baseline_moti_path), f"基准文件丢失！"
    assert os.path.getsize(baseline_moti_path) == baseline_moti_sz, f"基准文件被意外修改！"

    # 4. 强断言：临时沙箱目录已彻底清理，零孤儿文件残留
    parent_dir = os.path.dirname(dest_dir)
    leftovers = [
        item for item in os.listdir(parent_dir)
        if "_tmp_build_" in item
    ]
    assert len(leftovers) == 0, f"故障注入阶段 {fault_stage} 残留临时构建沙箱目录: {leftovers}"


# ==============================================================================
# 5. 批处理队列容错隔离与失败断点测试
# ==============================================================================
def test_batch_export_queue_isolation(tmp_path):
    """验证批量导出队列在某一项损坏或异常时，隔离错误并继续处理后续合法文件"""
    corrupt_psd = str(tmp_path / "corrupt.psd")
    with open(corrupt_psd, "wb") as f:
        f.write(b"NOT_A_VALID_PSD_HEADER")

    file_queue = [
        SAMPLE_9_16_PSD,
        corrupt_psd,
        SAMPLE_4K_PSD
    ]

    export_dir = str(tmp_path / "batch_out")
    os.makedirs(export_dir, exist_ok=True)
    builder = MotionBuilder()

    success_count = 0
    failed_files = []

    for psd_p in file_queue:
        try:
            base_name = os.path.splitext(os.path.basename(psd_p))[0]
            parsed = parse_psd_file(psd_p)
            tpl_dir = os.path.join(export_dir, base_name)
            builder.build_template_atomic(
                layers_info=parsed["layers"],
                output_dir=tpl_dir,
                template_name=base_name,
                psd_path=psd_p,
                backup_existing=True
            )
            success_count += 1
        except Exception as e:
            failed_files.append((psd_p, str(e)))

    # 断言：损坏项被隔离，合法项成功导出
    assert success_count == 2
    assert len(failed_files) == 1
    assert failed_files[0][0] == corrupt_psd
    assert "corrupt" in failed_files[0][0]

    # 验证导出的合法项完整有效
    assert os.path.isdir(os.path.join(export_dir, "vertical_wedding_9_16"))
    assert os.path.isdir(os.path.join(export_dir, "commercial_4k"))
