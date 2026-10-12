# CPU_TIMING_PLAN.md: PoP MDRV 11 fill loop ($28d2: move.b (a2)+,(a3) / lea 2(a3),a3 / dbra)
# timed per the Phase 0 TSM table, against the sound scan. 32 clocks/word in blanking
# (dbra internal 2 clocks puts the next fetch off the 4-clock grid), 56 in display (7 RAM cycles x 8).
# PoP MDRV fill (words 37..369 then 0..36) vs the sound scan, real Plus timing.
LINE, ACTIVE_FROM, DISP = 352, 28, 256   # clocks/line, first display line, display clocks/line
def cost(t, blank_c, disp_c):
    line, x = divmod(t, LINE)
    return disp_c if (line >= ACTIVE_FROM and x < DISP) else blank_c
def run(t0, blank_c, disp_c, S=37):
    t = t0; order = list(range(S, 370)) + list(range(0, S)); wt = {}
    for k in order:
        t += cost(t, blank_c, disp_c); wt.setdefault(k, t)
    # wrap part: word k (k < S) must be written AFTER the scan reads it (read at k*LINE)
    bad = [k for k in range(0, S) if wt[k] < k * LINE + LINE]   # read during line k
    return wt[0] / LINE, bad
for label, b, d in (('fast core today (30, no contention)', 30, 30),
                    ('grid only (32, no contention)', 32, 32),
                    ('real Plus (32 blank / 56 display)', 32, 56)):
    for t0w in (2.0, 2.5, 3.0, 3.5):
        wrap, bad = run(int(t0w * LINE), b, d)
        print(f'{label:38s} lat={t0w} words: wrap at line {wrap:5.1f}, overwritten before read: '
              f'{(bad[0], bad[-1]) if bad else "none -> CLEAN"}')
print()
for label, b, d in (('contention only, no grid (30 / 56)', 30, 56),):
    for t0w in (2.0, 2.5, 3.0):
        wrap, bad = run(int(t0w * LINE), b, d)
        print(f'{label:38s} lat={t0w} words: wrap at line {wrap:5.1f}, overwritten: {(bad[0], bad[-1]) if bad else "none -> CLEAN"}')
# margin: how many clocks of lat could be LOST before the real-Plus case buzzes
for t0 in range(0, 1200, 50):
    if run(t0, 32, 56)[1]:
        print('real Plus buzzes only if lat <', t0, 'clocks =', round(t0 / LINE, 2), 'words'); 
