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

    def __init__(self, executor: Callable[[Dict[str, str]], None]):
        """
        executor: 可调用对象，接收 item dict（含 source/target），
                  成功无返回，失败抛异常。
        """
        self.executor = executor

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
        """幂等性：目标目录已完整存在（非空）视为已完成"""
        return os.path.isdir(target) and len(os.listdir(target)) > 0

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
            try:
                self.executor(item)
                self._mark(item, "done")
            except Exception as e:
                self._mark(item, "failed", str(e))
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
            try:
                self.executor(item)
                self._mark(item, "done")
            except Exception as e:
                self._mark(item, "failed", str(e))
                self._save(state_path, state)
                break
            self._save(state_path, state)

        state["updated_at"] = time.time()
        self._save(state_path, state)
        return state
