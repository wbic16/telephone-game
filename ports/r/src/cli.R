# Hub-side CLI for libphext-r (Exocortical Telephone Game, contract v2).
#
# Transport: with no argument, stdin carries ONE JSON object and stdout
# carries ONE JSON response. With the argument `serve`, the CLI reads
# one JSON request per line and answers one JSON object per line.
# Requests carry phext state as base64 under "state" (v2) or
# "state_b64" (v1 wire compat).
#
# v2 subcommands: id, keygen, seek, echo, elect, choose (insert-only),
# apply, attest, validate, verify (stress.phext walk). v1 `fetch` and
# tar-based `verify` (game_tar_b64) remain for the v1 harness.
#
# choose — this port's own deterministic adventure rule (insert-only):
#   start from the tracked position; while the candidate coordinate
#   already holds a scroll, advance it by one scroll break. Insert
#   "r was here, turn N" at the first unused coordinate found.
# elect — popcorn: sha256("r-elect:<position>:<turn>:<candidates>")
#   picks from the candidates other than itself (when there are any).
# echo — sha256 hex of "r-echo:" + the ping nonce.
# attest — PGP detached armored signature (gpg, key home
#   ~/telephone-r/keys on the hub) over the canonical descriptor JSON
#   (sorted keys, "," / ":" separators, ASCII-escaped).
# Base R has no JSON, no base64 and no SHA-256, so this file carries a
# small JSON parser/writer and a base64 codec; SHA-256 uses the CRAN
# `digest` package when it is loadable and otherwise falls back to the
# system sha256sum(1) on a temp file (a hash utility, not another
# phext implementation).

args_all <- commandArgs(trailingOnly = FALSE)
file_arg <- sub("^--file=", "", grep("^--file=", args_all, value = TRUE)[1])
src_dir <- dirname(normalizePath(file_arg))
source(file.path(src_dir, "phext.R"))

IMPL <- "r"
ZERO <- paste(rep("0", 64), collapse = "")
KEY_HOME <- "/home/wbic16/telephone-r/keys"
`%||%` <- function(a, b) if (is.null(a) || inherits(a, "json_null")) b else a

## ---------------------------------------------------------- SHA-256
sha256hex <- function(bytes) {
  if (requireNamespace("digest", quietly = TRUE)) {
    return(digest::digest(bytes, algo = "sha256", serialize = FALSE))
  }
  tf <- tempfile()
  on.exit(unlink(tf))
  writeBin(bytes, tf)
  out <- system2("sha256sum", tf, stdout = TRUE)
  strsplit(out[1], " ", fixed = TRUE)[[1]][1]
}
sha256hex_str <- function(s) sha256hex(charToRaw(enc2utf8(s)))

## ---------------------------------------------------------- base64
B64_ALPH <- charToRaw("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
b64encode <- function(bytes) {
  if (length(bytes) == 0L) return("")
  vals <- as.integer(bytes)
  pad <- (3L - length(vals) %% 3L) %% 3L
  vals <- c(vals, rep(0L, pad))
  m <- matrix(vals, nrow = 3L)
  idx <- rbind(m[1, ] %/% 4L,
               (m[1, ] %% 4L) * 16L + m[2, ] %/% 16L,
               (m[2, ] %% 16L) * 4L + m[3, ] %/% 64L,
               m[3, ] %% 64L)
  chars <- rawToChar(B64_ALPH[as.integer(idx) + 1L])
  if (pad > 0L) {
    chars <- paste0(substr(chars, 1, nchar(chars) - pad),
                    paste(rep("=", pad), collapse = ""))
  }
  chars
}
b64decode <- function(s) {
  s <- gsub("[\r\n ]", "", s)
  if (nchar(s) == 0L) return(raw(0))
  # Integer-codepoint path (vectorized); strsplit(s, "") builds one
  # string object per character and crawls on megabyte inputs.
  cps <- utf8ToInt(s)
  vals <- match(cps, utf8ToInt(rawToChar(B64_ALPH))) - 1L
  vals[cps == 61L] <- 0L  # '='
  pad <- sum(cps == 61L)
  m <- matrix(vals, nrow = 4L)
  bytes <- as.raw(rbind(m[1, ] * 4L + m[2, ] %/% 16L,
                        (m[2, ] %% 16L) * 16L + m[3, ] %/% 4L,
                        (m[3, ] %% 4L) * 64L + m[4, ]))
  if (pad > 0L) bytes <- bytes[1:(length(bytes) - pad)]
  bytes
}

## Game-scale framing helper (2026-11-24): R's memCompress
## (type="gzip") takes ~560 s on a 1.3 MB serve reply at 1,000
## placements (measured on aletheia-core) -- with it, r's serve-mode
## explode/validate appeared hung while unframed one-shot mode took
## ~31 s. Frame with the system gzip(1) on temp files instead, like
## the lua/fortran/awk/tcl ports. memDecompress stays for unframing:
## it reads a framed request in ~4 ms.
gz_frame <- function(text) {
  fin <- tempfile()
  con <- file(fin, "wb")
  writeBin(text_to_raw(text), con)
  close(con)
  fb <- paste0(fin, ".b64")
  system(sprintf("gzip -c %s | base64 -w0 > %s",
                 shQuote(fin), shQuote(fb)))
  enc <- paste(readLines(fb, warn = FALSE), collapse = "")
  unlink(c(fin, fb))
  paste0("GZ1:", enc)
}

## ---------------------------------------------------------- mini JSON
JSON_NULL <- structure(list(), class = "json_null")
.jparse <- function(text) {
  cps <- utf8ToInt(enc2utf8(text))
  st <- new.env()
  st$cps <- cps
  st$i <- 0L
  st$n <- length(cps)
  peek <- function() {
    while (st$i < st$n && st$cps[st$i + 1L] %in% c(32L, 9L, 10L, 13L)) {
      st$i <- st$i + 1L
    }
    if (st$i >= st$n) stop("unexpected end of JSON")
    st$cps[st$i + 1L]
  }
  parse_string <- function() {
    st$i <- st$i + 1L
    # Fast path: no escape before the closing quote — slice the
    # codepoint vector once. The accumulating loop below is O(n^2)
    # through c() copies and must never see a megabyte base64 value.
    start <- st$i + 1L
    if (start <= st$n) {
      rel <- which(st$cps[start:st$n] == 34L |
                   st$cps[start:st$n] == 92L)
      if (length(rel) > 0L && st$cps[start + rel[1L] - 1L] == 34L) {
        end <- start + rel[1L] - 1L  # index of the closing quote
        st$i <- end
        if (end == start) return("")
        return(intToUtf8(st$cps[start:(end - 1L)]))
      }
    }
    out <- integer(0)
    repeat {
      st$i <- st$i + 1L
      cp <- st$cps[st$i]
      if (cp == 34L) break
      if (cp == 92L) {
        st$i <- st$i + 1L
        esc <- st$cps[st$i]
        if (esc == 117L) {
          hex <- intToUtf8(st$cps[(st$i + 1L):(st$i + 4L)])
          cp2 <- strtoi(hex, base = 16L)
          st$i <- st$i + 4L
          if (cp2 >= 0xD800 && cp2 <= 0xDBFF &&
              st$i + 2L <= st$n && st$cps[st$i + 1L] == 92L &&
              st$cps[st$i + 2L] == 117L) {
            hex2 <- intToUtf8(st$cps[(st$i + 3L):(st$i + 6L)])
            lo <- strtoi(hex2, base = 16L)
            cp2 <- 0x10000 + (cp2 - 0xD800) * 1024 + (lo - 0xDC00)
            st$i <- st$i + 6L
          }
          out <- c(out, cp2)
        } else {
          out <- c(out, switch(intToUtf8(esc),
                               "n" = 10L, "t" = 9L, "r" = 13L,
                               "b" = 8L, "f" = 12L, esc))
        }
      } else {
        out <- c(out, cp)
      }
    }
    if (length(out) == 0L) "" else intToUtf8(out)
  }
  parse_number <- function() {
    start <- st$i
    while (st$i < st$n &&
           st$cps[st$i + 1L] %in% utf8ToInt("-+0123456789.eE")) {
      st$i <- st$i + 1L
    }
    tok <- intToUtf8(st$cps[(start + 1L):st$i])
    if (grepl("[.eE]", tok)) as.numeric(tok) else as.integer(tok)
  }
  parse_value <- function() {
    cp <- peek()
    if (cp == 123L) {
      st$i <- st$i + 1L
      obj <- list()
      if (peek() == 125L) {
        st$i <- st$i + 1L
        return(obj)
      }
      repeat {
        key <- parse_value()
        if (peek() != 58L) stop("expected :")
        st$i <- st$i + 1L
        obj[[key]] <- parse_value()
        nxt <- peek()
        st$i <- st$i + 1L
        if (nxt == 125L) break
        if (nxt != 44L) stop("expected , or }")
      }
      obj
    } else if (cp == 91L) {
      st$i <- st$i + 1L
      arr <- list()
      if (peek() == 93L) {
        st$i <- st$i + 1L
        return(arr)
      }
      repeat {
        arr[[length(arr) + 1L]] <- parse_value()
        nxt <- peek()
        st$i <- st$i + 1L
        if (nxt == 93L) break
        if (nxt != 44L) stop("expected , or ]")
      }
      arr
    } else if (cp == 34L) {
      parse_string()
    } else if (cp == 116L) {
      st$i <- st$i + 4L
      TRUE
    } else if (cp == 102L) {
      st$i <- st$i + 5L
      FALSE
    } else if (cp == 110L) {
      st$i <- st$i + 4L
      JSON_NULL
    } else {
      parse_number()
    }
  }
  parse_value()
}

# Fast path for canonical = FALSE (2026-11-24): the per-codepoint
# loop in .jstr_escape below costs ~28 s on the 1.3 MB explode map at
# game scale (jwrite uses canonical = FALSE exclusively). This
# vectorized form is byte-identical -- verified against the loop over
# every key/value of the 1,000-placement snapshot map plus edge-case
# strings. canonical = TRUE (canon(), used on small attest/event
# structures) keeps the original loop untouched.
.jstr_escape_fast <- function(s) {
  cps <- utf8ToInt(enc2utf8(s))
  n <- length(cps)
  if (n == 0L) return('""')
  parts <- character(n)
  esc <- cps == 34L | cps == 92L | cps == 10L | cps == 13L |
         cps == 9L | cps < 32L
  if (any(!esc)) {
    parts[!esc] <- intToUtf8(cps[!esc], multiple = TRUE)
  }
  if (any(esc)) {
    ec <- cps[esc]
    parts[esc] <- ifelse(ec == 34L, '\\"', ifelse(ec == 92L, '\\\\',
      ifelse(ec == 10L, '\\n', ifelse(ec == 13L, '\\r',
      ifelse(ec == 9L, '\\t', sprintf('\\u%04x', ec))))))
  }
  paste0('"', paste(parts, collapse = ""), '"')
}

.jstr_escape <- function(s, canonical) {
  if (!canonical) return(.jstr_escape_fast(s))
  cps <- utf8ToInt(enc2utf8(s))
  parts <- character(0)
  for (cp in cps) {
    parts <- c(parts,
      if (cp == 34L) '\\"'
      else if (cp == 92L) "\\\\"
      else if (cp == 10L) "\\n"
      else if (cp == 13L) "\\r"
      else if (cp == 9L) "\\t"
      else if (canonical && cp == 8L) "\\b"
      else if (canonical && cp == 12L) "\\f"
      else if (cp >= 32L && cp < 127L) intToUtf8(cp)
      else if (canonical && cp <= 0xFFFF) sprintf("\\u%04x", cp)
      else if (canonical) {
        x <- cp - 0x10000
        sprintf("\\u%04x\\u%04x", 0xD800 + x %/% 1024L, 0xDC00 + x %% 1024L)
      }
      else if (cp < 32L) sprintf("\\u%04x", cp)
      else intToUtf8(cp))
  }
  paste0('"', paste(parts, collapse = ""), '"')
}

jwrite <- function(v) {
  if (inherits(v, "json_null") || is.null(v)) {
    "null"
  } else if (is.logical(v)) {
    if (v) "true" else "false"
  } else if (is.integer(v)) {
    as.character(v)
  } else if (is.numeric(v)) {
    if (v == trunc(v)) as.character(as.integer(v)) else as.character(v)
  } else if (is.character(v)) {
    .jstr_escape(v, canonical = FALSE)
  } else if (is.list(v)) {
    if (!is.null(names(v)) && any(names(v) != "")) {
      inner <- vapply(names(v), function(k) {
        paste0(.jstr_escape(k, canonical = FALSE), ":", jwrite(v[[k]]))
      }, character(1))
      paste0("{", paste(inner, collapse = ","), "}")
    } else {
      inner <- vapply(v, jwrite, character(1))
      paste0("[", paste(inner, collapse = ","), "]")
    }
  } else {
    stop("cannot write JSON for ", class(v))
  }
}

canon <- function(v) {
  if (inherits(v, "json_null") || is.null(v)) {
    "null"
  } else if (is.logical(v)) {
    if (v) "true" else "false"
  } else if (is.integer(v)) {
    as.character(v)
  } else if (is.numeric(v)) {
    if (v == trunc(v)) as.character(as.integer(v)) else as.character(v)
  } else if (is.character(v)) {
    .jstr_escape(v, canonical = TRUE)
  } else if (is.list(v)) {
    if (!is.null(names(v)) && any(names(v) != "")) {
      keys <- sort(names(v))
      inner <- vapply(keys, function(k) {
        paste0(.jstr_escape(k, canonical = TRUE), ":", canon(v[[k]]))
      }, character(1))
      paste0("{", paste(inner, collapse = ","), "}")
    } else {
      inner <- vapply(v, canon, character(1))
      paste0("[", paste(inner, collapse = ","), "]")
    }
  } else {
    stop("cannot canonicalize ", class(v))
  }
}

hexdecode <- function(hex) {
  n <- nchar(hex) %/% 2L
  as.raw(strtoi(substring(hex, 2L * (1:n) - 1L, 2L * (1:n)), base = 16L))
}
state_of <- function(req) {
  b64decode(req[["state"]] %||% req[["state_b64"]])
}

## ---------------------------------------------------------- gpg
gpg_run <- function(args, home = KEY_HOME) {
  dir.create(home, showWarnings = FALSE, recursive = TRUE)
  outfile <- tempfile()
  errfile <- tempfile()
  status <- system2("gpg", args,
                    env = paste0("GNUPGHOME=", home),
                    stdout = outfile, stderr = errfile)
  out <- if (file.exists(outfile)) {
    rawToChar(readBin(outfile, "raw", file.info(outfile)$size))
  } else {
    ""
  }
  unlink(c(outfile, errfile))
  list(ok = identical(as.integer(status), 0L), out = out)
}

ensure_key <- function() {
  listing <- gpg_run(c("--batch", "--list-keys", "--with-colons"))
  if (!listing$ok || !grepl("pub:", listing$out, fixed = TRUE)) {
    gen <- gpg_run(c("--batch", "--pinentry-mode", "loopback",
                     "--passphrase", "", "--quick-generate-key",
                     "libphext-r <r@telephone.exocortex>",
                     "ed25519", "sign", "never"))
    if (!gen$ok) stop("keygen failed")
  }
  exp <- gpg_run(c("--batch", "--armor", "--export", "libphext-r"))
  if (!exp$ok) stop("pubkey export failed")
  trimws(exp$out)
}

sign_descriptor <- function(descriptor) {
  ensure_key()
  dir <- tempfile(pattern = "r-attest")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))
  data <- file.path(dir, "descriptor.json")
  writeBin(charToRaw(enc2utf8(canon(descriptor))), data)
  sig <- file.path(dir, "descriptor.sig")
  res <- gpg_run(c("--batch", "--yes", "--pinentry-mode", "loopback",
                   "--passphrase", "", "--detach-sign", "--armor",
                   "--output", sig, data))
  if (!res$ok) stop("attest signing failed")
  trimws(rawToChar(readBin(sig, "raw", file.info(sig)$size)))
}

verify_signature <- function(pubkeys, signature, data_raw) {
  dir <- tempfile(pattern = "r-verify")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE))
  home <- file.path(dir, "gnupg")
  dir.create(home)
  Sys.chmod(home, "0700")
  keyfile <- file.path(dir, "keys.asc")
  writeBin(charToRaw(enc2utf8(pubkeys)), keyfile)
  imp <- gpg_run(c("--batch", "--import", keyfile), home = home)
  if (!imp$ok) return(FALSE)
  datafile <- file.path(dir, "data")
  writeBin(data_raw, datafile)
  sigfile <- file.path(dir, "data.sig")
  writeBin(charToRaw(enc2utf8(signature)), sigfile)
  res <- gpg_run(c("--batch", "--verify", sigfile, datafile), home = home)
  res$ok
}

## ---------------------------------------------------------- seek
# Raw file I/O only: in-process directory listing + byte reads; break
# positions are located on the raw vector in-process. No subprocesses,
# no search tools, no indexes.
seek <- function(root) {
  if (!dir.exists(root)) return(NULL)
  top <- sort(list.files(root, pattern = "\\.phext$", full.names = TRUE))
  rest <- sort(list.files(root, pattern = "\\.phext$",
                          full.names = TRUE, recursive = TRUE))
  files <- c(top, setdiff(rest, top))
  target <- rep(13L, 9L)
  breakvals <- as.integer(PHEXT_BREAKS)
  for (path in files) {
    data <- readBin(path, "raw", file.info(path)$size)
    vals <- as.integer(data)
    bp <- which(vals %in% breakvals)
    coord <- rep(1L, 9L)
    run_start <- 1L
    found <- NULL
    for (i in bp) {
      if (identical(coord, target) && i > run_start) {
        found <- data[run_start:(i - 1L)]
        break
      }
      d <- PHEXT_BREAK_DIM[vals[i] + 1L]
      coord[d] <- coord[d] + 1L
      if (d < 9L) coord[(d + 1L):9L] <- 1L
      run_start <- i + 1L
    }
    if (is.null(found) && identical(coord, target) &&
        length(data) >= run_start) {
      found <- data[run_start:length(data)]
    }
    if (!is.null(found)) {
      nl <- match(10L, as.integer(found))
      first <- if (is.na(nl)) found else found[seq_len(nl - 1L)]
      return(list(impl = IMPL, path = path,
                  offset = as.integer(run_start - 1L),
                  coordinate = "13.13.13/13.13.13/13.13.13",
                  title = trimws(raw_to_text(first))))
    }
  }
  NULL
}

## ---------------------------------------------------------- untar
untar <- function(data) {
  out <- list()
  off <- 0L
  n <- length(data)
  cstr <- function(bytes) {
    z <- match(0L, as.integer(bytes))
    if (!is.na(z)) bytes <- bytes[seq_len(z - 1L)]
    rawToChar(bytes)
  }
  while (off + 512L <= n) {
    header <- data[(off + 1L):(off + 512L)]
    if (all(header == as.raw(0))) break
    name <- cstr(header[1:100])
    prefix <- cstr(header[346:500])
    if (nchar(prefix) > 0L) name <- paste0(prefix, "/", name)
    size_field <- trimws(cstr(header[125:136]))
    size <- if (nchar(size_field) == 0L) 0L else strtoi(size_field, base = 8L)
    type <- as.integer(header[157])
    off <- off + 512L
    if (type == 0x30 || type == 0L) {
      out[[name]] <- if (size > 0L) data[(off + 1L):(off + size)] else raw(0)
    }
    off <- off + ((size + 511L) %/% 512L) * 512L
  }
  out
}

## ---------------------------------------------------------- game logic
apply_step <- function(data, step) {
  op <- step[["op"]]
  coord <- coord_parse(step[["coordinate"]])
  fetch_sha <- if (op == "fetch") sha256hex(fetch(data, coord)) else NULL
  if (op == "fetch" || op == "navigate") {
    return(list(state = data, fetch_sha256 = fetch_sha))
  }
  map <- explode(data)
  key <- coord_format(coord)
  if (op == "insert") {
    existing <- if (key %in% names(map)) map[[key]] else raw(0)
    map[[key]] <- c(existing, text_to_raw(step[["text"]] %||% ""))
  } else if (op == "replace") {
    map[[key]] <- text_to_raw(step[["text"]] %||% "")
  } else if (op == "remove") {
    map[[key]] <- NULL
  } else {
    stop("unknown op ", op)
  }
  list(state = implode(map), fetch_sha256 = fetch_sha)
}

verify_fail <- function(n, msg, field = "steps_checked") {
  out <- list(impl = IMPL, verdict = "fail",
              first_failure = list(detail = msg))
  out[[field]] <- as.integer(n)
  out
}

verify_tar <- function(tar_bytes) {
  files <- untar(tar_bytes)
  find <- function(suffix) {
    hits <- names(files)[names(files) == suffix |
                           endsWith(names(files), paste0("/", suffix))]
    if (length(hits) == 0L) NULL else files[[hits[1]]]
  }
  tdata <- find("transcript.jsonl")
  gdata <- find("genesis.phext")
  if (is.null(tdata) || is.null(gdata)) {
    return(verify_fail(0, "missing transcript/genesis"))
  }
  lines <- strsplit(rawToChar(tdata), "\n", fixed = TRUE)[[1]]
  lines <- trimws(lines)
  lines <- lines[nchar(lines) > 0L]
  records <- lapply(lines, .jparse)
  if (length(records) == 0L) return(verify_fail(0, "empty transcript"))
  head <- ZERO
  for (rec in records) {
    if (!identical(rec[["prev"]], head)) {
      return(verify_fail(0, "chain prev mismatch"))
    }
    body <- rec
    body[["prev"]] <- NULL
    body[["hash"]] <- NULL
    digest <- sha256hex(c(hexdecode(head), charToRaw(enc2utf8(canon(body)))))
    if (!identical(digest, rec[["hash"]])) {
      return(verify_fail(0, "chain hash mismatch"))
    }
    head <- rec[["hash"]]
  }
  state <- gdata
  if (!identical(sha256hex(state), records[[1]][["genesis_sha256"]])) {
    return(verify_fail(0, "genesis hash mismatch"))
  }
  pings <- list()
  for (r in records) {
    if (identical(r[["type"]], "ping")) {
      pings[[as.character(r[["turn"]])]] <- r[["nonce"]]
    }
  }
  echoes <- list()
  checked <- 0L
  for (rec in records) {
    type <- rec[["type"]]
    turn_key <- as.character(rec[["turn"]])
    if (identical(type, "echo")) {
      if (identical(rec[["impl"]], IMPL)) {
        want <- sha256hex_str(paste0("r-echo:", pings[[turn_key]]))
        if (!identical(want, rec[["echo"]])) {
          return(verify_fail(checked, paste0(
            "own echo mismatch turn ", rec[["turn"]])))
        }
      }
      echoes[[turn_key]] <- c(echoes[[turn_key]], list(rec))
    } else if (identical(type, "handoff")) {
      es <- echoes[[turn_key]]
      if (is.null(es) || length(es) == 0L) {
        return(verify_fail(checked, "handoff with no echoes"))
      }
      ord <- order(vapply(es, function(e) e[["echo"]], character(1)),
                   vapply(es, function(e) e[["impl"]], character(1)))
      best <- es[[ord[1]]]
      if (!identical(best[["impl"]], rec[["to"]])) {
        return(verify_fail(checked, paste0(
          "echolocation outcome mismatch turn ", rec[["turn"]])))
      }
    } else if (identical(type, "turn")) {
      step <- rec[["step"]]
      if (identical(step[["op"]], "fetch")) {
        got <- sha256hex(fetch(state, coord_parse(step[["coordinate"]])))
        if (!identical(got, rec[["fetch_sha256"]])) {
          return(verify_fail(checked, paste0(
            "fetch mismatch turn ", rec[["turn"]])))
        }
      }
      state <- apply_step(state, step)$state
      if (!identical(sha256hex(state), rec[["state_sha256"]])) {
        return(verify_fail(checked, paste0(
          "state mismatch turn ", rec[["turn"]])))
      }
      checked <- checked + 1L
    }
  }
  list(impl = IMPL, verdict = "pass", steps_checked = checked,
       first_failure = JSON_NULL)
}

## ---------------------------------------------------------- v2 verify
verify_stress <- function(data, pubkeys_arg) {
  map <- explode(data)
  keys_name <- "1.1.1/1.1.1/1.1.2"
  hash_name <- "1.1.1/1.1.1/1.1.3"
  index_name <- "1.1.1/1.1.1/1.1.1"
  pubkeys <- pubkeys_arg %||% ""
  if (keys_name %in% names(map)) {
    inscribed <- raw_to_text(map[[keys_name]])
    if (!nzchar(pubkeys)) pubkeys <- inscribed
    if (hash_name %in% names(map)) {
      want <- trimws(raw_to_text(map[[hash_name]]))
      if (!identical(sha256hex(map[[keys_name]]), want)) {
        return(verify_fail(0, "keys-hash scroll does not match keys scroll",
                           "placements_checked"))
      }
    }
  }
  index <- list()
  if (index_name %in% names(map)) {
    text <- trimws(raw_to_text(map[[index_name]]))
    if (nzchar(text)) {
      if (startsWith(text, "{")) {
        obj <- .jparse(text)
        for (k in names(obj)) index[[k]] <- obj[[k]]
      } else {
        for (line in strsplit(text, "\n", fixed = TRUE)[[1]]) {
          parts <- strsplit(trimws(line), "\\s+")[[1]]
          if (length(parts) == 2L) index[[parts[1]]] <- parts[2]
        }
      }
    }
  }
  reserved <- c(index_name, keys_name, hash_name)
  event_names <- grep("^1\\.1\\.1/1\\.1\\.1/2\\.1\\.[0-9]+$", names(map),
                      value = TRUE)
  seq_of <- function(nm) {
    as.integer(strsplit(nm, "[/.]")[[1]][9])
  }
  event_names <- event_names[order(vapply(event_names, seq_of, integer(1)))]
  head <- ZERO
  attested <- character(0)
  checked <- 0L
  for (nm in event_names) {
    ev <- tryCatch(.jparse(raw_to_text(map[[nm]])),
                   error = function(e) NULL)
    if (is.null(ev)) {
      return(verify_fail(checked, paste0("event at ", nm, " is not JSON"),
                         "placements_checked"))
    }
    if (!identical(ev[["prev"]], head)) {
      return(verify_fail(checked, paste0(
        "event chain prev mismatch at ", nm), "placements_checked"))
    }
    body <- ev
    body[["prev"]] <- NULL
    body[["hash"]] <- NULL
    digest <- sha256hex(c(hexdecode(head), charToRaw(enc2utf8(canon(body)))))
    if (!identical(digest, ev[["hash"]])) {
      return(verify_fail(checked, paste0(
        "event chain hash mismatch at ", nm), "placements_checked"))
    }
    head <- ev[["hash"]]
    if (identical(ev[["type"]], "placement")) {
      desc <- ev[["descriptor"]]
      coord_str <- desc[["coordinate"]]
      if (!(coord_str %in% names(map))) {
        return(verify_fail(checked, paste0(
          "placement scroll missing at ", coord_str), "placements_checked"))
      }
      if (!identical(sha256hex(map[[coord_str]]), desc[["scroll_sha256"]])) {
        return(verify_fail(checked, paste0(
          "placement scroll hash mismatch at ", coord_str),
          "placements_checked"))
      }
      if (!identical(index[[coord_str]] %||% "", desc[["scroll_sha256"]])) {
        return(verify_fail(checked, paste0(
          "index hash mismatch at ", coord_str), "placements_checked"))
      }
      sig <- ev[["signature"]] %||% ""
      if (!nzchar(pubkeys) ||
          !verify_signature(pubkeys, sig,
                            charToRaw(enc2utf8(canon(desc))))) {
        return(verify_fail(checked, paste0(
          "attestation signature fails at ", coord_str),
          "placements_checked"))
      }
      attested <- c(attested, coord_str)
      checked <- checked + 1L
    }
  }
  for (nm in names(map)) {
    if (nm %in% reserved || nm %in% event_names) next
    if (!identical(index[[nm]] %||% "", sha256hex(map[[nm]]))) {
      return(verify_fail(checked, paste0(
        "unindexed placement at ", nm), "placements_checked"))
    }
    if (!(nm %in% attested)) {
      return(verify_fail(checked, paste0(
        "unattested placement at ", nm), "placements_checked"))
    }
  }
  if (length(index) != length(attested)) {
    return(verify_fail(checked, "index/attestation count mismatch",
                       "placements_checked"))
  }
  list(impl = IMPL, verdict = "pass", placements_checked = checked,
       first_failure = JSON_NULL)
}

## ---------------------------------------------------------- dispatch
dispatch <- function(req) {
  cmd <- req[["cmd"]]
  if (cmd == "id") {
    list(impl = IMPL)
  } else if (cmd == "keygen") {
    list(impl = IMPL, pubkey = ensure_key())
  } else if (cmd == "seek") {
    found <- seek(req[["root"]] %||% "")
    if (is.null(found)) list(impl = IMPL, error = "not found") else found
  } else if (cmd == "echo") {
    ping <- req[["ping"]] %||% req
    list(impl = IMPL,
         echo = sha256hex_str(paste0("r-echo:", ping[["nonce"]])))
  } else if (cmd == "elect") {
    candidates <- vapply(req[["candidates"]], as.character, character(1))
    pool <- candidates[candidates != IMPL]
    if (length(pool) == 0L) pool <- candidates
    seed <- sha256hex_str(paste0("r-elect:", req[["position"]], ":",
                                 req[["turn"]], ":",
                                 paste(candidates, collapse = ",")))
    idx <- strtoi(substr(seed, 1, 7), base = 16L) %% length(pool) + 1L
    list(elect = pool[idx])
  } else if (cmd == "choose") {
    data <- state_of(req)
    map <- explode(data)
    candidate <- coord_parse(req[["position"]])
    while (coord_format(candidate) %in% names(map)) {
      candidate <- coord_apply_break(candidate, 9L)
    }
    list(op = "insert", coordinate = coord_format(candidate),
         text = sprintf("r was here, turn %d", req[["turn"]]))
  } else if (cmd == "apply") {
    res <- apply_step(state_of(req), req[["step"]])
    list(state_b64 = b64encode(res$state),
         state_sha256 = sha256hex(res$state))
  } else if (cmd == "attest") {
    list(signature = sign_descriptor(req[["descriptor"]]))
  } else if (cmd == "validate") {
    data <- state_of(req)
    step <- req[["step"]]
    coord <- coord_parse(step[["coordinate"]])
    map <- explode(data)
    key <- coord_format(coord)
    detail <- NULL
    if (!(key %in% names(map))) {
      detail <- paste0("placed scroll missing at ", key)
    } else {
      placed <- map[[key]]
      desc <- req[["descriptor"]] %||% NULL
      if (!is.null(desc) &&
          !identical(sha256hex(placed), desc[["scroll_sha256"]])) {
        detail <- "placed scroll hash != attested scroll_sha256"
      } else if (!is.null(step[["text"]]) &&
                 !identical(raw_to_text(placed), step[["text"]])) {
        detail <- "placed scroll text != step text"
      } else if (!is.null(req[["prior_state"]])) {
        prior_bytes <- b64decode(req[["prior_state"]])
        if (!is.null(desc) &&
            !identical(sha256hex(prior_bytes), desc[["prior_file_sha256"]])) {
          detail <- "prior file hash != attested prior_file_sha256"
        } else {
          prior <- explode(prior_bytes)
          for (k in names(prior)) {
            if (!(k %in% names(map)) || !identical(map[[k]], prior[[k]])) {
              detail <- paste0("prior scroll overwritten or lost at ", k)
              break
            }
          }
          if (is.null(detail)) {
            added <- setdiff(names(map), names(prior))
            if (length(added) != 1L || added[1] != key) {
              detail <- paste0("expected exactly one added scroll at ", key)
            }
          }
        }
      }
    }
    if (!is.null(detail)) {
      list(impl = IMPL, verdict = "fail", detail = detail)
    } else {
      list(impl = IMPL, verdict = "pass",
           detail = paste0("placed scroll present at unused coordinate; ",
                           "no prior scroll overwritten"))
    }
  } else if (cmd == "verify") {
    if (!is.null(req[["game_tar_b64"]])) {
      verify_tar(b64decode(req[["game_tar_b64"]]))
    } else {
      verify_stress(state_of(req), req[["pubkeys"]] %||% NULL)
    }
  } else if (cmd == "fetch") {
    got <- fetch(state_of(req), coord_parse(req[["coordinate"]]))
    list(text_b64 = b64encode(got), text = raw_to_text(got))
  } else if (cmd == "explode") {
    # Hook for harness/adapter_base.py: coordinate string -> text_b64.
    map <- explode(state_of(req))
    out <- lapply(map, b64encode)
    list(map = out)
  } else if (cmd == "implode") {
    input <- req[["map"]]
    map <- lapply(input, b64decode)
    out <- implode(map)
    list(state_b64 = b64encode(out), state_sha256 = sha256hex(out))
  } else if (cmd == "insert") {
    # Game insert (adapter_base hook semantics): unused coord only.
    map <- explode(state_of(req))
    key <- coord_format(coord_parse(req[["coordinate"]]))
    if (key %in% names(map)) {
      list(error = "coordinate already occupied")
    } else {
      map[[key]] <- b64decode(req[["text_b64"]])
      out <- implode(map)
      list(state_b64 = b64encode(out), state_sha256 = sha256hex(out))
    }
  } else {
    stop("unknown cmd ", cmd)
  }
}

main <- function() {
  trailing <- commandArgs(trailingOnly = TRUE)
  if (length(trailing) >= 1L && trailing[1] == "serve") {
    con <- file("stdin")
    open(con, "r")
    on.exit(close(con))
    repeat {
      line <- readLines(con, n = 1L, warn = FALSE)
      if (length(line) == 0L) break
      line <- trimws(line)
      if (!nzchar(line)) next
      # Game-scale framing (2026-11-24): lines over 8 KB may arrive
      # gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh
      # channel is ~25-70 KB/s and raw base64 state lines took
      # minutes at 1,000 placements. Base R memCompress/memDecompress
      # do the gzip. Lossless; plain lines unchanged.
      if (startsWith(line, "GZ1:")) {
        line <- raw_to_text(memDecompress(b64decode(substring(line, 5L)),
                                          type = "gzip"))
      }
      resp <- tryCatch(dispatch(.jparse(line)),
                       error = function(e) list(error = conditionMessage(e)))
      out <- jwrite(resp)
      if (nchar(out) > 8192L) {
        out <- gz_frame(out)
      }
      cat(out, "\n", sep = "")
      flush.console()
    }
    return(invisible(NULL))
  }
  inp <- paste(readLines(file("stdin"), warn = FALSE), collapse = "\n")
  resp <- dispatch(.jparse(inp))
  cat(jwrite(resp), "\n", sep = "")
}
main()
