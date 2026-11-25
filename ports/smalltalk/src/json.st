"Minimal JSON reader + canonical writer for libphext-smalltalk.
Canonical form matches Python json.dumps(sort_keys, separators,
ensure_ascii=True): keys sorted, no spaces, strings escaped with
\uXXXX for control and non-ASCII characters."

| JsonRdr JsonWtr |
JsonRdr := Object subclass: #JsonRdr
	instanceVariableNames: 's pos'
	classVariableNames: ''
	package: 'LibPhext'.

JsonRdr class compile: 'parse: str
	^ self new parseTop: str'.

JsonRdr compile: 'parseTop: str
	s := str.
	pos := 1.
	^ self value'.

JsonRdr compile: 'ws
	[ pos <= s size and: [ (s at: pos) isSeparator ] ] whileTrue: [ pos := pos + 1 ]'.

JsonRdr compile: 'value
	self ws.
	^ (s at: pos) = ${
		ifTrue: [ self object ]
		ifFalse: [ (s at: pos) = $[
			ifTrue: [ self array ]
			ifFalse: [ (s at: pos) = $"
				ifTrue: [ self string ]
				ifFalse: [ self literal ] ] ]'.

JsonRdr compile: 'object
	| d |
	d := Dictionary new.
	pos := pos + 1.
	self ws.
	(s at: pos) = $} ifTrue: [ pos := pos + 1. ^ d ].
	[ true ] whileTrue: [
		| k v |
		self ws.
		k := self string.
		self ws.
		pos := pos + 1.
		v := self value.
		d at: k put: v.
		self ws.
		(s at: pos) = $} ifTrue: [ pos := pos + 1. ^ d ].
		pos := pos + 1 ]'.

JsonRdr compile: 'array
	| a |
	a := OrderedCollection new.
	pos := pos + 1.
	self ws.
	(s at: pos) = $] ifTrue: [ pos := pos + 1. ^ a asArray ].
	[ true ] whileTrue: [
		a add: self value.
		self ws.
		(s at: pos) = $] ifTrue: [ pos := pos + 1. ^ a asArray ].
		pos := pos + 1 ]'.

JsonRdr compile: 'hex4: from
	| v |
	v := 0.
	from to: from + 3 do: [ :i |
		| c |
		c := s at: i.
		v := v * 16 + (c isDigit
			ifTrue: [ c digitValue ]
			ifFalse: [ (c asUppercase asciiValue) - 55 ]) ].
	^ v'.

JsonRdr compile: 'string
	| out |
	out := WriteStream on: String new.
	pos := pos + 1.
	[ (s at: pos) = $" ] whileFalse: [
		| ch |
		ch := s at: pos.
		ch = $\
			ifTrue: [
				| e |
				pos := pos + 1.
				e := s at: pos.
				e = $n ifTrue: [ out nextPut: Character lf ].
				e = $t ifTrue: [ out nextPut: Character tab ].
				e = $r ifTrue: [ out nextPut: Character cr ].
				e = $b ifTrue: [ out nextPut: (Character value: 8) ].
				e = $f ifTrue: [ out nextPut: (Character value: 12) ].
				e = $/ ifTrue: [ out nextPut: $/ ].
				e = $\ ifTrue: [ out nextPut: $\ ].
				e = $" ifTrue: [ out nextPut: $" ].
				e = $u ifTrue: [
					| cp |
					cp := self hex4: pos + 1.
					pos := pos + 4.
					(cp between: 55296 and: 56319) ifTrue: [
						| lo |
						lo := self hex4: pos + 3.
						cp := 65536 + ((cp - 55296) * 1024) + (lo - 56320).
						pos := pos + 6 ].
					out nextPut: (Character value: cp) ].
				pos := pos + 1 ]
			ifFalse: [
				out nextPut: ch.
				pos := pos + 1 ] ].
	pos := pos + 1.
	^ out contents'.

JsonRdr compile: 'literal
	| rest |
	rest := s copyFrom: pos to: s size.
	(rest beginsWith: ''true'') ifTrue: [ pos := pos + 4. ^ true ].
	(rest beginsWith: ''false'') ifTrue: [ pos := pos + 5. ^ false ].
	(rest beginsWith: ''null'') ifTrue: [ pos := pos + 4. ^ nil ].
	^ self number'.

JsonRdr compile: 'number
	| start tok |
	start := pos.
	[ pos <= s size and: [ ''-0123456789.eE+'' includes: (s at: pos) ] ] whileTrue: [ pos := pos + 1 ].
	tok := s copyFrom: start to: pos - 1.
	((tok includes: $.) or: [ (tok includes: $e) or: [ tok includes: $E ] ])
		ifTrue: [ ^ tok asNumber ]
		ifFalse: [ ^ tok asInteger ]'.

JsonWtr := Object subclass: #JsonWtr
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'LibPhext'.

JsonWtr class compile: 'write: v
	| out |
	out := WriteStream on: String new.
	self write: v into: out.
	^ out contents'.

JsonWtr class compile: 'uEscape: cp into: out
	| hex d |
	hex := ''0123456789abcdef''.
	out nextPutAll: ''\u''.
	4 to: 1 by: -1 do: [ :i |
		d := (cp bitShift: (i - 1) * -4) bitAnd: 15.
		out nextPut: (hex at: d + 1) ]'.

JsonWtr class compile: 'writeString: str into: out
	out nextPut: $".
	str do: [ :ch |
		| cp |
		cp := ch asciiValue.
		cp = 34 ifTrue: [ out nextPutAll: ''\"'' ] ifFalse: [
		cp = 92 ifTrue: [ out nextPutAll: ''\\'' ] ifFalse: [
		cp = 8 ifTrue: [ out nextPutAll: ''\b'' ] ifFalse: [
		cp = 9 ifTrue: [ out nextPutAll: ''\t'' ] ifFalse: [
		cp = 10 ifTrue: [ out nextPutAll: ''\n'' ] ifFalse: [
		cp = 12 ifTrue: [ out nextPutAll: ''\f'' ] ifFalse: [
		cp = 13 ifTrue: [ out nextPutAll: ''\r'' ] ifFalse: [
		(cp < 32 or: [ cp > 126 ])
			ifTrue: [
				cp > 65535
					ifTrue: [
						| v |
						v := cp - 65536.
						self uEscape: 55296 + (v bitShift: -10) into: out.
						self uEscape: 56320 + (v bitAnd: 1023) into: out ]
					ifFalse: [ self uEscape: cp into: out ] ]
			ifFalse: [ out nextPut: ch ] ] ] ] ] ] ] ] ].
	out nextPut: $"'.

JsonWtr class compile: 'write: v into: out
	v isNil ifTrue: [ out nextPutAll: ''null''. ^ self ].
	v = true ifTrue: [ out nextPutAll: ''true''. ^ self ].
	v = false ifTrue: [ out nextPutAll: ''false''. ^ self ].
	(v isKindOf: Number) ifTrue: [ out nextPutAll: v printString. ^ self ].
	(v isKindOf: String) ifTrue: [ self writeString: v into: out. ^ self ].
	(v isKindOf: Dictionary) ifTrue: [
		| keys |
		keys := v keys asSortedCollection.
		out nextPut: ${.
		keys withIndexDo: [ :k :i |
			i > 1 ifTrue: [ out nextPut: $, ].
			self writeString: k into: out.
			out nextPut: $:.
			self write: (v at: k) into: out ].
		out nextPut: $}.
		^ self ].
	(v isKindOf: SequenceableCollection) ifTrue: [
		out nextPut: $[.
		v withIndexDo: [ :e :i |
			i > 1 ifTrue: [ out nextPut: $, ].
			self write: e into: out ].
		out nextPut: $].
		^ self ].
	self error: ''unwritable json value'''.
