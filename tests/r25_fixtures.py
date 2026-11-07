"""
R25 C 域测试夹具构造器
======================
用 psd_tools 在 tmp_path 内动态构造边界 PSD，避免向仓库提交二进制样本，
且保证 SA-4 重跑测试时可复现。

覆盖 C-8 四类边界：
- 空组 (empty group)
- 全隐藏层 (all-hidden)
- 超长段落 (very long paragraph，通过改写 TypeLayer 的 Txt 实现)
- 嵌套 5 层 (nested 5 levels)

以及 PNG 降级 / 智能对象 / 多行段落等辅助夹具。
"""
import os
import shutil
import numpy as np
from psd_tools import PSDImage
from psd_tools.psd.descriptor import String

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
DATA_DIR = os.path.join(TESTS_DIR, "data")
COMPLEX_PSD = os.path.join(DATA_DIR, "complex_layers.psd")


def _new_canvas(w=300, h=300):
    return PSDImage.new("RGB", (w, h))


def _pixel_layer(parent, name, color=(255, 0, 0, 255), size=(50, 50)):
    arr = np.zeros((size[1], size[0], 4), dtype=np.uint8)
    arr[:, :, 0] = color[0]
    arr[:, :, 1] = color[1]
    arr[:, :, 2] = color[2]
    arr[:, :, 3] = color[3]
    # R28 / A-57：psd_tools 1.26 提供 create_pixel_layer_from_array(ndarray)，
    # 1.24 的 create_pixel_layer 只接受 PIL.Image（同一语义），这里做版本兼容。
    if hasattr(parent, "create_pixel_layer_from_array"):
        return parent.create_pixel_layer_from_array(arr, name=name)
    from PIL import Image
    return parent.create_pixel_layer(Image.fromarray(arr, mode="RGBA"), name=name)


def build_empty_group_psd(dst_path):
    """空组 + 一个普通图层。空组本身是一个图层节点，必须被计入 skipped。"""
    psd = _new_canvas()
    psd.create_group(name="EmptyGroup")
    _pixel_layer(psd, "NormalLayer", color=(0, 200, 0, 255))
    psd.save(dst_path)
    return dst_path


def build_all_hidden_psd(dst_path, n=4):
    """全部图层均隐藏。每个隐藏层必须计入 skipped（显式忽略），不得静默消失。"""
    psd = _new_canvas()
    for i in range(n):
        layer = _pixel_layer(psd, f"Hidden_{i}", color=(i * 40 % 255, 100, 200, 255))
        layer.visible = False
    psd.save(dst_path)
    return dst_path


def build_nested_groups_psd(dst_path, depth=5):
    """嵌套 depth 层的组，最内层放一个像素层。验证层级与守恒。"""
    psd = _new_canvas()
    parent = psd
    for i in range(depth):
        parent = parent.create_group(name=f"Lvl{i}")
    _pixel_layer(parent, "DeepLeaf", color=(255, 128, 0, 255))
    # 顶层再放一个普通层，避免文件只有组
    _pixel_layer(psd, "TopLeaf", color=(0, 128, 255, 255))
    psd.save(dst_path)
    return dst_path


def _mutate_first_text_layer(src_psd, dst_path, new_text):
    """以 src_psd 为基底，改写第一个文本图层的 Txt 为 new_text 并保存到 dst_path。"""
    psd = PSDImage.open(src_psd)
    tl = next((l for l in psd.descendants() if l.kind == "type"), None)
    if tl is None:
        raise RuntimeError(f"{src_psd} 中无文本图层，无法构造文本夹具")
    td = tl._data.text_data
    td[b"Txt "] = String(new_text)
    psd.save(dst_path)
    return dst_path


def build_long_paragraph_psd(dst_path, length=6000):
    """超长段落：单文本图层，文本长度约 length 字符。"""
    text = "段落文字用于验证图层守恒与缺字标记：" + ("内容保持不截断。ABCDEFG 一二三四五 " * 120)
    text = (text * (length // max(1, len(text)) + 1))[:length]
    return _mutate_first_text_layer(COMPLEX_PSD, dst_path, text)


def build_multiline_paragraph_psd(dst_path):
    """多行段落：含多个换行，验证段落文字不塌成单行。"""
    text = "第一行标题\n第二行副标题\n第三行说明文字\n第四行落款与日期"
    return _mutate_first_text_layer(COMPLEX_PSD, dst_path, text)


def build_simple_shape_like_psd(dst_path):
    """构造一个可降级为 PNG 的非文本层（像素层），用于 C-9 PNG 降级路径。"""
    psd = _new_canvas()
    _pixel_layer(psd, "PixelForPng", color=(120, 60, 200, 255), size=(80, 80))
    psd.save(dst_path)
    return dst_path


def copy_complex_psd(dst_path):
    """复制 complex_layers.psd 到 dst_path（含智能对象/形状/组/文本/描边）。"""
    shutil.copyfile(COMPLEX_PSD, dst_path)
    return dst_path


def build_visible_smartobject_psd(dst_path):
    """以 complex_layers 为基底，把**所有**智能对象改为可见并保存。
    用于验证智能对象的"展平为位图"路径（默认 smart_object_policy=flatten）。
    注意：complex_layers 内有多个智能对象（含隐藏的占位对象）；flatten 路径的
    断言对象是"全部可见智能对象均 degraded"，因此这里必须全部置为可见，
    不能只改第一个——否则残留的隐藏 SO 会走"隐藏图层忽略"分支，混入断言。
    该智能对象带描边，composite 需要 scipy；本环境若无 scipy，
    展平出的 PNG 可能缺失，但图层仍应被记为 degraded（绝不静默丢弃）。
    """
    psd = PSDImage.open(COMPLEX_PSD)
    so_layers = [l for l in psd.descendants() if l.kind == "smartobject"]
    if not so_layers:
        raise RuntimeError("complex_layers.psd 中无智能对象")
    for so in so_layers:
        so.visible = True
    psd.save(dst_path)
    return dst_path
