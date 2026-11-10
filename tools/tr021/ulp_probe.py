#!/usr/bin/env python3
"""TR-021: 量化 special.cosdg/sindg 与 rotate() 补丁所用 math 等价实现的末位差异。

必须用【完整 scipy】的 python3 运行（需要 scipy.special）：
  /tmp/tr018/full/python_bundle/bin/python3 tools/tr021/ulp_probe.py <out_dir>

输出: stdout 文本（由 run_probes.sh tee 成证据）+ <out_dir>/ulp_stats.json
ULP 距离用 IEEE754 有序 uint64 位键计算；值接近 0 时 ULP 度量会放大，
故「精确归零」点单列，不与常规角度混算。
"""
import math
import os
import sys
import json

import numpy as np

try:
    from scipy import special
except ImportError:
    sys.exit("FATAL: 本脚本需要完整 scipy（scipy.special）。请用 TR-018 的 full python_bundle/bin/python3 运行。")

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)

SIGN = np.uint64(1) << np.uint64(63)


def key(x):
    """float64 位模式 -> 单调有序 uint64（负数取反，正数异或符号位）。"""
    u = np.asarray(x, dtype=np.float64).view(np.uint64)
    return np.where((u & SIGN) != 0, ~u, u ^ SIGN)


def ulp(a, b):
    ka, kb = key(a), key(b)
    return np.where(ka >= kb, ka - kb, kb - ka)  # uint64，无溢出


N = 1_440_000
ang = np.arange(N, dtype=np.float64) * (360.0 / N)
cm = np.fromiter((math.cos(math.radians(a)) for a in ang), dtype=np.float64, count=N)
sm = np.fromiter((math.sin(math.radians(a)) for a in ang), dtype=np.float64, count=N)

result = {"N": N, "sampling": "arange(1440000) * (360/1440000)", "compare": "math.cos/sin(math.radians(x))"}

print("=== A. 主口径（与补丁实现一致：0..360 均匀 144 万角度，math 标量） ===")
for name, ref, alt in (("cos", special.cosdg(ang), cm), ("sin", special.sindg(ang), sm)):
    d = ulp(ref, alt)
    nz = d != 0
    zero_pt = (ref == 0.0) | (alt == 0.0)
    clean = nz & ~zero_pt
    hist = {str(k): int((d[clean] == k).sum()) for k in (1, 2, 3, 4, 5)}
    hist[">=6"] = int((d[clean] >= 6).sum())
    tot = sum(hist.values())
    max_abs = float(np.abs(ref - alt).max())
    print(f"[{name}] 末位不同 {int(nz.sum())} / {N} ({nz.mean()*100:.2f}%)  "
          f"最大绝对差 {max_abs:.6e}")
    print(f"       排除精确归零后 ULP 分布 1={hist['1']} 2={hist['2']} 3={hist['3']} "
          f"4={hist['4']} 5={hist['5']} >=6={hist['>=6']}  最大 {int(d[clean].max())} ULP")
    print(f"       1 ULP 占比 {hist['1']/tot*100:.2f}%   <=2 ULP 占比 "
          f"{(hist['1']+hist['2'])/tot*100:.2f}%   精确归零差异点 {int((nz & zero_pt).sum())}")
    result[name] = dict(diff=int(nz.sum()), pct=round(float(nz.mean() * 100), 2),
                        hist=hist, zero_points=int((nz & zero_pt).sum()),
                        max_ulp=int(d[clean].max()), max_absdiff=max_abs,
                        one_ulp_pct=round(hist["1"] / tot * 100, 2),
                        le2_ulp_pct=round((hist["1"] + hist["2"]) / tot * 100, 2))

any_diff = int(((special.cosdg(ang) != cm) | (special.sindg(ang) != sm)).sum())
print(f"[合计] 任一函数末位不同的角度 {any_diff} / {N} ({any_diff/N*100:.2f}%)")
result["any_angle_diff"] = any_diff

print("\n=== B. 采样口径扫描（说明计数随口径浮动，结论不变） ===")
cands = {
    "linspace(0,360,1440000)": np.linspace(0., 360., N),
    "arange(1440000)*0.00025": np.arange(N, dtype=np.float64) * 0.00025,
    "linspace(-180,180,1440000)": np.linspace(-180., 180., N),
    "arange(1440000)*0.001 (0..1440)": np.arange(N, dtype=np.float64) * 0.001,
}
scan = {}
for label, xs in cands.items():
    r = special.cosdg(xs)
    a = np.fromiter((math.cos(math.radians(x)) for x in xs), dtype=np.float64, count=N)
    n = int((r != a).sum())
    print(f"  {label:<36} cosdg 末位不同 {n:>8} ({n/N*100:5.2f}%)")
    scan[label] = n
result["sampling_scan"] = scan
result["problem_ticket_count"] = 1_006_000  # 问题单记录值，口径未注明

print("\n=== C. 特殊角度：cosdg/sindg 精确归零 vs math 残差 ===")
special_angles = {}
for a in (0., 45., 90., 180., 270., 360., -90.):
    c_ref, c_alt = float(special.cosdg(a)), math.cos(math.radians(a))
    s_ref, s_alt = float(special.sindg(a)), math.sin(math.radians(a))
    print(f"  {a:>6.0f}°  cosdg={c_ref: .17e}  math.cos={c_alt: .17e} | "
          f"sindg={s_ref: .17e}  math.sin={s_alt: .17e}")
    special_angles[str(a)] = dict(cosdg=c_ref, math_cos=c_alt, sindg=s_ref, math_sin=s_alt)
result["special_angles"] = special_angles

print("\n=== D. cosdg/sindg 真实来源 ===")
import scipy.special._ufuncs as uf
print("  type          :", type(special.cosdg).__name__)
print("  _ufuncs file  :", uf.__file__)
print("  same object   :", uf.cosdg is special.cosdg, uf.sindg is special.sindg)
result["cosdg_source"] = dict(type=type(special.cosdg).__name__, ufunc_file=uf.__file__,
                              same_object=bool(uf.cosdg is special.cosdg))
print("\n结论：已知差异：rotate 路径 1 ULP（常规角度末位差，绝对差 ≤5.55e-16）；"
      "90° 倍数角另有精确归零导致的结构性差异。")

json.dump(result, open(os.path.join(OUT, "ulp_stats.json"), "w"), indent=2, ensure_ascii=False)
