#!/usr/bin/env python3
"""
A-16 四态证据生成工具（可在项目内逐字节复现）

背景（A-20 审核发现）：
  生成 `unverifiable` 截图的脚本原是临时脚本（/tmp/a16_uv.py），已删除且不在项目内，
  导致第三方拿到交付物无法复现该截图。本文件把生成逻辑固化到仓库，
  并纳入指纹清单。

覆盖四种状态：
  1. detected           —— macOS 原生环境，已装字体 + 覆盖该文本（PingFang + 中文）
  2. partial_missing    —— macOS 原生环境，已装字体但缺字形（Helvetica + 中文）
  3. font_missing       —— macOS 原生环境，字体未安装（CormorantInfant-Regular）
  4. unverifiable       —— 等价环境构造：拦截 builtins.__import__ 使 import AppKit 失败

关于第 4 态的性质（必须如实标注）：
  该截图来自「等价环境构造」，**不是 macOS 真机实拍**。
  其正确性由第三方在真实无 AppKit 环境（import AppKit 真实失败）独立交叉验证：
  8 个文字层全部返回 unverifiable，与截图中黄徽章一致。
  本脚本只负责「让程序进入该分支」，不负责证明「进入后判定正确」。

用法：
    python3 tools/make_a16_evidence.py
    python3 tools/make_a16_evidence.py --out docs/a16_evidence
"""
import argparse
import builtins
import json
import os
import subprocess
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(PROJECT_ROOT, "docs", "a16_evidence")
PSD_REL = "tests/data/four_state.psd"

# 四态各自使用的图层索引与期望状态
STATE_LAYERS = {
    "detected": 1,                 # 领 衔 呈 现 / PingFangSC-Regular
    "missing_fallback": 3,         # 新 娘  朱 永 宏 / Helvetica + 中文
    "font_missing": 5,             # 新 郎  陈 晗 / CormorantInfant-Regular
}

# 生成 unverifiable 截图时使用的子进程内联脚本
UNVERIFIABLE_RUNNER = r'''
import builtins, os, sys
_real = builtins.__import__
def _fake(n, *a, **k):
    if n == "AppKit" or n.startswith("AppKit."):
        raise ImportError("simulated no-AppKit (equivalent environment)")
    return _real(n, *a, **k)
builtins.__import__ = _fake
for m in [m for m in list(sys.modules) if m.startswith("AppKit")]:
    del sys.modules[m]

os.environ["QT_QPA_PLATFORM"] = "offscreen"
sys.path.insert(0, PROJECT_ROOT_PLACEHOLDER)

from PyQt6.QtWidgets import QApplication
from core.psd_parser import parse_psd_file
from gui.canvas_view import CanvasContainer

app = QApplication.instance() or QApplication(sys.argv)
p = parse_psd_file(PSD_PLACEHOLDER, extract_thumbnails=True)
c = CanvasContainer(); c.resize(1500, 1000); c.show()
c.load_layers(p["layers"]); c.set_artboard_resolution(p["width"], p["height"])
c._on_checkerboard_toggled(True)
app.processEvents()
c.grab().save(OUT_PLACEHOLDER)

states = sorted({l.font_info["detection_status"]
                 for l in p["layers"] if l.kind == "type"})
print("STATUSES=" + ",".join(states))
print("LAYER_COUNT=%d" % len([l for l in p["layers"] if l.kind == "type"]))
'''


def _guard_write(path: str):
    """与 tools/round.py 一致的白名单策略：只允许写入项目根目录内"""
    resolved = os.path.realpath(os.path.abspath(path))
    root = os.path.realpath(os.path.abspath(PROJECT_ROOT))
    if resolved != root and not resolved.startswith(root + os.sep):
        raise SystemExit(f"拒绝写入项目根目录之外的路径: {resolved}")


def _write_png_via_subprocess(out_png: str) -> str:
    """
    在子进程内拦截 AppKit 后渲染 unverifiable 截图。
    必须用子进程：本进程若已 import AppKit，无法可靠回退。
    """
    script = (
        UNVERIFIABLE_RUNNER
        .replace("PROJECT_ROOT_PLACEHOLDER", repr(PROJECT_ROOT))
        .replace("PSD_PLACEHOLDER", repr(os.path.join(PROJECT_ROOT, PSD_REL)))
        .replace("OUT_PLACEHOLDER", repr(out_png))
    )
    env = dict(os.environ)
    env["QT_QPA_PLATFORM"] = "offscreen"
    proc = subprocess.run([sys.executable, "-c", script],
                          cwd=PROJECT_ROOT, env=env,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"unverifiable 截图生成失败:\n{proc.stderr}")
    return proc.stdout


def _font_evidence() -> list:
    """四重交叉验证字体是否存在"""
    import AppKit
    avail = set(AppKit.NSFontManager.sharedFontManager().availableFonts())
    ats = subprocess.run(["atsutil", "fonts", "-list"],
                         capture_output=True, text=True).stdout
    ats_names = {l.strip() for l in ats.splitlines() if l.strip()}

    from core.psd_parser import check_font_availability_status
    rows = []
    for name in ("PingFangSC-Regular", "Helvetica",
                 "CormorantInfant-Regular", "FZZYSK--GBK1-0"):
        rows.append({
            "font": name,
            "canonical_status": check_font_availability_status(name),
            "in_NSFontManager_availableFonts": name in avail,
            "NSFont_instance_created":
                AppKit.NSFont.fontWithName_size_(name, 12.0) is not None,
            "in_atsutil_fonts_list": name in ats_names,
        })
    return rows, sorted(a for a in avail if "Cormorant" in a)


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 A-16 四态证据")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    out_dir = os.path.abspath(args.out)
    _guard_write(os.path.join(out_dir, "placeholder"))
    os.makedirs(out_dir, exist_ok=True)

    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    sys.path.insert(0, PROJECT_ROOT)

    from PyQt6.QtWidgets import QApplication
    from core.psd_parser import (parse_psd_file, check_font_glyph_coverage,
                                 check_font_availability_status)
    from gui.canvas_view import CanvasContainer

    app = QApplication.instance() or QApplication(sys.argv)
    psd_path = os.path.join(PROJECT_ROOT, PSD_REL)

    parsed = parse_psd_file(psd_path, extract_thumbnails=True)

    # ── 1~3 态：macOS 原生环境真实渲染 ──
    for state, idx in STATE_LAYERS.items():
        layer = next(l for l in parsed["layers"] if l.index == idx)
        c = CanvasContainer()
        c.resize(1200, 800)
        c.show()
        c.load_layers([layer])
        c.set_artboard_resolution(parsed["width"], parsed["height"])
        c._on_checkerboard_toggled(True)
        c.right_canvas.centerOn(0, 0)
        app.processEvents()
        out = os.path.join(out_dir, f"A16_{state}.png")
        _guard_write(out)
        c.grab().save(out)
        badge, _, _ = c.right_canvas.items_map[idx].get_badge_info()
        print(f"[native] {state:18} layer={layer.name!r} badge={badge}")

    # 同屏总览（macOS 三态）
    c = CanvasContainer()
    c.resize(1500, 1000)
    c.show()
    c.load_layers(parsed["layers"])
    c.set_artboard_resolution(parsed["width"], parsed["height"])
    c._on_checkerboard_toggled(True)
    app.processEvents()
    out = os.path.join(out_dir, "A16_four_state_canvas_macos.png")
    _guard_write(out)
    c.grab().save(out)

    # ── 4 态：等价环境构造（非真机实拍） ──
    uv_out = os.path.join(out_dir, "A16_unverifiable_canvas_noappkit.png")
    _guard_write(uv_out)
    uv_stdout = _write_png_via_subprocess(uv_out)
    print("[equivalent] unverifiable -> " +
          ",".join(l for l in uv_stdout.splitlines() if l.startswith("STATUSES=")))

    # ── 结构化证据 ──
    fonts, cormorant_family = _font_evidence()
    layers = []
    for d in parsed["diagnostics"]["font_diagnostics"]:
        st = d["detection_status"]
        layers.append({
            "layer_index": d["layer_index"],
            "layer_name": d["layer_name"],
            "font": d["original_font"],
            "internal_status": st,
            "four_state": {
                "detected": "detected",
                "missing_fallback": "partial_missing(字形缺失)",
                "font_missing": "font_missing",
                "unverifiable": "unverifiable",
            }.get(st, st),
            "glyph_coverage": d["glyph_coverage"],
            "missing_chars": d["missing_chars"],
        })

    evidence = {
        "psd": PSD_REL,
        "psd_width": parsed["width"],
        "psd_height": parsed["height"],
        "platform": "macOS (AppKit available)",
        "generator": "tools/make_a16_evidence.py",
        "unverifiable_method": (
            "等价环境构造：拦截 builtins.__import__ 使 import AppKit 失败；"
            "非 macOS 真机实拍。其判定正确性由第三方在真实无 AppKit 环境交叉验证。"
        ),
        "fonts": fonts,
        "glyph_proof": {
            "Helvetica_on_chinese":
                check_font_glyph_coverage("Helvetica", "新娘朱永宏"),
            "PingFang_on_chinese":
                check_font_glyph_coverage("PingFangSC-Regular", "新娘朱永宏"),
        },
        "layers": layers,
        "cormorant_variant_check": {
            "cormorant_family_available": cormorant_family,
            "cormorantinfant_count":
                len([a for a in cormorant_family if "CormorantInfant" in a]),
        },
    }
    ev_path = os.path.join(out_dir, "A16_font_and_state_evidence.json")
    _guard_write(ev_path)
    with open(ev_path, "w", encoding="utf-8") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=2)

    print(f"\n证据目录: {os.path.relpath(out_dir, PROJECT_ROOT)}")
    print(f"文件数: {len(os.listdir(out_dir))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
