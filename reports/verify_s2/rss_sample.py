#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S2 / FCPX Studio Pro R2.app (PID 96268) RSS 只读采样器

设计意图：
  * t0 已在本轮采好并写盘（见 rss_t0.txt / rss_samples.jsonl 第一条）。
  * 本脚本把「每 10 分钟一次、2 小时后给前后对比」做成能力，但本轮**不等待 2 小时**、
    **不启动任何后台/detach/nohup 进程**、**不运行 loop**。
  * t1 由集成方在「会话后续或用户回来后」显式执行 sample_once --label t1，再跑 report。

读数口径：
  * 首选用户指定命令 `ps -o rss= -p 96268`（单位 KB）。
  * 当前会话沙箱把 ps/top 的 exec 拒了（operation not permitted），脚本自动 fallback 到
    `libproc proc_pidinfo(PROC_PIDTASKINFO)` 的 pti_resident_size/1024 —— 与 ps rss 同口径，
    纯只读、不需要 task_for_pid、不触碰任何 FCPX 库、不启动/退出任何 App。
  * 不做、也不宣称做泄漏检测：leaks / footprint 需要 task_for_pid，已被沙箱拒绝。

用法：
  python3 rss_sample.py report                       # 看当前样本与前后对比状态（本轮跑这个）
  python3 rss_sample.py sample_once --label t1      # 后续会话/用户回来时采 t1
  python3 rss_sample.py sample_once --dry-run       # 只打印不写盘（本轮允许）
  python3 rss_sample.py loop --interval 600 --duration 7200 --i-accept-foreground
                                                    # 仅前台人在场时用；本轮禁用
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import json
import os
import sys
import time

PID = 96268
TARGET_SPAN_S = 7200          # 2 小时
INTERVAL_S = 600              # 每 10 分钟
STORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rss_samples.jsonl")


class ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("pti_virtual_size", ctypes.c_uint64),
        ("pti_resident_size", ctypes.c_uint64),
        ("pti_total_user", ctypes.c_uint64),
        ("pti_total_system", ctypes.c_uint64),
        ("pti_threads_user", ctypes.c_uint64),
        ("pti_threads_system", ctypes.c_uint64),
        ("pti_policy", ctypes.c_int32),
        ("pti_faults", ctypes.c_int32),
        ("pti_pageins", ctypes.c_int32),
        ("pti_cow_faults", ctypes.c_int32),
        ("pti_message_sent", ctypes.c_int32),
        ("pti_message_received", ctypes.c_int32),
        ("pti_syscalls_mach", ctypes.c_int32),
        ("pti_syscalls_unix", ctypes.c_int32),
        ("pti_csw", ctypes.c_int32),
        ("pti_threadnum", ctypes.c_int32),
        ("pti_numrunning", ctypes.c_int32),
        ("pti_priority", ctypes.c_int32),
    ]


PROC_PIDTASKINFO = 4


def read_rss_kb(pid: int) -> tuple[int, str]:
    """返回 (RSS KB, 采样来源)。只读，不 attach、不 task_for_pid。"""
    # 1) 用户指定命令
    try:
        import subprocess
        r = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return int(r.stdout.strip().split()[0]), "ps -o rss= -p %d" % pid
    except Exception:
        pass  # 沙箱 exec 拒绝 -> 走 libproc

    # 2) 等价只读接口
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                     ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        buf = ProcTaskInfo()
        n = lib.proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                             ctypes.byref(buf), ctypes.sizeof(buf))
        if n == ctypes.sizeof(buf) and buf.pti_resident_size > 0:
            return int(buf.pti_resident_size // 1024), (
                "libproc proc_pidinfo(PROC_PIDTASKINFO) [ps exec denied by sandbox]")
    except Exception as exc:  # pragma: no cover
        raise RuntimeError("RSS 只读采集失败: %s" % exc) from exc
    raise RuntimeError("RSS 只读采集失败：进程 %d 不存在或 proc_pidinfo 返回 %r" % (pid, n))


def load() -> list[dict]:
    if not os.path.exists(STORE):
        return []
    out = []
    with open(STORE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def ts_of(rec: dict) -> dt.datetime:
    d = dt.datetime.fromisoformat(rec["ts"])
    return d if d.tzinfo else d.astimezone()


def make_record(label: str, pid: int) -> dict:
    kb, src = read_rss_kb(pid)
    return {
        "label": label,
        "ts": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "pid": pid,
        "rss_kb": kb,
        "rss_mb": round(kb / 1024, 5),
        "source": src,
        "note": "只读 RSS 观测，未触碰 FCPX 库；非泄漏检测",
    }


def cmd_sample_once(args) -> int:
    rec = make_record(args.label, args.pid)
    if args.dry_run:
        print(json.dumps(rec, ensure_ascii=False, indent=2))
        print("DRY-RUN：未写盘。")
        return 0
    existing = load()
    if args.label == "t0" and any(r.get("label") == "t0" for r in existing):
        print("ERROR: t0 已存在，禁止覆盖（保护本轮基线）。t1 请用 --label t1。", file=sys.stderr)
        return 2
    with open(STORE, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("已写入 %s: %s  RSS=%d KB (%.2f MB)  来源=%s"
          % (STORE, rec["label"], rec["rss_kb"], rec["rss_mb"], rec["source"]))
    return 0


def cmd_report(args) -> int:
    recs = load()
    if not recs:
        print("无样本：%s 不存在或为空。" % STORE)
        return 1
    t0 = next((r for r in recs if r.get("label") == "t0"), recs[0])
    t0ts, lastts = ts_of(t0), ts_of(recs[-1])
    span = (lastts - t0ts).total_seconds()

    print("=== S2 / R2.app RSS 前后对比（只读观测，非泄漏检测）===")
    print("t0   : %s | %s | %d KB | %.5f MB | %s"
          % (t0["label"], t0["ts"], t0["rss_kb"], t0["rss_mb"], t0.get("source", "-")))
    print("最新 : %s | %s | %d KB | %.5f MB | %s"
          % (recs[-1].get("label", "?"), recs[-1]["ts"],
             recs[-1]["rss_kb"], recs[-1]["rss_mb"], recs[-1].get("source", "-")))
    d = recs[-1]["rss_kb"] - t0["rss_kb"]
    pct = (d / t0["rss_kb"] * 100) if t0["rss_kb"] else 0.0
    print("Δ RSS: %+d KB | %+.5f MB | %+.2f%%" % (d, d / 1024, pct))
    print("采样点数: %d | 已跨时长: %.1f min / 目标 120 min | 采样间隔设计: %d s"
          % (len(recs), span / 60, INTERVAL_S))
    # 找 t1：t0 之后 >= 2h 的第一个样本
    t1 = next((r for r in recs[1:] if (ts_of(r) - t0ts).total_seconds() >= TARGET_SPAN_S), None)
    if t1 is None or len(recs) < 2:
        print("结论：t1 尚未采集，2 小时前后对比不成立。")
        print("      t1 需会话后续或用户回来再采：python3 rss_sample.py sample_once --label t1")
        print("      注意：若用户已主动退出 R2.app，则 t1 须在 R2 再次处于运行态的后续会话里采；"
              "本代理不启动/重启任何 App。")
    else:
        d1 = t1["rss_kb"] - t0["rss_kb"]
        print("t1   : %s | %s | %d KB | %.5f MB"
              % (t1.get("label"), t1["ts"], t1["rss_kb"], t1["rss_mb"]))
        print("结论：2 小时前后对比 Δ = %+d KB (%+.5f MB, %+.2f%%)，"
              "采样点数 %d。" % (d1, d1 / 1024, d1 / t0["rss_kb"] * 100, len(recs)))
    print("提示：leaks / footprint 需 task_for_pid，沙箱已拒；本轮只做 RSS 观测，不宣称泄漏检测。")
    return 0


def cmd_loop(args) -> int:
    if not args.i_accept_foreground:
        print("ERROR: loop 必须显式 --i-accept-foreground；禁止 nohup/detach/& 后台运行。",
              file=sys.stderr)
        return 2
    print("WARNING: 本轮 S2 不执行本模式；以下命令只在用户/集成方前台在场时使用。")
    end = time.time() + args.duration
    while time.time() < end:
        rec = make_record("auto", args.pid)
        with open(STORE, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print("%s RSS=%d KB" % (rec["ts"], rec["rss_kb"]), flush=True)
        remain = end - time.time()
        if remain <= 0:
            break
        time.sleep(min(args.interval, remain))
    print("loop 结束，跑 `python3 rss_sample.py report` 看前后对比。")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="R2.app RSS 只读采样（本轮不等待、不后台）")
    sub = ap.add_subparsers(dest="cmd")

    p1 = sub.add_parser("sample_once", help="采一个点并追加写盘")
    p1.add_argument("--label", default="t1")
    p1.add_argument("--pid", type=int, default=PID)
    p1.add_argument("--dry-run", action="store_true", help="只打印，不写盘（本轮允许）")
    p1.set_defaults(func=cmd_sample_once)

    p2 = sub.add_parser("report", help="输出 t0 / 最新点 / 前后对比状态")
    p2.set_defaults(func=cmd_report)

    p3 = sub.add_parser("loop", help="前台定时采样（本轮禁用）")
    p3.add_argument("--interval", type=int, default=INTERVAL_S)
    p3.add_argument("--duration", type=int, default=TARGET_SPAN_S)
    p3.add_argument("--pid", type=int, default=PID)
    p3.add_argument("--i-accept-foreground", action="store_true")
    p3.set_defaults(func=cmd_loop)

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
