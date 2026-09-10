"""Build Aeon Nocturne: a renamed LM-derived display face with custom ligatures.
Requires fonttools[woff] and the Latin Modern 17 regular source supplied by
fonts-lmodern. Original source remains available from the GUST Latin Modern project.
"""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
import argparse
p=argparse.ArgumentParser();p.add_argument('--source',default='/usr/share/texmf/fonts/opentype/public/lm/lmroman17-regular.otf');a=p.parse_args()
out=Path(__file__).resolve().parents[1]/'app/fonts';out.mkdir(exist_ok=True)
f=TTFont(a.source);gs=f.getGlyphSet();top=f['CFF '].cff.topDictIndex[0];cs=top.CharStrings
rules=[]
def add(name,components,width,swash=False):
 pen=T2CharStringPen(width,gs)
 for glyph,transform in components:gs[glyph].draw(TransformPen(pen,transform))
 if swash:
  pen.moveTo((400,85));pen.curveTo((545,-50),(740,-132),(1010,12));pen.curveTo((777,-170),(539,-98),(390,73));pen.closePath()
 char=pen.getCharString(private=top.Private,globalSubrs=f['CFF '].cff.GlobalSubrs)
 cs.charStrings[name]=len(cs.charStringsIndex);cs.charStringsIndex.append(char);top.charset.append(name)
 f['hmtx'][name]=(round(width),0)
for pair in ['HE','TH','AE','LL','OO','RA','TT','ER']:
 first,second=pair;wa=f['hmtx'][first][0];wb=f['hmtx'][second][0]
 overlap={'HE':145,'TH':170,'AE':175,'LL':140,'OO':200,'RA':135,'TT':180,'ER':135}[pair]
 name='aeon_'+pair;dx=wa-overlap
 add(name,[(first,(1,0,0,1,0,0)),(second,(1,0,0,1,dx,0))],dx+wb,pair=='RA')
 rules.append(f'sub {first} {second} by {name};')
for pair in ['OU','QU']:
 name='aeon_'+pair
 add(name,[(pair[0],(1,0,0,1,0,0)),('U',(.60,0,0,.60,151,135))],720)
 rules.append(f'sub {pair[0]} U by {name};')
# Long ascender ligatures join naturally; text remains ordinary searchable Unicode.
for pair in ['st','ft']:
 wa=f['hmtx'][pair[0]][0];wb=f['hmtx'][pair[1]][0];dx=wa-28
 name='aeon_'+pair;add(name,[(pair[0],(1,0,0,1,0,0)),(pair[1],(1,0,0,1,dx,0))],dx+wb)
 rules.append(f'sub {pair[0]} {pair[1]} by {name};')
f.setGlyphOrder(top.charset);f['maxp'].numGlyphs=len(top.charset)
standard=[]
for chars,glyph in [('ff','f_f'),('fi','f_i'),('fl','f_l'),('ffi','f_f_i'),('ffl','f_f_l')]:
 if glyph in f.getGlyphOrder():standard.append(f'sub {" ".join(chars)} by {glyph};')
addOpenTypeFeaturesFromString(f,'languagesystem DFLT dflt; languagesystem latn dflt; feature liga {\n'+'\n'.join(standard+rules)+'\n} liga;')
for nid,value in {1:'Aeon Nocturne',2:'Regular',3:'Aeon-Nocturne-4.4',4:'Aeon Nocturne Regular',6:'AeonNocturne-Regular',16:'Aeon Nocturne',17:'Regular'}.items():
 f['name'].setName(value,nid,3,1,0x409);f['name'].setName(value,nid,1,0,0)
top.FamilyName='Aeon Nocturne';top.FullName='Aeon Nocturne Regular';f['CFF '].cff.fontNames=['AeonNocturne-Regular']
f['name'].setName('Modified Latin Modern Roman 17 by B. Jackowski and J. M. Nowacki. Aeon interlocking glyphs and swash additions, 2026. Distributed under GUST Font License / LPPL 1.3c.',0,3,1,0x409)
f.flavor='woff';f.save(out/'AeonNocturne-Regular.woff')
print('Built',out/'AeonNocturne-Regular.woff')
