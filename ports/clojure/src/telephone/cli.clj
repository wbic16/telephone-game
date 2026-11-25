;; Hub-side CLI for libphext-clojure (Exocortical Telephone Game,
;; contract v2).
;;
;; Transport: with the argument `serve`, stdin carries one JSON
;; request per line and stdout carries one JSON response per line.
;; With no argument, stdin carries ONE JSON object and stdout ONE
;; response. State crosses the wire as base64 under "state".
;; Serve lines over 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
;;
;; This CLI wraps only this port's own libphext (telephone.phext).
;; JSON is hand-written (no third-party deps); base64/SHA-256/gzip are
;; the JDK's; PGP goes through subprocess gpg with a per-port
;; GNUPGHOME (~/telephone-clojure/gnupg unless TELEPHONE_GNUPGHOME).
(ns telephone.cli
  (:require [telephone.phext :as px]
            [clojure.string :as str])
  (:import [java.security MessageDigest]
           [java.util Base64]
           [java.util.zip GZIPInputStream GZIPOutputStream]
           [java.io ByteArrayOutputStream ByteArrayInputStream File]
           [java.nio.file Files]
           [java.nio.file.attribute FileAttribute])
  (:gen-class))

(def impl "clojure")
(def index-coord [1 1 1 1 1 1 1 1 1])
(def keys-coord [1 1 1 1 1 1 1 1 2])
(def kh-coord [1 1 1 1 1 1 1 1 3])
(def event-prefix [1 1 1 1 1 1 2 1])

;; ---------------------------------------------------------------- JSON
;; Parsed JSON: objects = maps with string keys (sorted-map-by not
;; needed; the canonical writer sorts), arrays = vectors, strings =
;; String, integers = Long, reals = Double, true/false, nil = null.

(defn- parse-json [s]
  (let [pos (atom 0)
        n (count s)]
    (letfn [(peek-ch [] (nth s @pos))
            (next-ch [] (let [c (nth s @pos)] (swap! pos inc) c))
            (skip-ws [] (while (and (< @pos n)
                                    (contains? #{\space \tab \newline \return} (nth s @pos)))
                          (swap! pos inc)))
            (expect [c] (let [got (next-ch)]
                          (when (not= got c)
                            (throw (IllegalArgumentException. (str "expected " c " got " got))))))
            (parse-value []
              (skip-ws)
              (case (peek-ch)
                \{ (parse-obj)
                \[ (parse-arr)
                \" (parse-str)
                \t (do (doseq [c "true"] (expect c)) true)
                \f (do (doseq [c "false"] (expect c)) false)
                \n (do (doseq [c "null"] (expect c)) nil)
                (parse-num)))
            (parse-obj []
              (expect \{)
              (skip-ws)
              (if (= (peek-ch) \})
                (do (next-ch) {})
                (loop [out {}]
                  (skip-ws)
                  (let [k (parse-str)]
                    (skip-ws)
                    (expect \:)
                    (let [v (parse-value)
                          out (assoc out k v)]
                      (skip-ws)
                      (case (next-ch)
                        \} out
                        \, (recur out)
                        (throw (IllegalArgumentException. "expected , or }"))))))))
            (parse-arr []
              (expect \[)
              (skip-ws)
              (if (= (peek-ch) \])
                (do (next-ch) [])
                (loop [out []]
                  (let [v (parse-value)]
                    (skip-ws)
                    (case (next-ch)
                      \] (conj out v)
                      \, (recur (conj out v))
                      (throw (IllegalArgumentException. "expected , or ]")))))))
            (parse-str []
              (expect \")
              (let [sb (StringBuilder.)]
                (loop []
                  (let [c (next-ch)]
                    (case c
                      \" (.toString sb)
                      \\ (let [e (next-ch)]
                           (case e
                             \n (.append sb \newline)
                             \r (.append sb \return)
                             \t (.append sb \tab)
                             \b (.append sb \backspace)
                             \f (.append sb \formfeed)
                             \/ (.append sb \/)
                             \u (let [cp (Integer/parseInt (subs s @pos (+ @pos 4)) 16)]
                                  (swap! pos + 4)
                                  (.append sb (char cp)))
                             (.append sb e))
                           (recur))
                      (do (.append sb c) (recur)))))))
            (parse-num []
              (let [start @pos]
                (while (and (< @pos n)
                            (contains? (set "-+0123456789.eE") (nth s @pos)))
                  (swap! pos inc))
                (let [txt (subs s start @pos)]
                  (if (re-find #"[.eE]" txt)
                    (Double/parseDouble txt)
                    (Long/parseLong txt)))))]
      (let [v (parse-value)]
        (skip-ws)
        v))))

(defn- escape-json-string [^String s]
  ;; Matches Python json.dumps(..., ensure_ascii=True): escape ", \,
  ;; the short escapes, and every char outside 0x20..0x7E as \uXXXX
  ;; (surrogate pairs above 0xFFFF).
  (let [sb (StringBuilder.)]
    (.append sb \")
    (doseq [ch s]
      (let [cp (int ch)]
        (cond
          (= ch \") (.append sb "\\\"")
          (= ch \\) (.append sb "\\\\")
          (= ch \newline) (.append sb "\\n")
          (= ch \return) (.append sb "\\r")
          (= ch \tab) (.append sb "\\t")
          (= cp 8) (.append sb "\\b")
          (= cp 12) (.append sb "\\f")
          (or (< cp 0x20) (> cp 0x7E))
          (if (and (> cp 0xFFFF))
            (.append sb (format "\\u%04x\\u%04x"
                                (int (Character/highSurrogate cp))
                                (int (Character/lowSurrogate cp))))
            (.append sb (format "\\u%04x" cp)))
          :else (.append sb ch))))
    (.append sb \")
    (.toString sb)))

(defn- write-json-into [v ^StringBuilder sb]
  (cond
    (nil? v) (.append sb "null")
    (true? v) (.append sb "true")
    (false? v) (.append sb "false")
    (string? v) (.append sb (escape-json-string v))
    (integer? v) (.append sb (str v))
    (number? v) (.append sb (str v))
    (map? v) (do (.append sb \{)
                 (loop [entries (seq (sort-by key v)) first? true]
                   (when entries
                     (when-not first? (.append sb \,))
                     (.append sb (escape-json-string (ffirst entries)))
                     (.append sb \:)
                     (write-json-into (second (first entries)) sb)
                     (recur (next entries) false)))
                 (.append sb \}))
    (sequential? v) (do (.append sb \[)
                        (loop [items (seq v) first? true]
                          (when items
                            (when-not first? (.append sb \,))
                            (write-json-into (first items) sb)
                            (recur (next items) false)))
                        (.append sb \]))
    :else (throw (IllegalArgumentException. (str "cannot write " v)))))

(defn write-json [v]
  (let [sb (StringBuilder.)]
    (write-json-into v sb)
    (.toString sb)))

(defn canon-bytes [v]
  (.getBytes (write-json v) "UTF-8"))

;; ---------------------------------------------------------------- util
(defn sha256hex [^bytes bs]
  (let [d (.digest (MessageDigest/getInstance "SHA-256") bs)]
    (apply str (map #(format "%02x" (bit-and % 0xFF)) d))))

(defn b64encode [^bytes bs] (.encodeToString (Base64/getEncoder) bs))
(defn b64decode [^String s] (.decode (Base64/getDecoder) s))

(defn latin1-bytes [^String s] (.getBytes s "ISO-8859-1"))
(defn latin1-string [^bytes bs] (String. bs "ISO-8859-1"))
(defn utf8-string [^bytes bs] (String. bs "UTF-8"))

(defn state-of [req]
  (b64decode (or (get req "state") (get req "state_b64"))))

(defn explode-str-map [data]
  (into {} (map (fn [[c t]] [(px/coord-string c) t]) (px/explode data))))

(defn gzip-bytes [^bytes bs]
  (let [buf (ByteArrayOutputStream.)
        out (GZIPOutputStream. buf)]
    (.write out bs)
    (.close out)
    (.toByteArray buf)))

(defn gunzip-bytes [^bytes bs]
  (let [in (GZIPInputStream. (ByteArrayInputStream. bs))]
    (.readAllBytes in)))

;; ---------------------------------------------------------------- gpg
(defn gnupg-home []
  (let [h (or (System/getenv "TELEPHONE_GNUPGHOME")
              (str (System/getProperty "user.home") "/telephone-" impl "/gnupg"))
        f (File. h)]
    (.mkdirs f)
    ;; best-effort 0700
    (try (.setExecutable f true true) (catch Exception _))
    (try
      (let [pb (ProcessBuilder. ["chmod" "700" h])]
        (.waitFor (.start pb)))
      (catch Exception _))
    h))

(defn- run-gpg [home args ^bytes input]
  (let [pb (ProcessBuilder. (into ["gpg" "--batch" "--yes"] args))
        env (.environment pb)]
    (.put env "GNUPGHOME" home)
    (let [p (.start pb)]
      (when input
        (with-open [os (.getOutputStream p)]
          (.write os input)))
      (let [out (.readAllBytes (.getInputStream p))
            err (.readAllBytes (.getErrorStream p))
            rc (.waitFor p)]
        (when (not= 0 rc)
          (throw (RuntimeException. (str "gpg failed: " (String. err "UTF-8")))))
        out))))

(defn keygen []
  (let [home (gnupg-home)
        uid (str "telephone-" impl)
        keys (String. (run-gpg home ["--list-keys" "--with-colons"] nil) "UTF-8")]
    (when (not (str/includes? keys "pub"))
      (run-gpg home ["--pinentry-mode" "loopback" "--passphrase" ""
                     "--quick-generate-key" uid "ed25519" "sign" "never"] nil))
    {"impl" impl
     "pubkey" (String. (run-gpg home ["--armor" "--export" uid] nil) "UTF-8")}))

(defn attest [descriptor]
  (let [home (gnupg-home)
        uid (str "telephone-" impl)
        sig (run-gpg home ["--pinentry-mode" "loopback" "--passphrase" ""
                           "--detach-sign" "--armor" "-u" uid]
                     (canon-bytes descriptor))]
    {"signature" (String. sig "UTF-8")}))

(defn verify-signature [pubkeys-text ^bytes data ^String sig-b64]
  (try
    (let [td (Files/createTempDirectory "telverify" (into-array FileAttribute []))
          home (str (.resolve td "gnupg"))]
      (.mkdirs (File. home))
      (let [pb (ProcessBuilder. ["chmod" "700" home])] (.waitFor (.start pb)))
      (let [env-home home
            run (fn [args ^bytes input]
                  (let [pb (ProcessBuilder. (into ["gpg" "--batch" "--yes"] args))
                        env (.environment pb)]
                    (.put env "GNUPGHOME" env-home)
                    (let [p (.start pb)]
                      (when input
                        (with-open [os (.getOutputStream p)] (.write os input)))
                      (.readAllBytes (.getInputStream p))
                      (.readAllBytes (.getErrorStream p))
                      (.waitFor p))))]
        (when (not= 0 (run ["--import"] (.getBytes pubkeys-text "UTF-8")))
          (throw (RuntimeException. "import failed")))
        (let [sigfile (str (.resolve td "sig.asc"))]
          (Files/write (.resolve td "sig.asc") (b64decode sig-b64)
                       (into-array java.nio.file.OpenOption []))
          (= 0 (run ["--verify" sigfile "-"] data)))))
    (catch Exception _ false)))

;; ---------------------------------------------------------------- game
(def cache (atom nil)) ;; {:map {coord-vec bytes} :hash hex}

(defn do-echo [ping]
  {"impl" impl "echo" (sha256hex (canon-bytes {"impl" impl "ping" ping}))})

(defn do-elect [position candidates turn]
  (let [pool (vec (or (seq (filter #(not= % impl) candidates)) candidates))
        seed (sha256hex (.getBytes (str impl "-elect:" position ":" turn ":"
                                        (str/join "," candidates)) "UTF-8"))]
    {"elect" (nth pool (mod (Long/parseLong (subs seed 0 8) 16) (count pool)))}))

(defn do-choose [data position turn]
  (let [m (px/explode data)
        pos (loop [p (px/coord-parse position)]
              (if (contains? m p)
                (recur (assoc p 8 (inc (nth p 8))))
                p))]
    {"op" "insert"
     "coordinate" (px/coord-string pos)
     "text" (str impl " was here, turn " turn)}))

(defn do-apply [data step]
  (let [coord (px/coord-parse (get step "coordinate"))
        m (px/explode data)]
    (when (contains? m coord)
      (throw (IllegalArgumentException. "coordinate already occupied")))
    (let [out (px/implode (assoc m coord (latin1-bytes (get step "text"))))]
      {"state_b64" (b64encode out) "state_sha256" (sha256hex out)})))

(defn do-init [data]
  (reset! cache {:map (px/explode data) :hash (sha256hex data)})
  {"impl" impl "verdict" "pass"})

(defn- vfail [detail] {"impl" impl "verdict" "fail" "detail" detail})

(defn do-validate [data step event-coord-s index-line]
  (let [new (px/explode data)
        coord (px/coord-parse (get step "coordinate"))
        ev (px/coord-parse event-coord-s)
        old (:map @cache)]
    (cond
      (not= (some-> (get new coord) latin1-string) (get step "text"))
      (vfail "placed scroll missing or altered")

      :else
      (let [bad (first (filter (fn [[c t]]
                                 (and (not= c index-coord)
                                      (let [nv (get new c)]
                                        (or (nil? nv)
                                            (not (java.util.Arrays/equals
                                                   ^bytes nv ^bytes t))))))
                               old))]
        (cond
          (some? bad) (vfail (str "prior scroll overwritten at " (px/coord-string (first bad))))
          (some (fn [c] (and (not (contains? old c)) (not= c coord) (not= c ev))) (keys new))
          (vfail (str "unexpected new scroll at "
                      (px/coord-string (first (filter (fn [c] (and (not (contains? old c))
                                                                   (not= c coord) (not= c ev)))
                                                      (keys new))))))
          (not (str/ends-with? (str/trim-newline (latin1-string (get new index-coord (byte-array 0))))
                               (str/trim-newline index-line)))
          (vfail "index does not record the placement")
          :else (do (reset! cache {:map new :hash (sha256hex data)})
                    {"impl" impl "verdict" "pass"}))))))

(defn- vfail-n [n msg]
  {"impl" impl "verdict" "fail" "placements_checked" n
   "first_failure" {"detail" msg}})

(defn do-verify [data]
  (let [m (px/explode data)
        keys-text (utf8-string (get m keys-coord (byte-array 0)))]
    (if (not= (sha256hex (.getBytes keys-text "UTF-8"))
              (str/trim (latin1-string (get m kh-coord (byte-array 0)))))
      (vfail-n 0 "keys-hash scroll does not match keys")
      (let [events (into {}
                         (comp (filter (fn [[c _]] (= (subvec c 0 8) event-prefix)))
                               (map (fn [[c t]] [(nth c 8) (parse-json (utf8-string t))])))
                         m)
            seqs (sort (keys events))]
        (loop [i 0 seqs (seq seqs) prev-hash nil placements {}]
          (if (nil? seqs)
            (let [idx-lines (filter (fn [ln] (and (seq ln) (not (str/starts-with? ln "#"))))
                                    (str/split-lines (latin1-string (get m index-coord (byte-array 0)))))]
              (cond
                (not= (count idx-lines) (count placements))
                (vfail-n (count placements) "index lines != placements")
                :else
                (let [bad (first (filter (fn [ln]
                                           (let [[_n cs h _actor] (str/split ln #" " 4)]
                                             (not= (get (get placements (px/coord-parse cs)) "text_sha256") h)))
                                         idx-lines))]
                  (if bad
                    (vfail-n (count placements) (str "index hash mismatch: " (subs bad 0 (min 40 (count bad)))))
                    {"impl" impl "verdict" "pass"
                     "placements_checked" (count placements)
                     "first_failure" nil}))))
            (let [s (first seqs)]
              (cond
                (not= s (inc i)) (vfail-n (count placements) (str "event seq gap at " s))
                :else
                (let [ev (get events s)]
                  (cond
                    (not= (get ev "prev") prev-hash)
                    (vfail-n (count placements) (str "event chain broken at seq " s))
                    :else
                    (let [prev2 (sha256hex (canon-bytes (get ev "body")))]
                      (if (= (get (get ev "body") "type") "placement")
                        (let [body (get ev "body")
                              coord (px/coord-parse (get body "coord"))]
                          (cond
                            (contains? placements coord)
                            (vfail-n (count placements) (str "coordinate reused at seq " s))
                            (let [t (get m coord)]
                              (or (nil? t) (not= (sha256hex t) (get body "text_sha256"))))
                            (vfail-n (count placements) (str "placement scroll hash mismatch seq " s))
                            (not (verify-signature
                                   keys-text
                                   (canon-bytes {"turn" (get body "turn")
                                                 "coordinate" (get body "coord")
                                                 "scroll_sha256" (get body "text_sha256")
                                                 "file_sha256" (get body "file_sha256")})
                                   (get body "att")))
                            (vfail-n (count placements) (str "attestation fails at seq " s))
                            :else (recur (inc i) (next seqs) prev2 (assoc placements coord body))))
                        (recur (inc i) (next seqs) prev2 placements)))))))))))))

;; ---------------------------------------------------------------- dispatch
(defn dispatch [req]
  (case (get req "cmd")
    "id" {"impl" impl}
    "keygen" (keygen)
    "echo" (do-echo (get req "ping"))
    "elect" (do-elect (get req "position") (get req "candidates") (get req "turn"))
    "choose" (do-choose (state-of req) (get req "position") (get req "turn"))
    "apply" (do-apply (state-of req) (get req "step"))
    "attest" (attest (get req "descriptor"))
    "init" (do-init (state-of req))
    "validate" (do-validate (state-of req) (get req "step")
                            (get req "event_coord") (get req "index_line"))
    "verify" (do-verify (state-of req))
    (throw (IllegalArgumentException. (str "unknown cmd " (get req "cmd"))))))

(defn handle-line [line]
  (try
    (let [req (parse-json line)
          resp (write-json (dispatch req))]
      (if (> (count resp) 8192)
        (str "GZ1:" (b64encode (gzip-bytes (.getBytes resp "UTF-8"))))
        resp))
    (catch Exception e
      (write-json {"error" (str (.getSimpleName (class e)) ": " (.getMessage e))}))))

(defn unframe [line]
  (if (str/starts-with? line "GZ1:")
    (String. (gunzip-bytes (b64decode (subs line 4))) "UTF-8")
    line))

(defn -main [& args]
  (if (some #{"serve"} args)
    (let [rdr (java.io.BufferedReader. (java.io.InputStreamReader. System/in "UTF-8"))]
      (loop [line (.readLine rdr)]
        (when line
          (when (not (str/blank? line))
            (println (handle-line (unframe line)))
            (flush))
          (recur (.readLine rdr)))))
    (let [text (String. (.readAllBytes System/in) "UTF-8")]
      (when (not (str/blank? text))
        (println (handle-line (unframe (str/trim text))))))))
