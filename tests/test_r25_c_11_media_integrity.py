"""
R25 C-11 媒体资产完整性（SA-2b 修复 SA-4 问题 2）
==================================================
SA-4 独立复查发现：composite 失败（典型：缺 scipy 时带描边图层）时，
.moti 仍引用不存在的 Media/element_XX.png、构建 status=ok、错误被
构建期 except:pass 吞掉——坏交付物全程静默出货。

本文件锁定修复后的契约（解析侧，psd_parser/psd_layer_fallback 范围）：
1. 媒体生成失败必须大声记录：诊断条目 severity='error'、
   "Media 资产生成失败: <确切原因>"、layer_name 明确；
2. 机器可核查计数器 missing_media_refs（顶层 + summary 同源），
   > 0 时整体诊断不得宣称完整成功（risk_assessment 为高风险）；
3. 失败层绝不静默丢弃：以 degraded 计入 output，守恒恒成立；
4. 失败层 fallback_png_path 必须为 None（绝不引用不存在的 PNG）；
5. best-effort 回退：composite 抛错时用 PIL 原始像素 (topil) 渲染，
   回退也失败才如实报错。

注意：测试不依赖 scipy 是否安装——失败路径用 monkeypatch 强制注入。
"""
import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from PIL import Image

import r25_fixtures as FX
from core.psd_parser import parse_psd_file, verify_layer_conservation
from core.psd_layer_fallback import render_layer_to_png_bytes


def _degraded_with_media_error(r):
    return [d for d in r["diagnosis_report"]["layers"] if d.get("media_error")]


def test_media_failure_recorded_loudly_not_silent(tmp_path, monkeypatch):
    """强制 composite 失败 → 诊断逐层记录失败 + missing_media_refs>=1 + 守恒不破。"""
    # 注入总失败：模拟 composite 与 PIL 回退全部失败（与 scipy 是否安装无关）
    def _always_fail(layer):
        return False, None, {"error": "模拟 composite 失败: Stroke effects require: scipy (SA-2b 注入)"}

    monkeypatch.setattr("core.psd_parser.render_layer_to_png_bytes", _always_fail)

    p = FX.build_visible_smartobject_psd(str(tmp_path / "so_media_fail.psd"))
    out = str(tmp_path / "pngs")
    r = parse_psd_file(p, extract_fallback_pngs=True, png_output_dir=out)

    # 1) 守恒不因失败而破：失败层以 degraded 计入 output，绝不静默消失
    cons = verify_layer_conservation(r)
    assert cons["holds"], f"守恒被破坏: {cons['detail']}"
    failed_layers = _degraded_with_media_error(r)
    assert failed_layers, "媒体失败必须有诊断条目，不得静默"
    assert len(failed_layers) >= 1
    for d in failed_layers:
        assert d["disposition"] == "degraded", "失败层必须仍计入 output（degraded-with-warning）"
        assert d["severity"] == "error", "媒体失败严重度必须为 error"
        assert "Media 资产生成失败" in d["media_error"], "必须携带标准失败前缀"
        assert "模拟 composite 失败" in d["media_error"], "必须携带确切失败原因"
        assert "Media 资产生成失败" in d["reason"], "处置原因须包含失败信息"
        assert d.get("fallback_png", {}).get("missing_media_ref") is True

    # 2) 机器可核查计数器：顶层与 summary 同源且 >= 1
    assert r["missing_media_refs"] >= 1
    assert r["diagnosis_report"]["summary"]["missing_media_refs"] == r["missing_media_refs"]
    assert r["missing_media_refs"] == len(failed_layers)

    # 3) 整体诊断不得宣称完整成功
    risk = r["diagnosis_report"]["summary"]["risk_assessment"]
    assert "高风险" in risk and "媒体资产" in risk, f"风险结论必须示警媒体缺失: {risk}"

    # 4) 警告列表同样记录（供 GUI/诊断面板展示）
    assert any("Media 资产生成失败" in w for w in r["diagnostics"]["warnings"])

    # 5) 绝不悬挂引用：失败层的 fallback_png_path 必须为 None
    for li in r["layers"]:
        if li.kind == "fallback_png" and li.name in {d["layer_name"] for d in failed_layers}:
            assert li.fallback_png_path is None, (
                f"图层 '{li.name}' 媒体生成失败后仍引用 PNG 路径: {li.fallback_png_path}"
            )


def test_media_failure_conservation_never_drops_layer(tmp_path, monkeypatch):
    """失败层守恒专项：output 里必须数得到每一个失败层，无静默丢弃。"""
    def _always_fail(layer):
        return False, None, {"error": "注入失败"}

    monkeypatch.setattr("core.psd_parser.render_layer_to_png_bytes", _always_fail)
    p = FX.build_visible_smartobject_psd(str(tmp_path / "so_cons.psd"))
    r = parse_psd_file(p, extract_fallback_pngs=True, png_output_dir=str(tmp_path / "pngs"))

    cons = verify_layer_conservation(r)
    assert cons["holds"], cons["detail"]
    failed_names = {d["layer_name"] for d in _degraded_with_media_error(r)}
    output_names = {l.name for l in r["layers"]}
    assert failed_names <= output_names, "每个失败层都必须仍在输出层集合中被计账"
    assert len(r["diagnosis_report"]["layers"]) == cons["input_layer_count"]


def test_media_success_path_zero_missing_refs(tmp_path):
    """正常路径（不注入失败）：missing_media_refs == 0，产出 PNG 真实落盘。
    依赖 PIL 原始像素回退，与 scipy 是否安装无关。"""
    p = FX.build_visible_smartobject_psd(str(tmp_path / "so_ok.psd"))
    out = str(tmp_path / "pngs")
    r = parse_psd_file(p, extract_fallback_pngs=True, png_output_dir=out)

    assert r["missing_media_refs"] == 0, "无注入失败时不应有缺失媒体引用"
    assert "高风险" not in r["diagnosis_report"]["summary"]["risk_assessment"] or "媒体资产" not in r["diagnosis_report"]["summary"]["risk_assessment"]
    # 每个声称有 PNG 的降级层，文件必须真实存在（杜绝引用不存在文件）
    for d in r["diagnosis_report"]["layers"]:
        fb = d.get("fallback_png")
        if fb and fb.get("path"):
            assert os.path.isfile(fb["path"]), f"诊断声称的 PNG 不存在: {fb['path']}"


class _FakeLayerCompositeRaises:
    """composite 抛错（模拟缺 scipy 的描边图层），topil 可用（PIL 原始像素）。"""
    def composite(self):
        raise RuntimeError("Stroke effects require: scipy")

    def topil(self):
        return Image.new("RGBA", (10, 12), (255, 0, 0, 255))


class _FakeLayerAllFail:
    """composite 与 topil 全部抛错——必须如实报错，不得伪造成功。"""
    def composite(self):
        raise RuntimeError("composite boom")

    def topil(self):
        raise RuntimeError("topil boom")


def test_pil_fallback_when_composite_raises():
    """best-effort 回退：composite 抛错 → PIL 原始像素渲染成功并诚实标注。"""
    ok, raw, info = render_layer_to_png_bytes(_FakeLayerCompositeRaises())
    assert ok, f"PIL 回退应成功: {info}"
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    assert info["render_method"] == "pil_topil_fallback"
    assert "fallback_note" in info, "必须诚实标注该 PNG 来自回退路径（效果未包含）"
    assert info["width"] == 10 and info["height"] == 12
    assert info["bit_depth"] == 8 and info["color_type"] == 6


def test_both_composite_and_pil_fail_reports_error():
    """composite 与 PIL 回退均失败：如实返回错误（由解析侧大声记录）。"""
    ok, raw, info = render_layer_to_png_bytes(_FakeLayerAllFail())
    assert ok is False
    assert raw is None
    assert "composite 失败" in info["error"] and "topil boom" in info["error"]
