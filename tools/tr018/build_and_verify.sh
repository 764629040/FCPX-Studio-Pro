#!/bin/zsh
# ═══════════════════════════════════════════════════════════════════════════
# TR-018 一键复现：从「完整 scipy 的 python_bundle」重建 slim 包并跑禁降级验收。
#
# 用法:
#   tools/tr018/build_and_verify.sh <full_python_bundle> <work_dir>
#
# 例:
#   tools/tr018/build_and_verify.sh \
#     "/tmp/tr018/full/python_bundle" "/tmp/tr018/reproduce"
#
# 前置:
#   * <full_python_bundle> 必须是裁剪前的完整运行包（含 bin/python3 与 site-packages/scipy）
#   * 项目 tests/data/*.psd 存在（render_layers_sha.py 的 PSD 样本集）
#   * 基线 reports/verify_tr018/sha_full_layers.json、num_full.json 已随仓库提交
#
# 产物（全部落在 <work_dir>）:
#   slim/python_bundle/            重建出的裁剪包
#   sha_app.json / png_app/        裁剪后逐层 PNG sha256
#   num_app.json                   裁剪后数值输出
#   RESULT.txt                     验收结论
#
# 不做的事: 不碰 .app、不重签、不改仓库源文件、不 push。
# ═══════════════════════════════════════════════════════════════════════════
set -eu

HERE=${0:A:h}
ROOT=${HERE:h:h}
FULL_BUNDLE="$1"
WORK="$2"
[ -x "$FULL_BUNDLE/bin/python3" ] || { echo "FATAL: 不是完整 python_bundle: $FULL_BUNDLE" >&2; exit 2; }

FULL_PY="$FULL_BUNDLE/bin/python3"
FULL_SCIPY="$FULL_BUNDLE/lib/python3.14/site-packages/scipy"
SLIM_BUNDLE="$WORK/slim/python_bundle"
SLIM_PY="$SLIM_BUNDLE/bin/python3"
SLIM_SCIPY="$SLIM_BUNDLE/lib/python3.14/site-packages/scipy"
BASE_SHA="$ROOT/reports/verify_tr018/sha_full_layers.json"
BASE_NUM="$ROOT/reports/verify_tr018/num_full.json"

mkdir -p "$WORK/slim"
rm -rf "$SLIM_BUNDLE"
echo "=== 1. 复制完整包 -> slim ==="
cp -a "$FULL_BUNDLE" "$SLIM_BUNDLE"

echo "=== 2. 只留 ndimage / interpolate / _lib / .dylibs ==="
zsh "$HERE/slim_scipy.sh" "$SLIM_SCIPY"

echo "=== 3. 保留区打补丁（lazy import + 真实等价实现） ==="
"$FULL_PY" "$HERE/patch_slim.py" "$SLIM_SCIPY"

echo "=== 4. 注入真实 Cython 编译扩展别名 ==="
TR018_FULL_SCIPY="$FULL_SCIPY" "$FULL_PY" "$HERE/alias_capi.py" "$SLIM_SCIPY"

echo "=== 5. 逐层 PNG sha256（项目真实渲染入口） ==="
# core/ 只用来提供 psd_layer_fallback，解释器决定加载哪份 scipy。
# 优先用运行包自带的 core；没有则回退到仓库 core/。
if [ -d "$ROOT/FCPX Studio Pro R2.app/Contents/Resources/core" ]; then
  RES_DIR="$ROOT/FCPX Studio Pro R2.app/Contents/Resources"
else
  # 仓库根自带 core/，sys.path 必须直接指向根才能 `import core`
  RES_DIR="$ROOT"
fi
TR018_PROJECT_ROOT="$ROOT" "$SLIM_PY" "$HERE/render_layers_sha.py" \
  "$RES_DIR" "$WORK/png_app" "$WORK/sha_app.json"

echo "=== 6. 数值等价 ==="
"$SLIM_PY" "$HERE/numeric_equiv.py" > "$WORK/num_app.json"

echo "=== 7. 比对与结论 ==="
"$FULL_PY" - "$BASE_SHA" "$WORK/sha_app.json" "$BASE_NUM" "$WORK/num_app.json" "$WORK/png_app" "$FULL_BUNDLE" "$SLIM_BUNDLE" <<'PY' | tee "$WORK/RESULT.txt"
import json, glob, os, sys
base_sha, app_sha, base_num, app_num, png_dir, full_b, slim_b = sys.argv[1:]
A, B = json.load(open(base_sha)), json.load(open(app_sha))
assert A.keys() == B.keys(), "PSD 集合不一致"
diffs = []; total = 0; styled = 0; methods = {}
for psd in sorted(A):
    assert len(A[psd]) == len(B[psd]), (psd, "层数不一致")
    for i, (x, y) in enumerate(zip(A[psd], B[psd])):
        total += 1
        methods[y.get("render_method")] = methods.get(y.get("render_method"), 0) + 1
        if x.get("styles", {}).get("has_styles"): styled += 1
        for k in ("idx","name","kind","visible","styles","ok","render_method",
                  "error","sha256","nbytes","exception"):
            if x.get(k) != y.get(k): diffs.append((psd, i, k, x.get(k), y.get(k)))
print("LAYERS", total, "DIFF", len(diffs), "STYLED", styled, "METHODS", methods)
for d in diffs[:10]: print("  DIFF", d)

def flat(x, p=""):
    if isinstance(x, dict):
        r = []
        for k, v in x.items(): r += flat(v, p + "." + k)
        return r
    if isinstance(x, list):
        r = []
        for i, v in enumerate(x): r += flat(v, p + "[%d]" % i)
        return r
    return [(p, x)]
a, b = flat(json.load(open(base_num))), flat(json.load(open(app_num)))
nd = [(k, x, y) for (k, x), (_, y) in zip(a, b) if x != y]
print("NUM_SCALARS", len(a), len(b), "NUM_DIFF", len(nd))
byte_same = open(base_num, "rb").read() == open(app_num, "rb").read()
print("BYTE_IDENTICAL:", "YES" if byte_same and not nd else "NO")

def du(p):
    return sum(os.path.getsize(os.path.join(r, f))
               for r, _, fs in os.walk(p) for f in fs) / 1024 / 1024
full_mb, slim_mb = du(full_b), du(slim_b)
print("SIZE_MB full=%.1f slim=%.1f" % (full_mb, slim_mb))
ok = (not diffs and not nd and byte_same and slim_mb <= 100
      and set(methods) == {"psd_composite"} and len(glob.glob(png_dir + "/*")) == total)
print("VERDICT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
echo "=== DONE: $WORK/RESULT.txt ==="
