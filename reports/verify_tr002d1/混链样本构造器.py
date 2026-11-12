#!/usr/bin/env python3
# TR-002-D-1：混合链样本构造器
# 方法：取 8 层中文链样本副本，把文档顺序第一个 layer 的
#   name="属性" id="1"   -> name="Properties" id="1"
#   name="变换" id="100"  -> name="Transform" id="100"
# 该层从此 positionChain == "en"（不可写），其余 7 层保持 "zh"（可写）。
# 只动这两个 name 属性值，其余字节一律不动。
import re, sys

src = open('/tmp/tr002d1/zh8.moti', 'rb').read().decode('utf-8')
out_path = '/tmp/tr002d1/mixed8.moti'

starts = [m.start() for m in re.finditer(r'<layer[ >]', src)]
assert len(starts) == 8, f'expect 8 layers, got {len(starts)}'

L0 = src[starts[0]:starts[1]]
p_attr = 'name="属性" id="1"'
p_trans = 'name="变换" id="100"'
assert L0.count(p_attr) == 2, f'L0 attr marker count={L0.count(p_attr)}'
assert L0.count(p_trans) == 1, f'L0 trans marker count={L0.count(p_trans)}'
# L0 内两个 属性 参数全改名（其中一个带 变换 子链、一个不带），
# 保证该层无任何中文链残留 -> positionChain 判 "en"。
L0_new = L0.replace(p_attr, 'name="Properties" id="1"')
L0_new = L0_new.replace(p_trans, 'name="Transform" id="100"')

out = src[:starts[0]] + L0_new + src[starts[1]:]
open(out_path, 'wb').write(out.encode('utf-8'))

# 自检：其余层不动
for n in range(1, 8):
    s, e = starts[n], starts[n+1] if n+1 < len(starts) else len(src)
    assert src[s:e] == out[s + (len(L0_new) - len(L0)):e + (len(L0_new) - len(L0))], f'L{n} moved'
print('OK', out_path)
