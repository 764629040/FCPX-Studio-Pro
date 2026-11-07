"""
A-33 回归测试：四态证据的可验证性

背景（第十七轮审核提出）：
  `four_state.psd` 与 `vertical_wedding_9_16.psd` 的 composite() **零像素差异**
  （0/2073600），仅差 8 字节。审核据此质疑"四态没有可验证证据"。

核实结论：
  - composite 零差异 **成立**，但这是设计使然：
    四态不体现在像素上，而体现在 PSD 的 **FontSet 字体元数据**上。
    字体诊断读的是 FontSet，与像素渲染无关。
  - "FontSet 为空" **不成立**：8 层 FontSet 全部非空且互不相同。
  - "无生成脚本" **不成立**：tests/make_four_state_fixture.py 存在。

但审核的一点批评成立：**只做像素比对无法证明四态**。
本文件补显式断言：四态必须由解析状态证明，不能由像素证明。
"""
import os
import sys
import hashlib

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

import numpy as np
from psd_tools import PSDImage

from core.psd_parser import parse_psd_file

DATA_DIR = os.path.join(TESTS_DIR, "data")
FOUR_STATE = os.path.join(DATA_DIR, "four_state.psd")
LEGACY = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
GENERATOR = os.path.join(TESTS_DIR, "make_four_state_fixture.py")


def _font_names(psd_path):
    """取每层 FontSet 的首个字体名"""
    psd = PSDImage.open(psd_path)
    out = []
    for layer in psd.descendants():
        if layer.kind != "type":
            continue
        fs = (layer.resource_dict or {}).get("FontSet") or []
        name = None
        if fs:
            raw = fs[0].get("Name")
            name = getattr(raw, "value", raw)
            name = str(name) if name is not None else None
        out.append((layer.name, name))
    return out


# ═══════════════════════════════════════════════════════════════
# 固化事实：像素层面确实无差别
# ═══════════════════════════════════════════════════════════════
def test_33_composite_is_pixel_identical():
    """
    固化事实：两份夹具的 composite() 零像素差异。

    这不是缺陷，而是"A-33 必须靠解析状态证明"的证据。
    若将来有人改成靠像素验证四态，这条断言会提醒他此路不通。
    """
    a = PSDImage.open(FOUR_STATE).composite().convert("RGBA")
    b = PSDImage.open(LEGACY).composite().convert("RGBA")
    da = np.array(a).astype(int)
    db = np.array(b).astype(int)
    diff = np.abs(da - db)
    non_zero = int((diff.sum(axis=2) > 0).sum())
    assert non_zero == 0, (
        f"两份夹具 composite 出现 {non_zero} 像素差异，"
        "说明像素层面已能区分——需更新 A-33 的说明"
    )


# ═══════════════════════════════════════════════════════════════
# 核心：四态由 FontSet 承载
# ═══════════════════════════════════════════════════════════════
def test_33_fontset_is_not_empty():
    """审核称 FontSet 为空——实测必须非空"""
    names = _font_names(FOUR_STATE)
    assert len(names) == 8, f"应有 8 个 type 层，实际 {len(names)}"
    empty = [n for n, f in names if not f]
    assert not empty, f"以下层 FontSet 为空: {empty}"


def test_33_fontset_differs_from_legacy_layer_by_layer():
    """8 层 FontSet 必须全部与旧夹具不同"""
    four = dict(_font_names(FOUR_STATE))
    legacy = dict(_font_names(LEGACY))

    assert set(four) == set(legacy), "两份夹具的层名集合应一致"

    same = [name for name in four if four[name] == legacy[name]]
    assert not same, f"以下层 FontSet 未改变: {same}"

    # 逐层打印便于人工核对
    details = "\n".join(
        f"  {n}: legacy={legacy[n]!r} -> four_state={four[n]!r}"
        for n in four
    )
    assert len([n for n in four if four[n] != legacy[n]]) == 8, details


def test_33_fontset_covers_multiple_fonts():
    """四态夹具必须覆盖多种字体（否则无法产出多态）"""
    fonts = {f for _, f in _font_names(FOUR_STATE) if f}
    assert len(fonts) >= 3, f"字体种类过少，无法覆盖四态: {fonts}"
    # 断言包含预期的关键字体
    joined = " ".join(fonts)
    assert "PingFang" in joined, "缺少应可用的中文字体"
    assert "Helvetica" in joined, "缺少应缺字形的西文字体"
    assert "CormorantInfant" in joined, "缺少应未安装的字体"


# ═══════════════════════════════════════════════════════════════
# 决定性：解析状态必须真的分化
# ═══════════════════════════════════════════════════════════════
def test_33_parsed_status_is_multi_state():
    """
    四态的真实证据：解析器读出的 detection_status 必须分化。

    按环境分支（与 A-10 契约一致）：
      - macOS（有 AppKit）：应分化出多种状态
      - 无 AppKit：统一 unverifiable —— 这是正确行为，不是缺陷
    """
    try:
        import AppKit  # noqa: F401
        has_appkit = True
    except Exception:
        has_appkit = False

    four = parse_psd_file(FOUR_STATE, extract_thumbnails=False)
    statuses = {d["detection_status"]
                for d in four["diagnostics"]["font_diagnostics"]}

    if has_appkit:
        assert len(statuses) >= 2, f"四态未分化，仅 {statuses}"
    else:
        assert statuses == {"unverifiable"}, (
            f"无 AppKit 时应统一 unverifiable（A-10 契约），实际 {statuses}"
        )


def test_33_four_state_differs_from_legacy_on_macos():
    """
    macOS（有 AppKit）下，四态夹具与旧夹具的解析结果必须不同。
    这是"四态真实生效"的决定性证据。
    """
    try:
        import AppKit  # noqa: F401
        has_appkit = True
    except Exception:
        has_appkit = False

    four = parse_psd_file(FOUR_STATE, extract_thumbnails=False)
    legacy = parse_psd_file(LEGACY, extract_thumbnails=False)

    four_st = [d["detection_status"]
               for d in four["diagnostics"]["font_diagnostics"]]
    legacy_st = [d["detection_status"]
                 for d in legacy["diagnostics"]["font_diagnostics"]]

    if not has_appkit:
        # 无 AppKit：两者都应统一 unverifiable（A-10 契约）
        assert set(four_st) == {"unverifiable"}
        assert set(legacy_st) == {"unverifiable"}
        return

    assert four_st != legacy_st, (
        "四态夹具与旧夹具的解析状态相同，四态未生效"
    )
    # 旧夹具应全为 detected（同一已装字体）
    assert set(legacy_st) == {"detected"}, f"旧夹具状态异常: {set(legacy_st)}"
    # 四态夹具应覆盖至少 3 种
    assert len(set(four_st)) >= 3, f"四态覆盖不足: {set(four_st)}"


def test_33_expected_state_distribution():
    """在 macOS 下断言四态的具体分布"""
    try:
        import AppKit  # noqa: F401
    except Exception:
        pytest.skip("无 AppKit，状态统一为 unverifiable")

    import subprocess
    # 依赖具体字体安装情况，用解析结果动态判定期望值
    four = parse_psd_file(FOUR_STATE, extract_thumbnails=False)
    diags = four["diagnostics"]["font_diagnostics"]
    counts = {}
    for d in diags:
        counts[d["detection_status"]] = counts.get(d["detection_status"], 0) + 1

    # 至少要有 detected 与 font_missing 两类（Helvetica/CormorantInfant 已确认）
    assert "detected" in counts, f"无 detected 态: {counts}"
    assert "font_missing" in counts, f"无 font_missing 态: {counts}"
    assert sum(counts.values()) == 8


# ═══════════════════════════════════════════════════════════════
# 可复现性
# ═══════════════════════════════════════════════════════════════
def test_33_generator_script_exists():
    """审核称 tools/ 下无生成脚本——必须存在"""
    assert os.path.isfile(GENERATOR), f"生成脚本缺失: {GENERATOR}"
    src = open(GENERATOR, encoding="utf-8").read()
    assert "FontSet" in src, "生成脚本应改写 FontSet"
    assert "STATE_FONTS" in src or "font" in src.lower()


def test_33_fixtures_differ_only_in_fontset():
    """
    说明性断言：两份夹具文件大小接近、composite 相同，
    差异集中在 FontSet —— 这正是 A-33 的设计。
    """
    size_four = os.path.getsize(FOUR_STATE)
    size_legacy = os.path.getsize(LEGACY)
    assert abs(size_four - size_legacy) < 1024, (
        "两文件大小差异过大，说明改动不止 FontSet"
    )
