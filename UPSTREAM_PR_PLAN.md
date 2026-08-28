# Plan: preparing the MacPlus_MiSTer upstream PR

Decided 2026-08-28. Nothing here is started. `scsi-upgrade` is untouched and
stays the development branch.

## The decision, and what drove it

`scsi-upgrade` against `master` is **54 files, 27,004 insertions, 96 commits**.
That is not a reviewable PR. But most of it is not code:

| | lines |
|---|---|
| `sim/` (benches + `.hex` fixtures) | 15,482 |
| `SCSI_UPGRADE_PLAN.md` | 3,765 |
| `scripts/` | 621 |
| probe deck (`dbg_probes.sv`, `build_tag.v`) | 651 |
| `FLOPPY_WRITE_PLAN.md` | 447 |

**The upstream repo's own convention settles what to include.** `git ls-tree
master` is: `.gitignore`, `MacPlus.qpf`, `MacPlus.qsf`, `MacPlus.srf`,
`MacPlus.sv`, `clean.bat`, `files.qip`, `readme.md`, `releases`, `rtl`, `sys`.
**No `sim/`, no `scripts/`, no debug scaffolding, one `readme.md`.** So plan
docs, testbenches and the probe deck are all out — not as a judgement call, but
because the repo does not carry that kind of thing.

Trimmed to match, the PR becomes:

| | before | after |
|---|---|---|
| floppy-write vs master | 12,937 | **2,127** (13 files) |
| scsi-upgrade vs floppy-write | 14,079 | **3,923** (10 files) |
| **combined** | 27,004 | **~6,050** |

**One PR, not two** (user, 2026-08-28). The split argument was a function of the
27k size and evaporates at 6k; it is also one recompile/retest cycle instead of
two. Residual risk, accepted: an objection to either half stalls both.

Everything dropped stays on the fork, which is public.

## What to strip, precisely

**`bus_hold` is FUNCTIONAL and MUST STAY.** It feeds `_cpuDTACK` and is the
entire hold-off fix. Only these come out:

* `frontier_evt` — ncr5380.sv, dataController_top.sv, MacPlus.sv
* `dbg_bus` / `scsi_dbg` — ncr5380.sv, dataController_top.sv, MacPlus.sv
* `dbg_abort` — scsi.v, ncr5380.sv
* `rtl/dbg_probes.sv`, `rtl/build_tag.v`, and the `ifdef USE_SCSI_ISSP` block
* `USE_SCSI_ISSP` macro and the dropped file entries in `MacPlus.qsf` /
  `files.qip`

**The benches survive stripping.** Verified 2026-08-28: `tb_ncr5380_seam.v` has
ZERO references to `frontier_evt`, `dbg_bus` or `dbg_abort`. It reaches
internals by hierarchy (`target.frontier_violated`, `target.sense_asc`,
`target.wdog_abort`), which port removal does not affect. So the full sim ladder
still runs against stripped RTL. The one casualty is `tb_dbg_probes.v`, which
tests the deck itself.

**Keep `scsi-upgrade` intact as the debug branch.** The probe deck found the
2026-08-22 wedge and is what proved the hold-off engaged (`PHLD holds/breaches`).
Cherry-pick it back if a future hardware bug needs it, rather than rebuilding it.

## Steps

1. Cut a PR branch from `master`.
2. Drop `sim/`, `scripts/`, both plan docs, `dbg_probes.sv`, `build_tag.v`.
3. Strip `frontier_evt` / `dbg_bus` / `dbg_abort` and their plumbing. **Keep
   `bus_hold`.**
4. Remove `USE_SCSI_ISSP` and the dropped entries from `MacPlus.qsf` /
   `files.qip`.
5. Settle the **68020 question** (asked on the forum). Removing an OSD option
   after merge annoys users more than never shipping it.
6. Re-run the sim ladder against stripped RTL — expected unaffected, cheap check.
   Gates: `tb_ncr5380_seam` 81/81, `tb_scsi_target`, `tb_scsi_cdrom`,
   `tb_cd_mix` 18/18.
7. **Recompile** (ask first, per standing rule) and hardware smoke test: boot,
   CD read + audio, a CD->disk copy, floppy write. Non-negotiable — no build
   without the probe deck has ever been run.
8. Open the PR.

## Dependency

**Main_MiSTer PR #1295 merged 2026-08-27** (`9b193ea`, squashed). But the last
Main release is `MiSTer_20260823`, cut BEFORE the merge, so the gate is not in
any released binary yet. Releases run every 1-3 months, irregularly.

Consequence: even after this core PR merges, CD-ROM only reaches ordinary users
when the next Main release ships. Keep the patched binary attached to the forum
post until then. Watch with:

```
git fetch upstream && git ls-tree upstream/master --name-only releases/ | tail -3
```

## Not doing

* Splitting into two PRs — see above.
* Shipping the plan docs, benches or probe deck — see above.
* Stripping `bus_hold` — it is the fix.
