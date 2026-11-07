"""
R22-A40 / R23-A41 模板唯一化单测

覆盖：
  - 安装前去重：真正的同源历史别名目录（如 `01_领衔呈现`）被移入隐藏回收站
  - R23/A-41 回归：裸编号目录 `1`（用户独立模板）即使与 T01 同处一分类，**不得被移走**
  - R23/A-41 内容级判据：名称别名命中但 .moti 内容明显非同源时，**默认不移动**（入 kept）
  - 安装后唯一性校验：parent 下无同源兄弟、目标内恰 1 .moti、Media 数符合
  - 唯一性失败路径：人为放置可见同源重复目录 → verify_unique_after_install 抛 TemplateUniquenessError
  - 处置报告字段完整（path/size/sha256/mtime/reason/moved_to）
"""
import os
import sys
import glob
import hashlib
import shutil

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder
from core import template_dedup as dd


DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def _build(name, out_dir, psd=COMPLEX_PSD):
    parsed = parse_psd_file(psd, extract_thumbnails=False)
    mb = MotionBuilder()
    return mb.build_template_atomic(
        parsed["layers"], str(out_dir), name,
        psd_path=psd,
        canvas_size=(parsed["width"], parsed["height"]),
    )


def _make_sibling(parent, sib_name, src_moti_dir, moti_text=None):
    """复制 src 模板的 .moti 到一个新的同源兄弟目录，构造历史版本。

    若传入 moti_text，则写入该文本作为 .moti（用于构造非同源内容）。
    """
    sib = os.path.join(str(parent), sib_name)
    os.makedirs(sib, exist_ok=True)
    if moti_text is None:
        src_moti = os.path.join(str(src_moti_dir), f"{os.path.basename(str(src_moti_dir))}.moti")
        shutil.copy2(src_moti, os.path.join(sib, f"{sib_name}.moti"))
    else:
        with open(os.path.join(sib, f"{sib_name}.moti"), "w", encoding="utf-8") as f:
            f.write(moti_text)
    return sib


def _visible_dirs(parent):
    return sorted(d for d in os.listdir(parent)
                  if not d.startswith(".") and os.path.isdir(os.path.join(parent, d)))


def test_a40_dedup_moves_homologous_siblings(tmp_path):
    parent = tmp_path / "PSD婚礼字幕"
    os.makedirs(parent, exist_ok=True)
    target = parent / "T01_领衔呈现_竖版"

    # 第一次构建：无历史版本
    res1 = _build("T01_领衔呈现_竖版", target)
    assert res1["status"] == "ok"
    assert res1["dedup_report"]["scanned"] == 0

    # 人为放置：真正的同源历史别名 01_领衔呈现（去前缀别名，命中 derive_template_aliases）
    # 以及无关裸编号目录 1（用户独立模板，R23 后不可再被当作别名移走）
    _make_sibling(parent, "01_领衔呈现", target)
    _make_sibling(parent, "1", target)

    # 重新安装（覆盖）→ 去重应只把同源别名 01_领衔呈现 移入隐藏回收站
    res2 = _build("T01_领衔呈现_竖版", target)
    assert res2["status"] == "ok"
    report = res2["dedup_report"]
    moved_names = {os.path.basename(m["path"]) for m in report["moved"]}
    assert "01_领衔呈现" in moved_names, f"同源别名 01_领衔呈现 应被移出，报告: {report}"

    # R23/A-41：无关裸编号目录 1 不得被移走，且必须仍然可见
    assert "1" not in moved_names, f"R23/A-41：无关裸编号目录 1 不得被移走，报告: {report}"
    assert os.path.isdir(os.path.join(parent, "1")), "无关目录 1 应保留在扫描树内"

    # parent 下可见目录仅剩 T01 目标自身与无关的 1（历史版本与备份均为隐藏）
    assert _visible_dirs(parent) == ["1", "T01_领衔呈现_竖版"], \
        f"可见目录应只剩目标与无关 1，实际: {_visible_dirs(parent)}"

    # 安装后唯一性校验通过（无同源兄弟）
    sibs = dd.scan_homologous_siblings(str(target))
    assert sibs == [], f"安装后不应有同源兄弟，实际: {sibs}"


def test_a40_uniqueness_failure_raises(tmp_path):
    parent = tmp_path / "PSD婚礼字幕"
    os.makedirs(parent, exist_ok=True)
    target = parent / "T01_领衔呈现_竖版"
    _build("T01_领衔呈现_竖版", target)

    # 人为放置一个可见的同源重复目录（模拟未被去重清理的残留：命中别名 01_领衔呈现）
    _make_sibling(parent, "01_领衔呈现", target)
    with pytest.raises(dd.TemplateUniquenessError):
        dd.verify_unique_after_install(
            str(target),
            _sha(os.path.join(str(target), "T01_领衔呈现_竖版.moti")),
            dd._media_count(str(target)),
            extra_aliases=dd.derive_template_aliases("T01_领衔呈现_竖版"),
        )


def test_a40_report_contains_reason_and_metadata(tmp_path):
    parent = tmp_path / "PSD婚礼字幕"
    os.makedirs(parent, exist_ok=True)
    target = parent / "T01_领衔呈现_竖版"
    _build("T01_领衔呈现_竖版", target)
    _make_sibling(parent, "01_领衔呈现", target)

    res = _build("T01_领衔呈现_竖版", target)
    report = res["dedup_report"]
    assert len(report["moved"]) == 1
    entry = report["moved"][0]
    for k in ("path", "size", "sha256", "mtime", "reason", "moved_to"):
        assert k in entry, f"处置报告缺字段 {k}"
    assert entry["reason"], "应给出移出原因"
    # 移出目标为隐藏回收目录
    assert os.path.basename(os.path.dirname(entry["moved_to"])).startswith(
        ".T01_领衔呈现_竖版_trash_")


def test_a40_unrelated_bare_number_not_moved(tmp_path):
    """R23/A-41 核心回归：无关裸编号目录（用户独立模板）即使同处一个分类，也不得被移走。"""
    parent = tmp_path / "PSD婚礼字幕"
    os.makedirs(parent, exist_ok=True)
    target = parent / "T01_领衔呈现_竖版"
    res1 = _build("T01_领衔呈现_竖版", target)
    assert res1["status"] == "ok"

    # 放置一个无关裸编号目录 1，内含完全不同内容的 .moti（独立模板）
    _make_sibling(
        parent, "1", target,
        moti_text='<?xml version="1.0" encoding="UTF-8"?>'
                  '<ozml version="5.14"><title name="完全无关的字幕">'
                  '<text>hi</text></title></ozml>',
    )

    res2 = _build("T01_领衔呈现_竖版", target)
    report = res2["dedup_report"]
    moved_names = {os.path.basename(m["path"]) for m in report["moved"]}
    assert "1" not in moved_names, "R23/A-41：无关裸编号目录 1 不得被移走"
    assert os.path.isdir(os.path.join(parent, "1")), "无关目录 1 应保留在扫描树内"
    # 无同源兄弟残留 → 安装后唯一性校验通过
    assert dd.scan_homologous_siblings(str(target)) == []


def test_a40_name_alias_but_content_unrelated_is_kept(tmp_path):
    """R23/A-41 内容级判据：名称别名命中（01_领衔呈现），但 .moti 内容明显非同源 → 默认不移动。"""
    parent = tmp_path / "PSD婚礼字幕"
    os.makedirs(parent, exist_ok=True)
    target = parent / "T01_领衔呈现_竖版"
    _build("T01_领衔呈现_竖版", target)

    # 01_领衔呈现 命中 derive_template_aliases，但内容是另一个完全不同的模板
    sib = _make_sibling(
        parent, "01_领衔呈现", target,
        moti_text='<?xml version="1.0" encoding="UTF-8"?>'
                  '<ozml version="5.14"><title name="另一个完全不同的模板">'
                  '<text>xyz</text></title></ozml>',
    )

    res = _build("T01_领衔呈现_竖版", target)
    report = res["dedup_report"]
    moved_names = {os.path.basename(m["path"]) for m in report["moved"]}
    kept_names = {os.path.basename(k["path"]) for k in report["kept"]}

    assert "01_领衔呈现" not in moved_names, \
        "名称别名命中但内容非同源时不得移动"
    assert "01_领衔呈现" in kept_names, \
        "无法确认同源的目录应进入 kept（默认不移动，交人工复核）"
    assert os.path.isdir(sib), "01_领衔呈现 应保留在扫描树内（未被移走）"
    # kept 条目应带「无法确认同源」原因
    assert any("无法确认同源" in k["reason"] for k in report["kept"]), \
        f"kept 应说明无法确认同源: {report['kept']}"
