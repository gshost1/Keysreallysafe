import math
def pt(cx,cy,r,deg):
    a=math.radians(deg); return f"{cx+r*math.cos(a):.1f} {cy+r*math.sin(a):.1f}"
def arc(cx,cy,r,a0,a1):
    large=1 if (a1-a0)%360>180 else 0
    return f"M{pt(cx,cy,r,a0)}A{r} {r} 0 {large} 1 {pt(cx,cy,r,a1)}"
def squircle(x,y,s,n=5.0,steps=240):
    # continuous-curvature superellipse, closer to the macOS tile than a rounded rect
    c=s/2; pts=[]
    for i in range(steps):
        t=2*math.pi*i/steps; ct,st=math.cos(t),math.sin(t)
        px=c*math.copysign(abs(ct)**(2/n),ct); py=c*math.copysign(abs(st)**(2/n),st)
        pts.append(f"{x+c+px:.1f} {y+c+py:.1f}")
    return "M"+"L".join(pts)+"Z"
TILE=squircle(100,100,824)
DEFS='''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4a4a50"/><stop offset="1" stop-color="#151517"/></linearGradient>
<linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".14"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="bl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5ab0ff"/><stop offset="1" stop-color="#0a6cff"/></linearGradient>
<filter id="sh" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity=".3"/></filter>'''
def tile(shadow):
    f=' filter="url(#sh)"' if shadow else ''
    return (f'<path d="{TILE}" fill="url(#bg)"{f}/><path d="{TILE}" fill="url(#hl)"/>'
            f'<path d="{TILE}" fill="none" stroke="#fff" stroke-opacity=".08" stroke-width="2"/>')
def glyph(small=False):
    if small:  # 16-32px: heavier ring, two deep cuts instead of four
        r,sw,cx,op=158,100,380,.28
        blade='<path d="M150 -48H400Q462 -48 474 0Q462 48 424 48L400 48L372 96L344 48L318 48L290 92L262 48L150 48Z" fill="#fff" stroke="#fff" stroke-width="14" stroke-linejoin="round"/>'
    else:
        r,sw,cx,op=150,72,372,.2
        blade='<path d="M150 -36H405Q452 -36 462 0Q452 36 420 36L404 36L386 68L364 36L342 36L322 74L300 36L278 36L260 62L242 36L150 36Z" fill="#fff" stroke="#fff" stroke-width="10" stroke-linejoin="round"/>'
    return (f'<circle cx="{cx}" cy="512" r="{r}" fill="none" stroke="#fff" stroke-opacity="{op}" stroke-width="{sw}"/>'
            f'<path d="{arc(cx,512,r,-90,162)}" fill="none" stroke="url(#bl)" stroke-width="{sw}" stroke-linecap="round"/>'
            f'<g transform="translate({cx} 512)">{blade}</g>')
S='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
files={
 "keysrs-icon.svg":      S+f"<defs>{DEFS}</defs>{tile(False)}{glyph()}</svg>",
 "keysrs-icon-app.svg":  S+f"<defs>{DEFS}</defs>{tile(True)}{glyph()}</svg>",
 "keysrs-icon-small.svg":S+f"<defs>{DEFS}</defs>{tile(False)}{glyph(True)}</svg>",
 # full-bleed square for apple-touch-icon; iOS applies its own mask
 "keysrs-icon-bleed.svg":S+f'<defs>{DEFS}</defs><rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#hl)"/><g transform="translate(512 512) scale(1.12) translate(-512 -512)">{glyph()}</g></svg>',
}
for k,v in files.items(): open(k,"w").write(v)
