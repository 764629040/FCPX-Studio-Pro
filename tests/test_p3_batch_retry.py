"""P3 批量：单项目动重试 + 严格幂等判定 + 执行结果留痕单测。

覆盖 core/batch_runner.py 在 P3 批量场景新增的行为：
  1. max_retries 内自动重试，耗尽后落 failed，attempts 记录实际尝试次数；
  2. 注入的 is_complete 严格判定优先于「目录非空」，半成品空目录不误判完成；
  3. executor 返回值记入 item["result"]。
"""
import os
import sys
import json

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.batch_runner import BatchRunner  # noqa: E402


def _load(state_path):
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def test_auto_retry_records_attempts_then_fails(tmp_path):
    """max_retries=1：失败项尝试 2 次后落 failed，其余保持 pending。"""
    state_path = str(tmp_path / ".batch_state.json")
    items = [("s0.png", str(tmp_path / "t0")), ("s1.png", str(tmp_path / "t1"))]

    def executor(item):
        raise RuntimeError("固定失败")

    runner = BatchRunner(executor, max_retries=1)
    runner.run_new(items, state_path)

    state = _load(state_path)
    failed = [it for it in state["items"] if it["status"] == "failed"]
    pending = [it for it in state["items"] if it["status"] == "pending"]
    assert len(failed) == 1
    assert len(pending) == 1
    assert failed[0]["attempts"] == 2, f"应尝试 2 次: {failed[0].get('attempts')}"


def test_strict_complete_check_not_fooled_by_empty_dir(tmp_path):
    """空目录在严格判定下不算完成：不会被幂等跳过。"""
    state_path = str(tmp_path / ".batch_state.json")
    target = str(tmp_path / "t0")
    os.makedirs(target, exist_ok=True)  # 半成品空目录（失败时先建目录再抛错）
    items = [("s0.png", target)]

    def executor(item):
        os.makedirs(item["target"], exist_ok=True)
        with open(os.path.join(item["target"], "分层清单.json"), "w") as f:
            f.write("{}")

    def strict_complete(t):
        return os.path.isfile(os.path.join(t, "分层清单.json"))

    runner = BatchRunner(executor, is_complete=strict_complete)
    runner.run_new(items, state_path)

    state = _load(state_path)
    assert state["items"][0]["status"] == "done"

    # 模拟上次失败留下的空目录：严格判定应为未完成，下一轮会重跑
    os.remove(os.path.join(target, "分层清单.json"))
    assert runner._is_complete(target) is False


def test_executor_result_stored_on_item(tmp_path):
    """executor 返回的结果字典记入 item["result"]。"""
    state_path = str(tmp_path / ".batch_state.json")
    target = str(tmp_path / "t0")
    items = [("s0.png", target)]

    def executor(item):
        os.makedirs(item["target"], exist_ok=True)
        return {"layer_count": 5, "elapsed_ms": 12.3}

    runner = BatchRunner(executor, is_complete=lambda t: os.path.isdir(t))
    runner.run_new(items, state_path)

    state = _load(state_path)
    assert state["items"][0]["status"] == "done"
    assert state["items"][0]["result"] == {"layer_count": 5, "elapsed_ms": 12.3}
