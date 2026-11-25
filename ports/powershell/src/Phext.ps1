# libphext-powershell — a PowerShell port of libphext (0.6.1 parity).
#
# Semantics are normative from libphext-py: a phext is a byte buffer;
# nine dimension-break bytes walk a 9-component coordinate; scroll text
# is a maximal run of non-break bytes (newline 0x0A is ordinary text).
# Buffers cross the API as [byte[]]; internally the walk runs over a
# Latin1 string (System.Text.Encoding.Latin1 is a bijection between
# bytes and chars 0-255), which keeps the break search on native .NET
# string primitives. Coordinates are [long[]] of length 9, ordered
# lexicographically; string form a.b.c/d.e.f/g.h.i.

class PositionedScroll {
    [long[]]$Coord
    [byte[]]$Text
    PositionedScroll([long[]]$c, [byte[]]$t) { $this.Coord = $c; $this.Text = $t }
}

class Phext {
    static [System.Text.Encoding]$Enc = [System.Text.Encoding]::Latin1
    static [byte[]]$DimensionBreaks = [byte[]]@(0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17)
    static [char[]]$BreakChars = [char[]]@(0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17)

    static [int] BreakDim([byte]$b) {
        switch ($b) {
            0x01 { return 0 } 0x1F { return 1 } 0x1E { return 2 } 0x1D { return 3 }
            0x1C { return 4 } 0x1A { return 5 } 0x19 { return 6 } 0x18 { return 7 }
            0x17 { return 8 }
        }
        return -1
    }

    static [long[]] CoordRoot() { return [long[]]@(1, 1, 1, 1, 1, 1, 1, 1, 1) }

    static [long[]] CoordParse([string]$s) {
        $groups = $s.Trim().Split('/')
        if ($groups.Count -ne 3) { throw "coordinate must be a.b.c/d.e.f/g.h.i: $s" }
        $nums = [System.Collections.Generic.List[long]]::new()
        foreach ($g in $groups) {
            foreach ($p in $g.Split('.')) { $nums.Add([long]::Parse($p)) }
        }
        if ($nums.Count -ne 9) { throw "coordinate needs 9 parts: $s" }
        foreach ($n in $nums) { if ($n -lt 1) { throw "components must be >= 1: $s" } }
        return $nums.ToArray()
    }

    static [string] CoordString([long[]]$c) {
        return ('{0}.{1}.{2}/{3}.{4}.{5}/{6}.{7}.{8}' -f $c[0], $c[1], $c[2], $c[3], $c[4], $c[5], $c[6], $c[7], $c[8])
    }

    static [int] CoordCompare([long[]]$a, [long[]]$b) {
        for ($i = 0; $i -lt 9; $i++) {
            if ($a[$i] -ne $b[$i]) { return $a[$i].CompareTo($b[$i]) }
        }
        return 0
    }

    static [long[]] CoordApplyBreak([long[]]$c, [int]$d) {
        $out = [long[]]$c.Clone()
        $out[$d] += 1
        for ($lower = $d + 1; $lower -lt 9; $lower++) { $out[$lower] = 1 }
        return $out
    }

    static [System.Collections.Generic.List[PositionedScroll]] Phokenize([byte[]]$buffer) {
        $out = [System.Collections.Generic.List[PositionedScroll]]::new()
        $s = [Phext]::Enc.GetString($buffer)
        $coord = [Phext]::CoordRoot()
        $runStart = 0
        $pos = 0
        while ($true) {
            $idx = $s.IndexOfAny([Phext]::BreakChars, $pos)
            if ($idx -lt 0) { break }
            if ($idx -gt $runStart) {
                $out.Add([PositionedScroll]::new($coord, [Phext]::Enc.GetBytes($s.Substring($runStart, $idx - $runStart))))
            }
            $d = [Phext]::BreakDim([byte][char]$s[$idx])
            $coord = [Phext]::CoordApplyBreak($coord, $d)
            $runStart = $idx + 1
            $pos = $idx + 1
        }
        if ($s.Length -gt $runStart) {
            $out.Add([PositionedScroll]::new($coord, [Phext]::Enc.GetBytes($s.Substring($runStart))))
        }
        return $out
    }

    static [long[]] EmitAdvance([System.Text.StringBuilder]$sb, [long[]]$loc, [long[]]$target) {
        if ([Phext]::CoordCompare($loc, $target) -lt 0) {
            $dim = 0
            while ($loc[$dim] -eq $target[$dim]) { $dim++ }
            for ($k = 0; $k -lt ($target[$dim] - $loc[$dim]); $k++) { [void]$sb.Append([Phext]::BreakChars[$dim]) }
            for ($lower = $dim + 1; $lower -lt 9; $lower++) {
                for ($k = 0; $k -lt ($target[$lower] - 1); $k++) { [void]$sb.Append([Phext]::BreakChars[$lower]) }
            }
        }
        return $target
    }

    static [byte[]] Dephokenize([System.Collections.Generic.List[PositionedScroll]]$stack) {
        $sorted = [System.Collections.Generic.List[PositionedScroll]]::new($stack)
        $sorted.Sort([System.Comparison[PositionedScroll]]{ param($a, $b) [Phext]::CoordCompare($a.Coord, $b.Coord) })
        $sb = [System.Text.StringBuilder]::new()
        $loc = [Phext]::CoordRoot()
        foreach ($ps in $sorted) {
            if ($ps.Text.Length -eq 0) { continue }
            $loc = [Phext]::EmitAdvance($sb, $loc, $ps.Coord)
            [void]$sb.Append([Phext]::Enc.GetString($ps.Text))
        }
        return [Phext]::Enc.GetBytes($sb.ToString())
    }

    static [byte[]] DephokenizeInOrder([System.Collections.Generic.List[PositionedScroll]]$stack) {
        $sb = [System.Text.StringBuilder]::new()
        $loc = [Phext]::CoordRoot()
        foreach ($ps in $stack) {
            $loc = [Phext]::EmitAdvance($sb, $loc, $ps.Coord)
            [void]$sb.Append([Phext]::Enc.GetString($ps.Text))
        }
        return [Phext]::Enc.GetBytes($sb.ToString())
    }

    static [byte[]] Normalize([byte[]]$buffer) { return [Phext]::Dephokenize([Phext]::Phokenize($buffer)) }

    static [byte[]] Fetch([byte[]]$buffer, [long[]]$coord) {
        foreach ($ps in [Phext]::Phokenize($buffer)) {
            if ([Phext]::CoordCompare($ps.Coord, $coord) -eq 0) { return $ps.Text }
        }
        return [byte[]]@()
    }

    static [byte[]] UpdateBuffer([byte[]]$buffer, [long[]]$coord, [byte[]]$scroll, [bool]$overwrite) {
        $items = [Phext]::Phokenize($buffer)
        $result = [System.Collections.Generic.List[PositionedScroll]]::new()
        $next = [PositionedScroll]::new($coord, $scroll)
        $appended = $false
        foreach ($ps in $items) {
            $cmp = [Phext]::CoordCompare($ps.Coord, $coord)
            if ($cmp -gt 0 -and -not $appended) {
                $result.Add($next); $appended = $true; $result.Add($ps)
            } elseif ($cmp -eq 0 -and -not $appended) {
                if ($overwrite) {
                    $result.Add($next)
                } else {
                    $merged = [byte[]]::new($ps.Text.Length + $next.Text.Length)
                    [Array]::Copy($ps.Text, 0, $merged, 0, $ps.Text.Length)
                    [Array]::Copy($next.Text, 0, $merged, $ps.Text.Length, $next.Text.Length)
                    $result.Add([PositionedScroll]::new($coord, $merged))
                }
                $appended = $true
            } else {
                $result.Add($ps)
            }
        }
        if (-not $appended) { $result.Add($next) }
        return [Phext]::DephokenizeInOrder($result)
    }

    # insert: existing text is prepended to the inserted text.
    static [byte[]] Insert([byte[]]$buffer, [long[]]$coord, [byte[]]$scroll) {
        return [Phext]::UpdateBuffer($buffer, $coord, $scroll, $false)
    }

    static [byte[]] Replace([byte[]]$buffer, [long[]]$coord, [byte[]]$scroll) {
        return [Phext]::UpdateBuffer($buffer, $coord, $scroll, $true)
    }

    # remove: replace with "" then normalize — coordinate-preserving:
    # the removed coordinate reads "" and neighbours do not shift.
    static [byte[]] Remove([byte[]]$buffer, [long[]]$coord) {
        return [Phext]::Normalize([Phext]::UpdateBuffer($buffer, $coord, [byte[]]@(), $true))
    }

    static [hashtable] Explode([byte[]]$buffer) {
        $out = @{}
        foreach ($ps in [Phext]::Phokenize($buffer)) {
            $out[[Phext]::CoordString($ps.Coord)] = $ps
        }
        return $out
    }

    static [byte[]] Implode([hashtable]$map) {
        $stack = [System.Collections.Generic.List[PositionedScroll]]::new()
        foreach ($k in $map.Keys) { $stack.Add($map[$k]) }
        return [Phext]::Dephokenize($stack)
    }
}

# ------------------------------------------------------------------
# DynamicPhext: capacity-managed dynamic array scroll store.
# Start at capacity 1, double when full on append, shrink only at
# quarter load (never half — that thrashes).
class DynamicPhext {
    [object[]]$Data
    [int]$Capacity
    [int]$N
    [int]$ResizeCount
    [long]$ElementsCopied
    [int]$ShrinkDivisor

    DynamicPhext() { $this.Init([byte[]]@(), 4) }
    DynamicPhext([byte[]]$buffer) { $this.Init($buffer, 4) }
    DynamicPhext([byte[]]$buffer, [int]$shrinkDivisor) { $this.Init($buffer, $shrinkDivisor) }

    hidden [void] Init([byte[]]$buffer, [int]$sd) {
        if ($sd -lt 2) { throw "shrink_divisor must be >= 2" }
        $this.ShrinkDivisor = $sd
        $this.Data = [object[]]::new(1)
        $this.Capacity = 1
        $this.N = 0
        $this.ResizeCount = 0
        $this.ElementsCopied = 0
        if ($buffer.Length -gt 0) { $this.Load($buffer) }
    }

    [int] Length() { return $this.N }

    hidden [void] Resize([int]$newCapacity) {
        $nd = [object[]]::new($newCapacity)
        [Array]::Copy($this.Data, 0, $nd, 0, $this.N)
        $this.Data = $nd
        $this.Capacity = $newCapacity
        $this.ResizeCount += 1
        $this.ElementsCopied += $this.N
    }

    hidden [void] GrowIfFull() { if ($this.N -eq $this.Capacity) { $this.Resize(2 * $this.Capacity) } }

    hidden [void] ShrinkIfSparse() {
        if ($this.Capacity -gt 1 -and $this.N -le [Math]::Floor($this.Capacity / $this.ShrinkDivisor)) {
            $this.Resize([Math]::Max(1, [Math]::Floor($this.Capacity / 2)))
        }
    }

    hidden [void] Push([PositionedScroll]$ps) {
        $this.GrowIfFull()
        $this.Data[$this.N] = $ps
        $this.N += 1
    }

    [void] Load([byte[]]$buffer) {
        $this.Capacity = 1
        $this.Data = [object[]]::new(1)
        $this.N = 0
        $this.ResizeCount = 0
        $this.ElementsCopied = 0
        foreach ($ps in [Phext]::Phokenize($buffer)) { $this.Push($ps) }
    }

    [System.Collections.Generic.List[PositionedScroll]] Scrolls() {
        $out = [System.Collections.Generic.List[PositionedScroll]]::new()
        for ($i = 0; $i -lt $this.N; $i++) { $out.Add($this.Data[$i]) }
        return $out
    }

    [byte[]] Serialize() { return [Phext]::Dephokenize($this.Scrolls()) }

    # Binary search: @(index, found); index is the insertion point.
    hidden [object[]] Find([long[]]$coord) {
        $lo = 0; $hi = $this.N
        while ($lo -lt $hi) {
            $mid = [Math]::Floor(($lo + $hi) / 2)
            $cmp = [Phext]::CoordCompare($this.Data[$mid].Coord, $coord)
            if ($cmp -lt 0) { $lo = $mid + 1 }
            elseif ($cmp -gt 0) { $hi = $mid }
            else { return @($mid, $true) }
        }
        return @($lo, $false)
    }

    [byte[]] Fetch([long[]]$coord) {
        $f = $this.Find($coord)
        if ($f[1]) { return $this.Data[$f[0]].Text }
        return [byte[]]@()
    }

    [bool] Contains([long[]]$coord) { return $this.Find($coord)[1] }

    [void] Append([long[]]$coord, [byte[]]$text) {
        if ($this.N -gt 0 -and [Phext]::CoordCompare($coord, $this.Data[$this.N - 1].Coord) -le 0) {
            throw "append requires a coordinate past the current tail"
        }
        if ($text.Length -gt 0) { $this.Push([PositionedScroll]::new($coord, $text)) }
    }

    [void] Update([long[]]$coord, [byte[]]$text, [bool]$overwrite) {
        $f = $this.Find($coord)
        $index = $f[0]
        if ($f[1]) {
            if ($text.Length -eq 0) {
                if ($overwrite) { $this.RemoveAt($index) }
            } else {
                if ($overwrite) {
                    $t = $text
                } else {
                    $existing = $this.Data[$index].Text
                    $t = [byte[]]::new($existing.Length + $text.Length)
                    [Array]::Copy($existing, 0, $t, 0, $existing.Length)
                    [Array]::Copy($text, 0, $t, $existing.Length, $text.Length)
                }
                $this.Data[$index] = [PositionedScroll]::new($coord, $t)
            }
        } elseif ($text.Length -gt 0) {
            $this.GrowIfFull()
            for ($i = $this.N; $i -gt $index; $i--) { $this.Data[$i] = $this.Data[$i - 1] }
            $this.Data[$index] = [PositionedScroll]::new($coord, $text)
            $this.N += 1
        }
    }

    [void] Insert([long[]]$coord, [byte[]]$text) { $this.Update($coord, $text, $false) }
    [void] Replace([long[]]$coord, [byte[]]$text) { $this.Update($coord, $text, $true) }

    hidden [void] RemoveAt([int]$index) {
        for ($i = $index; $i -lt $this.N - 1; $i++) { $this.Data[$i] = $this.Data[$i + 1] }
        $this.N -= 1
        $this.Data[$this.N] = $null
        $this.ShrinkIfSparse()
    }

    [void] Remove([long[]]$coord) {
        $f = $this.Find($coord)
        if ($f[1]) { $this.RemoveAt($f[0]) }
    }
}

# ------------------------------------------------------------------
# BranchingMap: a hash map of dimension `depth` branching into hash
# maps of one fewer dimension, recursively, down to leaves holding
# scroll text. One map lookup per dimension.
class BranchingNode {
    [hashtable]$Children = @{}
    [byte[]]$Leaf = $null
}

class BranchingMap {
    [int]$Depth
    [BranchingNode]$Root
    [int]$Count

    BranchingMap([int]$depth) {
        if ($depth -lt 1) { throw "depth must be >= 1" }
        $this.Depth = $depth
        $this.Root = [BranchingNode]::new()
        $this.Count = 0
    }

    [int] Length() { return $this.Count }

    [byte[]] Fetch([long[]]$key) {
        $node = $this.Root
        for ($level = 0; $level -lt $this.Depth; $level++) {
            $child = $node.Children[$key[$level]]
            if ($null -eq $child) { return $null }
            if ($level -eq $this.Depth - 1) { return $child.Leaf }
            $node = $child
        }
        return $null
    }

    [bool] Contains([long[]]$key) { return $null -ne $this.Fetch($key) }

    # Returns true when a new leaf was created.
    [bool] Put([long[]]$key, [byte[]]$value) {
        $node = $this.Root
        for ($level = 0; $level -lt $this.Depth; $level++) {
            $comp = $key[$level]
            $child = $node.Children[$comp]
            if ($null -eq $child) {
                $child = [BranchingNode]::new()
                $node.Children[$comp] = $child
            }
            if ($level -eq $this.Depth - 1) {
                $created = $null -eq $child.Leaf
                $child.Leaf = $value
                if ($created) { $this.Count += 1 }
                return $created
            }
            $node = $child
        }
        return $false
    }

    [bool] Remove([long[]]$key) {
        $removed = $this.RemoveRec($this.Root, $key, 0)
        if ($removed) { $this.Count -= 1 }
        return $removed
    }

    hidden [bool] RemoveRec([BranchingNode]$node, [long[]]$key, [int]$level) {
        $comp = $key[$level]
        $child = $node.Children[$comp]
        if ($null -eq $child) { return $false }
        if ($level -eq $this.Depth - 1) {
            if ($null -eq $child.Leaf) { return $false }
            $node.Children.Remove($comp)
            return $true
        }
        $removed = $this.RemoveRec($child, $key, $level + 1)
        if ($removed -and $child.Children.Count -eq 0 -and $null -eq $child.Leaf) {
            $node.Children.Remove($comp)
        }
        return $removed
    }

    # Items in lexicographic (coordinate) order.
    [System.Collections.Generic.List[object]] Items() {
        $out = [System.Collections.Generic.List[object]]::new()
        $this.ItemsRec($this.Root, [long[]]@(), 0, $out)
        return $out
    }

    hidden [void] ItemsRec([BranchingNode]$node, [long[]]$prefix, [int]$level,
                           [System.Collections.Generic.List[object]]$out) {
        $keys = [long[]]@($node.Children.Keys | Sort-Object)
        foreach ($comp in $keys) {
            $child = $node.Children[$comp]
            $k = [long[]]@($prefix + $comp)
            if ($level -eq $this.Depth - 1) {
                $out.Add(@($k, $child.Leaf))
            } else {
                $this.ItemsRec($child, $k, $level + 1, $out)
            }
        }
    }
}

# ------------------------------------------------------------------
# TransitivePhext: scroll store over a BranchingMap at depth 9.
class TransitivePhext {
    [BranchingMap]$Map

    TransitivePhext() { $this.Map = [BranchingMap]::new(9) }
    TransitivePhext([byte[]]$buffer) {
        $this.Map = [BranchingMap]::new(9)
        if ($buffer.Length -gt 0) { $this.Load($buffer) }
    }

    [int] Depth() { return $this.Map.Depth }
    [int] Length() { return $this.Map.Length() }

    [void] Load([byte[]]$buffer) {
        $this.Map = [BranchingMap]::new(9)
        foreach ($ps in [Phext]::Phokenize($buffer)) { [void]$this.Map.Put($ps.Coord, $ps.Text) }
    }

    [System.Collections.Generic.List[PositionedScroll]] Scrolls() {
        $out = [System.Collections.Generic.List[PositionedScroll]]::new()
        foreach ($e in $this.Map.Items()) { $out.Add([PositionedScroll]::new($e[0], $e[1])) }
        return $out
    }

    [byte[]] Serialize() { return [Phext]::Dephokenize($this.Scrolls()) }

    [byte[]] Fetch([long[]]$coord) {
        $v = $this.Map.Fetch($coord)
        if ($null -eq $v) { return [byte[]]@() }
        return $v
    }

    [bool] Contains([long[]]$coord) { return $this.Map.Contains($coord) }

    [void] Update([long[]]$coord, [byte[]]$text, [bool]$overwrite) {
        if ($text.Length -eq 0) {
            if ($overwrite) { [void]$this.Map.Remove($coord) }
        } elseif ($overwrite) {
            [void]$this.Map.Put($coord, $text)
        } else {
            $existing = $this.Map.Fetch($coord)
            if ($null -eq $existing) {
                [void]$this.Map.Put($coord, $text)
            } else {
                $t = [byte[]]::new($existing.Length + $text.Length)
                [Array]::Copy($existing, 0, $t, 0, $existing.Length)
                [Array]::Copy($text, 0, $t, $existing.Length, $text.Length)
                [void]$this.Map.Put($coord, $t)
            }
        }
    }

    [void] Insert([long[]]$coord, [byte[]]$text) { $this.Update($coord, $text, $false) }
    [void] Replace([long[]]$coord, [byte[]]$text) { $this.Update($coord, $text, $true) }
    [void] Remove([long[]]$coord) { [void]$this.Map.Remove($coord) }
    [void] Append([long[]]$coord, [byte[]]$text) { $this.Insert($coord, $text) }
}
