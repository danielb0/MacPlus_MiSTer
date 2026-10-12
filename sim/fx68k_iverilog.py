"""Make an iverilog-compatible copy of rtl/fx68k/fx68k.sv (sim only).

iverilog rejects two things fx68k does: unpacked structs, and struct ports
whose members are driven piecewise (some by `assign`, some by always_ff). The
structs hold only logic fields, so packing them changes nothing. In the one
module that DRIVES each struct, every `X.member` becomes a flat `X_member`
signal, and the struct is assembled once with a single `assign X = {...}`.
Consumers keep reading `X.member` from the packed struct.

    python sim/fx68k_iverilog.py            -> sim/out/fx68k_sim.sv
"""
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'rtl', 'fx68k', 'fx68k.sv')
DST = os.path.join(ROOT, 'sim', 'out', 'fx68k_sim.sv')

# struct type -> (variable name, module that drives it)
DRIVEN = {'s_clks': ('Clks', 'fx68k'),
          's_irdecod': ('Irdecod', 'irdDecode'),
          's_nanod': ('Nanod', 'nDecoder3')}

src = open(SRC).read()

# member lists, in declaration order (first member = MSB of the packed struct)
members = {}
for body, name in re.findall(r'typedef struct \{(.*?)\}\s*(\w+);', src, re.S):
    lst = []
    for line in body.split('\n'):
        line = line.split('//')[0].strip()
        m = re.match(r'logic\s*(\[[^\]]+\])?\s*(.*);', line)
        if not m:
            continue
        for n in m.group(2).split(','):
            lst.append((m.group(1) or '', n.strip()))
    members[name] = lst
src = src.replace('typedef struct {', 'typedef struct packed {')


# iverilog also wants a cast wherever a ?: yields an enum; plain ints don't
def de_enum(m):
    vals, n, items = [], 0, []
    for it in m.group(1).split(','):
        it = it.strip()
        if '=' in it:
            name, v = [x.strip() for x in it.split('=')]
            n = int(v)
        else:
            name = it
        items.append('%s = %d' % (name, n))
        n += 1
    return 'localparam int unsigned %s;\n\tint unsigned %s;' % (', '.join(items), m.group(2))


src = re.sub(r'enum int unsigned\s*\{([^}]*)\}\s*([\w, ]+);', de_enum, src)

# split into modules and rewrite the driving one for each struct
parts = re.split(r'(?m)^(?=module )', src)
out = []
for part in parts:
    mm = re.match(r'module\s+(\w+)', part)
    for stype, (var, mod) in DRIVEN.items():
        if not mm or mm.group(1) != mod:
            continue
        flat = members[stype]
        part = re.sub(r'\b%s\.(\w+)' % var, r'%s_\1' % var, part)
        decl = ''.join('\tlogic %s %s_%s;\n' % (w, var, n) for w, n in flat)
        pack = '\tassign %s = {%s};\n' % (var, ', '.join('%s_%s' % (var, n) for _, n in flat))
        # insert after the port list (first ');' that closes the header)
        hdr_end = part.index(');') + 2
        part = part[:hdr_end] + '\n' + decl + pack + part[hdr_end:]
    out.append(part)

os.makedirs(os.path.dirname(DST), exist_ok=True)
open(DST, 'w', newline='\n').write(''.join(out))
print('wrote', DST)
