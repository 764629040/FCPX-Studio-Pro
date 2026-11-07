"""
R21-T1 磁盘空间预检单测

缺口：全仓无 shutil.disk_usage，磁盘将满时写入到一半失败留下残件。
实现：build_template_atomic pre-flight 检查 3，估算待写数据量，
      不足抛 StorageSpaceError。

断言：
  1. disk_usage.free 极小值 → 抛 StorageSpaceError
  2. 正常空间 → 不抛（回归保护）
"""
import os
import sys
import shutil
import tempfile
from unittest.mock import MagicMock

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder, StorageSpaceError

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")  # 4.8MB


def _fake_usage(free_bytes):
    """构造一个 disk_usage 返回值"""
    m = MagicMock()
    m.free = free_bytes
    m.total = 1024 * 1024 * 1024 * 100
    m.used = m.total - free_bytes
    return m


def test_t1_raises_storage_space_error_when_disk_full(tmp_path, monkeypatch):
    """T1-1：可用空间极小值 → 抛 StorageSpaceError"""
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    out_dir = tmp_path / "tpl_t1_full"

    # 把 disk_usage 的 free 改成极小值（1KB）
    monkeypatch.setattr(
        "core.motion_builder.shutil.disk_usage",
        lambda path: _fake_usage(1024),
    )

    with pytest.raises(StorageSpaceError) as exc_info:
        mb.build_template_atomic(
            parsed["layers"], str(out_dir), "t1_test",
            psd_path=COMPLEX_PSD,
            canvas_size=(parsed["width"], parsed["height"]),
        )

    msg = str(exc_info.value)
    assert "MB" in msg, f"异常信息应包含 MB 单位: {msg}"
    # 断言目标目录未被创建（pre-flight 阻断，零写入）
    assert not out_dir.exists(), "pre-flight 阻断后不应产生任何输出"


def test_t1_no_raise_with_normal_space(tmp_path):
    """T1-2：正常空间 → 不抛 StorageSpaceError（回归保护）"""
    parsed = parse_psd_file(COMPLEX_PSD, extract_thumbnails=False)
    mb = MotionBuilder()
    out_dir = tmp_path / "tpl_t1_ok"

    # 不 monkeypatch，使用真实 disk_usage（tmp_path 所在卷必然有足够空间）
    result = mb.build_template_atomic(
        parsed["layers"], str(out_dir), "t1_test",
        psd_path=COMPLEX_PSD,
        canvas_size=(parsed["width"], parsed["height"]),
    )

    assert result["status"] == "ok"
    assert os.path.isdir(out_dir), "正常空间下应成功构建"
