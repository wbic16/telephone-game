;;;; libphext-lisp — a Common Lisp port of libphext (0.6.1 parity).
;;;;
;;;; Semantics are normative from libphext-py: a phext is a byte buffer;
;;;; nine dimension-break bytes walk a 9-component coordinate; scroll
;;;; text is a maximal run of non-break bytes (newline 0x0A is ordinary
;;;; text). All buffers are (vector (unsigned-byte 8)); coordinates are
;;;; lists of 9 integers, ordered lexicographically. String form:
;;;; a.b.c/d.e.f/g.h.i

(defpackage :phext
  (:use :cl)
  (:export #:coord-parse #:coord-string #:coord< #:coord= #:coord-root
           #:phokenize #:dephokenize #:normalize #:fetch-scroll
           #:update-scroll #:insert-scroll #:replace-scroll
           #:remove-scroll #:explode #:implode
           #:dynamic-phext #:make-dynamic-phext #:dynamic-load
           #:dynamic-serialize #:dynamic-fetch #:dynamic-insert
           #:dynamic-replace #:dynamic-remove #:dynamic-append
           #:dynamic-length #:dynamic-capacity #:dynamic-resize-count
           #:dynamic-elements-copied
           #:transitive-phext #:make-transitive-phext #:transitive-load
           #:transitive-serialize #:transitive-fetch #:transitive-insert
           #:transitive-replace #:transitive-remove #:transitive-append
           #:transitive-length #:transitive-depth
           #:branching-map #:make-branching-map #:branching-fetch
           #:branching-put #:branching-remove #:branching-items
           #:branching-length
           #:bytes #:string-to-bytes #:bytes-to-string))

(in-package :phext)

;;; Dimension breaks in dimension order (library .. scroll).
(defparameter *dimension-breaks* #(1 31 30 29 28 26 25 24 23))

(defun break-dim (b)
  "Dimension index of break byte B, or NIL for ordinary text bytes."
  (position b *dimension-breaks*))

(defun bytes (&rest bs)
  (make-array (length bs) :element-type '(unsigned-byte 8)
                          :initial-contents bs))

(defun string-to-bytes (s)
  "Bytes of S under the latin-1 convention (codepoint == byte)."
  (map '(vector (unsigned-byte 8)) #'char-code s))

(defun bytes-to-string (v)
  (map 'string #'code-char v))

;;; ------------------------------------------------------------------
;;; Coordinates: lists of 9 integers, each >= 1.

(defun coord-root () (list 1 1 1 1 1 1 1 1 1))

(defun coord-parse (s)
  (let ((groups (split-string s #\/)))
    (unless (= (length groups) 3)
      (error "coordinate must be a.b.c/d.e.f/g.h.i: ~A" s))
    (let ((nums (loop for g in groups append
                      (mapcar #'parse-integer (split-string g #\.)))))
      (unless (= (length nums) 9)
        (error "coordinate needs 9 parts: ~A" s))
      (dolist (n nums)
        (when (< n 1) (error "components must be >= 1: ~A" s)))
      nums)))

(defun split-string (s ch)
  (let ((out '()) (start 0))
    (loop for i from 0 below (length s)
          when (char= (char s i) ch)
            do (push (subseq s start i) out) (setf start (1+ i)))
    (push (subseq s start) out)
    (nreverse out)))

(defun coord-string (c)
  (format nil "~D.~D.~D/~D.~D.~D/~D.~D.~D"
          (nth 0 c) (nth 1 c) (nth 2 c) (nth 3 c) (nth 4 c)
          (nth 5 c) (nth 6 c) (nth 7 c) (nth 8 c)))

(defun coord< (a b)
  (loop for x in a for y in b
        when (/= x y) do (return-from coord< (< x y)))
  nil)

(defun coord= (a b) (equal a b))

(defun coord-apply-break (c d)
  "Break at dimension D (0-based): increment it, reset lowers to 1."
  (let ((out (copy-list c)))
    (incf (nth d out))
    (loop for lower from (1+ d) below 9 do (setf (nth lower out) 1))
    out))

;;; ------------------------------------------------------------------
;;; Core buffer API. A positioned scroll is a cons (coord . bytes).

(defun phokenize (buffer)
  "Ordered list of (coord . text) positioned scrolls in BUFFER."
  (let ((out '())
        (coord (coord-root))
        (run-start 0)
        (n (length buffer)))
    (loop for i from 0 below n
          for d = (break-dim (aref buffer i))
          when d do
            (when (> i run-start)
              (push (cons (copy-list coord)
                          (subseq buffer run-start i)) out))
            (setf coord (coord-apply-break coord d)
                  run-start (1+ i)))
    (when (> n run-start)
      (push (cons (copy-list coord) (subseq buffer run-start n)) out))
    (nreverse out)))

(defun %advance (loc target)
  "Break bytes moving LOC up to TARGET; mutates LOC (a list)."
  (let ((out '()))
    (when (coord< loc target)
      (let ((dim (loop for i from 0 below 9
                       when (/= (nth i loc) (nth i target)) do (return i))))
        (loop repeat (- (nth dim target) (nth dim loc))
              do (push (aref *dimension-breaks* dim) out))
        (setf (nth dim loc) (nth dim target))
        (loop for lower from (1+ dim) below 9 do (setf (nth lower loc) 1))
        (loop for lower from (1+ dim) below 9 do
          (loop repeat (1- (nth lower target))
                do (push (aref *dimension-breaks* lower) out))
          (setf (nth lower loc) (nth lower target)))))
    (coerce (nreverse out) '(vector (unsigned-byte 8)))))

(defun dephokenize (stack)
  "Canonical bytes: sorted coordinate order, empty scrolls skipped."
  (let ((sorted (sort (copy-list stack) #'coord< :key #'car))
        (loc (coord-root))
        (chunks '()))
    (dolist (ps sorted)
      (unless (zerop (length (cdr ps)))
        (push (%advance loc (car ps)) chunks)
        (push (cdr ps) chunks)))
    (apply #'concatenate '(vector (unsigned-byte 8)) (nreverse chunks))))

(defun normalize (buffer)
  (dephokenize (phokenize buffer)))

(defun fetch-scroll (buffer coord)
  "Text at COORD, or empty bytes for a gap coordinate."
  (dolist (ps (phokenize buffer) (bytes))
    (when (coord= (car ps) coord) (return (cdr ps)))))

(defun update-scroll (buffer coord scroll overwrite)
  (let ((items (phokenize buffer))
        (result '())
        (next (cons coord scroll))
        (appended nil))
    (dolist (ps items)
      (when (and (coord< coord (car ps)) (not appended))
        (push next result) (setf appended t))
      (cond ((and (coord= (car ps) coord) (not appended))
             (unless overwrite
               (setf (cdr next) (concatenate '(vector (unsigned-byte 8))
                                             (cdr ps) (cdr next))))
             (push next result)
             (setf appended t))
            (t (push ps result))))
    (unless appended (push next result))
    ;; dephokenize in placed order (phokenize order + insertion point),
    ;; exactly as libphext-py's update/dephokenize sequence.
    (let ((loc (coord-root)) (chunks '()))
      (dolist (ps (nreverse result))
        (push (%advance loc (car ps)) chunks)
        (push (cdr ps) chunks))
      (apply #'concatenate '(vector (unsigned-byte 8)) (nreverse chunks)))))

(defun insert-scroll (buffer coord scroll)
  "Existing text is prepended to the inserted text."
  (update-scroll buffer coord scroll nil))

(defun replace-scroll (buffer coord scroll)
  (update-scroll buffer coord scroll t))

(defun remove-scroll (buffer coord)
  "Replace with \"\" then normalize — coordinate-preserving: the
removed coordinate reads \"\" and neighbours do not shift."
  (normalize (update-scroll buffer coord (bytes) t)))

(defun explode (buffer)
  "Hash table (coord list -> text), :test EQUAL."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (ps (phokenize buffer) h)
      (setf (gethash (car ps) h) (cdr ps)))))

(defun implode (map)
  (let ((parts '()))
    (maphash (lambda (k v) (push (cons k v) parts)) map)
    (dephokenize parts)))

;;; ------------------------------------------------------------------
;;; DynamicPhext: capacity-managed dynamic array scroll store.
;;; Start at capacity 1, double when full, shrink only at quarter
;;; load (never half — that thrashes). Edit semantics are
;;; update-scroll's own; the array stays in coordinate order so
;;; dynamic-serialize is byte-identical to the string path.

(defclass dynamic-phext ()
  ((data :accessor dp-data)
   (capacity :accessor dp-capacity :initform 1)
   (n :accessor dp-n :initform 0)
   (shrink-divisor :accessor dp-shrink-divisor :initarg :shrink-divisor
                   :initform 4)
   (resize-count :accessor dynamic-resize-count :initform 0)
   (elements-copied :accessor dynamic-elements-copied :initform 0)))

(defun make-dynamic-phext (&optional buffer (shrink-divisor 4))
  (when (< shrink-divisor 2) (error "shrink_divisor must be >= 2"))
  (let ((d (make-instance 'dynamic-phext :shrink-divisor shrink-divisor)))
    (setf (dp-data d) (make-array 1))
    (when (and buffer (plusp (length buffer))) (dynamic-load d buffer))
    d))

(defun dp-resize (d new-capacity)
  (let ((nd (make-array new-capacity)))
    (loop for i from 0 below (dp-n d) do (setf (aref nd i) (aref (dp-data d) i)))
    (setf (dp-data d) nd
          (dp-capacity d) new-capacity)
    (incf (dynamic-resize-count d))
    (incf (dynamic-elements-copied d) (dp-n d))))

(defun dp-grow-if-full (d)
  (when (= (dp-n d) (dp-capacity d)) (dp-resize d (* 2 (dp-capacity d)))))

(defun dp-shrink-if-sparse (d)
  (when (and (> (dp-capacity d) 1)
             (<= (dp-n d) (floor (dp-capacity d) (dp-shrink-divisor d))))
    (dp-resize d (max 1 (floor (dp-capacity d) 2)))))

(defun dp-push (d ps)
  (dp-grow-if-full d)
  (setf (aref (dp-data d) (dp-n d)) ps)
  (incf (dp-n d)))

(defun dynamic-load (d buffer)
  (setf (dp-capacity d) 1
        (dp-data d) (make-array 1)
        (dp-n d) 0
        (dynamic-resize-count d) 0
        (dynamic-elements-copied d) 0)
  (dolist (ps (phokenize buffer)) (dp-push d ps)))

(defun dynamic-scrolls (d)
  (loop for i from 0 below (dp-n d) collect (aref (dp-data d) i)))

(defun dynamic-serialize (d) (dephokenize (dynamic-scrolls d)))
(defun dynamic-length (d) (dp-n d))
(defun dynamic-capacity (d) (dp-capacity d))

(defun dp-find (d coord)
  "Binary search: returns (index found-p)."
  (let ((lo 0) (hi (dp-n d)))
    (loop while (< lo hi) do
      (let ((mid (floor (+ lo hi) 2)))
        (cond ((coord< (car (aref (dp-data d) mid)) coord) (setf lo (1+ mid)))
              ((coord< coord (car (aref (dp-data d) mid))) (setf hi mid))
              (t (return-from dp-find (values mid t))))))
    (values lo nil)))

(defun dynamic-fetch (d coord)
  (multiple-value-bind (index found) (dp-find d coord)
    (if found (cdr (aref (dp-data d) index)) (bytes))))

(defun dynamic-contains (d coord)
  (nth-value 1 (dp-find d coord)))

(defun dynamic-append (d coord text)
  (when (and (plusp (dp-n d))
             (not (coord< (car (aref (dp-data d) (1- (dp-n d)))) coord)))
    (error "append requires a coordinate past the current tail"))
  (unless (zerop (length text)) (dp-push d (cons coord text))))

(defun dp-remove-at (d index)
  (loop for i from index below (1- (dp-n d))
        do (setf (aref (dp-data d) i) (aref (dp-data d) (1+ i))))
  (decf (dp-n d))
  (setf (aref (dp-data d) (dp-n d)) nil)
  (dp-shrink-if-sparse d))

(defun dynamic-update (d coord text overwrite)
  (multiple-value-bind (index found) (dp-find d coord)
    (cond (found
           (cond ((zerop (length text))
                  (when overwrite (dp-remove-at d index)))
                 (overwrite
                  (setf (aref (dp-data d) index) (cons coord text)))
                 (t (setf (aref (dp-data d) index)
                          (cons coord (concatenate '(vector (unsigned-byte 8))
                                                   (cdr (aref (dp-data d) index))
                                                   text))))))
          ((plusp (length text))
           (dp-grow-if-full d)
           (loop for i from (dp-n d) above index
                 do (setf (aref (dp-data d) i) (aref (dp-data d) (1- i))))
           (setf (aref (dp-data d) index) (cons coord text))
           (incf (dp-n d))))))

(defun dynamic-insert (d coord text) (dynamic-update d coord text nil))
(defun dynamic-replace (d coord text) (dynamic-update d coord text t))
(defun dynamic-remove (d coord)
  (multiple-value-bind (index found) (dp-find d coord)
    (when found (dp-remove-at d index))))

;;; ------------------------------------------------------------------
;;; TransitivePhext: branching hash-map scroll store — one hash map
;;; per coordinate dimension (9 layers), leaves holding scroll text.
;;; BranchingMap is dimension-generic: a map of depth D whose values
;;; are maps of depth D-1, recursively, down to leaves.

(defclass branching-map ()
  ((depth :accessor bm-depth :initarg :depth)
   (root :accessor bm-root :initform (make-hash-table :test 'eql))
   (count :accessor branching-length :initform 0)))

(defun make-branching-map (depth)
  (when (< depth 1) (error "depth must be >= 1"))
  (make-instance 'branching-map :depth depth))

(defun bm-fetch (node key level depth)
  (let ((child (gethash (nth level key) node)))
    (cond ((null child) nil)
          ((= level (1- depth)) child)
          (t (bm-fetch child key (1+ level) depth)))))

(defun branching-fetch (m key)
  (bm-fetch (bm-root m) key 0 (bm-depth m)))

(defun bm-put (node key level depth value)
  (let ((comp (nth level key)))
    (if (= level (1- depth))
        (let ((created (not (nth-value 1 (gethash comp node)))))
          (setf (gethash comp node) value)
          created)
        (let ((child (gethash comp node)))
          (unless child
            (setf child (make-hash-table :test 'eql)
                  (gethash comp node) child))
          (bm-put child key (1+ level) depth value)))))

(defun branching-put (m key value)
  (let ((created (bm-put (bm-root m) key 0 (bm-depth m) value)))
    (when created (incf (branching-length m)))
    created))

(defun bm-remove (node key level depth)
  (let ((comp (nth level key)))
    (if (= level (1- depth))
        (if (nth-value 1 (gethash comp node))
            (progn (remhash comp node) t)
            nil)
        (let ((child (gethash comp node)))
          (when child
            (let ((removed (bm-remove child key (1+ level) depth)))
              (when (and removed (zerop (hash-table-count child)))
                (remhash comp node))
              removed))))))

(defun branching-remove (m key)
  (let ((removed (bm-remove (bm-root m) key 0 (bm-depth m))))
    (when removed (decf (branching-length m)))
    removed))

(defun bm-items (node prefix depth level sink)
  (let ((keys '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k keys)) node)
    (dolist (comp (sort keys #'<))
      (let ((child (gethash comp node)))
        (if (= level (1- depth))
            (funcall sink (append prefix (list comp)) child)
            (bm-items child (append prefix (list comp)) depth (1+ level)
                      sink))))))

(defun branching-items (m sink)
  "Call SINK with (key text) in lexicographic (coordinate) order."
  (bm-items (bm-root m) '() (bm-depth m) 0 sink))

(defclass transitive-phext ()
  ((map :accessor tp-map)))

(defun make-transitive-phext (&optional buffer)
  (let ((tp (make-instance 'transitive-phext)))
    (setf (tp-map tp) (make-branching-map 9))
    (when (and buffer (plusp (length buffer))) (transitive-load tp buffer))
    tp))

(defun transitive-depth (tp) (bm-depth (tp-map tp)))
(defun transitive-length (tp) (branching-length (tp-map tp)))

(defun transitive-load (tp buffer)
  (setf (tp-map tp) (make-branching-map 9))
  (dolist (ps (phokenize buffer))
    (branching-put (tp-map tp) (car ps) (cdr ps))))

(defun transitive-scrolls (tp)
  (let ((out '()))
    (branching-items (tp-map tp)
                     (lambda (k v) (push (cons k v) out)))
    (nreverse out)))

(defun transitive-serialize (tp) (dephokenize (transitive-scrolls tp)))

(defun transitive-fetch (tp coord)
  (or (branching-fetch (tp-map tp) coord) (bytes)))

(defun transitive-contains (tp coord)
  (not (null (branching-fetch (tp-map tp) coord))))

(defun transitive-update (tp coord text overwrite)
  (cond ((zerop (length text))
         (when overwrite (branching-remove (tp-map tp) coord)))
        (overwrite (branching-put (tp-map tp) coord text))
        (t (let ((existing (branching-fetch (tp-map tp) coord)))
             (branching-put (tp-map tp) coord
                            (if existing
                                (concatenate '(vector (unsigned-byte 8))
                                             existing text)
                                text))))))

(defun transitive-insert (tp coord text) (transitive-update tp coord text nil))
(defun transitive-replace (tp coord text) (transitive-update tp coord text t))
(defun transitive-remove (tp coord) (branching-remove (tp-map tp) coord))
(defun transitive-append (tp coord text) (transitive-insert tp coord text))
