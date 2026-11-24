// Package phext is a Go port of libphext (0.6.1 parity semantics, normative
// reference: libphext-py). Phext is a 9-dimensional plain-text format:
// scrolls of text addressed by a Coordinate, separated in the byte stream
// by dimension-break bytes.
//
// Dimension breaks (dimension index -> byte):
//	0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
//	4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
//	8 scroll 0x17.
// A break at dimension d increments component d and resets all lower
// components to 1. Scroll text is a maximal run of non-break bytes; the
// newline byte 0x0A is ordinary text, NOT a break. All operations are on
// raw bytes ([]byte); text is never interpreted as UTF-8.
package phext

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// DimensionBreaks maps dimension index (0=library .. 8=scroll) to its byte.
var DimensionBreaks = [9]byte{0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17}

var breakDimension = func() map[byte]int {
	m := make(map[byte]int, 9)
	for d, b := range DimensionBreaks {
		m[b] = d
	}
	return m
}()

func isBreak(b byte) bool { _, ok := breakDimension[b]; return ok }

// Coordinate is a 9-component phext address, each component >= 1, ordered
// lexicographically. String form: a.b.c/d.e.f/g.h.i
type Coordinate struct {
	Parts [9]int
}

// DefaultCoordinate is 1.1.1/1.1.1/1.1.1, where every phext buffer begins.
func DefaultCoordinate() Coordinate {
	return Coordinate{Parts: [9]int{1, 1, 1, 1, 1, 1, 1, 1, 1}}
}

// ParseCoordinate parses "a.b.c/d.e.f/g.h.i"; every component must be >= 1.
func ParseCoordinate(s string) (Coordinate, error) {
	var c Coordinate
	groups := strings.Split(strings.TrimSpace(s), "/")
	if len(groups) != 3 {
		return c, fmt.Errorf("invalid coordinate %q", s)
	}
	i := 0
	for _, g := range groups {
		for _, p := range strings.Split(g, ".") {
			if i >= 9 {
				return c, fmt.Errorf("invalid coordinate %q", s)
			}
			n, err := strconv.Atoi(p)
			if err != nil || n < 1 {
				return c, fmt.Errorf("invalid coordinate %q", s)
			}
			c.Parts[i] = n
			i++
		}
	}
	if i != 9 {
		return c, fmt.Errorf("invalid coordinate %q", s)
	}
	return c, nil
}

func (c Coordinate) String() string {
	p := c.Parts
	return fmt.Sprintf("%d.%d.%d/%d.%d.%d/%d.%d.%d",
		p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
}

// Compare returns -1, 0, or 1 by lexicographic component order.
func (c Coordinate) Compare(o Coordinate) int {
	for i := 0; i < 9; i++ {
		if c.Parts[i] != o.Parts[i] {
			if c.Parts[i] < o.Parts[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

// ApplyBreak advances the coordinate at dimension d: component d
// increments, all lower components reset to 1.
func (c *Coordinate) ApplyBreak(d int) {
	c.Parts[d]++
	for j := d + 1; j < 9; j++ {
		c.Parts[j] = 1
	}
}

// PositionedScroll is one scroll: text at a coordinate.
type PositionedScroll struct {
	Coord Coordinate
	Text  []byte
}

// Phokenize splits a buffer into its ordered (coordinate, text) scrolls.
func Phokenize(buffer []byte) []PositionedScroll {
	var out []PositionedScroll
	walker := DefaultCoordinate()
	i := 0
	for i < len(buffer) {
		if isBreak(buffer[i]) {
			walker.ApplyBreak(breakDimension[buffer[i]])
			i++
			continue
		}
		start := i
		for i < len(buffer) && !isBreak(buffer[i]) {
			i++
		}
		text := make([]byte, i-start)
		copy(text, buffer[start:i])
		out = append(out, PositionedScroll{Coord: walker, Text: text})
	}
	return out
}

// advance returns the break bytes that move *loc up to target, updating loc.
func advance(loc *Coordinate, target Coordinate) []byte {
	if loc.Compare(target) >= 0 {
		return nil
	}
	d := 0
	for loc.Parts[d] == target.Parts[d] {
		d++
	}
	var out []byte
	for k := 0; k < target.Parts[d]-loc.Parts[d]; k++ {
		out = append(out, DimensionBreaks[d])
	}
	reached := loc.Parts
	reached[d] = target.Parts[d]
	for j := d + 1; j < 9; j++ {
		reached[j] = 1
	}
	for lower := d + 1; lower < 9; lower++ {
		for k := 0; k < target.Parts[lower]-1; k++ {
			out = append(out, DimensionBreaks[lower])
		}
		reached[lower] = target.Parts[lower]
	}
	loc.Parts = reached
	return out
}

// Dephokenize serializes scrolls (in ascending coordinate order, as
// produced by Phokenize) into canonical phext bytes, advancing from
// 1.1.1/1.1.1/1.1.1 and emitting dimension breaks.
func Dephokenize(scrolls []PositionedScroll) []byte {
	var out []byte
	loc := DefaultCoordinate()
	for _, ps := range scrolls {
		out = append(out, advance(&loc, ps.Coord)...)
		out = append(out, ps.Text...)
	}
	return out
}

// Normalize is Phokenize then Dephokenize: drops empty scrolls and puts
// the buffer in canonical order/form.
func Normalize(buffer []byte) []byte {
	return Dephokenize(Phokenize(buffer))
}

// Fetch returns the text at coord, or "" if no scroll exists there (a gap
// coordinate returns "", never a control byte).
func Fetch(buffer []byte, coord Coordinate) []byte {
	for _, ps := range Phokenize(buffer) {
		if ps.Coord == coord {
			return ps.Text
		}
	}
	return []byte{}
}

func update(buffer []byte, coord Coordinate, text []byte, overwrite bool) []byte {
	items := Phokenize(buffer)
	next := PositionedScroll{Coord: coord, Text: text}
	var result []PositionedScroll
	appended := false
	for _, ps := range items {
		if ps.Coord.Compare(coord) > 0 && !appended {
			result = append(result, next)
			appended = true
		}
		if ps.Coord == coord && !appended {
			if !overwrite {
				merged := make([]byte, 0, len(ps.Text)+len(text))
				merged = append(merged, ps.Text...)
				merged = append(merged, text...)
				next.Text = merged
			}
			result = append(result, next)
			appended = true
			continue
		}
		result = append(result, ps)
	}
	if !appended {
		result = append(result, next)
	}
	return Dephokenize(result)
}

// Insert adds text at coord: if a scroll already exists there, the new
// text is existing + inserted; otherwise a new scroll is created.
func Insert(buffer []byte, coord Coordinate, text []byte) []byte {
	return update(buffer, coord, text, false)
}

// Replace overwrites the scroll at coord (creating it if absent).
func Replace(buffer []byte, coord Coordinate, text []byte) []byte {
	return update(buffer, coord, text, true)
}

// Remove deletes the scroll at coord and normalizes the buffer.
func Remove(buffer []byte, coord Coordinate) []byte {
	return Normalize(update(buffer, coord, []byte{}, true))
}

// Explode is the map form of Phokenize.
func Explode(buffer []byte) map[Coordinate][]byte {
	m := make(map[Coordinate][]byte)
	for _, ps := range Phokenize(buffer) {
		m[ps.Coord] = ps.Text
	}
	return m
}

// Implode is the map form of Dephokenize: keys are emitted in ascending
// coordinate order.
func Implode(m map[Coordinate][]byte) []byte {
	coords := make([]Coordinate, 0, len(m))
	for c := range m {
		coords = append(coords, c)
	}
	sort.Slice(coords, func(i, j int) bool { return coords[i].Compare(coords[j]) < 0 })
	scrolls := make([]PositionedScroll, 0, len(m))
	for _, c := range coords {
		scrolls = append(scrolls, PositionedScroll{Coord: c, Text: m[c]})
	}
	return Dephokenize(scrolls)
}
