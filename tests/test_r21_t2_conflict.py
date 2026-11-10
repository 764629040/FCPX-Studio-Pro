"""
R21-T2 重名模板冲突预检单测

缺口：backup_existing=True 静默把已有目录 rename 成 _bak_<ts> 覆盖，
      用户不被告知"要覆盖已有模板"，存在数据丢失风险。
实现：build_template_atomic 新增 on_conflict 参数（backup/abort/ask）。

断言：
  1. on_conflict="abort" + 目标已存在 → 抛 TemplateConflictError，目标原样未动
  2. 默认 backup + 目标已存在 → 正常备份+覆盖（旧行为不回归）
  3. on_conflict="ask" + 回调返回 False → 不写入
"""
import os
import sys
import time
import tempfile
import glob
import hashlib

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder, TemplateConflictError

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _snapshot_dir(path):
    """取目录快照：文件列表 + 每个文件的 mtime + 目录 mtime"""
    files = {}
    for root, _, names in os.walk(path):
        for n in names:
            fp = os.path.join(root, n)
            files[fp] = (os.path.getmtime(fp), os.path.getsize(fp))
    dir_mtime = os.path.getmtime(path)
    return files, dir_mtime


def _first_build(tmp_path, name="existing_tpl"):
    """先构建一个模板目录，作为'已存在'的目标"""
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    out_dir = tmp_path / name
    mb.build_template_atomic(
        parsed["layers"], str(out_dir), "existing",
        psd_path=COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )
    return out_dir


def test_t2_abort_raises_and_target_untouched(tmp_path):
    """T2-1：abort 模式抛错，且目标目录原样未动（mtime+文件列表不变）"""
    existing = _first_build(tmp_path)
    before_files, before_dir_mtime = _snapshot_dir(str(existing))

    # 再构建一个同目标，用 abort
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    with pytest.raises(TemplateConflictError):
        mb.build_template_atomic(
            parsed["layers"], str(existing), "existing",
            psd_path=COMPLEX_PSD,
            canvas_size=(parsed["width"], parsed["height"]),
            on_conflict="abort",
        )

    after_files, after_dir_mtime = _snapshot_dir(str(existing))
    assert after_files == before_files, "abort 后目标目录文件列表不应变化"
    assert after_dir_mtime == before_dir_mtime, "abort 后目标目录 mtime 不应变化"


def _sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def test_t2_default_backup_uses_hidden_prefix(tmp_path):
    """T2-2（TR-009 更新）：默认 backup 一律移出 FCPX 扫描树，
    写 ~/Library/Application Support/FCPXStudio/backups/<分类>/<时间戳>_<名>，
    扫描树内不得残留任何 _bak_（可见或隐藏），且旧版本 .moti 内容保留在备份中。"""
    existing = _first_build(tmp_path)
    old_moti = os.path.join(str(existing), "existing.moti")
    old_sha = _sha256_of(old_moti)

    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    result = mb.build_template_atomic(
        parsed["layers"], str(existing), "existing",
        psd_path=COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
        # 不传 on_conflict，走默认 backup
    )
    assert result["status"] == "ok"
    assert os.path.isdir(str(existing)), "默认 backup 后目标目录应存在"

    parent = str(existing.parent)
    # 扫描树内不得有可见 _bak_ 目录
    visible_baks = glob.glob(os.path.join(parent, "*_bak_*"))
    assert visible_baks == [], f"扫描树内不得有可见 _bak_ 目录，实际: {visible_baks}"
    # 扫描树内也不得有隐藏 ._bak_ 目录（TR-009：备份彻底移出扫描树）
    hidden_baks = glob.glob(os.path.join(parent, ".*_bak_*"))
    assert hidden_baks == [], f"扫描树内不得有隐藏 ._bak_ 目录，实际: {hidden_baks}"

    # 备份应落到 App 资源目录（扫描树之外），并保留旧版本 .moti
    bak = result["backup_path"]
    assert bak, "应返回备份路径"
    assert "Library/Application Support/FCPXStudio/backups" in bak, \
        f"备份应落在 App 资源目录，实际: {bak}"
    assert not bak.startswith(parent), f"备份不得落在原目标父目录（扫描树）内: {bak}"
    cand = os.path.join(bak, "existing.moti")
    assert os.path.isfile(cand), f"备份应包含旧版本 .moti: {cand}"
    assert _sha256_of(cand) == old_sha, "备份应保留旧版本 .moti 内容"


def test_t2_ask_callback_false_blocks_write(tmp_path):
    """T2-3：ask 模式回调返回 False → 抛错且不写入"""
    existing = _first_build(tmp_path)
    before_files, before_dir_mtime = _snapshot_dir(str(existing))

    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()

    call_count = [0]
    def _deny(_path):
        call_count[0] += 1
        return False

    with pytest.raises(TemplateConflictError):
        mb.build_template_atomic(
            parsed["layers"], str(existing), "existing",
            psd_path=COMPLEX_PSD,
            canvas_size=(parsed["width"], parsed["height"]),
            on_conflict="ask",
            conflict_callback=_deny,
        )

    assert call_count[0] == 1, f"回调应被调用一次，实际 {call_count[0]} 次"
    after_files, after_dir_mtime = _snapshot_dir(str(existing))
    assert after_files == before_files, "ask 返回 False 后目标目录不应变化"
    assert after_dir_mtime == before_dir_mtime, "ask 返回 False 后目录 mtime 不应变化"
