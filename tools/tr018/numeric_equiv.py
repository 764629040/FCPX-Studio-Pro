#!/usr/bin/env python3
"""TR-018: 数值等价验证 —— 用同一批数据在指定 python 下计算，输出 JSON。
覆盖 psd_tools 实际用到的 scipy API：ndimage 描边/阴影 + interpolate 渐变/曲线/色相。
"""
import sys, json, numpy as np
from scipy import ndimage, interpolate

out = {}

# 1) 描边/阴影核心：distance_transform_edt / grey_erosion / gaussian_filter
rng = np.random.default_rng(20261110)
a = (rng.random((37, 41)) > 0.7)
out["edt"] = np.round(ndimage.distance_transform_edt(a), 9).tolist()
out["grey_erosion"] = ndimage.grey_erosion(
    rng.random((21, 23)).astype(np.float32), size=(3, 3)).round(9).tolist()
out["gaussian"] = ndimage.gaussian_filter(
    rng.random((17, 19)).astype(np.float32), sigma=1.7).round(9).tolist()
out["max_uniform"] = [
    ndimage.maximum_filter1d(rng.random(50).astype(np.float32), size=3).round(9).tolist(),
    ndimage.uniform_filter1d(rng.random(50).astype(np.float32), size=3).round(9).tolist(),
]

# 2) 渐变填充：interp1d 线性（psd_tools paint.py 用法）
X = np.array([0.0, 0.25, 0.6, 1.0], dtype=np.float32)
Y = np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1]], dtype=np.float32)
G = interpolate.interp1d(X, Y, axis=0, bounds_error=False, fill_value=(Y[0], Y[-1]))
out["interp1d"] = np.round(G(np.linspace(-0.1, 1.1, 23)), 9).tolist()

# 3) 曲线/对比度调整：CubicSpline natural（psd_tools adjustments.py 用法）
x = np.array([0, 64/255, 192/255, 1], dtype=np.float32)
y = np.array([0, 0.3, 0.75, 1], dtype=np.float32)
t = np.linspace(0, 1, 17).astype(np.float32)
out["cubic_spline"] = np.round(
    interpolate.CubicSpline(x, y, bc_type="natural")(t), 9).tolist()

# 4) 色相饱和度：RegularGridInterpolator linear（psd_tools adjustments.py 用法）
axis = np.linspace(-1, 1, 21, dtype=np.float32)
vals = rng.random((21, 21)).astype(np.float32)
rgi = interpolate.RegularGridInterpolator((axis, axis), vals, method="linear")
pts = np.array([[0.0, 0.0], [-0.35, 0.72], [0.91, -0.44]], dtype=np.float32)
out["rgi"] = np.round(rgi(pts), 9).tolist()

# 5) 其余常用：Pchip / BSpline / PPoly / interpn / griddata
out["pchip"] = np.round(
    interpolate.PchipInterpolator([0, 1, 2, 3], [0, 1, 0.5, 2])([0.2, 1.3, 2.8]), 9).tolist()
out["bspline"] = np.round(
    interpolate.BSpline(np.array([0, 0, 0, 1, 2, 2, 2]),
                        np.array([[0, 0], [1, 2], [2, 0], [3, 1]], dtype=float), 2)(
        np.linspace(0, 2, 11)), 9).tolist()
out["interpn"] = np.round(
    interpolate.interpn((axis, axis), vals, pts, method="linear"), 9).tolist()
out["griddata"] = np.round(
    interpolate.griddata(rng.random((12, 2)), rng.random(12), (0.3, 0.4), method="linear"), 9).tolist()

json.dump(out, sys.stdout, separators=(",", ":"))
