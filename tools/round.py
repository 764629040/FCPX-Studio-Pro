#!/usr/bin/env python3
"""
FCPX Studio Pro — 审核轮次自动化工具（round.py）

把每轮重复的手工操作收敛成一条命令，替代以下人工步骤：
  1. 手工重算 30 个受控文件的 SHA-256 并写清单
  2. 分别跑 macOS / 无 AppKit 两套测试并手工记录退出码
  3. 手工比对上一轮清单，找出"到底改了哪几个文件"
  4. 手工整理日志路径与统计数据

设计约束（与项目红线一致）：
  - 退出码一律直接取自 subprocess 返回值，绝不经过 tee / 管道
  - 不写 /Volumes/NO NAME/128（只读铁律），写入前显式校验
  - 不声称跨卷一致，清单内只记 canonical_path
  - 不修改任何源码，只读源码 + 写 docs/

用法：
    python3 tools/round.py verify            # 只跑双环境测试 + 记录退出码
    python3 tools/round.py inventory [--tag round6]
                                             # 只生成指纹清单并对比上一轮
    python3 tools/round.py all --tag round6  # 全流程：指纹 + 双环境测试 + 差异摘要
    python3 tools/round.py diff <旧清单> [--new 新清单]
                                             # 对比两份清单，列出改动文件
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS_DIR = os.path.join(PROJECT_ROOT, "docs")

# 只读卷黑名单：作为额外防线保留（防御性冗余），
# 但主防线是下面的「白名单」——写入必须落在项目根目录内。
FORBIDDEN_ROOTS = ("/Volumes/NO NAME/128",)

# 受控文件清单（与历轮 audit_inventory 保持一致）
SOURCE_FILES = [
    "core/psd_parser.py", "core/motion_builder.py", "core/cli_bridge.py",
    "core/thumbnail.py", "core/symlink_manager.py", "core/__init__.py",
    "gui/main_window.py", "gui/canvas_view.py", "gui/inspector_panel.py",
    "gui/asset_hub_panel.py", "gui/__init__.py", "main.py", "requirements.txt",
]
TEST_FILES = [
    "tests/test_clean_environment.py",
    "tests/test_psd_import_and_diagnosis.py",
    "tests/test_preview_comparison.py",
    "tests/test_font_diagnosis_honesty.py",
    "tests/test_p0_rotation_and_reason.py",
    "tests/test_round2_a3_to_a7.py",
    "tests/test_round3_a9_a10_a13.py",
    "tests/test_round4_a12_a17.py",
    # A-23：以下测试文件此前遗漏，现全部纳入受控清单
    "tests/test_round5_tools_inventory.py",
    "tests/test_a15_badge_collapse.py",
    "tests/test_a20_evidence_inventory.py",
    "tests/probe_real_interaction.py",
    "tests/make_four_state_fixture.py",
]
FIXTURE_FILES = [
    "tests/data/vertical_wedding_9_16.psd",
    "tests/data/wedding_with_decorations_23.psd",
    "tests/data/complex_layers.psd",
    "tests/data/commercial_4k.psd",
    "tests/data/corrupted_file.psd",
    "tests/data/four_state.psd",
    "tests/data/vertical_9x16_true.psd",
    "tests/data/vertical_9x16_true.json",
    "tests/data/vertical_9x16_rebased.psd",
    "assets/reference_base.moti",
]
# A-19：工具自身必须纳入受控清单。
# round.py 能写 docs/、能起子进程、能生成清单，是高权限工具；
# 若自身不受指纹保护，任何改动都无法被发现——因此与源码同等对待。
TOOL_FILES = [
    "tools/round.py",
    "tools/make_a16_evidence.py",
    "tools/dsh-plugin/package.json",
    "tools/dsh-plugin/cordis.patch.yml",
    "tools/dsh-plugin/index.js",
    "tools/dsh-plugin/README.md",
]
# A-20：审核证据文件同样必须受指纹保护。
# 证据若可被替换而无人察觉，整个审核链的可信度就无从谈起。
EVIDENCE_FILES = [
    "docs/a15_evidence/A15_folded_dots.png",
    "docs/a15_evidence/A15_expanded_on_hover.png",
    "docs/a15_evidence/A15_singleton_multi_select.png",
    "docs/a15_evidence/A22_fit_zoom_dots.png",
    "docs/host_verify/Motion_23.moti_130616.png",
    "docs/host_verify/Motion_1.moti_130713.png",
    "docs/host_verify/snapshot_Motion_130616.json",
    "docs/host_verify/snapshot_Motion_130713.json",
    "docs/round13_evidence/a24_comp_size_verify.json",
    "docs/round14_evidence/a28_a29_verify.json",
    "docs/round15_evidence/a30_a31_verify.json",
    "docs/round16_evidence/a30_verdict_c_verify.json",
    "docs/round17_evidence/a33_four_state_verify.json",
    "build_staging/_build_review.json",
    "build_staging/T01_领衔呈现_竖版/T01_领衔呈现_竖版.moti",
    "build_staging/T01_领衔呈现_竖版/large.png",
    "build_staging/T01_领衔呈现_竖版/small.png",
    "build_staging/T23_含装饰_横版/T23_含装饰_横版.moti",
    "build_staging/T23_含装饰_横版/large.png",
    "build_staging/T23_含装饰_横版/small.png",
    "build_staging/T23_含装饰_横版/Media/element_03_箭头.png",
    "build_staging/T23_含装饰_横版/Media/element_05_横线.png",
    "docs/a16_evidence/A16_detected.png",
    "docs/a16_evidence/A16_missing_fallback.png",
    "docs/a16_evidence/A16_font_missing.png",
    "docs/a16_evidence/A16_unverifiable_canvas_noappkit.png",
    "docs/a16_evidence/A16_four_state_canvas_macos.png",
    "docs/a16_evidence/A16_font_and_state_evidence.json",
]
def _discover_test_files() -> list:
    """
    A-23 根治：自动发现 tests/ 下所有测试文件，避免新增测试被漏登记。
    与显式清单取并集——显式清单保证顺序稳定，自动发现保证不漏。
    """
    import glob
    found = []
    for p in sorted(glob.glob(os.path.join(PROJECT_ROOT, "tests", "*.py"))):
        rel = os.path.relpath(p, PROJECT_ROOT)
        if os.path.basename(p) == "__init__.py":
            continue
        found.append(rel)
    return found


def _merge_test_files() -> list:
    """显式清单 + 自动发现，去重保序"""
    merged = list(TEST_FILES)
    for rel in _discover_test_files():
        if rel not in merged:
            merged.append(rel)
    return merged


def _discover_source_files() -> list:
    """
    F-3：自动发现 core/ 与 gui/ 下所有源码文件，避免新增模块（如 R21 的
    template_versions.py、batch_runner.py，及 R22 的 template_dedup.py）漏登。
    与显式 SOURCE_FILES 取并集——显式保证顺序稳定，自动发现保证不漏。
    """
    found = []
    import glob
    for pat in ("core", "gui"):
        for p in sorted(glob.glob(os.path.join(PROJECT_ROOT, pat, "**", "*.py"), recursive=True)):
            rel = os.path.relpath(p, PROJECT_ROOT)
            if "__pycache__" in rel.split(os.sep):
                continue
            found.append(rel)
    return found


def _dedupe(items: list) -> list:
    """
    去重保序。

    显式清单与自动发现可能重叠（例如新增测试文件同时被显式登记，
    又被 glob 发现），若不去重会导致 CONTROLLED 长度与实际清单项数不等，
    使"项数 == 受控清单长度"的断言误报。
    """
    seen = set()
    out = []
    for it in items:
        if it in seen:
            continue
        seen.add(it)
        out.append(it)
    return out


CONTROLLED = _dedupe(SOURCE_FILES + _merge_test_files() + _discover_source_files()
                     + FIXTURE_FILES + TOOL_FILES + EVIDENCE_FILES)

PYTHON = sys.executable


def _guard_write(path: str):
    """
    写入前守卫：白名单为主，黑名单为辅。

    A-19：原实现只用 FORBIDDEN_ROOTS 黑名单，只能拦住明确列出的卷。
    若将来出现新的只读挂载点、或路径经符号链接/相对路径绕过，
    黑名单就会漏判。改为「必须位于项目根目录内」的白名单判定，
    默认拒绝一切项目外写入，安全性由"白名单"而非"穷举黑名单"保证。
    """
    resolved = os.path.realpath(os.path.abspath(path))
    root = os.path.realpath(os.path.abspath(PROJECT_ROOT))

    # 辅：显式黑名单（防御性冗余，即使路径计算异常也能兜住）
    for forbidden in FORBIDDEN_ROOTS:
        if resolved.startswith(os.path.realpath(os.path.abspath(forbidden))):
            raise SystemExit(f"拒绝写入只读卷: {resolved}")

    # 主：白名单——必须落在项目根目录内
    if resolved != root and not resolved.startswith(root + os.sep):
        raise SystemExit(
            f"拒绝写入项目根目录之外的路径: {resolved}\n"
            f"（本项目只允许写入 {root} 之内，白名单策略）"
        )


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _module_type(rel: str) -> str:
    """F-3：按路径前缀标注模块类型，便于分区核对受控清单。"""
    top = rel.split(os.sep)[0]
    if top in ("core", "gui", "tests", "tools"):
        return top
    if top == "docs":
        return "doc"
    if top in ("assets", "build_staging") or rel.startswith("tests" + os.sep + "data" + os.sep):
        return "asset"
    return "other"


def build_inventory(phase: str) -> dict:
    files = {}
    missing = []
    for rel in CONTROLLED:
        p = os.path.join(PROJECT_ROOT, rel)
        if os.path.exists(p):
            files[rel] = {
                "sha256": sha256_of(p),
                "size": os.path.getsize(p),
                "module_type": _module_type(rel),
            }
        else:
            files[rel] = {
                "sha256": None,
                "size": None,
                "module_type": _module_type(rel),
                "error": "MISSING",
            }
            missing.append(rel)
    inv = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "root": PROJECT_ROOT,
        "phase": phase,
        "canonical_path": PROJECT_ROOT,
        "note": "单卷权威路径；不声称跨卷一致",
        "count": len(files),
        "missing": missing,
        "files": files,
    }
    return inv


def find_previous_inventory(tag: str):
    """找出本项目 docs/ 下最近一份 audit_inventory，排除本次 tag"""
    cands = []
    for name in os.listdir(DOCS_DIR):
        if not (name.startswith("audit_inventory_") and name.endswith(".json")):
            continue
        if tag and tag in name:
            continue
        p = os.path.join(DOCS_DIR, name)
        cands.append((os.path.getmtime(p), p))
    if not cands:
        return None
    return max(cands)[1]


def diff_inventories(old_path: str, new_inv: dict) -> dict:
    with open(old_path, encoding="utf-8") as f:
        old = json.load(f)
    old_files = old.get("files", {})
    new_files = new_inv.get("files", {})

    changed, added, removed, same = [], [], [], 0
    for rel, meta in new_files.items():
        if rel not in old_files:
            added.append(rel)
        elif old_files[rel].get("sha256") != meta.get("sha256"):
            changed.append(rel)
        else:
            same += 1
    for rel in old_files:
        if rel not in new_files:
            removed.append(rel)

    return {
        "baseline": os.path.basename(old_path),
        "same": same,
        "changed": changed,
        "added": added,
        "removed": removed,
    }


def run_pytest(no_appkit: bool, tag: str) -> dict:
    """
    跑测试并记录真实退出码。

    no_appkit=True 时用 import 拦截模拟无 AppKit 环境。
    退出码直接取 subprocess.returncode，绝不经 tee / 管道。
    """
    env = dict(os.environ)
    env["QT_QPA_PLATFORM"] = "offscreen"

    if no_appkit:
        # 通过 -c 注入拦截器后再启动 pytest，保证 pytest 自身退出码可被捕获
        runner = (
            "import builtins,sys\n"
            "_r=builtins.__import__\n"
            "def _f(n,*a,**k):\n"
            "    if n=='AppKit' or n.startswith('AppKit.'): raise ImportError('simulated no-AppKit')\n"
            "    return _r(n,*a,**k)\n"
            "builtins.__import__=_f\n"
            "import pytest\n"
            "sys.exit(pytest.main(['tests/','-rs','--no-header','-v']))\n"
        )
        cmd = [PYTHON, "-c", runner]
    else:
        cmd = [PYTHON, "-m", "pytest", "tests/", "-v"]

    started = time.time()
    proc = subprocess.run(cmd, cwd=PROJECT_ROOT, env=env,
                          capture_output=True, text=True)
    elapsed = time.time() - started

    suffix = "no_appkit" if no_appkit else "macos"
    log_path = os.path.join(DOCS_DIR, f"pytest_{tag}_{suffix}.log")
    _guard_write(log_path)

    header = [
        f"=== FCPX Studio Pro 测试复跑（{suffix}）===",
        f"GENERATED_AT={time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"CMD={' '.join(cmd)}",
        f"CWD={PROJECT_ROOT}",
        f"METHOD={'builtins.__import__ 拦截 AppKit' if no_appkit else '原生 macOS'}"
        ,
        "---",
    ]
    with open(log_path, "w", encoding="utf-8") as f:
        f.write("\n".join(header) + "\n")
        f.write(proc.stdout)
        if proc.stderr:
            f.write("\n--- STDERR ---\n" + proc.stderr)
        f.write(f"\nPYTEST_EXIT_CODE={proc.returncode}\n")

    tail = [l for l in proc.stdout.strip().splitlines() if l.strip()]
    summary = tail[-1] if tail else "(无输出)"

    return {
        "env": suffix,
        "exit_code": proc.returncode,          # 直接取进程返回码
        "summary": summary,
        "elapsed_sec": round(elapsed, 1),
        "log": os.path.relpath(log_path, PROJECT_ROOT),
    }


def cmd_inventory(args) -> int:
    tag = args.tag or "round"
    inv = build_inventory(tag)
    out = os.path.join(DOCS_DIR, f"audit_inventory_{tag}.json")
    _guard_write(out)

    # R24 #6：防止复核方重跑覆盖上一轮原件。
    # ① 写出前若同名文件已存在，先原地备份为 .bak（仅保留最近一份）；
    # ② 额外写一份带时间戳的副本，双保险。
    # R26：日志前缀由硬编码 [R24#6] 改为动态读 tag（SA-4 复查问题 6）。
    if os.path.exists(out):
        bak = out + ".bak"
        if os.path.exists(bak):
            os.remove(bak)
        os.replace(out, bak)
        print(f"[{tag}] 已备份上一轮清单 -> {os.path.relpath(bak, PROJECT_ROOT)}")
    ts = time.strftime("%Y%m%d_%H%M%S")
    ts_out = os.path.join(DOCS_DIR, f"audit_inventory_{tag}_{ts}.json")
    _guard_write(ts_out)
    with open(ts_out, "w", encoding="utf-8") as f:
        json.dump(inv, f, indent=2, ensure_ascii=False)
    print(f"[{tag}] 已写时间戳副本 -> {os.path.relpath(ts_out, PROJECT_ROOT)}")

    with open(out, "w", encoding="utf-8") as f:
        json.dump(inv, f, indent=2, ensure_ascii=False)

    print(f"指纹清单: {os.path.relpath(out, PROJECT_ROOT)}  ({inv['count']} 项)")
    if inv["missing"]:
        print(f"缺失文件 {len(inv['missing'])}: {inv['missing']}")

    prev = find_previous_inventory(tag)
    if prev:
        d = diff_inventories(prev, inv)
        print(f"对比基线 {d['baseline']}: 相同 {d['same']} / "
              f"改动 {len(d['changed'])} / 新增 {len(d['added'])} / 移除 {len(d['removed'])}")
        for rel in d["changed"]:
            print(f"  改动 {rel}")
        for rel in d["added"]:
            print(f"  新增 {rel}")
        for rel in d["removed"]:
            print(f"  移除 {rel}")
    return 0


def cmd_verify(args) -> int:
    tag = args.tag or "round"
    results = []
    for no_appkit in (False, True):
        r = run_pytest(no_appkit, tag)
        results.append(r)
        print(f"[{r['env']:10}] exit={r['exit_code']}  {r['summary']}")
        print(f"            log={r['log']}")

    rc = 0 if all(r["exit_code"] == 0 for r in results) else 1
    print(f"\n综合退出码: {rc}")
    return rc


def cmd_all(args) -> int:
    rc1 = cmd_inventory(args)
    print()
    rc2 = cmd_verify(args)
    return max(rc1, rc2)


def cmd_diff(args) -> int:
    if not os.path.isfile(args.old):
        print(f"找不到旧清单: {args.old}", file=sys.stderr)
        return 2
    new_inv = build_inventory("diff")
    d = diff_inventories(args.old, new_inv)
    print(f"基线: {d['baseline']}")
    print(f"相同 {d['same']} / 改动 {len(d['changed'])} / "
          f"新增 {len(d['added'])} / 移除 {len(d['removed'])}")
    for rel in d["changed"]:
        print(f"  改动 {rel}")
    for rel in d["added"]:
        print(f"  新增 {rel}")
    for rel in d["removed"]:
        print(f"  移除 {rel}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="FCPX Studio Pro 审核轮次自动化")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name, fn, help_text in (
        ("inventory", cmd_inventory, "生成指纹清单并对比上一轮"),
        ("verify", cmd_verify, "双环境跑测试并记录真实退出码"),
        ("all", cmd_all, "指纹 + 双环境测试（一条命令完成一轮准备）"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--tag", default="round", help="本轮标记，用于命名产物")
        p.set_defaults(func=fn)

    p_diff = sub.add_parser("diff", help="对比两份指纹清单")
    p_diff.add_argument("old", help="旧清单路径")
    p_diff.set_defaults(func=cmd_diff)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
