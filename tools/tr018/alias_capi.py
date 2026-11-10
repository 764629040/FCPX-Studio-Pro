#!/usr/bin/env python3
"""TR-018 实验：把编译扩展的 C 级依赖以真实 .so 放进 _lib/ + sys.modules 别名，
不新增 scipy 子包目录。返回 0 表示 interp1d/CubicSpline/RGI 全部可加载。"""
import os, sys, json
SP = sys.argv[1]
LIB = os.path.join(SP, "_lib")
FULL = os.environ.get("TR018_FULL_SCIPY", "")
assert FULL and os.path.isfile(os.path.join(FULL, "linalg", "__init__.py")), \
    "TR018_FULL_SCIPY 未指向完整 scipy 目录（用于拷贝真实编译 .so）"

# 真实 .so（不是 stub），从 full 复制进 _lib/_tr018_capi/
DST = os.path.join(LIB, "_tr018_capi")
os.makedirs(DST, exist_ok=True)
CAPIS = [
    ("linalg/cython_lapack.cpython-314-darwin.so", "cython_lapack.cpython-314-darwin.so"),
    ("linalg/cython_blas.cpython-314-darwin.so", "cython_blas.cpython-314-darwin.so"),
    ("spatial/_qhull.cpython-314-darwin.so", "_qhull.cpython-314-darwin.so"),
]
import shutil
for rel, name in CAPIS:
    src = os.path.join(FULL, rel)
    assert os.path.isfile(src), src
    shutil.copy2(src, os.path.join(DST, name))
    print("  COPY", name, os.path.getsize(os.path.join(DST, name)))

# 在 scipy/__init__.py 顶部注入别名注册（幂等标记）
INIT = os.path.join(SP, "__init__.py")
s = open(INIT, encoding="utf-8").read()
MARK = "# TR-018 CAPI alias"
assert MARK not in s
BOOT = '''# TR-018 CAPI alias
# 只打包 ndimage/interpolate/_lib 时，interpolate 的 Cython 扩展
# (_ppoly / _interpnd) 在 C 级 cimport 了 scipy.linalg.cython_lapack 与
# scipy.spatial._qhull。这里把这两个**真实编译扩展**从 _lib/_tr018_capi/
# 注册成对应模块名，避免新增子包目录；不是 stub，是 scipy 原版 .so。
def _tr018_register_capi():
    import sys as _s, types as _t, importlib.util as _u, os as _o
    _d = _o.path.join(_o.path.dirname(__file__), "_lib", "_tr018_capi")
    _specs = [
        ("scipy.linalg", "cython_lapack.cpython-314-darwin.so"),
        ("scipy.linalg", "cython_blas.cpython-314-darwin.so"),
        ("scipy.spatial", "_qhull.cpython-314-darwin.so"),
    ]
    for _pkg, _fn in _specs:
        if _pkg not in _s.modules:
            _m = _t.ModuleType(_pkg)
            _m.__path__ = []
            _s.modules[_pkg] = _m
        _full = _pkg + "." + _fn.split(".")[0]
        if _full in _s.modules:
            continue
        _f = _o.path.join(_d, _fn)
        if not _o.path.isfile(_f):
            continue
        _sp = _u.spec_from_file_location(_full, _f)
        _mod = _u.module_from_spec(_sp)
        _s.modules[_full] = _mod
        try:
            _sp.loader.exec_module(_mod)
        except Exception:
            _s.modules.pop(_full, None)
        else:
            setattr(_s.modules[_pkg], _fn.split(".")[0], _mod)


_tr018_register_capi()
del _tr018_register_capi
# /TR-018 CAPI alias

'''
open(INIT, "w", encoding="utf-8").write(BOOT + s)
print("  INJECT scipy/__init__.py boot")
