#!/bin/zsh
# R34 直证复现脚本 —— 在项目根目录执行：zsh docs/r34_evidence/run_r34_harness.sh
set -e
cd "$(dirname "$0")/../.."

echo "== 1. 编译并运行 Swift 原生画布直证 harness =="
swiftc -O \
  FCPXStudioNative/Sources/FCPXStudio/Models/AppConfig.swift \
  FCPXStudioNative/Sources/FCPXStudio/Models/LayerModel.swift \
  FCPXStudioNative/Sources/FCPXStudio/Sockets/PSDParserSocket.swift \
  FCPXStudioNative/Sources/FCPXStudio/Views/InfiniteCanvasView.swift \
  tools/r34_render_harness.swift \
  -o docs/r34_evidence/r34_render_harness
./docs/r34_evidence/r34_render_harness

echo "\n== 2. Python .moti 对齐与坐标补偿验证 =="
python3 -c "
import sys, os, json, tempfile
sys.path.insert(0, '.')
from core.psd_parser import parse_psd_file
from core.motion_builder import MotionBuilder
import xml.etree.ElementTree as ET

psd_path = 'tests/data/vertical_wedding_9_16.psd'
parsed = parse_psd_file(psd_path)
mb = MotionBuilder()
with tempfile.NamedTemporaryFile(suffix='.moti', delete=False) as tf:
    moti_path = tf.name

mb.build_moti(parsed['layers'], moti_path, canvas_size=(parsed['width'], parsed['height']))
root = ET.parse(moti_path).getroot()
moti_layers = root.findall('.//layer')
for idx, psd_layer in enumerate(parsed['layers']):
    moti_layer = moti_layers[idx]
    p401_vals = [p.attrib.get('value') for p in moti_layer.findall('.//parameter[@id=\"401\"]')]
    expected = '2' if psd_layer.alignment == 'center' else '1'
    assert all(v == expected for v in p401_vals), f'Mismatch in {psd_layer.name}'
os.remove(moti_path)
print('PASS: All .moti layers parameter 401 synced with PSD alignment!')
"
