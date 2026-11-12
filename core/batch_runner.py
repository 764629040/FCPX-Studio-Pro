"""
R21-T4 批量处理断点续跑

缺口：批量处理多个 PSD 时中途失败只有一句报告文案，无 checkpoint、无续跑入口。
      50 个文件挂在第 37 个，只能从头再来。

本模块提供：
  - BatchRunner(executor)：构造时注入执行器，执行器接收 item dict
  - run_new(items, state_path)：新建任务并执行
  - resume_task(state_path)：只跑 pending + failed，done 跳过（幂等）
  - retry_failed(state_path)：只重试 failed

状态文件 `.batch_state.json` 落在输出目录（不写 128 卷），
每处理完一项立即原子写盘，保证断电也有进度。
core 层不依赖 GUI。
"""
import os
import json
import time
import uuid
from typing import Callable, Dict, List, Optional, Tuple


class BatchRunner:
    """批量任务断点续跑器"""

    def __init__(self, executor: Callable[[Dict[str, str]], None], max_retries: int = 0,
                 is_complete: Optional[Callable[[str], bool]] = None):
        """
        executor: 可调用对象，接收 item dict（含 source/target），
                  成功可返回结果字典（记入 item["result"]），失败抛异常。
        max_retries: 单项首次失败后的自动重试次数（默认 0，保持旧口径：
                  一次失败即落 failed，靠 retry_failed 手动重试）；
                  批量场景可传 ≥1 开启当轮自动重试。
        is_complete: 可选幂等判定（入参 target 路径）；缺省沿用旧口径
                  「目标目录非空即完成」。失败时执行器可能先建了空目录再抛异常，
                  粗判会把半成品误判完成，需要严格契约产物判定时传入。
        """
        self.executor = executor
        self.max_retries = max(0, int(max_retries))
        self._is_complete_fn = is_complete

    # ── 状态读写 ──

    def _init_state(self, items: List[Tuple[str, str]], task_id: Optional[str] = None) -> Dict:
        return {
            "task_id": task_id or uuid.uuid4().hex[:12],
            "items": [
                {
                    "source": s,
                    "target": t,
                    "status": "pending",
                    "error": "",
                    "updated_at": 0.0,
                }
                for s, t in items
            ],
            "created_at": time.time(),
            "updated_at": time.time(),
        }

    def _load(self, state_path: str) -> Optional[Dict]:
        if not os.path.exists(state_path):
            return None
        with open(state_path, encoding="utf-8") as f:
            return json.load(f)

    def _save(self, state_path: str, state: Dict) -> None:
        """原子写：写临时文件 + os.replace，避免写一半损坏"""
        tmp = state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
        os.replace(tmp, state_path)

    def _mark(self, item: Dict, status: str, error: str = "") -> None:
        item["status"] = status
        item["error"] = error
        item["updated_at"] = time.time()

    def _is_complete(self, target: str) -> bool:
        """幂等性：优先用注入的严格判定；缺省沿用「目标目录非空即完成」。"""
        if self._is_complete_fn is not None:
            return bool(self._is_complete_fn(target))
        return os.path.isdir(target) and len(os.listdir(target)) > 0

    def _execute_item(self, item: Dict) -> None:
        """执行单项：失败按 max_retries 自动重试；记录尝试次数、耗时与结果。

        成功 → status=done，executor 返回值记入 item["result"]；
        耗尽重试仍失败 → status=failed，最后一条异常进 item["error"]。
        """
        last_err = ""
        for attempt in range(1, self.max_retries + 2):
            t0 = time.perf_counter()
            try:
                result = self.executor(item)
                item["result"] = result
                item["attempts"] = attempt
                item["elapsed_ms"] = round((time.perf_counter() - t0) * 1000, 1)
                self._mark(item, "done")
                return
            except Exception as e:  # 执行器内部异常统一收口为 failed
                last_err = str(e)
                item["attempts"] = attempt
                item["elapsed_ms"] = round((time.perf_counter() - t0) * 1000, 1)
        self._mark(item, "failed", last_err)

    # ── 公开接口 ──

    def run_new(
        self,
        items: List[Tuple[str, str]],
        state_path: str,
        task_id: Optional[str] = None,
    ) -> Dict:
        """新建任务：初始化状态并执行全部项（含 pending + failed）"""
        state = self._init_state(items, task_id)
        self._save(state_path, state)
        return self.resume_task(state_path)

    def resume_task(self, state_path: str) -> Dict:
        """续跑：只跑 pending 和 failed，done 跳过。失败即中断本轮，后续保持 pending。"""
        state = self._load(state_path)
        if state is None:
            raise FileNotFoundError(f"状态文件不存在: {state_path}")

        for item in state["items"]:
            if item["status"] == "done":
                continue
            # 幂等：target 已完整存在 → 直接标记 done，不重复执行
            if self._is_complete(item["target"]):
                self._mark(item, "done")
                self._save(state_path, state)
                continue
            self._execute_item(item)
            if item["status"] == "failed":
                # 失败即中断本轮，后续项保持 pending，供下次 resume
                self._save(state_path, state)
                break
            # 每项后立即写盘，保证断电也有进度
            self._save(state_path, state)

        state["updated_at"] = time.time()
        self._save(state_path, state)
        return state

    def retry_failed(self, state_path: str) -> Dict:
        """只重试 failed 项。失败即中断本轮。"""
        state = self._load(state_path)
        if state is None:
            raise FileNotFoundError(f"状态文件不存在: {state_path}")

        for item in state["items"]:
            if item["status"] != "failed":
                continue
            if self._is_complete(item["target"]):
                self._mark(item, "done")
                self._save(state_path, state)
                continue
            self._execute_item(item)
            if item["status"] == "failed":
                self._save(state_path, state)
                break
            self._save(state_path, state)

        state["updated_at"] = time.time()
        self._save(state_path, state)
        return state
