"""
回归测试：A-19（工具自身必须纳入受控指纹清单 + 写入守卫改用白名单）

背景（第六轮审核发现）：
  - `tools/` 下 5 个文件全部不在 audit_inventory 清单内（30 项中 tools 条目为 0）。
    `round.py` 能写 docs/、能起子进程、能生成清单，属高权限工具；
    若自身不受指纹保护，任何改动都无法被发现。
  - 只读守卫原为黑名单（硬编码 "/Volumes/NO NAME/128"），
    新增只读挂载点或路径绕过即失效。

对应修复：
  tools/round.py
    - 新增 TOOL_FILES，把 5 个 tools 文件纳入 CONTROLLED 清单
    - _guard_write() 改为「必须位于项目根目录内」的白名单判定，
      黑名单降级为辅助防线

本文件独立可跑：
  pytest tests/test_round5_tools_inventory.py -v
"""
import os
import sys
import json

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

TOOLS_DIR = os.path.join(PROJECT_ROOT, "tools")
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import round as round_tool  # noqa: E402

# R28 / A-53：模块级 importlib.reload(round_tool) 已删除。
# 此处刚完成首次 import，reload 无任何语义收益，反而在跨文件跑序下制造模块身份分裂。


# ═══════════════════════════════════════════════════════════════
# A-19 之一：tools/ 必须纳入受控清单
# ═══════════════════════════════════════════════════════════════
TOOL_PATHS = [
    "tools/round.py",
    "tools/dsh-plugin/package.json",
    "tools/dsh-plugin/cordis.patch.yml",
    "tools/dsh-plugin/index.js",
    "tools/dsh-plugin/README.md",
]


def test_tool_files_are_in_controlled_list():
    """A-19 核心：tools 文件必须在 CONTROLLED 清单里"""
    controlled = round_tool.CONTROLLED
    missing = [p for p in TOOL_PATHS if p not in controlled]
    assert not missing, f"以下工具文件未纳入受控清单: {missing}"


def test_inventory_includes_tools_with_hashes():
    """A-19 核心：生成的清单必须真实包含 tools 条目及其 sha256"""
    inv = round_tool.build_inventory("a19-selftest")

    for path in TOOL_PATHS:
        assert path in inv["files"], f"清单缺少 {path}"
        meta = inv["files"][path]
        assert meta.get("sha256"), f"{path} 无 sha256"
        assert len(meta["sha256"]) == 64, f"{path} sha256 长度异常"
        assert meta.get("size", 0) > 0, f"{path} size 异常"


def test_inventory_count_matches_controlled():
    """清单项数必须等于受控清单长度，不得静默丢项"""
    inv = round_tool.build_inventory("a19-selftest")
    assert inv["count"] == len(round_tool.CONTROLLED)
    assert inv["missing"] == [], f"存在缺失文件: {inv['missing']}"


def test_round_py_itself_is_hashed():
    """工具本体受保护：round.py 必须出现在清单且哈希可复算"""
    import hashlib
    inv = round_tool.build_inventory("a19-selftest")
    assert "tools/round.py" in inv["files"]

    real = hashlib.sha256(
        open(os.path.join(PROJECT_ROOT, "tools/round.py"), "rb").read()
    ).hexdigest()
    assert inv["files"]["tools/round.py"]["sha256"] == real


# ═══════════════════════════════════════════════════════════════
# A-19 之二：写入守卫必须白名单优先
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("rel_or_abs", [
    "docs/anything.md",
    "tools/tmp.txt",
    "tests/reports/x.json",
])
def test_guard_allows_paths_inside_project(rel_or_abs):
    """项目内路径必须放行（避免误拦截正常工作流）"""
    target = os.path.join(PROJECT_ROOT, rel_or_abs)
    round_tool._guard_write(target)   # 不抛异常即通过


@pytest.mark.parametrize("outside", [
    "/Volumes/NO NAME/128/x.md",
    "/Volumes/NO NAME/128/sub/dir/y.log",
    "/tmp/x.md",
    "/etc/x",
])
def test_guard_rejects_paths_outside_project(outside):
    """项目外路径必须拒绝——白名单策略，无需穷举每个只读卷"""
    with pytest.raises(SystemExit):
        round_tool._guard_write(outside)


def test_guard_rejects_sibling_project_with_same_name():
    """
    A-19 关键：项目根的「前缀相似」路径不得被误放行。
    旧实现若用 startswith(root) 无分隔符判断，会放过 root+"_evil"。
    """
    evil = PROJECT_ROOT + "_evil" + os.sep + "x.md"
    with pytest.raises(SystemExit):
        round_tool._guard_write(evil)


def test_guard_allows_project_root_itself():
    """项目根本身允许（用于目录级操作）"""
    round_tool._guard_write(PROJECT_ROOT)


def test_guard_uses_whitelist_not_blacklist_only():
    """
    A-19 核心：即使某路径不在黑名单里，只要在项目外就必须被拒绝。
    用一个虚构的、从未被硬编码过的路径来证明白名单生效。
    """
    never_listed = "/Volumes/SomeFutureReadOnlyVolume/never_listed/x.md"
    with pytest.raises(SystemExit):
        round_tool._guard_write(never_listed)
