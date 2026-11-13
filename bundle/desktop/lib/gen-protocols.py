#!/usr/bin/python3
"""gen-protocols.py <outdir> <xml>... — pywayland bindings (wayland core + the
given protocols) as one package <outdir>/gproto."""
import os, sys
from pywayland.scanner import Protocol

out = os.path.join(sys.argv[1], "gproto")
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "__init__.py"), "a").close()
protocols = [Protocol.parse_file(f) for f in sys.argv[2:] + ["/usr/share/wayland/wayland.xml"]]
imports = {i.name: p.name for p in protocols for i in p.interface}
for p in protocols:
    cur = dict(imports)
    cur.update({i.name: p.name for i in p.interface})
    p.output(out, cur)
