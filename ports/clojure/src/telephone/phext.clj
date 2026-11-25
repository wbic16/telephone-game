;; libphext-clojure — a Clojure port of libphext (0.6.1 parity).
;;
;; Semantics are normative from libphext-py: a phext is a byte buffer;
;; nine dimension-break bytes walk a 9-component coordinate; scroll text
;; is a maximal run of non-break bytes (newline 0x0A is ordinary text).
;; Buffers are byte arrays so control bytes are never reinterpreted.
;; Coordinates are vectors of 9 longs, ordered lexicographically;
;; string form a.b.c/d.e.f/g.h.i.
(ns telephone.phext
  (:import [java.io ByteArrayOutputStream]))

(def dimension-breaks
  "Dimension breaks in dimension order (library .. scroll)."
  [0x01 0x1F 0x1E 0x1D 0x1C 0x1A 0x19 0x18 0x17])

(def break-dim
  (into {} (map-indexed (fn [d b] [b d]) dimension-breaks)))

(defn coord-root [] [1 1 1 1 1 1 1 1 1])

(defn coord-parse [s]
  (let [groups (clojure.string/split (clojure.string/trim s) #"/")]
    (when (not= 3 (count groups))
      (throw (IllegalArgumentException. (str "coordinate must be a.b.c/d.e.f/g.h.i: " s))))
    (let [nums (vec (mapcat (fn [g] (map #(Long/parseLong %) (clojure.string/split g #"\."))) groups))]
      (when (not= 9 (count nums))
        (throw (IllegalArgumentException. (str "coordinate needs 9 parts: " s))))
      (when (some #(< % 1) nums)
        (throw (IllegalArgumentException. (str "components must be >= 1: " s))))
      nums)))

(defn coord-string [c]
  (format "%d.%d.%d/%d.%d.%d/%d.%d.%d"
          (nth c 0) (nth c 1) (nth c 2) (nth c 3) (nth c 4)
          (nth c 5) (nth c 6) (nth c 7) (nth c 8)))

(defn coord-compare [a b]
  (loop [i 0]
    (cond
      (= i 9) 0
      (not= (nth a i) (nth b i)) (compare (nth a i) (nth b i))
      :else (recur (inc i)))))

(defn coord-apply-break [c d]
  (let [out (vec c)
        out (assoc out d (inc (nth out d)))]
    (reduce (fn [o lower] (assoc o lower 1)) out (range (inc d) 9))))

;; A positioned scroll is a map {:coord [...] :text byte-array}.

(defn phokenize
  "Ordered list of positioned scrolls in buffer (byte array)."
  [buffer]
  (let [n (alength buffer)]
    (loop [i 0 coord (coord-root) run-start 0 acc (transient [])]
      (if (< i n)
        (let [d (get break-dim (bit-and (aget buffer i) 0xFF))]
          (if (some? d)
            (recur (inc i)
                   (coord-apply-break coord d)
                   (inc i)
                   (if (> i run-start)
                     (conj! acc {:coord coord
                                 :text (java.util.Arrays/copyOfRange buffer run-start i)})
                     acc))
            (recur (inc i) coord run-start acc)))
        (persistent!
          (if (> n run-start)
            (conj! acc {:coord coord
                        :text (java.util.Arrays/copyOfRange buffer run-start n)})
            acc))))))

(defn- emit-advance
  "Write the break bytes that move loc up to target into out; returns
  target as the new loc. Assumes loc <= target."
  [^ByteArrayOutputStream out loc target]
  (when (neg? (coord-compare loc target))
    (let [dim (loop [d 0] (if (= (nth loc d) (nth target d)) (recur (inc d)) d))]
      (dotimes [_ (- (nth target dim) (nth loc dim))]
        (.write out (int (nth dimension-breaks dim))))
      (doseq [lower (range (inc dim) 9)]
        (dotimes [_ (dec (nth target lower))]
          (.write out (int (nth dimension-breaks lower)))))))
  target)

(defn dephokenize
  "Canonical bytes: sorted coordinate order, advancing from the root;
  empty scrolls contribute nothing."
  [stack]
  (let [sorted (sort-by :coord (fn [a b] (coord-compare a b)) stack)
        out (ByteArrayOutputStream.)]
    (loop [loc (coord-root) items (seq sorted)]
      (when items
        (let [{:keys [coord text]} (first items)]
          (if (pos? (alength text))
            (do (emit-advance out loc coord)
                (.write out ^bytes text)
                (recur coord (next items)))
            (recur loc (next items))))))
    (.toByteArray out)))

(defn- dephokenize-in-order
  "Bytes for scrolls in the given (placed) order, as py's update emits."
  [stack]
  (let [out (ByteArrayOutputStream.)]
    (loop [loc (coord-root) items (seq stack)]
      (when items
        (let [{:keys [coord text]} (first items)
              loc (emit-advance out loc coord)]
          (.write out ^bytes text)
          (recur loc (next items)))))
    (.toByteArray out)))

(defn normalize [buffer]
  (dephokenize (phokenize buffer)))

(defn fetch-scroll
  "Text at coord, or empty byte array for a gap coordinate."
  [buffer coord]
  (let [hit (first (filter #(= (:coord %) coord) (phokenize buffer)))]
    (if hit (:text hit) (byte-array 0))))

(defn- update-buffer [buffer coord scroll overwrite?]
  (let [items (phokenize buffer)]
    (loop [items (seq items) acc (transient []) next-ps {:coord coord :text scroll} appended? false]
      (if items
        (let [ps (first items)
              cmp (coord-compare (:coord ps) coord)]
          (cond
            (and (pos? cmp) (not appended?))
            (recur (next items) (conj! (conj! acc next-ps) ps) next-ps true)

            (and (zero? cmp) (not appended?))
            (let [merged (if overwrite?
                           next-ps
                           {:coord coord
                            :text (let [baos (ByteArrayOutputStream.)]
                                    (.write baos ^bytes (:text ps))
                                    (.write baos ^bytes (:text next-ps))
                                    (.toByteArray baos))})]
              (recur (next items) (conj! acc merged) next-ps true))

            :else
            (recur (next items) (conj! acc ps) next-ps appended?)))
        ;; dephokenize in placed order (no sort), as py's update does
        (dephokenize-in-order (persistent! (if appended? acc (conj! acc next-ps))))))))

(defn insert-scroll
  "Existing text is prepended to the inserted text."
  [buffer coord scroll]
  (update-buffer buffer coord scroll false))

(defn replace-scroll [buffer coord scroll]
  (update-buffer buffer coord scroll true))

(defn remove-scroll
  "Replace with \"\" then normalize — coordinate-preserving: the removed
  coordinate reads \"\" and neighbours do not shift."
  [buffer coord]
  (normalize (update-buffer buffer coord (byte-array 0) true)))

(defn explode
  "Map form: coordinate vector -> text."
  [buffer]
  (into {} (map (fn [ps] [(:coord ps) (:text ps)]) (phokenize buffer))))

(defn implode [mapping]
  (dephokenize (map (fn [[c t]] {:coord c :text t}) mapping)))

;; ------------------------------------------------------------------
;; DynamicPhext: capacity-managed dynamic array scroll store.
;; Start at capacity 1, double when full on append, shrink only at
;; quarter load (never half — that thrashes). Edit semantics are
;; update-buffer's own; the array stays in coordinate order so
;; serialize is byte-identical to the string path.
(declare dynamic-load transitive-load)

;; State lives in a single public atom field: deftype mutable fields
;; are private, so the record functions below go through the atom.
(deftype DynamicPhext [state shrink-divisor]
  Object
  (toString [_] (str "DynamicPhext[len=" (:n @state) ",cap=" (:capacity @state) "]")))

(defn make-dynamic
  ([] (make-dynamic (byte-array 0) 4))
  ([buffer] (make-dynamic buffer 4))
  ([buffer shrink-divisor]
   (when (< shrink-divisor 2)
     (throw (IllegalArgumentException. "shrink_divisor must be >= 2")))
   (let [d (DynamicPhext. (atom {:data (object-array 1) :capacity 1 :n 0
                                 :resize-count 0 :elements-copied 0})
                          shrink-divisor)]
     (when (pos? (alength buffer)) (dynamic-load d buffer))
     d)))

(defn- dyn-resize [^DynamicPhext d new-capacity]
  (let [st @(.state d)
        nd (object-array new-capacity)]
    (System/arraycopy (:data st) 0 nd 0 (:n st))
    (reset! (.state d) (assoc st :data nd :capacity new-capacity
                              :resize-count (inc (:resize-count st))
                              :elements-copied (+ (:elements-copied st) (:n st))))))

(defn- dyn-grow-if-full [^DynamicPhext d]
  (let [st @(.state d)]
    (when (= (:n st) (:capacity st)) (dyn-resize d (* 2 (:capacity st))))))

(defn- dyn-shrink-if-sparse [^DynamicPhext d]
  (let [st @(.state d)]
    (when (and (> (:capacity st) 1)
               (<= (:n st) (quot (:capacity st) (.shrink-divisor d))))
      (dyn-resize d (max 1 (quot (:capacity st) 2))))))

(defn- dyn-push [^DynamicPhext d ps]
  (dyn-grow-if-full d)
  (let [st @(.state d)]
    (aset (:data st) (:n st) ps)
    (reset! (.state d) (assoc st :n (inc (:n st))))))

(defn dynamic-load [^DynamicPhext d buffer]
  (reset! (.state d) {:data (object-array 1) :capacity 1 :n 0
                      :resize-count 0 :elements-copied 0})
  (doseq [ps (phokenize buffer)] (dyn-push d ps))
  d)

(defn dynamic-length [^DynamicPhext d] (:n @(.state d)))
(defn dynamic-capacity [^DynamicPhext d] (:capacity @(.state d)))
(defn dynamic-resize-count [^DynamicPhext d] (:resize-count @(.state d)))

(defn dynamic-scrolls [^DynamicPhext d]
  (let [st @(.state d)]
    (vec (take (:n st) (:data st)))))

(defn dynamic-serialize [^DynamicPhext d]
  (dephokenize (dynamic-scrolls d)))

(defn- dyn-find [^DynamicPhext d coord]
  (let [st @(.state d) data (:data st) n (:n st)]
    (loop [lo 0 hi n]
      (if (< lo hi)
        (let [mid (quot (+ lo hi) 2)
              cmp (coord-compare (:coord (aget data mid)) coord)]
          (cond
            (neg? cmp) (recur (inc mid) hi)
            (pos? cmp) (recur lo mid)
            :else [mid true]))
        [lo false]))))

(defn dynamic-fetch [^DynamicPhext d coord]
  (let [[index found?] (dyn-find d coord)]
    (if found? (:text (aget (:data @(.state d)) index)) (byte-array 0))))

(defn dynamic-contains? [^DynamicPhext d coord]
  (second (dyn-find d coord)))

(defn dynamic-append [^DynamicPhext d coord text]
  (let [st @(.state d)]
    (when (and (pos? (:n st))
               (not (pos? (coord-compare coord (:coord (aget (:data st) (dec (:n st))))))))
      (throw (IllegalArgumentException. "append requires a coordinate past the current tail"))))
  (when (pos? (alength text)) (dyn-push d {:coord coord :text text}))
  d)

(defn- dyn-remove-at [^DynamicPhext d index]
  (let [st @(.state d) data (:data st) n (:n st)]
    (loop [i index]
      (when (< i (dec n))
        (aset data i (aget data (inc i)))
        (recur (inc i))))
    (aset data (dec n) nil)
    (reset! (.state d) (assoc st :n (dec n))))
  (dyn-shrink-if-sparse d))

(defn dynamic-update [^DynamicPhext d coord text overwrite?]
  (let [[index found?] (dyn-find d coord)
        st @(.state d) data (:data st)]
    (if found?
      (if (zero? (alength text))
        (when overwrite? (dyn-remove-at d index))
        (let [t (if overwrite?
                  text
                  (let [baos (ByteArrayOutputStream.)]
                    (.write baos ^bytes (:text (aget data index)))
                    (.write baos ^bytes text)
                    (.toByteArray baos)))]
          (aset data index {:coord coord :text t})))
      (when (pos? (alength text))
        (dyn-grow-if-full d)
        (let [st2 @(.state d) data2 (:data st2) n (:n st2)]
          (loop [i n]
            (when (> i index)
              (aset data2 i (aget data2 (dec i)))
              (recur (dec i))))
          (aset data2 index {:coord coord :text text})
          (reset! (.state d) (assoc st2 :n (inc n)))))))
  d)

(defn dynamic-insert [d coord text] (dynamic-update d coord text false))
(defn dynamic-replace [d coord text] (dynamic-update d coord text true))

(defn dynamic-remove [^DynamicPhext d coord]
  (let [[index found?] (dyn-find d coord)]
    (when found? (dyn-remove-at d index)))
  d)

;; ------------------------------------------------------------------
;; BranchingMap: a hash map of dimension `depth` branching into hash
;; maps of one fewer dimension, recursively, down to leaves holding
;; scroll text. One map lookup per dimension.
(deftype BranchingMap [depth root count-atom]
  Object
  (toString [_] (str "BranchingMap[depth=" depth ",count=" @count-atom "]")))

(defn make-branching-map [depth]
  (when (< depth 1) (throw (IllegalArgumentException. "depth must be >= 1")))
  (BranchingMap. depth {:children (java.util.HashMap.) :leaf (atom nil)} (atom 0)))

(defn- bm-node [] {:children (java.util.HashMap.) :leaf (atom nil)})

(defn branching-fetch [^BranchingMap m key]
  (loop [node (.root m) level 0]
    (let [child (.get ^java.util.HashMap (:children node) (nth key level))]
      (cond
        (nil? child) nil
        (= level (dec (.depth m))) @(:leaf child)
        :else (recur child (inc level))))))

(defn branching-contains? [m key] (some? (branching-fetch m key)))

(defn branching-put [^BranchingMap m key value]
  (let [created (loop [node (.root m) level 0]
                  (let [comp (nth key level)]
                    (if (= level (dec (.depth m)))
                      (let [child (or (.get ^java.util.HashMap (:children node) comp)
                                      (let [nd (bm-node)]
                                        (.put ^java.util.HashMap (:children node) comp nd)
                                        nd))
                            created (nil? @(:leaf child))]
                        (reset! (:leaf child) value)
                        created)
                      (let [child (or (.get ^java.util.HashMap (:children node) comp)
                                      (let [nd (bm-node)]
                                        (.put ^java.util.HashMap (:children node) comp nd)
                                        nd))]
                        (recur child (inc level))))))]
    (when created (swap! (.count-atom m) inc))
    created))

(defn branching-remove [^BranchingMap m key]
  (letfn [(rec [node level]
            (let [comp (nth key level)
                  child (.get ^java.util.HashMap (:children node) comp)]
              (cond
                (nil? child) false
                (= level (dec (.depth m)))
                (if (nil? @(:leaf child))
                  false
                  (do (.remove ^java.util.HashMap (:children node) comp) true))
                :else
                (let [removed (rec child (inc level))]
                  (when (and removed (.isEmpty ^java.util.HashMap (:children child))
                             (nil? @(:leaf child)))
                    (.remove ^java.util.HashMap (:children node) comp))
                  removed))))]
    (let [removed (rec (.root m) 0)]
      (when removed (swap! (.count-atom m) dec))
      removed)))

(defn branching-length [^BranchingMap m] @(.count-atom m))

(defn branching-items [^BranchingMap m]
  (let [out (java.util.ArrayList.)]
    (letfn [(rec [node prefix level]
              (doseq [comp (sort (.keySet ^java.util.HashMap (:children node)))]
                (let [child (.get ^java.util.HashMap (:children node) comp)
                      k (conj prefix comp)]
                  (if (= level (dec (.depth m)))
                    (.add out [k @(:leaf child)])
                    (rec child k (inc level))))))]
      (rec (.root m) [] 0))
    (vec out)))

;; ------------------------------------------------------------------
;; TransitivePhext: scroll store over a BranchingMap at depth 9.
(deftype TransitivePhext [map-atom]
  Object
  (toString [_] "TransitivePhext"))

(defn make-transitive
  ([] (make-transitive (byte-array 0)))
  ([buffer]
   (let [t (TransitivePhext. (atom (make-branching-map 9)))]
     (when (pos? (alength buffer)) (transitive-load t buffer))
     t)))

(defn transitive-load [^TransitivePhext t buffer]
  (reset! (.map-atom t) (make-branching-map 9))
  (doseq [ps (phokenize buffer)]
    (branching-put @(.map-atom t) (:coord ps) (:text ps)))
  t)

(defn transitive-depth [^TransitivePhext t] (.depth ^BranchingMap @(.map-atom t)))
(defn transitive-length [^TransitivePhext t] (branching-length @(.map-atom t)))

(defn transitive-scrolls [^TransitivePhext t]
  (mapv (fn [[k v]] {:coord k :text v}) (branching-items @(.map-atom t))))

(defn transitive-serialize [^TransitivePhext t]
  (dephokenize (transitive-scrolls t)))

(defn transitive-fetch [^TransitivePhext t coord]
  (let [v (branching-fetch @(.map-atom t) coord)]
    (if (nil? v) (byte-array 0) v)))

(defn transitive-contains? [^TransitivePhext t coord]
  (branching-contains? @(.map-atom t) coord))

(defn transitive-update [^TransitivePhext t coord text overwrite?]
  (if (zero? (alength text))
    (when overwrite? (branching-remove @(.map-atom t) coord))
    (if overwrite?
      (branching-put @(.map-atom t) coord text)
      (let [existing (branching-fetch @(.map-atom t) coord)]
        (branching-put @(.map-atom t) coord
                       (if (some? existing)
                         (let [baos (ByteArrayOutputStream.)]
                           (.write baos ^bytes existing)
                           (.write baos ^bytes text)
                           (.toByteArray baos))
                         text)))))
  t)

(defn transitive-insert [t coord text] (transitive-update t coord text false))
(defn transitive-replace [t coord text] (transitive-update t coord text true))
(defn transitive-remove [^TransitivePhext t coord] (branching-remove @(.map-atom t) coord) t)
(defn transitive-append [t coord text] (transitive-insert t coord text))
