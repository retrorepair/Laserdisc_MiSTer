"""Test vectors for core/sim/tb_player.sv: per-frame VBI words of the GGV1069 capture (core/sim/player_vbi.hex)
and the expected search results. Run with the ld-decode venv python from the project root."""
import sqlite3
db=r'decoded/GGV1069_NTSC/GGV1069_CAV_NTSC_side1.tbc.db'
c=sqlite3.connect(db)
v={f:(a,b) for f,a,b,_ in c.execute('select field_id,vbi0,vbi1,vbi2 from vbi')}
n=c.execute('select count(*) from field_record').fetchone()[0]//2
lines=[]; pic=[]; ch=[]
for k in range(n):
    a1,b1=v.get(2*k,(0,0)); a2,b2=v.get(2*k+1,(0,0))
    lines.append('%08x%08x%08x%08x' % (b2,a2,b1,a1))
    p=None; cc=None
    for w in (b1,b2):
        if (w>>20)==0xF:
            s='%05X'%(w&0x7FFFF)
            if s.isdigit(): p=int(s)
        if (w&0xF00FFF)==0x800DDD:
            cc=int('%X'%((w>>12)&0x7F))
    pic.append(p); ch.append(cc)
print(n, ch[2000], pic[2000], sum(x is not None for x in ch))
open('core/sim/player_vbi.hex','w',newline='').write('\n'.join(lines)+'\n')
def first(pred): return next(k for k in range(n) if pred(k))
for name,pred in (('ch1',lambda k: ch[k] is not None and ch[k]>=1),('ch15',lambda k: ch[k] is not None and ch[k]>=15),
                  ('ch17',lambda k: ch[k] is not None and ch[k]>=17),('pic12345',lambda k: pic[k] is not None and pic[k]>=12345)):
    print(name, first(pred))
c0 = next(ch[k] for k in range(12504, n) if ch[k] is not None)
print('chapter at 12504', c0, 'start of', c0 + 2, first(lambda k: ch[k] is not None and ch[k] >= c0 + 2),
      'start of', c0, first(lambda k: ch[k] is not None and ch[k] >= c0))
