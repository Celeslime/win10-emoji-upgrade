import ctypes as c
from ctypes import wintypes

gdi32 = c.windll.gdi32
user32 = c.windll.user32
user32.GetDC.restype = wintypes.HDC
hdc = user32.GetDC(0)

class LOGFONTW(c.Structure):
    _fields_ = [("lfHeight", c.c_long),("lfWidth", c.c_long),("lfEscapement", c.c_long),
                ("lfOrientation", c.c_long),("lfWeight", c.c_long),("lfItalic", c.c_byte),
                ("lfUnderline", c.c_byte),("lfStrikeOut", c.c_byte),("lfCharSet", c.c_byte),
                ("lfOutPrecision", c.c_byte),("lfClipPrecision", c.c_byte),
                ("lfQuality", c.c_byte),("lfPitchAndFamily", c.c_byte),
                ("lfFaceName", c.c_wchar*32)]

def glyph_exists(family, cp):
    lf = LOGFONTW(); lf.lfHeight = -24; lf.lfCharSet = 1; lf.lfFaceName = family
    h = gdi32.CreateFontIndirectW(c.byref(lf))
    if not h: return None
    old = gdi32.SelectObject(hdc, h)
    units = ord(chr(cp).encode('utf-16-le').decode('utf-16-le')[0]) if False else None
    # 构造 UTF-16 代理对
    s = chr(cp)
    pair = s.encode('utf-16-le')
    n = len(pair)//2
    arr = (wintypes.WCHAR*n)()
    units = [int.from_bytes(pair[i*2:i*2+2],'little') for i in range(n)]
    buf = (wintypes.WCHAR*n)(*units)
    out = (wintypes.USHORT*n)()
    r = gdi32.GetGlyphIndicesW(hdc, buf, n, out, 1)  # GGI_MARK_NONEXISTING
    gdi32.SelectObject(hdc, old)
    gdi32.DeleteObject(h)
    if r == -1: return None
    # 任一单元缺字形都算缺
    return all(v != 0xFFFF and v != -1 for v in out)

tests = [(0x1F600,"E1  grinning"),(0x1F970,"E12 smiling-hearts"),(0x1F9CB,"E13 bubble-tea"),
         (0x1FAE0,"E14 melting-face"),(0x1FA77,"E15 pink-heart"),(0x1FAC6,"E17 fingerprint")]
for fam in ("Segoe UI Emoji","Segoe UI Symbol"):
    print("==", fam)
    for cp,nm in tests:
        g = glyph_exists(fam, cp)
        print("  %-22s %s" % (nm, "有字形" if g else "缺失(方框)"))
