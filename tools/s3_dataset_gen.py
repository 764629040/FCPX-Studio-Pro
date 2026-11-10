#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
S3 / P1 独立 harness 数据生成器（固定 seed，完全可复现）。

在 /tmp 生成：
  /tmp/s3_verify/data/dataset_1000.json    1000 条合成模板
  /tmp/s3_verify/data/dataset_10000.json   10000 条合成模板
  /tmp/s3_verify/data/track.json           同一段滚动轨迹（visibleRect.origin.y 序列）
  /tmp/s3_verify/data/MANIFEST.sha256      以上文件 SHA256 清单

硬约束：数据文件只写 /tmp（外置卷仅剩 ~255Mi，禁止写大数据）。
两份实现（现状 / 新实现）都从**同一份文件**加载同一份数组，保证「同一份数据」。
"""
import hashlib
import json
import os
import random
import sys

OUT = "/tmp/s3_verify/data"
SEED = 0x53335031  # "S3P1"
os.makedirs(OUT, exist_ok=True)


def make_dataset(n: int) -> list:
    rnd = random.Random(SEED ^ n)
    cats = ["Titles.localized", "Effects.localized", "Transitions.localized",
            "Generators.localized", "LUTs", "Audio"]
    tiers = ["builtin", "user", "system"]
    items = []
    for i in range(n):
        cat = cats[rnd.randrange(len(cats))]
        tier = tiers[rnd.randrange(len(tiers))]
        # 路径唯一，作为缩略图缓存键
        path = "/S3_SYNTH/%s/%s/Template_%05d.fcpbundle" % (tier, cat, i)
        items.append({
            "idx": i,
            "path": path,
            "name": "模板 %05d · %s" % (i, cat.split(".")[0]),
            "sizeMB": round(rnd.uniform(0.4, 240.0), 3),
            "tier": tier,
            "category": cat,
            "enabled": (rnd.random() > 0.12),
            "offline": (rnd.random() < 0.03),
            "corrupted": (rnd.random() < 0.01),
            "symlink": (rnd.random() < 0.02),
            "thumbSeed": rnd.randrange(1, 2 ** 31),
        })
    return items


def make_track(item_counts, viewport_w=900.0, viewport_h=760.0, frames=240, seed=SEED):
    """同一段滚动轨迹：按**全量**内容高度生成 offset 序列，去程到底 + 回程到顶。
    两份实现用完全相同的 offsets 数组。"""
    rnd = random.Random(seed)
    margin, spacing = 16.0, 14.0
    cols = min(4, max(1, int((viewport_w - margin * 2 + spacing) / (210 + spacing))))
    rows = (max(item_counts) + cols - 1) // cols
    card_h = 236.0
    content_h = rows * (card_h + spacing) + margin + 44.0 + margin
    max_offset = max(0.0, content_h - viewport_h)

    half = frames // 2
    offsets = []
    # 去程： easing 让轨迹更接近真实滚轮（非匀速），但完全确定
    for f in range(half):
        t = (f + 1) / half
        eased = t * t * (3 - 2 * t)
        offsets.append(round(max_offset * eased, 3))
    # 回程
    for f in range(half):
        t = (f + 1) / half
        eased = t * t * (3 - 2 * t)
        offsets.append(round(max_offset * (1 - eased), 3))
    while len(offsets) < frames:
        offsets.append(0.0)

    return {
        "frames": len(offsets),
        "viewportWidth": viewport_w,
        "viewportHeight": viewport_h,
        "columns": cols,
        "maxItemCount": max(item_counts),
        "contentHeight": round(content_h, 3),
        "maxOffset": round(max_offset, 3),
        "offsets": offsets,
    }


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    counts = [1000, 10000]
    written = []
    for n in counts:
        p = os.path.join(OUT, "dataset_%d.json" % n)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(make_dataset(n), f, ensure_ascii=False, separators=(",", ":"))
        written.append(p)
        print("dataset n=%-6d -> %s (%d bytes)" % (n, p, os.path.getsize(p)))

    tp = os.path.join(OUT, "track.json")
    with open(tp, "w", encoding="utf-8") as f:
        json.dump(make_track(counts), f, separators=(",", ":"))
    written.append(tp)
    print("track            -> %s (%d bytes)" % (tp, os.path.getsize(tp)))

    mp = os.path.join(OUT, "MANIFEST.sha256")
    with open(mp, "w", encoding="utf-8") as f:
        f.write("# S3 P1 dataset manifest  seed=0x%08X\n" % SEED)
        for p in written:
            f.write("%s  %s\n" % (sha256(p), os.path.basename(p)))
    print("manifest         -> %s" % mp)
    with open(mp, encoding="utf-8") as f:
        sys.stdout.write(f.read())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
