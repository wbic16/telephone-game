;;; libphext-scheme -- a Guile Scheme port of libphext (0.6.1 parity).
;;;
;;; Semantics normative from libphext-py: a phext is a byte buffer;
;;; nine dimension-break bytes walk a 9-component coordinate; scroll
;;; text is a maximal run of non-break bytes (newline 0x0A is ordinary
;;; text). Buffers are bytevectors; coordinates are lists of 9
;;; integers, ordered lexicographically; string form a.b.c/d.e.f/g.h.i.

(use-modules (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

(define %breaks '#(1 31 30 29 28 26 25 24 23))

(define (bv-append . bvs)
  (let ((out (make-bytevector (fold + 0 (map bytevector-length bvs)))))
    (let loop ((rest bvs) (pos 0))
      (if (null? rest)
          out
          (begin (bytevector-copy! (car rest) 0 out pos
                                   (bytevector-length (car rest)))
                 (loop (cdr rest) (+ pos (bytevector-length (car rest)))))))))

(define (bv-slice bv start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bv start out 0 (- end start))
    out))
(define %break-dim
  (let ((t (make-hash-table)))
    (for-each (lambda (d) (hashv-set! t (vector-ref %breaks d) d)) (iota 9))
    t))

(define (coord-root) (list 1 1 1 1 1 1 1 1 1))

(define (coord-parse s)
  (let ((groups (string-split (string-trim s) #\/)))
    (unless (= (length groups) 3) (error "coordinate must be a.b.c/d.e.f/g.h.i" s))
    (let ((nums (append-map (lambda (g) (map string->number (string-split g #\.))) groups)))
      (unless (= (length nums) 9) (error "coordinate needs 9 parts" s))
      (when (any (lambda (v) (or (not v) (< v 1))) nums)
        (error "components must be >= 1" s))
      nums)))

(define (coord-string c)
  (string-join (list (string-join (map number->string (take c 3)) ".")
                     (string-join (map number->string (take (drop c 3) 3)) ".")
                     (string-join (map number->string (drop c 6)) "."))
               "/"))

(define (coord-compare a b)
  (cond ((null? a) 0)
        ((< (car a) (car b)) -1)
        ((> (car a) (car b)) 1)
        (else (coord-compare (cdr a) (cdr b)))))

(define (coord-apply-break c d)
  (append (take c d)
          (list (+ (list-ref c d) 1))
          (make-list (- 8 d) 1)))

;;; phokenize: bytevector -> list of (coord . text-bytevector)
(define (phokenize buffer)
  (let loop ((i 0) (coord (coord-root)) (run-start 0) (acc '()))
    (if (< i (bytevector-length buffer))
        (let ((d (hashv-ref %break-dim (bytevector-u8-ref buffer i) #f)))
          (if d
              (loop (+ i 1)
                    (coord-apply-break coord d)
                    (+ i 1)
                    (if (> i run-start)
                        (cons (cons coord (bv-slice buffer run-start i)) acc)
                        acc))
              (loop (+ i 1) coord run-start acc)))
        (reverse
         (if (> (bytevector-length buffer) run-start)
             (cons (cons coord (bv-slice buffer run-start (bytevector-length buffer)))
                   acc)
             acc)))))

;;; a chunk buffer: reversed list of bytevectors, concatenated at end
(define (chunks->bytevector chunks)
  (if (null? chunks)
      (make-bytevector 0)
      (apply bv-append (reverse chunks))))

(define (emit-advance loc target chunks)
  (if (< (coord-compare loc target) 0)
      (let* ((dim (list-index (lambda (xy) (not (= (car xy) (cadr xy))))
                              (zip loc target)))
             (chunks (cons (make-bytevector
                            (- (list-ref target dim) (list-ref loc dim))
                            (vector-ref %breaks dim))
                           chunks))
             (chunks (fold (lambda (lower acc)
                             (let ((n (- (list-ref target lower) 1)))
                               (if (> n 0)
                                   (cons (make-bytevector n (vector-ref %breaks lower)) acc)
                                   acc)))
                           chunks
                           (iota (- 8 dim) (+ dim 1)))))
        (values target chunks))
      (values loc chunks)))

(define (dephokenize stack)
  (let loop ((items (sort stack (lambda (a b) (< (coord-compare (car a) (car b)) 0))))
             (loc (coord-root)) (chunks '()))
    (if (null? items)
        (chunks->bytevector chunks)
        (let ((ps (car items)))
          (if (= (bytevector-length (cdr ps)) 0)
              (loop (cdr items) loc chunks)
              (call-with-values (lambda () (emit-advance loc (car ps) chunks))
                (lambda (loc2 chunks2)
                  (loop (cdr items) loc2 (cons (cdr ps) chunks2)))))))))

(define (dephokenize-in-order stack)
  (let loop ((items stack) (loc (coord-root)) (chunks '()))
    (if (null? items)
        (chunks->bytevector chunks)
        (let ((ps (car items)))
          (call-with-values (lambda () (emit-advance loc (car ps) chunks))
            (lambda (loc2 chunks2)
              (loop (cdr items) loc2 (cons (cdr ps) chunks2))))))))

(define (normalize buffer) (dephokenize (phokenize buffer)))

(define (fetch buffer coord)
  (let ((hit (assoc coord (phokenize buffer))))
    (if hit (cdr hit) (make-bytevector 0))))

(define (%update buffer coord scroll overwrite?)
  (let loop ((items (phokenize buffer)) (acc '()) (appended #f))
    (if (null? items)
        (dephokenize-in-order
         (reverse (if appended acc (cons (cons coord scroll) acc))))
        (let* ((ps (car items))
               (cmp (coord-compare (car ps) coord)))
          (cond
            ((and (> cmp 0) (not appended))
             (loop (cdr items) (cons ps (cons (cons coord scroll) acc)) #t))
            ((and (= cmp 0) (not appended))
             (loop (cdr items)
                   (cons (cons coord
                               (if overwrite?
                                   scroll
                                   (bv-append (cdr ps) scroll)))
                         acc)
                   #t))
            (else (loop (cdr items) (cons ps acc) appended)))))))

;;; insert: existing text is prepended to the inserted text.
(define (insert buffer coord scroll) (%update buffer coord scroll #f))
(define (replace buffer coord scroll) (%update buffer coord scroll #t))

;;; remove: replace with "" then normalize -- coordinate-preserving:
;;; the removed coordinate reads "" and neighbours do not shift.
(define (remove buffer coord) (normalize (%update buffer coord (make-bytevector 0) #t)))

;;; explode: hash table coord-string -> (coord . text)
(define (explode buffer)
  (let ((t (make-hash-table)))
    (for-each (lambda (ps) (hash-set! t (coord-string (car ps)) ps))
              (phokenize buffer))
    t))

(define (implode table)
  (dephokenize (hash-map->list (lambda (k v) v) table)))

;;; ------------------------------------------------------------------
;;; DynamicPhext: capacity-managed dynamic array scroll store.
;;; Start at capacity 1, double when full on append, shrink only at
;;; quarter load (never half -- that thrashes). Represented as a
;;; vector: #(data-vector n capacity resize-count elements-copied
;;; shrink-divisor); operations are functional (return a new store),
;;; in the Scheme idiom.
(define (dynamic-new buffer shrink-divisor)
  (when (< shrink-divisor 2) (error "shrink_divisor must be >= 2"))
  (let ((dp (vector (make-vector 1 #f) 0 1 0 0 shrink-divisor)))
    (if (= (bytevector-length buffer) 0)
        dp
        (dynamic-load dp buffer))))

(define (dynamic-length dp) (vector-ref dp 1))
(define (dynamic-capacity dp) (vector-ref dp 2))
(define (dynamic-resize-count dp) (vector-ref dp 3))
(define (dynamic-elements-copied dp) (vector-ref dp 4))

(define (dynamic--copy dp data n capacity rc ec)
  (vector data n capacity rc ec (vector-ref dp 5)))

(define (dynamic--resize dp new-capacity)
  (let ((nd (make-vector new-capacity #f))
        (data (vector-ref dp 0))
        (n (vector-ref dp 1)))
    (do ((i 0 (+ i 1))) ((= i n))
      (vector-set! nd i (vector-ref data i)))
    (dynamic--copy dp nd n new-capacity
                   (+ (vector-ref dp 3) 1)
                   (+ (vector-ref dp 4) n))))

(define (dynamic--grow dp)
  (if (= (vector-ref dp 1) (vector-ref dp 2))
      (dynamic--resize dp (* 2 (vector-ref dp 2)))
      dp))

(define (dynamic--shrink dp)
  (if (and (> (vector-ref dp 2) 1)
           (<= (vector-ref dp 1) (quotient (vector-ref dp 2) (vector-ref dp 5))))
      (dynamic--resize dp (max 1 (quotient (vector-ref dp 2) 2)))
      dp))

(define (dynamic--push dp ps)
  (let ((dp (dynamic--grow dp)))
    (vector-set! (vector-ref dp 0) (vector-ref dp 1) ps)
    (dynamic--copy dp (vector-ref dp 0) (+ (vector-ref dp 1) 1)
                   (vector-ref dp 2) (vector-ref dp 3) (vector-ref dp 4))))

(define (dynamic-load dp buffer)
  (let ((fresh (vector (make-vector 1 #f) 0 1 0 0 (vector-ref dp 5))))
    (fold (lambda (ps acc) (dynamic--push acc ps)) fresh (phokenize buffer))))

(define (dynamic-scrolls dp)
  (let ((data (vector-ref dp 0)) (n (vector-ref dp 1)))
    (map (lambda (i) (vector-ref data i)) (iota n))))

(define (dynamic-serialize dp) (dephokenize (dynamic-scrolls dp)))

(define (dynamic--find dp coord)
  (let loop ((lo 0) (hi (vector-ref dp 1)))
    (if (>= lo hi)
        (values lo #f)
        (let* ((mid (quotient (+ lo hi) 2))
               (cmp (coord-compare (car (vector-ref (vector-ref dp 0) mid)) coord)))
          (cond ((< cmp 0) (loop (+ mid 1) hi))
                ((> cmp 0) (loop lo mid))
                (else (values mid #t)))))))

(define (dynamic-fetch dp coord)
  (call-with-values (lambda () (dynamic--find dp coord))
    (lambda (idx found)
      (if found (cdr (vector-ref (vector-ref dp 0) idx)) (make-bytevector 0)))))

(define (dynamic-contains? dp coord)
  (call-with-values (lambda () (dynamic--find dp coord))
    (lambda (idx found) found)))

(define (dynamic-append dp coord text)
  (let ((n (vector-ref dp 1)))
    (when (and (> n 0)
               (<= (coord-compare coord (car (vector-ref (vector-ref dp 0) (- n 1)))) 0))
      (error "append requires a coordinate past the current tail")))
  (if (= (bytevector-length text) 0)
      dp
      (dynamic--push dp (cons coord text))))

(define (dynamic--remove-at dp idx)
  (let ((data (vector-ref dp 0)) (n (vector-ref dp 1)))
    (do ((i idx (+ i 1))) ((= i (- n 1)))
      (vector-set! data i (vector-ref data (+ i 1))))
    (vector-set! data (- n 1) #f)
    (dynamic--shrink
     (dynamic--copy dp data (- n 1) (vector-ref dp 2)
                    (vector-ref dp 3) (vector-ref dp 4)))))

(define (dynamic-update dp coord text overwrite?)
  (call-with-values (lambda () (dynamic--find dp coord))
    (lambda (idx found)
      (cond
        ((and found (= (bytevector-length text) 0))
         (if overwrite? (dynamic--remove-at dp idx) dp))
        (found
         (let ((old (cdr (vector-ref (vector-ref dp 0) idx))))
           (vector-set! (vector-ref dp 0) idx
                        (cons coord (if overwrite? text
                                        (bv-append old text))))
           dp))
        ((= (bytevector-length text) 0) dp)
        (else
         (let ((dp (dynamic--grow dp)))
           (let ((data (vector-ref dp 0)) (n (vector-ref dp 1)))
             (do ((i n (- i 1))) ((= i idx))
               (vector-set! data i (vector-ref data (- i 1))))
             (vector-set! data idx (cons coord text))
             (dynamic--copy dp data (+ n 1) (vector-ref dp 2)
                            (vector-ref dp 3) (vector-ref dp 4)))))))))

(define (dynamic-insert dp coord text) (dynamic-update dp coord text #f))
(define (dynamic-replace dp coord text) (dynamic-update dp coord text #t))
(define (dynamic-remove dp coord)
  (call-with-values (lambda () (dynamic--find dp coord))
    (lambda (idx found) (if found (dynamic--remove-at dp idx) dp))))

;;; ------------------------------------------------------------------
;;; BranchingMap: nested hash tables, one lookup per dimension, down
;;; to leaves holding scroll text. Represented as
;;; #(depth root count); functional updates.
(define (branching-new depth)
  (when (< depth 1) (error "depth must be >= 1"))
  (vector depth (make-hash-table) 0))

(define (branching-length bm) (vector-ref bm 2))

(define (table-count t) (hash-fold (lambda (k v n) (+ n 1)) 0 t))

(define (branching-fetch bm key)
  (let loop ((node (vector-ref bm 1)) (comps key) (level (vector-ref bm 0)))
    (let ((child (hash-ref node (car comps) #f)))
      (cond ((not child) #f)
            ((= level 1) child)
            (else (loop child (cdr comps) (- level 1)))))))

(define (branching-contains? bm key) (and (branching-fetch bm key) #t))

;;; returns (values new-bm created?)
(define (branching-put bm key value)
  (define (rec node comps level)
    (if (= level 1)
        (let ((created (not (hash-ref node (car comps) #f))))
          (hash-set! node (car comps) value)
          (values node created))
        (let ((child (or (hash-ref node (car comps) #f) (make-hash-table))))
          (call-with-values (lambda () (rec child (cdr comps) (- level 1)))
            (lambda (new-child created)
              (hash-set! node (car comps) new-child)
              (values node created))))))
  (call-with-values (lambda () (rec (vector-ref bm 1) key (vector-ref bm 0)))
    (lambda (root created)
      (values (vector (vector-ref bm 0) root
                      (+ (vector-ref bm 2) (if created 1 0)))
              created))))

;;; returns (values new-bm removed?)
(define (branching-remove bm key)
  (define (rec node comps level)
    (cond
      ((= level 1)
       (if (hash-ref node (car comps) #f)
           (begin (hash-remove! node (car comps)) (values node #t))
           (values node #f)))
      (else
       (let ((child (hash-ref node (car comps) #f)))
         (if (not child)
             (values node #f)
             (call-with-values (lambda () (rec child (cdr comps) (- level 1)))
               (lambda (new-child removed)
                 (when (and removed (= (table-count new-child) 0))
                   (hash-remove! node (car comps)))
                 (when (and removed (not (= (table-count new-child) 0)))
                   (hash-set! node (car comps) new-child))
                 (values node removed))))))))
  (call-with-values (lambda () (rec (vector-ref bm 1) key (vector-ref bm 0)))
    (lambda (root removed)
      (values (vector (vector-ref bm 0) root
                      (- (vector-ref bm 2) (if removed 1 0)))
              removed))))

(define (branching-items bm)
  (define (rec node prefix level acc)
    (if (= level 1)
        (hash-fold (lambda (comp v a) (cons (cons (append prefix (list comp)) v) a))
                   acc node)
        (hash-fold (lambda (comp child a) (rec child (append prefix (list comp))
                                               (- level 1) a))
                   acc node)))
  (sort (rec (vector-ref bm 1) '() (vector-ref bm 0) '())
        (lambda (a b) (< (coord-compare (car a) (car b)) 0))))

;;; ------------------------------------------------------------------
;;; TransitivePhext: scroll store over a BranchingMap at depth 9.
;;; Represented as a one-element vector holding the BranchingMap.
(define (transitive-new buffer)
  (let ((tp (vector (branching-new 9))))
    (if (= (bytevector-length buffer) 0)
        tp
        (transitive-load tp buffer))))

(define (transitive-load tp buffer)
  (let ((fresh (vector (branching-new 9))))
    (for-each (lambda (ps)
                (call-with-values (lambda () (branching-put (vector-ref fresh 0)
                                                            (car ps) (cdr ps)))
                  (lambda (bm created) (vector-set! fresh 0 bm))))
              (phokenize buffer))
    fresh))

(define (transitive-depth tp) (vector-ref (vector-ref tp 0) 0))
(define (transitive-length tp) (branching-length (vector-ref tp 0)))
(define (transitive-scrolls tp) (branching-items (vector-ref tp 0)))
(define (transitive-serialize tp) (dephokenize (transitive-scrolls tp)))
(define (transitive-fetch tp coord)
  (or (branching-fetch (vector-ref tp 0) coord) (make-bytevector 0)))
(define (transitive-contains? tp coord) (branching-contains? (vector-ref tp 0) coord))

(define (transitive-update tp coord text overwrite?)
  (cond
    ((= (bytevector-length text) 0)
     (if overwrite? (transitive-remove tp coord) tp))
    (overwrite?
     (call-with-values (lambda () (branching-put (vector-ref tp 0) coord text))
       (lambda (bm created) (vector bm))))
    (else
     (call-with-values
         (lambda () (branching-put (vector-ref tp 0) coord
                                   (bv-append (transitive-fetch tp coord) text)))
       (lambda (bm created) (vector bm))))))

(define (transitive-insert tp coord text) (transitive-update tp coord text #f))
(define (transitive-replace tp coord text) (transitive-update tp coord text #t))
(define (transitive-append tp coord text) (transitive-insert tp coord text))
(define (transitive-remove tp coord)
  (call-with-values (lambda () (branching-remove (vector-ref tp 0) coord))
    (lambda (bm removed) (vector bm))))
