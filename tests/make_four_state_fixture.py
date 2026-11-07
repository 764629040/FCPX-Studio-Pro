"""
生成 tests/data/four_state.psd —— 四态字体诊断固定夹具。

背景：独立审核 A-7 指出 tests/data/ 缺少 four_state.psd，
导致「四态徽章同屏」无法被第三方复现。

本脚本以 tests/data/complex_layers.psd 为基底（保留其真实文本图层结构，
包括 90° 竖排 transform），改写每个文本图层的 FontSet，使其分别命中：

  1. complete         —— PingFangSC-Regular（系统已装，中文覆盖完整）
  2. partial_missing  —— Helvetica（系统已装，但缺中文字形）
  3. font_missing     —— CormorantInfant-Regular（系统未安装，仅 CormorantGaramond 变体）
  4. unverifiable     —— 通过 monkeypatch 模拟 AppKit 不可用时的分支，
                          在正常环境下该图层用已安装字体验证其"有字体"路径

用法：python3 tests/make_four_state_fixture.py
产物：tests/data/four_state.psd（确定性生成，可重复）
"""
import os
import sys
import shutil

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from psd_tools import PSDImage

# 基底：vertical_wedding_9_16.psd 含 8 个文本图层，足够承载四态
BASE_PSD = os.path.join(TESTS_DIR, "data", "vertical_wedding_9_16.psd")
OUT_PSD = os.path.join(TESTS_DIR, "data", "four_state.psd")

# 四态目标字体（按基底 PSD 的文本图层顺序逐个指定）
# 基底 vertical_wedding_9_16.psd 的 8 个文本图层依次为：
#   0 领衔呈现(中文) 1 lead the presentation(英文) 2 新娘朱永宏(中文) 3 THE BRIDE(英文)
#   4 新郎陈晗(中文) 5 THE GROOM(英文) 6 镇雄(中文) 7 CITY(英文)
# 四态必须落在"能真实触发该状态"的图层上：
#   complete        -> 已装字体 + 覆盖该文本（PingFang 配中文）
#   partial_missing -> 已装字体但缺该文本字形（Helvetica 配中文）
#   font_missing    -> 系统未安装字体（CormorantInfant-Regular 配英文）
#   unverifiable    -> 只能在无 AppKit 环境出现，正常环境用已装字体占位，
#                      由 tests/test_four_state_fixture.py 在无 AppKit 下验证其归属
STATE_FONTS = [
    ("complete", "PingFangSC-Regular"),          # 图层 0 中文
    ("complete", "Helvetica"),                    # 图层 1 英文
    ("partial_missing", "Helvetica"),             # 图层 2 中文 + 西文字体 -> 缺字形
    ("complete", "PingFangSC-Regular"),           # 图层 3 英文（PingFang 含拉丁字形）
    ("font_missing", "CormorantInfant-Regular"),  # 图层 4 中文 + 未装字体
    ("font_missing", "CormorantInfant-Regular"),  # 图层 5 英文 + 未装字体
    ("partial_missing", "Helvetica"),             # 图层 6 中文 -> 缺字形
    ("complete", "Helvetica"),                    # 图层 7 英文
]


def build():
    if not os.path.isfile(BASE_PSD):
        raise SystemExit(f"基底 PSD 不存在: {BASE_PSD}")

    psd = PSDImage.open(BASE_PSD)
    type_layers = [l for l in psd.descendants() if l.kind == "type"]
    if len(type_layers) < len(STATE_FONTS):
        raise SystemExit(
            f"基底仅有 {len(type_layers)} 个文本图层，不足以构造 {len(STATE_FONTS)} 态"
        )

    for (state, font_name), layer in zip(STATE_FONTS, type_layers):
        rd = layer.resource_dict
        font_set = rd.get("FontSet")
        if font_set is None:
            raise SystemExit(f"图层 {layer.name} 无 FontSet，无法改写")
        # 首个条目即 StyleRun 中 Font=0 所引用的字体。
        # 注意：不要改写 layer.text —— psd-tools 会因引擎描述符结构失配
        # 在 save() 时抛 AttributeError。文本内容保持基底原样即可，
        # 四态差异完全由字体名承载。
        # FontSet[i]["Name"] 是 psd_tools 的 String 包装类型，
        # 直接赋纯 str 会在 save() 序列化时崩（'str' object has no attribute 'write'），
        # 必须改写其 .value 以保留包装类型。
        font_set[0]["Name"].value = font_name

    psd.save(OUT_PSD)
    print(f"已生成: {OUT_PSD}")
    print(f"大小: {os.path.getsize(OUT_PSD)} bytes")

    # 回读校验
    check = PSDImage.open(OUT_PSD)
    for i, l in enumerate([x for x in check.descendants() if x.kind == "type"]):
        if i >= len(STATE_FONTS):
            break
        fs = l.resource_dict.get("FontSet") or []
        print(f"  图层 {l.name!r}: FontSet[0]={fs[0].get('Name') if fs else None}")


if __name__ == "__main__":
    build()
