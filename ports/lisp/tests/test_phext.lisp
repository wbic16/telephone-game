;;;; Test suite for libphext-lisp — plain assertions, no framework.
;;;; Run: sbcl --script tests/test_phext.lisp [fixtures_dir]

(load (merge-pathnames "../src/phext.lisp" *load-truename*))

(defpackage :phext-test (:use :cl))
(in-package :phext-test)

(defvar *failures* 0)
(defvar *checks* 0)

(defun ok (cond name)
  (incf *checks*)
  (unless cond
    (incf *failures*)
    (format *error-output* "FAIL: ~A~%" name)))

(defun eq* (a b name) (ok (equalp a b) name))

(defun b (s) (phext:string-to-bytes s))
(defun c (s) (phext:coord-parse s))
(defun bb (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

;;; coordinate
(eq* (phext:coord-string (c "1.2.3/4.5.6/7.8.9")) "1.2.3/4.5.6/7.8.9" "coord format")
(ok (phext:coord< (c "1.1.1/1.1.1/1.1.1") (c "1.1.1/1.1.1/1.1.2")) "order scroll")
(ok (phext:coord< (c "1.1.1/1.1.1/1.1.9") (c "1.1.1/1.1.2/1.1.1")) "order section")
(ok (phext:coord< (c "1.9.9/9.9.9/9.9.9") (c "2.1.1/1.1.1/1.1.1")) "order library")
(eq* (c "1.1.1/1.1.1/1.1.1") (phext:coord-root) "root")
(ok (handler-case (progn (c "0.1.1/1.1.1/1.1.1") nil) (error () t)) "coord rejects 0")
(ok (handler-case (progn (c "1.1/1.1.1/1.1.1") nil) (error () t)) "coord rejects short")

;;; phokenize
(let ((sc (phext:phokenize (b "hello"))))
  (eq* (length sc) 1 "one scroll")
  (eq* (phext:coord-string (car (first sc))) "1.1.1/1.1.1/1.1.1" "first coord")
  (eq* (cdr (first sc)) (b "hello") "first text"))
(let ((sc (phext:phokenize
           (concatenate '(vector (unsigned-byte 8))
                        (b "a") (bb 23) (b "b") (bb 23 23)
                        (b (format nil "c~%line2"))))))
  (eq* (length sc) 3 "scroll breaks")
  (eq* (phext:coord-string (car (second sc))) "1.1.1/1.1.1/1.1.2" "second coord")
  (eq* (phext:coord-string (car (third sc))) "1.1.1/1.1.1/1.1.4" "gap coord advance")
  (eq* (cdr (third sc)) (b (format nil "c~%line2")) "newline is ordinary text"))
(let ((sc (phext:phokenize (concatenate '(vector (unsigned-byte 8)) (b "x") (bb 1) (b "y")))))
  (eq* (phext:coord-string (car (second sc))) "2.1.1/1.1.1/1.1.1" "library break resets"))
(let ((sc (phext:phokenize (concatenate '(vector (unsigned-byte 8)) (b "x") (bb 24) (b "y")))))
  (eq* (phext:coord-string (car (second sc))) "1.1.1/1.1.1/1.2.1" "section break"))
(eq* (length (phext:phokenize (b ""))) 0 "empty buffer")
(let ((sc (phext:phokenize (bb 97 0 255 98))))
  (eq* (length sc) 1 "binary text is one scroll")
  (eq* (length (cdr (first sc))) 4 "binary text preserved"))

;;; round trip
(let ((sample (concatenate '(vector (unsigned-byte 8))
                           (b "alpha") (bb 23) (b "beta") (bb 24)
                           (b "gamma") (bb 1) (b "delta"))))
  (eq* (phext:dephokenize (phext:phokenize sample)) sample "round trip sample"))
(let ((built (phext:dephokenize
              (list (cons (c "1.1.1/1.1.1/1.1.2") (b "two"))
                    (cons (c "1.1.1/1.1.1/1.1.1") (b "one"))))))
  (eq* built (concatenate '(vector (unsigned-byte 8)) (b "one") (bb 23) (b "two"))
      "dephokenize sorts canonically"))
(eq* (phext:normalize (phext:normalize (concatenate '(vector (unsigned-byte 8)) (bb 23 23) (b "lead"))))
    (phext:normalize (concatenate '(vector (unsigned-byte 8)) (bb 23 23) (b "lead")))
    "normalize idempotent")

;;; fetch incl. gaps
(let ((buf (concatenate '(vector (unsigned-byte 8))
                        (b "one") (bb 23) (b "two") (bb 23 23) (b "four"))))
  (eq* (phext:fetch-scroll buf (c "1.1.1/1.1.1/1.1.1")) (b "one") "fetch 1")
  (eq* (phext:fetch-scroll buf (c "1.1.1/1.1.1/1.1.4")) (b "four") "fetch 4")
  (eq* (phext:fetch-scroll buf (c "1.1.1/1.1.1/1.1.3")) (b "") "gap fetch is empty")
  (eq* (phext:fetch-scroll buf (c "9.9.9/9.9.9/9.9.9")) (b "") "far gap fetch is empty"))
(eq* (phext:fetch-scroll (b "") (c "1.1.1/1.1.1/1.1.1")) (b "") "fetch empty buffer")

;;; insert
(let ((out (phext:insert-scroll (b "base") (c "1.1.1/1.1.1/1.1.1") (b "+more"))))
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.1")) (b "base+more")
      "insert appends after existing"))
(let ((out (phext:insert-scroll (b "") (c "1.1.1/1.1.1/1.1.3") (b "new"))))
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.3")) (b "new") "insert creates at gap")
  (eq* out (concatenate '(vector (unsigned-byte 8)) (bb 23 23) (b "new"))
      "insert at gap emits breaks"))
(let ((out (phext:insert-scroll
            (concatenate '(vector (unsigned-byte 8)) (b "a") (bb 23) (b "c"))
            (c "1.1.1/1.1.1/1.1.2") (b "b"))))
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.2")) (b "cb")
      "insert merges existing + inserted"))

;;; replace / remove — remove is coordinate-preserving
(let ((out (phext:replace-scroll
            (concatenate '(vector (unsigned-byte 8)) (b "old") (bb 23) (b "keep"))
            (c "1.1.1/1.1.1/1.1.1") (b "new"))))
  (eq* out (concatenate '(vector (unsigned-byte 8)) (b "new") (bb 23) (b "keep"))
      "replace overwrites"))
(let ((out (phext:replace-scroll (b "a") (c "1.1.1/1.1.1/1.1.5") (b "deep"))))
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.5")) (b "deep") "replace creates"))
(let ((out (phext:remove-scroll
            (concatenate '(vector (unsigned-byte 8))
                         (b "a") (bb 23) (b "b") (bb 23) (b "c"))
            (c "1.1.1/1.1.1/1.1.2"))))
  (eq* out (concatenate '(vector (unsigned-byte 8)) (b "a") (bb 23 23) (b "c"))
      "remove leaves a gap (no renumbering)")
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.2")) (b "")
      "removed coordinate reads empty")
  (eq* (phext:fetch-scroll out (c "1.1.1/1.1.1/1.1.3")) (b "c")
      "neighbour keeps its coordinate"))
(eq* (length (phext:remove-scroll (b "only") (c "1.1.1/1.1.1/1.1.1"))) 0
    "remove sole scroll")
(eq* (phext:remove-scroll (b "a") (c "5.5.5/5.5.5/5.5.5")) (b "a")
    "remove gap is a no-op")

;;; explode / implode
(let ((map (phext:explode (concatenate '(vector (unsigned-byte 8))
                                       (b "x") (bb 23) (b "y")))))
  (eq* (hash-table-count map) 2 "explode count")
  (eq* (phext:implode map)
      (concatenate '(vector (unsigned-byte 8)) (b "x") (bb 23) (b "y"))
      "implode round trip"))

;;; Dynamic + Transitive equivalence with the string path
(let ((dyn (phext:make-dynamic-phext))
      (trn (phext:make-transitive-phext))
      (strbuf (b "")))
  (labels ((estep (op coord text)
             (let ((cc (c coord)) (tt (b text)))
               (cond ((string= op "insert")
                      (setf strbuf (phext:insert-scroll strbuf cc tt))
                      (phext:dynamic-insert dyn cc tt)
                      (phext:transitive-insert trn cc tt))
                     ((string= op "replace")
                      (setf strbuf (phext:replace-scroll strbuf cc tt))
                      (phext:dynamic-replace dyn cc tt)
                      (phext:transitive-replace trn cc tt))
                     ((string= op "remove")
                      (setf strbuf (phext:remove-scroll strbuf cc))
                      (phext:dynamic-remove dyn cc)
                      (phext:transitive-remove trn cc)))
               (eq* (phext:dynamic-serialize dyn) strbuf
                   (format nil "dynamic == string after ~A ~A" op coord))
               (eq* (phext:transitive-serialize trn) strbuf
                   (format nil "transitive == string after ~A ~A" op coord))
               (eq* (phext:dynamic-fetch dyn cc) (phext:fetch-scroll strbuf cc)
                   "dynamic fetch after op")
               (eq* (phext:transitive-fetch trn cc) (phext:fetch-scroll strbuf cc)
                   "transitive fetch after op"))))
    (estep "insert" "1.1.1/1.1.1/1.1.1" "alpha")
    (estep "insert" "1.1.1/1.1.1/1.1.3" "gamma")
    (estep "insert" "1.1.1/1.1.1/1.1.2" "beta")
    (estep "insert" "1.1.1/1.1.1/1.1.2" "+")
    (estep "replace" "2.1.1/1.1.1/1.1.1" "lib2")
    (estep "remove" "1.1.1/1.1.1/1.1.3" "")
    (eq* (phext:dynamic-fetch dyn (c "1.1.1/1.1.1/1.1.3")) (b "")
        "dynamic removed coord is gap")
    (eq* (phext:transitive-fetch trn (c "1.1.1/1.1.1/1.1.3")) (b "")
        "transitive removed coord is gap")
    (eq* (phext:dynamic-fetch dyn (c "2.1.1/1.1.1/1.1.1")) (b "lib2")
        "dynamic neighbour unmoved")
    (eq* (phext:transitive-fetch trn (c "2.1.1/1.1.1/1.1.1")) (b "lib2")
        "transitive neighbour unmoved")
    (estep "insert" "1.1.1/1.1.1/1.1.1" "")
    (estep "replace" "1.1.1/1.1.1/1.1.1" "")
    (eq* (phext:dynamic-length dyn) (phext:transitive-length trn)
        "store lengths agree")))

;;; DynamicPhext capacity discipline
(let ((cap (phext:make-dynamic-phext)))
  (loop for i from 1 to 64 do
    (phext:dynamic-append cap (list 1 1 1 1 1 1 1 1 i) (b "s")))
  (eq* (phext:dynamic-capacity cap) 64 "capacity doubles to fit 64")
  (ok (<= (phext:dynamic-resize-count cap) 7) "resize count is logarithmic"))

;;; fixtures
(let ((dir (second sb-ext:*posix-argv*)))
  (if dir
      (let ((files 0) (identical 0) (idem 0))
        (dolist (path (directory (merge-pathnames
                                  "**/input.phext"
                                  (concatenate 'string dir "/"))))
          (incf files)
          (let ((data (with-open-file (s path :element-type '(unsigned-byte 8))
                        (let ((v (make-array (file-length s)
                                             :element-type '(unsigned-byte 8))))
                          (read-sequence v s) v))))
            (when (equalp (phext:dephokenize (phext:phokenize data)) data)
              (incf identical))
            (let ((n1 (phext:normalize data)))
              (when (equalp (phext:normalize n1) n1) (incf idem)))))
        (format t "fixtures: ~D input.phext, ~D byte-identical round-trips, ~D normalize-idempotent~%"
                files identical idem)
        (eq* files 16 "16 fixtures found")
        (eq* identical files "fixtures byte-identical round-trips")
        (eq* idem files "all fixtures normalize idempotently"))
      (format t "fixtures: skipped (no fixtures dir)~%")))

(format t "lisp suite: ~D checks, ~D failures~%" *checks* *failures*)
(sb-ext:exit :code (if (zerop *failures*) 0 1))
