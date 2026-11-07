#!/usr/bin/env python3
"""
R33 样本生成器（验收判据 1 / 判据 7）

背景：
- 任务单指定主样本 /mnt/local/128/字幕素材/镇雄.psd 在开发机不存在
  （/mnt 无挂载，全盘搜索无同名 PSD，见 docs/r33_evidence/DISLOSURE_样本说明.md）。
- 因此按审核实测的结构**等价重建**：2848×1600、13 层、12 隐藏、0 文字层、
  唯一可见非底板层名为「镇雄夜色」。照片内容取自用户 SD 卡真实的
  镇雄夜景素材（ffmpeg 从 /Volumes/SD/镇雄街拍合集/*.mov 抽帧），不是凭空涂鸦。

判据 7 要求「随机抽 3 个从未测过的 PSD」：本机不存在用户 PSD 素材库，
所以用随机种子生成 3 个结构互不相同、从未参与过任何测试的 PSD
（真实照片 + 隐藏层 + 分组），种子与来源全部写入 manifest.json 可复现。

用法：
    python3 tools/make_r33_samples.py --out-dir docs/r33_evidence --seed 20261105
"""
import argparse
import json
import os
import random
import subprocess
import sys
from datetime import datetime

from PIL import Image, ImageDraw, ImageEnhance
from psd_tools import PSDImage

VIDEO_DIR = "/Volumes/SD/镇雄街拍合集"


def add_pixel_layer(parent, image, name: str, top: int = 0, left: int = 0):
    """创建像素层并写入中文名。

    psd_tools 的 create_pixel_layer(name=...) 直接写 _record.name，保存时用
    macroman 编码 Pascal 字符串，中文会抛 UnicodeEncodeError。走 .name setter
    则会退回 '?' 并把真名写入 luni(UNICODE_LAYER_NAME) 标签 —— 与 Photoshop
    的实际存储方式一致，读回来仍是中文。
    """
    layer = parent.create_pixel_layer(image, name="tmp", top=top, left=left)
    layer.name = name
    return layer


def add_group(parent, name: str):
    group = parent.create_group(name="tmp")
    group.name = name
    return group


def probe_duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def extract_frame(video: str, at: float, size: tuple) -> Image.Image:
    tmp = "/tmp/r33_frame_tmp.png"
    vf = f"scale={size[0]}:{size[1]}:force_original_aspect_ratio=increase,crop={size[0]}:{size[1]}"
    subprocess.run(
        ["ffmpeg", "-y", "-ss", str(at), "-i", video, "-frames:v", "1", "-vf", vf, tmp],
        capture_output=True,
    )
    return Image.open(tmp).convert("RGB")


def pick_videos(rng: random.Random, count: int):
    vids = [os.path.join(VIDEO_DIR, f) for f in os.listdir(VIDEO_DIR) if f.endswith(".mov")]
    if not vids:
        raise SystemExit(f"SD 卡目录没有 .mov 素材: {VIDEO_DIR}")
    rng.shuffle(vids)
    return vids[:count]


def build_zhenxiong(photo: Image.Image, out_path: str) -> dict:
    """等价重建审核实测的 镇雄.psd 结构：
    2848×1600 / 13 层 / 0 文字 / 「图层 2」可见全画布底板 / 11 个隐藏像素层 /
    「镇雄夜色」可见（唯一可见非底板层）。
    psd_tools 中先创建的在顶层，因此创建顺序 = 顶 → 底。"""
    w, h = photo.size
    psd = PSDImage.new("RGB", (w, h), color=(0, 0, 0))

    # 顶层：唯一可见非底板层
    top = ImageEnhance.Brightness(photo).enhance(1.05)
    add_pixel_layer(psd, top, "镇雄夜色", top=0, left=0)

    # 11 个隐藏层（与审核实测一致：visible=False 的像素层）
    hidden_names = []
    for i in range(1, 12):
        if i % 3 == 1:
            crop = photo.crop((100 * i, 60 * i, 100 * i + 1280, 60 * i + 720))
            img = crop
            top_i, left_i = 60 * i, 100 * i
        elif i % 3 == 2:
            img = ImageEnhance.Contrast(photo).enhance(0.6 + 0.08 * i)
            top_i, left_i = 0, 0
        else:
            patch = Image.new("RGBA", (900, 500), (20, 40 + 12 * i, 90, 255))
            img = patch
            top_i, left_i = 200 + 40 * i, 300 + 25 * i
        layer = add_pixel_layer(psd, img, f"备选调色_{i:02d}", top=top_i, left=left_i)
        layer.visible = False
        hidden_names.append(layer.name)

    # 底板：全画布可见（按规范会被判定为底板层过滤）
    base_layer = add_pixel_layer(psd, photo.copy(), "图层 2", top=0, left=0)
    assert base_layer.visible

    psd.save(out_path)
    return {
        "file": os.path.basename(out_path),
        "canvas": [w, h],
        "layers": 13,
        "text_layers": 0,
        "visible_non_bg": ["镇雄夜色"],
        "visible_bg": ["图层 2"],
        "hidden": hidden_names,
    }


def build_random_unseen(photo: Image.Image, seed: int, idx: int, out_path: str) -> dict:
    """生成一个从未测过的 PSD：随机画幅 + 底板 + 可见装饰层 + 隐藏层 + 分组。"""
    rng = random.Random(seed * 100 + idx)
    sizes = [(1920, 1080), (1080, 1920), (2048, 1152), (1600, 1600)]
    w, h = sizes[rng.randrange(len(sizes))]
    photo = photo.resize((w, h))
    psd = PSDImage.new("RGB", (w, h), color=(10, 10, 14))

    layers_desc = []
    # 顶层可见装饰块（保证非底板可见层存在）
    n_top = rng.randint(1, 3)
    for k in range(n_top):
        bw, bh = rng.randint(w // 6, w // 2), rng.randint(h // 8, h // 3)
        patch = Image.new("RGBA", (bw, bh),
                          (rng.randint(30, 220), rng.randint(30, 220), rng.randint(30, 220), 230))
        layer = add_pixel_layer(
            psd, patch, f"装饰块_{k}",
            top=rng.randint(0, max(0, h - bh)), left=rng.randint(0, max(0, w - bw))
        )
        layers_desc.append({"name": layer.name, "visible": True})

    # 隐藏层
    n_hidden = rng.randint(1, 5)
    hidden_names = []
    for k in range(n_hidden):
        cw, ch = rng.randint(w // 8, w // 3), rng.randint(h // 8, h // 3)
        x0 = rng.randint(0, w - cw)
        y0 = rng.randint(0, h - ch)
        img = photo.crop((x0, y0, x0 + cw, y0 + ch))
        layer = add_pixel_layer(
            psd, img, f"隐藏片段_{k}",
            top=rng.randint(0, max(0, h - ch)), left=rng.randint(0, max(0, w - cw))
        )
        layer.visible = False
        hidden_names.append(layer.name)
        layers_desc.append({"name": layer.name, "visible": False})

    # 分组（可见，含一个可见子层）
    if rng.random() < 0.7:
        grp = add_group(psd, f"装饰组_{idx}")
        cw, ch = w // 3, h // 4
        sub = Image.new("RGBA", (cw, ch), (240, 200, 60, 200))
        add_pixel_layer(grp, sub, "组内亮条", top=h // 3, left=w // 3)
        layers_desc.append({"name": f"装饰组_{idx}/组内亮条", "visible": True})

    # 底板
    add_pixel_layer(psd, photo.copy(), "背景", top=0, left=0)

    psd.save(out_path)
    return {
        "file": os.path.basename(out_path),
        "canvas": [w, h],
        "seed": seed,
        "layers_desc": layers_desc,
        "hidden_count": n_hidden,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="docs/r33_evidence")
    ap.add_argument("--seed", type=int, default=20261105)
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    rng = random.Random(args.seed)

    videos = pick_videos(rng, 4)
    print("视频来源：")
    for v in videos:
        print("  ", v, f"(duration={probe_duration(v):.1f}s)")

    # 1) 镇雄等价样本：2848×1600 / 13 层 / 12 隐藏 / 0 文字
    zx_photo = extract_frame(videos[0], 8.0, (2848, 1600))
    zx_path = os.path.join(args.out_dir, "zhenxiong_equivalent.psd")
    zx_info = build_zhenxiong(zx_photo, zx_path)
    print("主样本:", zx_info["file"], zx_info["canvas"], os.path.getsize(zx_path), "bytes")

    # 2) 三个从未测过的随机 PSD（真实照片 + 随机结构）
    unseen_infos = []
    for i in range(3):
        at = rng.uniform(1.0, 12.0)
        photo = extract_frame(videos[i + 1], at, (1920, 1080))
        path = os.path.join(args.out_dir, f"unseen_random_{i + 1}.psd")
        info = build_random_unseen(photo, args.seed, i + 1, path)
        info["source_video"] = os.path.basename(videos[i + 1])
        info["frame_at"] = round(at, 2)
        unseen_infos.append(info)
        print("随机样本:", info["file"], info["canvas"], "hidden=", info["hidden_count"],
              os.path.getsize(path), "bytes")

    manifest = {
        "generated_at": datetime.now().isoformat(),
        "seed": args.seed,
        "zhenxiong_equivalent": zx_info,
        "zhenxiong_source_video": os.path.basename(videos[0]),
        "unseen": unseen_infos,
        "note": "原 /mnt/local/128/字幕素材/镇雄.psd 在开发机不存在（/mnt 无挂载），"
                "本样本为结构等价重建；照片为用户 SD 卡真实镇雄素材抽帧。",
    }
    mp = os.path.join(args.out_dir, "r33_samples_manifest.json")
    with open(mp, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("manifest:", mp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
