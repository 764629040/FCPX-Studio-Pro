"""
R32 / A-65 回归：大输出 PSD 必须能被解析，输出 > 64 KB（旧版死锁边界）。

背景：R31 的 PSDParserSocket 先 waitUntilExit() 再读 stdout，任何桥接输出
超过 macOS 管道缓冲（64 KB）都会永久互锁。tests/data 现有样本输出都 < 64 KB，
打不到边界，所以本文件在 tmp_path 动态构造大样本（不提交二进制）。

- 任务单要求「输出 > 500 KB」的打穿样本由 Swift 侧 harness 承担
  （docs/r32_evidence/r32_stress_260_layers.psd = 582 702 B 桥接输出），
  pytest 侧用 ~150 层样本锁住「必须越过 64 KB 且解析正确」的回归线。
"""
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from r25_fixtures import PROJECT_ROOT  # noqa: E402
import r32_stress  # noqa: E402

BRIDGE = os.path.join(PROJECT_ROOT, "core", "cli_bridge.py")


def test_bridge_output_exceeds_64kb_pipe_boundary(tmp_path):
    """桥接输出必须能越过 64 KB 旧死锁边界，且 JSON 完整、图层数守恒。"""
    psd_path = str(tmp_path / "r32_stress.psd")
    n_layers = r32_stress.build(psd_path, n_layers=150)

    proc = subprocess.run(
        [sys.executable, BRIDGE, "parse", psd_path],
        capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, f"桥接解析失败: {proc.stderr[-500:]}"

    out = proc.stdout
    assert len(out.encode("utf-8")) > 64 * 1024, (
        f"回归样本失效：输出 {len(out.encode('utf-8'))} B 未越过 64 KB 边界，"
        "请增加层数"
    )

    data = json.loads(out)
    assert data["width"] > 0 and data["height"] > 0
    assert data["layer_count"] == n_layers
    assert len(data["layers"]) == n_layers
    # 每层都有名字（长名是放大输出的手段，不能丢）
    assert all(l["name"].startswith("Caption_Layer_") for l in data["layers"])


def test_corrupted_psd_reports_error_not_empty_layers(tmp_path):
    """损坏 PSD：桥接必须显式报错（exit != 0 + message），不许输出空成功。"""
    corrupted = os.path.join(PROJECT_ROOT, "tests", "data", "corrupted_file.psd")
    proc = subprocess.run(
        [sys.executable, BRIDGE, "parse", corrupted],
        capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode != 0, "损坏文件不得伪装成功（exit 必须 != 0）"
    payload = json.loads(proc.stdout)
    assert payload.get("status") == "error"
    assert payload.get("message"), "必须有 message 说明原因"
