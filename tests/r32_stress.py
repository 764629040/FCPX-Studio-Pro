"""
R32 / A-65 大输出回归样本生成（pytest 动态夹具用，不提交二进制）。

独立于 tools/make_r32_stress_psd.py 的轻量版：只依赖 psd_tools + numpy，
与 tests/r25_fixtures.py 的像素层兼容层保持同一口径。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r25_fixtures as F  # noqa: E402


def build(dst_path: str, n_layers: int = 150) -> int:
    """生成 n_layers 层长名像素层 PSD，返回层数。"""
    psd = F._new_canvas(640, 360)
    for i in range(n_layers):
        F._pixel_layer(psd, "Caption_Layer_With_A_Very_Long_Descriptive_Name_%03d" % i,
                       color=(i % 255, 80, 160, 255))
    psd.save(dst_path)
    return n_layers
