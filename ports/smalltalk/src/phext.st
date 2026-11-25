"libphext-smalltalk -- phext 0.6.1 parity in Pharo Smalltalk.
Byte-oriented: scroll text is ByteArray (latin-1 semantics at the JSON
boundary, one char per byte). Break bytes: 16r01 16r1F 16r1E 16r1D
16r1C 16r1A 16r19 16r18 16r17 for dimensions 0..8 (library..scroll).
REMOVE IS COORDINATE-PRESERVING: remove drops the scroll and implode
leaves the gap (no renumbering) -- explicitly tested."

| PhextLib DynPhext TrnPhext |
PhextLib := Object subclass: #PhextLib
	instanceVariableNames: ''
	classVariableNames: 'BreakDim BreakBytes'
	package: 'LibPhext'.

PhextLib class compile: 'initialize
	BreakBytes := #(1 31 30 29 28 26 25 24 23).
	BreakDim := Array new: 257 withAll: -1.
	BreakBytes withIndexDo: [ :b :i | BreakDim at: b + 1 put: i - 1 ]'.

PhextLib class compile: 'breakDim
	BreakDim ifNil: [ self initialize ].
	^ BreakDim'.

PhextLib class compile: 'breakBytes
	BreakBytes ifNil: [ self initialize ].
	^ BreakBytes'.

PhextLib class compile: 'coordString: coord
	^ (coord at: 1) printString , ''.'' , (coord at: 2) printString , ''.'' , (coord at: 3) printString , ''/'' ,
	  (coord at: 4) printString , ''.'' , (coord at: 5) printString , ''.'' , (coord at: 6) printString , ''/'' ,
	  (coord at: 7) printString , ''.'' , (coord at: 8) printString , ''.'' , (coord at: 9) printString'.

PhextLib class compile: 'parseCoord: s
	| parts nums |
	parts := s splitOn: ''/''.
	parts size = 3 ifFalse: [ ^ nil ].
	nums := OrderedCollection new.
	parts do: [ :g |
		| gp |
		gp := g splitOn: ''.''.
		gp size = 3 ifFalse: [ ^ nil ].
		gp do: [ :n |
			(n allSatisfy: [ :ch | ch isDigit ]) ifFalse: [ ^ nil ].
			nums add: n asInteger ] ].
	nums size = 9 ifFalse: [ ^ nil ].
	(nums anySatisfy: [ :n | n < 1 ]) ifTrue: [ ^ nil ].
	^ nums asArray'.

PhextLib class compile: 'coordCompare: a with: b
	1 to: 9 do: [ :i |
		(a at: i) = (b at: i) ifFalse: [ ^ (a at: i) < (b at: i) ifTrue: [ -1 ] ifFalse: [ 1 ] ] ].
	^ 0'.

"explode: ByteArray -> Dictionary coordString -> { coord. text }"
PhextLib class compile: 'explode: data
	| dim map coord runStart i n d |
	dim := self breakDim.
	map := Dictionary new.
	coord := Array new: 9 withAll: 1.
	runStart := 0.
	i := 1.
	n := data size.
	[ i <= n ] whileTrue: [
		d := dim at: (data at: i) + 1.
		d >= 0
			ifTrue: [
				runStart > 0 ifTrue: [
					map at: (self coordString: coord)
						put: { coord copy. data copyFrom: runStart to: i - 1 }.
					runStart := 0 ].
				coord at: d + 1 put: (coord at: d + 1) + 1.
				d + 2 to: 9 do: [ :k | coord at: k put: 1 ] ]
			ifFalse: [ runStart = 0 ifTrue: [ runStart := i ] ].
		i := i + 1 ].
	runStart > 0 ifTrue: [
		map at: (self coordString: coord)
			put: { coord copy. data copyFrom: runStart to: n } ].
	^ map'.

"implode: Dictionary coordString -> {coord. text} -> ByteArray (canonical)"
PhextLib class compile: 'implode: map
	| entries out loc bb |
	bb := self breakBytes.
	entries := map values asSortedCollection: [ :a :b | (self coordCompare: a first with: b first) < 0 ].
	out := WriteStream on: ByteArray new.
	loc := Array new: 9 withAll: 1.
	entries do: [ :e |
		| coord text dim |
		coord := e first.
		text := e second.
		text size > 0 ifTrue: [
			(self coordCompare: loc with: coord) < 0 ifTrue: [
				dim := 1.
				[ (loc at: dim) = (coord at: dim) ] whileTrue: [ dim := dim + 1 ].
				out nextPutAll: (ByteArray new: (coord at: dim) - (loc at: dim) withAll: (bb at: dim)).
				dim + 1 to: 9 do: [ :k |
					(coord at: k) > 1 ifTrue: [
						out nextPutAll: (ByteArray new: (coord at: k) - 1 withAll: (bb at: k)) ] ].
				loc := coord copy ].
			out nextPutAll: text ] ].
	^ out contents'.

PhextLib class compile: 'fetch: data atCoord: coord
	| map e |
	map := self explode: data.
	e := map at: (self coordString: coord) ifAbsent: [ ^ ByteArray new ].
	^ e second'.

PhextLib class compile: 'update: data atCoord: coord text: text overwrite: ow
	| map key e |
	map := self explode: data.
	key := self coordString: coord.
	e := map at: key ifAbsent: [ nil ].
	e isNil
		ifTrue: [ text size > 0 ifTrue: [ map at: key put: { coord. text } ] ]
		ifFalse: [
			ow
				ifTrue: [ text size > 0
					ifTrue: [ map at: key put: { coord. text } ]
					ifFalse: [ map removeKey: key ] ]
				ifFalse: [ map at: key put: { coord. e second , text } ] ].
	^ self implode: map'.

PhextLib class compile: 'insert: data atCoord: coord text: text
	^ self update: data atCoord: coord text: text overwrite: false'.

PhextLib class compile: 'replace: data atCoord: coord text: text
	^ self update: data atCoord: coord text: text overwrite: true'.

PhextLib class compile: 'remove: data atCoord: coord
	| map |
	map := self explode: data.
	map removeKey: (self coordString: coord) ifAbsent: [ ].
	^ self implode: map'.

PhextLib class compile: 'normalize: data
	^ self implode: (self explode: data)'.

"---- helpers: hex, sha256 (Pharo System-Hashing SHA256), base64 (Zinc) ----"
PhextLib class compile: 'hexOf: bytes
	| hex out |
	hex := ''0123456789abcdef''.
	out := WriteStream on: String new.
	bytes do: [ :b |
		out nextPut: (hex at: (b bitShift: -4) + 1).
		out nextPut: (hex at: (b bitAnd: 15) + 1) ].
	^ out contents'.

PhextLib class compile: 'sha256Hex: bytes
	^ self hexOf: (SHA256 hashMessage: bytes)'.

PhextLib class compile: 'b64Encode: bytes
	^ ZnBase64Encoder new encode: bytes'.

PhextLib class compile: 'b64Decode: s
	^ ZnBase64Encoder new decode: s'.

"---- DynamicPhext: CLRS quarter-full dynamic array store ----"
DynPhext := Object subclass: #DynPhext
	instanceVariableNames: 'store n capacity resizeCount elementsCopied'
	classVariableNames: ''
	package: 'LibPhext'.

DynPhext compile: 'initialize
	store := Array new: 1.
	n := 0.
	capacity := 1.
	resizeCount := 0.
	elementsCopied := 0'.

DynPhext compile: 'capacity ^ capacity'.
DynPhext compile: 'resizeCount ^ resizeCount'.
DynPhext compile: 'length ^ n'.

DynPhext compile: 'resize: newCap
	| ns |
	ns := Array new: newCap.
	1 to: n do: [ :i | ns at: i put: (store at: i) ].
	store := ns.
	capacity := newCap.
	resizeCount := resizeCount + 1.
	elementsCopied := elementsCopied + n'.

DynPhext compile: 'growIfFull
	n = capacity ifTrue: [ self resize: capacity * 2 ]'.

DynPhext compile: 'shrinkIfSparse
	(capacity > 1 and: [ n <= (capacity // 4) ]) ifTrue: [
		self resize: (capacity // 2 max: 1) ]'.

DynPhext compile: 'find: coord
	"-> { index. found } binary search over coordinate order"
	| lo hi mid c |
	lo := 1.
	hi := n + 1.
	[ lo < hi ] whileTrue: [
		mid := (lo + hi) // 2.
		c := PhextLib coordCompare: (store at: mid) first with: coord.
		c < 0 ifTrue: [ lo := mid + 1 ].
		c > 0 ifTrue: [ hi := mid ].
		c = 0 ifTrue: [ ^ { mid. true } ] ].
	^ { lo. false }'.

DynPhext compile: 'pushEntry: e
	self growIfFull.
	n := n + 1.
	store at: n put: e'.

DynPhext compile: 'loadBytes: data
	| map entries |
	self initialize.
	map := PhextLib explode: data.
	entries := map values asSortedCollection: [ :a :b | (PhextLib coordCompare: a first with: b first) < 0 ].
	entries do: [ :e | self pushEntry: e ]'.

DynPhext class compile: 'fromBytes: data
	^ self new loadBytes: data; yourself'.

DynPhext compile: 'serialize
	| map |
	map := Dictionary new.
	1 to: n do: [ :i |
		| e |
		e := store at: i.
		map at: (PhextLib coordString: e first) put: e ].
	^ PhextLib implode: map'.

DynPhext compile: 'fetch: coord
	| f |
	f := self find: coord.
	^ f second ifTrue: [ (store at: f first) second ] ifFalse: [ ByteArray new ]'.

DynPhext compile: 'append: coord text: text
	(n > 0 and: [ (PhextLib coordCompare: coord with: (store at: n) first) <= 0 ])
		ifTrue: [ self error: ''append requires a coordinate past the tail'' ].
	text size = 0 ifTrue: [ ^ self ].
	self pushEntry: { coord. text }'.

DynPhext compile: 'update: coord text: text overwrite: ow
	| f idx newText |
	newText := text.
	f := self find: coord.
	idx := f first.
	f second ifTrue: [
		text size = 0 ifTrue: [
			ow ifTrue: [ self removeAt: idx ].
			^ self ].
		ow ifFalse: [ newText := (store at: idx) second , text ].
		store at: idx put: { coord. newText }.
		^ self ].
	text size = 0 ifTrue: [ ^ self ].
	self growIfFull.
	n + 1 to: idx + 1 by: -1 do: [ :i | store at: i put: (store at: i - 1) ].
	store at: idx put: { coord. text }.
	n := n + 1'.

DynPhext compile: 'insert: coord text: text
	self update: coord text: text overwrite: false'.

DynPhext compile: 'replace: coord text: text
	self update: coord text: text overwrite: true'.

DynPhext compile: 'removeAt: idx
	idx to: n - 1 do: [ :i | store at: i put: (store at: i + 1) ].
	store at: n put: nil.
	n := n - 1.
	self shrinkIfSparse'.

DynPhext compile: 'remove: coord
	| f |
	f := self find: coord.
	f second ifTrue: [ self removeAt: f first ]'.

"---- TransitivePhext: branching hash maps, one layer per dimension ----"
TrnPhext := Object subclass: #TrnPhext
	instanceVariableNames: 'root'
	classVariableNames: ''
	package: 'LibPhext'.

TrnPhext compile: 'initialize
	root := Dictionary new'.

TrnPhext compile: 'loadBytes: data
	| map |
	self initialize.
	map := PhextLib explode: data.
	map do: [ :e | self putCoord: e first text: e second ]'.

TrnPhext class compile: 'fromBytes: data
	^ self new loadBytes: data; yourself'.

TrnPhext compile: 'nodeFor: coord create: create
	| node |
	node := root.
	1 to: 8 do: [ :d |
		| k |
		k := coord at: d.
		node := node at: k ifAbsent: [
			create ifTrue: [ node at: k put: Dictionary new ] ifFalse: [ ^ nil ] ] ].
	^ node'.

TrnPhext compile: 'putCoord: coord text: text
	| leaf |
	leaf := self nodeFor: coord create: true.
	leaf at: (coord at: 9) put: text'.

TrnPhext compile: 'fetch: coord
	| leaf |
	leaf := self nodeFor: coord create: false.
	leaf isNil ifTrue: [ ^ ByteArray new ].
	^ leaf at: (coord at: 9) ifAbsent: [ ByteArray new ]'.

TrnPhext compile: 'update: coord text: text overwrite: ow
	| cur newText |
	cur := self fetch: coord.
	newText := text.
	text size = 0 ifTrue: [
		ow ifTrue: [ self remove: coord ].
		^ self ].
	ow ifFalse: [ newText := cur , text ].
	self putCoord: coord text: newText'.

TrnPhext compile: 'insert: coord text: text
	self update: coord text: text overwrite: false'.

TrnPhext compile: 'replace: coord text: text
	self update: coord text: text overwrite: true'.

TrnPhext compile: 'remove: coord
	| leaf |
	leaf := self nodeFor: coord create: false.
	leaf isNil ifFalse: [ leaf removeKey: (coord at: 9) ifAbsent: [ ] ]'.

TrnPhext compile: 'length
	| count |
	count := 0.
	self allEntriesDo: [ :e | count := count + 1 ].
	^ count'.

TrnPhext compile: 'allEntriesDo: block
	| walk |
	walk := nil.
	walk := [ :node :depth :prefix |
		depth = 9
			ifTrue: [ node keysAndValuesDo: [ :k :v | block value: { prefix , { k }. v } ] ]
			ifFalse: [ node keysAndValuesDo: [ :k :v | walk value: v value: depth + 1 value: prefix , { k } ] ] ].
	walk value: root value: 1 value: #()'.

TrnPhext compile: 'serialize
	| map |
	map := Dictionary new.
	self allEntriesDo: [ :e | map at: (PhextLib coordString: e first) put: e ].
	^ PhextLib implode: map'.

PhextLib initialize.
