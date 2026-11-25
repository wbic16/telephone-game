;;;; Hub-side CLI for libphext-lisp (Exocortical Telephone Game,
;;;; contract v2).
;;;;
;;;; Transport: with the argument "serve", stdin carries one JSON
;;;; request per line and stdout carries one JSON response per line.
;;;; With no argument, stdin carries ONE JSON object and stdout ONE
;;;; response. This CLI serves the four libphext hooks the local
;;;; adapter (ports/lisp/adapter, harness/adapter_base.py) plugs into
;;;; its shared game machinery: explode / implode / insert / fetch.
;;;; Requests carry phext state as base64 under "state" (v2) or
;;;; "state_b64".
;;;;
;;;; Base64 and JSON are hand-written here (Common Lisp has neither in
;;;; the standard); SHA-256 shells out to sha256sum(1), as earlier
;;;; waves did where the language lacks it.

(load (merge-pathnames "phext.lisp" *load-truename*))

(defpackage :phext-cli (:use :cl))
(in-package :phext-cli)

(defparameter *impl* "lisp")

;;; ------------------------------------------------------------ base64
(defparameter *b64-alphabet*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun b64-encode (bytes)
  (let ((out (make-string-output-stream)) (n (length bytes)) (i 0))
    (loop while (< i n) do
      (let* ((b0 (aref bytes i))
             (b1 (if (< (1+ i) n) (aref bytes (1+ i)) 0))
             (b2 (if (< (+ i 2) n) (aref bytes (+ i 2)) 0))
             (triple (logior (ash b0 16) (ash b1 8) b2)))
        (write-char (char *b64-alphabet* (ldb (byte 6 18) triple)) out)
        (write-char (char *b64-alphabet* (ldb (byte 6 12) triple)) out)
        (write-char (if (< (1+ i) n)
                        (char *b64-alphabet* (ldb (byte 6 6) triple))
                        #\=) out)
        (write-char (if (< (+ i 2) n)
                        (char *b64-alphabet* (ldb (byte 6 0) triple))
                        #\=) out))
      (incf i 3))
    (get-output-stream-string out)))

(defun b64-value (ch)
  (or (position ch *b64-alphabet*) 0))

(defun b64-decode (s)
  (let ((clean (remove-if (lambda (ch) (member ch '(#\Newline #\Return #\Space))) s))
        (out '()))
    (loop for i from 0 below (length clean) by 4 do
      (let* ((c0 (char clean i))
             (c1 (char clean (1+ i)))
             (c2 (char clean (+ i 2)))
             (c3 (char clean (+ i 3)))
             (triple (logior (ash (b64-value c0) 18) (ash (b64-value c1) 12)
                             (ash (b64-value c2) 6) (b64-value c3))))
        (push (ldb (byte 8 16) triple) out)
        (unless (char= c2 #\=) (push (ldb (byte 8 8) triple) out))
        (unless (char= c3 #\=) (push (ldb (byte 8 0) triple) out))))
    (make-array (length out) :element-type '(unsigned-byte 8)
                             :initial-contents (nreverse out))))

;;; ------------------------------------------------------------ sha256
(defun sha256hex (bytes)
  "SHA-256 via sha256sum(1) over a temp file (bytes may be binary)."
  (let ((path (format nil "/tmp/phext-lisp-sha-~D" (get-universal-time))))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output
                                   :element-type '(unsigned-byte 8)
                                   :if-exists :supersede)
             (write-sequence bytes s))
           (let ((out (make-string-output-stream)))
             (sb-ext:run-program "sha256sum" (list path)
                                 :output out :search t)
             (subseq (get-output-stream-string out) 0 64)))
      (ignore-errors (delete-file path)))))

;;; ------------------------------------------------------------ JSON
;;; Parsed JSON: objects are alists (string . value), arrays are lists,
;;; strings are strings, numbers are integers, true=:true false=:false
;;; null=:null.

(defstruct parser (text "") (pos 0))

(defun p-peek (p) (char (parser-text p) (parser-pos p)))
(defun p-next (p) (prog1 (p-peek p) (incf (parser-pos p))))
(defun p-skip-ws (p)
  (loop while (and (< (parser-pos p) (length (parser-text p)))
                   (member (p-peek p) '(#\Space #\Tab #\Newline #\Return)))
        do (incf (parser-pos p))))

(defun p-expect (p ch)
  (unless (char= (p-next p) ch) (error "expected ~A" ch)))

(defun parse-json (text)
  (let ((p (make-parser :text text)))
    (p-skip-ws p)
    (prog1 (p-value p) (p-skip-ws p))))

(defun p-value (p)
  (p-skip-ws p)
  (case (p-peek p)
    (#\{ (p-object p))
    (#\[ (p-array p))
    (#\" (p-string p))
    (#\t (p-literal p "true" :true))
    (#\f (p-literal p "false" :false))
    (#\n (p-literal p "null" :null))
    (otherwise (p-number p))))

(defun p-literal (p word value)
  (loop for ch across word do (p-expect p ch))
  value)

(defun p-object (p)
  (p-expect p #\{)
  (p-skip-ws p)
  (let ((out '()))
    (when (char= (p-peek p) #\}) (p-next p) (return-from p-object out))
    (loop
      (p-skip-ws p)
      (let ((key (p-string p)))
        (p-skip-ws p) (p-expect p #\:)
        (push (cons key (p-value p)) out))
      (p-skip-ws p)
      (let ((ch (p-next p)))
        (when (char= ch #\}) (return (nreverse out)))
        (unless (char= ch #\,) (error "expected , or }"))))))

(defun p-array (p)
  (p-expect p #\[)
  (p-skip-ws p)
  (let ((out '()))
    (when (char= (p-peek p) #\]) (p-next p) (return-from p-array out))
    (loop
      (push (p-value p) out)
      (p-skip-ws p)
      (let ((ch (p-next p)))
        (when (char= ch #\]) (return (nreverse out)))
        (unless (char= ch #\,) (error "expected , or ]"))))))

(defun p-string (p)
  (p-expect p #\")
  (let ((out (make-string-output-stream)))
    (loop for ch = (p-next p)
          until (char= ch #\")
          do (if (char= ch #\\)
                 (let ((esc (p-next p)))
                   (case esc
                     (#\n (write-char #\Newline out))
                     (#\r (write-char #\Return out))
                     (#\t (write-char #\Tab out))
                     (#\b (write-char #\Backspace out))
                     (#\f (write-char #\Page out))
                     (#\u (let ((cp (parse-integer
                                     (subseq (parser-text p) (parser-pos p)
                                             (+ (parser-pos p) 4))
                                     :radix 16)))
                            (incf (parser-pos p) 4)
                            ;; Surrogate pairs: game text is latin-1;
                            ;; lone surrogates degrade to '?'.
                            (write-char (if (<= cp #xFFFF) (code-char cp) #\?) out)))
                     (otherwise (write-char esc out))))
                 (write-char ch out)))
    (get-output-stream-string out)))

(defun p-number (p)
  (let ((start (parser-pos p)))
    (loop while (and (< (parser-pos p) (length (parser-text p)))
                     (member (p-peek p) '(#\- #\+ #\. #\e #\E
                                          #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)))
          do (incf (parser-pos p)))
    (parse-integer (subseq (parser-text p) start (parser-pos p)))))

(defun json-escape (s out)
  (write-char #\" out)
  (loop for ch across s do
    (case ch
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return (write-string "\\r" out))
      (#\Tab (write-string "\\t" out))
      (otherwise
       (if (< (char-code ch) #x20)
           (format out "\\u~4,'0X" (char-code ch))
           (write-char ch out)))))
  (write-char #\" out))

(defun json-write (v out)
  (cond ((eq v :null) (write-string "null" out))
        ((eq v :true) (write-string "true" out))
        ((eq v :false) (write-string "false" out))
        ((stringp v) (json-escape v out))
        ((integerp v) (format out "~D" v))
        ((and (consp v) (stringp (car v))) ; object entry (key . value)
         (error "bare object entry"))
        ((listp v)
         (if (and v (consp (first v)) (stringp (car (first v))))
             (progn ; object: alist
               (write-char #\{ out)
               (loop for (entry . rest) on v do
                 (json-escape (car entry) out)
                 (write-char #\: out)
                 (json-write (cdr entry) out)
                 (when rest (write-char #\, out)))
               (write-char #\} out))
             (progn ; array
               (write-char #\[ out)
               (loop for (x . rest) on v do
                 (json-write x out)
                 (when rest (write-char #\, out)))
               (write-char #\] out))))
        (t (error "cannot write ~S as JSON" v))))

(defun json-string (v)
  (let ((out (make-string-output-stream)))
    (json-write v out)
    (get-output-stream-string out)))

(defun jget (obj key)
  (cdr (assoc key obj :test #'string=)))

;;; ------------------------------------------------------------ hooks
(defun state-of (req)
  (b64-decode (or (jget req "state") (jget req "state_b64"))))

(defun dispatch (req)
  (let ((cmd (jget req "cmd")))
    (cond
      ((string= cmd "id")
       (list (cons "impl" *impl*)))
      ((string= cmd "explode")
       (let ((map (phext:explode (state-of req))) (entries '()))
         (maphash (lambda (k v)
                    (push (cons (phext:coord-string k) (b64-encode v))
                          entries))
                  map)
         (list (cons "map" entries))))
      ((string= cmd "implode")
       (let ((map (make-hash-table :test 'equal)))
         (dolist (entry (jget req "map"))
           (setf (gethash (phext:coord-parse (car entry)) map)
                 (b64-decode (cdr entry))))
         (let ((bytes (phext:implode map)))
           (list (cons "state_b64" (b64-encode bytes))
                 (cons "state_sha256" (sha256hex bytes))))))
      ((string= cmd "insert")
       ;; Game insert (adapter_base hook semantics): unused coord only.
       (let* ((coord (phext:coord-parse (jget req "coordinate")))
              (map (phext:explode (state-of req))))
         (if (nth-value 1 (gethash coord map))
             (list (cons "error" "coordinate already occupied"))
             (progn
               (setf (gethash coord map) (b64-decode (jget req "text_b64")))
               (let ((bytes (phext:implode map)))
                 (list (cons "state_b64" (b64-encode bytes))
                       (cons "state_sha256" (sha256hex bytes))))))))
      ((string= cmd "fetch")
       (let ((got (phext:fetch-scroll
                   (state-of req)
                   (phext:coord-parse (jget req "coordinate")))))
         (list (cons "text_b64" (b64-encode got)))))
      (t (error "unknown cmd ~A" cmd)))))

;;; ------------------------------------------------------------ gzip
;;; Wire compression (see ports/lisp/adapter): requests over 64 KiB
;;; may arrive as {"gz_b64": "<base64 gzip of the request JSON>"} and
;;; large responses are returned the same way. Common Lisp has no
;;; zlib, so gzip goes through gzip(1) on temp files (the standard
;;; command-line-tool route earlier waves used for missing pieces).
(defvar *gz-counter* 0)

(defun gz-filter (program in-bytes)
  (let* ((tag (format nil "/tmp/phext-lisp-gz-~D-~D"
                      (get-universal-time) (incf *gz-counter*)))
         (pin (concatenate 'string tag ".in"))
         (pout (concatenate 'string tag ".out")))
    (unwind-protect
         (progn
           (with-open-file (s pin :direction :output
                                  :element-type '(unsigned-byte 8)
                                  :if-exists :supersede)
             (write-sequence in-bytes s))
           (sb-ext:run-program program (list "-c" pin)
                               :output pout :if-output-exists :supersede
                               :search t :wait t)
           (with-open-file (s pout :element-type '(unsigned-byte 8))
             (let ((v (make-array (file-length s)
                                  :element-type '(unsigned-byte 8))))
               (read-sequence v s) v)))
      (ignore-errors (delete-file pin))
      (ignore-errors (delete-file pout)))))

(defun handle-line (line)
  (handler-case
      (let ((req (parse-json line)))
        (when (jget req "gz_b64")
          (setf req (parse-json
                     (phext:bytes-to-string
                      (gz-filter "gunzip"
                                 (b64-decode (jget req "gz_b64")))))))
        (let ((resp (json-string (dispatch req))))
          (if (> (length resp) 65536)
              (json-string
               (list (cons "gz_b64"
                           (b64-encode
                            (gz-filter "gzip"
                                       (phext:string-to-bytes resp))))))
              resp)))
    (error (e) (json-string (list (cons "error" (format nil "~A" e)))))))

(defun main ()
  (let ((args (rest sb-ext:*posix-argv*)))
    (if (member "serve" args :test #'string=)
        (loop for line = (read-line *standard-input* nil nil)
              while line do
                (when (plusp (length line))
                  (write-line (handle-line line))
                  (finish-output)))
        (let ((text (loop for line = (read-line *standard-input* nil nil)
                          while line collect line)))
          (write-line (handle-line (format nil "~{~A~%~}" text)))
          (finish-output))))
  (sb-ext:exit :code 0))

(main)
