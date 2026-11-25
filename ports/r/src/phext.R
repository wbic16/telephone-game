# libphext-r — an R port of libphext (0.6.1 parity).
#
# Semantics are normative from libphext-py: a phext is a byte buffer;
# nine dimension-break bytes walk a 9-component coordinate; scroll text
# is a maximal run of non-break bytes (newline 0x0A is ordinary text).
#
# Byte handling (important in R): phext bytes include control
# characters, and R character strings cannot be trusted with them —
# embedded NUL terminates/corrupts strings and encodings reinterpret
# bytes. So EVERYTHING here works on raw vectors (R's `raw` type):
# buffers are raw, scroll text is raw, and coordinates are integer
# vectors. Strings appear only at the edges: coordinate formatting /
# parsing, and the text helpers below, which use the latin-1
# convention (byte value == Unicode codepoint) via utf8ToInt /
# intToUtf8 on values 1..255 (a 0 byte has no string form and stays
# raw-only; game scroll text built by `choose` never contains it
# because the CLI only round-trips fetched text through strings when
# appending an ASCII suffix, and intToUtf8(0) is dropped by R — see
# raw_to_text).

# Dimension breaks in dimension order (library .. scroll), 1-based
# dimension d uses PHEXT_BREAKS[d].
PHEXT_BREAKS <- as.raw(c(0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17))
# Byte value + 1 -> dimension (1-based; 0 = not a break).
PHEXT_BREAK_DIM <- integer(256)
for (.d in 1:9) PHEXT_BREAK_DIM[as.integer(PHEXT_BREAKS[.d]) + 1L] <- .d
rm(.d)

## ------------------------------------------------------------------
## Coordinate: integer vector of length 9, each >= 1, class phext_coord.
## Ordered lexicographically; string form a.b.c/d.e.f/g.h.i.
coord_new <- function(v) {
  v <- as.integer(v)
  stopifnot(length(v) == 9L, all(v >= 1L))
  structure(v, class = "phext_coord")
}
coord_root <- function() coord_new(rep(1L, 9L))

coord_parse <- function(s) {
  groups <- strsplit(trimws(s), "/", fixed = TRUE)[[1]]
  if (length(groups) != 3L) stop("coordinate must be a.b.c/d.e.f/g.h.i: ", s)
  nums <- integer(0)
  for (g in groups) {
    parts <- strsplit(g, ".", fixed = TRUE)[[1]]
    nums <- c(nums, as.integer(parts))
  }
  if (length(nums) != 9L || any(is.na(nums))) {
    stop("coordinate must have exactly 9 numeric parts: ", s)
  }
  coord_new(nums)
}

coord_format <- function(coord) {
  v <- as.integer(coord)
  sprintf("%d.%d.%d/%d.%d.%d/%d.%d.%d", v[1], v[2], v[3], v[4], v[5],
          v[6], v[7], v[8], v[9])
}

# Lexicographic comparison of two 9-vectors: -1, 0, or 1.
coord_cmp_vec <- function(a, b) {
  for (i in 1:9) {
    if (a[i] != b[i]) return(if (a[i] < b[i]) -1L else 1L)
  }
  0L
}
coord_cmp <- function(a, b) coord_cmp_vec(as.integer(a), as.integer(b))
coord_eq <- function(a, b) coord_cmp(a, b) == 0L

# Break at dimension d (1-based): increment component d, reset all
# lower components to 1.
coord_apply_break <- function(coord, d) {
  v <- as.integer(coord)
  v[d] <- v[d] + 1L
  if (d < 9L) v[(d + 1L):9L] <- 1L
  coord_new(v)
}

## ------------------------------------------------------------------
## Text edges (latin-1 convention). See the header note on byte 0.
text_to_raw <- function(text) {
  # Vectorized (2026-11-24): the original per-codepoint c() loop is
  # O(n^2) and took ~560 s on a 1.3 MB string at game scale -- it sat
  # inside the serve framing path (memCompress/gzip framing both call
  # it) and made serve-mode explode/validate appear hung. Semantics
  # unchanged: cp < 256 emits the single byte cp; above that, the
  # character's UTF-8 bytes.
  cps <- utf8ToInt(enc2utf8(text))
  if (length(cps) == 0L) return(raw(0))
  if (all(cps < 256L)) return(as.raw(cps))
  chunks <- lapply(cps, function(cp) {
    if (cp < 256L) as.raw(cp) else charToRaw(enc2utf8(intToUtf8(cp)))
  })
  do.call(c, chunks)
}
raw_to_text <- function(bytes) {
  vals <- as.integer(bytes)
  vals <- vals[vals > 0L] # R strings cannot hold a 0 codepoint
  if (length(vals) == 0L) "" else intToUtf8(vals)
}

## ------------------------------------------------------------------
# phokenize: ordered list of scrolls; each scroll is
# list(coord = <phext_coord>, text = <raw>).
phokenize <- function(buffer) {
  stopifnot(is.raw(buffer))
  n <- length(buffer)
  if (n == 0L) return(list())
  # Vectorized scan: one lookup gives every byte's break dimension
  # (0 = ordinary text). The R loop below runs once per BREAK, not
  # once per byte — a per-byte loop made large buffers (the ~1 MB
  # seek prefix) take minutes of interpreted iteration.
  dims <- PHEXT_BREAK_DIM[as.integer(buffer) + 1L]
  bpos <- which(dims > 0L)
  out <- list()
  coord <- rep(1L, 9L)
  run_start <- 1L
  for (bp in bpos) {
    if (bp > run_start) {
      out[[length(out) + 1L]] <- list(
        coord = coord_new(coord), text = buffer[run_start:(bp - 1L)])
    }
    d <- dims[bp]
    coord[d] <- coord[d] + 1L
    if (d < 9L) coord[(d + 1L):9L] <- 1L
    run_start <- bp + 1L
  }
  if (n >= run_start) {
    out[[length(out) + 1L]] <- list(
      coord = coord_new(coord), text = buffer[run_start:n])
  }
  out
}

# Advance loc (9-vector) up to target; returns list(bytes, loc).
.phext_advance <- function(loc, target) {
  target <- as.integer(target)
  if (coord_cmp_vec(loc, target) >= 0L) return(list(bytes = raw(0), loc = loc))
  dim <- 1L
  while (loc[dim] == target[dim]) dim <- dim + 1L
  chunks <- list(rep(PHEXT_BREAKS[dim], target[dim] - loc[dim]))
  loc[dim] <- target[dim]
  if (dim < 9L) {
    loc[(dim + 1L):9L] <- 1L
    for (lower in (dim + 1L):9L) {
      if (target[lower] > 1L) {
        chunks[[length(chunks) + 1L]] <-
          rep(PHEXT_BREAKS[lower], target[lower] - 1L)
      }
      loc[lower] <- target[lower]
    }
  }
  list(bytes = do.call(c, chunks), loc = loc)
}

# Serialize scrolls in the given order, emitting empty scrolls'
# advance bytes too (libphext-py update semantics).
.phext_serialize_in_order <- function(scrolls) {
  chunks <- list()
  loc <- rep(1L, 9L)
  for (ps in scrolls) {
    adv <- .phext_advance(loc, ps$coord)
    loc <- adv$loc
    chunks[[length(chunks) + 1L]] <- adv$bytes
    chunks[[length(chunks) + 1L]] <- ps$text
  }
  if (length(chunks) == 0L) raw(0) else do.call(c, chunks)
}

# dephokenize: canonical bytes — sorted coordinate order, advancing
# from 1.1.1/1.1.1/1.1.1; empty scrolls contribute nothing.
dephokenize <- function(scrolls) {
  scrolls <- Filter(function(ps) length(ps$text) > 0L, scrolls)
  if (length(scrolls) == 0L) return(raw(0))
  mat <- do.call(rbind, lapply(scrolls, function(ps) as.integer(ps$coord)))
  ord <- do.call(order, lapply(1:9, function(j) mat[, j]))
  .phext_serialize_in_order(scrolls[ord])
}

# normalize = phokenize then dephokenize (drops empties, canonical order).
normalize <- function(buffer) dephokenize(phokenize(buffer))

# fetch: text at coord, or raw(0) for a gap coordinate (never a
# control byte).
fetch <- function(buffer, coord) {
  for (ps in phokenize(buffer)) {
    if (coord_eq(ps$coord, coord)) return(ps$text)
  }
  raw(0)
}

.phext_update <- function(buffer, coord, text, overwrite) {
  result <- list()
  appended <- FALSE
  for (ps in phokenize(buffer)) {
    if (!appended && coord_cmp(ps$coord, coord) > 0L) {
      result[[length(result) + 1L]] <- list(coord = coord, text = text)
      appended <- TRUE
    }
    if (!appended && coord_eq(ps$coord, coord)) {
      merged <- if (overwrite) text else c(ps$text, text)
      result[[length(result) + 1L]] <- list(coord = coord, text = merged)
      appended <- TRUE
      next
    }
    result[[length(result) + 1L]] <- ps
  }
  if (!appended) result[[length(result) + 1L]] <- list(coord = coord, text = text)
  .phext_serialize_in_order(result)
}

# insert: if a scroll exists at coord, the new text is the existing
# text followed by the inserted text (libphext-py prepends the
# existing scroll to the inserted one); otherwise create.
insert <- function(buffer, coord, text) .phext_update(buffer, coord, text, FALSE)

# replace: overwrite the scroll at coord.
replace <- function(buffer, coord, text) .phext_update(buffer, coord, text, TRUE)

# remove: replace with "" then normalize.
remove <- function(buffer, coord) {
  normalize(.phext_update(buffer, coord, raw(0), TRUE))
}

# explode: map form — a named list, names are coordinate strings.
explode <- function(buffer) {
  out <- list()
  for (ps in phokenize(buffer)) out[[coord_format(ps$coord)]] <- ps$text
  out
}

# implode: canonical bytes from an explode()-style named list.
implode <- function(map) {
  scrolls <- lapply(names(map), function(nm) {
    list(coord = coord_parse(nm), text = map[[nm]])
  })
  dephokenize(scrolls)
}
