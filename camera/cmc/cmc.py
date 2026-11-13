import struct,sys
d=open(sys.argv[1],'rb').read()
recs={}
p=0x38; end=0x20+struct.unpack_from('<I',d,0x24)[0]
while p+8<=end:
    sz,fmt,key,nid=struct.unpack_from('<IBBH',d,p); recs.setdefault(nid,[]).append((p,sz)); p+=sz
def body(nid,i=0):
    p,sz=recs[nid][i]; return d[p+8:p+sz]
LS={0:'none',1:'A',2:'B',3:'C',4:'D50',5:'D55',6:'D65',7:'D75',8:'E',9:'F1',10:'F2',11:'F3',12:'F4',13:'F5',14:'F6',15:'F7',16:'F8',17:'F9',18:'F10',19:'F11',20:'F12'}
print('general',struct.unpack_from('<4H',body(2)))
b=body(3); n=struct.unpack_from('<I',b)[0]; print('black level luts',n)
for i in range(n):
    et,ag,c1,c2,c3,c4=struct.unpack_from('<II4H',b,4+16*i); print('  exp %d gain %d -> %d %d %d %d'%(et,ag,c1,c2,c3,c4))
print('saturation',struct.unpack_from('<4H',body(5)))
print('sensitivity raw',body(7).hex())
b=body(10); lvl,ng,gw,gh=struct.unpack_from('<4H',b); print('LSC level %d grids %d %dx%d'%(lvl,ng,gw,gh))
o=8
for i in range(ng):
    st,cl,x,y=struct.unpack_from('<4H',b,o); o+=8
    g=struct.unpack_from('<%dH'%(4*gw*gh),b,o); o+=8*gw*gh
    ch=[g[k*gw*gh:(k+1)*gw*gh] for k in range(4)]
    def stat(c): 
        c=[v for v in c]; ctr=c[(gh//2)*gw+gw//2]; return 'ctr %d corner %d max %d'%(ctr,c[0],max(c))
    print('  grid %d src %s lvl %d cie(%.4f,%.4f) | '%(i,LS.get(st,st),cl,x/65536,y/65536),' / '.join(stat(c) for c in ch))
b=body(15); na,nn=struct.unpack_from('<2H',b); print('chromaticity response: avg %d nvm %d'%(na,nn))
for i in range(na+nn):
    x,y,rg,bg=struct.unpack_from('<4H',b,4+8*i); print('  cie(%.4f,%.4f) R/G %.4f B/G %.4f'%(x/65536,y/65536,rg/1024,bg/1024), rg,bg)
b=body(18); nm=struct.unpack_from('<H',b)[0]; print('color matrices',nm,'body len',len(b))
o=2
for i in range(nm):
    ls,rg,bg,x,y=struct.unpack_from('<I4H',b,o); m1=struct.unpack_from('<9i',b,o+12); m2=struct.unpack_from('<9i',b,o+48); o+=84
    print('  %s chroma R/G %d B/G %d cie(%.4f,%.4f)'%(LS.get(ls,ls),rg,bg,x/65536,y/65536))
    print('    accurate ',m1,' rowsums',[sum(m1[k*3:k*3+3]) for k in range(3)])
    print('    preferred',m2,' rowsums',[sum(m2[k*3:k*3+3]) for k in range(3)])
print('analog gain conv raw',body(19).hex())
print('digital gain raw',body(20).hex())
