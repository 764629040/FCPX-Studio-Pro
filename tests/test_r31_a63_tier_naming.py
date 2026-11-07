"""
R31 / A-63：存储归属命名纠错（Python 侧）
=========================================
`~/Movies/Motion Templates.localized` 在 FCPX 语义里是「用户」级，
不是「系统内置盘」。本测试守护：
  · 内部命名纠正为 user_tier_root，旧名保留为 deprecated 别名；
  · 扫描结果同时给出 tier（归属）与 disk_form（磁盘形态）两个维度；
  · 不再出现「系统内置盘」这类把用户级说成系统级的文案。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

import core.symlink_manager as sm
from core.symlink_manager import SymlinkManager


def test_user_tier_is_not_named_system():
    expected = os.path.expanduser("~/Movies/Motion Templates.localized")
    assert sm.DEFAULT_USER_MOTION_DIR == expected
    # 旧名保留为兼容别名，但指向同一个用户级目录
    assert sm.DEFAULT_SYSTEM_MOTION_DIR == sm.DEFAULT_USER_MOTION_DIR


def test_system_root_alias_forwards_to_user_tier():
    mgr = object.__new__(SymlinkManager)   # 跳过 __init__，避免触碰真实 ~/Movies
    mgr.user_tier_root = "/tmp/r31_user_tier"
    assert mgr.system_root == "/tmp/r31_user_tier"
    mgr.system_root = "/tmp/r31_other"
    assert mgr.user_tier_root == "/tmp/r31_other"


def test_scan_reports_tier_and_disk_form(tmp_path):
    """用户级扫描必须同时给归属（user）与磁盘形态（physical/external_link）。"""
    user_root = tmp_path / "Motion Templates.localized"
    cat = user_root / "Titles.localized"
    cat.mkdir(parents=True)

    physical = cat / "实体模板"
    physical.mkdir()
    (physical / "a.bin").write_bytes(b"x" * 128)

    external = tmp_path / "external" / "外置模板"
    external.mkdir(parents=True)
    (external / "b.bin").write_bytes(b"y" * 64)
    (cat / "外置模板").symlink_to(external)

    mgr = object.__new__(SymlinkManager)
    mgr.user_tier_root = str(user_root)
    rows = {r["name"]: r for r in mgr.get_installed_plugins("Titles.localized")}

    assert rows["实体模板"]["tier"] == "user"
    assert rows["实体模板"]["disk_form"] == "physical"
    assert rows["外置模板"]["tier"] == "user"
    assert rows["外置模板"]["disk_form"] == "external_link"
    assert rows["外置模板"]["is_symlink"] is True


def test_no_misleading_copy_in_python_ui():
    """文案守卫：不得再把用户级叫「系统内置盘」。"""
    gui_file = os.path.join(PROJECT_ROOT, "gui", "asset_hub_panel.py")
    with open(gui_file, encoding="utf-8") as f:
        content = f.read()
    assert "系统内置盘" not in content
    assert "用户级" in content

    with open(os.path.join(PROJECT_ROOT, "core", "symlink_manager.py"), encoding="utf-8") as f:
        core_src = f.read()
    assert "确保系统盘" not in core_src
    assert "user_tier_root" in core_src
