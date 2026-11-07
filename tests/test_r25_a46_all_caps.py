"""
R25-A46 全大写 (id="12") 参数注入回归测试

背景:
  R24 确认：坏构建 `14fa354d…` (docs/r24_evidence/legacy_bad_build_14fa354d/01_领衔呈现/01_领衔呈现.moti)
  在文本层 <style> 中【完全缺失】 name="全部大写" / id="12" 参数，且 Media/ 为空。
  当 Motion/FCPX 加载该模板时，TXTextLayout::applyAllCaps 读取 id=12，
  OZChannel::getValueAsDouble 命中空指针 → SIGSEGV（11-02 崩溃日志印证）。

  修复已存在于 core/motion_builder.py (build_moti, 文本层分支 ~L348-366)：
  为每个文本层 <style> 无条件注入 parameter[@id="12"][name="全部大写"]，且插在 id="81" 之后。

本测试覆盖:
  ① 构建含 8 个文本层的模板，解析 .moti，断言每个 <style> 含 parameter[@id="12"] 且 name="全部大写"。
  ② 断言 id="12" 是 id="81" 的【直接后一个兄弟】。
  ③ 断言 id="12" 数量 == 文本层数量。
  ④ 负样本：真实坏构建 name="全部大写" 计数 == 0；新构建好模板计数 == 文本层数量。
  ⑤ 结构完整性：注入后 .moti 仍可 ET.parse；总 <parameter> 数不低于坏构建基线（注入只增不减）。
  ⑥ 红/绿有效性证明见 docs/r25_evidence/test_goes_red.txt（临时注释注入块 → 红；还原 → 绿）。

注意：本测试不触碰 ~/Movies，不在只读卷写入；所有临时产物落在 pytest tmp_path。
"""
import os
import sys
import xml.etree.ElementTree as ET

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.motion_builder import MotionBuilder  # noqa: E402

# 真实坏构建（R24 证据）：缺少 id=12，Media 空
BAD_MOTI = os.path.join(
    PROJECT_ROOT,
    "docs", "r24_evidence", "legacy_bad_build_14fa354d",
    "01_领衔呈现", "01_领衔呈现.moti",
)

N_TEXT_LAYERS = 8  # 对齐 T01_领衔呈现_竖版 (8 个文本层)


class _TextLayer:
    """最小可用的纯文本图层信息对象（不挂 fallback_png_path → 走文本层分支）。"""
    def __init__(self, name, text, font_size=72.0, tracking=0.0,
                 motion_pos=(0.0, 0.0), visible=True, is_published=False,
                 font_name="Helvetica"):
        self.kind = "type"            # 文本层（否则会被识别为媒体层）
        self.name = name
        self.text = text
        self.font_size = font_size    # 必须：round(info.font_size, 2)
        self.tracking = tracking      # 必须：round(info.tracking, 4)
        self.motion_pos = motion_pos  # 必须：mx, my = info.motion_pos
        self.visible = visible        # 必须存在（用于 if not info.visible）
        self.is_published = is_published
        self.font_name = font_name
        self.fallback_png_path = None  # 关键：保证不是媒体层


def _make_text_layers(n=N_TEXT_LAYERS):
    return [
        _TextLayer(
            name=f"L{i:02d}",
            text=f"标题文本{i:02d}",
            font_size=60.0 + i,
            tracking=0.5 * i,
            motion_pos=(0.0, 0.0),
        )
        for i in range(1, n + 1)
    ]


def _build_good_template(tmp_path, n=N_TEXT_LAYERS, template_name="r25_a46_tpl"):
    """通过 MotionBuilder.build_template_atomic 构建一个纯文本层模板包。"""
    layers = _make_text_layers(n)
    mb = MotionBuilder()
    out_dir = str(tmp_path / "out")
    res = mb.build_template_atomic(
        layers_info=layers,
        output_dir=out_dir,
        template_name=template_name,
        # 不传 psd_path：走透明占位缩略图，不触发 PSD 解析；不挂媒体贴图
    )
    assert res["status"] == "ok", f"build_template_atomic 返回非 ok: {res}"
    moti_path = os.path.join(out_dir, f"{template_name}.moti")
    assert os.path.isfile(moti_path), f"未生成 .moti: {moti_path}"
    return out_dir, moti_path, layers


def _styles(root):
    return root.findall(".//style")


def _count_param(root, attr, value):
    return sum(1 for p in root.findall(".//parameter") if p.attrib.get(attr) == value)


# ─────────────────────────────────────────────────────────────────────────────
# ① 每个文本层 <style> 必须含 id="12" 且 name="全部大写"
# ─────────────────────────────────────────────────────────────────────────────
def test_text_layers_contain_id12(tmp_path):
    _, moti_path, layers = _build_good_template(tmp_path, N_TEXT_LAYERS)
    tree = ET.parse(moti_path)
    root = tree.getroot()
    styles = _styles(root)
    assert len(styles) == len(layers), (
        f"文本层 style 数量不符: 期望 {len(layers)}，实际 {len(styles)}"
    )
    for si, style in enumerate(styles, 1):
        p = style.find("parameter[@id='12']")
        assert p is not None, f"style #{si} 缺少 parameter[@id='12']"
        assert p.attrib.get("name") == "全部大写", (
            f"style #{si} id=12 的 name 应为 '全部大写'，实际 '{p.attrib.get('name')}'"
        )


# ─────────────────────────────────────────────────────────────────────────────
# ② id="12" 必须是 id="81" 的直接后一个兄弟（顺序）
# ─────────────────────────────────────────────────────────────────────────────
def test_id12_immediately_after_id81(tmp_path):
    _, moti_path, _ = _build_good_template(tmp_path, N_TEXT_LAYERS)
    tree = ET.parse(moti_path)
    root = tree.getroot()
    for si, style in enumerate(_styles(root), 1):
        params = style.findall("parameter")
        ids = [p.attrib.get("id") for p in params]
        assert "81" in ids, f"style #{si} 缺少 id='81' 锚点"
        assert "12" in ids, f"style #{si} 缺少 id='12'"
        assert ids.index("12") == ids.index("81") + 1, (
            f"style #{si}: id='12' 未紧邻 id='81' 之后 (顺序={ids})"
        )


# ─────────────────────────────────────────────────────────────────────────────
# ③ id="12" 数量必须 == 文本层数量
# ─────────────────────────────────────────────────────────────────────────────
def test_id12_count_equals_text_layer_count(tmp_path):
    n = N_TEXT_LAYERS
    _, moti_path, _ = _build_good_template(tmp_path, n)
    tree = ET.parse(moti_path)
    root = tree.getroot()
    c12 = _count_param(root, "id", "12")
    cname = _count_param(root, "name", "全部大写")
    assert c12 == n, f"id='12' 数量应为 {n}，实际 {c12}"
    assert cname == n, f"name='全部大写' 数量应为 {n}，实际 {cname}"


# ─────────────────────────────────────────────────────────────────────────────
# ④ 负样本：真实坏构建 全部大写==0；新构建好模板 == 文本层数量
# ─────────────────────────────────────────────────────────────────────────────
def test_negative_bad_build_zero_vs_good_build_n(tmp_path):
    assert os.path.isfile(BAD_MOTI), f"坏构建 .moti 缺失: {BAD_MOTI}"

    btree = ET.parse(BAD_MOTI)
    broot = btree.getroot()
    bad_name = _count_param(broot, "name", "全部大写")
    bad_id12 = _count_param(broot, "id", "12")
    assert bad_name == 0, f"坏构建 name='全部大写' 应为 0，实际 {bad_name}"
    assert bad_id12 == 0, f"坏构建 id='12' 应为 0，实际 {bad_id12}"
    # 坏构建确实含有文本层 style（证明其“本应有” id=12），只是缺失
    bad_styles = _styles(broot)
    assert len(bad_styles) > 0, "坏构建应包含文本层 style"

    # 新构建的好模板
    n = N_TEXT_LAYERS
    _, moti_path, _ = _build_good_template(tmp_path, n)
    gtree = ET.parse(moti_path)
    groot = gtree.getroot()
    good_id12 = _count_param(groot, "id", "12")
    good_name = _count_param(groot, "name", "全部大写")
    assert good_id12 == n, f"好构建 id='12' 应为 {n}，实际 {good_id12}"
    assert good_name == n, f"好构建 name='全部大写' 应为 {n}，实际 {good_name}"


# ─────────────────────────────────────────────────────────────────────────────
# ⑤ 结构完整性：注入后 ET.parse 成功；总 <parameter> 数不低于坏构建基线
# ─────────────────────────────────────────────────────────────────────────────
def test_structural_integrity_after_injection(tmp_path):
    assert os.path.isfile(BAD_MOTI), f"坏构建 .moti 缺失: {BAD_MOTI}"
    btree = ET.parse(BAD_MOTI)
    broot = btree.getroot()
    bad_total = len(broot.findall(".//parameter"))

    n = N_TEXT_LAYERS
    _, moti_path, _ = _build_good_template(tmp_path, n)

    # 重新解析必须成功（无异常）
    tree = ET.parse(moti_path)
    root = tree.getroot()
    assert root.tag == "ozml", f"根节点应为 ozml，实际 {root.tag}"
    assert root.find("scene") is not None, "缺少 scene 根结构"

    good_total = len(root.findall(".//parameter"))

    # 注入只允许“增加”参数，绝不允许“减少”；基线=坏构建（缺 8 个 id=12）
    assert good_total >= bad_total, (
        f"注入后总 <parameter> 数下降: good={good_total} < bad={bad_total}"
    )
