import struct, sys, hashlib, os

def load(p):
    d = open(p,'rb').read()
    n = struct.unpack(">H", d[4:6])[0]
    t = {}
    for i in range(n):
        o = 12 + i*16
        tag, chk, off, ln = struct.unpack(">4sIII", d[o:o+16])
        t[tag.decode('latin1')] = (off, ln)
    return d, t

def names(d, t):
    no, nl = t['name']
    cnt, so = struct.unpack(">HH", d[no+2:no+6])
    want = {1:"Family",2:"Subfamily",3:"UniqueID",4:"FullName",5:"Version",6:"PSName",8:"Manufacturer",9:"Designer"}
    out = {}
    for i in range(cnt):
        r = no + 6 + i*12
        pid, eid, lid, nid, ln, lo = struct.unpack(">HHHHHH", d[r:r+12])
        if nid in want and pid == 3:
            try: s = d[no+so+lo:no+so+lo+ln].decode('utf-16-be')
            except Exception: continue
            out.setdefault(nid, s)
    return {want[k]: v.strip() for k, v in out.items()}

def cmap_cov(d, t):
    co, cl = t['cmap']
    n = struct.unpack(">H", d[co+2:co+4])[0]
    best = None
    for i in range(n):
        pid, eid, off = struct.unpack(">HHI", d[co+4+i*8:co+4+i*8+8])
        fmt = struct.unpack(">H", d[co+off:co+off+2])[0]
        if fmt == 12: best = co+off
        elif best is None and fmt == 4: best = co+off
    cov = set()
    if struct.unpack(">H", d[best:best+2])[0] == 12:
        ng = struct.unpack(">I", d[best+12:best+16])[0]
        for g in range(ng):
            s,e,gi = struct.unpack(">III", d[best+16+g*12:best+16+g*12+12])
            cov.update(range(s,e+1)) if e-s < 200000 else cov.update([s,e])
    return cov

TESTS = [(0x1F600,"😀 grinning",1),(0x2764,"❤ red heart",1),(0x1F970,"🥰 smiling hearts",12),
 (0x1F9CB,"🧋 bubble tea",13),(0x1FAC0,"🫀 anatomical heart",13),(0x1FAE0,"🫠 melting face",14),
 (0x1FAF6,"🫶 heart hands",14),(0x1FA77,"🩷 pink heart",15),(0x1FABF,"🪿 goose",15),
 (0x1FAE8,"🫨 shaking face",15),(0x1FA89,"🪉 harp",16),(0x1FAE9,"🫩 face with bags",16),
 (0x1FA8A,"🪊 trombone",16),(0x1FADE,"🫞 leafless tree",16),(0x1FAC6,"🫆 fingerprint",17),
 (0x1FADC,"🫜 root vegetable",17),(0x1FADF,"🫟 splatter",17)]

for p in sys.argv[1:]:
    print("=" * 62)
    print("FILE :", p)
    print("SIZE : %.2f MB" % (os.path.getsize(p)/1048576))
    print("SHA256:", hashlib.sha256(open(p,'rb').read()).hexdigest().upper()[:32], "...")
    d, t = load(p)
    print("TABLES:", " ".join(sorted(t.keys())))
    for k, v in names(d, t).items():
        print(f"{k:12}: {v}")
    if 'COLR' in t:
        base = t['COLR'][0]
        ver = struct.unpack(">H", d[base:base+2])[0]
        ng = struct.unpack(">H", d[base+2:base+4])[0] if len(d) >= base+4 else 0
        print("COLR        : format version", ver, "| base-glyph 记录数", ng)
    else:
        print("COLR        : 无（可能不是彩色字体）")
    if 'CPAL' in t:
        cbase = t['CPAL'][0]
        npl = struct.unpack(">H", d[cbase+4:cbase+6])[0]
        print("CPAL        : 调色板数", npl)
    cov = cmap_cov(d, t)
    print("码位总数    :", len(cov))
    print()
    print("%-5s %-22s %s" % ("Emoji","名称","是否包含"))
    for cp, nm, ver in TESTS:
        print("%-5s %-22s %s" % (f"E{ver}", nm, "YES" if cp in cov else "-- 缺失 --"))
