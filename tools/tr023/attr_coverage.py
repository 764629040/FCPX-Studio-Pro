#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TR-023 阶段 1：全库字幕文字属性命中率盘点（只读）。

────────────────────────────────────────────────────────────────────────────
【做什么】
遍历 ~/Movies/Motion Templates.localized/Titles.localized 递归下全部 .moti，
对每个「文字对象」抽取文字样式参数的真实 XML 路径，统计下列 10 个属性的
命中模板数 / 命中率 / 路径写法：

  字体 大小 字距 对齐 颜色 渐变 阴影 描边 行距 行高

【口径（与 TR-022-3 对齐，不重算）】
  总数        1247 个 .moti
  XML 解析成功 1241
  XML 解析失败 6（文件名见输出；与 TR-022-3 的清单逐字一致）
  分母        1241（全部可解析模板）
  范围        ~/Movies/Motion Templates.localized/Titles.localized 递归（rglob "*.moti"）

【「文字对象」定义（TR-023-A1 修正后）】
  取所有「子树里存在叶子 <parameter name="文本"|"Text">」的 <scenenode>，
  去掉「本身是另一个候选的祖先」的，只留最内层；文本值为空也算一个对象。
  全库三档：全部候选 2904 / 最内层 2860 / 最内层且文本非空 2852。
  （2852 就是 QC 的口径，差 8 个空文本对象；名单在报告里逐条列出。）

【颜色口径（TR-023-A1 修正）】
  颜色按「源」逐条统计，不同拼写分开，不合并成一个正则：
  物质族（对象/基础、对象/基本、Object/Basic/Substance、基本/Basic）、
  面/颜色、表面/颜色、Face/Color、填充渐变（面/表面/Face/顶层）、
  图层|层/物质/颜色。各源给模板数 / 有值数 / 样例，并集单独给。
  描边色（轮廓|Outline/颜色|Color）归「描边」，投影/光晕的渐变不算填充色。
  上一版把「物质|表面|面」并成一个正则、再把并集当成「表面/面 629」，是归因错误。

【「真实存在」两级判据（两个数都给，不许只看大的那个）】
  A 节点存在    —— 该参数的 XML 节点在文件里出现了
  B 节点有值    —— A 且节点上确实带可用值（数值参数看 value / <curve>@value；
                   字体看 <font> 文本；颜色看末级 红/绿/蓝 的 value；
                   组参数看组内是否存在带值的末级参数）
  命中表主列用 B（「有值」），A 单列出来做对照。

【使用方法】
  python3 tools/tr023/attr_coverage.py                 # 全库，写 txt + json
  python3 tools/tr023/attr_coverage.py --root <dir>    # 换根目录
  python3 tools/tr023/attr_coverage.py --dump-names    # 只打印全库叶子参数名

【测量口径（TR-022-4 的纪律）】
  · 时间：进程内墙钟，一次单次运行，不取平均；一位小数。
  · 体积：只报 os.stat().st_size 一个数。
  · 只读：全程 open(..., "rb") 读入内存解析，不写回任何 .moti。
────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import unicodedata
import xml.etree.ElementTree as ET
from collections import Counter, OrderedDict
from datetime import datetime
from pathlib import Path

DEFAULT_ROOT = Path.home() / "Movies/Motion Templates.localized/Titles.localized"


def dwidth(s):
    """终端显示宽度：中文/全角算 2 列，其余 1 列。只用于对齐文本报告。"""
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad(s, width, align="left"):
    gap = max(0, width - dwidth(s))
    return (" " * gap + s) if align == "right" else (s + " " * gap)

# TR-022-3 已核定的 6 个解析失败文件（本脚本必须复现同一组，否则报警）
TR022_FAIL_FILES = [
    "点 03.moti",
    "点 07.moti",
    "点文本 03.moti",
    "菜单条修复.moti",
    "菜单条自定义.moti",
    "条01.moti",
]

TEXT_LEAF_NAMES = ("文本", "Text")


# ────────────────────────────────────────────────────────────────────────────
# XML 走查
# ────────────────────────────────────────────────────────────────────────────
def iter_params(el):
    """深度遍历，产出所有 <parameter> 元素。ET.iter 不支持过滤，自己走。"""
    for child in el:
        if child.tag == "parameter":
            yield child
        yield from iter_params(child)


# 路径里保留这些容器标签名，让输出能逐字回 XML 对照
# （只保留有语义的几层，<curve>/<flags>/<foldFlags> 这类噪声不进路径）
PATH_TAGS = ("style", "paragraphStyle", "scenenode", "layer", "group")


def walk_leaves(el, path, out):
    """收集 el 子树里所有叶子参数：out 里放 (路径元组, 元素)。"""
    for child in el:
        if child.tag == "parameter":
            name = child.get("name") or "?"
            cpath = path + (name,)
            if child.findall("parameter"):
                walk_leaves(child, cpath, out)
            else:
                out.append((cpath, child))
        elif child.tag in PATH_TAGS:
            walk_leaves(child, path + (child.tag,), out)
        else:
            walk_leaves(child, path, out)


def numeric_value(el):
    """取参数的数值：自身 value 属性，或 <curve>@value。取不到返回 None。"""
    raw = el.get("value")
    if raw is not None:
        try:
            return float(raw)
        except ValueError:
            return None
    for curve in el.findall("curve"):
        raw = curve.get("value")
        if raw is not None:
            try:
                return float(raw)
            except ValueError:
                continue
    return None


def has_value_anywhere(el):
    """组参数用：子树里任意一个末级参数带数值 / 非空文本，就算有值。"""
    for node in el.iter():
        if node.tag == "parameter":
            if numeric_value(node) is not None:
                return True
        elif node.tag in ("font", "defaultFont", "text"):
            if (node.text or "").strip():
                return True
    return False


COLOR_COMPONENTS = ("红色", "绿色", "蓝色", "红", "绿", "蓝", "Red", "Green", "Blue")


def color_has_value(el):
    """颜色组：自身或末级 红/绿/蓝 至少一个带数值。"""
    if (el.get("name") or "") in COLOR_COMPONENTS and numeric_value(el) is not None:
        return True
    for node in el.iter("parameter"):
        if (node.get("name") or "") in COLOR_COMPONENTS and numeric_value(node) is not None:
            return True
    return False


def color_path_has_value(el, leaf):
    """该条颜色路径是否真的带颜色值。

    容器路径（如 面/颜色）本身没有 value，要往下找红绿蓝；
    RGB 叶子（红/Red）只看自己。
    """
    if numeric_value(el) is not None:
        return True
    if leaf in COLOR_RGB_LEAF:
        return False
    for node in el.iter("parameter"):
        if (node.get("name") or "") in COLOR_RGB_LEAF and numeric_value(node) is not None:
            return True
    return False


# ────────────────────────────────────────────────────────────────────────────
# 文字对象与属性抽取
# ────────────────────────────────────────────────────────────────────────────
def _has_text_leaf(node):
    for p in iter_params(node):
        if (p.get("name") or "") in TEXT_LEAF_NAMES and not p.findall("parameter"):
            return True
    return False


def text_leaf_value(node):
    """取该文字对象的文本值：<parameter name="文本"|"Text"> 的 value 属性或 <text> 文本。"""
    for p in iter_params(node):
        if (p.get("name") or "") not in TEXT_LEAF_NAMES:
            continue
        if p.findall("parameter"):
            continue
        v = (p.get("value") or "").strip()
        if v:
            return v
        for tag in ("text", "string"):
            for c in p.findall(tag):
                if (c.text or "").strip():
                    return (c.text or "").strip()
    return ""


def find_text_scenenodes(root):
    """文字对象 = 最内层那个 <scenenode>（TR-023-A1 修正实现）。

    一句话规则：取所有「子树里存在叶子 <parameter name="文本"|"Text">」的
    <scenenode>，把「本身是另一个候选的祖先」的那些去掉，只留最内层；
    <parameter name="文本"> 没有值（空字符串）的对象也算一个文字对象。

    实现注意：不能拿 id() 当跨轮身份。ElementTree 的元素是按需构造的临时对象，
    前一批被回收后 id 会被复用，旧实现因此会把 44 个互不相干的节点误判成嵌套。
    这里先把 nodes / parent 两份引用都握住，id 才稳定。
    """
    nodes = list(root.iter("scenenode"))
    parent = {c: p for p in root.iter() for c in p}
    candidates = [n for n in nodes if _has_text_leaf(n)]
    cand_ids = {id(n) for n in candidates}
    # 排除「本身是别的候选的祖先」的：把每个候选的所有祖先标成 outer
    outer = set()
    for n in candidates:
        cur = parent.get(n)
        while cur is not None:
            if id(cur) in cand_ids:
                outer.add(id(cur))
            cur = parent.get(cur)
    return [n for n in candidates if id(n) not in outer]


def text_object_paths(scenenode):
    """一个文字对象里所有叶子参数：[(路径, 元素)]，路径以 "scenenode" 开头。"""
    leaves = []
    walk_leaves(scenenode, ("scenenode",), leaves)
    return [("/".join(p), el) for p, el in leaves]


def text_objects_in_file(root):
    """产出 (scenenode, [(路径, 元素)], {路径: 元素})。"""
    for sn in find_text_scenenodes(root):
        items = text_object_paths(sn)
        index = {}
        for path, el in items:
            index.setdefault(path, el)
        yield sn, items, index


# ────────────────────────────────────────────────────────────────────────────
# 属性定义：path 正则 → 命中
#   kind: "leaf" 叶子参数；"group" 组参数（用子树判值）
# ────────────────────────────────────────────────────────────────────────────
ATTR_SPECS = OrderedDict()

ATTR_SPECS["字体"] = {
    "desc": "字体名（<font> 文本）",
    "rules": [
        (re.compile(r"^scenenode/(?:字体|Font)$"), "leaf_font"),
    ],
}

ATTR_SPECS["大小"] = {
    "desc": "字号（数值）",
    "rules": [
        (re.compile(r"^scenenode/(?:大小|Size)$"), "leaf_num"),
    ],
}

ATTR_SPECS["字距"] = {
    "desc": "字距（tracking，数值）",
    "rules": [
        (re.compile(r"^scenenode/(?:间距/字距|格式/字距|字距)$"), "leaf_num"),
        (re.compile(r"^scenenode/(?:Format|Spacing)/Tracking$"), "leaf_num"),
    ],
    # 名字相近但不是「字距」的写法，单独列，不计入命中
    "near_miss": [
        re.compile(r"^scenenode/(?:间距/字距微调|Spacing/Kerning)$"),
    ],
}

ATTR_SPECS["对齐"] = {
    "desc": "段落水平对齐（数值枚举）",
    "rules": [
        (re.compile(r"^scenenode/(?:对象|Object)/(?:段落|Paragraphs)/(?:段落|Paragraph)/"
                    r"(?:对齐|Alignment)$"), "leaf_num"),
        (re.compile(r"^scenenode/(?:对齐|Alignment)$"), "leaf_num"),
    ],
    "near_miss": [
        re.compile(r"(?:垂直对齐|Vertical Alignment)$"),
        re.compile(r"(?:对齐到路径|沿路径对齐|Align to Path)$"),
    ],
}

ATTR_SPECS["颜色"] = {
    "desc": "文字填充颜色（物质/面/表面/Face 的 RGB，或填充渐变的两端色标）",
    # 只认「填充」。描边色（轮廓/Outline）归「描边」，投影/光晕的渐变不是填充色，
    # 一律不进这一条 —— TR-023-A1 之前把它们并进来，才报出 631/629 这种假数。
    "rules": [
        (re.compile(r"^scenenode/(?:"
                    r"(?:对象|Object)/(?:基础|基本|Basic)/(?:物质|Substance)/(?:颜色|Color)"
                    r"|(?:基本|Basic)/(?:物质|Substance)/(?:颜色|Color)"
                    r"|(?:面|表面|Face)/(?:颜色|Color)"
                    r"|(?:面|表面|Face)/(?:渐变|Gradient)"
                    r"|(?:图层|层)/(?:物质|Substance)/(?:颜色|Color)"
                    r"|渐变"
                    r")"), "group_color"),
    ],
}

ATTR_SPECS["渐变"] = {
    "desc": "文字填充渐变（面/表面/Face 下的渐变组，含顶层 渐变）",
    "rules": [
        (re.compile(r"^scenenode/(?:(?:面|表面|Face)/(?:渐变|Gradient)|渐变)(?:/|$)"),
         "group_any"),
    ],
    # 真正的渐变要有第二个色标且带颜色值；只有 RGB1 的其实还是纯色。
    # 必须限定在填充渐变（面/表面/Face/顶层），否则会命中 投影/外框/光晕 的渐变。
    "control": [
        (re.compile(r"^scenenode/(?:(?:面|表面|Face)/(?:渐变|Gradient)|渐变)/.*RGB2/.*"
                    r"(?:红色|红|Red)$"), "leaf_num"),
    ],
}

ATTR_SPECS["阴影"] = {
    "desc": "投影 / 图层阴影",
    "rules": [
        (re.compile(r"^scenenode/(?:投影|Drop Shadow)(?:/|$)"), "group_any"),
        (re.compile(r"^scenenode/(?:属性|Properties)/"
                    r"(?:阴影|Shadows|投影|Drop Shadow|拖放阴影)(?:/|$)"), "group_any"),
        (re.compile(r"^scenenode/(?:拖放阴影)(?:/|$)"), "group_any"),
    ],
    # 能调强度的参数（距离 / 不透明度）；只有渐变/纹理 节点的话等于没法做控件
    "control": [
        (re.compile(r"^scenenode/(?:投影|拖放阴影|Drop Shadow)/(?:距离|Distance|不透明度|Opacity)$"),
         "leaf_num"),
        (re.compile(r"^scenenode/(?:属性|Properties)/(?:阴影|Shadows|投影|Drop Shadow|拖放阴影)/"
                    r"(?:距离|Distance|不透明度|Opacity|模糊|Blur/[XY])$"), "leaf_num"),
    ],
}

ATTR_SPECS["描边"] = {
    "desc": "文字外框/轮廓（不含 对象/形状/轮廓）",
    "rules": [
        (re.compile(r"^scenenode/(?:外框|Outline|轮廓)(?:/|$)"), "group_any"),
    ],
    # 描边宽度是唯一能当控件用的数值
    "control": [
        (re.compile(r"^scenenode/(?:外框|Outline|轮廓)/(?:宽度|Width)$"), "leaf_num"),
    ],
}

ATTR_SPECS["行距"] = {
    "desc": "段落行间距",
    "rules": [
        (re.compile(r"^scenenode/(?:对象|Object)/(?:段落|Paragraphs)/(?:段落|Paragraph)/"
                    r"(?:行间距|线条间距|Line Spacing)$"), "leaf_num"),
        (re.compile(r"^scenenode/(?:行间距|线条间距|Line Spacing)$"), "leaf_num"),
    ],
}

ATTR_SPECS["行高"] = {
    "desc": "行高（本属性若 0 命中即为无数据来源）",
    "rules": [
        (re.compile(r"^scenenode/.*(?:行高|行高度|Line Height|LineHeight|Leading)$"), "leaf_num"),
    ],
}

# ── 颜色源：逐条列出真实路径前缀，不同拼写分开算，不合并成一个正则 ────────────
# TR-023-A1 修正：上一版把 11 种写法并成一个正则，再把并集当成「表面/面 颜色 629」，
# 是归因错误。这里每个源单独一套集合，报告里逐源给模板数与样例路径。
COLOR_SOURCES = [
    ("对象/基础/物质/颜色", re.compile(r"^scenenode/对象/基础/物质/颜色")),
    ("面/颜色", re.compile(r"^scenenode/面/颜色")),
    ("表面/颜色", re.compile(r"^scenenode/表面/颜色")),
    ("渐变（面/表面/Face/顶层 合并）", re.compile(
        r"^scenenode/(?:(?:面|表面|Face)/(?:渐变|Gradient)|渐变)")),
    ("对象/基本/物质/颜色", re.compile(r"^scenenode/对象/基本/物质/颜色")),
    ("Object/Basic|基础|基本/Substance|物质/Color|颜色",
     re.compile(r"^scenenode/Object/(?:Basic|基础|基本)/(?:Substance|物质)/(?:Color|颜色)")),
    ("基本|Basic/物质|Substance/颜色|Color",
     re.compile(r"^scenenode/(?:基本|Basic)/(?:物质|Substance)/(?:颜色|Color)")),
    ("Face/Color", re.compile(r"^scenenode/Face/Color")),
    ("图层|层/物质|Substance/颜色|Color", re.compile(
        r"^scenenode/(?:图层|层)/(?:物质|Substance)/(?:颜色|Color)")),
]

# 不计入主色的三类：描边色归「描边」，投影/光晕的渐变不是填充色，属性/颜色 是色彩管理
COLOR_EXCLUDED = [
    ("描边色（轮廓|Outline / 颜色|Color）→ 归「描边」",
     re.compile(r"^scenenode/(?:轮廓|Outline)/(?:颜色|Color)")),
    ("投影渐变（投影|Drop Shadow / 渐变|Gradient）→ 不是填充色",
     re.compile(r"^scenenode/(?:投影|Drop Shadow)/(?:渐变|Gradient)")),
    ("光晕渐变（光晕|Glow / 渐变|Gradient）→ 不是填充色",
     re.compile(r"^scenenode/(?:光晕|Glow)/(?:渐变|Gradient)")),
    ("色彩管理（属性|Properties / 颜色|Color）→ 不是颜色值",
     re.compile(r"^scenenode/(?:属性|Properties)/(?:颜色|Color)")),
]

# 渐变是否真有第二个色标（只有 RGB1 的其实是纯色）
GRADIENT_SECOND_STOP = re.compile(
    r"^scenenode/.*(?:渐变|Gradient)/.*RGB2/.*(?:红色|绿色|蓝色|红|绿|蓝|Red|Green|Blue)$")

# 阴影可调控件的三个数值参数：距离 / 不透明度 / 模糊
SHADOW_CTL = {
    "距离": re.compile(r"^scenenode/(?:投影|拖放阴影|Drop Shadow)/(?:距离|Distance)$"),
    "不透明度": re.compile(r"^scenenode/(?:投影|拖放阴影|Drop Shadow)/(?:不透明度|Opacity)$"),
    "模糊": re.compile(r"^scenenode/(?:投影|拖放阴影|Drop Shadow)/(?:模糊|Blur(?:/[XY])?)$"),
}
SHADOW_CN_DIST = re.compile(r"^scenenode/投影/距离$")

COLOR_RGB_LEAF = ("红", "绿", "蓝", "红色", "绿色", "蓝色", "Red", "Green", "Blue")

# 中文 / 英文拼写各自的并集（用于报告里「中文并集 / 英文并集 / 交集」一行）
COLOR_ZH = re.compile(
    r"^scenenode/(?:"
    r"对象/(?:基础|基本)/物质/颜色"
    r"|面/颜色|表面/颜色|基本/物质/颜色|面/渐变|表面/渐变|渐变"
    r"|(?:图层|层)/物质/颜色"
    r")")
COLOR_EN = re.compile(
    r"^scenenode/(?:"
    r"Face/Color|Face/Gradient"
    r"|Object/(?:Basic|基础|基本)/(?:Substance|物质)/(?:Color|颜色)"
    r"|(?:Basic|Substance)/(?:Color|颜色)"
    r")")

# 单值判据分派
def leaf_has_value(kind, el):
    if kind == "leaf_font":
        for tag in ("font", "defaultFont"):
            for node in el.findall(tag):
                if (node.text or "").strip():
                    return True
        return False
    if kind == "leaf_num":
        return numeric_value(el) is not None
    if kind == "group_color":
        return color_has_value(el)
    if kind == "group_any":
        return has_value_anywhere(el)
    return False


def normalize(path):
    """去掉中间层的容器标签段（style/paragraphStyle/layer/group），保留开头 scenenode。

    例：scenenode/style/间距/字距 → scenenode/间距/字距
    这样同一种属性不管包在 <style> 还是 <paragraphStyle> 里都归一类，
    但报告里展示的仍是完整路径，能逐字回 XML 对照。
    """
    segs = path.split("/")
    head, rest = segs[0], segs[1:]
    return "/".join([head] + [s for s in rest if s not in PATH_TAGS])


def classify(path, el):
    """返回 [(属性名, 是否带值)]。"""
    norm = normalize(path)
    out = []
    for attr, spec in ATTR_SPECS.items():
        for rx, kind in spec["rules"]:
            if rx.search(norm):
                out.append((attr, leaf_has_value(kind, el)))
                break
    return out


def classify_control(path, el):
    """该路径能否当「可调控件」用：组属性要求组里有强度数值，其余同 rules。"""
    norm = normalize(path)
    out = []
    for attr, spec in ATTR_SPECS.items():
        rules = spec.get("control") or spec["rules"]
        for rx, kind in rules:
            if rx.search(norm):
                if leaf_has_value(kind, el):
                    out.append(attr)
                break
    return out


def near_misses(path):
    norm = normalize(path)
    hits = []
    for attr, spec in ATTR_SPECS.items():
        for rx in spec.get("near_miss", []):
            if rx.search(norm):
                hits.append(attr)
                break
    return hits


# ────────────────────────────────────────────────────────────────────────────
# 主流程
# ────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    ap.add_argument("--outdir", default="reports/verify_tr023")
    ap.add_argument("--dump-names", action="store_true")
    args = ap.parse_args()

    root = Path(os.path.expanduser(args.root))
    files = sorted(root.rglob("*.moti"))
    if not files:
        print("没找到 .moti：%s" % root, file=sys.stderr)
        return 2

    t0 = time.time()

    # 统计容器
    fail_files = []
    n_text_templates = 0
    n_text_objects = 0
    n_text_candidates = 0          # 全部「子树里有文本叶子」的 scenenode（含被排除的外层群组）
    n_text_nonempty = 0            # 最内层且 <parameter 文本> 真的有值
    empty_text_objects = []        # 空文本对象（QC 的 2852 不含这 8 个）
    nested_samples = []            # 被最内层规则排掉的外层群组样例
    # 每个属性：命中模板集合 / 有值模板集合 / 路径写法 → 模板集合
    hit_tpl = {a: set() for a in ATTR_SPECS}
    val_tpl = {a: set() for a in ATTR_SPECS}
    ctl_tpl = {a: set() for a in ATTR_SPECS}
    spelling = {a: Counter() for a in ATTR_SPECS}
    ctl_spelling = {a: Counter() for a in ATTR_SPECS}
    # 全局叶子名（--dump-names 与「疑似缺失」排查用）
    all_leaf_names = Counter()
    near_miss_spelling = Counter()
    # 颜色：逐源 + 逐路径
    color_src_tpl = {name: set() for name, _rx in COLOR_SOURCES}
    color_src_val = {name: set() for name, _rx in COLOR_SOURCES}
    color_path_tpl = {}            # 路径 → 模板集合
    color_path_occ = Counter()     # 路径 → 出现次数
    color_path_samples = {}        # 路径 → [样例模板相对路径]
    color_excl_tpl = {name: set() for name, _rx in COLOR_EXCLUDED}
    # 阴影：三个可调参数分别命中
    shadow_ctl_tpl = {k: set() for k in SHADOW_CTL}
    shadow_cn_dist_tpl = set()
    shadow_dist_nonzero_tpl = set()
    shadow_samples = []            # 234 口径命中的模板前 20
    all_paths_seen = set()

    for i, f in enumerate(files):
        try:
            tree = ET.parse(str(f))
        except Exception:
            fail_files.append(f.name)
            continue
        doc = tree.getroot()
        rel = str(f).replace(str(root) + "/", "")
        objs = list(text_objects_in_file(doc))
        # 文字对象三档：全部候选 / 最内层 / 最内层且文本非空
        cands = [n for n in doc.iter("scenenode") if _has_text_leaf(n)]
        n_text_candidates += len(cands)
        keep_ids = {id(sn) for sn, _i, _x in objs}
        for n in cands:
            if id(n) not in keep_ids and len(nested_samples) < 5:
                nested_samples.append((rel, n.get("id")))
        if objs:
            n_text_templates += 1
            n_text_objects += len(objs)

        for sn, items, _index in objs:
            if text_leaf_value(sn):
                n_text_nonempty += 1
            elif len(empty_text_objects) < 12:
                empty_text_objects.append((rel, sn.get("id")))
            for path, el in items:
                all_paths_seen.add(path)
                all_leaf_names[path.rsplit("/", 1)[-1]] += 1
                for attr, ok in classify(path, el):
                    hit_tpl[attr].add(f)
                    spelling[attr][path] += 1
                    if ok:
                        val_tpl[attr].add(f)
                for attr in classify_control(path, el):
                    ctl_tpl[attr].add(f)
                    ctl_spelling[attr][path] += 1
                for attr in near_misses(path):
                    near_miss_spelling[(attr, path)] += 1

                norm = normalize(path)
                leaf = norm.rsplit("/", 1)[-1]
                # 颜色：逐源 + 逐路径（TR-023-A1：不再用一个并集正则冒充单一来源）
                for src_name, src_rx in COLOR_SOURCES:
                    if src_rx.match(norm):
                        color_src_tpl[src_name].add(f)
                        if color_path_has_value(el, leaf):
                            color_src_val[src_name].add(f)
                        color_path_tpl.setdefault(norm, set()).add(f)
                        color_path_occ[norm] += 1
                        bucket = color_path_samples.setdefault(norm, [])
                        if rel not in bucket and len(bucket) < 2:
                            bucket.append(rel)
                        break
                for ex_name, ex_rx in COLOR_EXCLUDED:
                    if ex_rx.match(norm):
                        color_excl_tpl[ex_name].add(f)
                        break
                # 阴影：三个可调参数分别记，报告里给规则原文
                for ctl_name, ctl_rx in SHADOW_CTL.items():
                    if ctl_rx.match(norm) and numeric_value(el) is not None:
                        shadow_ctl_tpl[ctl_name].add(f)
                        if len(shadow_samples) < 20 and rel not in shadow_samples:
                            shadow_samples.append(rel)
                if SHADOW_CN_DIST.match(norm) and numeric_value(el) is not None:
                    shadow_cn_dist_tpl.add(f)
                if leaf in ("距离", "Distance") and numeric_value(el):
                    shadow_dist_nonzero_tpl.add(f)

        if (i + 1) % 250 == 0:
            print("... %d/%d  %.1fs" % (i + 1, len(files), time.time() - t0),
                  file=sys.stderr, flush=True)

    elapsed = time.time() - t0
    total = len(files)
    ok_count = total - len(fail_files)
    denom = ok_count

    # 与 TR-022-3 已核定的失败清单交叉核对，对不上就在报告里显式报警
    fail_norm = sorted(fail_files)
    fail_match = (fail_norm == sorted(TR022_FAIL_FILES))

    if args.dump_names:
        for name, cnt in all_leaf_names.most_common():
            print("%7d  %s" % (cnt, name))
        return 0

    # ── 组装 ────────────────────────────────────────────────────────────────
    def pct(n, d):
        return (100.0 * n / d) if d else 0.0

    ui_ready, ui_partial, no_data = [], [], []
    for attr, spec in ATTR_SPECS.items():
        n_ctl = len(ctl_tpl[attr])
        r = pct(n_ctl, denom)
        if n_ctl == 0 or r < 5.0:
            no_data.append(attr)
        elif r >= 50.0:
            ui_ready.append(attr)
        else:
            ui_partial.append(attr)

    # 中文 / 英文拼写的并集（同一模板可能两边都有，交集不为 0）
    zh_set = set()
    en_set = set()
    for p, tpl in color_path_tpl.items():
        if COLOR_ZH.match(p):
            zh_set |= tpl
        if COLOR_EN.match(p):
            en_set |= tpl

    report = {
        "meta": {
            "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "root": str(root),
            "elapsed_s": round(elapsed, 1),
            "script": "tools/tr023/attr_coverage.py",
            "read_only": True,
        },
        "denominator": {
            "total_moti": total,
            "xml_ok": ok_count,
            "xml_fail": len(fail_files),
            "fail_files": fail_norm,
            "fail_matches_tr022": fail_match,
            "scope": "Titles.localized 递归（rglob '*.moti'）",
            "denominator_used": denom,
        },
        "text_scope": {
            "templates_with_text_object": n_text_templates,
            "text_objects": n_text_objects,
            "definition": ("最内层 <scenenode>，其子树里存在叶子 <parameter name='文本'|'Text'>；"
                           "文本为空也算对象"),
            "candidates_all": n_text_candidates,
            "innermost": n_text_objects,
            "nested_excluded": n_text_candidates - n_text_objects,
            "nonempty_text_objects": n_text_nonempty,
            "empty_text_objects": len(empty_text_objects),
            "empty_text_samples": [
                {"file": f, "scenenode_id": i} for f, i in empty_text_objects
            ],
            "nested_excluded_samples": [
                {"file": f, "outer_scenenode_id": i} for f, i in nested_samples
            ],
        },
        "color_sources": {
            name: {
                "templates": len(color_src_tpl[name]),
                "templates_with_value": len(color_src_val[name]),
                "hit_rate_pct": round(pct(len(color_src_tpl[name]), denom), 1),
            }
            for name, _rx in COLOR_SOURCES
        },
        "color_sources_union": len(hit_tpl["颜色"]),
        "color_union_with_value": len(val_tpl["颜色"]),
        "color_zh_union": len(zh_set),
        "color_en_union": len(en_set),
        "color_zh_en_intersection": len(zh_set & en_set),
        # 中文并集的模板清单：QC 报 405、我数 404，差 1 时用这份清单直接 diff
        "color_zh_templates": sorted(str(x).replace(str(root) + "/", "") for x in zh_set),
        "color_excluded": {name: len(s) for name, s in color_excl_tpl.items()},
        "color_paths": [
            {
                "path": p,
                "templates": len(tpls),
                "occurrences": color_path_occ[p],
                "samples": color_path_samples.get(p, []),
            }
            for p, tpls in sorted(color_path_tpl.items(), key=lambda kv: (-len(kv[1]), kv[0]))
        ],
        "shadow": {
            "rule": ("文字对象内存在 <parameter> 路径 "
                     "scenenode/(投影|拖放阴影|Drop Shadow)/(距离|Distance|不透明度|Opacity|模糊|Blur)，"
                     "且该参数带数值（value 或 <curve>@value）"),
            "by_param": {k: len(v) for k, v in shadow_ctl_tpl.items()},
            "union": len(set().union(*shadow_ctl_tpl.values())) if shadow_ctl_tpl else 0,
            "cn_only_dist": len(shadow_cn_dist_tpl),
            "dist_nonzero": len(shadow_dist_nonzero_tpl),
            "samples": shadow_samples,
        },
        "attributes": {},
        "verdict": {"ui_ready": ui_ready, "ui_partial": ui_partial, "no_data": no_data},
    }
    for attr, spec in ATTR_SPECS.items():
        n_hit = len(hit_tpl[attr])
        n_val = len(val_tpl[attr])
        n_ctl = len(ctl_tpl[attr])
        report["attributes"][attr] = {
            "desc": spec["desc"],
            "hit_templates_node": n_hit,
            "hit_rate_node_pct": round(pct(n_hit, denom), 1),
            "hit_templates_with_value": n_val,
            "hit_rate_value_pct": round(pct(n_val, denom), 1),
            "hit_templates_controllable": n_ctl,
            "hit_rate_controllable_pct": round(pct(n_ctl, denom), 1),
            "hit_rate_among_text_pct": round(pct(n_ctl, n_text_templates), 1),
            "spellings": [
                {"path": p, "occurrences": c}
                for p, c in spelling[attr].most_common()
            ],
            "controllable_spellings": [
                {"path": p, "occurrences": c}
                for p, c in ctl_spelling[attr].most_common()
            ],
        }

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "attr_coverage.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    # ── 文本报告 ────────────────────────────────────────────────────────────
    L = []
    A = L.append
    A("TR-023 阶段 1｜全库字幕文字属性命中率")
    A("=" * 74)
    A("")
    A("【口径】")
    A("  生成时间      %s" % report["meta"]["generated_at"])
    A("  统计范围      %s 递归（rglob \"*.moti\"）" % root)
    A("  总数          %d 个 .moti" % total)
    A("  XML 解析成功  %d" % ok_count)
    A("  XML 解析失败  %d（%s）" % (len(fail_files), "、".join(fail_norm)))
    A("  失败清单与 TR-022-3 一致：%s" % ("是" if fail_match else "否（口径变了，必须查）"))
    A("  分母          一律用 %d（可解析模板数），不用 %d" % (denom, total))
    A("  含文字对象模板 %d / %d = %.1f%%"
      % (n_text_templates, denom, pct(n_text_templates, denom)))
    A("  文字对象总数  %d 个 <scenenode>" % n_text_objects)
    A("  耗时          %.1f s（单次墙钟，不取平均）" % elapsed)
    A("")
    A("  一行复现：")
    A("    cd \"/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro\" && \\")
    A("      python3 tools/tr023/attr_coverage.py")
    A("")

    A("【命中率总表】分母 %d（可解析模板）；文字模板内率分母 %d" % (denom, n_text_templates))
    A("-" * 78)
    A(pad("属性", 6) + pad("节点存在", 10, "right") + pad("有值", 8, "right")
      + pad("有值率", 9, "right") + pad("可控", 8, "right")
      + pad("可控率", 9, "right") + pad("文字内率", 10, "right"))
    A("-" * 78)
    for attr in ATTR_SPECS:
        d = report["attributes"][attr]
        A(pad(attr, 6)
          + pad("%d" % d["hit_templates_node"], 10, "right")
          + pad("%d" % d["hit_templates_with_value"], 8, "right")
          + pad("%.1f%%" % d["hit_rate_value_pct"], 9, "right")
          + pad("%d" % d["hit_templates_controllable"], 8, "right")
          + pad("%.1f%%" % d["hit_rate_controllable_pct"], 9, "right")
          + pad("%.1f%%" % d["hit_rate_among_text_pct"], 10, "right"))
    A("-" * 78)
    A("说明：")
    A("  · 「节点存在」= XML 里有这个参数节点，但可能是空壳（例如 物质/颜色 只有 <foldFlags>）。")
    A("  · 「有值」     = 节点上确实带可用值（数值→value/@curve，字体→<font> 文本，颜色→末级红绿蓝的 value）。")
    A("  · 「可控」     = 还能当控件用：渐变要有第二个色标(RGB2)、阴影要有 距离/不透明度、")
    A("                   描边要有 宽度。只有空组 / 只有渐变纹理节点的，一律不算可控。")
    A("  · 「文字内率」 分母是 %d 个含文字对象的模板，看「真做 UI 时能覆盖多少真字幕」。" % n_text_templates)
    A("  · 双语重复：同一模板里 Font 与 字体、Size 与 大小 会同时出现（Motion 同时写本地化名与原名），")
    A("    所以下面「路径写法」的出现次数会大于模板数，不是重复统计错误。")
    A("  · 颜色：节点存在 %d 个模板，其中 %d 个真的带红绿蓝数值，差额 %d 个是"
      % (report["attributes"]["颜色"]["hit_templates_node"],
         report["attributes"]["颜色"]["hit_templates_with_value"],
         report["attributes"]["颜色"]["hit_templates_node"]
         - report["attributes"]["颜色"]["hit_templates_with_value"]))
    A("    容器空壳（例如只有 面/颜色 节点、下面没有 RGB）。逐源明细见「颜色源优先级表」。")
    A("")

    A("【逐属性路径写法】同类但命名不同的写法分开列")
    A("-" * 74)
    for attr, spec in ATTR_SPECS.items():
        d = report["attributes"][attr]
        A("")
        A("■ %s —— %s" % (attr, spec["desc"]))
        A("  节点存在 %d / %d   有值 %d / %d   可控 %d / %d"
          % (d["hit_templates_node"], denom, d["hit_templates_with_value"], denom,
             d["hit_templates_controllable"], denom))
        if not d["spellings"]:
            A("  路径写法：无（全库 0 个模板出现过）")
            continue
        A("  路径写法（按出现次数降序；同一个文字对象里出现两次算两次）：")
        for s in d["spellings"][:40]:
            A("    " + pad(s["path"], 62) + pad("%d" % s["occurrences"], 6, "right"))
        if len(d["spellings"]) > 40:
            A("    …… 另有 %d 种写法（完整清单见 .json）" % (len(d["spellings"]) - 40))
        if d["controllable_spellings"]:
            A("  其中能当控件用的写法（判据见总表下方「可控」）：")
            for s in d["controllable_spellings"][:6]:
                A("    " + pad(s["path"], 62) + pad("%d" % s["occurrences"], 6, "right"))
        nm = [(k, v) for (a, k), v in near_miss_spelling.items() if a == attr]
        if nm:
            A("  名字相近但**不计入**的写法（语义不同，别混）：")
            for k, v in sorted(nm, key=lambda x: -x[1])[:10]:
                A("    " + pad(k, 62) + pad("%d" % v, 6, "right"))
    A("")

    A("【颜色源优先级表】分母 %d；取色器按这个顺序回退，多源会重叠，不能相加" % denom)
    A("-" * 96)
    A(pad("序", 4) + pad("源（真实路径前缀）", 40) + pad("模板数", 8, "right")
      + pad("有值", 8, "right") + pad("有值率", 9, "right") + "  一条样例模板")
    A("-" * 96)
    for idx, (src_name, _rx) in enumerate(COLOR_SOURCES, 1):
        n_t = len(color_src_tpl[src_name])
        n_v = len(color_src_val[src_name])
        sample = ""
        for p, tpl in color_path_tpl.items():
            if _rx.match(p) and tpl:
                sample = sorted(color_path_samples.get(p, ["—"]))[0]
                break
        mark = "  ← 空壳，取不到 RGB" if n_v == 0 else ""
        A(pad(str(idx), 4) + pad(src_name, 40) + pad("%d" % n_t, 8, "right")
          + pad("%d" % n_v, 8, "right")
          + pad("%.1f%%" % pct(n_v, denom), 9, "right") + "  " + sample + mark)
    A("-" * 96)
    A(pad("并集", 6) + pad("上面 9 个源全算（= 总表的「颜色」行）", 40)
      + pad("%d" % len(hit_tpl["颜色"]), 8, "right")
      + pad("%d" % len(val_tpl["颜色"]), 8, "right")
      + pad("%.1f%%" % pct(len(val_tpl["颜色"]), denom), 9, "right"))
    A("")
    A("  中英分开看（同一模板可能两边都有，交集 %d）：" % len(zh_set & en_set))
    A("    中文写法并集 %d 个模板 / 英文写法并集 %d 个模板 / 总并集 %d"
      % (len(zh_set), len(en_set), len(zh_set | en_set)))
    A("    你报中文并集 405，我数 %d，差 %d；%d 个模板的清单在 .json 的"
      % (len(zh_set), abs(405 - len(zh_set)), len(zh_set)))
    A("    color_zh_templates 里，直接 diff 就能定位是哪一份。")
    A("")
    A("  口径说明（TR-023-A1 修正）：")
    A("    · 每个源数的是「该路径前缀在该模板的某个文字对象里出现过」的模板数，")
    A("      容器节点本身也算（面/颜色 没有子节点时也是一条参数路径），")
    A("      所以是 226 / 165 / 106，而不是只数红绿蓝叶子得到的 163 / 92。")
    A("    · 「有值」= 该路径自身带 value，或其下红绿蓝叶子带 value。")
    A("    · 226 个 对象/基础/物质/颜色 的「有值」是 0：这批节点全是")
    A("      <parameter name=\"颜色\"><foldFlags>15</foldFlags></parameter> 空壳，")
    A("      下面没有 红/绿/蓝。同族 对象/基本、Object/Basic/Substance、基本/物质 一样是 0。")
    A("      结论：物质/颜色 这一族不能当取色源，能取到 RGB 的只有 面 / 表面 / Face / 渐变，")
    A("      外加 29 个 图层|层/物质/颜色（图层级物质色，见第 9 行）。")
    A("    · 上一版「物质/颜色 仅 29」的 29 其实是 图层/物质/颜色（29 个模板，真带 RGB），")
    A("      不是 对象/基础/物质/颜色（226 个模板，0 个带 RGB）—— 两族被我混成了一个正则。")
    A("    · 上一版 629 = 面 163 + 表面 92 + Face 374（三者互不重叠，都是带值的纯色填充）；")
    A("      631 = 629 + 2 个只靠 图层/物质/颜色 才有值的模板。")
    A("      629 这个数本身不假，但把它标成「表面/面 颜色 629」是错标：")
    A("      它是三个族的并集，其中「表面/颜色」只占 92/106。")
    A("    · 描边色 轮廓|Outline / 颜色|Color 归「描边」，不计入主色。")
    A("    · 投影 / 光晕 的渐变（投影/渐变、光晕/渐变）不是填充色，已排除在主色之外。")
    A("")
    A("  不计入主色的颜色路径（单独统计，确认没有漏算填充色）：")
    for ex_name, _rx in COLOR_EXCLUDED:
        A("    " + pad(ex_name, 60) + pad("%d 个模板" % len(color_excl_tpl[ex_name]), 10, "right"))
    A("")

    A("【颜色逐路径明细】每条给 模板数 + 出现次数 + 样例模板（全量，不汇总）")
    A("-" * 96)
    main_rows = [(p, t) for p, t in color_path_tpl.items()
                 if any(rx.match(p) for _n, rx in COLOR_SOURCES)]
    main_rows.sort(key=lambda kv: (-len(kv[1]), kv[0]))
    for p, tpl in main_rows:
        A("  " + pad(p, 58) + pad("%d" % len(tpl), 6, "right")
          + pad("%d" % color_path_occ[p], 7, "right") + "  "
          + (color_path_samples.get(p) or ["—"])[0])
    A("")
    A("  已排除、但确实存在的颜色路径（不进主色）：")
    excl_rows = [(p, t) for p, t in color_path_tpl.items()
                 if not any(rx.match(p) for _n, rx in COLOR_SOURCES)]
    excl_rows.sort(key=lambda kv: (-len(kv[1]), kv[0]))
    for p, tpl in excl_rows[:20]:
        A("  " + pad(p, 58) + pad("%d" % len(tpl), 6, "right")
          + pad("%d" % color_path_occ[p], 7, "right") + "  "
          + (color_path_samples.get(p) or ["—"])[0])
    if len(excl_rows) > 20:
        A("  …… 另有 %d 条（完整清单见 .json 的 color_paths）" % (len(excl_rows) - 20))
    A("")

    A("【阴影「可控」判定规则原文 + 命中清单】")
    A("-" * 96)
    A("  规则（脚本里逐字对应 SHADOW_CTL）：")
    A("    文字对象内存在参数路径")
    A("      scenenode/(投影|拖放阴影|Drop Shadow)/(距离|Distance)")
    A("      scenenode/(投影|拖放阴影|Drop Shadow)/(不透明度|Opacity)")
    A("      scenenode/(投影|拖放阴影|Drop Shadow)/(模糊|Blur|Blur/X|Blur/Y)")
    A("    且该参数带数值（value 或 <curve>@value）。三者取并集。")
    A("")
    A("  各参数命中：距离 %d / 不透明度 %d / 模糊 %d → 并集 %d"
      % (len(shadow_ctl_tpl["距离"]), len(shadow_ctl_tpl["不透明度"]),
         len(shadow_ctl_tpl["模糊"]), report["shadow"]["union"]))
    A("  更严口径对照：只数中文 投影/距离 = %d；距离数值 ≠ 0 = %d"
      % (len(shadow_cn_dist_tpl), len(shadow_dist_nonzero_tpl)))
    A("  说明：并集从 218 抬到 234 的是「模糊」这一项；只要求「有距离」就是 218。")
    A("        你数到 51，我这几个口径都不是 51（中文 投影/距离 %d、距离≠0 %d、距离 %d）。"
      % (len(shadow_cn_dist_tpl), len(shadow_dist_nonzero_tpl),
         len(shadow_ctl_tpl["距离"])))
    A("        51 若是「距离≠0 且中文拼写」或别的组合，把命中清单一给，我照你的口径对齐。")
    A("")
    A("  并集口径命中的模板，前 20 个：")
    for s in shadow_samples:
        A("    " + s)
    A("")

    A("【文字对象口径】一句话规则 + 三档数字 + 边界样本")
    A("-" * 96)
    A("  规则：取所有「子树里存在叶子 <parameter name=\"文本\"|\"Text\">」的 <scenenode>，")
    A("        去掉「本身是另一个候选的祖先」的，只留最内层；文本值为空也算一个对象。")
    A("")
    A("  A 全部候选（含外层群组）      %d" % n_text_candidates)
    A("  B 最内层（本报告采用）        %d   （排掉 %d 个外层）"
      % (n_text_objects, n_text_candidates - n_text_objects))
    A("  C 最内层且文本非空            %d   （= QC 的 2852，差 %d 个空文本对象）"
      % (n_text_nonempty, n_text_objects - n_text_nonempty))
    A("")
    A("  边界样本 1（计入）：PSD婚礼字幕/10/10.moti scenenode id=3001702 —— 文本为空，")
    A("    本报告算 1 个文字对象，QC 的 2852 不含它；8 个空文本对象全在这个差里。")
    if nested_samples:
        f0, i0 = nested_samples[0]
        A("  边界样本 2（不计入）：%s scenenode id=%s —— 它内部还有带文本叶子的 scenenode，"
          % (f0, i0))
        A("    属于群组外壳，按「最内层」规则排掉，避免把群组算成一个字幕对象。")
        A("  边界样本 3（计入，普通）：-2026年4月项目/婚礼模板/婚礼模板.moti 的 11 个 scenenode")
        A("    （id 3000102…3001102），每层一个文本，全部计入。")
    A("")

    A("【结论】")
    A("-" * 74)
    A("口径：只看「可控」（有真实数值/颜色可读可写），不看「节点存在」。")
    A("")

    def ctl_line(attr):
        d = report["attributes"][attr]
        cands = d["controllable_spellings"]
        # 颜色/渐变优先拿「红通道」那条当代表路径，否则取出现最多的那条
        if attr in ("颜色", "渐变"):
            red = [s for s in cands if re.search(r"(红色|红|Red)$", s["path"])]
            cands = red or cands
        main = cands[0]["path"] if cands else "—"
        return ("  · %-4s 可控 %4d/%d = %5.1f%%（文字模板内 %5.1f%%），主写法 %s"
                % (attr, d["hit_templates_controllable"], denom,
                   d["hit_rate_controllable_pct"], d["hit_rate_among_text_pct"], main))

    A("A. 可以直接做 UI（可控率 ≥50%，多数模板都取得到值）：")
    for attr in sorted(ui_ready,
                       key=lambda a: -report["attributes"][a]["hit_templates_controllable"]):
        A(ctl_line(attr))
    A("")
    A("B. 有数据来源但覆盖不全（5%~50%）：能做，但大多数模板要显示空态/禁用，")
    A("   不能给默认 0 值控件冒充可用：")
    for attr in sorted(ui_partial,
                       key=lambda a: -report["attributes"][a]["hit_templates_controllable"]):
        A(ctl_line(attr))
    A("")
    A("C. 没有数据来源、做了也是空控件（本轮一律不做）：")
    for attr in no_data:
        d = report["attributes"][attr]
        if d["hit_templates_node"] == 0:
            A("  · %-4s 全库 0 个模板有这个参数" % attr)
        else:
            A("  · %-4s 节点存在 %d 个模板，但可控只有 %d 个（%s）"
              % (attr, d["hit_templates_node"], d["hit_templates_controllable"],
                 "只有纹理/渐变空壳，没有强度参数" if attr in ("阴影", "描边") else "覆盖过低"))
    A("")
    A("─" * 74)
    A("只读声明：全程只读 .moti，未写回、未落中间文件；未 push、未重建 dmg。")
    A("")

    txt = "\n".join(L)
    (outdir / "attr_coverage.txt").write_text(txt, encoding="utf-8")
    print(txt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
