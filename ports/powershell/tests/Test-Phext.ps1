# Test suite for libphext-powershell — plain assertions, no framework.
# Run: Test-Phext.ps1 [fixtures_dir]
param([string]$FixturesDir)

. (Join-Path $PSScriptRoot '..' 'src' 'Phext.ps1')

$script:Checks = 0
$script:Failures = 0

function Assert-Ok([bool]$cond, [string]$name) {
    $script:Checks++
    if (-not $cond) {
        $script:Failures++
        [Console]::Error.WriteLine("FAIL: $name")
    }
}
function Assert-Eq($a, $b, [string]$name) { Assert-Ok ($a -eq $b) $name }
function Assert-Eqb([byte[]]$a, [byte[]]$b, [string]$name) {
    $eq = $a.Length -eq $b.Length
    if ($eq) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $eq = $false; break } } }
    Assert-Ok $eq $name
}
function B([string]$s) { return ,([Phext]::Enc.GetBytes($s)) }
function C([string]$s) { return [Phext]::CoordParse($s) }
function Throws([scriptblock]$sb) { try { & $sb; return $false } catch { return $true } }

$SB = [char]0x17; $LB = [char]0x01; $TB = [char]0x18

# coordinate
Assert-Eq ([Phext]::CoordString((C '1.2.3/4.5.6/7.8.9'))) '1.2.3/4.5.6/7.8.9' 'coord format'
Assert-Ok (([Phext]::CoordCompare((C '1.1.1/1.1.1/1.1.1'), (C '1.1.1/1.1.1/1.1.2'))) -lt 0) 'order scroll'
Assert-Ok (([Phext]::CoordCompare((C '1.1.1/1.1.1/1.1.9'), (C '1.1.1/1.1.2/1.1.1'))) -lt 0) 'order section'
Assert-Ok (([Phext]::CoordCompare((C '2.1.1/1.1.1/1.1.1'), (C '1.9.9/9.9.9/9.9.9'))) -gt 0) 'order library'
Assert-Eq ([Phext]::CoordString((C '1.1.1/1.1.1/1.1.1'))) ([Phext]::CoordString([Phext]::CoordRoot())) 'root'
Assert-Ok (Throws { [void](C '0.1.1/1.1.1/1.1.1') }) 'coord rejects 0'
Assert-Ok (Throws { [void](C '1.1/1.1.1/1.1.1') }) 'coord rejects short'

# phokenize
$sc = [Phext]::Phokenize((B 'hello'))
Assert-Eq $sc.Count 1 'one scroll'
Assert-Eq ([Phext]::CoordString($sc[0].Coord)) '1.1.1/1.1.1/1.1.1' 'first coord'
Assert-Eqb $sc[0].Text (B 'hello') 'first text'
$sc = [Phext]::Phokenize((B "a${SB}b${SB}${SB}c`nline2"))
Assert-Eq $sc.Count 3 'scroll breaks'
Assert-Eq ([Phext]::CoordString($sc[1].Coord)) '1.1.1/1.1.1/1.1.2' 'second coord'
Assert-Eq ([Phext]::CoordString($sc[2].Coord)) '1.1.1/1.1.1/1.1.4' 'gap coord advance'
Assert-Eqb $sc[2].Text (B "c`nline2") 'newline is ordinary text'
$sc = [Phext]::Phokenize((B "x${LB}y"))
Assert-Eq ([Phext]::CoordString($sc[1].Coord)) '2.1.1/1.1.1/1.1.1' 'library break resets'
$sc = [Phext]::Phokenize((B "x${TB}y"))
Assert-Eq ([Phext]::CoordString($sc[1].Coord)) '1.1.1/1.1.1/1.2.1' 'section break'
Assert-Eq ([Phext]::Phokenize((B ''))).Count 0 'empty buffer'
$sc = [Phext]::Phokenize([byte[]]@(0x61, 0x00, 0xFF, 0x62))
Assert-Eq $sc.Count 1 'binary text is one scroll'
Assert-Eq $sc[0].Text.Length 4 'binary text preserved'

# round trip
$sample = B "alpha${SB}beta${TB}gamma${LB}delta"
Assert-Eqb ([Phext]::Dephokenize([Phext]::Phokenize($sample))) $sample 'round trip sample'
$list = [System.Collections.Generic.List[PositionedScroll]]::new()
$list.Add([PositionedScroll]::new((C '1.1.1/1.1.1/1.1.2'), (B 'two')))
$list.Add([PositionedScroll]::new((C '1.1.1/1.1.1/1.1.1'), (B 'one')))
Assert-Eqb ([Phext]::Dephokenize($list)) (B "one${SB}two") 'dephokenize sorts canonically'
Assert-Eqb ([Phext]::Normalize([Phext]::Normalize((B "${SB}${SB}lead")))) ([Phext]::Normalize((B "${SB}${SB}lead"))) 'normalize idempotent'

# fetch incl. gaps
$buf = B "one${SB}two${SB}${SB}four"
Assert-Eqb ([Phext]::Fetch($buf, (C '1.1.1/1.1.1/1.1.1'))) (B 'one') 'fetch 1'
Assert-Eqb ([Phext]::Fetch($buf, (C '1.1.1/1.1.1/1.1.4'))) (B 'four') 'fetch 4'
Assert-Eqb ([Phext]::Fetch($buf, (C '1.1.1/1.1.1/1.1.3'))) (B '') 'gap fetch is empty'
Assert-Eqb ([Phext]::Fetch($buf, (C '9.9.9/9.9.9/9.9.9'))) (B '') 'far gap fetch is empty'
Assert-Eqb ([Phext]::Fetch((B ''), (C '1.1.1/1.1.1/1.1.1'))) (B '') 'fetch empty buffer'

# insert
$out = [Phext]::Insert((B 'base'), (C '1.1.1/1.1.1/1.1.1'), (B '+more'))
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.1'))) (B 'base+more') 'insert appends after existing'
$out = [Phext]::Insert((B ''), (C '1.1.1/1.1.1/1.1.3'), (B 'new'))
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.3'))) (B 'new') 'insert creates at gap'
Assert-Eqb $out (B "${SB}${SB}new") 'insert at gap emits breaks'
$out = [Phext]::Insert((B "a${SB}c"), (C '1.1.1/1.1.1/1.1.2'), (B 'b'))
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.2'))) (B 'cb') 'insert merges existing + inserted'

# replace / remove — remove is coordinate-preserving
$out = [Phext]::Replace((B "old${SB}keep"), (C '1.1.1/1.1.1/1.1.1'), (B 'new'))
Assert-Eqb $out (B "new${SB}keep") 'replace overwrites'
$out = [Phext]::Replace((B 'a'), (C '1.1.1/1.1.1/1.1.5'), (B 'deep'))
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.5'))) (B 'deep') 'replace creates'
$out = [Phext]::Remove((B "a${SB}b${SB}c"), (C '1.1.1/1.1.1/1.1.2'))
Assert-Eqb $out (B "a${SB}${SB}c") 'remove leaves a gap (no renumbering)'
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.2'))) (B '') 'removed coordinate reads empty'
Assert-Eqb ([Phext]::Fetch($out, (C '1.1.1/1.1.1/1.1.3'))) (B 'c') 'neighbour keeps its coordinate'
Assert-Eq ([Phext]::Remove((B 'only'), (C '1.1.1/1.1.1/1.1.1'))).Length 0 'remove sole scroll'
Assert-Eqb ([Phext]::Remove((B 'a'), (C '5.5.5/5.5.5/5.5.5'))) (B 'a') 'remove gap is a no-op'

# explode / implode
$map = [Phext]::Explode((B "x${SB}y"))
Assert-Eq $map.Count 2 'explode count'
Assert-Eqb ([Phext]::Implode($map)) (B "x${SB}y") 'implode round trip'

# Dynamic + Transitive equivalence with the string path
$dyn = [DynamicPhext]::new()
$trn = [TransitivePhext]::new()
$script:StrBuf = B ''
function Step([string]$op, [string]$coord, [string]$text) {
    $c = C $coord
    $t = B $text
    switch ($op) {
        'insert' {
            $script:StrBuf = [Phext]::Insert($script:StrBuf, $c, $t)
            $dyn.Insert($c, $t); $trn.Insert($c, $t)
        }
        'replace' {
            $script:StrBuf = [Phext]::Replace($script:StrBuf, $c, $t)
            $dyn.Replace($c, $t); $trn.Replace($c, $t)
        }
        'remove' {
            $script:StrBuf = [Phext]::Remove($script:StrBuf, $c)
            $dyn.Remove($c); $trn.Remove($c)
        }
    }
    Assert-Eqb ($dyn.Serialize()) $script:StrBuf "dynamic == string after $op $coord"
    Assert-Eqb ($trn.Serialize()) $script:StrBuf "transitive == string after $op $coord"
    Assert-Eqb ($dyn.Fetch($c)) ([Phext]::Fetch($script:StrBuf, $c)) 'dynamic fetch after op'
    Assert-Eqb ($trn.Fetch($c)) ([Phext]::Fetch($script:StrBuf, $c)) 'transitive fetch after op'
}
Step 'insert' '1.1.1/1.1.1/1.1.1' 'alpha'
Step 'insert' '1.1.1/1.1.1/1.1.3' 'gamma'
Step 'insert' '1.1.1/1.1.1/1.1.2' 'beta'
Step 'insert' '1.1.1/1.1.1/1.1.2' '+'
Step 'replace' '2.1.1/1.1.1/1.1.1' 'lib2'
Step 'remove' '1.1.1/1.1.1/1.1.3' ''
Assert-Eqb ($dyn.Fetch((C '1.1.1/1.1.1/1.1.3'))) (B '') 'dynamic removed coord is gap'
Assert-Eqb ($trn.Fetch((C '1.1.1/1.1.1/1.1.3'))) (B '') 'transitive removed coord is gap'
Assert-Eqb ($dyn.Fetch((C '2.1.1/1.1.1/1.1.1'))) (B 'lib2') 'dynamic neighbour unmoved'
Assert-Eqb ($trn.Fetch((C '2.1.1/1.1.1/1.1.1'))) (B 'lib2') 'transitive neighbour unmoved'
Step 'insert' '1.1.1/1.1.1/1.1.1' ''
Step 'replace' '1.1.1/1.1.1/1.1.1' ''
Assert-Eq ($dyn.Length()) ($trn.Length()) 'store lengths agree'

# DynamicPhext capacity discipline
$cap = [DynamicPhext]::new()
for ($i = 1; $i -le 64; $i++) { $cap.Append([long[]]@(1, 1, 1, 1, 1, 1, 1, 1, $i), (B 's')) }
Assert-Eq $cap.Capacity 64 'capacity doubles to fit 64'
Assert-Ok ($cap.ResizeCount -le 7) 'resize count is logarithmic'

# fixtures
if ($FixturesDir) {
    $files = 0; $identical = 0; $idem = 0
    $paths = Get-ChildItem -Path $FixturesDir -Recurse -Filter 'input.phext' -File
    foreach ($p in $paths) {
        $files++
        $data = [System.IO.File]::ReadAllBytes($p.FullName)
        $rt = [Phext]::Dephokenize([Phext]::Phokenize($data))
        $sameRt = $rt.Length -eq $data.Length
        if ($sameRt) { for ($i = 0; $i -lt $rt.Length; $i++) { if ($rt[$i] -ne $data[$i]) { $sameRt = $false; break } } }
        if ($sameRt) { $identical++ }
        $n1 = [Phext]::Normalize($data)
        $n2 = [Phext]::Normalize($n1)
        $same = $n1.Length -eq $n2.Length
        if ($same) { for ($i = 0; $i -lt $n1.Length; $i++) { if ($n1[$i] -ne $n2[$i]) { $same = $false; break } } }
        if ($same) { $idem++ }
    }
    Write-Output "fixtures: $files input.phext, $identical byte-identical round-trips, $idem normalize-idempotent"
    Assert-Eq $files 16 '16 fixtures found'
    Assert-Eq $identical $files 'fixtures byte-identical round-trips'
    Assert-Eq $idem $files 'all fixtures normalize idempotently'
} else {
    Write-Output 'fixtures: skipped (no fixtures dir)'
}

Write-Output "powershell suite: $script:Checks checks, $script:Failures failures"
exit $(if ($script:Failures -eq 0) { 0 } else { 1 })
