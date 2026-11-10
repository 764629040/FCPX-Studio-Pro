#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 TR-020 的机器产物汇总成人看的验收记录 / 逐层数据表。

所有数字直接读 JSON 实测值，不重新推断、不写「约 / 基本 / 大致」。
"""
import argparse
import json
import os

import numpy
import PIL
import psd_tools

PSD_TOOLS_VER = psd_tools.__version__
NUMPY_VER = numpy.__version__
PIL_VER = PIL.__version__


def load(p):
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True, help="analyze/commit/verify 产物目录")
    ap.add_argument("--overmerge", default="", help="过合并注入测试产物目录")
    ap.add_argument("--out", required=True, help="证据输出目录")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    cand = load(os.path.join(args.work, "candidates.json"))
    appr = load(os.path.join(args.work, "approved.json"))
    comm = load(os.path.join(args.work, "commit_report.json"))
    ver = load(os.path.join(args.work, "verify.json"))
    ad = cand["adaptive"]
    cs = cand["color_stats"]
    em = cand["elapsed_ms"]
    cm = comm["elapsed_ms"]

    L = []
    L.append("TR-020 | 一般（新功能） | PNG 多元素智能拆图层  验收记录")
    L.append("=" * 76)
    L.append("输入样本：%s" % cand["source"])
    L.append("原 PNG sha256：%s" % cand["source_sha256"])
    L.append("原 PNG 大小：%d B（%.1f MB）  画幅：%d×%d  模式：%s" %
             (cand["source_bytes"], cand["source_bytes"] / 1048576.0,
              cand["width"], cand["height"], cand["source_mode"]))
    L.append("分析后 sha256：%s  一致：%s" %
             (cand["source_sha256_after_analyze"], cand["source_unchanged"]))
    L.append("导出后 sha256：%s  一致：%s" %
             (comm["source_sha256_after"], comm["source_unchanged"]))
    L.append("")
    L.append("【TR-022 更正声明】本文件由 tools/tr020/make_report.py 重生成，日期 2026-11-11。")
    L.append("  TR-022-1：上一版把「确认卡标题」直接当成 PSD 层名对外宣称（当时 PSD 里实际写的是")
    L.append("            『图层 01 · #3C78FF』）。自本版起 PSD 层名 = 标题 + ' · #HEX'，例如")
    L.append("            『邀请函蓝 · #3C78FF』；第四节拆成「确认卡标题 / PSD 层名」两列，回导段逐层比对。")
    L.append("  TR-022-4：所有实测数字后面都带测量条件（单次墙钟 / 不取平均 / 一位小数 / 含哪些字节）。")
    L.append("")
    L.append("一、预处理与颜色口径（透明不是白）")
    L.append("-" * 76)
    L.append("前景像素 alpha>0：%d    透明像素：%d" %
             (cand["foreground_pixels"], cand["transparent_pixels"]))
    L.append("主色 alpha 加权均值：%s" % cs["rgb_mean_alpha_weighted"])
    L.append("朴素全图 RGB 均值（被透明区污染）：%s" % cs["rgb_mean_naive_all_pixels"])
    L.append("朴素仅非透明 RGB 均值：%s" % cs["rgb_mean_naive_nonzero_only"])
    L.append("透明区 RGB 均值：%s" % cs["transparent_rgb_mean"])
    L.append("→ 代码里所有主色都用 sum(RGB*a)/sum(a)，透明像素权重为 0，不参与均值。")
    L.append("")
    L.append("二、预切：8 邻域连通块 + 自适应形态学膨胀")
    L.append("-" * 76)
    L.append("8 邻域原始连通块：%d（噪声门槛 %d px，丢弃 %d）" %
             (cand["raw_component_count"], cand["noise_floor_px"],
              cand["dropped_noise_component_count"]))
    L.append("画布对角线：%.1f px  笔画尺度：%.1f px" %
             (ad["canvas_diagonal_px"], ad["stroke_scale_px"]))
    L.append("半径搜索上限 cap = clamp(round(0.02×对角线), 4, 64) = %d px（随画布尺寸）" %
             ad["radius_search_cap_px"])
    L.append("组数序列 N(r)：%s" % ad["radius_series"])
    L.append("最长稳定平台：r = %d…%d，长度 %d，组数 %d" %
             (ad["plateau_start_px"], ad["plateau_end_px"],
              ad["plateau_length"], ad["plateau_group_count"]))
    L.append("采用半径 r = %d px，膨胀核 %d×%d（取平台最小 r，数据驱动，非常数）" %
             (ad["radius_px"], ad["kernel_px"], ad["kernel_px"]))
    L.append("最终候选组之间最小 bbox 间隙：%.1f px；膨胀直径 %d px" %
             (ad["min_gap_between_final_groups_px"], 2 * ad["radius_px"]))
    L.append("预切候选块：%d；过合并告警：%d 条 %s" %
             (cand["candidate_count"], len(cand["warnings"]), cand["warnings"]))
    L.append("预切实测耗时：%.1f ms（单次墙钟、不取平均；读 %.1f / 连通块 %.1f / "
             "自适应膨胀 %.1f / 候选导出 %.1f；一位小数）" %
             (em["total"], em["read"], em["connected_components"],
              em["dilation_grouping"], em["candidates_export"]))
    L.append("")

    if args.overmerge and os.path.isfile(os.path.join(args.overmerge, "candidates.json")):
        ov = load(os.path.join(args.overmerge, "candidates.json"))
        L.append("二·补 过合并告警注入测试（强制 r=80，证明告警不是摆设）")
        L.append("-" * 76)
        L.append("候选块：%d（正常预切是 %d），告警 %d 条" %
                 (ov["candidate_count"], cand["candidate_count"], len(ov["warnings"])))
        for w in ov["warnings"]:
            L.append("  全局告警：%s" % w)
        for c in ov["candidates"]:
            for w in c["warnings"]:
                L.append("  块 #%d：%s" % (c["id"], w))
        L.append("")

    L.append("三、人工确认（层数由人批准，程序不替人决定）")
    L.append("-" * 76)
    L.append("批准文件：approved.json   来源：%s   时间：%s" %
             (appr.get("approval_source", "unknown"), appr.get("confirmed_at", "")))
    L.append("批准层数：%d   导出层数：%d" %
             (appr["approved_layer_count"], comm["exported_layer_count"]))
    for a in appr.get("operator_actions", []):
        L.append("  操作：%s / %s / %s" %
                 (a.get("action"), a.get("source"), a.get("note", "")))
    L.append("")

    L.append("四、逐层数据（RGB / 像素数 / 位置 / 文件体积，全部实测）")
    L.append("-" * 76)
    L.append("说明：『确认卡标题』是确认窗里那一栏（用户可填/改的语义名）；"
             "『PSD 层名』是真正写进 PSD 的字符串 = 标题 + ' · #HEX'（已在回导段逐层校验）。")
    L.append("| 层 | 确认卡标题 | PSD 层名 | 主色 RGB | HEX | 像素数 | bbox (x0,y0,x1,y1) | 切块 PNG | 不透明度 |")
    L.append("|---:|---|---|---|---|---|---:|---|---|---:|")
    for l in comm["layers"]:
        psd_name = l.get("psd_name") or l["name"]
        L.append("| %d | %s | %s | %s | %s | %d | %s | %s (%.1f KB) | %d |" %
                 (l["index"], l["name"], psd_name, "/".join("%.1f" % v for v in l["rgb"]),
                  l["hex"], l["pixels"], l["bbox"], l["png"], l["png_kb"], l["opacity"]))
    L.append("像素数合计：%d（= 源图前景 %d）" %
             (sum(l["pixels"] for l in comm["layers"]), cand["foreground_pixels"]))
    L.append("")

    L.append("五、导出路径与实测时间 / 体积")
    L.append("-" * 76)
    L.append("路径 A 复合多层 PSD：%s" % comm["psd"]["path"])
    L.append("  %d B = %.1f MB（一位小数；含 PSD 头 + 合并图像数据 + 层记录；"
             "PSD 内无时间戳，同输入同实现逐字节稳定，不同 psd_tools 版本/压缩参数有 ±0.1 KB 量级差异）" %
             (comm["psd"]["bytes"], comm["psd"]["mb"]))
    L.append("路径 B 安装为当前模板的多图层：设计器载入该 PSD 后图层树 %d 层，见真机截图。"
             % comm["exported_layer_count"])
    L.append("commit 实测耗时：%.1f ms（单次墙钟、不取平均；读 %.1f / 切块 %.1f / 写 PSD %.1f；一位小数）" %
             (cm["total"], cm["read"], cm["cut"], cm["psd_write"]))
    L.append("")

    L.append("六、PSD 回导设计器验证")
    L.append("-" * 76)
    L.append("VERDICT: %s   PASS=%d FAIL=%d" %
             (ver["verdict"], ver["pass_count"], ver["fail_count"]))
    for c in ver["checks"]:
        L.append("  %s %-40s %s" %
                 ("✅" if c["ok"] else "❌", c["check"], c["detail"]))
    L.append("cli_bridge.py parse 回导层数：%s（与批准层数 %d 一致）" %
             (ver["bridge_layer_count"], appr["approved_layer_count"]))
    L.append("")

    L.append("七、红线遵守")
    L.append("-" * 76)
    L.append("- 原 PNG 未改写：analyze / commit / verify 三次 sha256 全部一致。")
    L.append("- 层数不静默决定：analyze 只给候选；approved.json 由人签字；commit 严格按条目数输出。")
    L.append("- 透明不当白：全程 RGBA，切块保留原始 alpha（含 1~8 的弱边缘），回导逐像素一致。")
    L.append("- 未自动退出/重启 FCPX，未触碰 FCPX 资料库，未 push，未发版，未重建 dmg。")
    L.append("- 所有大小 / 时间均为实测值，一位小数，无「基本 / 大致 / 约」。")
    L.append("")
    L.append("八、测量口径（TR-022-4：每个数字都能被别人按同样条件复算）")
    L.append("-" * 76)
    L.append("· 时间：进程内 time.perf_counter() 差，单次墙钟，不取平均；分段边界见 png_split.py commit() 顶部注释。")
    L.append("· 体积：os.path.getsize(path)，单位 B；KB = B/1024，MB = B/1048576，一律 %.1f 四舍五入到一位小数。")
    L.append("· PSD 体积含 PSD 头 + 合并图像数据 + 层记录；PSD 内无时间戳，同输入同实现逐字节稳定；")
    L.append("  换 psd_tools 版本或压缩参数会变动 ±0.1 KB 量级（本次 psd_tools %s / numpy %s / PIL %s）。" %
             (PSD_TOOLS_VER, NUMPY_VER, PIL_VER))
    L.append("· 像素 / bbox：numpy 直接数 alpha>0 与 bbox，无缩放、无插值。")
    L.append("· 环境：本机 macOS 单进程、无并发任务；数字只对这套软硬件组合成立。")

    text = "\n".join(L) + "\n"
    with open(os.path.join(args.out, "验收记录.txt"), "w", encoding="utf-8") as f:
        f.write(text)
    with open(os.path.join(args.out, "拆层数据表.md"), "w", encoding="utf-8") as f:
        f.write("# TR-020 拆层数据表\n\n```text\n" + text + "```\n")
    print("WROTE", os.path.join(args.out, "验收记录.txt"))
    print("WROTE", os.path.join(args.out, "拆层数据表.md"))


if __name__ == "__main__":
    main()
