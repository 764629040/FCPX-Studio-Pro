#!/bin/zsh
# ═══════════════════════════════════════════════════════════════════════════
# TR-021 验收：文本核对 + 不新增 stub 扫描。
#
# 用法: tools/tr021/verify_tr021.sh [rebuild_scipy_dir]
#   默认 rebuild_scipy_dir = /tmp/tr018/reproduce_tr021/slim/.../site-packages/scipy
#   （由 tools/tr018/build_and_verify.sh 重建；不存在则 S8 记 NOTE，不判 FAIL）
#
# 输出: reports/verify_tr021/验收脚本输出.txt，末行 TR-021 VERDICT
# 只读，不修改 .app / 不重签 / 不写回。
# ═══════════════════════════════════════════════════════════════════════════
set -eu
set -o pipefail

HERE=${0:A:h}
ROOT=${HERE:h:h}
APP="$ROOT/FCPX Studio Pro R2.app"
SCIPY="$APP/Contents/Resources/python_bundle/lib/python3.14/site-packages/scipy"
APP_PY="$APP/Contents/Resources/python_bundle/bin/python3"
OUT="$ROOT/reports/verify_tr021"
REBUILD=${1:-/tmp/tr018/reproduce_tr021/slim/python_bundle/lib/python3.14/site-packages/scipy}

[ -x "$APP_PY" ] || { echo "FATAL: 落地包 python3 不可用: $APP_PY" >&2; exit 2; }
mkdir -p "$OUT"

python3 - "$ROOT" "$SCIPY" "$APP_PY" "$REBUILD" <<'PY' 2>&1 | tee "$OUT/验收脚本输出.txt"
import os, re, sys, json, subprocess

ROOT, SCIPY, APP_PY, REBUILD = sys.argv[1:5]
ANCHOR = "已知差异：rotate 路径 1 ULP"
DELETED = ["cluster","constants","datasets","differentiate","fft","fftpack",
           "integrate","io","linalg","misc","odr","optimize","signal","sparse",
           "spatial","special","stats"]
checks = []

def chk(name, cond, detail=""):
    ok = bool(cond)
    checks.append((name, ok))
    print(("PASS  " if ok else "FAIL  ") + name + (("   | " + detail) if detail else ""))

def read(p):
    try:
        return open(p, encoding="utf-8").read()
    except Exception as e:
        return "<<READ_ERROR %s>>" % e

# ── 一、文本核对 ──────────────────────────────────────────────────────────
print("=== 一、文本核对（锚点：%s） ===" % ANCHOR)
paths = {
    "T1 主裁剪说明 docs/TR-018_scipy_裁剪说明.md":  os.path.join(ROOT, "docs/TR-018_scipy_裁剪说明.md"),
    "T3 patch_slim.py":                              os.path.join(ROOT, "tools/tr018/patch_slim.py"),
    "T4 落地包 ndimage/_interpolation.py":          os.path.join(SCIPY, "ndimage/_interpolation.py"),
    "T5 TR-018 验收记录":                            os.path.join(ROOT, "reports/verify_tr018/验收记录.txt"),
    "T6 台账 docs/待办清单_20261110.md":             os.path.join(ROOT, "docs/待办清单_20261110.md"),
    "T7 TR-021 验收记录":                            os.path.join(ROOT, "reports/verify_tr021/验收记录.txt"),
}
for name, p in paths.items():
    chk(name, ANCHOR in read(p), "未命中锚点" if ANCHOR not in read(p) else "已命中")

doc = read(paths["T1 主裁剪说明 docs/TR-018_scipy_裁剪说明.md"])
chk("T2 主文档记录 90° 结构性差异（2752 像素 / 结构性差异）",
    "2752" in doc and "结构性差异" in doc and "affine_transform" in doc)
chk("T8 主文档写明「不新增 stub」与处置路径", "不新增 stub" in doc and "alias_capi.py" in doc)

diff_ev = os.path.join(ROOT, "reports/verify_tr021/运行时代码差异核对.txt")
chk("T9 运行时代码差异证据 RUNTIME_CODE_ADDED: 0",
    "RUNTIME_CODE_ADDED: 0" in read(diff_ev))

# ── 二、不新增 stub 扫描（静态） ──────────────────────────────────────────
print("\n=== 二、不新增 stub 扫描（目录 / 源码 / 脚本） ===")
dirs = sorted(d for d in os.listdir(SCIPY) if os.path.isdir(os.path.join(SCIPY, d)))
chk("S1 落地包 scipy 子目录集合正确", dirs == [".dylibs", "_lib", "interpolate", "ndimage"], str(dirs))
left = [d for d in DELETED if os.path.exists(os.path.join(SCIPY, d))]
chk("S2 17 个已删子包目录均不存在", not left, "残留: %s" % left)
special_hits = [n for n in os.listdir(SCIPY) if "special" in n.lower() or "stub" in n.lower()]
chk("S3 无 special*/stub* 目录或文件", not special_hits, str(special_hits))

fake_def, cosdg_files = [], []
for r, _, fs in os.walk(SCIPY):
    for fn in fs:
        if not fn.endswith(".py"):
            continue
        p = os.path.join(r, fn)
        s = read(p)
        if re.search(r"^\s*def\s+(cosdg|sindg)\b", s, re.M) or \
           re.search(r"^\s*(cosdg|sindg)\s*=", s, re.M):
            fake_def.append(os.path.relpath(p, SCIPY))
        if "cosdg" in s or "sindg" in s:
            cosdg_files.append(os.path.relpath(p, SCIPY))
chk("S4 包内无 cosdg/sindg 假实现定义", not fake_def, str(fake_def))
chk("S4b cosdg/sindg 仅作为引用出现在 ndimage/_interpolation.py",
    cosdg_files == ["ndimage/_interpolation.py"] or
    all(x == "ndimage/_interpolation.py" for x in cosdg_files), str(cosdg_files))

alias = read(os.path.join(ROOT, "tools/tr018/alias_capi.py"))
chk("S5 alias_capi.py 的别名注册不含 special/cosdg/sindg",
    "scipy.special" not in alias and "cosdg" not in alias and "sindg" not in alias)
patch = read(os.path.join(ROOT, "tools/tr018/patch_slim.py"))
chk("S5b patch_slim.py 未新增 special 模块/假 ufunc",
    "ModuleType" not in patch and "def cosdg" not in patch)

# ── 三、不新增 stub 扫描（落地包 runtime） ────────────────────────────────
print("\n=== 三、不新增 stub 扫描（落地包内 Python 运行时） ===")
CODE = r'''
import json, sys, os
import numpy as np
import scipy
from scipy import ndimage as ndi
r = {}
r["special_keys"] = sorted(k for k in sys.modules if k.startswith("scipy.special"))
try:
    from scipy import special
    r["special_importable"] = True
except ImportError as e:
    r["special_importable"] = False
    r["special_error"] = type(e).__name__
except Exception as e:
    r["special_importable"] = "OTHER:" + type(e).__name__
from psd_tools.composite._compat import HAS_SCIPY
r["HAS_SCIPY"] = bool(HAS_SCIPY)
out = ndi.rotate(np.arange(16, dtype=float).reshape(4,4), 30.0, reshape=False, order=1)
r["rotate_usable"] = bool(out.shape == (4,4) and np.isfinite(out).all())
sp = os.path.dirname(scipy.__file__)
r["scipy_subdirs"] = sorted(d for d in os.listdir(sp) if os.path.isdir(os.path.join(sp,d)))
print("TR021_JSON=" + json.dumps(r))
'''
p = subprocess.run([APP_PY, "-c", CODE], capture_output=True, text=True)
line = [x for x in p.stdout.splitlines() if x.startswith("TR021_JSON=")]
if not line:
    print("  runtime stderr:", p.stderr[:800])
    rt = {}
else:
    rt = json.loads(line[-1].split("TR021_JSON=", 1)[1])
chk("S6 sys.modules 无 scipy.special* 假模块",
    bool(line) and rt.get("special_keys") == [], str(rt.get("special_keys")))
chk("S6b from scipy import special 仍抛 ImportError（无假包）",
    bool(line) and rt.get("special_importable") is False, str(rt.get("special_error")))
chk("S7 HAS_SCIPY 保持 True（未破坏 TR-018）", rt.get("HAS_SCIPY") is True)
chk("S7b ndimage.rotate 在裁剪包下仍可调用", rt.get("rotate_usable") is True)
chk("S7c runtime 报告的子目录集合正确",
    rt.get("scipy_subdirs") == [".dylibs", "_lib", "interpolate", "ndimage"],
    str(rt.get("scipy_subdirs")))

# ── 四、落地包与重建产物一致性 ────────────────────────────────────────────
print("\n=== 四、落地包 vs 一键重建产物（注释同步验证） ===")
if os.path.isdir(REBUILD):
    d = subprocess.run(["diff", "-rq", SCIPY, REBUILD], capture_output=True, text=True)
    chk("S8 落地包 scipy 与重建产物逐字节一致", d.returncode == 0,
        (d.stdout + d.stderr).strip()[:400])
else:
    print("NOTE  S8 跳过：未找到重建产物 %s" % REBUILD)

# ── 汇总 ──────────────────────────────────────────────────────────────────
np_ = sum(1 for _, ok in checks if ok)
nf = len(checks) - np_
print("\nPASS = %d   FAIL = %d" % (np_, nf))
for name, ok in checks:
    if not ok:
        print("  FAILED:", name)
print("TR-021 VERDICT: %s" % ("PASS" if nf == 0 else "FAIL"))
sys.exit(0 if nf == 0 else 1)
PY
