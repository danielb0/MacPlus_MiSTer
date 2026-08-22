# Regenerate rtl/build_tag.v from the current HEAD, so a hardware capture can
# name the bitstream it came from (read back on the PBLD probe).
#
# Run this IMMEDIATELY BEFORE a Quartus compile, after everything else is
# committed. The tag then names the commit whose RTL is being built, and
# build_tag.v itself is left dirty in the tree -- that is expected and correct.
#
# The file is COMMITTED as 0 ("unstamped") on purpose, so a missed stamp reads
# back as UNSTAMPED instead of as the previous commit's SHA. Never commit the
# stamped value -- a stray 'git add -A' has poisoned it before.
#
# It exists because on 2026-08-22 the tag was hand-stamped, then committed, and
# so ended up naming the PREVIOUS commit: the file said ac38fc96 while HEAD was
# 3426398e. A capture that misnames its own build is worse than no tag at all.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $sha = (git rev-parse --short=8 HEAD).Trim()
    if ($sha -notmatch '^[0-9a-f]{8}$') { throw "unexpected SHA from git: '$sha'" }

    $dirty = git status --porcelain -- rtl sys MacPlus.sv MacPlus.qsf |
             Where-Object { $_ -notmatch 'rtl/build_tag\.v' }
    if ($dirty) {
        Write-Warning "Design files are dirty; the tag will name HEAD, not what you are building:"
        $dirty | ForEach-Object { Write-Warning "  $_" }
    }

    $body = @"
// build_tag.v -- REGENERATED BEFORE EVERY COMPILE, do not hand-edit.
// Written by scripts/stamp_build_tag.ps1 from: git rev-parse --short=8 HEAD
//
// Why this exists: on 2026-08-22 two different RTL fixes produced byte-for-byte
// identical probe captures, and there was no way to tell from the board whether
// the second build had actually been loaded -- the .rbf is loaded from the build
// directory, so which bitstream is running depends on when the core was last
// loaded, not on when it was compiled. A capture must be able to name its own
// bitstream. Read back on the PBLD probe and printed by read_probes.tcl.
module build_tag(output [31:0] tag);
	assign tag = 32'h$sha;
endmodule
"@
    # NOT Set-Content -Encoding utf8: on Windows PowerShell 5.1 that writes a
    # BOM, and iverilog then fails to parse the file -- it reports build_tag as
    # a missing module and produces no executable, which is easy to miss if a
    # stale .vvp is still lying around. Write plain UTF-8, no BOM.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $root 'rtl/build_tag.v'), ($body + "`r`n"), $utf8NoBom)
    Write-Host "rtl/build_tag.v stamped $sha"
} finally { Pop-Location }
