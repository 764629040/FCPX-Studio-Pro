# -*- coding: utf-8 -*-
"""TR-002-C 纯字节落点探针 + 内存模拟写回自证（不写仓库、不改样本）"""
import os, re, json, hashlib
ROOT = "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro"
P = os.path.join(ROOT, "build_staging", "T01_领衔呈现_竖版", "T01_领衔呈现_竖版.moti")
b = open(P, "rb").read()
N = len(b)
TAG = re.compile(rb"<[^>]*>", re.S)
ATTR = re.compile(rb'([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|\'([^\']*)\')')

class Node:
    __slots__ = ("name","start","end","attrs","selfclose","path","layer_idx")
    def __init__(s, name, start, end, attrs, selfclose, path, layer_idx):
        s.name, s.start, s.end, s.attrs, s.selfclose, s.path, s.layer_idx = name,start,end,attrs,selfclose,path,layer_idx

def key(n):  # 祖先链键：标签名 + id + name（parameter 用 name/id）
    return (n.name, n.attrs.get(b"id",(b"",0,0))[0], n.attrs.get(b"name",(b"",0,0))[0])

def parse_attrs(tok, base):
    out = {}
    for m in ATTR.finditer(tok):
        val = m.group(3) if m.group(3) is not None else m.group(4)
        q = tok.rfind(m.group(2), 0, m.end())
        vs = base + q + 1
        out[m.group(1)] = (val, vs, vs + len(val))
    return out

nodes = []
stack = []
layer_counter = -1
for m in TAG.finditer(b):
    tok, st, en = m.group(0), m.start(), m.end()
    if tok.startswith(b"<!--") or tok.startswith(b"<?") or tok.startswith(b"<!"): continue
    if tok.startswith(b"</"):
        nm = tok[2:-1].strip()
        for k in range(len(stack)-1, -1, -1):
            if stack[k].name == nm:
                del stack[k:]; break
        continue
    sc = tok.rstrip().endswith(b"/>")
    inner = tok[1:-2].strip() if sc else tok[1:-1].strip()
    nm = re.match(rb"([A-Za-z_:][-A-Za-z0-9_:.]*)", inner)
    nm = nm.group(1) if nm else b""
    attrs = parse_attrs(tok, st)
    if nm == b"layer": layer_counter += 1
    path = tuple(key(x) for x in stack)
    nodes.append(Node(nm, st, en, attrs, sc, path, layer_counter if nm==b"layer" else -1))
    if not sc:
        # 栈里存临时 Node（path 不重要）
        stack.append(Node(nm, st, en, attrs, False, (), -1))

layers = [n for n in nodes if n.name == b"layer"]

def under(layer, name, pid, chain):
    """在 layer 子树内找 parameter，且祖先链【尾段】严格等于 chain（不全局搜 id/name）。"""
    hi = next((L.start for L in layers if L.start > layer.start), N)
    out = []
    for n in nodes:
        if n.name != b"parameter" or not (layer.start < n.start < hi): continue
        if n.attrs.get(b"name",(b"",0,0))[0] != name or n.attrs.get(b"id",(b"",0,0))[0] != pid: continue
        if len(n.path) >= len(chain) and n.path[-len(chain):] == chain:
            out.append(n)
    return out

def text_span(layer):
    tp = [n for n in nodes if n.name == b"parameter" and n.start > layer.start
          and n.start < (next((L.start for L in layers if L.start > layer.start), N))
          and n.attrs.get(b"name",(b"",0,0))[0] == "文本".encode() and n.attrs.get(b"id",(b"",0,0))[0] == b"369"]
    if not tp: return None
    hi = next((L.start for L in layers if L.start > layer.start), N)
    seg = b[tp[0].start:hi]
    m = re.search(rb"<text>(.*?)</text>", seg, re.S)
    if not m: return None
    a = tp[0].start + m.start(1); c = tp[0].start + m.end(1)
    return (m.group(1), a, c)

rows = []
for i, L in enumerate(layers):
    chain = ((b"parameter", b"1", "属性".encode()),
             (b"parameter", b"100", "变换".encode()),
             (b"parameter", b"101", "位置".encode()))
    xs = under(L, b"X", b"1", chain)
    ys = under(L, b"Y", b"2", chain)
    en = L.attrs.get(b"enabled"); lk = L.attrs.get(b"locked")
    rows.append(dict(
        index=i,
        name=L.attrs.get(b"name",(b"",0,0))[0].decode(),
        id=L.attrs.get(b"id",(b"",0,0))[0].decode(),
        layer_open=(L.start, L.end), gt=L.end-1,
        x=(xs[0].attrs[b"value"][0].decode(), xs[0].attrs[b"value"][1], xs[0].attrs[b"value"][2]) if xs else None,
        y=(ys[0].attrs[b"value"][0].decode(), ys[0].attrs[b"value"][1], ys[0].attrs[b"value"][2]) if ys else None,
        text=(text_span(L)[0].decode(), text_span(L)[1], text_span(L)[2]) if text_span(L) else None,
        enabled=en[0].decode() if en else None, locked=lk[0].decode() if lk else None,
        enabled_span=(en[1],en[2]) if en else None, locked_span=(lk[1],lk[2]) if lk else None,
    ))

json.dump(rows, open("/tmp/tr002c/landing_bytes.json","w"), ensure_ascii=False, indent=1)
print("=== 字节落点（8 层） ===")
for r in rows:
    print("#%d %-9s id=%-8s X=%-8s@%d..%d Y=%-8s@%d..%d text@%d..%d enabled=%s locked=%s gt=%d" % (
        r["index"], r["name"], r["id"], r["x"][0], r["x"][1], r["x"][2], r["y"][0], r["y"][1], r["y"][2],
        r["text"][1], r["text"][2], r["enabled"] or "缺", r["locked"] or "缺", r["gt"]))
print()
print("sha256(before) =", hashlib.sha256(b).hexdigest(), "bytes =", N)

# ── 内存模拟写回：只改目标字节区间 + 属性缺失时单点插入 ──
def esc(t): return t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
edits = [(0, dict(text="领衔呈现·改", x="-200.5", y="490.0", enabled="0", locked="1")),
         (3, dict(text="THE BRIDE & CO", x="12.5", y="520.0"))]
repl = []   # (start, end, newbytes, label)
insert = [] # (pos, newbytes, label)
for idx, e in edits:
    r = rows[idx]
    if "text" in e: repl.append((r["text"][1], r["text"][2], esc(e["text"]).encode(), "#%d text" % idx))
    if "x" in e:    repl.append((r["x"][1], r["x"][2], e["x"].encode(), "#%d X" % idx))
    if "y" in e:    repl.append((r["y"][1], r["y"][2], e["y"].encode(), "#%d Y" % idx))
    if "enabled" in e:
        if r["enabled_span"]: repl.append((r["enabled_span"][0], r["enabled_span"][1], e["enabled"].encode(), "#%d enabled" % idx))
        else: insert.append((r["gt"], (' enabled="%s"' % e["enabled"]).encode(), "#%d enabled(insert)" % idx))
    if "locked" in e:
        if r["locked_span"]: repl.append((r["locked_span"][0], r["locked_span"][1], e["locked"].encode(), "#%d locked" % idx))
        else: insert.append((r["gt"], (' locked="%s"' % e["locked"]).encode(), "#%d locked(insert)" % idx))

ops = sorted([(a,c,bytes(l,"utf8"),l) for a,c,d,l in repl] + [(p,p,d,l) for p,d,l in insert], key=lambda x:-x[0])
out = bytearray(b)
for a,c,d,l in ops: out[a:c] = d
out = bytes(out)
delta = sum(len(d)-(c-a) for a,c,d,l in ops)
print("after bytes =", len(out), " delta =", delta, " assert =", len(out)-N == delta)
print("changed ops =", len(ops))
open("/tmp/tr002c/sim_after.moti","wb").write(out)
# 非目标行差异 0 检查（按行）
def line_diff(old,new):
    lo=old.split(b"\n"); ln=new.split(b"\n")
    return [(i+1,lo[i],ln[i]) for i in range(min(len(lo),len(ln))) if lo[i]!=ln[i]]
d = line_diff(b,out)
print("diff lines =", len(d))
for i,o,n in d[:12]: print("  L%d  - %r\n       + %r" % (i,o[:150],n[:150]))
print("sha256(after) =", hashlib.sha256(out).hexdigest())
