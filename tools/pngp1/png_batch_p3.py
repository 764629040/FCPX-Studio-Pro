#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PNG 智能拆分 P3：批量拆分 + 失败重试 + 断点续跑 + 批处理日志/耗时表。

复用 core.batch_runner.BatchRunner（checkpoint 原子写盘、done 幂等跳过、
resume 续跑 pending+failed、retry_failed 只重试失败项）。本驱动只负责：
  - 扫描源目录 PNG，生成「源图 → 输出子目录」任务项；
  - 执行器调 png_split_p1.split() 单张拆分，并跑 check 契约复算；
  - 落批处理日志 JSON 与耗时表 TXT。

红线（沿用立项 §8）：0 模型权重、0 联网、不新增第三方依赖；文字层永远位图；
输出 8bit RGBA 同分辨率；目录/文件名无空格、全角符号、emoji。

用法：
  python3 tools/pngp1/png_batch_p3.py batch --src-dir DIR --out DIR [--mode new|resume|retry] [--max-retries 1]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import unicodedata
from typing import Dict, List, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
sys.path.insert(0, _HERE)
sys.path.insert(0, _ROOT)
from png_split_p1 import split, check  # noqa: E402

from core.batch_runner import BatchRunner  # noqa: E402

PNG_EXTS = (".png",)


def sanitize_dir_name(name: str) -> str:
    """输出目录名：去空格/全角符号/emoji，保留 CJK、ASCII 字母数字与 _ - .。"""
    name = unicodedata.normalize("NFKC", name)
    name = re.sub(r"[\s\u3000]+", "_", name)
    name = "".join(ch for ch in name if ch.isalnum() or ch in "_-.")
    name = name.strip("_-.")
    return name or "untitled"


def discover_pngs(src_dir: str) -> List[str]:
    """递归收集源目录下 PNG，按路径排序，保证任务顺序可复现。"""
    found: List[str] = []
    for dp, _, files in os.walk(src_dir):
        for f in files:
            if f.lower().endswith(PNG_EXTS):
                found.append(os.path.join(dp, f))
    return sorted(found)


def build_items(src_dir: str, out_dir: str) -> List[Tuple[str, str]]:
    items: List[Tuple[str, str]] = []
    for src in discover_pngs(src_dir):
        base = os.path.splitext(os.path.basename(src))[0]
        target = os.path.join(out_dir, sanitize_dir_name(base))
        items.append((src, target))
    return items


def make_executor():
    """执行器：单张拆分 + 契约复算，结果元数据回传 runner 记入 item["result"]。"""
    def executor(item: Dict) -> Dict:
        doc = split(item["source"], item["target"])
        verdict = {"verdict": "SKIP", "failures": []}
        try:
            ck = check(item["target"])
            verdict = {
                "verdict": ck.get("verdict", "SKIP"),
                "failures": ["%s: %s" % (c.get("check"), c.get("detail"))
                             for c in ck.get("checks", []) if not c.get("ok")],
            }
        except Exception as e:  # 复算异常不掩盖拆分结果，记入证据
            verdict = {"verdict": "CHECK_ERROR", "failures": [str(e)]}
        return {
            "layer_count": doc.get("layer_count"),
            "classes": doc.get("classes_present", []),
            "elapsed_ms": doc.get("timings_ms", {}).get("total"),
            "ratio_to_source": doc.get("sizes", {}).get("ratio_to_source"),
            "warnings": doc.get("warnings", []),
            "check": verdict,
        }
    return executor


def _elapsed_rows(state: Dict) -> List[Dict]:
    rows = []
    for it in state["items"]:
        res = it.get("result") or {}
        rows.append({
            "source": os.path.basename(it["source"]),
            "status": it["status"],
            "layers": res.get("layer_count"),
            "attempts": it.get("attempts"),
            "elapsed_ms": it.get("elapsed_ms"),
            "ratio": res.get("ratio_to_source"),
            "check": (res.get("check") or {}).get("verdict"),
            "error": it.get("error", ""),
        })
    return rows


def write_reports(out_dir: str, state: Dict, wall_s: float) -> Tuple[str, str]:
    counts = {"done": 0, "failed": 0, "pending": 0}
    for it in state["items"]:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
    done_ms = [it.get("elapsed_ms") for it in state["items"]
               if it["status"] == "done" and isinstance(it.get("elapsed_ms"), (int, float))]
    stat = {
        "total": len(state["items"]),
        "done": counts["done"],
        "failed": counts["failed"],
        "pending": counts["pending"],
        "wall_s": round(wall_s, 2),
        "elapsed_ms": {
            "total": round(sum(done_ms), 1) if done_ms else 0.0,
            "median": round(sorted(done_ms)[len(done_ms) // 2], 1) if done_ms else 0.0,
            "max": round(max(done_ms), 1) if done_ms else 0.0,
        },
    }

    log_path = os.path.join(out_dir, "批处理日志.json")
    log_doc = {"task_id": state.get("task_id"), "summary": stat,
               "items": _elapsed_rows(state)}
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump(log_doc, f, ensure_ascii=False, indent=2)

    table_path = os.path.join(out_dir, "耗时表.txt")
    lines = [
        "PNG 批量拆分 P3 耗时表",
        f"任务号 {state.get('task_id')}　总耗时 {stat['wall_s']}s",
        f"合计 {stat['total']} 张：成功 {stat['done']} / 失败 {stat['failed']} / 待处理 {stat['pending']}",
        f"成功项耗时(ms)：合计 {stat['elapsed_ms']['total']}　中位 {stat['elapsed_ms']['median']}　最大 {stat['elapsed_ms']['max']}",
        "",
        f"{'#':>3}  {'状态':<7} {'层':>3} {'尝试':>3} {'耗时ms':>9} {'体积比':>7} {'复算':<12} 源文件",
    ]
    for i, row in enumerate(_elapsed_rows(state), start=1):
        lines.append(
            f"{i:>3}  {row['status']:<7} {str(row['layers']):>3} {str(row['attempts']):>3} "
            f"{str(row['elapsed_ms']):>9} {str(row['ratio']):>7} {str(row['check']):<12} {row['source']}"
        )
    if counts["failed"]:
        lines.append("")
        lines.append("失败项：")
        for row in _elapsed_rows(state):
            if row["status"] == "failed":
                lines.append(f"  - {row['source']}: {row['error']}")
    with open(table_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return log_path, table_path


def _p1_complete(target: str) -> bool:
    """严格幂等判定：P1 契约产物「分层清单.json」存在才算完成。

    失败时 split() 会先建输出目录再抛异常，只看目录非空会把半成品误判完成。
    """
    return os.path.isfile(os.path.join(target, "分层清单.json"))


def run(args: argparse.Namespace) -> int:
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    state_path = os.path.join(out_dir, ".batch_state.json")

    items = build_items(args.src_dir, out_dir)
    if not items:
        print("源目录未发现 PNG：%s" % args.src_dir)
        return 1

    runner = BatchRunner(make_executor(), max_retries=args.max_retries,
                         is_complete=_p1_complete)
    t0 = time.perf_counter()
    if args.mode == "new":
        state = runner.run_new(items, state_path)
    elif args.mode == "resume":
        state = runner.resume_task(state_path)
    else:
        state = runner.retry_failed(state_path)
    wall_s = time.perf_counter() - t0

    log_path, table_path = write_reports(out_dir, state, wall_s)
    counts = {"done": 0, "failed": 0, "pending": 0}
    for it in state["items"]:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
    print("批量完成：成功 %d / 失败 %d / 待处理 %d（共 %d）"
          % (counts["done"], counts["failed"], counts["pending"], len(items)))
    print("日志：%s" % log_path)
    print("耗时表：%s" % table_path)
    return 0 if counts["failed"] == 0 else 2


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="PNG 智能拆分 P3 批量")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("batch")
    b.add_argument("--src-dir", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--mode", choices=["new", "resume", "retry"], default="new")
    b.add_argument("--max-retries", type=int, default=1)
    args = ap.parse_args(argv)
    if args.cmd == "batch":
        return run(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
