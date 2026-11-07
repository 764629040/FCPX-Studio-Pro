"""
回归测试：第三轮审核 A-10 / A-13 + A-9 裁决要求的两处最小修正

  A-10  无 AppKit 平台把「无法检测」误报为「字体未安装」
  A-13  左栏整幅错位（OriginalLayerGraphicItem 固化画板尺寸，
        set_artboard_resolution 不重算既有图元）
  A-9a  诊断链路与画布链路 extract_thumbnails 开关口径不一致
  A-9b  图层组 / 真空层 / 切片解码失败 三种情况文案混同

对应修复：
  core/psd_parser.py  — 新增 appkit_available() / check_font_availability_status() 三态；
                        检测状态改为按 availability 区分，无能力时归 unverifiable；
                        generate_conversion_diagnosis_report 增加 extract_thumbnails 参数（默认 True）。
  gui/canvas_view.py  — set_artboard_resolution 增加 _relayout_items()；
                        占位原因拆分为 group / empty_layer / no_slice / decode_failed。
"""

# R26（独立复核报告 R25 §十.5）：本文件为 GUI 运行时测试，需真实 PyQt6 显示环境。
# 无 PyQt6 的环境按「手工验证，不自动跑」处理：importorskip 使其干净跳过（SKIPPED，非 ERROR）。
import pytest as _pytest_r26
_pytest_r26.importorskip("PyQt6", reason="GUI 测试需 PyQt6；无则转手工验证，不自动跑")

import os
import sys
import builtins

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.psd_parser import (
    parse_psd_file,
    check_font_availability,
    check_font_availability_status,
    appkit_available,
    generate_conversion_diagnosis_report,
    PSDLayerInfo,
)
from gui.canvas_view import CanvasContainer, OriginalLayerGraphicItem

app = QApplication.instance() or QApplication(sys.argv)

DATA_DIR = os.path.join(TESTS_DIR, "data")
VERTICAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")
FOUR_STATE_PSD = os.path.join(DATA_DIR, "four_state.psd")

try:
    import AppKit  # noqa: F401
    HAS_APPKIT = True
except Exception:
    HAS_APPKIT = False


# ═══════════════════════════════════════════════════════════════
# A-10  无法检测 ≠ 字体未安装
# ═══════════════════════════════════════════════════════════════
def test_availability_status_never_reports_missing_without_capability():
    """
    A-10 核心：无检测能力时必须返回 unverifiable，绝不能返回 missing。
    """
    status = check_font_availability_status("SomeFontThatMayOrMayNotExist")
    if not HAS_APPKIT:
        assert status == "unverifiable", (
            f"无 AppKit 时误报为 {status}，应为 unverifiable"
        )
    else:
        assert status in ("available", "missing", "unverifiable")


def test_appkit_available_matches_import_result():
    """能力判定必须与真实导入结果一致"""
    assert appkit_available() is HAS_APPKIT


def test_no_appkit_parsing_yields_unverifiable_not_font_missing(monkeypatch):
    """
    A-10 核心（跨平台）：模拟无 AppKit 解析真实 PSD，
    所有文本图层必须为 unverifiable，严禁出现 font_missing。
    这正是审核方在 Linux 环境实测失败的断言。
    """
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "AppKit" or name.startswith("AppKit."):
            raise ImportError("simulated environment without AppKit")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)

    # A-49：不再 del sys.modules / importlib.reload —— 模块身份必须唯一，
    # 否则会污染同进程后续用例（复核方实证 c_11 随机红/绿）。
    # psd_parser 对 AppKit 是函数内延迟 import，调用期被 fake_import 拦截即可。
    import core.psd_parser as fresh

    parsed = fresh.parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    statuses = {l.font_info["detection_status"]
                for l in parsed["layers"] if l.kind == "type"}

    assert statuses == {"unverifiable"}, (
        f"无 AppKit 时应统一 unverifiable，实际 {statuses}"
    )
    assert "font_missing" not in statuses, "无检测能力不得谎报字体未安装"

    summary = parsed["diagnosis_report"]["summary"]
    assert summary["has_missing_risk"] is True
    assert summary["unverifiable_fonts_count"] > 0


def test_no_appkit_warning_text_is_not_misleading(monkeypatch):
    """A-10：无能力时告警文案不得写"未安装" """
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "AppKit" or name.startswith("AppKit."):
            raise ImportError("simulated environment without AppKit")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)

    # A-49：同上，不 del sys.modules / 不 reload，模块身份唯一
    import core.psd_parser as fresh

    parsed = fresh.parse_psd_file(FOUR_STATE_PSD, extract_thumbnails=False)
    warnings = parsed["diagnostics"].get("warnings", [])
    assert warnings, "应产生至少一条字体告警"
    # A-10 原意：无能力时任何告警都不得把「无法检测」谎报为「未安装」
    for w in warnings:
        assert "未安装" not in w, f"无能力却称未安装: {w}"
    # 且必须至少有一条明确告知「无法检测 / 风险未知 / 待复核」
    # （R26 起新增了「缺字/缺字体风险 (unverifiable)」类告警，不含上述三词但同样诚实，
    #   故此处由「逐条必须含」改为「至少一条含」，不降低「不得谎报未安装」的强度）
    assert any(
        ("无法检测" in w or "风险未知" in w or "待复核" in w) for w in warnings
    ), f"无能力时必须有明确的风险未知类告警，实际: {warnings}"


def test_bool_wrapper_still_works():
    """兼容性：布尔接口语义保持不变"""
    assert check_font_availability("PingFangSC-Regular") is (check_font_availability_status("PingFangSC-Regular") == "available")
    assert check_font_availability("") is False
    assert check_font_availability_status("AdobeInvisFont") == "missing"


# ═══════════════════════════════════════════════════════════════
# A-13  画板尺寸变化后图元必须重新定位
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("psd_path,label", [
    (VERTICAL_PSD, "竖版 1080x1920"),
    (COMPLEX_PSD, "横版 1920x1080"),
])
def test_artboard_resolution_change_relayouts_items(psd_path, label):
    """
    A-13 核心：先加载图层、后设置画板分辨率（审核方复现路径），
    左右两栏图元位置必须完全一致，不得整幅错位。
    """
    parsed = parse_psd_file(psd_path, extract_thumbnails=True)
    container = CanvasContainer()
    container.resize(1500, 950)
    container.show()

    container.load_layers(parsed["layers"])                       # 先加载
    container.set_artboard_resolution(parsed["width"], parsed["height"])  # 后设尺寸

    mismatched = []
    for layer in parsed["layers"]:
        left = container.left_canvas.items_map[layer.index]
        right = container.right_canvas.items_map[layer.index]
        dx = abs(left.pos().x() - right.pos().x())
        dy = abs(left.pos().y() - right.pos().y())
        if dx > 0.5 or dy > 0.5:
            mismatched.append((layer.name, dx, dy))

    assert not mismatched, f"{label} 左右图元位置不一致: {mismatched[:3]}"


def test_artboard_reference_center_is_used():
    """
    A-13 根因回归：图元位置必须以当前画板中心为参照。
    改分辨率后，位置应随参照系变化，而不是保持旧值。
    """
    parsed = parse_psd_file(VERTICAL_PSD, extract_thumbnails=True)
    layer = parsed["layers"][0]

    container = CanvasContainer()
    container.show()
    container.load_layers(parsed["layers"])

    container.set_artboard_resolution(1080, 1920)
    pos_narrow = container.left_canvas.items_map[layer.index].pos()

    # 换成方形画板：中心参考系改变，图元位置必须随之改变
    container.set_artboard_resolution(1080, 1080)
    pos_square = container.left_canvas.items_map[layer.index].pos()

    assert (pos_narrow.x(), pos_narrow.y()) != (pos_square.x(), pos_square.y()), (
        "改画板尺寸后图元位置未重算，仍是旧参照系"
    )


# ═══════════════════════════════════════════════════════════════
# A-9a  两条链路 extract_thumbnails 口径统一
# ═══════════════════════════════════════════════════════════════
def test_diagnosis_report_and_canvas_share_thumbnail_switch():
    """
    A-9a 核心：诊断链路与画布链路默认开关必须一致，
    不得出现"画布有切片、诊断无切片"的内部口径分裂。
    """
    import inspect
    sig_parse = inspect.signature(parse_psd_file)
    sig_diag = inspect.signature(generate_conversion_diagnosis_report)

    assert "extract_thumbnails" in sig_diag.parameters, (
        "generate_conversion_diagnosis_report 未暴露 extract_thumbnails 开关"
    )
    assert (
        sig_parse.parameters["extract_thumbnails"].default
        == sig_diag.parameters["extract_thumbnails"].default
    ), "诊断链路与解析链路的默认开关不一致"


def test_diagnosis_report_produces_slices_by_default():
    """A-9a：默认调用诊断链路时，必须能拿到原稿切片（与画布一致）"""
    report = generate_conversion_diagnosis_report(VERTICAL_PSD)
    assert report["summary"]["total_layers"] > 0

    parsed = parse_psd_file(VERTICAL_PSD)
    with_slice = [l for l in parsed["layers"]
                  if l.kind == "type" and l.original_slice_bytes]
    assert len(with_slice) > 0, "默认路径未产出原稿切片"


# ═══════════════════════════════════════════════════════════════
# A-9b  三类占位原因文案必须可区分
# ═══════════════════════════════════════════════════════════════
def _make_info(**kw):
    base = dict(index=1, name="t", kind="type", text="T", font_name="Helvetica",
                font_size=20.0, tracking=0.0, psd_bbox=(0, 0, 100, 50), motion_pos=(0, 0))
    base.update(kw)
    return PSDLayerInfo(**base)


def test_placeholder_reason_group():
    info = _make_info(layer_type="group")
    item = OriginalLayerGraphicItem(info, 1920, 1080)
    assert item.placeholder_reason == "group"
    assert item.is_empty_or_group is True


def test_placeholder_reason_empty_layer():
    info = _make_info()
    info.is_empty = True
    item = OriginalLayerGraphicItem(info, 1920, 1080)
    assert item.placeholder_reason == "empty_layer"


def test_placeholder_reason_no_slice():
    info = _make_info()
    item = OriginalLayerGraphicItem(info, 1920, 1080)
    assert item.placeholder_reason == "no_slice"


def test_placeholder_reason_decode_failed():
    info = _make_info(original_slice_bytes=b"not-a-real-png-payload")
    item = OriginalLayerGraphicItem(info, 1920, 1080)
    assert item.placeholder_reason == "decode_failed"


def test_placeholder_reasons_are_all_distinct():
    """A-9b 核心：四种原因（含正常）必须互不相同，不得共用一句文案"""
    infos = []

    g = _make_info(index=1, layer_type="group"); infos.append(g)
    e = _make_info(index=2); e.is_empty = True; infos.append(e)
    n = _make_info(index=3); infos.append(n)
    d = _make_info(index=4, original_slice_bytes=b"bad"); infos.append(d)

    reasons = [OriginalLayerGraphicItem(i, 1920, 1080).placeholder_reason for i in infos]
    assert reasons == ["group", "empty_layer", "no_slice", "decode_failed"]
    assert len(set(reasons)) == 4


def test_real_slices_do_not_trigger_placeholder():
    """正常路径：有真实切片时不应进入任何占位分支"""
    parsed = parse_psd_file(VERTICAL_PSD, extract_thumbnails=True)
    for layer in parsed["layers"]:
        if layer.kind == "type" and layer.original_slice_bytes:
            item = OriginalLayerGraphicItem(layer, parsed["width"], parsed["height"])
            assert item.placeholder_reason is None, (
                f"{layer.name} 有切片却被判为占位: {item.placeholder_reason}"
            )
            assert item.is_empty_or_group is False
