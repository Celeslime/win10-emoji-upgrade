import struct, sys, re, os
from collections import defaultdict

def tables(d):
    n = struct.unpack(">H", d[4:6])[0]
    t = {}
    for i in range(n):
        o = 12 + i*16
        tag, chk, off, ln = struct.unpack(">4sIII", d[o:o+16])
        t[tag.decode('latin1')] = (off, ln)
    return t

def coverage(d, t):
    co, cl = t['cmap']
    n = struct.unpack(">H", d[co+2:co+4])[0]
    cov = set()
    for i in range(n):
        pid, eid, off = struct.unpack(">HHI", d[co+4+i*8:co+4+i*8+8])
        b = co + off
        fmt = struct.unpack(">H", d[b:b+2])[0]
        if fmt == 12:
            ng = struct.unpack(">I", d[b+12:b+16])[0]
            for g in range(ng):
                s,e,gi = struct.unpack(">III", d[b+16+g*12:b+16+g*12+12])
                if e - s < 300000: cov.update(range(s, e+1))
        elif fmt == 4:
            segX2 = struct.unpack(">H", d[b+6:b+8])[0]; seg = segX2//2
            ends = struct.unpack(">%dH"%seg, d[b+14:b+14+segX2])
            starts = struct.unpack(">%dH"%seg, d[b+16+segX2:b+16+segX2*2])
            for s,e in zip(starts, ends):
                if e - s < 70000: cov.update(range(s, e+1))
    return cov

def colr_info(d, t):
    if 'COLR' not in t: return "无 COLR 表"
    b = t['COLR'][0]
    ver, nbase, off_base, off_layer, nlayer = struct.unpack(">HHIIH", d[b:b+14])
    s = f"COLR v{ver} | v0 基础字形记录 {nbase} 条 | v0 图层记录 {nlayer} 条"
    if ver >= 1 and len(d) >= b+26:
        off_blist, off_llist = struct.unpack(">II", d[b+14:b+22])
        cnt = struct.unpack(">I", d[b+off_blist:b+off_blist+4])[0] if off_blist else 0
        s += f" | v1 BaseGlyphList {cnt} 条"
    return s

# --- 读取 Unicode 官方 emoji 版本分组 ---
# 用法: python emoji_coverage.py <字体1> [字体2 ...]
# 数据: 默认在脚本目录找 emoji-test.txt，找不到则自动从 unicode.org 下载到脚本目录
here = os.path.dirname(os.path.abspath(__file__))
data = os.path.join(here, 'emoji-test.txt')
if not os.path.exists(data):
    import urllib.request
    url = 'https://unicode.org/Public/emoji/latest/emoji-test.txt'
    print('下载 Unicode 官方 emoji-test.txt ...')
    urllib.request.urlretrieve(url, data)
seqs = defaultdict(list)
rx = re.compile(r'E(\d+\.\d+)')
for line in open(data, encoding='utf-8'):
    if line.startswith('#') or ';' not in line: continue
    left, right = line.split('#', 1)
    if 'fully-qualified' not in left: continue
    cps = [int(x, 16) for x in left.split(';')[0].split()]
    m = rx.search(right)
    if m: seqs[m.group(1)].append(cps)

def verkey(v):
    a, b = v.split('.'); return (int(a), int(b))
allver = sorted(seqs.keys(), key=verkey)

fonts = {}
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    t = tables(d)
    nglyphs = struct.unpack(">H", d[t['maxp'][0]+4:t['maxp'][0]+6])[0]
    cov = coverage(d, t)
    fmt = "(%.2f MB)" % (os.path.getsize(p)/1048576)
    print("="*66)
    print(os.path.basename(os.path.dirname(p)) + "\\" + os.path.basename(p), fmt)
    print("maxp numGlyphs :", nglyphs)
    print("glyf 表大小    : %.0f KB" % (t['glyf'][1]/1024))
    print("cmap 码位总数  :", len(cov))
    print(colr_info(d, t))
    fonts[p] = cov

print()
print("="*66)
print("%-8s %-8s %s" % ("Emoji", "序列数", "\t".join("覆盖 %d" % (i+1) for i in range(len(fonts)))))
names = list(fonts.keys())
for v in allver:
    row = []
    tot = len(seqs[v])
    for p in names:
        cov = fonts[p]
        ok = sum(1 for cps in seqs[v] if all(c in cov for c in cps))
        row.append(f"{ok}/{tot} ({100*ok//max(tot,1)}%)")
    print("%-8s %-8d %s" % ("E"+v, tot, "\t".join(row)))
print()
print("字序列 ->", " | ".join(os.path.basename(os.path.dirname(p)) for p in names))
for i, p in enumerate(names):
    tot = sum(len(seqs[v]) for v in allver)
    ok = sum(1 for v in allver for cps in seqs[v] if all(c in fonts[p] for c in cps))
    print(f"[{i+1}] {p}: 全版本合计 {ok}/{tot} = {100*ok//tot}%")

new, old = names[0], names[1]
only_new = fonts[new] - fonts[old]
print("\n新增覆盖的码位数 :", len(only_new))
def blk(cp):
    return "U+%04X" % cp
sample = sorted(only_new)
print("新增码位区间示例 :", ", ".join(blk(c) for c in sample[:14]), "...")
print("本次新增表情版本 :", ", ".join("E"+v for v in allver
      if any(all(c in fonts[new] for c in cps) and not all(c in fonts[old] for c in cps) for cps in seqs[v])))
