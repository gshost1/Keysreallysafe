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
from pathlib import Path
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
DEFS = '<linearGradient id="tile" x2="0" y2="1"><stop stop-color="#fff"/><stop offset="1" stop-color="#ececf0"/></linearGradient><linearGradient id="blue" x2="1" y2="1"><stop stop-color="#5ab0ff"/><stop offset="1" stop-color="#0a6cff"/></linearGradient><filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dy="12" stdDeviation="12" flood-opacity="0.13"/></filter>'
def tile(shadow=True, small=False):
    return f'<path d="{TILE}" fill="url(#tile)" stroke="#d2d2d7" stroke-width="{7 if small else 3}"' + (' filter="url(#shadow)"' if shadow else '') + '/>'

def glyph(small=False):
    # Balanced master: two broad teeth; optically heavier at 16–32 px.
    return SMALL_GLYPH if small else GLYPH
GLYPH = '<circle cx="372" cy="512" r="150" fill="none" stroke="#000" stroke-opacity=".08" stroke-width="72"/><path d="M372 362A150 150 0 1 1 229.34 558.35" fill="none" stroke="url(#blue)" stroke-width="72" stroke-linecap="round"/><path d="M510 474H800Q834 474 840 512Q834 550 806 550H786L760 608L730 550H690L660 604L630 550H510Z" fill="#1d1d1f" stroke="#1d1d1f" stroke-width="6" stroke-linejoin="round"/>'
SMALL_GLYPH = '<circle cx="380" cy="512" r="158" fill="none" stroke="#000" stroke-opacity=".08" stroke-width="100"/><path d="M380 354A158 158 0 1 1 229.73 560.82" fill="none" stroke="url(#blue)" stroke-width="100" stroke-linecap="round"/><path d="M526 464H800Q834 464 840 512Q834 560 806 560H786L760 618L730 560H690L660 614L630 560H526Z" fill="#1d1d1f" stroke="#1d1d1f" stroke-width="10" stroke-linejoin="round"/>'

def build():
    prefix = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs>' + DEFS + '</defs>'
    files = {
        'keysrs-icon.svg': tile(False) + glyph(),
        'keysrs-icon-app.svg': tile() + glyph(),
        'keysrs-icon-small.svg': tile(True, True) + glyph(True),
        'keysrs-icon-bleed.svg': '<rect width="1024" height="1024" fill="url(#tile)"/><g transform="translate(512 512) scale(1.12) translate(-512 -512)">' + glyph() + '</g>',
    }
    for name, body in files.items():
        (ROOT / name).write_text(prefix + body + '</svg>')
    # Chromium renders SVG filters consistently with the website. Requires scripts/tests npm ci.
    script = r"""
const {chromium} = require('playwright');
(async () => {
 const browser = await chromium.launch();
 const page = await browser.newPage({deviceScaleFactor:1});
 for (const size of [16,32,48,64,128,180,256,512,1024]) {
  await page.setViewportSize({width:size,height:size});
  const name = size <= 32 ? 'small' : size === 180 ? 'bleed' : 'app';
  const svg = require('fs').readFileSync(process.argv[1]+'/keysrs-icon-'+name+'.svg','utf8');
  await page.setContent('<style>body{margin:0}svg{display:block;width:100vw;height:100vh}</style>'+svg);
  await page.screenshot({path:process.argv[1]+'/png/keysrs-icon-'+size+'.png',omitBackground:true});
 }
 await browser.close();
})().catch(e => {console.error(e);process.exit(1)});
"""
    subprocess.run(['node', '-e', script, str(ROOT)], cwd=REPO/'scripts/tests', check=True)
    with tempfile.TemporaryDirectory() as temp:
        iconset = Path(temp)/'Keysrs.iconset'
        iconset.mkdir()
        for size in [16,32,128,256,512]:
            for scale in [1,2]:
                source = ROOT/'png'/f'keysrs-icon-{size*scale}.png'
                suffix = '@2x' if scale == 2 else ''
                (iconset/f'icon_{size}x{size}{suffix}.png').write_bytes(source.read_bytes())
        subprocess.run(['/usr/bin/iconutil','-c','icns','-o',str(ROOT/'Keysrs.icns'),str(iconset)],check=True)
    svg = (ROOT/'keysrs-icon.svg').read_bytes()
    for directory in ['Site','Web']:
        (REPO/directory/'icon.svg').write_bytes(svg)
    Image.open(ROOT/'png/keysrs-icon-48.png').save(
        REPO/'Site/favicon.ico', sizes=[(16,16),(32,32),(48,48)],
        append_images=[Image.open(ROOT/'png/keysrs-icon-16.png'),
                       Image.open(ROOT/'png/keysrs-icon-32.png')])
    (REPO/'Site/apple-touch-icon.png').write_bytes((ROOT/'png/keysrs-icon-180.png').read_bytes())

if __name__ == '__main__':
    build()
