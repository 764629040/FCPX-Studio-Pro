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

【「文字对象」定义（避免把矩形/绘画的描边算成文字描边）】
  = 一个 <scenenode>，其子树里存在叶子 <parameter name="文本"|"Text">。
    文字样式参数在它下面的 <style> 里（字体/大小/间距/表面/外框/投影），
    段落参数在 <对象|Object>/<段落|Paragraphs>/<段落|Paragraph>/ 下（对齐/行间距）。
  因此输出的路径一律以 scenenode/ 开头，可逐字回 XML 核对。

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


# ────────────────────────────────────────────────────────────────────────────
# 文字对象与属性抽取
# ────────────────────────────────────────────────────────────────────────────
def _has_text_leaf(node):
    for p in iter_params(node):
        if (p.get("name") or "") in TEXT_LEAF_NAMES and not p.findall("parameter"):
            return True
    return False


def find_text_scenenodes(root):
    """返回「最内层」文字 scenenode：子树里有叶子 文本/Text，且内部没有更深的文字 scenenode。

    不取最内层的话，分组层（群组）的 scenenode 会因为装了子文字层也被算成文字对象，
    文字对象数会翻倍，图层级的 属性/阴影 也会被误记成文字阴影。
    """
    candidates = [n for n in root.iter("scenenode") if _has_text_leaf(n)]
    inner = set()
    for n in candidates:
        for sub in n.iter("scenenode"):
            if sub is not n:
                inner.add(id(sub))
    return [n for n in candidates if id(n) not in inner]


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
    "desc": "文字填充颜色（物质/表面 下的 红绿蓝）",
    "rules": [
        (re.compile(r"^scenenode/.*(?:物质|Substance|表面|面|Face)/(?:颜色|Color)(?:/|$)"),
         "group_color"),
    ],
}

ATTR_SPECS["渐变"] = {
    "desc": "文字填充渐变（表面/Face 下的渐变组）",
    "rules": [
        (re.compile(r"^scenenode/.*(?:表面|面|Face)/(?:渐变|Gradient)(?:/|$)"), "group_any"),
    ],
    # 真正的渐变要有第二个色标且带颜色值；只有 RGB1 的其实还是纯色
    "control": [
        (re.compile(r"^scenenode/.*(?:表面|面|Face)/(?:渐变|Gradient)/.*RGB2/.*"
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

# 颜色来源细分：做取色器时要知道颜色到底存在哪个节点里
COLOR_FAMILIES = [
    ("物质/颜色（2D 基本物质里的 RGB）",
     re.compile(r"^scenenode/.*(?:物质|Substance)/(?:颜色|Color)")),
    ("表面/面 颜色（2D 表面颜色 RGB）",
     re.compile(r"^scenenode/.*(?:表面|面|Face)/(?:颜色|Color)")),
    ("渐变首色标 RGB1（渐变模板只能取首色标当颜色）",
     re.compile(r"^scenenode/.*(?:表面|面|Face)/(?:渐变|Gradient)/.*RGB1/.*(?:红色|红|Red)$")),
]

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
    # 每个属性：命中模板集合 / 有值模板集合 / 路径写法 → 模板集合
    hit_tpl = {a: set() for a in ATTR_SPECS}
    val_tpl = {a: set() for a in ATTR_SPECS}
    ctl_tpl = {a: set() for a in ATTR_SPECS}
    spelling = {a: Counter() for a in ATTR_SPECS}
    ctl_spelling = {a: Counter() for a in ATTR_SPECS}
    # 全局叶子名（--dump-names 与「疑似缺失」排查用）
    all_leaf_names = Counter()
    near_miss_spelling = Counter()
    color_family_tpl = {name: set() for name, _rx in COLOR_FAMILIES}
    all_paths_seen = set()

    for i, f in enumerate(files):
        try:
            tree = ET.parse(str(f))
        except Exception:
            fail_files.append(f.name)
            continue
        doc = tree.getroot()
        objs = list(text_objects_in_file(doc))
        if objs:
            n_text_templates += 1
            n_text_objects += len(objs)

        for _sn, items, _index in objs:
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
                if color_has_value(el):
                    norm = normalize(path)
                    for fam_name, fam_rx in COLOR_FAMILIES:
                        if fam_rx.search(norm):
                            color_family_tpl[fam_name].add(f)
                            break

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
            "definition": "含叶子 <parameter name='文本'|'Text'> 的 <scenenode>",
        },
        "color_families": {
            name: len(tpls) for name, tpls in color_family_tpl.items()
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
    A("  · 颜色有一批模板只有 物质/颜色 空壳节点（<foldFlags> 之外没有红绿蓝），")
    A("    这类计入「节点存在」但不算「有值」，差额 %d 个模板就是空壳。"
      % (report["attributes"]["颜色"]["hit_templates_node"]
         - report["attributes"]["颜色"]["hit_templates_with_value"]))
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

    A("【颜色来源细分】做取色器前必须知道颜色到底存在哪个节点")
    A("-" * 74)
    for fam_name, _rx in COLOR_FAMILIES:
        A("  " + pad(fam_name, 46) + pad("%d 个模板" % len(color_family_tpl[fam_name]), 12, "right"))
    A("  注：三类会重叠（同一模板既有 物质/颜色 又有渐变的情况存在），不能相加当总数；")
    A("      颜色总命中仍是上面总表的 %d 个模板。" % report["attributes"]["颜色"]["hit_templates_controllable"])
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
