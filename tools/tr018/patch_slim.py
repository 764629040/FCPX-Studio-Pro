#!/usr/bin/env python3
"""TR-018: 让「只留 ndimage/interpolate/_lib」的 scipy 仍真实渲染（禁降级）。

背景：psd_tools.composite._compat 用 `from scipy import interpolate` 判 HAS_SCIPY，
而 scipy 1.16.3 的 interpolate/__init__.py 是全量 eager import，连锁需要
linalg/sparse/special/optimize/spatial（已删）。纯删子包 → HAS_SCIPY=False →
描边/投影在 effects.py 抛 ImportError → 掉到 PIL 回退 → PNG sha 变化（降级）。

补丁原则：
  * 不新增子包目录、不塞返回假值的 stub；
  * 只改被保留的三个子包内部 + 顶层 __init__.py；
  * 每处替换带精确断言，源码版本不符直接失败，绝不静默；
  * 完整 scipy 下走原 import（数值逐位不变），裁剪包下按需加载或给出真实等价实现；
  * 确实依赖已删子包的 API，在访问时抛明确 ImportError（诚实失败，不静默降级）。

用法: patch_slim.py <scipy_dir>
"""
import os, sys, json

SP = sys.argv[1]
assert os.path.isfile(os.path.join(SP, "ndimage", "__init__.py")), "不是 scipy 目录"


def patch(rel, old, new, count=1):
    p = os.path.join(SP, rel)
    s = open(p, encoding="utf-8").read()
    n = s.count(old)
    assert n == count, f"{rel}: 期望 {count} 处匹配，实际 {n} 处 —— 源码版本不符，停止"
    open(p, "w", encoding="utf-8").write(s.replace(old, new))
    print(f"  PATCH {rel}  x{n}")


# ── 1. scipy 顶层：submodules 收敛为实际保留的子包 ──────────────────────
# 不改 __getattr__ 逻辑；访问已删子包名时仍由 import_module 抛 ImportError。
patch("__init__.py", """submodules = [
    'cluster',
    'constants',
    'datasets',
    'differentiate',
    'fft',
    'fftpack',
    'integrate',
    'interpolate',
    'io',
    'linalg',
    'ndimage',
    'odr',
    'optimize',
    'signal',
    'sparse',
    'spatial',
    'special',
    'stats'
]""", """# TR-018 slim: 只打包 ndimage / interpolate / _lib，其余子包已删除。
# 保留两个名字，__getattr__ 仍可用 import_module 加载它们。
submodules = [
    'interpolate',
    'ndimage',
]""")

# ── 2. ndimage/_interpolation.py: 顶层 `from scipy import special` ────────
# special 仅在 rotate() 用于 cosdg/sindg；改成函数内按需加载 + math 等价兜底。
patch("ndimage/_interpolation.py", "from scipy import special\n", "")
patch("ndimage/_interpolation.py", "    c, s = special.cosdg(angle), special.sindg(angle)\n",
      """    # TR-018 slim: scipy.special 未随包分发。完整 scipy 下仍走 cosdg/sindg
    # （数值逐位一致）；裁剪包下用 math 等价实现，rotate 依然可用。
    try:
        from scipy import special as _special
        c, s = _special.cosdg(angle), _special.sindg(angle)
    except ImportError:
        import math as _math
        c, s = _math.cos(_math.radians(angle)), _math.sin(_math.radians(angle))
""")

# ── 3. interpolate/__init__.py: eager → PEP 562 lazy 命名空间 ────────────
symbols = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "interpolate_symbols.json"), encoding="utf-8"))
NAMESPACES = {
    "fitpack": "scipy.interpolate.fitpack",
    "fitpack2": "scipy.interpolate.fitpack2",
    "interpolate": "scipy.interpolate.interpolate",
    "ndgriddata": "scipy.interpolate.ndgriddata",
    "polyint": "scipy.interpolate.polyint",
    "rbf": "scipy.interpolate.rbf",
    "interpnd": "scipy.interpolate.interpnd",
    "pade": "scipy.interpolate._pade",
    "interpnd_module": None,
}
# builtins/别名单独处理，不放进符号表
sym_map = {k: v for k, v in symbols.items()
           if v.startswith("scipy.") and k not in NAMESPACES and k != "pchip"}
sym_lines = "\n".join(f"    {json.dumps(k)}: {json.dumps(v)}," for k, v in sorted(sym_map.items()))
ns_lines = "\n".join(f"    {json.dumps(k)}: {json.dumps(v)}," for k, v in sorted(NAMESPACES.items()) if v)
lazy_init = '''"""TR-018 slim build — lazy namespace for ``scipy.interpolate``.

原版 ``__init__.py`` 是 eager import：一句 ``from scipy import interpolate``
会连锁加载 linalg / sparse / special / optimize / spatial 等子包。本裁剪包
只保留 ndimage / interpolate / _lib，故改为 PEP 562 lazy：

* 模块对象本身零重型依赖，``from scipy import interpolate`` 立即成功，
  psd_tools.composite._compat.HAS_SCIPY 保持 True，描边/投影/发光不降级；
* 具体符号在被访问时才从对应私有模块加载，加载到的都是 scipy 真实实现；
* 若某符号的实现确实依赖已删子包，仅在访问该符号时抛 ImportError
  （诚实失败，绝不静默降级、也不返回占位值）。
"""
import importlib as _il

_SYMBOL_MODULE = {
%s
}

_DEPRECATED_NAMESPACES = {
%s
}

__all__ = sorted(set(_SYMBOL_MODULE) | set(_DEPRECATED_NAMESPACES) | {"pchip", "test"})


def __getattr__(name):
    mod_name = _SYMBOL_MODULE.get(name)
    if mod_name is not None:
        value = getattr(_il.import_module(mod_name), name)
        globals()[name] = value
        return value
    if name in _DEPRECATED_NAMESPACES:
        mod = _il.import_module(_DEPRECATED_NAMESPACES[name])
        globals()[name] = mod
        return mod
    if name == "pchip":
        return __getattr__("PchipInterpolator")
    if name == "test":
        from scipy._lib._testutils import PytestTester
        value = PytestTester(__name__)
        globals()[name] = value
        return value
    raise AttributeError(f"module 'scipy.interpolate' has no attribute {name!r}")


def __dir__():
    return sorted(__all__)
''' % (sym_lines, ns_lines)
open(os.path.join(SP, "interpolate", "__init__.py"), "w", encoding="utf-8").write(lazy_init)
print("  WRITE interpolate/__init__.py (lazy, %d symbols)" % len(sym_map))

# ── 4. interpolate/_interpolate.py: special 顶层依赖 ────────────────────
# interp1d（渐变填充用）主路径不碰 special；spec.poch/gamma 只在 PPoly/BPoly
# 导数里用。lazy proxy 保持 `spec.*` 调用点不变，comb 用 math.comb 等价兜底。
patch("interpolate/_interpolate.py",
      "import scipy.special as spec\nfrom scipy._lib._util import copy_if_needed\nfrom scipy.special import comb\n",
      """# TR-018 slim: scipy.special 已裁掉。完整 scipy 下走原 import（数值不变）；
# 裁剪包下用 lazy proxy，`spec.*` 仅在实际访问时解析。
try:
    import scipy.special as spec
    from scipy.special import comb
except ImportError:
    class _LazySpecial:
        def __getattr__(self, item):
            from scipy import special
            return getattr(special, item)
    spec = _LazySpecial()
    from math import comb  # 整数参数下与 scipy.special.comb 等价
from scipy._lib._util import copy_if_needed
""")

# ── 5. interpolate/_polyint.py: factorial ───────────────────────────────
patch("interpolate/_polyint.py", "from scipy.special import factorial\n",
      """try:
    from scipy.special import factorial
except ImportError:
    from math import factorial  # TR-018 slim: 整数阶乘，数值等价
""")

# ── 6. interpolate/_bsplines.py: 顶层跨包 import ────────────────────────
# interp1d 加载时会 `from ._bsplines import ...`，故本模块必须可导入。
# linalg/optimize/sparse 的函数只在 make_lsq_spline / make_smoothing_spline
# 里用（psd_tools 不走）；失败时保留 LinAlgError 为真实异常类，其余给出
# 调用即抛 ImportError 的诚实占位。poch 用 math.gamma 等价实现。
patch("interpolate/_bsplines.py",
      """from scipy.linalg import (get_lapack_funcs, LinAlgError,
                          cholesky_banded, cho_solve_banded,
                          solve, solve_banded)
from scipy.optimize import minimize_scalar
from . import _dierckx
from . import _fitpack_impl
from scipy.sparse import csr_array
from scipy.special import poch
""",
      """# TR-018 slim: 顶层跨包依赖改为可降级加载（完整 scipy 下走原 import）。
try:
    from scipy.linalg import (get_lapack_funcs, LinAlgError,
                              cholesky_banded, cho_solve_banded,
                              solve, solve_banded)
except ImportError:
    from numpy.linalg import LinAlgError

    def _tr018_missing(name):
        def _raise(*args, **kwargs):
            raise ImportError(
                "TR-018 slim: scipy.linalg.%s 不可用（linalg 子包未打包）" % name
            )
        return _raise
    get_lapack_funcs = _tr018_missing('get_lapack_funcs')
    cholesky_banded = _tr018_missing('cholesky_banded')
    cho_solve_banded = _tr018_missing('cho_solve_banded')
    solve = _tr018_missing('solve')
    solve_banded = _tr018_missing('solve_banded')
try:
    from scipy.optimize import minimize_scalar
except ImportError:
    def minimize_scalar(*args, **kwargs):
        raise ImportError("TR-018 slim: scipy.optimize 未打包")
from . import _dierckx
from . import _fitpack_impl
try:
    from scipy.sparse import csr_array
except ImportError:
    def csr_array(*args, **kwargs):
        raise ImportError("TR-018 slim: scipy.sparse 未打包")
try:
    from scipy.special import poch
except ImportError:
    import math as _math
    def poch(z, m):
        # Pochhammer 符号 (z)_m = Gamma(z+m)/Gamma(z)，本用例参数为小整数/半整数
        return _math.gamma(z + m) / _math.gamma(z)
""")

# ── 7. interpolate/_cubic.py: linalg.solve/solve_banded ─────────────────
# psd_tools 曲线调整用 CubicSpline(bc_type="natural") → solve_banded((1,1),...)。
# 用 numpy 的 Thomas 算法等价实现（对角占优三对角，LAPACK gbsv 同解），
# 使 CubicSpline 在裁剪包下仍真实可用而非静默降级。
patch("interpolate/_cubic.py", "from scipy.linalg import solve, solve_banded\n",
      """try:
    from scipy.linalg import solve, solve_banded
except ImportError:
    # TR-018 slim: 用 numpy 提供 solve / solve_banded((1,1),...) 的真实等价实现。
    import numpy as _np

    def solve(a, b, **kwargs):
        return _np.linalg.solve(_np.asarray(a), _np.asarray(b))

    def solve_banded(l_and_u, ab, b, **kwargs):
        # (1,1) 带状：与 LAPACK gbsv 相同的消元顺序（对角占优三对角无主元交换）。
        # 保留输入 dtype（自然三次样条为 float32 → LAPACK sgbsv），否则精度不等价。
        if tuple(l_and_u) != (1, 1):
            raise ImportError("TR-018 slim: 仅支持 (1,1) 带状求解")
        ab = _np.asarray(ab)
        b = _np.asarray(b)
        out = _np.array(b, dtype=_np.result_type(ab, b, _np.float32), copy=True)
        diag = _np.array(ab[1, :], dtype=out.dtype, copy=True)
        upper = _np.array(ab[0, 1:], dtype=out.dtype, copy=True)  # a[i, i+1]
        lower = _np.array(ab[2, :-1], dtype=out.dtype, copy=True)  # a[i+1, i]
        n = out.shape[0]
        for i in range(1, n):
            w = lower[i - 1] / diag[i - 1]
            diag[i] -= w * upper[i - 1]
            out[i] -= w * out[i - 1]
        x = _np.empty_like(out)
        x[-1] = out[-1] / diag[-1]
        for i in range(n - 2, -1, -1):
            x[i] = (out[i] - upper[i] * x[i + 1]) / diag[i]
        return x
""")

# ── 8. interpolate/_rgi.py: sparse.linalg (仅 method='slinear' 分支用) ──
patch("interpolate/_rgi.py", "import scipy.sparse.linalg as ssl\n",
      """try:
    import scipy.sparse.linalg as ssl
except ImportError:
    # TR-018 slim: _ndbspline.py 在模块加载时求值 `solver=ssl.gcrotmk`，
    # 故占位对象需提供 gcrotmk 属性；真正调用（仅 spline 类方法）时抛明确错。
    class _MissingSSL:
        @staticmethod
        def gcrotmk(*args, **kwargs):
            raise ImportError("TR-018 slim: scipy.sparse.linalg 未打包")
    ssl = _MissingSSL()
""")

# ── 9. interpolate/_pade.py: scipy.linalg ───────────────────────────────
patch("interpolate/_pade.py", "from scipy import linalg\n",
      """try:
    from scipy import linalg
except ImportError:
    linalg = None  # TR-018 slim: 访问属性时诚实报错
""")

# ── 10. 其余私有模块顶层跨包 import（rbf / rbfinterp / ndgriddata / ndbspline）
patch("interpolate/_rbf.py",
      "from scipy import linalg\nfrom scipy.special import xlogy\nfrom scipy.spatial.distance import cdist, pdist, squareform\n",
      """try:
    from scipy import linalg
    from scipy.special import xlogy
    from scipy.spatial.distance import cdist, pdist, squareform
except ImportError:
    linalg = xlogy = cdist = pdist = squareform = None  # TR-018 slim
""")
patch("interpolate/_rbfinterp.py",
      "from scipy.spatial import KDTree\nfrom scipy.special import comb\nfrom scipy.linalg.lapack import dgesv  # type: ignore[attr-defined]\n",
      """try:
    from scipy.spatial import KDTree
    from scipy.special import comb
    from scipy.linalg.lapack import dgesv  # type: ignore[attr-defined]
except ImportError:
    from math import comb
    KDTree = None
    dgesv = None  # TR-018 slim
""")
patch("interpolate/_ndgriddata.py", "from scipy.spatial import cKDTree\n",
      """try:
    from scipy.spatial import cKDTree
except ImportError:
    cKDTree = None  # TR-018 slim
""")
patch("interpolate/_ndbspline.py",
      "import scipy.sparse.linalg as ssl\nfrom scipy.sparse import csr_array\n",
      """try:
    import scipy.sparse.linalg as ssl
    from scipy.sparse import csr_array
except ImportError:
    # TR-018 slim: 本文件 L325 有 `def _iter_solve(..., solver=ssl.gcrotmk)`，
    # 默认参数在模块加载时求值，占位对象必须提供 gcrotmk 属性。
    class _MissingSSL:
        @staticmethod
        def gcrotmk(*args, **kwargs):
            raise ImportError("TR-018 slim: scipy.sparse.linalg 未打包")
    ssl = _MissingSSL()
    def csr_array(*args, **kwargs):
        raise ImportError("TR-018 slim: scipy.sparse 未打包")
""")

# deprecated 命名空间模块（.py 薄封装）：顶层若 import 已删子包则同样兜底
for fn in ("fitpack.py", "fitpack2.py", "interpolate.py", "ndgriddata.py",
           "polyint.py", "rbf.py", "interpnd.py"):
    p = os.path.join(SP, "interpolate", fn)
    if not os.path.isfile(p):
        continue
    s = open(p, encoding="utf-8").read()
    if not any(x in s for x in ("from scipy import linalg", "from scipy.linalg",
                                "from scipy.special", "from scipy.spatial",
                                "from scipy.optimize", "from scipy.sparse")):
        continue
    print("  NOTE  %s 含顶层跨包 import（lazy 命名空间下按需加载，未改）" % fn)

print("TR-018 PATCH OK ->", SP)
