"""R33 / A-68 + A-69 + A-70：纯图片 PSD 的显示与假成功根治（Python 侧）。

背景（审核 R33 实测 镇雄.psd）：
- 13 层全是像素层，旧桥接不导出贴图 → 画布全黑还显示绿色「完整提取」；
- 11 个隐藏层被静默丢弃，不写任何记录；
- 底板层被过滤后没有任何画面来源。

本文件验证：
1. A-68：可见像素层与底板层都会生成真实 PNG 贴图（文件存在且非空）；
2. A-69：层数守恒字段齐全，ignored_count 明确暴露（不再伪装完整）；
3. A-70：隐藏层必须写入 notes，include_hidden=True 时以 visible=False
   预览层进入列表且不改变转换口径。
"""
import os
import tempfile

import pytest

psd_tools = pytest.importorskip("psd_tools")
PILImage = pytest.importorskip("PIL.Image")


def _build_photo_psd(path, with_hidden=True):
    """小尺寸照片稿：底板 + 1 可见像素层 + 2 隐藏层（中文名走 luni）。"""
    from PIL import Image
    import numpy as np

    w, h = 320, 200
    rng = np.random.default_rng(2026)
    photo = Image.fromarray(rng.integers(0, 255, (h, w, 3), dtype=np.uint8), "RGB")

    psd = psd_tools.PSDImage.new("RGB", (w, h), color=(0, 0, 0))

    def add(img, name, top=0, left=0):
        layer = psd.create_pixel_layer(img, name="tmp", top=top, left=left)
        layer.name = name  # 中文名必须走 setter（luni），否则保存时 macroman 崩
        return layer

    patch = Image.fromarray(rng.integers(0, 255, (60, 90, 3), dtype=np.uint8), "RGB")
    add(patch, "可见装饰", top=20, left=30)
    hidden_names = []
    if with_hidden:
        for i in range(2):
            hl = add(patch.copy(), f"隐藏备选_{i}", top=40 + 10 * i, left=60 + 10 * i)
            hl.visible = False
            hidden_names.append(hl.name)
    add(photo.copy(), "底板照片", top=0, left=0)
    psd.save(path)
    return {"canvas": (w, h), "hidden": hidden_names}


def test_a68_bitmap_layers_and_background_get_real_pngs():
    from core.psd_parser import parse_psd_file

    with tempfile.TemporaryDirectory(prefix="r33_a68_") as tmp:
        psd_path = os.path.join(tmp, "photo.psd")
        _build_photo_psd(psd_path)
        out = os.path.join(tmp, "media")
        r = parse_psd_file(psd_path, extract_fallback_pngs=True, png_output_dir=out)

        # 可见像素层 → 降级贴图，文件必须真实存在
        bitmap = [l for l in r["layers"] if l.kind == "fallback_png"]
        assert len(bitmap) == 1
        p = bitmap[0].fallback_png_path
        assert p and os.path.exists(p) and os.path.getsize(p) > 0

        # 底板 → 画布预览贴图（转换仍忽略底板，但画面主体有了）
        bp = r["background_preview"]
        assert bp is not None
        assert os.path.exists(bp["png_path"]) and os.path.getsize(bp["png_path"]) > 0
        assert bp["psd_bbox"] == [0, 0, 320, 200]


def test_a69_counts_expose_ignored_and_conservation():
    from core.psd_parser import parse_psd_file

    with tempfile.TemporaryDirectory(prefix="r33_a69_") as tmp:
        psd_path = os.path.join(tmp, "photo.psd")
        info = _build_photo_psd(psd_path)
        r = parse_psd_file(psd_path, extract_fallback_pngs=True,
                           png_output_dir=os.path.join(tmp, "m"))
        s = r["diagnosis_report"]["summary"]

        # 输入 4 层 = 1 可见装饰 + 2 隐藏 + 1 底板
        assert s["total_layers"] == 4
        assert s["hidden_layer_count"] == 2
        assert s["background_layer_count"] == 1
        assert s["ignored_count"] == 3
        # 忽略必须可读、可追责，不允许只给一个数字
        assert "2 个隐藏" in s["ignored_summary"]
        assert "1 个底板" in s["ignored_summary"]
        # 守恒与计数闭合
        assert r["layer_conservation"]["holds"] is True
        assert s["count_sum_holds"] is True
        # 顶部快捷字段同步存在（Swift 桥接读取路径）
        for key in ("hidden_layer_count", "ignored_summary", "preview_layer_count",
                    "background_preview"):
            assert key in r


def test_a70_hidden_layers_recorded_and_preview_toggle():
    from core.psd_parser import parse_psd_file

    with tempfile.TemporaryDirectory(prefix="r33_a70_") as tmp:
        psd_path = os.path.join(tmp, "photo.psd")
        info = _build_photo_psd(psd_path)

        # 1) 默认口径：隐藏层必须写进 notes，绝不静默
        r = parse_psd_file(psd_path, extract_fallback_pngs=True,
                           png_output_dir=os.path.join(tmp, "m1"))
        hidden_notes = [n for n in r["diagnostics"]["notes"] if "跳过隐藏图层" in n]
        assert len(hidden_notes) == 2
        assert any("隐藏备选_0" in n for n in hidden_notes)
        assert r["diagnosis_report"]["summary"]["hidden_layer_names"] == info["hidden"]

        # 2) include_hidden=True：预览层进入列表，visible=False，A-73 归正统计口径
        rh = parse_psd_file(psd_path, extract_fallback_pngs=True,
                            png_output_dir=os.path.join(tmp, "m2"), include_hidden=True)
        previews = [l for l in rh["layers"] if not l.visible]
        assert len(previews) == 2
        assert [l.name for l in previews] == info["hidden"]
        for l in previews:
            # R42 / A-73：已提取为贴图的隐藏层其 disposition 为 degraded，计入 output
            assert l.disposition == "degraded"
            assert l.fallback_png_path and os.path.exists(l.fallback_png_path)

        # 3) A-73 口径收紧：output 包含已提取的隐藏层（1 可见 + 2 隐藏 = 3），ignored 仅计底板（1）
        s0 = r["diagnosis_report"]["summary"]
        s1 = rh["diagnosis_report"]["summary"]
        assert s0["ignored_count"] == 3
        assert s1["ignored_count"] == 1  # 仅底板层被忽略
        assert r["output_layer_count"] == 1
        assert rh["output_layer_count"] == 3  # 实际输出 3 层
        assert rh["layer_conservation"]["holds"] and s1["count_sum_holds"]
        assert rh["preview_layer_count"] == 2


def test_a70_bridge_flag_keeps_conservation():
    """cli_bridge --include-hidden 只加预览，不改守恒（桥接契约）。"""
    import json
    import subprocess
    import sys

    with tempfile.TemporaryDirectory(prefix="r33_bridge_") as tmp:
        psd_path = os.path.join(tmp, "photo.psd")
        _build_photo_psd(psd_path)
        proc = subprocess.run(
            [sys.executable, "core/cli_bridge.py", "parse", str(psd_path), "--include-hidden"],
            capture_output=True, text=True, timeout=120,
        )
        assert proc.returncode == 0, proc.stderr[-500:]
        d = json.loads(proc.stdout)
        assert d["status"] == "ok"
        assert d["include_hidden"] is True
        assert d["preview_layer_count"] == 2
        assert d["output_layer_count"] == 3
        assert d["skipped_layer_count"] == 1
        assert d["layer_conservation"]["holds"] is True
        assert d["background_preview"] is not None
        # 桥接必须给出 summary，Swift 端才允许判定完整性
        assert d["summary"]["count_sum_holds"] is True
        # 桥接已关闭缩略图（R33 性能修复），JSON 里不应再有巨大 base64
        for l in d["layers"]:
            assert not (l.get("thumbnail_base64") or "").strip()
