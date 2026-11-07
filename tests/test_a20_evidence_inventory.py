"""
回归测试：A-20（审核证据文件未入清单 + 证据生成脚本不可复现）

审核发现（第八轮）：
  1. `docs/a16_evidence/` 下 6 个证据文件未纳入指纹清单，
     可被替换而无人察觉 —— 证据链可信度无从谈起。
  2. 生成 `unverifiable` 截图的脚本不在项目内（原为 /tmp 临时脚本），
     第三方拿到交付物无法复现该截图。

对应修复：
  tools/round.py                —— 新增 EVIDENCE_FILES，纳入 6 个证据文件；
                                    TOOL_FILES 增加 make_a16_evidence.py
  tools/make_a16_evidence.py    —— 新增：四态证据生成器（可在项目内逐字节复现）

本文件独立可跑：
  pytest tests/test_a20_evidence_inventory.py -v
"""
import os
import sys
import hashlib

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

TOOLS_DIR = os.path.join(PROJECT_ROOT, "tools")
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import round as round_tool  # noqa: E402

# R28 / A-53：模块级 importlib.reload(round_tool) 已删除（理由同 test_round5_tools_inventory.py）。

EVIDENCE_DIR = os.path.join(PROJECT_ROOT, "docs", "a16_evidence")
GENERATOR = os.path.join(TOOLS_DIR, "make_a16_evidence.py")

EXPECTED_EVIDENCE = [
    "docs/a16_evidence/A16_detected.png",
    "docs/a16_evidence/A16_missing_fallback.png",
    "docs/a16_evidence/A16_font_missing.png",
    "docs/a16_evidence/A16_unverifiable_canvas_noappkit.png",
    "docs/a16_evidence/A16_four_state_canvas_macos.png",
    "docs/a16_evidence/A16_font_and_state_evidence.json",
]


# ═══════════════════════════════════════════════════════════════
# A-20 之一：证据文件必须受指纹保护
# ═══════════════════════════════════════════════════════════════
def test_evidence_files_are_controlled():
    """A-20 核心：6 个证据文件必须在 CONTROLLED 清单里"""
    missing = [p for p in EXPECTED_EVIDENCE if p not in round_tool.CONTROLLED]
    assert not missing, f"以下证据文件未纳入受控清单: {missing}"


def test_evidence_files_exist_on_disk():
    """清单里的证据文件必须真实存在，不得登记幽灵条目"""
    absent = [p for p in EXPECTED_EVIDENCE
              if not os.path.isfile(os.path.join(PROJECT_ROOT, p))]
    assert not absent, f"证据文件缺失: {absent}"


def test_inventory_records_evidence_hashes():
    """清单必须记录证据文件的 sha256，使其可被独立复算"""
    inv = round_tool.build_inventory("a20-selftest")
    for rel in EXPECTED_EVIDENCE:
        assert rel in inv["files"], f"清单缺少 {rel}"
        meta = inv["files"][rel]
        assert meta.get("sha256"), f"{rel} 无 sha256"
        assert len(meta["sha256"]) == 64
        assert meta.get("size", 0) > 0, f"{rel} size 异常"


def test_evidence_hash_matches_disk():
    """清单记录的哈希必须与磁盘实际内容一致（防止清单过期）"""
    inv = round_tool.build_inventory("a20-selftest")
    for rel in EXPECTED_EVIDENCE:
        real = hashlib.sha256(
            open(os.path.join(PROJECT_ROOT, rel), "rb").read()
        ).hexdigest()
        assert inv["files"][rel]["sha256"] == real, f"{rel} 哈希与磁盘不符"


def test_evidence_dir_has_no_uncontrolled_files():
    """
    A-20 纵深：证据目录里不允许出现「未纳入清单」的文件，
    否则新增证据可绕过指纹保护。
    """
    if not os.path.isdir(EVIDENCE_DIR):
        pytest.skip("证据目录不存在")
    controlled = {os.path.basename(p) for p in EXPECTED_EVIDENCE}
    actual = {n for n in os.listdir(EVIDENCE_DIR) if not n.startswith(".")}
    uncontrolled = actual - controlled
    assert not uncontrolled, f"证据目录存在未纳入清单的文件: {uncontrolled}"


# ═══════════════════════════════════════════════════════════════
# A-20 之二：证据生成脚本必须存在于项目内
# ═══════════════════════════════════════════════════════════════
def test_generator_script_exists():
    """A-20 核心：生成脚本必须在项目内，不得依赖已删除的临时文件"""
    assert os.path.isfile(GENERATOR), f"证据生成脚本缺失: {GENERATOR}"


def test_generator_script_is_controlled():
    """生成脚本自身必须受指纹保护"""
    assert "tools/make_a16_evidence.py" in round_tool.CONTROLLED


def test_generator_covers_all_four_states():
    """
    生成脚本必须覆盖四态，且明确标注 unverifiable 是「等价环境构造」。
    这条断言防止将来有人把等价构造写成「真机实拍」。
    """
    src = open(GENERATOR, encoding="utf-8").read()
    for state in ("detected", "missing_fallback", "font_missing"):
        assert state in src, f"生成脚本未覆盖 {state}"
    assert "unverifiable" in src
    # 必须如实披露方法性质
    assert "等价环境构造" in src, "生成脚本未标注 unverifiable 的方法性质"
    assert "非 macOS 真机实拍" in src, "生成脚本未声明这不是真机实拍"


def test_generator_uses_subprocess_for_unverifiable():
    """
    unverifiable 必须在子进程内拦截，不能在本进程直接改 builtins——
    否则会污染同进程内其他测试，且无法可靠回退已导入的 AppKit。
    """
    src = open(GENERATOR, encoding="utf-8").read()
    assert "subprocess" in src, "未使用子进程"
    assert "_fake" in src or "__import__" in src, "未见拦截逻辑"


def test_generator_guard_is_whitelist():
    """生成脚本的写入守卫同样必须是白名单策略"""
    src = open(GENERATOR, encoding="utf-8").read()
    assert "_guard_write" in src
    assert "项目根目录之外" in src or "startswith(root" in src


# ═══════════════════════════════════════════════════════════════
# 交叉：证据与清单的完整性
# ═══════════════════════════════════════════════════════════════
def test_inventory_count_reflects_evidence_addition():
    """清单项数必须包含证据文件（35 → 42）"""
    inv = round_tool.build_inventory("a20-selftest")
    assert inv["count"] == len(round_tool.CONTROLLED)
    assert inv["count"] >= 42, f"项数偏少，证据可能未纳入: {inv['count']}"
    assert inv["missing"] == [], f"存在缺失文件: {inv['missing']}"
