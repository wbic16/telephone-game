# Test suite for libphext-r — plain assertions, base R only.
# Run: Rscript tests/test_phext.R [fixtures_dir]
args_all <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", grep("^--file=", args_all, value = TRUE)[1])
port_dir <- dirname(dirname(normalizePath(file_arg)))
source(file.path(port_dir, "src", "phext.R"))

args <- commandArgs(trailingOnly = TRUE)
failures <- 0L
checks <- 0L
ok <- function(cond, name) {
  checks <<- checks + 1L
  if (!isTRUE(cond)) {
    failures <<- failures + 1L
    cat("FAIL:", name, "\n")
  }
}
eq <- function(a, b, name) ok(identical(a, b), name)
b <- function(s) text_to_raw(s)
cc <- function(s) coord_parse(s)

# coordinate
eq(coord_format(cc("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format")
ok(coord_cmp(cc("1.1.1/1.1.1/1.1.1"), cc("1.1.1/1.1.1/1.1.2")) < 0L, "order scroll")
ok(coord_cmp(cc("1.1.1/1.1.1/1.1.9"), cc("1.1.1/1.1.2/1.1.1")) < 0L, "order section")
ok(coord_cmp(cc("2.1.1/1.1.1/1.1.1"), cc("1.9.9/9.9.9/9.9.9")) > 0L, "order library")
ok(coord_eq(cc("1.1.1/1.1.1/1.1.1"), coord_root()), "root")
ok(tryCatch({ cc("0.1.1/1.1.1/1.1.1"); FALSE }, error = function(e) TRUE),
   "coord rejects 0")
ok(tryCatch({ cc("1.1/1.1.1/1.1.1"); FALSE }, error = function(e) TRUE),
   "coord rejects short")

# phokenize (raw buffers; \x17 etc. via as.raw)
buf_hello <- charToRaw("hello")
sc <- phokenize(buf_hello)
eq(length(sc), 1L, "one scroll")
eq(coord_format(sc[[1]]$coord), "1.1.1/1.1.1/1.1.1", "first coord")
eq(sc[[1]]$text, buf_hello, "first text")
buf2 <- c(charToRaw("a"), as.raw(0x17), charToRaw("b"), as.raw(0x17),
          as.raw(0x17), charToRaw("c\nline2"))
sc <- phokenize(buf2)
eq(length(sc), 3L, "scroll breaks")
eq(coord_format(sc[[2]]$coord), "1.1.1/1.1.1/1.1.2", "second coord")
eq(coord_format(sc[[3]]$coord), "1.1.1/1.1.1/1.1.4", "gap coord advance")
eq(sc[[3]]$text, charToRaw("c\nline2"), "newline is ordinary text")
sc <- phokenize(c(charToRaw("x"), as.raw(0x01), charToRaw("y")))
eq(coord_format(sc[[2]]$coord), "2.1.1/1.1.1/1.1.1", "library break resets")
sc <- phokenize(c(charToRaw("x"), as.raw(0x18), charToRaw("y")))
eq(coord_format(sc[[2]]$coord), "1.1.1/1.1.1/1.2.1", "section break")
eq(length(phokenize(raw(0))), 0L, "empty buffer")
sc <- phokenize(c(charToRaw("a"), as.raw(0x00), as.raw(0xff), charToRaw("b")))
eq(length(sc), 1L, "binary text is one scroll")
eq(length(sc[[1]]$text), 4L, "binary text preserved")

# round trip
sample <- c(charToRaw("alpha"), as.raw(0x17), charToRaw("beta"),
            as.raw(0x18), charToRaw("gamma"), as.raw(0x01), charToRaw("delta"))
eq(dephokenize(phokenize(sample)), sample, "round trip sample")
built <- dephokenize(list(
  list(coord = cc("1.1.1/1.1.1/1.1.2"), text = charToRaw("two")),
  list(coord = cc("1.1.1/1.1.1/1.1.1"), text = charToRaw("one"))))
eq(built, c(charToRaw("one"), as.raw(0x17), charToRaw("two")),
   "dephokenize sorts canonically")
lead <- c(as.raw(0x17), as.raw(0x17), charToRaw("lead"))
eq(normalize(normalize(lead)), normalize(lead), "normalize idempotent")

# fetch incl. gaps
buf <- c(charToRaw("one"), as.raw(0x17), charToRaw("two"), as.raw(0x17),
         as.raw(0x17), charToRaw("four"))
eq(fetch(buf, cc("1.1.1/1.1.1/1.1.1")), charToRaw("one"), "fetch 1")
eq(fetch(buf, cc("1.1.1/1.1.1/1.1.4")), charToRaw("four"), "fetch 4")
eq(fetch(buf, cc("1.1.1/1.1.1/1.1.3")), raw(0), "gap fetch is empty")
eq(fetch(buf, cc("9.9.9/9.9.9/9.9.9")), raw(0), "far gap fetch is empty")
eq(fetch(raw(0), cc("1.1.1/1.1.1/1.1.1")), raw(0), "fetch empty buffer")

# insert: existing + inserted (existing prepended)
out <- insert(charToRaw("base"), cc("1.1.1/1.1.1/1.1.1"), charToRaw("+more"))
eq(fetch(out, cc("1.1.1/1.1.1/1.1.1")), charToRaw("base+more"),
   "insert appends after existing")
out <- insert(raw(0), cc("1.1.1/1.1.1/1.1.3"), charToRaw("new"))
eq(fetch(out, cc("1.1.1/1.1.1/1.1.3")), charToRaw("new"), "insert creates at gap")
eq(out, c(as.raw(0x17), as.raw(0x17), charToRaw("new")), "insert at gap emits breaks")
out <- insert(c(charToRaw("a"), as.raw(0x17), charToRaw("c")),
              cc("1.1.1/1.1.1/1.1.2"), charToRaw("b"))
eq(out, c(charToRaw("a"), as.raw(0x17), charToRaw("cb")),
   "insert at existing scroll merges (existing + inserted)")
eq(fetch(out, cc("1.1.1/1.1.1/1.1.2")), charToRaw("cb"),
   "merged scroll at coordinate")

# replace / remove
out <- replace(c(charToRaw("old"), as.raw(0x17), charToRaw("keep")),
               cc("1.1.1/1.1.1/1.1.1"), charToRaw("new"))
eq(out, c(charToRaw("new"), as.raw(0x17), charToRaw("keep")), "replace overwrites")
out <- replace(charToRaw("a"), cc("1.1.1/1.1.1/1.1.5"), charToRaw("deep"))
eq(fetch(out, cc("1.1.1/1.1.1/1.1.5")), charToRaw("deep"), "replace creates")
out <- remove(c(charToRaw("a"), as.raw(0x17), charToRaw("b"), as.raw(0x17),
                charToRaw("c")), cc("1.1.1/1.1.1/1.1.2"))
eq(out, c(charToRaw("a"), as.raw(0x17), as.raw(0x17), charToRaw("c")),
   "remove + normalize leaves a gap (no renumbering)")
eq(fetch(out, cc("1.1.1/1.1.1/1.1.2")), raw(0), "removed coordinate is a gap")
eq(fetch(out, cc("1.1.1/1.1.1/1.1.3")), charToRaw("c"),
   "later scroll keeps its coordinate")
eq(length(remove(charToRaw("only"), cc("1.1.1/1.1.1/1.1.1"))), 0L,
   "remove sole scroll")
eq(remove(charToRaw("a"), cc("5.5.5/5.5.5/5.5.5")), charToRaw("a"),
   "remove gap is a no-op")

# explode / implode
map <- explode(c(charToRaw("x"), as.raw(0x17), charToRaw("y")))
eq(length(map), 2L, "explode count")
eq(implode(map), c(charToRaw("x"), as.raw(0x17), charToRaw("y")),
   "implode round trip")

# fixtures
fx <- if (length(args) >= 1L) args[1] else Sys.getenv("PHEXT_FIXTURES")
if (nzchar(fx) && dir.exists(fx)) {
  paths <- list.files(fx, pattern = "input\\.phext$", recursive = TRUE,
                      full.names = TRUE)
  identical_count <- 0L
  idem_count <- 0L
  for (p in paths) {
    data <- readBin(p, "raw", file.info(p)$size)
    if (identical(dephokenize(phokenize(data)), data)) {
      identical_count <- identical_count + 1L
    }
    n1 <- normalize(data)
    if (identical(normalize(n1), n1)) idem_count <- idem_count + 1L
  }
  cat(sprintf(paste0("fixtures: %d input.phext, %d byte-identical ",
                     "round-trips, %d normalize-idempotent\n"),
              length(paths), identical_count, idem_count))
  eq(idem_count, length(paths), "all fixtures normalize idempotently")
  ok(identical_count >= length(paths) - 2L,
     "fixtures byte-identical round-trips")
} else {
  cat("fixtures: skipped (no fixtures dir)\n")
}

cat(sprintf("r suite: %d checks, %d failures\n", checks, failures))
quit(status = if (failures > 0L) 1L else 0L)
