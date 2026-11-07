# PSD 支持边界矩阵 (R25 C-1)

> 单一事实来源：`core/psd_support_matrix.py` 导出的 `PSD_SUPPORT_MATRIX`。
> 本文件由该矩阵自动对齐生成；修改请以代码模块为准，并由
> `tests/test_r25_c_01_support_matrix.py` 校验完整性。

## 约定

- **supported**：该图层类型能否在 FCPX / Motion 矢量规范下 1:1 还原。
  - `true` 完全支持（纯矢量文本）
  - `conditional` 部分支持（如像素层：底板忽略、普通降级）
  - `structure_only` 仅保留结构，不独立渲染（组）
  - `false` 不支持，必须走降级 / 显式跳过
- **disposition**：解析器对该图层的处置
  - `preserved` 保留为可发布标题
  - `degraded` 降级为 32 位透明 RGBA PNG 嵌入
  - `ignored` 显式忽略（仍计入 `skipped_layer_count`，绝不静默丢弃）
- **behavior_when_unsupported**：不支持时的**显式**行为。任何类型都不得"静默丢弃"。

## 支持矩阵：图层类型 × 是否支持 × 不支持时行为

| 图层类型 | 是否支持 | 处置 | 不支持时的行为 |
|---|---|---|---|
| type（文字） | ✅ true | preserved | n/a（本类型即受支持）；字体/字形缺失时诊断高亮 + 缺字可见标记，绝不静默替换默认字体 |
| smartobject（智能对象） | ❌ false | degraded / skipped | 默认展平为 32 位透明 RGBA PNG；或按 `smart_object_policy='skip'` 显式跳过并记录原因；二者必居其一 |
| shape（矢量形状） | ❌ false | degraded | 展平为 32 位透明 RGBA PNG；描边/填充若无法映射则记入诊断 |
| pixel（位图像素） | ⚠️ conditional | degraded / ignored | 普通像素层展平为 PNG；识别为底板的像素层按规范显式忽略 |
| adjustment（调整图层） | ❌ false | degraded | 展平为 PNG 近似保留视觉；色彩校正语义不在 Motion 矢量规范内，显式记录 |
| group（图层组） | 🅾️ structure_only | ignored | 仅保留层级结构（layer_tree / layer_path / depth），计入 skipped，不单独输出 |
| unknown（未归类） | ❌ false | degraded | 按非文本层保守降级为 PNG，并记入 unsupported_features，绝不静默丢弃 |

## 图层样式（C-3 / C-4）支持边界

| 样式 | 是否支持 | 行为 |
|---|---|---|
| 描边 Stroke | ❌ 不在 Motion 矢量规范 | 结构化提取 size / color / position / opacity → 记入诊断；提供 Motion 描边参数写出就绪表示 |
| 投影 DropShadow | ❌ | 提取 blur / offset / color / opacity → 记入诊断；提供 Motion Drop Shadow 近似写出 |
| 内阴影 InnerShadow | ❌ | 同上（inner=True） |
| 外发光 OuterGlow | ❌ | 提取 blur / color / opacity → 记入诊断；提供 Motion Glow 近似写出 |
| 内发光 InnerGlow | ❌ | 同上（inner=True） |
| 斜面和浮雕 / 叠加类 | ❌ | 显式记入诊断，标注无 Motion 近似映射，待人工处理 |

> 说明：混合模式（C-5）、描边/投影/发光（C-3/C-4）的**最终写入 `.moti`**
> 由 `core/motion_builder.py` 负责，该文件属本次 R25 的红线范围，未改动。
> 本矩阵对应的数据层与"写出就绪"序列化实现位于 `core/motion_param_writer.py`，
> 作为后续集成的接口边界。

## 不变式（C-8 图层守恒）

对任意 PSD：

```
input_layer_count == output_layer_count + skipped_layer_count
```

- `input_layer_count` = 遍历到的全部图层数（`psd.descendants()`）
- `output_layer_count` = 实际输出层（`preserved` + `degraded`）
- `skipped_layer_count` = 显式忽略层（`ignored`，含组/底板/空层/隐藏层）

每个图层必然落入上述一类，因此守恒恒成立；`verify_layer_conservation()` 提供校验入口。

## SA-4 复查问题修复补记（SA-2b，2026-11-05）

### 问题 1（P1）：skip 策略守恒破坏 → 已修复

`core/psd_parser.py`：`smart_object_policy='skip'` 命中可见智能对象时，
该层现在**只**产生诊断条目（`disposition='ignored'`，reason 含"跳过"）与
树节点，**不再**进入 `layers_info`（不构造 `PSDLayerInfo`、不消耗
`layer_idx`）。修复前被跳过的层同时计入 output 与 skipped（双重计数），
SA-4 实测 input=12 / output=7 / skipped=7（差 -2）；修复后 12 = 5 + 7。
守恒式现对所有 `smart_object_policy`（skip / flatten）× 可见性组合恒成立，
回归锁定于 `tests/test_r25_c_02b_conservation_policy.py`。

### 问题 2（P1）：媒体生成失败静默出货 → 已修复（解析侧）

- `core/psd_layer_fallback.py`：`render_layer_to_png_bytes` 在 `composite()`
  抛错（典型：缺 scipy 的描边图层）时，先做 **PIL 原始像素回退**
  （`layer.topil()`，无 scipy 依赖，丢效果但保图层本体，
  `info["render_method"]="pil_topil_fallback"` 诚实标注）；回退也失败才返回错误。
- `core/psd_parser.py`：PNG 落盘**成功后**才把路径写进 `fallback_png_path`
  （失败时保持 `None`，杜绝 `.moti` 引用不存在的 `Media/element_XX.png`）；
  失败时诊断条目携带 `severity='error'`、`media_error=
  "Media 资产生成失败: <确切原因>"`，并计入机器可核查计数器
  `missing_media_refs`（顶层与 `summary` 同源）；`missing_media_refs > 0`
  时 `risk_assessment` 强制为高风险，整体诊断不得宣称完整成功。
  失败层仍以 `degraded` 计入 output，守恒不破（degraded-with-warning，
  绝不静默丢弃）。回归锁定于 `tests/test_r25_c_11_media_integrity.py`。
- 环境：本机已安装 scipy 1.18.1（SA-2b 获授权安装）；测试不依赖 scipy
  是否存在（失败路径用 monkeypatch 强制注入）。
- **诚实边界**：构建期（`core/motion_builder.py`）的 PNG 重提取
  `except: pass` 与 fabricate 引用属红线文件，本轮未改动；上述修复
  覆盖解析侧与诊断面。`.moti` 级别的媒体引用完整性校验仍需后续轮次
  在 motion_builder 域内闭合。

### 问题 3（P2）：缺字标记仅存在于 JSON → 数据层已闭合，GUI 待 SA-3

- 数据层：`marked_text` / `missing_glyph_visible_marker` /
  `highlight_missing_font` 已是 `PSDLayerInfo` 一等字段（`.marked_text`
  属性 + `to_dict()` 序列化）；诊断 `summary` 与解析结果顶层新增机器
  可核查计数器 `missing_glyph_layers`（应用了 □ 可见标记的文本层数），
  由 `tests/test_r25_c_10_missing_font.py::test_missing_glyph_counter_and_first_class_marked_text` 锁定。
- **诚实披露**：`.moti` 文本写入原始 `info.text`（motion_builder 属
  红线，未改动）；GUI 侧徽章 / 悬浮提示 / 诊断面板高亮的**接线归 SA-3
  的 `gui/` 域**，本轮只闭合数据层。用户可见的缺字呈现（GUI 高亮与
  Motion 内 □ 标记文本）仍需 SA-3 / 后续 motion_builder 轮次接线后
  才算端到端闭合。
