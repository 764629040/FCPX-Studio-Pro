# FCPX Studio Pro — 本次代码修复与测试复跑报告

- 报告日期：2026-10-27
- 执行角色：开发执行（**非独立审核**）
- 状态声明：**03 清单保持待独立审核，本报告不勾选任何结案项，不代表独立验收通过。**

---

## 1. 版本锁定（审核期间不得混用）

本次全部测试结果均来自下表指纹的同一版本。任何文件的 SHA-256 若变化，本报告结论作废需重跑。

### 1.1 复跑前（基线）源码指纹

| 文件 | SHA-256 |
|---|---|
| `core/psd_parser.py` | `fb02deb834fce8405def58623f0d00c8630ad80c4b9c13f056e2a62a5c07e0e0` |
| `core/motion_builder.py` | `986f6c2def60983533abc969177819a5e832d3b4c87a75428bca2b1f85a48eb7` |
| `gui/main_window.py` | `a2c0bdbb539dd1548ffcc8c1d74f3a9ba4e033cf0f934dc2ab45ea29cca9eda4` |
| `gui/canvas_view.py` | `e140db48463a81afc8543e7be9d649986ba18fe363706085c0d5c95cbb83a149` |
| `gui/inspector_panel.py` | `fcc27cc116130019ee40773c22ed667b987ef47be1d073b22dfac775faa1d0ed` |
| `tests/test_clean_environment.py` | `05506901228d151f08e4e6ddbdd7117fc55b8e26fed49e495dff7b9f16c0e839` |
| `tests/test_psd_import_and_diagnosis.py` | `c51738b5dc348ef8c5d493b2069d09b42481043c3eb79f17847775358c40cd71` |
| `tests/test_preview_comparison.py` | `5254c011e28b05041c49b4f043561c08aa9817fdb2b621069bc2fd52c3558a1a` |

完整清单（含 fixtures）：`docs/audit_inventory_20261027.json`

### 1.2 修复后源码指纹

| 文件 | SHA-256 | 变化 |
|---|---|---|
| `core/psd_parser.py` | `feaaaf0f5ec687b350361378ab21af238015a46a24808bc487d7f85d5ce193e5` | **已修改** |
| `tests/test_psd_import_and_diagnosis.py` | `31f5f3a21d9b25ed5b8e1d689e25cf706db92a0ff948b05b3612e4b05b2f03ef` | **已修改** |
| `tests/test_font_diagnosis_honesty.py` | `8f0ded73202e13edbc446a51c567c6f9507b3209a2cb81612f487edf4ad0be8a` | 新增 |
| `tests/probe_real_interaction.py` | `d1293ccee0abfc4457f21a247d7f6564a91f9e670f7f3d4fb67e61b7a5830250` | 新增 |
| 其余全部源码/测试 | 与 1.1 完全一致 | 未改动 |

完整清单：`docs/audit_inventory_20261027_postfix.json`

**关键发现（版本混用风险）**：项目内既有的 `docs/independent_audit_pytest_20261027.log` 记录的源码指纹与本次基线**不一致**：

| 文件 | 该日志记录 | 本次基线 | 结论 |
|---|---|---|---|
| `gui/canvas_view.py` | `188e3334…edaffc` | `e140db48…83a149` | 不同版本 |
| `gui/main_window.py` | `1bd93fa2…7e68c12` | `a2c0bdbb…cca9eda4` | 不同版本 |
| `core/psd_parser.py` | `08aba9ad…8e960a` | `fb02deb8…7e0e0e` | 不同版本 |
| `tests/test_preview_comparison.py` | `f711ae21…e2cb6a` | `5254c011…8a1d0e` | 不同版本 |
| `gui/inspector_panel.py` | `fcc27cc1…1d0ed` | 同 | 一致 |

因此该历史日志**不能**作为当前代码的验收依据，其结论不予沿用。

---

## 2. 复跑结果（用户指定命令）

命令（项目根目录执行）：

```
QT_QPA_PLATFORM=offscreen python3 -m pytest \
  tests/test_clean_environment.py \
  tests/test_psd_import_and_diagnosis.py \
  tests/test_preview_comparison.py -v
```

### 2.1 复跑前（修复前基线，用于定位问题）

| 项目 | 值 |
|---|---|
| 日志 | `docs/pytest_rerun_20261027_candidate.log` |
| 退出码文件 | `docs/pytest_rerun_20261027_candidate.exitcode` |
| 收集 / 通过 / 失败 / 跳过 | 21 / 20 / 1 / 0 |
| **pytest 退出码** | **1** |

退出码获取方式：进程重定向输出后直接取 `$?`，未经过 `tee` 或管道，因此是 pytest 自身退出码。

### 2.2 复跑后（修复完成）

| 项目 | 值 |
|---|---|
| 日志 | `docs/pytest_final_run_20261027.log` |
| 退出码文件 | `docs/pytest_final_run_20261027.exitcode` |
| 收集 / 通过 / 失败 / 跳过 | 21 / 21 / 0 / 0 |
| **pytest 退出码** | **0** |

### 2.3 新增回归测试

| 项目 | 值 |
|---|---|
| 日志 | `docs/pytest_regression_20261027.log` |
| 测试用例 | 3 / 3 通过 |
| **pytest 退出码** | **0** |

### 2.4 模拟 Linux 无 AppKit（用户指定的降级要求）

| 项目 | 值 |
|---|---|
| 日志 | `docs/pytest_simulated_no_appkit_20261027.log` |
| 方法 | 拦截 `builtins.__import__` 使 `import AppKit` 抛 `ImportError` |
| 收集 / 通过 / 失败 | 21 / 21 / 0 |
| **pytest 退出码** | **0** |

---

## 3. 测试平台与版本

| 项目 | 值 |
|---|---|
| 操作系统 | macOS 26.5 (arm64) |
| Python | 3.14.6（`/opt/homebrew/opt/python@3.14/bin/python3.14`） |
| pytest | 9.1.1 |
| PyQt6 | 6.11.0 |
| Qt | 6.11.0 |
| psd-tools | 1.24.0 |
| Qt 平台插件 | `offscreen` |

---

## 4. 失败根因（可复现，非偶发）

### 4.1 现象

`test_normal_text_psd_import_and_diagnosis` 失败于：

```
assert summary["has_missing_risk"] is False
E   assert True is False      # 实际 missing_fonts_count = 8
```

连续 3 次执行结果一致，稳定复现。

### 4.2 根因（环境状态变化，非代码回归）

样本 PSD `tests/data/vertical_wedding_9_16.psd` 的 8 个文本图层全部声明字体 `FZZYSK--GBK1-0`（方正准雅宋_GBK）。

在**当前** macOS 环境中该字体确实未注册，独立证据：

1. `AppKit.NSFont.fontWithName_size_("FZZYSK--GBK1-0", 12)` → `None`
2. `NSFontManager.availableFonts()` 2750 项中不含该名
3. `atsutil fonts -list` 全量 3367 项中检索 `FZZYSK` 命中数 = **0**（系统级交叉验证，非仅 AppKit）

字体目录状态：

| 位置 | 条目数 | 类型 |
|---|---|---|
| `~/Library/Fonts` | 732 | **全部为符号链接，真实文件 0 个** |
| 链接创建时间 | — | 2026-10-27 14:33–14:36 |

而项目内 `docs/test_suite_all_pass_20261027.log`（21 全通过）时间戳为 **13:48**，`tests/reports/diagnosis_normal.json` 为 **14:12**，**均早于** 14:33 的字体目录符号链接化操作。

结论：

- 13:48 全通过时，字体可被正常索引；
- 14:33 之后字体目录被替换为符号链接，fontd 不索引符号链接字体，AppKit 因此报告 `font_missing`；
- 代码行为**正确**（诚实报告字体缺失），测试把"该字体在本机已安装"当作固定前提写死，属于环境耦合缺陷。

### 4.3 顺带发现的第二个真实缺陷

模拟无 AppKit 环境（Linux 形态）时，`font_status` 全部为 `unverifiable`，但诊断汇总却输出：

```
missing_fonts_count: 0
has_missing_risk: False
risk_assessment: 无风险：所有图层均符合 Motion 矢量规范，字体覆盖率 100%
```

这是**伪通过**：明明无法检测字形，却宣称"覆盖率 100%、无风险"。违反用户明确要求"Linux 无 AppKit 时允许返回 unverifiable，但不得制造伪通过"。

---

## 5. 修复内容（最小改动，不含新功能）

### 5.1 `core/psd_parser.py`

新增 `unverifiable_fonts_count` 统计并纳入风险判定：

```python
unverifiable_fonts_count = sum(
    1 for d in diagnosis_layers if d.get("font_status") == "unverifiable"
)
has_missing_risk = (
    missing_fonts_count > 0
    or unverifiable_fonts_count > 0
    or any(len(d.get("missing_glyphs", [])) > 0 for d in diagnosis_layers)
)
```

风险文案新增 `unverifiable` 独立分支：

```
无法确定风险：存在 N 个文本图层字体环境不可验证（当前环境无法检测字形覆盖度），
缺失情况未知，需在 macOS 目标机复核
```

`summary` 新增字段 `unverifiable_fonts_count`（正常/损坏/异常三种报告形状均已补齐，值分别为计算结果 / 0 / 0）。

### 5.2 `tests/test_psd_import_and_diagnosis.py`

将"字体已安装"这一固定前提改为**按真实注册状态分支的实质断言**，三个分支均保留完整严格校验，未删除任何断言、未放宽预期、未引入死代码：

| 分支 | 触发条件 | 核心断言 |
|---|---|---|
| 无 AppKit | `not HAS_APPKIT` | `font_status == "unverifiable"`；`unverifiable_fonts_count == 8`；`has_missing_risk is True`；风险文案含"无法确定风险"；文案**不得**含 "100%" |
| 字体已注册 | `check_font_availability(declared)` | `font_status == "complete"`；`missing_glyphs == []`；`has_missing_risk is False`；文案含"无风险" |
| 字体未注册 | 其余 | `font_status == "font_missing"`；`missing_fonts_count == 8`；`has_missing_risk is True`；文案含"中风险"；每层 `missing_glyphs` 非空 |

回退字体断言按文本是否含中文分流（中文 → `PingFangSC-Regular`，纯西文 → `Helvetica`），与实际分流逻辑一致。

同时新增一道与分支无关的**恒定断言**：preserved 文本图层的 `font_status` 必须属于四态之一，禁止 `None`/空值静默漏检。

### 5.3 新增回归测试 `tests/test_font_diagnosis_honesty.py`

| 用例 | 校验点 |
|---|---|
| `test_unverifiable_must_not_claim_no_risk` | 无 AppKit 时禁止宣称无风险/100% 覆盖 |
| `test_unverifiable_count_present_in_all_report_shapes` | 三种报告形状均携带新字段 |
| `test_declared_font_state_is_honest_and_complete` | 真实环境状态与诊断输出必须一致，禁止矛盾伪通过 |

**有效性反证**：临时回滚 `has_missing_risk` 逻辑后重跑，`test_unverifiable_must_not_claim_no_risk` 立即失败（`assert False is True`）。证明该回归测试确实锁定缺陷，不是摆设。

### 5.4 未改动范围

- 未修改 `gui/canvas_view.py`、`gui/main_window.py`、`gui/inspector_panel.py`、`core/motion_builder.py` 等无关模块；
- 未新增任何产品功能；
- 未修改 `docs/` 之外的任何测试 fixtures；
- 未操作 `/Volumes/NO NAME/128`（仅只读查看目录列表，未写入/修改/移动/重命名/删除）；
- 未迁移源码，未修改已安装的 Motion/FCPX 模板；
- 未使用 `chmod`、`xattr` 或创建软链接处理审核工具挂载问题。

---

## 6. 四项功能验证证据

验证工具：`tests/probe_real_interaction.py`（独立探针，使用真实 Qt 事件，不依赖既有测试断言）
输出证据：`tests/reports/probe_real_interaction.json`

### 6.1 同名图层诊断跳转

| 检查项 | 实测 | 判定 |
|---|---|---|
| `index=10` 跳转行号 | 0 | ✅ |
| `index=20` 跳转行号 | 1 | ✅ |
| 同名但路径不同是否区分 | `True` | ✅ |
| 无 index 时全路径全等回退 | 命中行 1（正确） | ✅ |
| 子串陷阱（路径 `页脚组`）是否误命中 | 未命中（行号未变化） | ✅ |

实现核对（`gui/main_window.py` `_on_jump_to_diagnosis`）：
- 优先按 `UserRole` 中唯一 `layer_index` 精确比对；
- 回退路径使用 `path_item.text() == target_path` **全等比较**；
- 未发现任何名称包含/子串匹配分支。

### 6.2 四态徽章（文案 / 颜色 / 缺字信息 / 点击定位）

| 状态 | 徽章文案 | 前景色 | 背景色 | 点击定位行 |
|---|---|---|---|---|
| complete | `🟢 字体 100% 支持` | `#30d158` | `#14301c` | 0 ✅ |
| partial_missing | `🟠 缺字: 领, 衔` | `#ff9f0a` | `#3d2914` | 1 ✅ |
| font_missing | `🔴 原始字体未安装 (回退: PingFangSC-Regular)` | `#ff453a` | `#3d1418` | 2 ✅ |
| unverifiable | `🟡 无法验证字形` | `#ffd60a` | `#3d3514` | 3 ✅ |

属性面板（Inspector）按钮文案与配色同源，既有测试 `test_four_state_font_badges_and_interaction_coverage` 已覆盖并通过。

### 6.3 左右预览滚轮缩放与拖拽平移同步

使用真实 `QWheelEvent` / `QMouseEvent` 投递到 `viewport()`：

| 检查项 | 实测 | 判定 |
|---|---|---|
| 左画布滚轮缩放生效 | scale 0.2856 → 0.3284 | ✅ |
| 缩放同步至右画布 | 左右 m11 完全相等 | ✅ |
| 右画布滚轮反向缩放 | 0.3284 → 0.2856，左右一致 | ✅ |
| Shift+左键拖拽平移生效 | 水平滚动 -300 → -210 | ✅ |
| 平移同步至右画布 | 水平/垂直滚动值完全相等 | ✅ |
| 拖拽结束后 panning 状态复位 | `_is_panning is False` | ✅ |

### 6.4 棋盘格设置在新实例后恢复

真实读写 `QSettings("FCPXStudioPro", "FCPXStudioPro")`，并**新建** `CanvasContainer()` 实例验证：

| 写入值 | 新实例读取（左, 右） | 判定 |
|---|---|---|
| `False` | `(False, False)` | ✅ |
| `True` | `(True, True)` | ✅ |

探针结束后已还原原始设置值，未污染用户配置。

### 6.5 截图

| 文件 | 内容 |
|---|---|
| `docs/13_四态徽章实测截图.png` | 四态徽章画布渲染实拍 |
| `docs/14_诊断定位实测截图.png` | 诊断报告表格与定位实拍 |

（本次执行模型不支持读取图片，截图为程序直接 `grab()` 保存的原始产物，未经任何裁剪或编辑。）

---

## 7. 日志与证据索引（全部位于项目内）

| 路径 | 说明 |
|---|---|
| `docs/audit_inventory_20261027.json` | 修复前源码/fixtures 指纹清单 |
| `docs/audit_inventory_20261027_postfix.json` | 修复后指纹清单 |
| `docs/pytest_rerun_20261027_candidate.log` | 修复前完整原始输出 |
| `docs/pytest_rerun_20261027_candidate.exitcode` | 修复前 pytest 退出码 |
| `docs/pytest_final_run_20261027.log` | 修复后完整原始输出 |
| `docs/pytest_final_run_20261027.exitcode` | 修复后 pytest 退出码 |
| `docs/pytest_regression_20261027.log` | 新增回归测试输出与退出码 |
| `docs/pytest_simulated_no_appkit_20261027.log` | 模拟 Linux 无 AppKit 复跑 |
| `docs/fix_diff_20261027.txt` | 修复关键代码段 |
| `tests/reports/probe_real_interaction.json` | 四项功能真实交互证据 |
| `docs/13_四态徽章实测截图.png` | 四态徽章实拍 |
| `docs/14_诊断定位实测截图.png` | 诊断定位实拍 |

---

## 8. 遗留与未完成事项（诚实声明）

1. **字体环境未修复**：`~/Library/Fonts` 的 732 个符号链接字体仍未被 fontd 索引。本次按"只修复可复现问题"的边界，未使用 `chmod`/软链接等手段干预系统字体索引。如需在真机验证 `complete` 态，应由用户侧以真实字体文件安装，届时三态分支会自动走"已安装"路径。
2. **非 macOS 真机验证**：模拟无 AppKit 仅通过 `import` 拦截实现，属等价降级验证，不等同于真实 Linux 机器运行。
3. **跨版本复核**：本次结论仅对第 1 节所列指纹有效。既有 `docs/independent_audit_pytest_20261027.log` 对应的代码版本与本次不同，不得混用。
4. **03 清单未勾选**：`03_项目进度总清单.md` 保持原状，等独立审核人员复跑后自行判定。
5. **项目与模板版本管理**：按用户指令，仅在独立审核通过后才启动，本次未开始。

---

## 9. 结论

| 项目 | 结果 |
|---|---|
| 用户指定命令 | 21 收集 / 21 通过 / 0 失败 / 0 跳过 |
| pytest 真实退出码 | **0** |
| 修改文件数 | 2（`core/psd_parser.py`、`tests/test_psd_import_and_diagnosis.py`） |
| 新增文件数 | 2（回归测试 1、探针 1） |
| 无关模块改动 | 无 |
| 断言删除/放宽 | 无 |
| 03 清单 | 未勾选，待独立审核 |
