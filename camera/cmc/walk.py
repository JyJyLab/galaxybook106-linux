import struct,sys,collections
d=open(sys.argv[1],'rb').read()
assert d[:4]==b'CPFF'
print('CPFF size',struct.unpack_from('<I',d,4)[0],'file',len(d))
# find AIQB blocks
o=0x20
while o+24<=len(d):
    tag=d[o:o+4]; size=struct.unpack_from('<I',d,o+4)[0]
    print('block',tag,hex(o),'size',hex(size))
    if tag!=b'AIQB': break
    p=o+24; end=o+size
    names=collections.Counter()
    while p+8<=end:
        sz,fmt,key,nid=struct.unpack_from('<IBBH',d,p)
        if sz<8: print('  bad rec at',hex(p),sz); break
        names[nid]+=1
        print('  rec @%06x size %6d fmt %3d key %d name %d'%(p,sz,fmt,key,nid))
        p+=sz
    o=end
    if o>=len(d): break
