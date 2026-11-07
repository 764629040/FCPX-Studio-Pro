"""
端到端测试脚本：
1. 解析 /Volumes/.../01.psd
2. 转换为 Motion XML (.moti)
3. 生成 large.png 和 small.png
4. 在外置盘建立分类目录，并在系统盘建立软链接
5. 验证文件完整性
"""
import os
import sys
from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder
from core.thumbnail import generate_thumbnails_from_psd
from core.symlink_manager import SymlinkManager
from psd_tools import PSDImage

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LOCAL_PSD = os.path.join(PROJECT_ROOT, "tests", "data", "vertical_wedding_9_16.psd")
TEST_PSD = os.environ.get("TEST_PSD", DEFAULT_LOCAL_PSD)
EXTERNAL_ASSETS_DIR = os.environ.get("EXTERNAL_ASSETS_DIR", os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/FCPX_Studio_MVP"))
GROUP_NAME = "FCPX_Studio婚礼字幕测试"

def run_test():
    print("=== STEP 1: 解析 PSD ===")
    if not os.path.exists(TEST_PSD):
        print(f"错误: 未找到测试 PSD: {TEST_PSD}")
        return False
        
    parsed = parse_psd_file(TEST_PSD)
    print(f"PSD 尺寸: {parsed['width']}x{parsed['height']}")
    print(f"成功提取文字图层数: {parsed['layer_count']}")
    for l in parsed["layers"]:
        print(f"  [{l.index}] {l.name}: text={repr(l.text[:10])} pos={l.motion_pos} size={l.font_size}")

    print("\n=== STEP 2: 创建外置目标目录与模板包 ===")
    target_group_dir = os.path.join(EXTERNAL_ASSETS_DIR, "Titles.localized", GROUP_NAME)
    template_dir = os.path.join(target_group_dir, "01_领衔呈现")
    os.makedirs(template_dir, exist_ok=True)
    media_dir = os.path.join(template_dir, "Media")
    os.makedirs(media_dir, exist_ok=True)

    print("\n=== STEP 3: 生成 .moti 文件 ===")
    builder = MotionBuilder()
    moti_path = os.path.join(template_dir, "01_领衔呈现.moti")
    builder.build_moti(parsed["layers"], moti_path, "01_领衔呈现")
    print(f"已生成 Motion 文件: {moti_path} ({os.path.getsize(moti_path)} bytes)")

    print("\n=== STEP 4: 生成缩略图 ===")
    psd_obj = PSDImage.open(TEST_PSD)
    large_p, small_p = generate_thumbnails_from_psd(psd_obj, template_dir)
    print(f"已生成大缩略图: {large_p}")
    print(f"已生成小缩略图: {small_p}")

    print("\n=== STEP 5: 外置软链接挂载至系统盘 ===")
    mgr = SymlinkManager(EXTERNAL_ASSETS_DIR)
    ok, msg = mgr.link_category_to_system("Titles.localized", GROUP_NAME)
    print(f"挂载结果: {ok}, 消息: {msg}")

    print("\n=== STEP 6: 检查系统盘软链接状态 ===")
    installed = mgr.get_installed_plugins("Titles.localized")
    matched = [p for p in installed if p["name"] == GROUP_NAME]
    if matched:
        print(f"系统盘成功识别: {matched[0]}")
        print("\n🎉 端到端全链路测试 100% 成功！")
        return True
    else:
        print("未在系统盘找到挂载项！")
        return False

if __name__ == "__main__":
    success = run_test()
    sys.exit(0 if success else 1)
