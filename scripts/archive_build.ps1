# Archive the freshly built bitstream under the commit it came from.
#
#   powershell -File scripts/archive_build.ps1 ackgate
#
# Produces output_files/MacPlus_<sha>_<label>.rbf (and .sof).
#
# Why: on 2026-08-22 two builds produced byte-identical hardware captures and
# answering "which build was that?" took a JTAG session enumerating ISSP
# instances, because output_files/MacPlus.rbf is one file every compile
# overwrites. PBLD answers it live; this answers it afterwards, off-board.
param([Parameter(Mandatory=$true)][string]$Label)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if ($Label -notmatch '^[A-Za-z0-9._-]+$') { throw "label must be alphanumeric/._- : '$Label'" }
    $sha = (git rev-parse --short=8 HEAD).Trim()

    # The tag compiled into the bitstream must name the commit we are archiving
    # it as, or the archive filename and PBLD will disagree on the board.
    $tagLine = Select-String -Path 'rtl/build_tag.v' -Pattern "assign tag = 32'h([0-9a-f]{8})"
    if (-not $tagLine) { throw "cannot read the tag from rtl/build_tag.v" }
    $tag = $tagLine.Matches[0].Groups[1].Value
    if ($tag -ne $sha) {
        throw ("rtl/build_tag.v says $tag but HEAD is $sha. The build carries the " +
               "wrong tag; re-stamp and recompile rather than archiving a bitstream " +
               "that misnames itself.")
    }

    foreach ($ext in 'rbf','sof') {
        $src = "output_files/MacPlus.$ext"
        if (-not (Test-Path $src)) { Write-Warning "no $src, skipping"; continue }
        $dst = "output_files/MacPlus_${sha}_${Label}.$ext"
        if (Test-Path $dst) { throw "$dst already exists; pick another label" }
        Copy-Item $src $dst
        Write-Host "archived $dst"
    }
} finally { Pop-Location }
