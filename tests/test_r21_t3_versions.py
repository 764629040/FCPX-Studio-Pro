"""
R21-T3 模板版本管理单测

缺口：_bak_<ts> 只产生不消费，无列表/恢复/保留策略。
实现：core/template_versions.py 提供 list_versions / restore_version / prune_versions。

断言：
  1. list_versions：造 3 个版本 → 返回 3 条且倒序正确
  2. restore_version：恢复后内容等于目标版本，且多出一个新备份
  3. prune_versions(keep=2)：剩 2 个，被删的进了回收目录而非消失
  4. moti_ok：故意损坏的 .moti 返回 False
"""
import os
import sys
import time
import shutil

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.template_versions import (
    list_versions, restore_version, prune_versions,
)


def _make_backup(parent, name, mtime=None, moti_content=None):
    """在 parent 下造一个 {name}_bak_<ts> 目录（用 mtime 保证同秒内不撞名）"""
    # 用 mtime 数值作为后缀的一部分，避免同一秒内多次调用产生相同目录名
    suffix = f"{time.strftime('%Y%m%d_%H%M%S')}_{int(mtime or 0)}"
    bak = os.path.join(parent, f"{name}_bak_{suffix}")
    os.makedirs(os.path.join(bak, "Media"), exist_ok=True)
    with open(os.path.join(bak, f"{name}.moti"), "w") as f:
        f.write(moti_content if moti_content is not None else
                '<?xml version="1.0"?><ozml><scene/></ozml>')
    if mtime is not None:
        os.utime(bak, (mtime, mtime))
    return bak


def test_t3_list_versions_returns_descending(tmp_path):
    """T3-1：造 3 个版本 → list_versions 返回 3 条且倒序"""
    name = "tpl3"
    tdir = tmp_path / name
    os.makedirs(str(tdir))

    t1 = _make_backup(str(tmp_path), name, mtime=1000)
    t2 = _make_backup(str(tmp_path), name, mtime=2000)
    t3 = _make_backup(str(tmp_path), name, mtime=3000)

    versions = list_versions(str(tdir))
    assert len(versions) == 3, f"应返回 3 条，实际 {len(versions)}"
    assert versions[0].timestamp == 3000, "最新应排第一"
    assert versions[1].timestamp == 2000
    assert versions[2].timestamp == 1000
    for v in versions:
        assert v.moti_ok is True, "合法 .moti 应 moti_ok=True"


def test_t3_restore_creates_new_backup(tmp_path):
    """T3-2：恢复后内容等于目标版本，且现行版本被备份（多出一个新备份）"""
    name = "tpl2"
    tdir = tmp_path / name
    os.makedirs(str(tdir))
    # 现行版本写入 v1 内容
    with open(os.path.join(str(tdir), f"{name}.moti"), "w") as f:
        f.write('<?xml version="1.0"?><ozml><scene/></ozml>')

    # 造一个 v2 备份
    v2 = _make_backup(str(tmp_path), name, mtime=5000,
                      moti_content='<?xml version="1.0"?><ozml><scene v="2"/></ozml>')

    result = restore_version(str(tdir), v2)
    assert result["restored"] is True
    assert result["backup_path"], "恢复前应产生一个新备份"

    # 内容等于目标版本
    with open(os.path.join(str(tdir), f"{name}.moti")) as f:
        content = f.read()
    assert 'v="2"' in content, "恢复后内容应等于目标版本"

    # 现行版本被备份：result.backup_path 存在且是 _bak_（兼容 F-4 隐藏前缀）
    assert os.path.isdir(result["backup_path"]), "新备份目录应存在"
    _bp = os.path.basename(result["backup_path"])
    assert _bp.startswith(f"{name}_bak_") or _bp.startswith(f".{name}_bak_"), (
        f"新备份应以 {name}_bak_ 或 .{name}_bak_ 开头: {_bp}"
    )

    # list_versions 应能看到这个新备份
    versions = list_versions(str(tdir))
    assert any(v.path == result["backup_path"] for v in versions), (
        "新备份应出现在 list_versions 结果中"
    )


def test_t3_prune_moves_to_trash_not_delete(tmp_path):
    """T3-3：prune(keep=2) 剩 2 个，被删的进了回收目录"""
    name = "tpl1"
    tdir = tmp_path / name
    os.makedirs(str(tdir))

    v1 = _make_backup(str(tmp_path), name, mtime=1000)
    v2 = _make_backup(str(tmp_path), name, mtime=2000)
    v3 = _make_backup(str(tmp_path), name, mtime=3000)

    removed = prune_versions(str(tdir), keep=2)
    assert len(removed) == 1, f"应移走 1 个，实际 {len(removed)}"
    assert os.path.isdir(removed[0]), "被删版本应进入回收目录而非消失"

    # 回收目录里的是最早的 v1（被移入 {name}_trash_* 下，兼容 F-4 隐藏前缀）
    trash_parent = os.path.dirname(removed[0])
    _tp = os.path.basename(trash_parent)
    assert _tp.startswith(f"{name}_trash_") or _tp.startswith(f".{name}_trash_"), (
        f"回收目录名应以 {name}_trash_ 或 .{name}_trash_ 开头: {trash_parent}"
    )

    # 剩余 2 个
    remaining = list_versions(str(tdir))
    assert len(remaining) == 2, f"应剩 2 个，实际 {len(remaining)}"


def test_t3_moti_ok_detects_corrupted(tmp_path):
    """T3-4：故意损坏的 .moti 返回 moti_ok=False"""
    name = "tpl4"
    tdir = tmp_path / name
    os.makedirs(str(tdir))

    bad = _make_backup(str(tmp_path), name, mtime=1000,
                       moti_content="<<<not valid xml>>>")
    versions = list_versions(str(tdir))
    assert len(versions) == 1
    assert versions[0].moti_ok is False, "损坏的 .moti 应 moti_ok=False"
