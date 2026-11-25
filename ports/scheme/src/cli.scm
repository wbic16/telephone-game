;;; Hub-side CLI for libphext-scheme (Exocortical Telephone Game,
;;; contract v2). Transport: argument `serve` = one JSON request per
;;; line on stdin, one response per line on stdout; no argument = ONE
;;; JSON object on stdin, ONE response. State crosses the wire as
;;; base64 under "state". Serve lines over 8 KB travel GZ1-framed:
;;; "GZ1:" + base64(gzip(line)). Wraps only this port's own libphext
;;; (src/phext.scm). JSON is hand-written here (canonical form must
;;; match Python json.dumps); SHA-256/base64/gzip go through the
;;; standard CLI tools (sha256sum, base64, gzip) where Guile lacks
;;; them; PGP goes through subprocess gpg with per-port GNUPGHOME
;;; (~/telephone-scheme/gnupg unless TELEPHONE_GNUPGHOME).
;;;
;;; All wire text is handled as ISO-8859-1 strings (char == byte), so
;;; scroll bytes are never reinterpreted.

(use-modules (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (ice-9 rdelim)
             (ice-9 rw)
             (ice-9 popen)
             (ice-9 ftw))

(load (string-append (dirname (current-filename)) "/phext.scm"))

(define %impl "scheme")
(define %index-coord (coord-root))
(define %keys-coord '(1 1 1 1 1 1 1 1 2))
(define %kh-coord '(1 1 1 1 1 1 1 1 3))
(define %evprefix '(1 1 1 1 1 1 2 1))

;;; ---------------- byte/string helpers ----------------
(define (bv->latin1 bv)
  (bytevector->string bv (make-transcoder (latin-1-codec))))
(define (latin1->bv s)
  (string->bytevector s (make-transcoder (latin-1-codec))))
(define (bv->utf8 bv)
  (bytevector->string bv (make-transcoder (utf-8-codec))))
(define (utf8->bv s)
  (string->bytevector s (make-transcoder (utf-8-codec))))

(define (tmpfile tag)
  (string-append "/tmp/tel-scheme-" tag "-"
                 (number->string (getpid)) "-"
                 (number->string (random 1000000000))))

(define (shell-read cmd)  ; returns stdout as latin1 string
  (let* ((port (open-input-pipe cmd))
         (txt (read-string port)))
    (close-pipe port)
    txt))

(define (read-string port)
  (let loop ((acc '()))
    (let ((chunk (read-string-n port 65536)))
      (if (eof-object? chunk)
          (string-concatenate-reverse acc)
          (loop (cons chunk acc))))))

(define (read-string-n port n)
  (let ((buf (make-string n)))
    (let ((got (read-string!/partial buf port)))
      (if got (substring buf 0 got) (eof-object)))))

(define (sha256hex bv)
  (let ((f (tmpfile "sha")))
    (call-with-output-file f (lambda (p) (put-bytevector p bv)) #:binary #t)
    (let ((out (shell-read (string-append "sha256sum " f))))
      (delete-file f)
      (substring out 0 64))))

;; base64 via the standard CLI tool: this Guile build ships no
;; (rnrs base64) module.
(define (b64 bv)
  (let ((fi (tmpfile "b64i")) (fo (tmpfile "b64o")))
    (call-with-output-file fi (lambda (p) (put-bytevector p bv)) #:binary #t)
    (system (string-append "base64 -w0 < " fi " > " fo))
    (let ((out (call-with-input-file fo (lambda (p) (read-string p)))))
      (delete-file fi) (delete-file fo)
      (latin1->bv out))))

(define (unb64 s)
  (let ((fi (tmpfile "b64i")) (fo (tmpfile "b64o")))
    (call-with-output-file fi (lambda (p) (put-bytevector p (utf8->bv s))) #:binary #t)
    (system (string-append "base64 -d < " fi " > " fo))
    (let ((out (call-with-input-file fo
                 (lambda (p) (get-bytevector-all p)) #:binary #t)))
      (delete-file fi) (delete-file fo)
      out)))

(define (gzip-bytes bv)
  (let ((fi (tmpfile "gzi")) (fo (tmpfile "gzo")))
    (call-with-output-file fi (lambda (p) (put-bytevector p bv)) #:binary #t)
    (system (string-append "gzip -c " fi " > " fo))
    (let ((out (call-with-input-file fo
                 (lambda (p) (get-bytevector-all p)) #:binary #t)))
      (delete-file fi) (delete-file fo)
      out)))

(define (gunzip-bytes bv)
  (let ((fi (tmpfile "gzi")) (fo (tmpfile "gzo")))
    (call-with-output-file fi (lambda (p) (put-bytevector p bv)) #:binary #t)
    (system (string-append "gzip -dc " fi " > " fo))
    (let ((out (call-with-input-file fo
                 (lambda (p) (get-bytevector-all p)) #:binary #t)))
      (delete-file fi) (delete-file fo)
      out)))

;;; ---------------- JSON ----------------
;;; Terms: object = (obj . ((key . value) ...)), array = (arr . list),
;;; string = string, number = number, true/false = #t/#f, null = 'null.
(define (json-parse s)
  (let ((pos 0) (n (string-length s)))
    (define (peek) (string-ref s pos))
    (define (next!) (set! pos (+ pos 1)))
    (define (skip-ws)
      (while (and (< pos n) (memv (string-ref s pos) '(#\space #\tab #\newline #\return)))
        (next!)))
    (define (expect ch)
      (unless (char=? (string-ref s pos) ch) (error "json: expected" ch))
      (next!))
    (define (value)
      (skip-ws)
      (case (peek)
        ((#\{) (parse-obj))
        ((#\[) (parse-arr))
        ((#\") (parse-str))
        ((#\t) (literal "true") #t)
        ((#\f) (literal "false") #f)
        ((#\n) (literal "null") 'null)
        (else (parse-num))))
    (define (literal txt)
      (for-each (lambda (ch) (expect ch)) (string->list txt)))
    (define (parse-obj)
      (expect #\{) (skip-ws)
      (if (char=? (peek) #\})
          (begin (next!) (cons 'obj '()))
          (let loop ((acc '()))
            (skip-ws)
            (let ((k (parse-str)))
              (skip-ws) (expect #\:)
              (let ((v (value)))
                (skip-ws)
                (case (string-ref s pos)
                  ((#\}) (next!) (cons 'obj (reverse (cons (cons k v) acc))))
                  ((#\,) (next!) (loop (cons (cons k v) acc)))
                  (else (error "json: expected , or }"))))))))
    (define (parse-arr)
      (expect #\[) (skip-ws)
      (if (char=? (peek) #\])
          (begin (next!) (cons 'arr '()))
          (let loop ((acc '()))
            (let ((v (value)))
              (skip-ws)
              (case (string-ref s pos)
                ((#\]) (next!) (cons 'arr (reverse (cons v acc))))
                ((#\,) (next!) (loop (cons v acc)))
                (else (error "json: expected , or ]")))))))
    (define (parse-str)
      (expect #\")
      (let loop ((acc '()))
        (let ((ch (string-ref s pos)))
          (next!)
          (case ch
            ((#\") (list->string (reverse acc)))
            ((#\\)
             (let ((e (string-ref s pos)))
               (next!)
               (case e
                 ((#\n) (loop (cons #\newline acc)))
                 ((#\r) (loop (cons #\return acc)))
                 ((#\t) (loop (cons #\tab acc)))
                 ((#\b) (loop (cons #\bs acc)))
                 ((#\f) (loop (cons #\np acc)))
                 ((#\u)
                  (let ((cp (string->number (substring s pos (+ pos 4)) 16)))
                    (set! pos (+ pos 4))
                    (cond
                      ((and (>= cp #xD800) (<= cp #xDBFF)
                            (< (+ pos 5) n)
                            (char=? (string-ref s pos) #\\)
                            (char=? (string-ref s (+ pos 1)) #\u))
                       (let ((lo (string->number (substring s (+ pos 2) (+ pos 6)) 16)))
                         (if (and (>= lo #xDC00) (<= lo #xDFFF))
                             (begin (set! pos (+ pos 6))
                                    (loop (cons (integer->char
                                                 (+ #x10000
                                                    (* (- cp #xD800) 1024)
                                                    (- lo #xDC00)))
                                                acc)))
                             (loop (cons (integer->char cp) acc)))))
                      (else (loop (cons (integer->char cp) acc))))))
                 (else (loop (cons e acc))))))
            (else (loop (cons ch acc)))))))
    (define (parse-num)
      (let ((start pos))
        (while (and (< pos n)
                    (memv (string-ref s pos)
                          '(#\- #\+ #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9
                            #\. #\e #\E)))
          (next!))
        (let ((txt (substring s start pos)))
          (if (or (string-index txt #\.) (string-index txt #\e) (string-index txt #\E))
              (string->number txt)
              (string->number txt)))))
    (let ((v (value)))
      (skip-ws)
      v)))

(define (json-escape s)
  (let ((out (open-output-string)))
    (put-char out #\")
    (string-for-each
     (lambda (ch)
       (let ((cp (char->integer ch)))
         (cond
           ((char=? ch #\") (put-string out "\\\""))
           ((char=? ch #\\) (put-string out "\\\\"))
           ((char=? ch #\newline) (put-string out "\\n"))
           ((char=? ch #\return) (put-string out "\\r"))
           ((char=? ch #\tab) (put-string out "\\t"))
           ((char=? ch #\bs) (put-string out "\\b"))
           ((char=? ch #\np) (put-string out "\\f"))
           ((or (< cp #x20) (> cp #x7E))
            (if (> cp #xFFFF)
                (let ((v (- cp #x10000)))
                  (put-string out (string-append
                                   "\\u" (hex4 (+ #xD800 (quotient v 1024)))
                                   "\\u" (hex4 (+ #xDC00 (remainder v 1024))))))
                (put-string out (string-append "\\u" (hex4 cp)))))
           (else (put-char out ch)))))
     s)
    (put-char out #\")
    (get-output-string out)))

(define (hex4 n)
  (let ((h (number->string n 16)))
    (string-append (make-string (- 4 (string-length h)) #\0) h)))

(define (json-write v)
  (cond
    ((and (pair? v) (eq? (car v) 'obj))
     (let ((keys (sort (map car (cdr v)) string<?)))
       (string-append "{"
                      (string-join
                       (map (lambda (k)
                              (string-append (json-escape k) ":"
                                             (json-write (cdr (assoc k (cdr v))))))
                            keys)
                       ",")
                      "}")))
    ((and (pair? v) (eq? (car v) 'arr))
     (string-append "[" (string-join (map json-write (cdr v)) ",") "]"))
    ((string? v) (json-escape v))
    ((eq? v #t) "true")
    ((eq? v #f) "false")
    ((eq? v 'null) "null")
    ((integer? v) (number->string v))
    ((number? v) (number->string v))
    (else (error "json-write: bad term" v))))

(define (canon v) (utf8->bv (json-write v)))

(define (jget obj key) (cdr (assoc key (cdr obj))))
(define (jget-or obj key default)
  (let ((hit (assoc key (cdr obj)))) (if hit (cdr hit) default)))
(define (jobj pairs) (cons 'obj pairs))
(define (jarr items) (cons 'arr items))

;;; ---------------- gpg ----------------
(define (gnupg-home)
  (let ((home (or (getenv "TELEPHONE_GNUPGHOME")
                  (string-append (getenv "HOME") "/telephone-" %impl "/gnupg"))))
    (unless (file-exists? home) (mkdir home))
    (chmod home #o700)
    home))

(define (run-gpg home args input-bv)
  (let ((fi (tmpfile "gpgin")) (fo (tmpfile "gpgout")) (fe (tmpfile "gpgerr")))
    (call-with-output-file fi (lambda (p) (put-bytevector p input-bv)) #:binary #t)
    (setenv "GNUPGHOME" home)
    (let ((status (system (string-append
                           "gpg --batch --yes "
                           (string-join (map shell-quote args) " ")
                           " < " fi " > " fo " 2> " fe))))
      (unless (zero? (status:exit-val status))
        (let ((err (call-with-input-file fe (lambda (p) (read-string p)))))
          (delete-file fi) (delete-file fo) (delete-file fe)
          (error "gpg failed" err)))
      (let ((out (call-with-input-file fo
                   (lambda (p) (get-bytevector-all p)) #:binary #t)))
        (delete-file fi) (delete-file fo) (delete-file fe)
        out))))

(define (shell-quote s)
  (string-append "'" (string-map (lambda (ch) (if (char=? ch #\') #\x27 ch)) s) "'"))

(define (keygen)
  (let* ((home (gnupg-home))
         (uid (string-append "telephone-" %impl))
         (keys (bv->latin1
                (catch #t
                  (lambda () (run-gpg home '("--list-keys" "--with-colons")
                                      (make-bytevector 0)))
                  (lambda args (make-bytevector 0))))))
    (unless (string-contains keys "pub")
      (run-gpg home (list "--pinentry-mode" "loopback" "--passphrase" ""
                          "--quick-generate-key" uid "ed25519" "sign" "never")
               (make-bytevector 0)))
    (let ((pub (run-gpg home (list "--armor" "--export" uid) (make-bytevector 0))))
      (jobj (list (cons "impl" %impl) (cons "pubkey" (bv->latin1 pub)))))))

(define (attest descriptor)
  (let* ((home (gnupg-home))
         (uid (string-append "telephone-" %impl))
         (sig (run-gpg home (list "--pinentry-mode" "loopback" "--passphrase" ""
                                  "--detach-sign" "--armor" "-u" uid)
                       (canon descriptor))))
    ;; the local adapter translates armored -> base64-of-armored
    (jobj (list (cons "signature" (bv->latin1 sig))))))

(define (verify-signature pubkeys-text data-bv sig-b64)
  (catch #t
    (lambda ()
      (let* ((dir (tmpfile "verify"))
             (home (string-append dir "/gnupg"))
             (sigf (string-append dir "/sig.asc"))
             (dataf (string-append dir "/data"))
             (keysf (string-append dir "/keys")))
        (mkdir dir) (mkdir home) (chmod home #o700)
        (call-with-output-file sigf (lambda (p) (put-bytevector p (unb64 sig-b64))) #:binary #t)
        (call-with-output-file dataf (lambda (p) (put-bytevector p data-bv)) #:binary #t)
        (call-with-output-file keysf (lambda (p) (put-bytevector p (utf8->bv pubkeys-text))) #:binary #t)
        (setenv "GNUPGHOME" home)
        (let ((ok (and (zero? (status:exit-val
                               (system (string-append "gpg --batch --yes --import < " keysf
                                                      " 2>/dev/null"))))
                       (zero? (status:exit-val
                               (system (string-append "gpg --batch --yes --verify "
                                                      sigf " " dataf " 2>/dev/null")))))))
          (system (string-append "rm -rf " dir))
          ok)))
    (lambda args #f)))

;;; ---------------- game ----------------
(define %cache (make-parameter #f))  ; exploded hash table or #f

(define (state-of req)
  (unb64 (or (jget-or req "state" #f) (jget req "state_b64"))))

(define (do-echo ping)
  (jobj (list (cons "impl" %impl)
              (cons "echo" (sha256hex (canon (jobj (list (cons "impl" %impl)
                                                         (cons "ping" ping)))))))))

(define (do-elect position candidates turn)
  (let* ((names (cdr candidates))
         (pool0 (filter (lambda (x) (not (equal? x %impl))) names))
         (pool (if (null? pool0) names pool0))
         (seed (sha256hex (latin1->bv
                           (string-append %impl "-elect:" position ":"
                                          (number->string turn) ":"
                                          (string-join names ",")))))
         (idx (remainder (string->number (substring seed 0 8) 16) (length pool))))
    (jobj (list (cons "elect" (list-ref pool idx))))))

(define (do-choose data position turn)
  (let* ((m (explode data))
         (pos (let loop ((p (coord-parse position)))
                (if (hash-ref m (coord-string p) #f)
                    (loop (append (take p 8) (list (+ (list-ref p 8) 1))))
                    p))))
    (jobj (list (cons "op" "insert")
                (cons "coordinate" (coord-string pos))
                (cons "text" (string-append %impl " was here, turn "
                                            (number->string turn)))))))

(define (do-apply data step)
  (let* ((coord (coord-parse (jget step "coordinate")))
         (m (explode data)))
    (when (hash-ref m (coord-string coord) #f)
      (error "coordinate already occupied"))
    (hash-set! m (coord-string coord)
               (cons coord (latin1->bv (jget step "text"))))
    (let ((result (implode m)))
      (jobj (list (cons "state_b64" (bv->latin1 (b64 result)))
                  (cons "state_sha256" (sha256hex result)))))))

(define (do-init data)
  (%cache (explode data))
  (jobj (list (cons "impl" %impl) (cons "verdict" "pass"))))

(define (vfail detail)
  (jobj (list (cons "impl" %impl) (cons "verdict" "fail") (cons "detail" detail))))

(define (table-ref-coord table coord)
  (let ((hit (hash-ref table (coord-string coord) #f)))
    (and hit (cdr hit))))

(define (do-validate data step event-coord-s index-line)
  (let* ((new-map (explode data))
         (coord (coord-parse (jget step "coordinate")))
         (ev (coord-parse event-coord-s))
         (old (%cache))
         (placed (table-ref-coord new-map coord)))
    (cond
      ((or (not placed) (not (equal? (bv->latin1 placed) (jget step "text"))))
       (vfail "placed scroll missing or altered"))
      ((let loop ((entries (hash-map->list (lambda (k v) v) old)))
         (cond ((null? entries) #f)
               ((equal? (car (car entries)) %index-coord) (loop (cdr entries)))
               ((let ((nv (table-ref-coord new-map (car (car entries)))))
                  (or (not nv) (not (bytevector=? nv (cdr (car entries))))))
                (string-append "prior scroll overwritten at "
                               (coord-string (car (car entries)))))
               (else (loop (cdr entries)))))
       => (lambda (d) (vfail d)))
      ((let loop ((entries (hash-map->list (lambda (k v) v) new-map)))
         (cond ((null? entries) #f)
               ((or (hash-ref old (coord-string (car (car entries))) #f)
                    (equal? (car (car entries)) coord)
                    (equal? (car (car entries)) ev))
                (loop (cdr entries)))
               (else (string-append "unexpected new scroll at "
                                    (coord-string (car (car entries)))))))
       => (lambda (d) (vfail d)))
      (else
       (let ((idx (bv->latin1 (or (table-ref-coord new-map %index-coord)
                                  (make-bytevector 0)))))
         (if (string-suffix? (string-trim-right index-line #\newline)
                             (string-trim-right idx #\newline))
             (begin (%cache new-map)
                    (jobj (list (cons "impl" %impl) (cons "verdict" "pass"))))
             (vfail "index does not record the placement")))))))

(define (vfail-n n msg)
  (jobj (list (cons "impl" %impl) (cons "verdict" "fail")
              (cons "placements_checked" n)
              (cons "first_failure" (jobj (list (cons "detail" msg)))))))

(define (do-verify data)
  (let* ((m (explode data))
         (keys-text (bv->utf8 (or (table-ref-coord m %keys-coord) (make-bytevector 0))))
         (kh (string-trim (bv->latin1 (or (table-ref-coord m %kh-coord)
                                          (make-bytevector 0))))))
    (if (not (equal? (sha256hex (utf8->bv keys-text)) kh))
        (vfail-n 0 "keys-hash scroll does not match keys")
        (verify-events m keys-text))))

(define (verify-events m keys-text)
  (let* ((events (make-hash-table))
         (_ (hash-for-each
             (lambda (k v)
               (when (equal? (take (car v) 8) %evprefix)
                 (hash-set! events (list-ref (car v) 8)
                            (json-parse (bv->utf8 (cdr v))))))
             m))
         (seqs (sort (hash-map->list (lambda (k v) k) events) <)))
    (let loop ((seqs seqs) (expect 1) (prev 'null) (placements (make-hash-table)))
      (cond
        ((null? seqs) (verify-index m placements))
        ((not (= (car seqs) expect))
         (vfail-n (table-count placements)
                  (string-append "event seq gap at " (number->string (car seqs)))))
        (else
         (let* ((ev (hash-ref events (car seqs)))
                (ev-prev (jget-or ev "prev" 'null))
                (body (jget ev "body")))
           (cond
             ((not (equal? ev-prev prev))
              (vfail-n (table-count placements)
                       (string-append "event chain broken at seq "
                                      (number->string (car seqs)))))
             ((equal? (jget-or body "type" 'null) "placement")
              (let ((res (check-placement body m keys-text placements (car seqs))))
                (if (string? res)
                    (vfail-n (table-count placements) res)
                    (loop (cdr seqs) (+ expect 1)
                          (sha256hex (canon body)) placements))))
             (else
              (loop (cdr seqs) (+ expect 1) (sha256hex (canon body)) placements)))))))))

(define (check-placement body m keys-text placements s)
  (let ((coord (coord-parse (jget body "coord"))))
    (cond
      ((hash-ref placements (coord-string coord) #f)
       (string-append "coordinate reused at seq " (number->string s)))
      (else
       (let ((t (table-ref-coord m coord)))
         (cond
           ((or (not t) (not (equal? (sha256hex t) (jget body "text_sha256"))))
            (string-append "placement scroll hash mismatch seq " (number->string s)))
           (else
            (let ((desc (jobj (list (cons "turn" (jget body "turn"))
                                    (cons "coordinate" (jget body "coord"))
                                    (cons "scroll_sha256" (jget body "text_sha256"))
                                    (cons "file_sha256" (jget body "file_sha256"))))))
              (if (verify-signature keys-text (canon desc) (jget body "att"))
                  (begin (hash-set! placements (coord-string coord) body) #t)
                  (string-append "attestation fails at seq " (number->string s)))))))))))

(define (verify-index m placements)
  (let* ((n (table-count placements))
         (idx-text (bv->latin1 (or (table-ref-coord m %index-coord)
                                   (make-bytevector 0))))
         (lines (filter (lambda (ln) (and (not (string-null? ln))
                                          (not (string-prefix? "#" ln))))
                        (string-split idx-text #\newline))))
    (cond
      ((not (= (length lines) n)) (vfail-n n "index lines != placements"))
      (else
       (let loop ((lines lines))
         (cond
           ((null? lines)
            (jobj (list (cons "impl" %impl) (cons "verdict" "pass")
                        (cons "placements_checked" n)
                        (cons "first_failure" 'null))))
           (else
            (let* ((parts (string-split (car lines) #\space))
                   (body (hash-ref placements (list-ref parts 1) #f)))
              (if (or (not body) (not (equal? (jget body "text_sha256")
                                              (list-ref parts 2))))
                  (vfail-n n (string-append "index hash mismatch: "
                                            (substring (car lines) 0
                                                       (min 40 (string-length (car lines))))))
                  (loop (cdr lines)))))))))))

;;; ---------------- dispatch ----------------
(define (dispatch req)
  (let ((cmd (jget req "cmd")))
    (cond
      ((equal? cmd "id") (jobj (list (cons "impl" %impl))))
      ((equal? cmd "keygen") (keygen))
      ((equal? cmd "echo") (do-echo (jget req "ping")))
      ((equal? cmd "elect")
       (do-elect (jget req "position") (jget req "candidates") (jget req "turn")))
      ((equal? cmd "choose")
       (do-choose (state-of req) (jget req "position") (jget req "turn")))
      ((equal? cmd "apply") (do-apply (state-of req) (jget req "step")))
      ((equal? cmd "attest") (attest (jget req "descriptor")))
      ((equal? cmd "init") (do-init (state-of req)))
      ((equal? cmd "validate")
       (do-validate (state-of req) (jget req "step")
                    (jget req "event_coord") (jget req "index_line")))
      ((equal? cmd "verify") (do-verify (state-of req)))
      (else (error "unknown cmd" cmd)))))

(define (unframe line)
  (if (string-prefix? "GZ1:" line)
      (bv->latin1 (gunzip-bytes (unb64 (substring line 4))))
      line))

(define (handle-line line)
  (catch #t
    (lambda ()
      (let* ((req (json-parse (unframe line)))
             (out (json-write (dispatch req))))
        (if (> (string-length out) 8192)
            (string-append "GZ1:" (bv->latin1 (b64 (gzip-bytes (latin1->bv out)))))
            out)))
    (lambda (key . args)
      (json-write (jobj (list (cons "error"
                                    (string-append (symbol->string key) ": "
                                                   (format #f "~s" args)))))))))

(define (main args)
  (set-port-encoding! (current-input-port) "ISO-8859-1")
  (set-port-encoding! (current-output-port) "ISO-8859-1")
  (if (and (pair? args) (equal? (car args) "serve"))
      (let loop ()
        (let ((line (read-line (current-input-port))))
          (unless (eof-object? line)
            (unless (string-null? (string-trim line))
              (put-string (current-output-port) (handle-line (string-trim line)))
              (put-char (current-output-port) #\newline)
              (force-output (current-output-port)))
            (loop))))
      (let ((text (read-string (current-input-port))))
        (unless (string-null? (string-trim text))
          (put-string (current-output-port) (handle-line (string-trim text)))
          (put-char (current-output-port) #\newline)
          (force-output (current-output-port))))))

(main (cdr (command-line)))
