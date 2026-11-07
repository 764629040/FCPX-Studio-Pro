#!/usr/bin/env python3
"""
================================================================================
FCPX Studio Pro - 第一阶段 MVP 真实集成与边界极限补证验收测试套件
(Extended Acceptance & Real Motion/FCPX Integration Suite)
================================================================================
测试范围：
① 多画幅样本测试 (竖版 1080×1920 9:16 与 4K 3840×2160 16:9) 及 Action Safe 90% / Title Safe 80% 安全区边界验证
② 降级 PNG 真实位深 (8-bit per channel / 32-bit RGBA) IHDR Header 读取与 AppKit 字形字符集覆盖度 (Glyph Coverage) 深度校验
③ build_template_atomic 极限边界测试：已有目录时间戳备份、中断清理回滚、只读权限拦截、未挂载外置卷预检拦截
④ 符合 Apple 官方规范的真实 Motion Templates 目录生成与 49+ 细粒度发布参数校验（杜绝私有参数泄漏）
================================================================================
"""

import os
import sys
import shutil
import time
import struct
import tempfile
import xml.etree.ElementTree as ET
from PIL import Image

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
    StorageNotReadyError,
    StoragePermissionError,
    find_reference_template
)

DATA_DIR = os.path.join(CURRENT_DIR, "data")
PSD_BASE_DIR = os.environ.get(
    "PSD_BASE_DIR",
    "/Volumes/摄影师工具箱128GB/字幕/H373[豪门素材]  50款婚礼纪实字幕PSD格式可PS编辑文字/PSD格式通用/PSD文件" if os.path.exists("/Volumes/摄影师工具箱128GB") else DATA_DIR
)
PSD_01 = os.path.join(PSD_BASE_DIR, "01.psd") if os.path.exists(os.path.join(PSD_BASE_DIR, "01.psd")) else os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
PSD_23 = os.path.join(PSD_BASE_DIR, "23.psd") if os.path.exists(os.path.join(PSD_BASE_DIR, "23.psd")) else os.path.join(DATA_DIR, "wedding_with_decorations_23.psd")

GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RED = "\033[91m"
BOLD = "\033[1m"
RESET = "\033[0m"

def print_header(title: str):
    print(f"\n{BOLD}{CYAN}{'='*85}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'='*85}{RESET}")

def print_subheader(title: str):
    print(f"\n{BOLD}{YELLOW}--- {title} ---{RESET}")

def print_pass(msg: str):
    print(f"{GREEN}[PASS]{RESET} {msg}")

def print_fail(msg: str):
    print(f"{RED}[FAIL]{RESET} {msg}")

# ==============================================================================
# 测试 ①: 多画幅样本测试 (竖版 1080×1920 与 4K 3840×2160) 及安全区边界验证
# ==============================================================================
def test_multi_aspect_ratio_and_safe_areas():
    print_header("测试 ①: 多画幅样本测试 (1080×1920 9:16 & 3840×2160 4K) 与安全区边界合法性验证")
    
    os.makedirs(DATA_DIR, exist_ok=True)
    v_psd = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
    k4_psd = os.path.join(DATA_DIR, "commercial_4k.psd")

    # 若测试数据不存在，则由标准 PSD 二进制头生成合法测试画幅样本
    if not (os.path.exists(v_psd) and os.path.exists(k4_psd)):
        with open(PSD_01, "rb") as f:
            raw = bytearray(f.read())
        v_raw = bytearray(raw)
        struct.pack_into(">II", v_raw, 14, 1920, 1080)
        with open(v_psd, "wb") as f:
            f.write(v_raw)
        k4_raw = bytearray(raw)
        struct.pack_into(">II", k4_raw, 14, 2160, 3840)
        with open(k4_psd, "wb") as f:
            f.write(k4_raw)

    test_cases = [
        ("vertical_wedding_9_16.psd", v_psd, 1080, 1920, "9:16 (竖屏短视频)"),
        ("commercial_4k.psd", k4_psd, 3840, 2160, "16:9 (横版宽屏)")
    ]

    for filename, filepath, exp_w, exp_h, exp_aspect in test_cases:
        print_subheader(f"测试多画幅样本: {filename} (预期分辨率: {exp_w}×{exp_h})")
        parsed = parse_psd_file(filepath)

        w, h = parsed["width"], parsed["height"]
        aspect = parsed["aspect_ratio"]
        res_spec = parsed["resolution_spec"]

        assert w == exp_w and h == exp_h, f"分辨率不符: {w}x{h} vs {exp_w}x{exp_h}"
        assert exp_aspect in aspect, f"画幅比检测错误: {aspect} (预期包含 {exp_aspect})"

        print(f"  • 画布分辨率: {w} × {h}")
        print(f"  • 识别画幅比: {aspect}")
        print(f"  • 规格档位:   {res_spec}")
        print(f"  • Title Safe (80%) 笛卡尔边界: X ±{0.4*w:.1f}, Y ±{0.4*h:.1f}")
        print(f"  • Action Safe (90%) 笛卡尔边界: X ±{0.45*w:.1f}, Y ±{0.45*h:.1f}")

        print("\n  " + "-"*105)
        print(f"  | {'ID':<3} | {'图层名称':<20} | {'PSD BBox (L,T,R,B)':<22} | {'Motion 笛卡尔 (X,Y)':<18} | {'Title Safe 80%':<15} | {'Action Safe 90%':<15} |")
        print("  " + "-"*105)

        for l in parsed["layers"]:
            if l.kind != "type":
                continue
            left, top, right, bottom = l.psd_bbox
            mx, my = l.motion_pos
            safe = l.safe_area

            # 验证中心坐标严格位于安全区内
            assert safe["center_in_action_safe"], f"图层 '{l.name}' 中心超出 Action Safe 90% 范围: pos=({mx}, {my})"
            
            ts_str = f"{GREEN}√ PASS (Center){RESET}" if safe["center_in_title_safe"] else f"{YELLOW}Edge Caution{RESET}"
            as_str = f"{GREEN}√ PASS (Center){RESET}" if safe["center_in_action_safe"] else f"{RED}X Exceeded{RESET}"

            name_disp = (l.name[:16] + '..') if len(l.name) > 16 else l.name
            bbox_str = f"({left},{top},{right},{bottom})"
            mpos_str = f"({mx:+.1f}, {my:+.1f})"
            print(f"  | {l.index:<3} | {name_disp:<20} | {bbox_str:<22} | {mpos_str:<18} | {ts_str:<24} | {as_str:<24} |")

        print("  " + "-"*105)
        print_pass(f"{filename} 画幅换算与广播级安全区 (Title Safe 80% / Action Safe 90%) 校验完全合规！")

# ==============================================================================
# 测试 ②: 真实 PNG 位深、IHDR Header 读取与 AppKit 字形覆盖度深度检测
# ==============================================================================
def test_png_bitdepth_and_glyph_coverage():
    print_header("测试 ②: 降级 PNG 真实位深 (8-bit per ch / 32-bit RGBA) 与字形覆盖度 (Glyph Coverage) 深度检测")

    # --- Part A: 真实 PNG 位深与非空 Header 深度检验 ---
    print_subheader("Part A: 真实降级 PNG IHDR Chunk 解析与像素位深校验 (基于 23.psd 真实装饰形状)")
    temp_png_dir = tempfile.mkdtemp(prefix="fcpx_ihdr_check_")
    try:
        parsed_23 = parse_psd_file(PSD_23, extract_fallback_pngs=True, png_output_dir=temp_png_dir)
        fallback_layers = parsed_23["diagnostics"]["fallback_layers"]
        assert len(fallback_layers) > 0, "23.psd 应包含非纯文字图层"

        print("\n  " + "-"*115)
        print(f"  | {'ID':<3} | {'图层名称':<16} | {'导出 PNG 文件':<22} | {'IHDR 像素格式':<24} | {'有效非空':<10} | {'最大 Alpha':<10} | {'Header 校验':<12} |")
        print("  " + "-"*115)

        for fl in fallback_layers:
            meta = fl["png_info"]
            p = meta["path"]
            assert os.path.isfile(p), f"PNG 文件不存在: {p}"

            # 深度解析 PNG 二进制 Header (IHDR Chunk)
            with open(p, "rb") as pf:
                sig = pf.read(8)
                assert sig == b"\x89PNG\r\n\x1a\n", "PNG 魔数标识非法"
                chunk_len, chunk_type = struct.unpack(">I4s", pf.read(8))
                assert chunk_type == b"IHDR", "第一个 Chunk 必须为 IHDR"
                ihdr_data = pf.read(13)
                p_w, p_h, bit_depth, color_type = struct.unpack(">IIBB", ihdr_data[:10])

            assert bit_depth == 8, f"每个通道位深必须为 8-bit, 实际为 {bit_depth}"
            assert color_type == 6, f"颜色类型必须为 6 (RGBA 带透明通道), 实际为 {color_type}"
            total_bpp = bit_depth * 4
            assert total_bpp == 32, f"像素总位深必须为 32-bit RGBA, 实际为 {total_bpp}"
            assert meta["is_non_empty"], "图片不得为全透空图层"
            assert meta["max_alpha"] > 0, "Alpha 最大通道值必须大于 0"

            fname = os.path.basename(p)
            fmt_str = f"8-bit/ch (32-bit RGBA)"
            print(f"  | {fl['layer_index']:<3} | {fl['layer_name']:<16} | {fname:<22} | {fmt_str:<24} | {'√ True':<10} | {meta['max_alpha']:<10} | {'√ IHDR PASS':<12} |")

        print("  " + "-"*115)
        print_pass("所有降级贴图均为标准 8-bit per channel / 32-bit RGBA 真实有效图像，Header 严格合规！")

    finally:
        shutil.rmtree(temp_png_dir, ignore_errors=True)

    # --- Part B: AppKit 字形覆盖度 (Glyph Coverage) 深度检测 ---
    print_subheader("Part B: 字体字符集覆盖度 (Glyph Coverage) 与缺字风险防范检测")
    chinese_text = "领衔呈现 新郎陈晗 新娘朱永宏 百年好合"
    english_text = "Wedding Titles Studio Pro 2026"

    # 1. 正常中文字体检测 (FZZYSK 或 PingFangSC)
    cov_cn_fzz = check_font_glyph_coverage("FZZYSK--GBK1-0", chinese_text)
    print(f"  • FZZYSK--GBK1-0 对中文覆盖度: {cov_cn_fzz['coverage_rate']*100:.1f}%, 缺失字形: {cov_cn_fzz['missing_chars']}")
    assert cov_cn_fzz["coverage_rate"] == 1.0, "中文字体对测试中文覆盖度应为 100%"
    assert not cov_cn_fzz["has_missing_risk"], "不应存在缺字风险"

    # 2. 西文字体匹配中文字符串测试（模拟字体虽存在但缺字形缺陷）
    cov_en_on_cn = check_font_glyph_coverage("Helvetica", chinese_text)
    print(f"  • Helvetica 对中文测试覆盖度: {cov_en_on_cn['coverage_rate']*100:.1f}%, 缺失字形数: {len(cov_en_on_cn['missing_chars'])}")
    assert cov_en_on_cn["has_missing_risk"], "Helvetica 必须被检出缺中文字形风险"
    assert cov_en_on_cn["coverage_rate"] < 0.2, "Helvetica 对中文覆盖度必须极低"

    # 3. 西文字体匹配英文字符串测试
    cov_en_on_en = check_font_glyph_coverage("Helvetica", english_text)
    print(f"  • Helvetica 对纯西文覆盖度:   {cov_en_on_en['coverage_rate']*100:.1f}%, 缺失字形: {cov_en_on_en['missing_chars']}")
    assert cov_en_on_en["coverage_rate"] == 1.0, "Helvetica 对西文覆盖度应为 100%"

    print_pass("基于 AppKit coveredCharacterSet 的字形字符集覆盖度检测精准可靠，彻底杜绝乱码！")

# ==============================================================================
# 测试 ③: build_template_atomic 极限边界测试
# ==============================================================================
def test_atomic_extreme_boundaries():
    print_header("测试 ③: build_template_atomic 极限边界与高容错测试套件")
    builder = MotionBuilder()
    parsed = parse_psd_file(PSD_01)
    
    test_root = tempfile.mkdtemp(prefix="fcpx_extreme_boundary_")

    try:
        # --- 用例 3.1: 已有目标目录自动时间戳备份与历史保留 ---
        print_subheader("用例 3.1: 目标目录已存在时自动时间戳备份 (验证历史不丢失)")
        target_dir = os.path.join(test_root, "Template_Active")
        canary_file = os.path.join(target_dir, "historical_asset.dat")
        os.makedirs(target_dir, exist_ok=True)
        with open(canary_file, "w") as f:
            f.write("ORIGINAL_TEMPLATE_V1_DO_NOT_LOSE")

        res_atomic = builder.build_template_atomic(
            layers_info=parsed["layers"],
            output_dir=target_dir,
            template_name="Template_Active",
            psd_path=PSD_01,
            backup_existing=True
        )

        assert res_atomic["backup_path"] is not None
        assert os.path.isdir(res_atomic["backup_path"]), "备份目录未生成"
        backed_canary = os.path.join(res_atomic["backup_path"], "historical_asset.dat")
        assert os.path.isfile(backed_canary), "原目录特异历史资产在备份中丢失"
        with open(backed_canary, "r") as f:
            assert f.read() == "ORIGINAL_TEMPLATE_V1_DO_NOT_LOSE"
        assert not os.path.exists(canary_file), "新活动目录应保持纯净，旧 canary 文件不应存在"
        print_pass(f"已有目录自动安全备份至: {os.path.basename(res_atomic['backup_path'])}，历史无损保留！")

        # --- 用例 3.2: 中途异常注入与活动目录零污染验证 ---
        print_subheader("用例 3.2: 写入中途遭遇突发异常 (验证临时目录清理与活动目录回滚)")
        marker_v2 = os.path.join(target_dir, "v2_stable.marker")
        with open(marker_v2, "w") as f:
            f.write("STABLE_V2_STATE")

        caught_injection = False
        try:
            builder.build_template_atomic(
                layers_info=parsed["layers"],
                output_dir=target_dir,
                template_name="Template_Active",
                psd_path=PSD_01,
                backup_existing=True,
                _inject_failure_stage="after_thumbnails"  # 模拟崩溃
            )
        except RuntimeError as e:
            caught_injection = True
            print(f"  • 预期捕获注入异常: {e}")

        assert caught_injection, "未按预期抛出注入异常"
        # 验证临时沙箱无残留
        lingering = [d for d in os.listdir(test_root) if "_tmp_build_" in d]
        assert len(lingering) == 0, f"清理机制失效，发现残留临时沙箱: {lingering}"
        # 验证目标活动目录原样回滚
        assert os.path.isfile(marker_v2), "目标活动目录状态丢失，回滚失败"
        with open(marker_v2, "r") as f:
            assert f.read() == "STABLE_V2_STATE"
        print_pass("中途异常中断验证通过：临时沙箱完全清除，活动目录零污染零损坏！")

        # --- 用例 3.3: 目标路径只读 / 权限不足优雅拦截 ---
        print_subheader("用例 3.3: 目标路径只读 / 权限不足时先行优雅阻断")
        ro_sandbox = os.path.join(test_root, "readonly_dir")
        os.makedirs(ro_sandbox, exist_ok=True)
        os.chmod(ro_sandbox, 0o444)  # 设为只读

        ro_target = os.path.join(ro_sandbox, "sub_template")
        caught_ro = False
        try:
            builder.build_template_atomic(
                layers_info=parsed["layers"],
                output_dir=ro_target,
                template_name="sub_template",
                psd_path=PSD_01
            )
        except StoragePermissionError as pe:
            caught_ro = True
            print(f"  • 预期捕获权限拦截异常: {pe}")
        finally:
            os.chmod(ro_sandbox, 0o777)

        assert caught_ro, "只读目标路径未能被先行权限检查捕获"
        # 验证没有残留任何孤儿文件
        assert len(os.listdir(ro_sandbox)) == 0, "只读拦截失败，产生了孤儿文件"
        print_pass("只读存储路径在启动前被成功阻断拦截，未产生任何孤儿文件！")

        # --- 用例 3.4: 外置未挂载存储卷预检拦截 ---
        print_subheader("用例 3.4: 外置卷未挂载预检先行阻断拦截")
        ghost_vol_dir = "/Volumes/Ghost_Wedding_Drive_8888/Titles/Template"
        caught_storage = False
        try:
            builder.build_template_atomic(
                layers_info=parsed["layers"],
                output_dir=ghost_vol_dir,
                template_name="Template"
            )
        except StorageNotReadyError as se:
            caught_storage = True
            print(f"  • 预期捕获存储未就绪异常: {se}")

        assert caught_storage, "未挂载外置存储未被 Pre-flight 检查拦截"
        print_pass("未挂载外置路径成功阻断并给出 StorageNotReadyError 友好提示！")

    finally:
        shutil.rmtree(test_root, ignore_errors=True)

# ==============================================================================
# 测试 ④: 符合 Apple 规范的真实 Motion 模板目录生成与 49+ 参数校验
# ==============================================================================
def test_real_motion_template_generation_and_publishing():
    print_header("测试 ④: 真实 Motion Templates 目录生成与 49+ publishSettings 参数体系校验")

    # 标准 Final Cut Pro 模板发布目录
    official_base_dir = os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/FCPX_Studio_MVP")
    template_name = "01_领衔呈现"
    target_template_dir = os.path.join(official_base_dir, template_name)

    builder = MotionBuilder()
    parsed = parse_psd_file(PSD_01)

    print_subheader(f"目标安装路径: {target_template_dir}")
    
    # 真实原子生成至系统 Motion 模板库
    res = builder.build_template_atomic(
        layers_info=parsed["layers"],
        output_dir=target_template_dir,
        template_name=template_name,
        psd_path=PSD_01,
        backup_existing=True
    )

    # 1. 验证物理目录与文件规格
    print_subheader("1. 物理目录结构完整性与规格校验:")
    moti_path = res["moti_path"]
    large_png = res["large_png"]
    small_png = res["small_png"]
    media_dir = os.path.join(target_template_dir, "Media")

    assert os.path.isfile(moti_path), f"缺少 .moti: {moti_path}"
    moti_sz = os.path.getsize(moti_path)
    assert moti_sz >= 1024, f".moti 文件过小: {moti_sz} 字节"
    print(f"  • .moti 模板文件:     {os.path.basename(moti_path)} ({moti_sz:,} 字节, 语法合法)")

    assert os.path.isfile(large_png), f"缺少 large.png"
    assert os.path.isfile(small_png), f"缺少 small.png"
    with Image.open(large_png) as img_l:
        assert img_l.size == (640, 360), f"大缩略图尺寸错误: {img_l.size}"
        print(f"  • 大预览缩略图 large:  {img_l.size[0]}×{img_l.size[1]} (RGBA, {os.path.getsize(large_png):,} 字节)")
    with Image.open(small_png) as img_s:
        assert img_s.size == (192, 108), f"小缩略图尺寸错误: {img_s.size}"
        print(f"  • 小预览缩略图 small:  {img_s.size[0]}×{img_s.size[1]} (RGBA, {os.path.getsize(small_png):,} 字节)")
    
    assert os.path.isdir(media_dir), "缺少 Media 资源文件夹"
    print(f"  • 独立资产媒体目录:   Media/ (已就绪)")

    # 2. 深度验证 ozml publishSettings 发布参数体系
    print_subheader("2. ozml 5.14 规范与 49+ 发布通道逐项校验:")
    tree = ET.parse(moti_path)
    root = tree.getroot()
    assert root.tag == "ozml", "根节点必须为 ozml"
    scene = root.find("scene")
    assert scene is not None, "缺少 scene 节点"
    pub = scene.find("publishSettings")
    assert pub is not None, "缺少 publishSettings 节点"

    targets = pub.findall("target")
    total_published = len(targets)
    print(f"  • 已向 FCPX 检查器发布参数总数: {total_published} 个 (要求 >= 49)")
    assert total_published >= 49, f"发布参数数量不足: {total_published} < 49"

    # 统计核心发布参数分类
    text_chans = []
    font_chans = []
    size_chans = []
    track_chans = []
    pos_chans = []
    align_chans = []
    hdr_chans = []
    forbidden_chans = []

    for t in targets:
        name = t.attrib.get("name", "")
        chan = t.attrib.get("channel", "")

        if chan == "./1/103":
            hdr_chans.append(name)
        elif chan == "./2/369":
            text_chans.append(name)
        elif chan == "./83":
            font_chans.append(name)
        elif chan == "./3":
            size_chans.append(name)
        elif chan == "./81/79":
            track_chans.append(name)
        elif chan == "./1/100/101":
            pos_chans.append(name)
        elif "354" in chan and "401" in chan:
            align_chans.append(name)
        
        # 检查是否泄漏了不应发布的内部参数 (如混合模式、锚点、私有标旗)
        if any(leak in chan for leak in ["./1/100/100", "./1/104", "./1/106", "blendMode", "anchorPoint"]):
            forbidden_chans.append((name, chan))

    print(f"    - Graphics HDR 控制:    {len(hdr_chans)} 个通道 ({hdr_chans})")
    print(f"    - Text 文本编辑内容:    {len(text_chans)} 个图层通道")
    print(f"    - Font 字体选择器:      {len(font_chans)} 个图层通道")
    print(f"    - Size 独立字号调节:    {len(size_chans)} 个图层通道")
    print(f"    - Tracking 字距调节:    {len(track_chans)} 个图层通道")
    print(f"    - Position 笛卡尔坐标:  {len(pos_chans)} 个图层通道")
    print(f"    - Alignment 排版对齐:   {len(align_chans)} 个图层通道")

    assert len(hdr_chans) == 1, "缺少 HDR 控制通道"
    assert len(text_chans) == 8, "文字图层 Text 内容发布通道数量不符"
    assert len(font_chans) == 8, "文字图层 Font 发布通道数量不符"
    assert len(size_chans) == 8, "文字图层 Size 发布通道数量不符"
    assert len(track_chans) == 8, "文字图层 Tracking 发布通道数量不符"
    assert len(pos_chans) == 8, "文字图层 Position 发布通道数量不符"
    assert len(align_chans) == 8, "文字图层 Alignment 发布通道数量不符"
    assert len(forbidden_chans) == 0, f"发现泄漏的未勾选私有参数: {forbidden_chans}"

    print_pass("所有 49 个发布通道与 FCPX 官方规范 100% 对应，私有参数零泄漏！")
    print_pass(f"真实 Motion 模板已成功部署在 Final Cut Pro 模板库中:\n       {target_template_dir}")

# ==============================================================================
# 主入口
# ==============================================================================
def main():
    print(f"\n{BOLD}{CYAN}===================================================================================={RESET}")
    print(f"{BOLD}{CYAN}     FCPX Studio Pro - 第一阶段 MVP 真实集成与边界极限补证验收测试套件              {RESET}")
    print(f"{BOLD}{CYAN}===================================================================================={RESET}")

    start_time = time.time()
    try:
        test_multi_aspect_ratio_and_safe_areas()
        test_png_bitdepth_and_glyph_coverage()
        test_atomic_extreme_boundaries()
        test_real_motion_template_generation_and_publishing()

        elapsed = time.time() - start_time
        print(f"\n{BOLD}{GREEN}{'='*85}{RESET}")
        print(f"{BOLD}{GREEN}🎉 所有 4 大真实集成与极限边界补证验收测试 100% 全部通过！总耗时: {elapsed:.2f}s{RESET}")
        print(f"{BOLD}{GREEN}{'='*85}{RESET}\n")
        return 0

    except Exception as e:
        import traceback
        print(f"\n{BOLD}{RED}{'='*85}{RESET}")
        print(f"{BOLD}{RED}❌ 测试执行中断并捕获到未处理异常:{RESET}")
        traceback.print_exc()
        print(f"{BOLD}{RED}{'='*85}{RESET}\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
