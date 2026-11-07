"""
R22 F-1 / F-2 逻辑级回归

F-1 (T3 GUI 历史版本管理) 的底层契约：
  - list_versions 必须能发现 F-4 之后的隐藏前缀备份 .{name}_bak_*（旧版非隐藏也要兼容）
  - delete_version 将单版本移入隐藏回收目录 .{name}_trash_*（不直接删）
  - restore_version 对隐藏备份仍可恢复，并产生新的隐藏备份

F-2 (T4 GUI 批量断点续跑) 的底层契约：
  - 真实批量执行器形状（写 target + .moti）下，第 3 项中断 → 2 done / 1 failed / 2 pending
  - resume 只续跑未完成且已完成项不被重复执行（计数器断言）
  - retry_failed 只重试 failed

注：GUI 交互（右键菜单、进度条、续跑弹窗）需真机 PyQt6 显示环境，
    此处只覆盖它们依赖的 core 契约；GUI 接线代码另见 gui/asset_hub_panel.py / gui/main_window.py。
"""
import os
import sys
import time
import json

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.template_versions import (
    list_versions, restore_version, prune_versions, delete_version,
)
from core.batch_runner import BatchRunner


# ───────────────────────── F-1 helpers ─────────────────────────

def _make_backup(parent, name, mtime=None, hidden=False, moti_content=None):
    """造一个 {name}_bak_<ts> 或 .{name}_bak_<ts> 目录（与 F-4 命名一致）"""
    prefix = f".{name}_bak_" if hidden else f"{name}_bak_"
    suffix = f"{time.strftime('%Y%m%d_%H%M%S')}_{int(mtime or 0)}"
    bak = os.path.join(parent, f"{prefix}{suffix}")
    os.makedirs(os.path.join(bak, "Media"), exist_ok=True)
    with open(os.path.join(bak, f"{name}.moti"), "w") as f:
        f.write(moti_content if moti_content is not None
                else '<?xml version="1.0"?><ozml><scene/></ozml>')
    if mtime is not None:
        os.utime(bak, (mtime, mtime))
    return bak


def test_f1_list_versions_finds_hidden_backup(tmp_path):
    """F-1-1：list_versions 必须能发现 F-4 默认隐藏前缀 .{name}_bak_* 备份"""
    name = "tplH"
    tdir = tmp_path / name
    os.makedirs(str(tdir))

    # 仅一个隐藏备份（F-4 之后的默认形态）
    _make_backup(str(tmp_path), name, mtime=2000, hidden=True)

    versions = list_versions(str(tdir))
    assert len(versions) == 1, f"隐藏备份应被发现，实际 {len(versions)}"
    assert versions[0].moti_ok is True
    assert os.path.basename(versions[0].path).startswith(f".{name}_bak_")


def test_f1_list_versions_merges_hidden_and_legacy(tmp_path):
    """F-1-2：隐藏 + 旧版非隐藏备份合并去重，倒序"""
    name = "tplM"
    tdir = tmp_path / name
    os.makedirs(str(tdir))
    _make_backup(str(tmp_path), name, mtime=1000, hidden=False)
    _make_backup(str(tmp_path), name, mtime=3000, hidden=True)
    versions = list_versions(str(tdir))
    assert len(versions) == 2
    assert versions[0].timestamp == 3000


def test_f1_delete_version_moves_to_hidden_trash(tmp_path):
    """F-1-3：删除单版本 → 移入隐藏回收目录，不再出现在版本列表"""
    name = "tplD"
    tdir = tmp_path / name
    os.makedirs(str(tdir))
    bak = _make_backup(str(tmp_path), name, mtime=1000, hidden=True)

    res = delete_version(str(tdir), bak)
    assert res["deleted"] is True
    assert not os.path.isdir(bak), "原备份应已被移走"
    assert os.path.isdir(res["moved_to"]), "应进入回收目录"

    # 回收目录为隐藏前缀
    trash_parent = os.path.dirname(res["moved_to"])
    tp = os.path.basename(trash_parent)
    assert tp.startswith(f".{name}_trash_"), f"回收目录应隐藏: {tp}"

    # 版本列表应清空
    assert list_versions(str(tdir)) == [], "删除后版本列表应为空"


def test_f1_restore_from_hidden_backup(tmp_path):
    """F-1-4：从隐藏备份恢复，内容等于目标版本，并产生新的隐藏备份"""
    name = "tplR"
    tdir = tmp_path / name
    os.makedirs(str(tdir))
    with open(os.path.join(str(tdir), f"{name}.moti"), "w") as f:
        f.write('<?xml version="1.0"?><ozml><scene v="cur"/></ozml>')

    v2 = _make_backup(str(tmp_path), name, mtime=5000, hidden=True,
                      moti_content='<?xml version="1.0"?><ozml><scene v="2"/></ozml>')

    res = restore_version(str(tdir), v2)
    assert res["restored"] is True
    with open(os.path.join(str(tdir), f"{name}.moti")) as f:
        assert 'v="2"' in f.read(), "恢复后内容应等于目标版本"

    # 新备份应为隐藏前缀
    bp = os.path.basename(res["backup_path"])
    assert bp.startswith(f".{name}_bak_"), f"恢复产生的新备份应隐藏: {bp}"
    assert list_versions(str(tdir))  # 新备份可见


# ───────────────────────── F-2 helpers ─────────────────────────

def _make_batch_items(n, base):
    return [(f"src_{i}.psd", os.path.join(base, f"tgt_{i}")) for i in range(n)]


def _load(state_path):
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def _tgt(base, i):
    return os.path.join(base, f"tgt_{i}")


def _batch_executor(fail_on=None, counter=None):
    """
    模拟 GUI 批量执行器形状：成功则向 target 写入 .moti（使 _is_complete 成立），
    失败则抛异常。counter 记录每个 target 实际执行次数。
    """
    def executor(item):
        idx = int(os.path.basename(item["target"]).split("_")[1])
        if counter is not None:
            counter[item["target"]] = counter.get(item["target"], 0) + 1
        if idx == fail_on:
            raise RuntimeError(f"注入失败: {item['target']}")
        os.makedirs(item["target"], exist_ok=True)
        with open(os.path.join(item["target"], f"{idx}.moti"), "w") as f:
            f.write('<?xml version="1.0"?><ozml><scene/></ozml>')
    return executor


def test_f2_interrupt_at_third_then_resume(tmp_path):
    """F-2-1：第 3 项（idx=2）中断 → 2 done/1 failed/2 pending；resume 只续跑剩余且已完成不重跑"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_batch_items(5, str(tmp_path))
    base = str(tmp_path)
    counter = {}

    # 第一轮：第 3 项失败
    runner = BatchRunner(_batch_executor(fail_on=2, counter=counter))
    runner.run_new(items, state_path)

    state = _load(state_path)
    counts = {"done": 0, "failed": 0, "pending": 0}
    for it in state["items"]:
        counts[it["status"]] += 1
    assert counts["done"] == 2, f"前 2 个应 done: {counts}"
    assert counts["failed"] == 1, f"第 3 个应 failed: {counts}"
    assert counts["pending"] == 2, f"第 4、5 个应 pending: {counts}"

    # 第二轮：resume（不再失败）
    runner2 = BatchRunner(_batch_executor(fail_on=None, counter=counter))
    runner2.resume_task(state_path)

    # 已完成（tgt_0, tgt_1）不应被再执行
    assert counter[_tgt(base, 0)] == 1, "已 done 不应重跑"
    assert counter[_tgt(base, 1)] == 1, "已 done 不应重跑"
    # 失败项被重试
    assert counter[_tgt(base, 2)] == 2, f"failed 应重试一次: {counter[_tgt(base, 2)]}"
    # 续跑项被执行
    assert counter[_tgt(base, 3)] == 1
    assert counter[_tgt(base, 4)] == 1

    state = _load(state_path)
    assert all(it["status"] == "done" for it in state["items"]), "resume 后全部 done"


def test_f2_retry_failed_only(tmp_path):
    """F-2-2：retry_failed 只重试 failed 项，不碰 pending/done"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_batch_items(5, str(tmp_path))
    base = str(tmp_path)
    counter = {}

    BatchRunner(_batch_executor(fail_on=2, counter=counter)).run_new(items, state_path)

    # 只重试失败项（仍注入同一失败，验证只 touch failed）
    runner2 = BatchRunner(_batch_executor(fail_on=2, counter=counter))
    runner2.retry_failed(state_path)

    assert counter[_tgt(base, 0)] == 1, "done 不应被 retry 触碰"
    assert counter[_tgt(base, 1)] == 1
    assert counter[_tgt(base, 2)] == 2, "failed 应被重试"
    assert counter.get(_tgt(base, 3), 0) == 0, "pending 不应被 retry 触碰"
    assert counter.get(_tgt(base, 4), 0) == 0

    state = _load(state_path)
    failed = [it for it in state["items"] if it["status"] == "failed"]
    pending = [it for it in state["items"] if it["status"] == "pending"]
    assert len(failed) == 1 and len(pending) == 2, "retry 后结构不变（failed 仍 failed）"
