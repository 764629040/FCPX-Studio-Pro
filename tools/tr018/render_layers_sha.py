#!/usr/bin/env python3
"""TR-018: 按项目真实入口逐层渲染 PSD 为 PNG，输出 sha256 清单（禁降级验收）。

用法: render_layers_sha.py <bundle_resources_dir> <outdir> <jsonpath>
真实入口 = core/psd_layer_fallback.py::render_layer_to_png_bytes + extract_layer_styles
"""
import sys, os, glob, json, hashlib, io
from psd_tools import PSDImage

res_dir, outdir, jsonpath = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, res_dir)
from core.psd_layer_fallback import render_layer_to_png_bytes, extract_layer_styles  # noqa: E402

ROOT = os.environ.get(
    "TR018_PROJECT_ROOT",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
DATA = os.path.join(ROOT, "tests", "data")
os.makedirs(outdir, exist_ok=True)
result = {}
for p in sorted(glob.glob(os.path.join(DATA, "*.psd"))):
    name = os.path.basename(p)
    if name == "corrupted_file.psd":
        continue
    layers_out = []
    try:
        psd = PSDImage.open(p)
        for idx, layer in enumerate(psd.descendants()):
            try:
                styles = extract_layer_styles(layer)
                ok, png, info = render_layer_to_png_bytes(layer)
                rec = {
                    "idx": idx,
                    "name": layer.name,
                    "kind": layer.kind,
                    "visible": bool(layer.visible),
                    "styles": styles,
                    "ok": ok,
                    "render_method": (info or {}).get("render_method"),
                    "error": (info or {}).get("error"),
                }
                if ok and png:
                    rec["sha256"] = hashlib.sha256(png).hexdigest()
                    rec["nbytes"] = len(png)
                    with open(os.path.join(outdir, f"{name}.L{idx:03d}.png"), "wb") as f:
                        f.write(png)
                layers_out.append(rec)
            except Exception as e:
                layers_out.append({"idx": idx, "exception": repr(e)})
    except Exception as e:
        layers_out.append({"psd_exception": repr(e)})
    result[name] = layers_out
with open(jsonpath, "w") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
# 摘要：总层数 / 成功图层 / 各 render_method 计数 / 带样式图层数
from collections import Counter
c = Counter()
styled = 0
for ls in result.values():
    for r in ls:
        c[r.get("render_method") or ("error:" + str(r.get("error") or r.get("exception") or r.get("psd_exception"))[:40])] += 1
        if r.get("styles", {}).get("has_styles"):
            styled += 1
print(json.dumps({"total": sum(len(v) for v in result.values()),
                  "methods": dict(c), "styled_layers": styled}, ensure_ascii=False, indent=2))
