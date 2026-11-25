# Hub-side CLI for libphext-powershell (Exocortical Telephone Game,
# contract v2).
#
# Transport: with the argument `serve`, stdin carries one JSON
# request per line and stdout carries one JSON response per line.
# With no argument, stdin carries ONE JSON object and stdout ONE
# response. State crosses the wire as base64 under "state".
# Serve lines over 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
#
# This CLI wraps only this port's own libphext (src/Phext.ps1).
# JSON is hand-written here (canonical form must match the harness's
# Python json.dumps exactly); SHA-256/base64/gzip are .NET's; PGP
# goes through subprocess gpg with a per-port GNUPGHOME
# (~/telephone-powershell/gnupg unless TELEPHONE_GNUPGHOME).
param([string[]]$ArgsRest)

. (Join-Path $PSScriptRoot 'Phext.ps1')

$script:Impl = 'powershell'
$script:IndexCoord = '1.1.1/1.1.1/1.1.1'
$script:KeysCoord = '1.1.1/1.1.1/1.1.2'
$script:KhCoord = '1.1.1/1.1.1/1.1.3'
$script:CacheMap = $null
$script:CacheHash = ''

# ---------------------------------------------------------------- JSON
class JsonParser {
    [string]$S
    [int]$Pos
    JsonParser([string]$s) { $this.S = $s; $this.Pos = 0 }

    [void] SkipWs() {
        while ($this.Pos -lt $this.S.Length) {
            $cp = [int]$this.S[$this.Pos]
            if ($cp -eq 32 -or $cp -eq 9 -or $cp -eq 10 -or $cp -eq 13) { $this.Pos++ } else { break }
        }
    }
    [char] Peek() { return $this.S[$this.Pos] }
    [char] NextCh() { $c = $this.S[$this.Pos]; $this.Pos++; return $c }
    [void] Expect([char]$c) {
        $got = $this.NextCh()
        if ($got -ne $c) { throw "expected $c got $got" }
    }
    [object] ParseValue() {
        $this.SkipWs()
        switch ($this.Peek()) {
            '{' { return $this.ParseObj() }
            '[' { return $this.ParseArr() }
            '"' { return $this.ParseStr() }
            't' { foreach ($c in 'true'.ToCharArray()) { $this.Expect($c) }; return $true }
            'f' { foreach ($c in 'false'.ToCharArray()) { $this.Expect($c) }; return $false }
            'n' { foreach ($c in 'null'.ToCharArray()) { $this.Expect($c) }; return $null }
            default { return $this.ParseNum() }
        }
        return $null
    }
    [hashtable] ParseObj() {
        $this.Expect('{')
        $this.SkipWs()
        $out = @{}
        if ($this.Peek() -eq '}') { [void]$this.NextCh(); return $out }
        while ($true) {
            $this.SkipWs()
            $k = $this.ParseStr()
            $this.SkipWs()
            $this.Expect(':')
            $out[$k] = $this.ParseValue()
            $this.SkipWs()
            $c = $this.NextCh()
            if ($c -eq '}') { break }
            if ($c -ne ',') { throw "expected , or }" }
        }
        return $out
    }
    [System.Collections.ArrayList] ParseArr() {
        $this.Expect('[')
        $this.SkipWs()
        $out = [System.Collections.ArrayList]::new()
        if ($this.Peek() -eq ']') { [void]$this.NextCh(); return $out }
        while ($true) {
            [void]$out.Add($this.ParseValue())
            $this.SkipWs()
            $c = $this.NextCh()
            if ($c -eq ']') { break }
            if ($c -ne ',') { throw "expected , or ]" }
        }
        return $out
    }
    [string] ParseStr() {
        $this.Expect('"')
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            $c = $this.NextCh()
            if ($c -eq '"') { break }
            if ($c -eq '\') {
                $e = $this.NextCh()
                switch ($e) {
                    'n' { [void]$sb.Append("`n") }
                    'r' { [void]$sb.Append("`r") }
                    't' { [void]$sb.Append("`t") }
                    'b' { [void]$sb.Append([char]8) }
                    'f' { [void]$sb.Append([char]12) }
                    'u' {
                        $cp = [Convert]::ToInt32($this.S.Substring($this.Pos, 4), 16)
                        $this.Pos += 4
                        [void]$sb.Append([char]$cp)
                    }
                    default { [void]$sb.Append($e) }
                }
            } else {
                [void]$sb.Append($c)
            }
        }
        return $sb.ToString()
    }
    [object] ParseNum() {
        $start = $this.Pos
        while ($this.Pos -lt $this.S.Length -and '-+0123456789.eE'.Contains($this.S[$this.Pos])) { $this.Pos++ }
        $txt = $this.S.Substring($start, $this.Pos - $start)
        if ($txt -match '[.eE]') { return [double]::Parse($txt, [System.Globalization.CultureInfo]::InvariantCulture) }
        return [long]::Parse($txt)
    }
}

function ConvertTo-JsonEscape([string]$s) {
    # Matches Python json.dumps(..., ensure_ascii=True).
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($cp -eq 10) { [void]$sb.Append('\n') }
        elseif ($cp -eq 13) { [void]$sb.Append('\r') }
        elseif ($cp -eq 9) { [void]$sb.Append('\t') }
        elseif ($cp -eq 8) { [void]$sb.Append('\b') }
        elseif ($cp -eq 12) { [void]$sb.Append('\f') }
        elseif ($cp -lt 0x20 -or $cp -gt 0x7E) { [void]$sb.Append(('\u{0:x4}' -f $cp)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-CanonInto($v, [System.Text.StringBuilder]$sb) {
    if ($null -eq $v) { [void]$sb.Append('null'); return }
    if ($v -is [bool]) { [void]$sb.Append($v.ToString().ToLower()); return }
    if ($v -is [string]) { [void]$sb.Append((ConvertTo-JsonEscape $v)); return }
    if ($v -is [long] -or $v -is [int]) { [void]$sb.Append($v.ToString()); return }
    if ($v -is [double]) { [void]$sb.Append($v.ToString([System.Globalization.CultureInfo]::InvariantCulture)); return }
    if ($v -is [hashtable] -or $v -is [System.Collections.Specialized.OrderedDictionary]) {
        [void]$sb.Append('{')
        $keys = @($v.Keys | Sort-Object)
        $first = $true
        foreach ($k in $keys) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            [void]$sb.Append((ConvertTo-JsonEscape $k))
            [void]$sb.Append(':')
            Write-CanonInto $v[$k] $sb
        }
        [void]$sb.Append('}')
        return
    }
    if ($v -is [System.Collections.IList]) {
        [void]$sb.Append('[')
        $first = $true
        foreach ($x in $v) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            Write-CanonInto $x $sb
        }
        [void]$sb.Append(']')
        return
    }
    throw "cannot write $($v.GetType())"
}

function ConvertTo-CanonJson($v) {
    $sb = [System.Text.StringBuilder]::new()
    Write-CanonInto $v $sb
    return $sb.ToString()
}

function Get-CanonBytes($v) { return ,([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonJson $v))) }

# ---------------------------------------------------------------- util
function Get-Sha256Hex([byte[]]$bs) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $d = $sha.ComputeHash($bs)
        return ($d | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
}

function ConvertTo-B64([byte[]]$bs) { return [Convert]::ToBase64String($bs) }
function ConvertFrom-B64([string]$s) { return [Convert]::FromBase64String($s) }

function ConvertTo-Latin1Bytes([string]$s) {
    $bytes = [byte[]]::new($s.Length)
    for ($i = 0; $i -lt $s.Length; $i++) {
        $cp = [int]$s[$i]
        if ($cp -gt 255) { throw 'latin-1 overflow' }
        $bytes[$i] = [byte]$cp
    }
    return ,$bytes
}

function ConvertFrom-Latin1Bytes([byte[]]$bs) { return [Phext]::Enc.GetString($bs) }
function ConvertFrom-Utf8Bytes([byte[]]$bs) { return [System.Text.Encoding]::UTF8.GetString($bs) }

function Get-StateBytes($req) {
    $s = $req['state']
    if ($null -eq $s) { $s = $req['state_b64'] }
    return ,([Convert]::FromBase64String($s))
}

function Compress-Gzip([byte[]]$bs) {
    $ms = [System.IO.MemoryStream]::new()
    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($bs, 0, $bs.Length)
    $gz.Close()
    return ,($ms.ToArray())
}

function Expand-Gzip([byte[]]$bs) {
    $ms = [System.IO.MemoryStream]::new($bs)
    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.MemoryStream]::new()
    $gz.CopyTo($out)
    $gz.Close()
    return ,($out.ToArray())
}

function Test-BytesEqual([byte[]]$a, [byte[]]$b) {
    if ($null -eq $a -or $null -eq $b) { return ($null -eq $a) -and ($null -eq $b) }
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}

# ---------------------------------------------------------------- gpg
function Get-GnupgHome {
    $h = $env:TELEPHONE_GNUPGHOME
    if (-not $h) { $h = Join-Path $HOME "telephone-$script:Impl/gnupg" }
    [void][System.IO.Directory]::CreateDirectory($h)
    try { & chmod 700 $h 2>$null } catch {}
    return $h
}

function Invoke-Gpg([string]$gpgHome, [string[]]$gpgArgs, [byte[]]$stdinBytes) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'gpg'
    foreach ($a in @('--batch', '--yes') + $gpgArgs) { [void]$psi.ArgumentList.Add($a) }
    $psi.Environment['GNUPGHOME'] = $gpgHome
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $stdinBytes) { $p.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length) }
    $p.StandardInput.Close()
    $ms = [System.IO.MemoryStream]::new()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "gpg failed: $err" }
    return ,($ms.ToArray())
}

function Invoke-Keygen {
    $gpgHome = Get-GnupgHome
    $uid = "telephone-$script:Impl"
    $keys = [System.Text.Encoding]::UTF8.GetString((Invoke-Gpg $gpgHome @('--list-keys', '--with-colons') $null))
    if (-not $keys.Contains('pub')) {
        [void](Invoke-Gpg $gpgHome @('--pinentry-mode', 'loopback', '--passphrase', '',
                                  '--quick-generate-key', $uid, 'ed25519', 'sign', 'never') $null)
    }
    $pub = [System.Text.Encoding]::UTF8.GetString((Invoke-Gpg $gpgHome @('--armor', '--export', $uid) $null))
    return @{ impl = $script:Impl; pubkey = $pub }
}

function Invoke-Attest($descriptor) {
    $gpgHome = Get-GnupgHome
    $uid = "telephone-$script:Impl"
    $sig = Invoke-Gpg $gpgHome @('--pinentry-mode', 'loopback', '--passphrase', '',
                              '--detach-sign', '--armor', '-u', $uid) (Get-CanonBytes $descriptor)
    return @{ signature = [System.Text.Encoding]::UTF8.GetString($sig) }
}

function Test-Signature([string]$pubkeysText, [byte[]]$data, [string]$sigB64) {
    try {
        $td = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $gpgHome = Join-Path $td 'gnupg'
        [void][System.IO.Directory]::CreateDirectory($gpgHome)
        try { & chmod 700 $gpgHome 2>$null } catch {}
        [void](Invoke-Gpg $gpgHome @('--import') ([System.Text.Encoding]::UTF8.GetBytes($pubkeysText)))
        $sigfile = Join-Path $td 'sig.asc'
        [System.IO.File]::WriteAllBytes($sigfile, [Convert]::FromBase64String($sigB64))
        [void](Invoke-Gpg $gpgHome @('--verify', $sigfile, '-') $data)
        return $true
    } catch {
        return $false
    } finally {
        if ($td -and (Test-Path $td)) { Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- game
function Invoke-Echo($ping) {
    return @{ impl = $script:Impl; echo = (Get-Sha256Hex (Get-CanonBytes @{ impl = $script:Impl; ping = $ping })) }
}

function Invoke-Elect([string]$position, $candidates, [long]$turn) {
    $names = @($candidates | ForEach-Object { [string]$_ })
    $pool = @($names | Where-Object { $_ -ne $script:Impl })
    if ($pool.Count -eq 0) { $pool = $names }
    $seed = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes("$script:Impl-elect:${position}:${turn}:$($names -join ',')"))
    $idx = [Convert]::ToInt64($seed.Substring(0, 8), 16) % $pool.Count
    return @{ elect = $pool[$idx] }
}

function Invoke-Choose([byte[]]$data, [string]$position, [long]$turn) {
    $m = [Phext]::Explode($data)
    $pos = [Phext]::CoordParse($position)
    while ($m.ContainsKey([Phext]::CoordString($pos))) { $pos[8] += 1 }
    return @{ op = 'insert'; coordinate = [Phext]::CoordString($pos);
              text = "$script:Impl was here, turn $turn" }
}

function Invoke-Apply([byte[]]$data, $step) {
    $coord = [Phext]::CoordParse($step['coordinate'])
    $m = [Phext]::Explode($data)
    $cs = [Phext]::CoordString($coord)
    if ($m.ContainsKey($cs)) { throw 'coordinate already occupied' }
    $m[$cs] = [PositionedScroll]::new($coord, (ConvertTo-Latin1Bytes $step['text']))
    $out = [Phext]::Implode($m)
    return @{ state_b64 = (ConvertTo-B64 $out); state_sha256 = (Get-Sha256Hex $out) }
}

function Invoke-Init([byte[]]$data) {
    $script:CacheMap = [Phext]::Explode($data)
    $script:CacheHash = Get-Sha256Hex $data
    return @{ impl = $script:Impl; verdict = 'pass' }
}

function New-VFail([string]$detail) { return @{ impl = $script:Impl; verdict = 'fail'; detail = $detail } }

function Invoke-Validate([byte[]]$data, $step, [string]$eventCoordS, [string]$indexLine) {
    $new = [Phext]::Explode($data)
    $coordS = [Phext]::CoordString([Phext]::CoordParse($step['coordinate']))
    $old = $script:CacheMap
    $placed = $new[$coordS]
    if ($null -eq $placed -or (ConvertFrom-Latin1Bytes $placed.Text) -ne $step['text']) {
        return New-VFail 'placed scroll missing or altered'
    }
    foreach ($k in $old.Keys) {
        if ($k -eq $script:IndexCoord) { continue }
        $nv = $new[$k]
        if ($null -eq $nv -or -not (Test-BytesEqual $nv.Text $old[$k].Text)) {
            return New-VFail "prior scroll overwritten at $k"
        }
    }
    foreach ($k in $new.Keys) {
        if (-not $old.ContainsKey($k) -and $k -ne $coordS -and $k -ne $eventCoordS) {
            return New-VFail "unexpected new scroll at $k"
        }
    }
    $idx = ''
    if ($new.ContainsKey($script:IndexCoord)) { $idx = ConvertFrom-Latin1Bytes $new[$script:IndexCoord].Text }
    if (-not $idx.TrimEnd("`n").EndsWith($indexLine.TrimEnd("`n"))) {
        return New-VFail 'index does not record the placement'
    }
    $script:CacheMap = $new
    $script:CacheHash = Get-Sha256Hex $data
    return @{ impl = $script:Impl; verdict = 'pass' }
}

function New-VFailN([int]$n, [string]$msg) {
    return @{ impl = $script:Impl; verdict = 'fail'; placements_checked = $n;
              first_failure = @{ detail = $msg } }
}

function Invoke-Verify([byte[]]$data) {
    $m = [Phext]::Explode($data)
    $keysText = ''
    if ($m.ContainsKey($script:KeysCoord)) { $keysText = ConvertFrom-Utf8Bytes $m[$script:KeysCoord].Text }
    $kh = ''
    if ($m.ContainsKey($script:KhCoord)) { $kh = (ConvertFrom-Latin1Bytes $m[$script:KhCoord].Text).Trim() }
    if ((Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($keysText))) -ne $kh) {
        return New-VFailN 0 'keys-hash scroll does not match keys'
    }
    $events = @{}
    foreach ($k in $m.Keys) {
        $c = [Phext]::CoordParse($k)
        if ($c[0] -eq 1 -and $c[1] -eq 1 -and $c[2] -eq 1 -and $c[3] -eq 1 -and
            $c[4] -eq 1 -and $c[5] -eq 1 -and $c[6] -eq 2 -and $c[7] -eq 1) {
            $events[$c[8]] = [JsonParser]::new((ConvertFrom-Utf8Bytes $m[$k].Text)).ParseValue()
        }
    }
    $prevHash = $null
    $placements = @{}
    $seqs = @($events.Keys | Sort-Object)
    for ($i = 0; $i -lt $seqs.Count; $i++) {
        $s = $seqs[$i]
        if ($s -ne $i + 1) { return New-VFailN $placements.Count "event seq gap at $s" }
        $ev = $events[$s]
        if ($ev['prev'] -ne $prevHash) { return New-VFailN $placements.Count "event chain broken at seq $s" }
        $body = $ev['body']
        $prevHash = Get-Sha256Hex (Get-CanonBytes $body)
        if ($body['type'] -eq 'placement') {
            $coordS = $body['coord']
            if ($placements.ContainsKey($coordS)) { return New-VFailN $placements.Count "coordinate reused at seq $s" }
            $entry = $m[$coordS]
            if ($null -eq $entry -or (Get-Sha256Hex $entry.Text) -ne $body['text_sha256']) {
                return New-VFailN $placements.Count "placement scroll hash mismatch seq $s"
            }
            $desc = @{ turn = $body['turn']; coordinate = $body['coord'];
                       scroll_sha256 = $body['text_sha256']; file_sha256 = $body['file_sha256'] }
            if (-not (Test-Signature $keysText (Get-CanonBytes $desc) $body['att'])) {
                return New-VFailN $placements.Count "attestation fails at seq $s"
            }
            $placements[$coordS] = $body
        }
    }
    $idxText = ''
    if ($m.ContainsKey($script:IndexCoord)) { $idxText = ConvertFrom-Latin1Bytes $m[$script:IndexCoord].Text }
    $idxLines = @($idxText -split "`n" | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    if ($idxLines.Count -ne $placements.Count) { return New-VFailN $placements.Count 'index lines != placements' }
    foreach ($ln in $idxLines) {
        $parts = $ln -split ' ', 4
        $body = $placements[$parts[1]]
        if ($null -eq $body -or $body['text_sha256'] -ne $parts[2]) {
            return New-VFailN $placements.Count "index hash mismatch: $($ln.Substring(0, [Math]::Min(40, $ln.Length)))"
        }
    }
    return @{ impl = $script:Impl; verdict = 'pass'; placements_checked = $placements.Count; first_failure = $null }
}

# ---------------------------------------------------------------- dispatch
function Invoke-Dispatch($req) {
    switch ($req['cmd']) {
        'id' { return @{ impl = $script:Impl } }
        'keygen' { return Invoke-Keygen }
        'echo' { return Invoke-Echo $req['ping'] }
        'elect' { return Invoke-Elect $req['position'] $req['candidates'] ([long]$req['turn']) }
        'choose' { return Invoke-Choose (Get-StateBytes $req) $req['position'] ([long]$req['turn']) }
        'apply' { return Invoke-Apply (Get-StateBytes $req) $req['step'] }
        'attest' { return Invoke-Attest $req['descriptor'] }
        'init' { return Invoke-Init (Get-StateBytes $req) }
        'validate' { return Invoke-Validate (Get-StateBytes $req) $req['step'] $req['event_coord'] $req['index_line'] }
        'verify' { return Invoke-Verify (Get-StateBytes $req) }
        default { throw "unknown cmd $($req['cmd'])" }
    }
}

function Invoke-HandleLine([string]$line) {
    try {
        $req = [JsonParser]::new($line).ParseValue()
        $resp = ConvertTo-CanonJson (Invoke-Dispatch $req)
        if ($resp.Length -gt 8192) {
            return 'GZ1:' + [Convert]::ToBase64String((Compress-Gzip ([System.Text.Encoding]::UTF8.GetBytes($resp))))
        }
        return $resp
    } catch {
        return ConvertTo-CanonJson @{ error = "$($_.Exception.GetType().Name): $($_.Exception.Message)" }
    }
}

function Expand-Frame([string]$line) {
    if ($line.StartsWith('GZ1:')) {
        return [System.Text.Encoding]::UTF8.GetString((Expand-Gzip ([Convert]::FromBase64String($line.Substring(4)))))
    }
    return $line
}

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if ($ArgsRest -contains 'serve' -or $args -contains 'serve') {
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        if ($line.Trim() -eq '') { continue }
        [Console]::Out.WriteLine((Invoke-HandleLine (Expand-Frame $line.Trim())))
        [Console]::Out.Flush()
    }
} else {
    $text = [Console]::In.ReadToEnd().Trim()
    if ($text -ne '') { [Console]::Out.WriteLine((Invoke-HandleLine (Expand-Frame $text))) }
}
