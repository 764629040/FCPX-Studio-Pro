"""
R25 C-9 PNG 降级路径
====================
不可转换的图层（智能对象 / 形状 / 像素 / 调整层）降级为嵌入的 32 位透明 RGBA PNG 位图。
验证：
- 降级层产出真实 PNG 文件；
- PNG 为 8-bit per channel / 32-bit RGBA（IHDR 校验）；
- 非空白（有透明通道内容与 alpha>0）。
"""
import os
import sys
import struct

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import r25_fixtures as FX
from core.psd_parser import parse_psd_file
from core.psd_layer_fallback import render_layer_to_png_bytes

DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _assert_png_32bit_rgba(png_info, png_file):
    assert png_info["is_valid_header"], "PNG 签名/IHDR 校验失败"
    assert png_info["bit_depth"] == 8, "必须为 8-bit per channel"
    assert png_info["color_type"] == 6, "必须为 RGBA（color_type=6）"
    assert png_info["channels"] == 4
    assert png_info["total_bpp"] == 32, "必须为 32-bit RGBA"
    assert png_info["is_non_empty"], "降级 PNG 不得为全透明空图"
    assert os.path.isfile(png_file), "降级 PNG 文件应落盘"
    assert os.path.getsize(png_file) > 50
    # 独立复核 IHDR
    with open(png_file, "rb") as pf:
        sig = pf.read(8)
        assert sig == b"\x89PNG\r\n\x1a\n"
        pf.read(4)
        assert pf.read(4) == b"IHDR"
        ihdr = pf.read(13)
        _, _, bit_depth, color_type = struct.unpack(">IIBB", ihdr[:10])
        assert bit_depth == 8 and color_type == 6


def test_png_fallback_simple_pixel_layer(tmp_path):
    p = FX.build_simple_shape_like_psd(str(tmp_path / "px.psd"))
    out = str(tmp_path / "pngs")
    r = parse_psd_file(p, extract_fallback_pngs=True, png_output_dir=out)
    degraded = [d for d in r["diagnosis_report"]["layers"] if d["disposition"] == "degraded"]
    assert degraded, "像素层应降级为 PNG"
    fb = degraded[0]["fallback_png"]
    assert fb, "降级层须记录 fallback_png"
    _assert_png_32bit_rgba(fb, fb["path"])


def test_png_fallback_on_complex_psd(tmp_path):
    out = str(tmp_path / "pngs")
    r = parse_psd_file(COMPLEX_PSD, extract_fallback_pngs=True, png_output_dir=out)
    degraded = [d for d in r["diagnosis_report"]["layers"] if d["disposition"] == "degraded"]
    assert len(degraded) >= 2, "复杂 PSD 应至少有 2 个降级层"
    verified = 0
    for d in degraded:
        fb = d["fallback_png"]
        if fb:
            _assert_png_32bit_rgba(fb, fb["path"])
            verified += 1
    assert verified >= 2, "应至少验证 2 个 32 位透明 PNG"


def test_render_layer_to_png_bytes_helper():
    """直测 helper：对任意可 composite 图层返回 32 位 RGBA PNG 字节。"""
    r = parse_psd_file(COMPLEX_PSD)
    # 取一个降级（非文本）层名
    degraded_names = [d["layer_name"] for d in r["diagnosis_report"]["layers"] if d["disposition"] == "degraded"]
    assert degraded_names
    # 重新解析并拿到真实 layer 对象做 helper 直测
    from psd_tools import PSDImage
    psd = PSDImage.open(COMPLEX_PSD)
    target = next(l for l in psd.descendants() if l.name == degraded_names[0])
    ok, raw, info = render_layer_to_png_bytes(target)
    assert ok, f"helper 渲染失败: {info}"
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    assert info["bit_depth"] == 8 and info["color_type"] == 6
