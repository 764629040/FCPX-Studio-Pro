"""
R21-T4 批量处理断点续跑单测

缺口：批量处理中途失败无 checkpoint、无续跑入口，50 个挂第 37 个只能从头来。
实现：core/batch_runner.py 的 BatchRunner（状态落盘 .batch_state.json，原子写，
      每项完成立即写盘；resume_task 只跑 pending+failed；retry_failed 只重试 failed）。

断言：
  1. 造 5 任务第 3 个注入失败 → 2 done / 1 failed / 2 pending
  2. resume_task 后只重试失败项，done 未被重复处理（计数器断言）
  3. 每项完成后状态已更新（中断后重新加载能看到已完成项）
  4. 原子写——写过程中抛异常，原状态文件不被破坏
"""
import os
import sys
import json

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.batch_runner import BatchRunner


def _load(state_path):
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def _make_items(n, base):
    """造 n 个 (source, target) 对，target 用 base 下的绝对路径"""
    return [(f"src_{i}.psd", os.path.join(base, f"tgt_{i}")) for i in range(n)]


def _tgt(base, i):
    return os.path.join(base, f"tgt_{i}")


def _make_executor(fail_on=None, counter=None, make_target=None):
    """
    造一个 executor：
      - fail_on: 第几个 item 注入失败（0-based）
      - counter: 计数 dict，记录每个 target 被执行次数
      - make_target: 是否为 target 造目录内容
    """
    def executor(item):
        idx = int(os.path.basename(item["target"]).split("_")[1])
        if counter is not None:
            counter[item["target"]] = counter.get(item["target"], 0) + 1
        if idx == fail_on:
            raise RuntimeError(f"注入失败: {item['target']}")
        if make_target:
            os.makedirs(item["target"], exist_ok=True)
            with open(os.path.join(item["target"], "done.txt"), "w") as f:
                f.write("ok")
    return executor


def test_t4_failure_marks_and_keeps_pending(tmp_path):
    """T4-1：5 任务第 3 个失败 → 2 done / 1 failed / 2 pending"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_items(5, str(tmp_path))
    runner = BatchRunner(_make_executor(fail_on=2, make_target=True))

    runner.run_new(items, state_path)

    state = _load(state_path)
    counts = {"done": 0, "failed": 0, "pending": 0}
    for it in state["items"]:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
    assert counts["done"] == 2, f"前 2 个应 done: {counts}"
    assert counts["failed"] == 1, f"第 3 个应 failed: {counts}"
    assert counts["pending"] == 2, f"第 4、5 个应 pending: {counts}"


def test_t4_resume_skips_done_and_retries_failed(tmp_path):
    """T4-2：resume 后只重试失败项，done 未被重复处理"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_items(5, str(tmp_path))
    counter = {}
    base = str(tmp_path)
    # 第一轮：第 3 个失败
    runner = BatchRunner(_make_executor(fail_on=2, counter=counter, make_target=True))
    runner.run_new(items, state_path)

    assert counter[_tgt(base, 0)] == 1
    assert counter[_tgt(base, 2)] == 1

    # 第二轮：不再注入失败，验证 resume
    runner2 = BatchRunner(_make_executor(fail_on=None, counter=counter, make_target=True))
    runner2.resume_task(state_path)

    # done 的（tgt_0, tgt_1）不应被再次执行
    assert counter[_tgt(base, 0)] == 1, "已 done 的项不应被重复执行"
    assert counter[_tgt(base, 1)] == 1, "已 done 的项不应被重复执行"
    # failed 的（tgt_2）被重试
    assert counter[_tgt(base, 2)] == 2, f"failed 项应被重试一次，实际 {counter[_tgt(base, 2)]} 次"
    # pending 的（tgt_3, tgt_4）被续跑
    assert counter[_tgt(base, 3)] == 1
    assert counter[_tgt(base, 4)] == 1

    state = _load(state_path)
    for it in state["items"]:
        assert it["status"] == "done", f"resume 后全部应 done: {it['target']}={it['status']}"


def test_t4_progress_persisted_after_each_item(tmp_path):
    """T4-3：每项完成后状态已更新（模拟中断后重新加载能看到已完成项）"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_items(3, str(tmp_path))
    base = str(tmp_path)
    # 造一个 executor：第 2 项抛异常，模拟中断
    def executor(item):
        idx = int(os.path.basename(item["target"]).split("_")[1])
        if idx == 2:
            raise RuntimeError("模拟中断")
        os.makedirs(item["target"], exist_ok=True)
        with open(os.path.join(item["target"], "done.txt"), "w") as f:
            f.write("ok")

    runner = BatchRunner(executor)
    runner.run_new(items, state_path)

    # 重新加载状态，能看到已完成项
    state = _load(state_path)
    done = [it["target"] for it in state["items"] if it["status"] == "done"]
    assert _tgt(base, 0) in done, "第 0 项完成后应已落盘"
    assert _tgt(base, 1) in done, "第 1 项完成后应已落盘"


def test_t4_atomic_write_preserves_original_on_error(tmp_path):
    """T4-4：原子写——写过程中抛异常，原状态文件不被破坏"""
    state_path = str(tmp_path / ".batch_state.json")
    items = _make_items(2, str(tmp_path))
    runner = BatchRunner(_make_executor(make_target=True))
    runner.run_new(items, state_path)

    # 记录原状态
    original = _load(state_path)

    # 先构造一个未全部 done 的状态：把第 2 项改成 pending
    state = _load(state_path)
    state["items"][1]["status"] = "pending"
    runner._save(state_path, state)

    # 让 json.dump 抛异常（注入到 batch_runner 模块的 json.dump）
    import core.batch_runner as br
    original_dump = br.json.dump
    def _bad_dump(*a, **kw):
        raise RuntimeError("模拟写盘异常")
    br.json.dump = _bad_dump
    try:
        with pytest.raises(RuntimeError):
            runner.resume_task(state_path)  # 第 2 项 pending，触发写盘
    finally:
        br.json.dump = original_dump

    # 原状态文件应仍可读且未被破坏（原子写：写临时失败不影响原文件）
    state = _load(state_path)
    assert state["task_id"] == original["task_id"]
    assert len(state["items"]) == 2
