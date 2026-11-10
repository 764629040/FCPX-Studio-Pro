#!/usr/bin/env python3
"""TR-021: 在指定 runtime 下跑固定种子的 ndimage.rotate，输出可跨 runtime 比对的 JSON。

用法: rotate_probe.py <out_dir> <full|slim>
  full -> 用完整 scipy 的 python3 跑
  slim -> 用落地 R2.app 包内 python3 跑
两边结果由 run_probes.sh 比对。
"""
import hashlib
import json
import os
import sys

import numpy as np
import scipy
import scipy.ndimage as ndi

out_dir, mode = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

info = {"mode": mode, "scipy": scipy.__version__}
try:
    from scipy import special
    info["special_importable"] = True
    info["cosdg_type"] = type(special.cosdg).__name__
except ImportError as e:
    info["special_importable"] = False
    info["special_error"] = type(e).__name__ + ": " + str(e)

rng = np.random.default_rng(20261110)
a = rng.random((64, 64))
rot = {}
for angle in (37.3, 90.0):
    r = ndi.rotate(a, angle, reshape=False, order=3)
    np.save(os.path.join(out_dir, "rot_%s_%s.npy" % (mode, str(angle).replace(".", "_"))), r)
    rot[str(angle)] = {
        "sha256": hashlib.sha256(r.tobytes()).hexdigest(),
        "sum": float(r.sum()),
        "max": float(r.max()),
        "head": r.ravel()[:6].tolist(),
    }
info["rotate"] = rot
info["rotate_usable"] = True

json.dump(info, open(os.path.join(out_dir, "rotate_%s.json" % mode), "w"),
          indent=2, ensure_ascii=False)
print(json.dumps(info, indent=2, ensure_ascii=False))
