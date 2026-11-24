<?php
// libphext port for PHP (0.6.1 parity semantics; normative reference:
// libphext-py). Phext is a 9-dimensional plain-text format: scrolls of
// text addressed by a coordinate, separated in the byte stream by
// dimension-break bytes.
//
// Dimension breaks (dimension index -> byte):
//   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
//   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
//   8 scroll 0x17.
// A break at dimension d increments component d and resets all lower
// components to 1. Scroll text is a maximal run of non-break bytes; the
// newline byte 0x0A is ordinary text, NOT a break. PHP strings are byte
// strings, and every operation here is byte-level.

declare(strict_types=1);

final class Phext
{
    /** Dimension index (0=library .. 8=scroll) -> break byte. */
    public const DIMENSION_BREAKS = "\x01\x1F\x1E\x1D\x1C\x1A\x19\x18\x17";

    /** @return array<int,int>|null coordinate parts, or null when invalid */
    public static function parseCoordinate(string $s): ?array
    {
        $groups = explode('/', trim($s));
        if (count($groups) !== 3) {
            return null;
        }
        $parts = [];
        foreach ($groups as $g) {
            foreach (explode('.', $g) as $p) {
                if (!preg_match('/^\d+$/', $p)) {
                    return null;
                }
                $n = (int)$p;
                if ($n < 1) {
                    return null;
                }
                $parts[] = $n;
            }
        }
        return count($parts) === 9 ? $parts : null;
    }

    /** @param array<int,int> $c */
    public static function formatCoordinate(array $c): string
    {
        return "{$c[0]}.{$c[1]}.{$c[2]}/{$c[3]}.{$c[4]}.{$c[5]}/{$c[6]}.{$c[7]}.{$c[8]}";
    }

    /** Lexicographic comparison of two coordinate part arrays. */
    public static function compare(array $a, array $b): int
    {
        for ($i = 0; $i < 9; $i++) {
            if ($a[$i] !== $b[$i]) {
                return $a[$i] < $b[$i] ? -1 : 1;
            }
        }
        return 0;
    }

    /** @return array<int,int> dimension index for a break byte, or -1 */
    private static function breakDimension(string $byte): int
    {
        $d = strpos(self::DIMENSION_BREAKS, $byte);
        return $d === false ? -1 : $d;
    }

    /** Advance $coord at dimension $d: increment d, reset lower to 1. */
    private static function applyBreak(array &$coord, int $d): void
    {
        $coord[$d]++;
        for ($j = $d + 1; $j < 9; $j++) {
            $coord[$j] = 1;
        }
    }

    /**
     * Split a buffer into its ordered scrolls.
     * @return array<int, array{coord: array<int,int>, text: string}>
     */
    public static function phokenize(string $buffer): array
    {
        $out = [];
        $walker = [1, 1, 1, 1, 1, 1, 1, 1, 1];
        $len = strlen($buffer);
        $i = 0;
        while ($i < $len) {
            $d = self::breakDimension($buffer[$i]);
            if ($d >= 0) {
                self::applyBreak($walker, $d);
                $i++;
                continue;
            }
            $start = $i;
            while ($i < $len && self::breakDimension($buffer[$i]) < 0) {
                $i++;
            }
            $out[] = ['coord' => $walker, 'text' => substr($buffer, $start, $i - $start)];
        }
        return $out;
    }

    /** Break bytes that move $loc up to $target; updates $loc in place. */
    private static function advance(array &$loc, array $target): string
    {
        if (self::compare($loc, $target) >= 0) {
            return '';
        }
        $d = 0;
        while ($loc[$d] === $target[$d]) {
            $d++;
        }
        $out = str_repeat(self::DIMENSION_BREAKS[$d], $target[$d] - $loc[$d]);
        $reached = $loc;
        $reached[$d] = $target[$d];
        for ($j = $d + 1; $j < 9; $j++) {
            $reached[$j] = 1;
        }
        for ($lower = $d + 1; $lower < 9; $lower++) {
            $out .= str_repeat(self::DIMENSION_BREAKS[$lower], $target[$lower] - 1);
            $reached[$lower] = $target[$lower];
        }
        $loc = $reached;
        return $out;
    }

    /**
     * Serialize scrolls (ascending coordinate order, as Phokenize yields)
     * into canonical phext bytes, advancing from 1.1.1/1.1.1/1.1.1.
     * @param array<int, array{coord: array<int,int>, text: string}> $scrolls
     */
    public static function dephokenize(array $scrolls): string
    {
        $out = '';
        $loc = [1, 1, 1, 1, 1, 1, 1, 1, 1];
        foreach ($scrolls as $ps) {
            $out .= self::advance($loc, $ps['coord']);
            $out .= $ps['text'];
        }
        return $out;
    }

    /** Normalize = phokenize then dephokenize (drops empties, canonical). */
    public static function normalize(string $buffer): string
    {
        return self::dephokenize(self::phokenize($buffer));
    }

    /** Text at $coord, or "" for a gap coordinate (never a control byte). */
    public static function fetch(string $buffer, array $coord): string
    {
        foreach (self::phokenize($buffer) as $ps) {
            if ($ps['coord'] === $coord) {
                return $ps['text'];
            }
        }
        return '';
    }

    private static function update(string $buffer, array $coord, string $text, bool $overwrite): string
    {
        $items = self::phokenize($buffer);
        $next = ['coord' => $coord, 'text' => $text];
        $result = [];
        $appended = false;
        foreach ($items as $ps) {
            if (!$appended && self::compare($ps['coord'], $coord) > 0) {
                $result[] = $next;
                $appended = true;
            }
            if (!$appended && $ps['coord'] === $coord) {
                if (!$overwrite) {
                    $next['text'] = $ps['text'] . $next['text'];
                }
                $result[] = $next;
                $appended = true;
                continue;
            }
            $result[] = $ps;
        }
        if (!$appended) {
            $result[] = $next;
        }
        return self::dephokenize($result);
    }

    /** Insert: existing scroll at $coord becomes existing + inserted. */
    public static function insert(string $buffer, array $coord, string $text): string
    {
        return self::update($buffer, $coord, $text, false);
    }

    /** Replace: overwrite the scroll at $coord (creating it if absent). */
    public static function replace(string $buffer, array $coord, string $text): string
    {
        return self::update($buffer, $coord, $text, true);
    }

    /** Remove: replace with "" then normalize. */
    public static function remove(string $buffer, array $coord): string
    {
        return self::normalize(self::update($buffer, $coord, '', true));
    }

    /**
     * Map form of phokenize: coordinate string -> text.
     * @return array<string,string>
     */
    public static function explode(string $buffer): array
    {
        $map = [];
        foreach (self::phokenize($buffer) as $ps) {
            $map[self::formatCoordinate($ps['coord'])] = $ps['text'];
        }
        return $map;
    }

    /**
     * Map form of dephokenize: keys emitted in ascending coordinate order.
     * @param array<string,string> $map
     */
    public static function implode(array $map): string
    {
        $scrolls = [];
        foreach ($map as $coordStr => $text) {
            $scrolls[] = ['coord' => self::parseCoordinate($coordStr), 'text' => $text];
        }
        usort($scrolls, fn($a, $b) => self::compare($a['coord'], $b['coord']));
        return self::dephokenize($scrolls);
    }
}
