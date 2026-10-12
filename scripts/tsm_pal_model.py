"""CPU_TIMING_PLAN.md Phase 0. Mac Plus TSM (16R4) cycle model from the JED2EQN equations in
C:/temp/Mac/PALs/pals.txt, driven by a 68000 bus-cycle model.

Pins: i2 C16M, i3 C8M, i4 VID/u*, i5 /RAM, i6 /ROM, i7 /AS, i8 /UDS, i9 /LDS
      rf14 /RAS, rf15 TC, rf16 C1M, rf17 C4M   (registered on C16M rise)
      f12 /CASL, f13 /CASR, f18 C2M, f19 /DTACK (combinational, latching)
Convention: '/x := expr' means pin x is LOW after the clock when expr is true.

Time step = half a C16M period. Even steps: C16M rising edge, C16M=1.
Odd steps: C16M falling edge, C16M=0.
"""
import sys, itertools

def tsm_regs(p):
    i2,i3,i4,i5,i6,i7,i8,i9 = p['C16M'],p['C8M'],p['VID'],p['nRAM'],p['nROM'],p['nAS'],p['nUDS'],p['nLDS']
    rf14,rf15,rf16,rf17 = p['nRAS'],p['TC'],p['C1M'],p['C4M']
    f12,f18,f19 = p['nCASL'],p['C2M'],p['nDTACK']
    n = lambda x: 1 - x
    lo14 = (n(i3) and rf17 and n(rf16) and rf14 and n(f12)) or \
           (n(i3) and rf17 and n(rf16) and rf14 and i9) or \
           (n(i3) and rf17 and n(rf16) and rf14 and i8) or \
           (i3 and f18 and n(rf17)) or (i3 and n(rf17) and rf16) or \
           (n(f18) and n(rf14)) or (n(rf17) and n(rf14)) or (i3 and n(rf14))
    lo17 = (n(i3) and n(f18) and rf17 and n(rf14)) or \
           (n(i3) and i4 and n(rf17) and rf16) or (i3 and f18 and rf14) or \
           (n(i3) and n(rf17) and rf14) or (rf16 and rf14)
    lo16 = (n(i3) and n(f18) and rf17 and rf16 and n(rf14)) or \
           (f18 and n(rf16)) or (n(rf17) and n(rf16)) or (n(rf16) and rf14) or \
           (i3 and n(rf16))
    lo15 = f18 or n(rf17) or n(rf16) or rf14 or i3
    return {'nRAS': int(not lo14), 'C4M': int(not lo17),
            'C1M': int(not lo16), 'TC': int(not lo15)}

def tsm_comb(p):
    """Iterate the latching combinational outputs to a fixpoint."""
    n = lambda x: 1 - x
    for _ in range(20):
        i2,i3,i4,i5,i6,i7,i8,i9 = p['C16M'],p['C8M'],p['VID'],p['nRAM'],p['nROM'],p['nAS'],p['nUDS'],p['nLDS']
        rf14,rf15,rf16,rf17 = p['nRAS'],p['TC'],p['C1M'],p['C4M']
        f12,f13,f18,f19 = p['nCASL'],p['nCASR'],p['C2M'],p['nDTACK']
        lo19 = (n(i2) and n(i3) and rf17 and n(i5) and n(rf16) and n(i6) and n(i7) and rf14) or \
               (n(i2) and n(i3) and n(i4) and n(rf17) and n(i5) and i6 and n(i7) and n(rf14)) or \
               (n(i2) and n(i3) and n(rf17) and n(i5) and n(rf16) and i6 and n(i7) and n(rf14)) or \
               (n(i2) and n(i3) and n(rf17) and i5 and n(i6) and n(i7) and n(rf14)) or \
               (n(f19) and n(i9)) or (n(f19) and n(i8)) or (n(f19) and n(rf14))
        lo18 = (n(i2) and n(i3) and n(rf17) and n(i5) and n(rf16) and n(i6) and n(i7)) or \
               (n(i2) and n(i3) and n(rf17) and n(rf14)) or \
               (n(f18) and i4 and rf16) or (n(f18) and n(rf16) and n(rf15)) or \
               (n(f18) and rf17) or (i2 and n(f18)) or (n(i3) and n(f18))
        lo13 = (n(f19) and n(f18) and n(i4) and rf17 and n(i5) and i6 and n(rf14) and n(i8)) or \
               (n(f18) and i4 and rf17 and rf16 and n(rf14)) or (n(rf14) and n(f13))
        lo12 = (n(f19) and n(f18) and n(i4) and rf17 and n(i5) and i6 and n(rf14) and n(i9)) or \
               (n(f19) and i3 and n(f18) and rf17 and n(rf16) and rf14) or \
               (n(f18) and i4 and rf17 and rf16 and n(rf14)) or \
               (n(f18) and n(rf16) and n(f12)) or (n(rf14) and n(f12))
        new = {'nDTACK': int(not lo19), 'C2M': int(not lo18),
               'nCASR': int(not lo13), 'nCASL': int(not lo12)}
        if all(p[k] == v for k, v in new.items()):
            return
        p.update(new)
    raise RuntimeError('comb outputs oscillate')


class CPU:
    """68000 bus timing. A program is a list of (kind, idle_clocks_before):
    kind in 'RAM', 'ROM', 'IO'(VPA-less, e.g. SCC), with reads only."""
    def __init__(self, prog, delay):
        self.prog = list(prog)
        self.delay = delay          # half-C16M steps from C8M edge to pins
        self.pending = []           # (apply_at_step, {pin: val})
        self.state = 'IDLE'
        self.idle_left = 0
        self.idx = 0
        self.s = None
        self.starts = []            # step of each S0
        self.waits = []
        self.cur_wait = 0
        self.pins = {'nAS': 1, 'nUDS': 1, 'nLDS': 1, 'nRAM': 1, 'nROM': 1}
        self._load_next()

    def _load_next(self):
        if self.idx >= len(self.prog):
            self.state = 'DONE'; return
        kind, idle = self.prog[self.idx]
        self.kind = kind
        self.idle_left = idle * 2   # in C8M half-clocks
        self.state = 'IDLE' if idle else 'WAIT_S0'

    def drive(self, step, vals):
        self.pending.append((step + self.delay, vals))

    def apply(self, step):
        keep = []
        for at, v in self.pending:
            if at <= step: self.pins.update(v)
            else: keep.append((at, v))
        self.pending = keep

    def edge(self, step, rising, dtack_before):
        """Called on each C8M edge (rising/falling)."""
        if self.state == 'DONE': return
        if self.state == 'IDLE':
            self.idle_left -= 1
            if self.idle_left <= 0:
                self.state = 'WAIT_S0'
                if rising: self.edge(step, True, dtack_before)
            return
        if self.state == 'WAIT_S0':
            if not rising: return
            self.state = 'BUS'; self.s = 0
            self.starts.append(step); self.cur_wait = 0
            sel = {'RAM': (0, 1), 'ROM': (1, 0), 'IO': (0, 0)}[self.kind]
            self.drive(step, {'nRAM': sel[0], 'nROM': sel[1]})
            return
        # BUS: advance S states
        s = self.s
        if s == 0: self.s = 1                       # falling: S1
        elif s == 1:                                 # rising: S2, AS+DS low
            self.s = 2; self.drive(step, {'nAS': 0, 'nUDS': 0, 'nLDS': 0})
        elif s == 2: self.s = 3                       # falling: S3
        elif s == 3: self.s = 4                       # rising: S4
        elif s == 4:                                  # falling: sample DTACK
            if dtack_before == 0: self.s = 5
            else: self.s = 'W1'; self.cur_wait += 1
        elif s == 'W1': self.s = 'W2'                 # rising
        elif s == 'W2':                               # falling: resample
            if dtack_before == 0: self.s = 5
            else: self.s = 'W1'; self.cur_wait += 1
        elif s == 5: self.s = 6                       # rising: S6
        elif s == 6:                                  # falling: S7, latch, negate
            self.s = 7
            self.drive(step, {'nAS': 1, 'nUDS': 1, 'nLDS': 1})
        elif s == 7:                                  # rising: end of cycle
            self.waits.append(self.cur_wait)
            self.drive(step, {'nRAM': 1, 'nROM': 1})
            self.idx += 1; self._load_next()
            # a zero-idle next cycle starts on THIS rising edge
            if self.state == 'WAIT_S0':
                self.edge(step, True, dtack_before)


def run(prog, active, delay, phase_skew=0, steps=40000, trace=False):
    p = {'C16M': 0, 'C8M': 0, 'VID': 0, 'nRAM': 1, 'nROM': 1, 'nAS': 1,
         'nUDS': 1, 'nLDS': 1, 'nRAS': 1, 'TC': 0, 'C1M': 0, 'C4M': 0,
         'nCASL': 1, 'nCASR': 1, 'C2M': 1, 'nDTACK': 1}
    cpu = None
    rows = []
    for step in range(steps):
        rising16 = (step % 2 == 0)
        if rising16:
            # registers capture values from before the edge
            regs = tsm_regs(p)
            vid_next = p['C1M'] if active else 0      # LAG: VID/u* := C1M (display)
            c8_next = 1 - p['C8M']                    # TSG: /C8M := C8M
            old_c8 = p['C8M']
            dtack_before = p['nDTACK']
            p.update(regs); p['VID'] = vid_next; p['C8M'] = c8_next; p['C16M'] = 1
            if prog is not None and cpu is None and step >= 2000 + phase_skew and c8_next == 1:
                cpu = CPU(prog, delay)
            if cpu:
                cpu.edge(step, c8_next == 1, dtack_before)
        else:
            p['C16M'] = 0
        if cpu:
            cpu.apply(step)
            for k in ('nAS', 'nUDS', 'nLDS', 'nRAM', 'nROM'): p[k] = cpu.pins[k]
        tsm_comb(p)
        if trace and len(rows) < trace:
            rows.append((step, dict(p), cpu.s if cpu else None))
        if cpu and cpu.state == 'DONE':
            break
    return cpu, rows


if __name__ == '__main__':
    # CPU_TIMING_PLAN.md Phase 0: wait states by bus-cycle start phase
    # (C8M clocks since the C1M rising edge), for both pin-delay assumptions.
    import random
    from collections import defaultdict
    random.seed(1)
    for delay in (0, 2):
        for kind, active in (('RAM', False), ('RAM', True), ('ROM', False),
                             ('ROM', True), ('IO', False)):
            prog = [(kind, random.choice([4, 5, 6, 7, 9, 10, 11, 13]))
                    for _ in range(300)]
            cpu, rows = run(prog, active, delay, steps=60000, trace=60000)
            c1 = [r[0] for i, r in enumerate(rows[1:], 1)
                  if r[1]['C1M'] == 1 and rows[i-1][1]['C1M'] == 0]
            table = defaultdict(set)
            for st, w in zip(cpu.starts, cpu.waits):
                table[(st - max(e for e in c1 if e <= st)) // 4].add(w)
            print(delay, kind, 'display' if active else 'blank  ',
                  {k: sorted(v) for k, v in sorted(table.items())})
