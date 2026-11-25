;; Test suite for libphext-clojure — plain assertions, no framework.
;; Run: telephone.test [fixtures_dir]
(ns telephone.test
  (:require [telephone.phext :as px])
  (:import [java.nio.file Files Paths]
           [java.util Arrays])
  (:gen-class))

(def checks (atom 0))
(def failures (atom 0))

(defn ok [cond name]
  (swap! checks inc)
  (when-not cond
    (swap! failures inc)
    (binding [*out* *err*] (println (str "FAIL: " name)))))

(defn eq [a b name] (ok (= a b) name))
(defn eqb [^bytes a ^bytes b name] (ok (Arrays/equals a b) name))
(defn B [s] (.getBytes ^String s "ISO-8859-1"))
(defn C [s] (px/coord-parse s))

(defn -main [& args]
  ;; coordinate
  (eq (px/coord-string (C "1.2.3/4.5.6/7.8.9")) "1.2.3/4.5.6/7.8.9" "coord format")
  (ok (neg? (px/coord-compare (C "1.1.1/1.1.1/1.1.1") (C "1.1.1/1.1.1/1.1.2"))) "order scroll")
  (ok (neg? (px/coord-compare (C "1.1.1/1.1.1/1.1.9") (C "1.1.1/1.1.2/1.1.1"))) "order section")
  (ok (pos? (px/coord-compare (C "2.1.1/1.1.1/1.1.1") (C "1.9.9/9.9.9/9.9.9"))) "order library")
  (eq (C "1.1.1/1.1.1/1.1.1") (px/coord-root) "root")
  (ok (try (C "0.1.1/1.1.1/1.1.1") false (catch Exception _ true)) "coord rejects 0")
  (ok (try (C "1.1/1.1.1/1.1.1") false (catch Exception _ true)) "coord rejects short")

  ;; phokenize
  (let [sc (px/phokenize (B "hello"))]
    (eq (count sc) 1 "one scroll")
    (eq (px/coord-string (:coord (first sc))) "1.1.1/1.1.1/1.1.1" "first coord")
    (eqb (:text (first sc)) (B "hello") "first text"))
  (let [sc (px/phokenize (B "a\u0017b\u0017\u0017c\nline2"))]
    (eq (count sc) 3 "scroll breaks")
    (eq (px/coord-string (:coord (nth sc 1))) "1.1.1/1.1.1/1.1.2" "second coord")
    (eq (px/coord-string (:coord (nth sc 2))) "1.1.1/1.1.1/1.1.4" "gap coord advance")
    (eqb (:text (nth sc 2)) (B "c\nline2") "newline is ordinary text"))
  (let [sc (px/phokenize (B "x\u0001y"))]
    (eq (px/coord-string (:coord (nth sc 1))) "2.1.1/1.1.1/1.1.1" "library break resets"))
  (let [sc (px/phokenize (B "x\u0018y"))]
    (eq (px/coord-string (:coord (nth sc 1))) "1.1.1/1.1.1/1.2.1" "section break"))
  (eq (count (px/phokenize (B ""))) 0 "empty buffer")
  (let [sc (px/phokenize (byte-array [0x61 0x00 0xFF 0x62]))]
    (eq (count sc) 1 "binary text is one scroll")
    (eq (alength (:text (first sc))) 4 "binary text preserved"))

  ;; round trip
  (let [sample (B "alpha\u0017beta\u0018gamma\u0001delta")]
    (eqb (px/dephokenize (px/phokenize sample)) sample "round trip sample"))
  (let [built (px/dephokenize [{:coord (C "1.1.1/1.1.1/1.1.2") :text (B "two")}
                               {:coord (C "1.1.1/1.1.1/1.1.1") :text (B "one")}])]
    (eqb built (B "one\u0017two") "dephokenize sorts canonically"))
  (eqb (px/normalize (px/normalize (B "\u0017\u0017lead")))
       (px/normalize (B "\u0017\u0017lead")) "normalize idempotent")

  ;; fetch incl. gaps
  (let [buf (B "one\u0017two\u0017\u0017four")]
    (eqb (px/fetch-scroll buf (C "1.1.1/1.1.1/1.1.1")) (B "one") "fetch 1")
    (eqb (px/fetch-scroll buf (C "1.1.1/1.1.1/1.1.4")) (B "four") "fetch 4")
    (eqb (px/fetch-scroll buf (C "1.1.1/1.1.1/1.1.3")) (B "") "gap fetch is empty")
    (eqb (px/fetch-scroll buf (C "9.9.9/9.9.9/9.9.9")) (B "") "far gap fetch is empty")
    (eqb (px/fetch-scroll (B "") (C "1.1.1/1.1.1/1.1.1")) (B "") "fetch empty buffer"))

  ;; insert
  (let [out (px/insert-scroll (B "base") (C "1.1.1/1.1.1/1.1.1") (B "+more"))]
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.1")) (B "base+more") "insert appends after existing"))
  (let [out (px/insert-scroll (B "") (C "1.1.1/1.1.1/1.1.3") (B "new"))]
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.3")) (B "new") "insert creates at gap")
    (eqb out (B "\u0017\u0017new") "insert at gap emits breaks"))
  (let [out (px/insert-scroll (B "a\u0017c") (C "1.1.1/1.1.1/1.1.2") (B "b"))]
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.2")) (B "cb") "insert merges existing + inserted"))

  ;; replace / remove — remove is coordinate-preserving
  (let [out (px/replace-scroll (B "old\u0017keep") (C "1.1.1/1.1.1/1.1.1") (B "new"))]
    (eqb out (B "new\u0017keep") "replace overwrites"))
  (let [out (px/replace-scroll (B "a") (C "1.1.1/1.1.1/1.1.5") (B "deep"))]
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.5")) (B "deep") "replace creates"))
  (let [out (px/remove-scroll (B "a\u0017b\u0017c") (C "1.1.1/1.1.1/1.1.2"))]
    (eqb out (B "a\u0017\u0017c") "remove leaves a gap (no renumbering)")
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.2")) (B "") "removed coordinate reads empty")
    (eqb (px/fetch-scroll out (C "1.1.1/1.1.1/1.1.3")) (B "c") "neighbour keeps its coordinate"))
  (eq (alength (px/remove-scroll (B "only") (C "1.1.1/1.1.1/1.1.1"))) 0 "remove sole scroll")
  (eqb (px/remove-scroll (B "a") (C "5.5.5/5.5.5/5.5.5")) (B "a") "remove gap is a no-op")

  ;; explode / implode
  (let [m (px/explode (B "x\u0017y"))]
    (eq (count m) 2 "explode count")
    (eqb (px/implode m) (B "x\u0017y") "implode round trip"))

  ;; Dynamic + Transitive equivalence with the string path
  (let [dyn (px/make-dynamic)
        trn (px/make-transitive)
        str-buf (atom (B ""))]
    (letfn [(step [op coord text]
              (let [c (C coord) t (B text)]
                (case op
                  "insert" (do (swap! str-buf #(px/insert-scroll % c t))
                               (px/dynamic-insert dyn c t)
                               (px/transitive-insert trn c t))
                  "replace" (do (swap! str-buf #(px/replace-scroll % c t))
                                (px/dynamic-replace dyn c t)
                                (px/transitive-replace trn c t))
                  "remove" (do (swap! str-buf #(px/remove-scroll % c))
                               (px/dynamic-remove dyn c)
                               (px/transitive-remove trn c)))
                (eqb (px/dynamic-serialize dyn) @str-buf (str "dynamic == string after " op " " coord))
                (eqb (px/transitive-serialize trn) @str-buf (str "transitive == string after " op " " coord))
                (eqb (px/dynamic-fetch dyn c) (px/fetch-scroll @str-buf c) "dynamic fetch after op")
                (eqb (px/transitive-fetch trn c) (px/fetch-scroll @str-buf c) "transitive fetch after op")))]
      (step "insert" "1.1.1/1.1.1/1.1.1" "alpha")
      (step "insert" "1.1.1/1.1.1/1.1.3" "gamma")
      (step "insert" "1.1.1/1.1.1/1.1.2" "beta")
      (step "insert" "1.1.1/1.1.1/1.1.2" "+")
      (step "replace" "2.1.1/1.1.1/1.1.1" "lib2")
      (step "remove" "1.1.1/1.1.1/1.1.3" "")
      (eqb (px/dynamic-fetch dyn (C "1.1.1/1.1.1/1.1.3")) (B "") "dynamic removed coord is gap")
      (eqb (px/transitive-fetch trn (C "1.1.1/1.1.1/1.1.3")) (B "") "transitive removed coord is gap")
      (eqb (px/dynamic-fetch dyn (C "2.1.1/1.1.1/1.1.1")) (B "lib2") "dynamic neighbour unmoved")
      (eqb (px/transitive-fetch trn (C "2.1.1/1.1.1/1.1.1")) (B "lib2") "transitive neighbour unmoved")
      (step "insert" "1.1.1/1.1.1/1.1.1" "")
      (step "replace" "1.1.1/1.1.1/1.1.1" "")
      (eq (px/dynamic-length dyn) (px/transitive-length trn) "store lengths agree")))

  ;; DynamicPhext capacity discipline
  (let [cap (px/make-dynamic)]
    (doseq [i (range 1 65)]
      (px/dynamic-append cap [1 1 1 1 1 1 1 1 i] (B "s")))
    (eq (px/dynamic-capacity cap) 64 "capacity doubles to fit 64")
    (ok (<= (px/dynamic-resize-count cap) 7) "resize count is logarithmic"))

  ;; fixtures
  (if (seq args)
    (let [root (Paths/get (first args) (into-array String []))
          stream (Files/walk root (into-array java.nio.file.FileVisitOption []))
          files (atom 0) identical (atom 0) idem (atom 0)]
      (try
        (doseq [p (iterator-seq (.iterator stream))]
          (when (= "input.phext" (str (.getFileName p)))
            (swap! files inc)
            (let [data (Files/readAllBytes p)]
              (when (Arrays/equals (px/dephokenize (px/phokenize data)) data)
                (swap! identical inc))
              (let [n1 (px/normalize data)]
                (when (Arrays/equals (px/normalize n1) n1)
                  (swap! idem inc))))))
        (finally (.close stream)))
      (println (format "fixtures: %d input.phext, %d byte-identical round-trips, %d normalize-idempotent"
                       @files @identical @idem))
      (eq @files 16 "16 fixtures found")
      (eq @identical @files "fixtures byte-identical round-trips")
      (eq @idem @files "all fixtures normalize idempotently"))
    (println "fixtures: skipped (no fixtures dir)"))

  (println (format "clojure suite: %d checks, %d failures" @checks @failures))
  (System/exit (if (zero? @failures) 0 1)))
