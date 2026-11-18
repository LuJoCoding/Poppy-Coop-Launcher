#!/usr/bin/env python3
"""Copies the binary files Launcher 3 embeds out of the original PoppyCoop Launcher 2.0 exe into res/:
10_101.bin dwmapi.dll (UE4SS proxy loader), 10_102.bin UE4SS.dll, 10_109.bin PoppyCoopNet.exe.
They are not kept in git (size / third-party binaries).   usage: extract_res.py <PoppyCoopLauncher 2.0 exe>"""
import struct, sys, os
d = open(sys.argv[1], 'rb').read()
u16 = lambda o: struct.unpack_from('<H', d, o)[0]
u32 = lambda o: struct.unpack_from('<I', d, o)[0]
pe = u32(0x3c); n = u16(pe + 6); so = pe + 24 + u16(pe + 20)
secs = [(d[so+40*i:so+40*i+8].rstrip(b'\0'), u32(so+40*i+12), u32(so+40*i+20)) for i in range(n)]
name, va, ro = [s for s in secs if s[0] == b'.rsrc'][0]
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'res')
os.makedirs(out, exist_ok=True)
def walk(o, path):
    for k in range(u16(o + 12) + u16(o + 14)):
        nm, ent = u32(o + 16 + 8*k), u32(o + 20 + 8*k)
        if ent & 0x80000000: walk(ro + (ent & 0x7fffffff), path + [nm])
        elif path[0] == 10 and path[1] in (101, 102, 109):
            rva, size = u32(ro + ent), u32(ro + ent + 4)
            open(os.path.join(out, f'10_{path[1]}.bin'), 'wb').write(d[rva - va + ro: rva - va + ro + size])
            print(f'res/10_{path[1]}.bin ({size} bytes)')
walk(ro, [])
