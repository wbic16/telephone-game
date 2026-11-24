package phext

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

func mustCoord(t *testing.T, s string) Coordinate {
	t.Helper()
	c, err := ParseCoordinate(s)
	if err != nil {
		t.Fatalf("ParseCoordinate(%q): %v", s, err)
	}
	return c
}

func TestCoordinateParseAndString(t *testing.T) {
	c := mustCoord(t, "1.2.3/4.5.6/7.8.9")
	if c.String() != "1.2.3/4.5.6/7.8.9" {
		t.Fatalf("round trip: got %s", c.String())
	}
	for _, bad := range []string{"", "1.1.1/1.1.1", "0.1.1/1.1.1/1.1.1", "a.b.c/d.e.f/g.h.i", "1.1.1/1.1.1/1.1"} {
		if _, err := ParseCoordinate(bad); err == nil {
			t.Fatalf("ParseCoordinate(%q) should fail", bad)
		}
	}
}

func TestCoordinateOrder(t *testing.T) {
	less := [][2]string{
		{"1.1.1/1.1.1/1.1.1", "1.1.1/1.1.1/1.1.2"},
		{"1.1.1/1.1.1/1.1.9", "1.1.1/1.1.2/1.1.1"},
		{"1.1.9/9.9.9/9.9.9", "1.2.1/1.1.1/1.1.1"},
		{"2.1.1/1.1.1/1.1.1", "10.1.1/1.1.1/1.1.1"},
	}
	for _, pair := range less {
		a, b := mustCoord(t, pair[0]), mustCoord(t, pair[1])
		if a.Compare(b) != -1 || b.Compare(a) != 1 || a.Compare(a) != 0 {
			t.Fatalf("order %s vs %s", pair[0], pair[1])
		}
	}
}

func TestBreakSemantics(t *testing.T) {
	// "a" at 1.1.1/1.1.1/1.1.1, scroll break, "b" at .../1.1.2,
	// section break resets scroll: "c" at 1.1.1/1.1.1/1.2.1,
	// library break: "d" at 2.1.1/1.1.1/1.1.1.
	buf := []byte("a\x17b\x18c\x01d")
	scrolls := Phokenize(buf)
	want := []string{"1.1.1/1.1.1/1.1.1:a", "1.1.1/1.1.1/1.1.2:b", "1.1.1/1.1.1/1.2.1:c", "2.1.1/1.1.1/1.1.1:d"}
	if len(scrolls) != len(want) {
		t.Fatalf("phokenize: got %d scrolls", len(scrolls))
	}
	for i, w := range want {
		got := scrolls[i].Coord.String() + ":" + string(scrolls[i].Text)
		if got != w {
			t.Fatalf("scroll %d: got %q want %q", i, got, w)
		}
	}
	if !bytes.Equal(Dephokenize(scrolls), buf) {
		t.Fatalf("dephokenize round trip: %q", Dephokenize(scrolls))
	}
}

func TestNewlineIsOrdinaryText(t *testing.T) {
	buf := []byte("line1\nline2")
	scrolls := Phokenize(buf)
	if len(scrolls) != 1 || string(scrolls[0].Text) != "line1\nline2" {
		t.Fatalf("newline split a scroll: %+v", scrolls)
	}
}

func TestFetchGap(t *testing.T) {
	buf := []byte("hello")
	if got := Fetch(buf, mustCoord(t, "1.1.1/1.1.1/1.1.2")); string(got) != "" {
		t.Fatalf("gap fetch: got %q", got)
	}
	if got := Fetch(buf, mustCoord(t, "9.9.9/9.9.9/9.9.9")); string(got) != "" {
		t.Fatalf("far gap fetch: got %q", got)
	}
	if got := Fetch(buf, mustCoord(t, "1.1.1/1.1.1/1.1.1")); string(got) != "hello" {
		t.Fatalf("fetch: got %q", got)
	}
}

func TestInsertPrependsExistingSemantics(t *testing.T) {
	// Reference semantics (libphext-py update, overwrite=false):
	// existing text + inserted text.
	buf := Insert([]byte("base"), mustCoord(t, "1.1.1/1.1.1/1.1.1"), []byte("+more"))
	if got := Fetch(buf, mustCoord(t, "1.1.1/1.1.1/1.1.1")); string(got) != "base+more" {
		t.Fatalf("insert merge: got %q", got)
	}
	// Insert at a new coordinate creates it, in canonical position.
	buf = Insert(buf, mustCoord(t, "1.1.1/1.1.1/1.1.3"), []byte("third"))
	if got := Fetch(buf, mustCoord(t, "1.1.1/1.1.1/1.1.3")); string(got) != "third" {
		t.Fatalf("insert create: got %q", got)
	}
	want := []byte("base+more\x17\x17third")
	if !bytes.Equal(buf, want) {
		t.Fatalf("insert bytes: got %q want %q", buf, want)
	}
}

func TestReplaceAndRemove(t *testing.T) {
	buf := []byte("a\x17b\x17c")
	buf = Replace(buf, mustCoord(t, "1.1.1/1.1.1/1.1.2"), []byte("B"))
	if !bytes.Equal(buf, []byte("a\x17B\x17c")) {
		t.Fatalf("replace: %q", buf)
	}
	buf = Remove(buf, mustCoord(t, "1.1.1/1.1.1/1.1.2"))
	// c stays at scroll 3: two scroll breaks separate it from a.
	if !bytes.Equal(buf, []byte("a\x17\x17c")) {
		t.Fatalf("remove+normalize: %q", buf)
	}
	if got := Fetch(buf, mustCoord(t, "1.1.1/1.1.1/1.1.2")); string(got) != "" {
		t.Fatalf("fetch after remove: %q", got)
	}
	// Remove a gap coordinate is a no-op after normalize.
	buf2 := Remove(buf, mustCoord(t, "5.5.5/5.5.5/5.5.5"))
	if !bytes.Equal(buf2, buf) {
		t.Fatalf("remove gap: %q vs %q", buf2, buf)
	}
}

func TestExplodeImplode(t *testing.T) {
	buf := []byte("x\x17y\x01z")
	m := Explode(buf)
	if len(m) != 3 {
		t.Fatalf("explode: %d entries", len(m))
	}
	if !bytes.Equal(Implode(m), buf) {
		t.Fatalf("implode: %q", Implode(m))
	}
	// Implode emits ascending order regardless of map iteration order.
	keys := make([]string, 0, len(m))
	for c := range m {
		keys = append(keys, c.String())
	}
	sort.Strings(keys)
	if keys[0] != "1.1.1/1.1.1/1.1.1" || keys[2] != "2.1.1/1.1.1/1.1.1" {
		t.Fatalf("explode keys: %v", keys)
	}
}

// TestFixtureRoundTrip runs the shared Step 0 conformance fixtures
// (every input.phext under $PHEXT_FIXTURES, recursively: the chains and
// ranges case sets). Standard (the one the sibling ports enforce):
// normalize must be idempotent for every fixture, and the
// phokenize/dephokenize round trip must be byte-identical for all but
// at most 2 fixtures (the known non-canonical real-corpora inputs).
func TestFixtureRoundTrip(t *testing.T) {
	dir := os.Getenv("PHEXT_FIXTURES")
	if dir == "" {
		t.Skip("PHEXT_FIXTURES not set")
	}
	count, identical := 0, 0
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || info.Name() != "input.phext" {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		count++
		if got := Dephokenize(Phokenize(data)); bytes.Equal(got, data) {
			identical++
		}
		n1 := Normalize(data)
		if !bytes.Equal(Normalize(n1), n1) {
			t.Fatalf("fixture %s: normalize not idempotent", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("no fixtures found")
	}
	if identical < count-2 {
		t.Fatalf("fixtures byte-identical round-trips: %d/%d (need >= %d)", identical, count, count-2)
	}
	t.Logf("fixtures: %d input.phext, %d byte-identical round-trips", count, identical)
}
