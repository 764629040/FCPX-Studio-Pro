#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S2 / 乐观态「已恢复在线 -> 部分损坏」中间态时长计算器

用途：从「带时间戳的日志 / 截图 mtime / 人工 CSV 打点」算出
      T_START(AssetHubView.swift:3084 乐观文案) -> T_END(:3129 部分损坏 / :3134 校验完成)
      的持续时长。

硬边界：
  * 本脚本只读输入文件 / 只做算术，不连接 FCPX、不动任何库、不启动任何 App、不抢焦点。
  * 本轮 S2 只跑 --selftest（内置合成数据）与 --print-log-command；不读任何真机日志。
  * 没有配对终点时明确输出 UNPAIRED_START，绝不虚构时长。

配套口径文档：reports/verify_s2/乐观态_中间态计时口径.md
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import sys
from dataclasses import dataclass, asdict

# --- 事件文本（与 AssetHubView.swift 状态栏文案逐字对齐）--------------------
START_PAT = re.compile(
    r"已重新连接[^\n]*?正在校验|已重新连接[^\n]*?已恢复在线|已恢复在线"
)
END_BAD_PAT = re.compile(r"部分文件缺失损坏")
END_OK_PAT = re.compile(r"校验完成[^\n]*?完全就绪在线|校验完成|完全就绪在线")
VOL_PAT = re.compile(r"外置盘\s*\[([^\]]+)\]")

TS_PAT = re.compile(
    r"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"
)
SHOT_START = re.compile(r"start|乐观|恢复在线|重连|校验中|reconnect", re.I)
SHOT_BAD = re.compile(r"部分损坏|标红|corrupt|damage", re.I)
SHOT_OK = re.compile(r"校验完成|就绪|success|校验ok", re.I)


@dataclass
class Event:
    ts: dt.datetime
    kind: str          # START / END_BAD / END_OK
    volume: str
    raw: str
    source: str
    naive_ts_assumed_local: bool = False


def parse_ts(text: str) -> tuple[dt.datetime, bool] | None:
    """返回 (带时区 datetime, 是否为无时区且按本地解释)"""
    s = text.strip().replace(",", ".")
    m = re.match(
        r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$", s
    )
    if not m:
        return None
    base, frac, tz = m.group(1).replace(" ", "T"), m.group(2) or "", m.group(3) or ""
    naive = not tz
    if tz == "Z":
        tz = "+00:00"
    elif tz and ":" not in tz:
        tz = tz[:3] + ":" + tz[3:]
    try:
        d = dt.datetime.fromisoformat(base + frac + tz)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.astimezone()  # 无时区 -> 按本机本地时区(CST/+08:00)解释
    return d, naive


def classify(text: str) -> str | None:
    # END 先判：避免「校验完成…已完全就绪在线」被 START 的「在线」误吞
    if END_BAD_PAT.search(text):
        return "END_BAD"
    if END_OK_PAT.search(text):
        return "END_OK"
    if START_PAT.search(text):
        return "START"
    return None


def volume_of(text: str) -> str:
    m = VOL_PAT.search(text)
    return m.group(1) if m else "?"


def parse_line(line: str, source: str) -> Event | None:
    m = TS_PAT.search(line)
    if not m:
        return None
    parsed = parse_ts(m.group(1))
    if parsed is None:
        return None
    ts, naive = parsed
    kind = classify(line)
    if kind is None:
        return None
    return Event(ts, kind, volume_of(line), line.strip(), source, naive)


def from_logs(paths: list[str]) -> list[Event]:
    out: list[Event] = []
    for p in paths:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                e = parse_line(line, f"log:{p}")
                if e:
                    out.append(e)
    return out


def from_shots(directory: str) -> list[Event]:
    """截图 mtime 打点：秒级精度，文件名决定事件类型"""
    out: list[Event] = []
    for name in sorted(os.listdir(directory)):
        p = os.path.join(directory, name)
        if not os.path.isfile(p):
            continue
        if SHOT_BAD.search(name):
            kind = "END_BAD"
        elif SHOT_OK.search(name):
            kind = "END_OK"
        elif SHOT_START.search(name):
            kind = "START"
        else:
            continue
        ts = dt.datetime.fromtimestamp(os.path.getmtime(p)).astimezone()
        out.append(Event(ts, kind, "?", f"screenshot:{name}", f"shot:{p}", False))
    return out


def from_csv(path: str) -> list[Event]:
    """列：timestamp,event,volume,raw（volume/raw 可空）"""
    out: list[Event] = []
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            parsed = parse_ts(row.get("timestamp", ""))
            if parsed is None:
                continue
            ts, naive = parsed
            kind = (row.get("event") or "").strip().upper()
            if kind not in ("START", "END_BAD", "END_OK"):
                continue
            out.append(
                Event(ts, kind, (row.get("volume") or "?").strip(),
                      (row.get("raw") or "").strip(), f"csv:{path}", naive)
            )
    return out


def pair(events: list[Event]) -> list[dict]:
    """按卷名把 START 与之后第一个 END 配对；不虚构终点"""
    events = sorted(events, key=lambda e: e.ts)
    opened: dict[str, Event] = {}
    results: list[dict] = []
    for e in events:
        if e.kind == "START":
            opened[e.volume] = e  # 同卷重复重连：以最后一次 START 为准
            continue
        s = opened.pop(e.volume, None)
        if s is None and len(opened) == 1:
            k = next(iter(opened))
            s = opened.pop(k)  # 卷名缺失('?')时允许唯一配对
        if s is None:
            results.append({
                "status": "ORPHAN_END", "volume": e.volume,
                "start": None, "end": e.ts.isoformat(),
                "duration_s": None, "outcome": e.kind,
                "note": "只有终点、没有起点，未计时",
            })
            continue
        delta = (e.ts - s.ts).total_seconds()
        if delta < 0:
            results.append({
                "status": "NEGATIVE_DELTA", "volume": e.volume,
                "start": s.ts.isoformat(), "end": e.ts.isoformat(),
                "duration_s": delta, "outcome": e.kind,
                "note": "时间倒挂，检查时钟/时区",
            })
            continue
        results.append({
            "status": "OK", "volume": e.volume,
            "start": s.ts.isoformat(), "end": e.ts.isoformat(),
            "duration_s": round(delta, 3), "outcome": e.kind,
            "naive_ts_assumed_local": s.naive_ts_assumed_local or e.naive_ts_assumed_local,
            "start_raw": s.raw, "end_raw": e.raw,
            "source": f"{s.source} -> {e.source}",
        })
    for vol, s in opened.items():
        results.append({
            "status": "UNPAIRED_START", "volume": vol,
            "start": s.ts.isoformat(), "end": None,
            "duration_s": None, "outcome": None,
            "note": "起点已观测、终点未观测到，禁止补值",
        })
    return results


def render(rows: list[dict], as_json: bool) -> None:
    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    print(f"{'volume':<16} {'status':<16} {'start':<27} {'end':<27} {'dur_s':>10}  outcome")
    print("-" * 108)
    for r in rows:
        print(f"{r['volume']:<16} {r['status']:<16} {str(r['start'] or '-'):<27} "
              f"{str(r['end'] or '-'):<27} {str(r['duration_s'] if r['duration_s'] is not None else '-'):>10}  "
              f"{r['outcome'] or '-'}")
    good = [r for r in rows if r["status"] == "OK"]
    bad = [r for r in good if r["outcome"] == "END_BAD"]
    print("-" * 108)
    if good:
        ds = [r["duration_s"] for r in good]
        print(f"有效配对 {len(good)} 组 | 平均 {sum(ds)/len(ds):.3f}s | "
              f"min {min(ds):.3f}s | max {max(ds):.3f}s")
        print(f"专项「已恢复在线 -> 部分损坏」(END_BAD) 配对 {len(bad)} 组")
    else:
        print("有效配对 0 组 —— 无真机时长数据，禁止写任何时长结论。")
    for r in rows:
        if r["status"] != "OK":
            print(f"  [{r['status']}] {r['volume']}: {r['note']}")


def selftest() -> int:
    """内置合成样例：只验证解析/配对能算，不是任何真机观测值"""
    sample = [
        "2026-11-10T20:00:01.000+08:00 外置盘 [MyDisk] 已重新连接，正在校验 12 套模板完整性…",
        "2026-11-10T20:00:05.250+08:00 外置盘 [MyDisk] 部分文件缺失损坏：3 套模板标红告警",
        "2026-11-10T20:01:00.000+08:00 外置盘 [MyDisk] 已重新连接，3 套模板已恢复在线",
        "2026-11-10T20:01:02.500+08:00 外置盘 [MyDisk] 校验完成，3 套模板已完全就绪在线",
    ]
    ev = [parse_line(x, "selftest") for x in sample]
    ev = [e for e in ev if e]
    assert len(ev) == 4, f"解析数量不对: {len(ev)}"
    rows = pair(ev)
    ok = [r for r in rows if r["status"] == "OK"]
    assert len(ok) == 2, rows
    assert abs(ok[0]["duration_s"] - 4.25) < 1e-6, rows
    assert ok[0]["outcome"] == "END_BAD" and ok[1]["outcome"] == "END_OK", rows
    print("SELFTEST PASS（内置合成数据，非真机观测）")
    render(rows, False)
    # 未配对保护
    orphan = pair([parse_line(sample[0], "selftest")])
    assert orphan[0]["status"] == "UNPAIRED_START", orphan
    print("SELFTEST PASS：未配对起点正确标记为 UNPAIRED_START，未虚构时长")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="乐观态中间态时长计算（只读输入、不碰 FCPX、不跑真机）")
    ap.add_argument("--log", action="append", default=[], help="带时间戳的日志文件，可重复")
    ap.add_argument("--shots", help="截图目录，按文件名+mtime 打点（秒级精度）")
    ap.add_argument("--csv", help="人工打点 CSV: timestamp,event,volume,raw")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--selftest", action="store_true", help="内置合成数据自检（本轮唯一允许跑的模式）")
    ap.add_argument("--print-log-command", action="store_true",
                    help="只打印建议的 log show 命令，不执行")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.print_log_command:
        print("# 仅打印，不执行。注意：当前 AssetHubView.swift 无 os_log/NSLog 埋点，现在抓不到状态栏文案。")
        print("log show --last 2h --style syslog \\")
        print("  --predicate 'eventMessage CONTAINS \"外置盘\" AND (eventMessage CONTAINS \"已重新连接\" "
              "OR eventMessage CONTAINS \"部分文件缺失损坏\" OR eventMessage CONTAINS \"校验完成\")' \\")
        print("  > /tmp/s2_optimistic.log")
        print("python3 optimistic_duration.py --log /tmp/s2_optimistic.log")
        return 0

    if not (args.log or args.shots or args.csv):
        print("ERROR: 需要 --log / --shots / --csv 之一；本轮 S2 只允许 --selftest / --print-log-command。",
              file=sys.stderr)
        return 2

    events: list[Event] = []
    events += from_logs(args.log)
    if args.shots:
        events += from_shots(args.shots)
    if args.csv:
        events += from_csv(args.csv)
    if not events:
        print("未解析到任何事件 —— 不输出时长、不写结论。")
        return 1
    render(pair(events), args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
