"""
R32 / A-65 回归样本生成器：构造一个桥接输出 > 500 KB 的 PSD。

背景：R31 的 PSDParserSocket 先 waitUntilExit 再读 stdout，任何输出超过
macOS 管道缓冲（64 KB）的 PSD 都会永久互锁。现有 tests/data 里的 PSD
输出都在 30 KB 以内，根本打不到边界，所以这里按需生成大样本（不提交二进制）。

用法:
    python3 tools/make_r32_stress_psd.py <输出路径> [图层数]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests"))
import r25_fixtures as F  # noqa: E402


def build(dst: str, n_layers: int = 260) -> str:
    psd = F._new_canvas(640, 360)
    for i in range(n_layers):
        F._pixel_layer(psd, "Caption_Layer_With_A_Very_Long_Descriptive_Name_%03d" % i,
                       color=(i % 255, 80, 160, 255))
    psd.save(dst)
    return dst


if __name__ == "__main__":
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 260
    build(out, n)
    print(f"written: {out} ({os.path.getsize(out)} bytes, {n} layers)")
