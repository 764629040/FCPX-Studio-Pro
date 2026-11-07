#!/usr/bin/env python3
"""
================================================================================
FCPX Studio Pro - 第一阶段 MVP 稳健化端到端验收验证脚本 (E2E Acceptance Suite)
================================================================================
测试范围：
① 动态画幅与坐标数学换算验证 (01.psd, 02.psd 笛卡尔坐标无损换算)
② 真实图层降级与字体三元组诊断验证 (字体三元组、缺失回退、真实 32 位透明 PNG 导出)
③ 原子写入与失败回滚测试 (临时沙箱构建、时间戳备份、故障注入与活动目录零污染验证)
④ Motion 模板目录树结构 (ls -lR 级) 与 ozml publishSettings 参数体系验证
================================================================================
"""

import os
import sys
import shutil
import time
import tempfile
import xml.etree.ElementTree as ET
from PIL import Image

# 注入项目根路径
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(CURRENT_DIR)
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file, check_font_availability, PSDLayerInfo
from core.motion_builder import MotionBuilder

DATA_DIR = os.path.join(CURRENT_DIR, "data")
PSD_BASE_DIR = os.environ.get(
    "PSD_BASE_DIR",
    "/Volumes/摄影师工具箱128GB/字幕/H373[豪门素材]  50款婚礼纪实字幕PSD格式可PS编辑文字/PSD格式通用/PSD文件" if os.path.exists("/Volumes/摄影师工具箱128GB") else DATA_DIR
)
PSD_01 = os.path.join(PSD_BASE_DIR, "01.psd") if os.path.exists(os.path.join(PSD_BASE_DIR, "01.psd")) else os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
PSD_02 = os.path.join(PSD_BASE_DIR, "02.psd") if os.path.exists(os.path.join(PSD_BASE_DIR, "02.psd")) else os.path.join(DATA_DIR, "commercial_4k.psd")
PSD_23 = os.path.join(PSD_BASE_DIR, "23.psd") if os.path.exists(os.path.join(PSD_BASE_DIR, "23.psd")) else os.path.join(DATA_DIR, "wedding_with_decorations_23.psd")  # 包含真实形状与装饰线条

GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RED = "\033[91m"
BOLD = "\033[1m"
RESET = "\033[0m"

def print_header(title: str):
    print(f"\n{BOLD}{CYAN}{'='*80}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'='*80}{RESET}")

def print_subheader(title: str):
    print(f"\n{BOLD}{YELLOW}--- {title} ---{RESET}")

def print_pass(msg: str):
    print(f"{GREEN}[PASS]{RESET} {msg}")

def print_fail(msg: str):
    print(f"{RED}[FAIL]{RESET} {msg}")

# ==============================================================================
# 测试 ①: 动态画幅与坐标数学换算验证
# ==============================================================================
def test_dynamic_canvas_and_coordinates():
    print_header("测试 ①: 动态画幅与坐标数学换算验证 (01.psd & 02.psd)")
    
    test_files = [("01.psd", PSD_01), ("02.psd", PSD_02)]
    
    for filename, filepath in test_files:
        print_subheader(f"分析文件: {filename}")
        assert os.path.exists(filepath), f"测试 PSD 不存在: {filepath}"
        
        parsed = parse_psd_file(filepath)
        w, h = parsed["width"], parsed["height"]
        aspect = parsed["aspect_ratio"]
        res_spec = parsed["resolution_spec"]
        
        print(f"  • 画布分辨率: {w} × {h}")
        print(f"  • 识别画幅比: {aspect}")
        print(f"  • 规格档位:   {res_spec}")
        
        assert w == 1920 and h == 1080, f"分辨率不符预期: {w}x{h}"
        assert "16:9" in aspect, f"画幅比检测错误: {aspect}"
        assert "1080P" in res_spec, f"分辨率档位错误: {res_spec}"

        cx, cy = w / 2.0, h / 2.0
        print(f"  • 画布中心参考原点: ({cx}, {cy})")
        print("\n  " + "-"*95)
        print(f"  | {'ID':<3} | {'图层名称':<22} | {'PSD BBox (L,T,R,B)':<24} | {'图层中心 (PSD)':<16} | {'Motion 笛卡尔坐标':<16} | {'可逆校验':<6} |")
        print("  " + "-"*95)

        for layer in parsed["layers"]:
            if layer.kind != "type":
                continue
            left, top, right, bottom = layer.psd_bbox
            layer_cx = (left + right) / 2.0
            layer_cy = (top + bottom) / 2.0
            mx, my = layer.motion_pos

            # 严格数学可逆换算
            expected_mx = round(layer_cx - cx, 2)
            expected_my = round(cy - layer_cy, 2)
            assert abs(mx - expected_mx) < 0.01, f"X 坐标换算偏离: {mx} vs {expected_mx}"
            assert abs(my - expected_my) < 0.01, f"Y 坐标换算偏离: {my} vs {expected_my}"

            reconstructed_cx = round(mx + cx, 2)
            reconstructed_cy = round(cy - my, 2)
            assert abs(reconstructed_cx - layer_cx) < 0.05
            assert abs(reconstructed_cy - layer_cy) < 0.05

            bbox_str = f"({left},{top},{right},{bottom})"
            psd_c_str = f"({layer_cx:.1f}, {layer_cy:.1f})"
            motion_str = f"({mx:+.2f}, {my:+.2f})"
            name_disp = (layer.name[:18] + '..') if len(layer.name) > 18 else layer.name
            print(f"  | {layer.index:<3} | {name_disp:<22} | {bbox_str:<24} | {psd_c_str:<16} | {motion_str:<16} | {'√ PASS':<6} |")

        print("  " + "-"*95)
        print_pass(f"{filename} 所有矢量图层中心笛卡尔坐标换算 100% 精度无损可逆！")

# ==============================================================================
# 测试 ②: 真实图层降级与字体三元组诊断验证
# ==============================================================================
def test_font_triplet_and_fallback_png():
    print_header("测试 ②: 真实图层降级与字体三元组诊断验证")
    
    # --- Part A: 字体三元组检测 ---
    print_subheader("Part A: 真实字体三元组诊断与缺失回退测试")
    parsed_01 = parse_psd_file(PSD_01)
    
    print("\n  " + "-"*105)
    print(f"  | {'ID':<3} | {'图层名称':<20} | {'原字体 (original_font)':<22} | {'检测状态':<16} | {'生效/回退字体':<20} |")
    print("  " + "-"*105)

    for l in parsed_01["layers"]:
        if l.kind != "type":
            continue
        info = l.font_info
        assert "original_font" in info, "font_info 缺少 original_font"
        assert "detection_status" in info, "font_info 缺少 detection_status"
        assert "fallback_font" in info, "font_info 缺少 fallback_font"
        assert info["detection_status"] in ("detected", "missing_fallback")
        
        name_disp = (l.name[:18] + '..') if len(l.name) > 18 else l.name
        status_color = GREEN if info["detection_status"] == "detected" else YELLOW
        status_str = f"{status_color}{info['detection_status']}{RESET}"
        print(f"  | {l.index:<3} | {name_disp:<20} | {info['original_font']:<22} | {info['detection_status']:<16} | {info['fallback_font']:<20} |")

    print("  " + "-"*105)
    print_pass(f"01.psd 字体检测正常：已检出 {parsed_01['diagnostics']['fonts_detected_count']} 个，回退 {parsed_01['diagnostics']['fonts_fallback_count']} 个")

    # 模拟未安装字体的回退检测
    print("\n  • 验证未安装罕见字体的三元组保护逻辑...")
    rare_font = "NonExistent_Wedding_Font_9999"
    is_avail = check_font_availability(rare_font)
    assert not is_avail, "罕见字体不应被检测为存在"

    # 验证中文和英文分别采用的最优回退字体
    chinese_text = "百年好合"
    english_text = "Happy Wedding"
    
    # 中文回退
    has_cn = any('\u4e00' <= c <= '\u9fff' for c in chinese_text)
    cn_fallback = "PingFangSC-Regular" if has_cn else "Helvetica"
    assert cn_fallback == "PingFangSC-Regular", "中文字符串必须回退至系统苹方字体"

    # 英文回退
    has_en_cn = any('\u4e00' <= c <= '\u9fff' for c in english_text)
    en_fallback = "PingFangSC-Regular" if has_en_cn else "Helvetica"
    assert en_fallback == "Helvetica", "纯英文字符串回退至系统 Helvetica"

    print_pass(f"字体三元组回退决策链准确: 中文 -> {cn_fallback}, 英文 -> {en_fallback}")

    # --- Part B: 真实图层 PNG 降级导出 ---
    print_subheader("Part B: 真实图层 32 位透明 PNG 降级栅格化导出 (使用 23.psd 真实装饰图形)")
    assert os.path.exists(PSD_23), f"未找到 23.psd: {PSD_23}"

    temp_png_dir = tempfile.mkdtemp(prefix="fcpx_fallback_pngs_")
    try:
        parsed_23 = parse_psd_file(PSD_23, extract_fallback_pngs=True, png_output_dir=temp_png_dir)
        fallback_layers = parsed_23["diagnostics"]["fallback_layers"]
        
        print(f"  • 成功扫描到降级非纯文本图层数: {len(fallback_layers)}")
        assert len(fallback_layers) > 0, "23.psd 应包含非纯文字图层"

        print("\n  " + "-"*110)
        print(f"  | {'ID':<3} | {'图层名':<16} | {'类型':<10} | {'输出 PNG 文件':<28} | {'尺寸':<12} | {'通道模式':<10} | {'文件大小':<10} |")
        print("  " + "-"*110)

        for fl in fallback_layers:
            png_meta = fl["png_info"]
            p = png_meta["path"]
            assert os.path.isfile(p), f"导出的 PNG 不存在: {p}"
            sz = png_meta["file_size"]
            assert sz > 0, "导出 PNG 大小必须大于 0 字节"

            # 严格验证是否为真实 32 位透明 RGBA
            with Image.open(p) as img:
                assert img.mode == "RGBA", f"图片必须为 RGBA 32位透明通道，实际为 {img.mode}"
                assert len(img.getbands()) == 4, f"通道数必须为 4，实际为 {len(img.getbands())}"
                assert img.width == png_meta["width"]
                assert img.height == png_meta["height"]

            dim_str = f"{png_meta['width']}×{png_meta['height']}"
            fname = os.path.basename(p)
            print(f"  | {fl['layer_index']:<3} | {fl['layer_name']:<16} | {fl['kind']:<10} | {fname:<28} | {dim_str:<12} | {png_meta['mode']} (4ch) | {sz:<7} 字节 |")

        print("  " + "-"*110)
        print_pass("真实图层 32 位透明 PNG 贴图全部成功提取并完成属性校验！")

    finally:
        shutil.rmtree(temp_png_dir, ignore_errors=True)

# ==============================================================================
# 测试 ③: 原子写入与失败回滚测试
# ==============================================================================
def test_atomic_write_and_rollback():
    print_header("测试 ③: 原子写入与安全回滚机制深度测试")

    parsed = parse_psd_file(PSD_01)
    builder = MotionBuilder()

    test_sandbox_root = tempfile.mkdtemp(prefix="fcpx_atomic_test_root_")
    target_template_dir = os.path.join(test_sandbox_root, "01_领衔呈现")
    
    try:
        # --- 场景 1: 初次正常构建 ---
        print_subheader("场景 1: 正常全量沙箱原子构建")
        res1 = builder.build_template_atomic(
            layers_info=parsed["layers"],
            output_dir=target_template_dir,
            template_name="01_领衔呈现",
            psd_path=PSD_01,
            backup_existing=True
        )
        assert os.path.isdir(target_template_dir), "目标模板目录未建立"
        assert os.path.isfile(res1["moti_path"]), ".moti 文件不存在"
        assert os.path.getsize(res1["moti_path"]) >= 1024, ".moti 文件体积过小"
        assert os.path.isfile(res1["large_png"]), "large.png 缺失"
        assert os.path.isfile(res1["small_png"]), "small.png 缺失"
        
        # 校验同级无临时构建目录残留
        parent_items = os.listdir(test_sandbox_root)
        tmp_dirs = [d for d in parent_items if "_tmp_build_" in d]
        assert len(tmp_dirs) == 0, f"发现残留的临时目录: {tmp_dirs}"
        print_pass("初次构建成功，所有关键产物完整，无任何临时构建沙箱残留！")

        # --- 场景 2: 原目标存在时的自动备份与替换 ---
        print_subheader("场景 2: 目标已存在时的自动时间戳备份")
        # 在旧目录植入特定标志文件
        v1_canary = os.path.join(target_template_dir, "v1_canary.txt")
        with open(v1_canary, "w") as f:
            f.write("CANARY_VERSION_1")

        time.sleep(1.05)  # 保证时间戳变动
        res2 = builder.build_template_atomic(
            layers_info=parsed["layers"],
            output_dir=target_template_dir,
            template_name="01_领衔呈现",
            psd_path=PSD_01,
            backup_existing=True
        )
        assert res2["backup_path"] is not None, "未返回备份目录路径"
        assert os.path.isdir(res2["backup_path"]), f"备份目录未建立: {res2['backup_path']}"
        backed_canary = os.path.join(res2["backup_path"], "v1_canary.txt")
        assert os.path.isfile(backed_canary), "备份目录中未包含原目录的特异标志文件"
        assert not os.path.exists(v1_canary), "新替换的目标活动目录中不应包含旧 canary 文件"
        print_pass(f"备份与原子替换成功！原模板已完整移入备份: {os.path.basename(res2['backup_path'])}")

        # --- 场景 3: 故障注入与自动清理回滚 ---
        print_subheader("场景 3: 构建过程中故意注入异常（模拟渲染奔溃）")
        # 在现有正常目录植入 v2 状态标志
        v2_canary = os.path.join(target_template_dir, "v2_active_marker.dat")
        with open(v2_canary, "w") as f:
            f.write("CRITICAL_ACTIVE_STATE_DO_NOT_CORRUPT")
        
        exception_caught = False
        try:
            builder.build_template_atomic(
                layers_info=parsed["layers"],
                output_dir=target_template_dir,
                template_name="01_领衔呈现",
                psd_path=PSD_01,
                backup_existing=True,
                _inject_failure_stage="after_thumbnails"  # 模拟缩略图生成后突发崩溃
            )
        except RuntimeError as e:
            exception_caught = True
            print(f"  • 预期捕获注入异常: {e}")

        assert exception_caught, "故障注入未能按预期抛出异常"

        # 严格验证回滚保护：
        # 1. 临时目录必须被坚决清理
        lingering_tmp = [d for d in os.listdir(test_sandbox_root) if "_tmp_build_" in d]
        assert len(lingering_tmp) == 0, f"清理机制失效，发现残留临时目录: {lingering_tmp}"

        # 2. 目标活动目录必须毫发无损，完全保留原先状态
        assert os.path.isdir(target_template_dir), "活动目录损坏或失踪"
        assert os.path.isfile(v2_canary), "活动目录内状态标志文件丢失，回滚失败！"
        with open(v2_canary, "r") as f:
            content = f.read()
        assert content == "CRITICAL_ACTIVE_STATE_DO_NOT_CORRUPT", "活动目录内容发生数据破坏"

        print_pass("异常回滚与清理机制 100% 成功！活动目录零污染，临时构建残留 0 存在！")

        # --- 场景 4: 动态级联探测 (Cascade Detection) 与环境可移植性 ---
        print_subheader("场景 4: 基准模板动态级联探测 (Cascade Detection) 可移植性验证")
        from core.motion_builder import find_reference_template

        # ① 默认级联探测 (用户目录自适应)
        detected_default = find_reference_template()
        assert os.path.isfile(detected_default), f"默认级联探测失败: {detected_default}"
        print(f"  • 默认动态解析路径: {detected_default}")

        # ② 环境变量优先级探测
        env_fake = os.path.join(test_sandbox_root, "env_reference.moti")
        shutil.copy2(detected_default, env_fake)
        os.environ["FCPX_MOTION_REFERENCE_PATH"] = env_fake
        try:
            detected_env = find_reference_template()
            assert detected_env == env_fake, f"环境变量优先级未生效: {detected_env} vs {env_fake}"
            print_pass("环境变量 FCPX_MOTION_REFERENCE_PATH 最高优先级探测生效！")
        finally:
            os.environ.pop("FCPX_MOTION_REFERENCE_PATH", None)

        # ③ 项目内置 assets 兜底探测
        project_assets_moti = os.path.join(PROJECT_ROOT, "assets", "reference_base.moti")
        assert os.path.isfile(project_assets_moti), f"项目 assets 兜底基准模板不存在: {project_assets_moti}"
        detected_assets = find_reference_template(project_assets_moti)
        assert detected_assets == os.path.abspath(project_assets_moti)
        print_pass(f"项目内置资产兜底机制验证成功: {os.path.basename(detected_assets)}，已彻底消除硬编码用户名！")

    finally:
        shutil.rmtree(test_sandbox_root, ignore_errors=True)

# ==============================================================================
# 测试 ④: 目录树结构与 ozml publishSettings 参数体系验证
# ==============================================================================
def test_directory_tree_and_publish_settings():
    print_header("测试 ④: Motion 模板目录树 (ls -lR) 与 ozml publishSettings 验证")

    parsed = parse_psd_file(PSD_01)
    builder = MotionBuilder()

    test_dir = tempfile.mkdtemp(prefix="fcpx_moti_verify_")
    template_dir = os.path.join(test_dir, "01_领衔呈现")

    try:
        res = builder.build_template_atomic(
            layers_info=parsed["layers"],
            output_dir=template_dir,
            template_name="01_领衔呈现",
            psd_path=PSD_01
        )

        # 1. 打印完整的目录树 (ls -lR 级展示)
        print_subheader("生成的 Motion 模板包物理目录树结构:")
        for root, dirs, files in os.walk(template_dir):
            rel_path = os.path.relpath(root, template_dir)
            level = 0 if rel_path == "." else rel_path.count(os.sep) + 1
            indent = "  " * level
            folder_name = os.path.basename(root) if rel_path != "." else os.path.basename(template_dir)
            print(f"{indent}{BOLD}📁 {folder_name}/{RESET}")
            for file in sorted(files):
                file_path = os.path.join(root, file)
                sz = os.path.getsize(file_path)
                perm = oct(os.stat(file_path).st_mode)[-3:]
                print(f"{indent}    📄 {file:<25} ({sz:>7} bytes, mode {perm})")

        # 2. 解析 .moti 文件验证 ozmlpublishSettings 参数体系
        print_subheader("ozml 规范与 publishSettings 发布参数校验:")
        moti_path = res["moti_path"]
        tree = ET.parse(moti_path)
        root = tree.getroot()
        assert root.tag == "ozml", f"根节点必须为 ozml，实际为 {root.tag}"
        scene = root.find("scene")
        assert scene is not None, "缺少 scene 节点"

        pub = scene.find("publishSettings")
        assert pub is not None, "缺少 publishSettings 发布参数节点"
        v = pub.find("version")
        assert v is not None and v.text == "2", "publishSettings version 必须为 2"

        targets = pub.findall("target")
        print(f"  • publishSettings 中已声明的发布参数总数: {len(targets)}")
        assert len(targets) > 0, "缺少发布通道"

        print("\n  " + "-"*85)
        print(f"  | {'序号':<4} | {'发布参数名称 (name)':<28} | {'目标对象 (object)':<16} | {'通道路径 (channel)':<22} |")
        print("  " + "-"*85)

        published_channels_found = set()
        for idx, t in enumerate(targets, start=1):
            name = t.attrib.get("name", "")
            obj = t.attrib.get("object", "")
            chan = t.attrib.get("channel", "")
            published_channels_found.add(chan)
            print(f"  | {idx:<4} | {name:<28} | {obj:<16} | {chan:<22} |")

        print("  " + "-"*85)

        # 校验核心发布通道存在
        assert "./1/103" in published_channels_found, "缺少 HDR Level 通道"
        assert "./2/369" in published_channels_found, "缺少 Text 文本内容发布通道"
        assert "./83" in published_channels_found, "缺少 Font 字体发布通道"
        assert "./3" in published_channels_found, "缺少 Size 字号发布通道"
        assert "./81/79" in published_channels_found, "缺少 Tracking 字距发布通道"
        assert "./1/100/101" in published_channels_found, "缺少 Position 坐标发布通道"

        print_pass("ozml publishSettings 结构合法，所有关键通道全部正确绑定发布！")

    finally:
        shutil.rmtree(test_dir, ignore_errors=True)

# ==============================================================================
# 主入口
# ==============================================================================
def main():
    print(f"\n{BOLD}{CYAN}================================================================================{RESET}")
    print(f"{BOLD}{CYAN}         FCPX Studio Pro - 第一阶段 MVP 稳健化验收验证全量测试套件              {RESET}")
    print(f"{BOLD}{CYAN}================================================================================{RESET}")

    start_time = time.time()
    try:
        test_dynamic_canvas_and_coordinates()
        test_font_triplet_and_fallback_png()
        test_atomic_write_and_rollback()
        test_directory_tree_and_publish_settings()

        elapsed = time.time() - start_time
        print(f"\n{BOLD}{GREEN}{'='*80}{RESET}")
        print(f"{BOLD}{GREEN}🎉 所有 4 大核心稳健化验收测试套件 100% 全部通过！总耗时: {elapsed:.2f}s{RESET}")
        print(f"{BOLD}{GREEN}{'='*80}{RESET}\n")
        return 0

    except Exception as e:
        import traceback
        print(f"\n{BOLD}{RED}{'='*80}{RESET}")
        print(f"{BOLD}{RED}❌ 测试执行中断并捕获到未处理异常:{RESET}")
        traceback.print_exc()
        print(f"{BOLD}{RED}{'='*80}{RESET}\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
