"""
回归测试：字体诊断环境可验证性 (unverifiable) 不得伪通过
对应修复：
  1. core/psd_parser.py — 诊断汇总新增 unverifiable_fonts_count，
     并将 unverifiable 计入 has_missing_risk，禁止在无法检测字形时输出
     "无风险 / 字体覆盖率 100%"。
  2. tests/test_psd_import_and_diagnosis.py — 正常文本 PSD 用例按
     字体真实注册状态分支断言（已安装 / 未安装 / 无 AppKit 三态）。

本文件独立可跑：
  pytest tests/test_font_diagnosis_honesty.py -v
"""
import os
import sys
import builtins

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

DATA_DIR = os.path.join(TESTS_DIR, "data")
NORMAL_PSD = os.path.join(DATA_DIR, "vertical_wedding_9_16.psd")

try:
    import AppKit  # noqa: F401
    HAS_APPKIT = True
except Exception:
    HAS_APPKIT = False


@pytest.fixture()
def no_appkit(monkeypatch):
    """A-49 修复：模拟无 AppKit 环境，但**不碰 sys.modules、不做模块重载**。

    旧实现 del sys.modules["core.psd_parser"] + reload 会造成模块身份分裂
    （重载产生的新模块对象与收集期绑定的旧模块函数 __globals__ 不是同一份 dict），
    后续用例的 monkeypatch 打在新对象上、被测代码却调用旧函数，补丁失效 →
    全量跑序下 c_11 媒体完整性用例随机红/绿（复核方 A-49 实证）。

    新实现只用 monkeypatch.setattr 拦截 builtins.__import__ 中的 AppKit 导入：
    - core/psd_parser.py 对 AppKit 全部是**函数内延迟 import**（模块级没有
      HAS_APPKIT 标志、没有模块级 AppKit 引用），import 语句在调用期经过
      __import__，拦截即等效于真实 Linux 无 AppKit 环境；
    - monkeypatch 在用例结束时自动还原 __import__，零手工清理；
    - 模块对象自始至终唯一，测试间零污染。
    """
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "AppKit" or name.startswith("AppKit."):
            raise ImportError("simulated environment without AppKit")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    import core.psd_parser as parser_mod  # 已导入的同一模块对象，不重载
    yield parser_mod
    # 无需任何手工恢复：monkeypatch 自动撤销 __import__ 补丁


def test_unverifiable_must_not_claim_no_risk(no_appkit):
    """无 AppKit 时：必须返回 unverifiable，且汇总严禁宣称无风险/100% 覆盖"""
    parsed = no_appkit.parse_psd_file(NORMAL_PSD, extract_thumbnails=False)
    summary = parsed["diagnosis_report"]["summary"]

    preserved = [l for l in parsed["diagnosis_report"]["layers"] if l["disposition"] == "preserved"]
    assert len(preserved) == 8
    for item in preserved:
        assert item["font_status"] == "unverifiable", "无字形检测能力时必须明确 unverifiable"

    assert summary["unverifiable_fonts_count"] == 8
    assert summary["missing_fonts_count"] == 0
    assert summary["has_missing_risk"] is True, "不可验证必须计入风险，严禁静默放行"
    assert "无法确定风险" in summary["risk_assessment"]
    assert "无风险" not in summary["risk_assessment"]
    assert "100%" not in summary["risk_assessment"], "不可验证时严禁宣称字体覆盖率 100%"


def test_unverifiable_count_present_in_all_report_shapes(tmp_path):
    """正常 / 损坏 / 解析异常三种报告形状都必须携带 unverifiable_fonts_count 字段"""
    from core.psd_parser import generate_conversion_diagnosis_report

    normal = generate_conversion_diagnosis_report(NORMAL_PSD)
    assert "unverifiable_fonts_count" in normal["summary"]

    corrupted = generate_conversion_diagnosis_report(os.path.join(DATA_DIR, "corrupted_file.psd"))
    assert corrupted["summary"]["unverifiable_fonts_count"] == 0
    assert corrupted["summary"]["failed_count"] == 1
    assert corrupted["summary"]["has_missing_risk"] is True


def test_declared_font_state_is_honest_and_complete():
    """
    真实环境：无论样本字体是否注册，诊断状态都必须与真实注册状态一致，
    且三态（complete / font_missing / unverifiable）之一必须被明确给出，
    严禁 None、空值或与真实状态矛盾的伪通过。
    """
    from core.psd_parser import parse_psd_file, check_font_availability

    parsed = parse_psd_file(NORMAL_PSD, extract_thumbnails=False)
    declared = parsed["diagnostics"]["font_diagnostics"][0]["original_font"]
    assert declared == "FZZYSK--GBK1-0"

    if not HAS_APPKIT:
        expected = "unverifiable"
    elif check_font_availability(declared):
        expected = "complete"
    else:
        expected = "font_missing"

    preserved = [l for l in parsed["diagnosis_report"]["layers"] if l["disposition"] == "preserved"]
    for item in preserved:
        assert item["font_status"] == expected, (
            f"图层 {item['layer_name']} 字体状态 {item['font_status']} 与真实状态 {expected} 不一致"
        )
        if expected == "font_missing":
            assert len(item["missing_glyphs"]) > 0
        elif expected == "complete":
            assert item["missing_glyphs"] == []

    summary = parsed["diagnosis_report"]["summary"]
    if expected == "font_missing":
        assert summary["has_missing_risk"] is True
        assert summary["missing_fonts_count"] == 8
    elif expected == "unverifiable":
        assert summary["has_missing_risk"] is True
    else:
        assert summary["has_missing_risk"] is False
