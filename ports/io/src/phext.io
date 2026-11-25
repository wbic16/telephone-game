// libphext 0.6.1 parity in Io: Phext (string ops) + DynamicPhext +
// TransitivePhext. Io Sequences are byte-safe mutable byte arrays,
// so no encoding bridge is needed. Semantics mirror phext.py /
// phext.dynamic / phext.transitive.
//
// Coordinates are Lists of 9 numbers, each >= 1. Break bytes by
// dimension 0..8: [1, 31, 30, 29, 28, 26, 25, 24, 23]. Scroll text
// is a maximal run of non-break bytes (0x0A is ordinary text).

PhextLib := Object clone do(
    breakBytes := list(1, 31, 30, 29, 28, 26, 25, 24, 23)

    // byte -> dimension+1, or 0 for text bytes; built once
    breakDim := nil
    initBreakDim := method(
        breakDim = List clone
        for(i, 1, 256, breakDim append(0))
        breakBytes foreach(d, b, breakDim atPut(b, d + 1))
    )

    // a run of the same byte, assembled from cached 1 KB blocks
    // (one block per break byte, built once)
    breakBlocks := nil
    breakRun := method(byte, count,
        if(breakBlocks == nil,
            breakBlocks = List clone
            for(i, 1, 256, breakBlocks append(nil))
            breakBytes foreach(b,
                blk := Sequence clone
                for(i, 1, 1024, blk append(b))
                breakBlocks atPut(b, blk)
            )
        )
        blockSeq := breakBlocks at(byte)
        out := Sequence clone
        remaining := count
        while(remaining > 0,
            take := remaining min(1024)
            out appendSeq(blockSeq exSlice(0, take))
            remaining = remaining - take
        )
        out
    )

    coordKey := method(c,
        c map(v, v asString alignRight(12, "0")) join
    )

    coordString := method(c,
        list(
            c at(0) asString .. "." .. c at(1) asString .. "." .. c at(2) asString,
            c at(3) asString .. "." .. c at(4) asString .. "." .. c at(5) asString,
            c at(6) asString .. "." .. c at(7) asString .. "." .. c at(8) asString
        ) join("/")
    )

    parseCoord := method(s,
        parts := s split(".", "/") map(v, v asNumber)
        if(parts size != 9, Exception raise("coordinate must have exactly 9 components: " .. s))
        parts foreach(v, if(v < 1, Exception raise("coordinate components must be >= 1: " .. s)))
        parts
    )

    // numeric -1/0/1 compare of two coordinates
    coordCmp := method(a, b,
        for(d, 0, 8,
            if(a at(d) < b at(d), return -1)
            if(a at(d) > b at(d), return 1)
        )
        0
    )

    coordValid := method(c,
        c size == 9 and c detect(v, v < 1) == nil
    )

    // bottom-up merge sort of a decorated list ([key, entry]
    // pairs) by key. Io's built-in sortBy degrades to O(n^2) on
    // already-sorted input (naive pivot), which is the common
    // case here, so the sort is done explicitly.
    sortDecorated := method(decorated,
        n := decorated size
        if(n < 2, return decorated)
        src := decorated
        width := 1
        while(width < n,
            dst := List clone
            lo := 0
            while(lo < n,
                mid := (lo + width) min(n)
                hi := (lo + 2 * width) min(n)
                a := lo; b := mid
                while(a < mid and b < hi,
                    if(src at(b) at(0) < src at(a) at(0),
                        dst append(src at(b)); b = b + 1,
                        dst append(src at(a)); a = a + 1
                    )
                )
                while(a < mid, dst append(src at(a)); a = a + 1)
                while(b < hi, dst append(src at(b)); b = b + 1)
                lo = lo + 2 * width
            )
            src = dst
            width = width * 2
        )
        src
    )

    // phokenize: buf -> list of [coord, text] in coordinate order
    phokenize := method(buf,
        if(breakDim == nil, initBreakDim)
        out := List clone
        coord := list(1, 1, 1, 1, 1, 1, 1, 1, 1)
        runstart := 0
        n := buf size
        for(i, 0, n - 1,
            dim := breakDim at(buf at(i))
            if(dim > 0,
                if(i > runstart,
                    out append(list(coord clone, buf exSlice(runstart, i)))
                )
                coord atPut(dim - 1, coord at(dim - 1) + 1)
                for(j, dim, 8, coord atPut(j, 1))
                runstart = i + 1
            )
        )
        if(runstart < n,
            out append(list(coord clone, buf exSlice(runstart, n)))
        )
        out
    )

    // dephokenize: list of [coord, text] -> phext string; entries
    // with empty text are skipped; input need not be sorted
    dephokenize := method(entries,
        // decorate with precomputed keys; Io sortBy takes a
        // boolean less-than predicate
        decorated := entries map(e, list(coordKey(e at(0)), e))
        sorted := sortDecorated(decorated) map(e, e at(1))
        out := Sequence clone
        loc := list(1, 1, 1, 1, 1, 1, 1, 1, 1)
        sorted foreach(e,
            text := e at(1)
            if(text size > 0,
                tgt := e at(0)
                if(coordCmp(loc, tgt) < 0,
                    dim := 0
                    while(loc at(dim) == tgt at(dim), dim = dim + 1)
                    out appendSeq(breakRun(breakBytes at(dim), tgt at(dim) - loc at(dim)))
                    loc atPut(dim, tgt at(dim))
                    for(j, dim + 1, 8,
                        if(tgt at(j) > 1,
                            out appendSeq(breakRun(breakBytes at(j), tgt at(j) - 1))
                        )
                        loc atPut(j, tgt at(j))
                    )
                )
                out appendSeq(text)
            )
        )
        out
    )

    normalize := method(buf, dephokenize(phokenize(buf)))

    fetch := method(buf, coord,
        key := coordKey(coord)
        phokenize(buf) foreach(e,
            if(coordKey(e at(0)) == key, return e at(1))
        )
        ""
    )

    // update: the single write path. insert prepends existing text;
    // replace overwrites. Returns the new buffer string.
    update := method(buf, coord, scroll, overwrite,
        entries := phokenize(buf)
        out := List clone
        appended := false
        key := coordKey(coord)
        entries foreach(e,
            if(coordKey(e at(0)) == key,
                appended = true
                if(overwrite,
                    out append(list(coord, scroll)),
                    out append(list(coord, e at(1) .. scroll))
                ),
                out append(e)
            )
        )
        if(appended not, out append(list(coord, scroll)))
        dephokenize(out)
    )

    insert := method(buf, coord, scroll, update(buf, coord, scroll, false))
    replace := method(buf, coord, scroll, update(buf, coord, scroll, true))

    // remove: replace with "" then normalize -- coordinate-
    // preserving: the removed coordinate reads "" and neighbours
    // do not shift.
    remove := method(buf, coord, normalize(replace(buf, coord, "")))

    explode := method(buf, phokenize(buf) map(e, e at(1)))
    implode := method(texts,
        out := Sequence clone
        texts foreach(t, out appendSeq(t); out append(1))
        out
    )
)

// DynamicPhext: capacity-managed dynamic array scroll store.
// Start at capacity 1, double when full on append, shrink only at
// quarter load (never half -- that thrashes). Mirrors
// phext.dynamic exactly.
DynamicPhext := Object clone do(
    coords := nil
    texts := nil
    cap := 1
    resizeCount := 0
    elementsCopied := 0
    shrinkDivisor := 4

    initWith := method(buf, divisor,
        self coords = List clone
        self texts = List clone
        self cap = 1
        self resizeCount = 0
        self elementsCopied = 0
        self shrinkDivisor = if(divisor == nil, 4, divisor)
        if(buf != nil and buf size > 0,
            PhextLib phokenize(buf) foreach(e, appendRaw(e at(0), e at(1)))
        )
        self
    )

    len := method(coords size)
    capacity := method(cap)

    resize := method(newcap,
        resizeCount = resizeCount + 1
        elementsCopied = elementsCopied + coords size
        cap = newcap
    )
    growIfFull := method(
        if(coords size == cap, resize(cap * 2))
    )
    shrinkIfSparse := method(
        if(cap > 1 and coords size <= (cap / shrinkDivisor) floor,
            resize(((cap / 2) floor) max(1))
        )
    )

    // binary search: index of coord, or -(insertion point)-1
    findIndex := method(coord,
        key := PhextLib coordKey(coord)
        lo := 0; hi := coords size - 1
        while(lo <= hi,
            mid := ((lo + hi) / 2) floor
            mk := PhextLib coordKey(coords at(mid))
            if(mk == key, return mid)
            if(mk < key, lo = mid + 1, hi = mid - 1)
        )
        -(lo) - 1
    )

    fetch := method(coord,
        i := findIndex(coord)
        if(i >= 0, texts at(i), "")
    )

    appendRaw := method(coord, text,
        if(text size == 0, return self)
        growIfFull
        coords append(coord)
        texts append(text)
        self
    )

    update := method(coord, text, overwrite,
        i := findIndex(coord)
        if(i >= 0,
            if(text size == 0,
                if(overwrite, removeAt(i)),
                if(overwrite,
                    texts atPut(i, text),
                    texts atPut(i, texts at(i) .. text)
                )
            ),
            if(text size > 0,
                growIfFull
                coords insertAt(coord, -i - 1)
                texts insertAt(text, -i - 1)
            )
        )
        self
    )

    insert := method(coord, text, update(coord, text, false))
    replace := method(coord, text, update(coord, text, true))

    removeAt := method(i,
        coords removeAt(i)
        texts removeAt(i)
        shrinkIfSparse
        self
    )

    remove := method(coord,
        i := findIndex(coord)
        if(i >= 0, removeAt(i))
        self
    )

    append := method(coord, text,
        if(coords size > 0 and PhextLib coordKey(coord) <= PhextLib coordKey(coords last),
            Exception raise("append coordinate must be after the current tail")
        )
        appendRaw(coord, text)
    )

    serialize := method(
        entries := List clone
        coords foreach(i, c, entries append(list(c, texts at(i))))
        PhextLib dephokenize(entries)
    )
)

// TransitivePhext: persistent scroll store with phext.transitive
// semantics. Io objects are mutable, so persistence is by
// copy-on-write snapshots: every update works on a cloned entry
// list, leaving previously taken snapshots untouched.
TransitivePhext := Object clone do(
    entries := nil    // list of [coord, text], coordinate order

    initWith := method(buf,
        self entries = List clone
        if(buf != nil and buf size > 0,
            self entries = PhextLib phokenize(buf)
        )
        self
    )

    len := method(entries size)

    fetch := method(coord,
        key := PhextLib coordKey(coord)
        entries foreach(e, if(PhextLib coordKey(e at(0)) == key, return e at(1)))
        ""
    )

    snapshot := method(
        t := TransitivePhext clone
        t entries = entries map(e, list(e at(0) clone, e at(1)))
        t
    )

    update := method(coord, text, overwrite,
        out := List clone
        appended := false
        key := PhextLib coordKey(coord)
        entries foreach(e,
            if(PhextLib coordKey(e at(0)) == key,
                appended = true
                if(text size > 0,
                    if(overwrite,
                        out append(list(coord, text)),
                        out append(list(coord, e at(1) .. text))
                    )
                ),
                out append(e)
            )
        )
        if(appended not and text size > 0, out append(list(coord, text)))
        decorated := out map(e, list(PhextLib coordKey(e at(0)), e))
        self entries = PhextLib sortDecorated(decorated) map(e, e at(1))
        self
    )

    insert := method(coord, text, update(coord, text, false))
    replace := method(coord, text, update(coord, text, true))

    remove := method(coord,
        key := PhextLib coordKey(coord)
        self entries = entries select(e, PhextLib coordKey(e at(0)) != key)
        self
    )

    append := method(coord, text,
        if(entries size > 0 and PhextLib coordKey(coord) <= PhextLib coordKey(entries last at(0)),
            Exception raise("append coordinate must be after the current tail")
        )
        if(text size > 0, entries append(list(coord, text)))
        self
    )

    serialize := method(PhextLib dephokenize(entries))
)
