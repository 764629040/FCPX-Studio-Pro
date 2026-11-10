# scipy 裁剪说明（TR-018 / TR-021）

> 适用范围：`FCPX Studio Pro R2.app/Contents/Resources/python_bundle/lib/python3.14/site-packages/scipy`
> 基线版本：Python 3.14.6 / scipy 1.16.3 / psd_tools 1.24.0
> 建立：2026-11-10（TR-018）　补充：2026-11-10（TR-021，已知差异）
> 权威证据：`reports/verify_tr018/`、`reports/verify_tr021/`；一键复现 `tools/tr018/build_and_verify.sh`

本文件是裁剪包的**唯一权威说明**。改裁剪逻辑前先读这里，尤其是第 5 节的「已知差异」。

---

## 1. 裁剪范围与硬约束

只保留四个目录：

```
scipy/
├── ndimage/        ✅ 保留
├── interpolate/    ✅ 保留
├── _lib/           ✅ 保留（含 TR-018 注入的 C 级扩展 _lib/_tr018_capi/）
└── .dylibs/        ✅ 保留
```

已删除 17 个子包：`cluster constants datasets differentiate fft fftpack integrate io linalg misc odr optimize signal sparse spatial special stats`。

硬约束（TR-018 立，TR-021 沿用）：

1. **禁降级**：`psd_tools.composite._compat.HAS_SCIPY` 必须为 `True`；带描边/阴影的 PSD 不得掉到 `pil_topil_fallback`。
2. **不新增子包目录**：`scipy/` 下不得出现被删子包的名字。
3. **不塞返回假值的 stub**：确实依赖已删子包的 API，只能在访问/调用时抛明确 `ImportError`（诚实失败），不得返回占位数值、不得静默降级。
4. **逐位一致**：`psd_tools` 实际调用到的 API 输出必须与完整 scipy 逐位一致。

体积结果：`python_bundle 140M → 88M`（≤100M）；`scipy 63M → 10M`；整包 app `93M`。

---

## 2. 为什么不能「纯删」

纯删后 `ndimage/_interpolation.py` 顶层 `from scipy import special` 与 `interpolate/__init__.py` 的 eager import 连锁失败：

```
ModuleNotFoundError: No module named 'scipy.special'
  → from scipy import interpolate 失败
  → HAS_SCIPY = False
  → composite/effects.py 抛 ImportError("Stroke effects require: scipy")
  → core/psd_layer_fallback.py::render_layer_to_png_bytes 掉到 pil_topil_fallback
  → wedding_with_decorations_23.psd L003「箭头」PNG sha 785e0597 → 8053f51d
```

所以必须在保留区内部打补丁，让「只留三个子包」在语义上仍然是一个能工作的 scipy。

---

## 3. 最终方案（三层，全部在保留区内）

| 层 | 脚本 | 动作 |
|---|---|---|
| A 目录层 | `tools/tr018/slim_scipy.sh` | 删除 17 个子包，只留上述四个目录 |
| B 保留区补丁 | `tools/tr018/patch_slim.py` | 顶层 `submodules` 收敛；`interpolate/__init__.py` 改 PEP 562 lazy 命名空间（63 个公开符号按需加载真实实现）；跨包顶层 import 改可降级加载；`CubicSpline` 的 `solve_banded((1,1),…)` 用 numpy Thomas 算法等价实现并保留 float32 dtype |
| C C 级依赖 | `tools/tr018/alias_capi.py` | `_ppoly.so` cimport `scipy.linalg.cython_lapack`、`_interpnd.so` cimport `scipy.spatial._qhull`。把原版真实 `.so` 复制进 `_lib/_tr018_capi/`，在 `scipy/__init__.py` 注册 `sys.modules` 别名；**不新增子包目录、不是 stub** |

B 层里 `_MissingSSL` / `_LazySpecial` / `_tr018_missing` 这类对象是「调用即抛 ImportError 的诚实占位」，不是返回假值的 stub。TR-021 不新增任何此类对象。

---

## 4. 已知差异：rotate 路径 1 ULP　★ TR-021

> 本节的标题即验收锚点：**已知差异：rotate 路径 1 ULP**。

### 4.1 触发点

`patch_slim.py` 第 2 组补丁把 `ndimage/_interpolation.py::rotate()` 中的

```python
c, s = special.cosdg(angle), special.sindg(angle)
```

改成：

```python
try:
    from scipy import special as _special
    c, s = _special.cosdg(angle), _special.sindg(angle)
except ImportError:
    import math as _math
    c, s = _math.cos(_math.radians(angle)), _math.sin(_math.radians(angle))
```

裁剪包里 `scipy.special` 已被删除，因此**必然走 `math` 兜底分支**。完整 scipy 下仍走原 `cosdg/sindg`，数值逐位不变。

### 4.2 成因

`cosdg/sindg` 是 `scipy.special._ufuncs.cpython-314-darwin.so` 里的 numpy ufunc（Boost 实现：先按角度归约到 360°，再按象限用专门多项式，并对 90° 倍数**精确归零**）。而 `math.cos(math.radians(x))` 是 `x * (π/180)` 一次额外舍入后交给 libm 的通用 cos。两条路径的角度归约与多项式不同，结果在末位分叉。

### 4.3 实测量级（144 万角度）

复现脚本：`tools/tr021/ulp_probe.py`。口径：0°~360° 均匀 1,440,000 个角度，对比 `special.cosdg/sindg` 与补丁实际使用的 `math.cos/sin(math.radians(x))` 标量值。

| 指标 | cosdg vs math.cos | sindg vs math.sin |
|---|---|---|
| 末位不同角度数 | 830,867 / 1,440,000（57.70%） | 760,093 / 1,440,000（52.78%） |
| 其中恰为 1 ULP（排除零点） | 394,680（47.50%） | 371,131（48.83%） |
| ≤ 2 ULP 占比 | 65.02% | 67.28% |
| 最大绝对差 | 5.551115e-16 | 5.551115e-16 |
| `cosdg/sindg` 精确归零、math 留残差的角度 | 2 | 1 |

任一函数末位不同的角度为 1,098,075 / 1,440,000（76.26%）。典型例：45° 时 `cosdg=0.7071067811865475`、`math=0.7071067811865476`，恰好 1 ULP。

> 口径说明：问题单记录「144 万角度里 100.6 万个末位不同」。本仓库按四种采样口径复现实测为 66.5 万 ~ 114.3 万（`linspace(-180,180)` 665,108 / `linspace(0,360)` 831,439 / `arange*0.00025` 830,867 / `arange*0.001` 1,142,598），100.6 万落在同一区间。**计数随采样口径浮动，结论一致：末位不同是普遍现象，量级为 1 ULP 为主、绝对差不超过 5.55e-16。** 计数差异不改变处置决策。

在 cos/sin 值接近 0 的角度附近，按「相对 ULP」计的数会被放大（ULP 本身趋近于 0），但**绝对误差仍是 1e-16 量级**，不影响下面的结论。

### 4.4 更严重的一支：90° 倍数角不是 1 ULP，是结构性差异

`cosdg/sindg` 对 90° 倍数精确返回 ±0.0，而 `math` 留下 `6.12e-17 ~ 2.45e-16` 残差：

| 角度 | cosdg | math.cos(radians) |
|---|---|---|
| 90° | `-0.00000000000000000e+00` | `6.12323399573676604e-17` |
| 270° | `0.00000000000000000e+00` | `-1.83697019872102969e-16` |
| 180° | `-1.0` | `-1.0`（sindg `-0.0` vs math `1.22464679914735321e-16`） |

`rotate()` 用 `c, s` 构造 `rot_matrix`，再算 `offset = in_center - rot_matrix @ ((out_shape-1)/2)`，最后交给 `affine_transform`。`c` 从精确 `0.0` 变成 `6.12e-17` 后，`offset` 带残差，`affine_transform` 把边界像素坐标判成界外，按 `cval=0` 填充 —— **边界列/行被大面积清零**（本例首列 59/64 像素，完整 scipy 侧为 0/64）。

端到端实测（`tools/tr021/rotate_probe.py`，64×64 随机数组、`order=3`、`reshape=False`、固定种子 20261110）：

| 角度 | full scipy sha256 | 裁剪包 sha256 | 差异 |
|---|---|---|---|
| 37.3° | `8c1e9e7ccd34…` | `8c1e9e7ccd34…` | 逐位一致（该角度 cosdg 与 math 恰好同值） |
| 90.0° | `bee1f510be29…` | `b69ef4733836…` | **2752 / 4096 像素不同，最大差 0.99597，sum Δ = -29.29，裁剪包首列 59/64 像素被填 0（full 首列 0 个）** |

所以「1 ULP」只描述常规角度的 `c/s` 标量；**一旦真的调用 `ndimage.rotate`，90° 倍数角会产生远大于 1 ULP 的输出差异**。这一点必须和「1 ULP」一起记录，否则会低估风险。

### 4.5 影响面：当前零影响

- `psd_tools`（包内 `site-packages/psd_tools/**/*.py`）全仓 grep：只调用 `distance_transform_edt`、`grey_erosion`、`maximum_filter1d`、`uniform_filter1d`，**零 `rotate` 调用**；唯一含 "rotat" 字样的是 `composite/adjustments.py` 里描述亮度样条的英文注释。
- 项目 `core/**/*.py` 零 `ndimage` / `rotate` 命中。
- `reports/verify_tr018/` 的 67 层带样式 PSD 逐层 PNG sha256 验收不涉及 `rotate`。
- TR-018 数值等价覆盖的 11 组 API（edt / grey_erosion / gaussian / maximum_filter1d / uniform_filter1d / interp1d / CubicSpline / RegularGridInterpolator / Pchip / BSpline / interpn / griddata）**不包含 rotate**，2541 个标量逐位一致。

**结论：本差异不影响任何现行渲染路径，不构成 TR-018 回归。** TR-018 的「禁降级」验收边界是 psd_tools 实际调用面，不是整个 scipy API 面。

### 4.6 声明边界

裁剪包**不是**完整 scipy 的数值等价替代品，只对上述调用面承诺逐位一致。`ndimage.rotate`（以及任何其他未纳入验收的 API）在裁剪包下可用，但输出可能与完整 scipy 不同。调用方若需要严格数值复现，不得假设二者等价。

---

## 5. 若将来真要启用 rotate：三条路，不新增 stub

本次（TR-021）采用 **A：文档标注 + 保持现状**，不改运行时逻辑、不新增任何 stub 或假模块。

| 方案 | 做法 | 能否逐位一致 | 是否新增 stub | 代价 |
|---|---|---|---|---|
| **A 文档标注（本次采用）** | 第 4 节写清差异与适用边界，调用面保持零 rotate | 不涉及 | 否 | 零代码风险；未来启用前必须重读本节 |
| **B 引入真 ufunc** | 沿用 C 层 `alias_capi.py` 机制：把 `scipy/special/_ufuncs.cpython-314-darwin.so` 复制进 `_lib/_tr018_capi/`，注册 `sys.modules` 别名，让 `rotate` 拿到**真实** `cosdg/sindg` ufunc，而不是假实现 | 能（同一份二进制实现） | **否**（不新增假模块、不新增子包目录，注入的是原版真实 `.so`） | 需先验证该 `.so` 的传递依赖（可能牵出 `_ufuncs_cxx` / `_cdflib` 等），并复核体积与验签；等于把 special 的一小块实现带回来 |
| **C 纯 math 复刻角度归约** | 不依赖 special，先 `fmod(x, 360)` 归约、按 90° 象限分支、对 90° 倍数精确返回 `0/±1`，再调 libm | **否**，只能做到「数学等价」；Boost 多项式与 libm 不同，常规角度仍会末位分叉 | 否 | 能修掉 4.4 的特殊角结构性差异（最要紧的那条），但保不住逐位一致 |

**取舍结论**：若未来启用 `rotate` 且要求与完整 scipy 逐位一致，只有 B 可靠；C 只能消除 90° 边界清零这类结构性差异，不能消除 1 ULP 分叉。无论选 B 还是 C，都不得通过「塞一个返回假值的 `scipy.special` / `cosdg` stub」来绕过 —— 那违反第 1 节硬约束 3，且会把差异藏起来变成静默错误。

启用前的强制动作：把 `rotate` 加入 `tools/tr018/numeric_equiv.py` 的等价集合，覆盖常规角与 90° 倍数角，重跑 `build_and_verify.sh` 并更新本报告。

---

## 6. 不变量 / 禁止事项

- 禁止重新引入任何已删子包目录。
- 禁止新增返回假值的 stub；诚实占位对象必须「调用即抛 ImportError」。
- 禁止修改 `.app` 后不重签：`codesign --force --deep --sign -` + `codesign --verify --strict --deep --verbose=2` 零报错是落地门槛。
- 禁止把 `PSDImage.composite(force=True)` 整图渲染当验收路径（部分样本撞 `aggdraw` 依赖）；必须用 `core/psd_layer_fallback.py::render_layer_to_png_bytes` 逐层路径。
- 完整原 scipy 备份：`/tmp/tr018/backup_scipy_original`（1035 文件 / 63M）。

---

## 7. 复现与证据索引

| 用途 | 位置 |
|---|---|
| 一键重建 + 禁降级验收 | `tools/tr018/build_and_verify.sh` |
| ULP 量级实测 | `tools/tr021/ulp_probe.py` → `reports/verify_tr021/ULP实测输出.txt` |
| full / slim rotate 端到端对比 | `tools/tr021/rotate_probe.py` → `reports/verify_tr021/rotate对比输出.txt` |
| TR-021 文本核对 + 不新增 stub 扫描 | `tools/tr021/verify_tr021.sh` → `reports/verify_tr021/验收脚本输出.txt` |
| TR-018 原始验收 | `reports/verify_tr018/验收记录.txt`、`落地复验原始输出.txt` |
| TR-021 验收 | `reports/verify_tr021/验收记录.txt` |
| 台账核销 | `docs/待办清单_20261110.md` H / I 节 |
