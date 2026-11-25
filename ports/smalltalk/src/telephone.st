"libphext-smalltalk -- contract-v2 adapter CLI in Pharo Smalltalk.
Stateless: one invocation handles one request file and writes one
response file; the hub runner owns GZ1 framing and the port
GNUPGHOME. Mirrors the mojo/hack CLI semantics with impl smalltalk."

| TelephoneCli TelSuite |
TelephoneCli := Object subclass: #TelephoneCli
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'LibPhext'.

TelSuite := Object subclass: #TelSuite
	instanceVariableNames: 'checks failures'
	classVariableNames: ''
	package: 'LibPhext'.

"---------------------------------------------------------------- run"
TelephoneCli class compile: 'run
	| args |
	args := Smalltalk arguments.
	args size >= 2 ifTrue: [
		(args at: 2) = ''test''
			ifTrue: [ TelSuite run: (args size >= 3 ifTrue: [ args at: 3 ] ifFalse: [ '''' ]) ]
			ifFalse: [ self processReq: (args at: 2) resp: (args at: 3) ] ].
	Smalltalk snapshot: false andQuit: true'.

TelephoneCli class compile: 'processReq: reqPath resp: respPath
	| raw line resp |
	raw := self readBytes: reqPath.
	line := self trimTrailLf: raw.
	resp := [ self handle: (JsonRdr parse: line asString) ]
		on: Exception
		do: [ :e | JsonWtr write: (Dictionary new
			at: ''error'' put: ''smalltalk: handler exception'';
			yourself) ].
	self writeBytes: respPath bytes: (resp , (String with: Character lf)) asByteArray'.

"---------------------------------------------------------------- io"
TelephoneCli class compile: 'readBytes: path
	| s |
	s := path asFileReference binaryReadStream.
	^ [ s upToEnd ] ensure: [ s close ]'.

TelephoneCli class compile: 'writeBytes: path bytes: bytes
	| s |
	path asFileReference deleteIfAbsent: [ ].
	s := path asFileReference binaryWriteStream.
	[ s nextPutAll: bytes ] ensure: [ s close ]'.

TelephoneCli class compile: 'trimTrailLf: b
	| n |
	n := b size.
	[ n > 0 and: [ (b at: n) = 10 ] ] whileTrue: [ n := n - 1 ].
	^ b copyFrom: 1 to: n'.

TelephoneCli class compile: 'trimBoth: s
	^ s trimBoth'.

"---------------------------------------------------------------- shell"
TelephoneCli class compile: 'shq: s
	| out esc |
	esc := String with: $'' with: $\ with: $'' with: $''.
	out := WriteStream on: String new.
	out nextPut: $''.
	s do: [ :ch |
		ch = $''
			ifTrue: [ out nextPutAll: esc ]
			ifFalse: [ out nextPut: ch ] ].
	out nextPut: $''.
	^ out contents'.

TelephoneCli class compile: 'shell: cmd
	^ LibC system: (''('' , cmd , '') >/dev/null 2>&1'')'.

TelephoneCli class compile: 'shellOut: cmd
	| tp data |
	tp := self tmpbase , ''.out''.
	LibC system: cmd , '' > '' , tp , '' 2>/dev/null''.
	data := [ self readBytes: tp ] on: Exception do: [ :e | ByteArray new ].
	LibC system: ''rm -f '' , tp.
	^ data asString'.

TelephoneCli class compile: 'tmpbase
	^ ''/tmp/telephone-smalltalk-'' , DateAndTime now asUnixTime printString
		, ''-'' , Time millisecondClockValue printString'.

"---------------------------------------------------------------- gpg"
TelephoneCli class compile: 'gpgBase
	^ ''gpg --batch --yes --pinentry-mode loopback --passphrase '' , (String with: $'' with: $'') , '' '''.

TelephoneCli class compile: 'keygen
	| listing pub |
	listing := self shellOut: self gpgBase , ''--list-keys --with-colons''.
	(listing includesSubstring: ''pub:'') ifFalse: [
		self shell: self gpgBase , ''--quick-generate-key '' , (self shq: ''telephone-smalltalk'') , '' ed25519 sign never'' ].
	pub := self shellOut: self gpgBase , ''--armor --export '' , (self shq: ''telephone-smalltalk'').
	(pub isEmpty or: [ pub last = Character lf ]) ifFalse: [ pub := pub , (String with: Character lf) ].
	^ JsonWtr write: (Dictionary new
		at: ''impl'' put: ''smalltalk'';
		at: ''pubkey'' put: pub;
		yourself)'.

TelephoneCli class compile: 'attest: descriptor
	| dp sp sig |
	dp := self tmpbase , ''.desc''.
	sp := self tmpbase , ''.sig''.
	self writeBytes: dp bytes: (JsonWtr write: descriptor) asByteArray.
	self shell: self gpgBase , ''--detach-sign --armor -u '' , (self shq: ''telephone-smalltalk'') , '' -o '' , (self shq: sp) , '' '' , (self shq: dp).
	sig := [ (self readBytes: sp) asString ] on: Exception do: [ :e | '''' ].
	self shell: ''rm -f '' , dp , '' '' , sp.
	^ JsonWtr write: (Dictionary new
		at: ''signature'' put: sig;
		yourself)'.

TelephoneCli class compile: 'verifySignature: pubkeys data: data sig: sigArmored
	| td base ok |
	td := self tmpbase , ''.vfy''.
	self shell: ''mkdir -p '' , td , ''/gnupg''.
	self shell: ''chmod 700 '' , td , ''/gnupg''.
	self writeBytes: td , ''/keys.asc'' bytes: pubkeys asByteArray.
	self writeBytes: td , ''/data'' bytes: data asByteArray.
	self writeBytes: td , ''/sig.asc'' bytes: sigArmored asByteArray.
	base := ''GNUPGHOME='' , (self shq: td , ''/gnupg'') , '' gpg --batch --yes ''.
	ok := false.
	(self shell: base , ''--import '' , (self shq: td , ''/keys.asc'')) = 0 ifTrue: [
		ok := (self shell: base , ''--verify '' , (self shq: td , ''/sig.asc'') , '' '' , (self shq: td , ''/data'')) = 0 ].
	self shell: ''rm -rf '' , td.
	^ ok'.

"---------------------------------------------------------------- game"
TelephoneCli class compile: 'reqState: req
	| v |
	v := req at: ''state'' ifAbsent: [ req at: ''state_b64'' ifAbsent: [ nil ] ].
	v ifNil: [ ^ ByteArray new ].
	^ PhextLib b64Decode: v'.

TelephoneCli class compile: 'jstr: v
	v isString ifTrue: [ ^ v ].
	v isInteger ifTrue: [ ^ v printString ].
	^ '''''.

TelephoneCli class compile: 'echoValue: ping
	| game round nonce |
	game := self jstr: (ping at: ''game'' ifAbsent: [ '''' ]).
	round := self jstr: (ping at: ''round'' ifAbsent: [ ping at: ''turn'' ifAbsent: [ '''' ] ]).
	nonce := self jstr: (ping at: ''nonce'' ifAbsent: [ '''' ]).
	^ PhextLib sha256Hex: (''smalltalk|'' , game , ''|'' , round , ''|'' , nonce) asByteArray'.

TelephoneCli class compile: 'elect: req
	| pos turn cands joined hb |
	pos := req at: ''position'' ifAbsent: [ '''' ].
	turn := req at: ''turn'' ifAbsent: [ 0 ].
	cands := req at: ''candidates'' ifAbsent: [ OrderedCollection new ].
	cands isEmpty ifTrue: [ ^ ''smalltalk'' ].
	joined := ''''.
	cands do: [ :c | joined = '''' ifFalse: [ joined := joined , '','' ]. joined := joined , c ].
	hb := SHA256 hashMessage: (pos , ''|'' , turn printString , ''|'' , joined) asByteArray.
	^ cands at: ((hb at: 1) \\ cands size) + 1'.

TelephoneCli class compile: 'wrap999: x
	^ 1 + (((x - 1) \\ 999) + 999 \\ 999)'.

TelephoneCli class compile: 'nextCoord: c
	| out d |
	out := c copy.
	d := 9.
	[ d >= 1 ] whileTrue: [
		(out at: d) < 999 ifTrue: [ out at: d put: (out at: d) + 1. ^ out ].
		out at: d put: 1.
		d := d - 1 ].
	^ out'.

TelephoneCli class compile: 'choose: req
	| state posS turn pv sc hb dim bump cand reserved used cs |
	state := self reqState: req.
	posS := req at: ''position''.
	turn := req at: ''turn''.
	pv := PhextLib parseCoord: posS.
	sc := PhextLib explode: state.
	hb := SHA256 hashMessage: ((posS , ''|'' , turn printString , ''|'') asByteArray , state).
	dim := ((hb at: 2) \\ 9) + 1.
	bump := 1 + ((hb at: 3) \\ 3).
	cand := pv copy.
	cand at: dim put: (self wrap999: ((cand at: dim) + bump)).
	reserved := { #(1 1 1 1 1 1 1 1 1). #(1 1 1 1 1 1 1 1 2). #(1 1 1 1 1 1 1 1 3) }.
	used := true.
	[ used ] whileTrue: [
		used := false.
		sc valuesDo: [ :e | (PhextLib coordCompare: e first with: cand) = 0 ifTrue: [ used := true ] ].
		used ifFalse: [
			reserved do: [ :r | (PhextLib coordCompare: r with: cand) = 0 ifTrue: [ used := true ] ] ].
		used ifTrue: [ cand := self nextCoord: cand ] ].
	cs := PhextLib coordString: cand.
	^ JsonWtr write: (Dictionary new
		at: ''coordinate'' put: cs;
		at: ''op'' put: ''insert'';
		at: ''text'' put: ''smalltalk turn '' , turn printString , '' at '' , cs;
		yourself)'.

TelephoneCli class compile: 'apply: req
	| state step op cs text coord new |
	state := self reqState: req.
	step := req at: ''step''.
	op := step at: ''op''.
	cs := step at: ''coordinate''.
	text := (step at: ''text'' ifAbsent: [ '''' ]) asByteArray.
	coord := PhextLib parseCoord: cs.
	op = ''fetch'' ifTrue: [
		^ JsonWtr write: (Dictionary new
			at: ''fetch_sha256'' put: (PhextLib sha256Hex: (PhextLib fetch: state atCoord: coord));
			at: ''state_b64'' put: (PhextLib b64Encode: state);
			at: ''state_sha256'' put: (PhextLib sha256Hex: state);
			yourself) ].
	coord ifNil: [ ^ JsonWtr write: (Dictionary new at: ''error'' put: ''bad coordinate''; yourself) ].
	op = ''insert'' ifTrue: [ new := PhextLib insert: state atCoord: coord text: text ].
	op = ''replace'' ifTrue: [ new := PhextLib replace: state atCoord: coord text: text ].
	op = ''remove'' ifTrue: [ new := PhextLib remove: state atCoord: coord ].
	new ifNil: [ ^ JsonWtr write: (Dictionary new at: ''error'' put: ''unknown step op''; yourself) ].
	^ JsonWtr write: (Dictionary new
		at: ''fetch_sha256'' put: nil;
		at: ''state_b64'' put: (PhextLib b64Encode: new);
		at: ''state_sha256'' put: (PhextLib sha256Hex: new);
		yourself)'.

TelephoneCli class compile: 'indexCoord
	^ #(1 1 1 1 1 1 1 1 1)'.

TelephoneCli class compile: 'keysCoord
	^ #(1 1 1 1 1 1 1 1 2)'.

TelephoneCli class compile: 'khCoord
	^ #(1 1 1 1 1 1 1 1 3)'.

TelephoneCli class compile: 'vfail: detail
	^ JsonWtr write: (Dictionary new
		at: ''detail'' put: detail;
		at: ''impl'' put: ''smalltalk'';
		at: ''verdict'' put: ''fail'';
		yourself)'.

TelephoneCli class compile: 'validate: req
	| step op state priorB64 |
	step := req at: ''step''.
	op := step at: ''op''.
	state := self reqState: req.
	priorB64 := req at: ''prior_state'' ifAbsent: [ nil ].
	priorB64 ifNil: [ ^ self vfail: ''validate called before init'' ].
	(req at: ''event_coord'' ifAbsent: [ nil ]) ifNotNil: [
		^ self validateDriver: req step: step state: state prior: (PhextLib b64Decode: priorB64) ].
	^ self validatePrior: req step: step state: state prior: (PhextLib b64Decode: priorB64)'.

TelephoneCli class compile: 'validatePrior: req step: step state: state prior: prior
	| cs coord text smp pmp |
	(step at: ''op'') = ''insert'' ifFalse: [ ^ self vfail: ''step op is not insert'' ].
	cs := step at: ''coordinate''.
	coord := PhextLib parseCoord: cs.
	text := (step at: ''text'') asByteArray.
	smp := PhextLib explode: state.
	pmp := PhextLib explode: prior.
	((smp at: cs ifAbsent: [ nil ]) isNil or: [ ((smp at: cs) second) ~= text ])
		ifTrue: [ ^ self vfail: ''placed scroll absent or content differs at '' , cs ].
	(pmp includesKey: cs) ifTrue: [ ^ self vfail: ''coordinate was not unused in the prior state'' ].
	smp size = (pmp size + 1) ifFalse: [ ^ self vfail: ''scroll count did not grow by exactly one'' ].
	pmp valuesDo: [ :e |
		((smp at: (PhextLib coordString: e first)) second) ~= e second
			ifTrue: [ ^ self vfail: ''a prior scroll was overwritten: '' , (PhextLib coordString: e first) ] ].
	^ JsonWtr write: (Dictionary new
		at: ''detail'' put: ''placed at unused coordinate; all prior scrolls intact'';
		at: ''impl'' put: ''smalltalk'';
		at: ''verdict'' put: ''pass'';
		yourself)'.

TelephoneCli class compile: 'validateDriver: req step: step state: state prior: prior
	| cs coord ev indexLine text newSc oldSc idx a b |
	cs := step at: ''coordinate''.
	coord := PhextLib parseCoord: cs.
	ev := PhextLib parseCoord: (req at: ''event_coord'').
	indexLine := req at: ''index_line''.
	text := (step at: ''text'') asByteArray.
	newSc := PhextLib explode: state.
	oldSc := PhextLib explode: prior.
	((newSc at: cs ifAbsent: [ nil ]) isNil or: [ ((newSc at: cs) second) ~= text ])
		ifTrue: [ ^ self vfail: ''placed scroll missing or altered'' ].
	oldSc valuesDo: [ :e |
		| c |
		c := e first.
		(PhextLib coordCompare: c with: self indexCoord) = 0 ifFalse: [
			((newSc includesKey: (PhextLib coordString: c)) not or:
				[ ((newSc at: (PhextLib coordString: c)) second) ~= e second ])
				ifTrue: [ ^ self vfail: ''prior scroll overwritten at '' , (PhextLib coordString: c) ] ] ].
	newSc valuesDo: [ :e |
		| c |
		c := e first.
		((oldSc includesKey: (PhextLib coordString: c)) not and:
			[ (PhextLib coordCompare: c with: coord) ~= 0 and:
				[ (PhextLib coordCompare: c with: ev) ~= 0 ] ])
			ifTrue: [ ^ self vfail: ''unexpected new scroll at '' , (PhextLib coordString: c) ] ].
	idx := (newSc at: (PhextLib coordString: self indexCoord) ifAbsent: [ { self indexCoord. ByteArray new } ]) second.
	a := self trimTrailLf: idx.
	b := self trimTrailLf: indexLine asByteArray.
	(b size > a size or: [ (a copyFrom: a size - b size + 1 to: a size) ~= b ])
		ifTrue: [ ^ self vfail: ''index does not record the placement'' ].
	^ JsonWtr write: (Dictionary new
		at: ''impl'' put: ''smalltalk'';
		at: ''verdict'' put: ''pass'';
		yourself)'.

"---------------------------------------------------------------- verify"
TelephoneCli class compile: 'vfail2: n msg: msg
	^ JsonWtr write: (Dictionary new
		at: ''first_failure'' put: (Dictionary new at: ''detail'' put: msg; yourself);
		at: ''impl'' put: ''smalltalk'';
		at: ''placements_checked'' put: n;
		at: ''verdict'' put: ''fail'';
		yourself)'.

TelephoneCli class compile: 'splitLines: b
	| out start i |
	out := OrderedCollection new.
	start := 1.
	i := 1.
	[ i <= b size ] whileTrue: [
		(b at: i) = 10 ifTrue: [
			out add: (b copyFrom: start to: i - 1).
			start := i + 1 ].
		i := i + 1 ].
	start <= b size ifTrue: [ out add: (b copyFrom: start to: b size) ].
	^ out'.

TelephoneCli class compile: 'verify: req
	| state pubkeys sc keysText kh idxLines events seqs prevHash seen checked |
	state := self reqState: req.
	pubkeys := req at: ''pubkeys''.
	sc := PhextLib explode: state.
	keysText := (sc at: (PhextLib coordString: self keysCoord) ifAbsent: [ nil ]).
	keysText ifNil: [ ^ self vfail2: 0 msg: ''no public-keys scroll at 1.1.1/1.1.1/1.1.2'' ].
	keysText := keysText second.
	(self trimBoth: pubkeys) = (self trimBoth: keysText asString)
		ifFalse: [ ^ self vfail2: 0 msg: ''supplied pubkeys do not match the inscribed keys scroll'' ].
	kh := (sc at: (PhextLib coordString: self khCoord) ifAbsent: [ nil ]).
	kh ifNil: [ ^ self vfail2: 0 msg: ''no keys-hash scroll at 1.1.1/1.1.1/1.1.3'' ].
	kh := kh second.
	(self trimBoth: kh asString) = (PhextLib sha256Hex: keysText)
		ifFalse: [ ^ self vfail2: 0 msg: ''keys-hash scroll does not match the keys scroll'' ].
	idxLines := OrderedCollection new.
	(self splitLines: (sc at: (PhextLib coordString: self indexCoord) ifAbsent: [ { self indexCoord. ByteArray new } ]) second) do: [ :ln |
		(ln isEmpty or: [ ln first = 35 ]) ifFalse: [ idxLines add: ln asString ] ].
	events := Dictionary new.
	sc valuesDo: [ :e |
		| c |
		c := e first.
		((c at: 1) = 1 and: [ (c at: 2) = 1 and: [ (c at: 3) = 1 and: [ (c at: 4) = 1 and: [ (c at: 5) = 1 and: [ (c at: 6) = 1 and: [ (c at: 7) = 2 and: [ (c at: 8) = 1 ] ] ] ] ] ] ])
			ifTrue: [ events at: (c at: 9) put: e second ] ].
	seqs := events keys asSortedCollection.
	prevHash := nil.
	seen := Set new.
	checked := 0.
	seqs withIndexDo: [ :seq :evIdx |
		| ev body pv cs textHash fileHash attB64 turnN actor pcoord desc sig foundIdx |
		seq = evIdx ifFalse: [ ^ self vfail2: checked msg: ''event seq gap at '' , seq printString ].
		ev := JsonRdr parse: (events at: seq) asString.
		body := ev at: ''body'' ifAbsent: [ nil ].
		body ifNil: [ ^ self vfail2: checked msg: ''event '' , seq printString , '' lacks a body object'' ].
		(ev includesKey: ''prev'') ifFalse: [ ^ self vfail2: checked msg: ''event '' , seq printString , '' lacks prev'' ].
		pv := ev at: ''prev''.
		seq = 1
			ifTrue: [ pv ifNotNil: [ ^ self vfail2: checked msg: ''event 1 prev is not null'' ] ]
			ifFalse: [ pv = prevHash ifFalse: [ ^ self vfail2: checked msg: ''event chain broken at seq '' , seq printString ] ].
		prevHash := PhextLib sha256Hex: (JsonWtr write: body) asByteArray.
		(body at: ''type'' ifAbsent: [ '''' ]) = ''placement'' ifTrue: [
			cs := body at: ''coord''.
			textHash := body at: ''text_sha256''.
			fileHash := body at: ''file_sha256''.
			attB64 := body at: ''att''.
			turnN := body at: ''turn''.
			actor := body at: ''actor''.
			(seen includes: cs) ifTrue: [ ^ self vfail2: checked msg: ''coordinate reused at '' , cs ].
			pcoord := PhextLib parseCoord: cs.
			(sc includesKey: cs) ifFalse: [ ^ self vfail2: checked msg: ''placement missing at '' , cs ].
			(PhextLib sha256Hex: (sc at: cs) second) = textHash
				ifFalse: [ ^ self vfail2: checked msg: ''placement hash mismatch at '' , cs ].
			foundIdx := false.
			idxLines do: [ :ln |
				| f |
				f := ln splitOn: '' ''.
				(f size = 4 and: [ (f at: 2) = cs ]) ifTrue: [
					foundIdx := true.
					((f at: 3) = textHash and: [ (f at: 1) = turnN printString and: [ (f at: 4) = actor ] ])
						ifFalse: [ ^ self vfail2: checked msg: ''index mismatch at '' , cs ] ] ].
			foundIdx ifFalse: [ ^ self vfail2: checked msg: ''index mismatch at '' , cs ].
			desc := JsonWtr write: (Dictionary new
				at: ''coordinate'' put: cs;
				at: ''file_sha256'' put: fileHash;
				at: ''scroll_sha256'' put: textHash;
				at: ''turn'' put: turnN;
				yourself).
			sig := PhextLib b64Decode: attB64.
			(self verifySignature: pubkeys data: desc sig: sig asString)
				ifFalse: [ ^ self vfail2: checked msg: ''event '' , seq printString , '' signature: gpg verify failed'' ].
			seen add: cs.
			checked := checked + 1 ] ].
	checked = 0 ifTrue: [ ^ self vfail2: 0 msg: ''no placement events found'' ].
	idxLines size = checked ifFalse: [ ^ self vfail2: checked msg: ''index lines differ from placements'' ].
	^ JsonWtr write: (Dictionary new
		at: ''first_failure'' put: nil;
		at: ''impl'' put: ''smalltalk'';
		at: ''placements_checked'' put: checked;
		at: ''verdict'' put: ''pass'';
		yourself)'.

"---------------------------------------------------------------- handle"
TelephoneCli class compile: 'handle: req
	| cmd |
	cmd := req at: ''cmd'' ifAbsent: [ '''' ].
	cmd = ''id'' ifTrue: [ ^ JsonWtr write: (Dictionary new at: ''impl'' put: ''smalltalk''; yourself) ].
	cmd = ''echo'' ifTrue: [
		^ JsonWtr write: (Dictionary new
			at: ''echo'' put: (self echoValue: (req at: ''ping'' ifAbsent: [ Dictionary new ]));
			at: ''impl'' put: ''smalltalk'';
			yourself) ].
	cmd = ''elect'' ifTrue: [
		^ JsonWtr write: (Dictionary new at: ''elect'' put: (self elect: req); yourself) ].
	cmd = ''choose'' ifTrue: [ ^ self choose: req ].
	cmd = ''apply'' ifTrue: [ ^ self apply: req ].
	cmd = ''keygen'' ifTrue: [ ^ self keygen ].
	cmd = ''attest'' ifTrue: [ ^ self attest: (req at: ''descriptor'') ].
	cmd = ''init'' ifTrue: [
		PhextLib explode: (self reqState: req).
		^ JsonWtr write: (Dictionary new
			at: ''impl'' put: ''smalltalk'';
			at: ''verdict'' put: ''pass'';
			yourself) ].
	cmd = ''validate'' ifTrue: [ ^ self validate: req ].
	cmd = ''verify'' ifTrue: [ ^ self verify: req ].
	^ JsonWtr write: (Dictionary new at: ''error'' put: ''unknown cmd '' , cmd; yourself)'.

"---------------------------------------------------------------- suite"
TelSuite compile: 'ok: cond name: name
	checks := checks + 1.
	cond ifFalse: [
		failures := failures + 1.
		Stdio stdout nextPutAll: ''FAIL: '' , name; lf; flush ]'.

TelSuite class compile: 'run: dir
	| s |
	s := self new.
	s runAll: dir.
	^ s'.

TelSuite compile: 'initialize
	checks := 0.
	failures := 0'.

TelSuite compile: 'runAll: fixturesDir
	| out c1 c2 c3 far d d2 dyn trn cap listing paths identical idem |
	out := Stdio stdout.
	c1 := #(1 1 1 1 1 1 1 1 1).
	c2 := #(1 1 1 1 1 1 1 1 2).
	c3 := #(1 1 1 1 1 1 1 2 1).
	far := #(3 1 4 1 5 9 2 6 5).
	self ok: (PhextLib coordString: far) = ''3.1.4/1.5.9/2.6.5'' name: ''coord format''.
	self ok: (PhextLib parseCoord: ''3.1.4/1.5.9/2.6.5'') = far name: ''coord parse''.
	self ok: (PhextLib parseCoord: ''1.2/3.4/5.6'') isNil name: ''coord parse rejects''.
	self ok: ((PhextLib coordCompare: c1 with: c2) < 0) name: ''coord compare''.
	self ok: (PhextLib explode: ByteArray new) isEmpty name: ''explode empty''.
	d := PhextLib insert: ByteArray new atCoord: c1 text: ''alpha'' asByteArray.
	self ok: d = ''alpha'' asByteArray name: ''insert into empty''.
	self ok: (PhextLib fetch: d atCoord: c1) = ''alpha'' asByteArray name: ''fetch''.
	self ok: (PhextLib fetch: d atCoord: c2) isEmpty name: ''fetch missing''.
	d := PhextLib insert: d atCoord: c1 text: ''beta'' asByteArray.
	self ok: (PhextLib fetch: d atCoord: c1) = ''alphabeta'' asByteArray name: ''insert appends''.
	d := PhextLib replace: d atCoord: c1 text: ''gamma'' asByteArray.
	self ok: (PhextLib fetch: d atCoord: c1) = ''gamma'' asByteArray name: ''replace overwrites''.
	d2 := PhextLib replace: d atCoord: c1 text: ByteArray new.
	self ok: d2 isEmpty name: ''replace empty deletes''.
	d := PhextLib insert: ByteArray new atCoord: c2 text: ''second'' asByteArray.
	d := PhextLib insert: d atCoord: c1 text: ''first'' asByteArray.
	self ok: (PhextLib fetch: d atCoord: c1) = ''first'' asByteArray name: ''two scrolls a''.
	self ok: (PhextLib fetch: d atCoord: c2) = ''second'' asByteArray name: ''two scrolls b''.
	self ok: (PhextLib normalize: d) = d name: ''normalize idempotent (small)''.
	d := PhextLib insert: ByteArray new atCoord: c1 text: ''one'' asByteArray.
	d := PhextLib insert: d atCoord: c2 text: ''two'' asByteArray.
	d := PhextLib insert: d atCoord: c3 text: ''three'' asByteArray.
	d := PhextLib remove: d atCoord: c2.
	self ok: (PhextLib fetch: d atCoord: c2) isEmpty name: ''remove drops the scroll''.
	self ok: (PhextLib fetch: d atCoord: c3) = ''three'' asByteArray name: ''remove is coordinate-preserving (gap kept)''.
	self ok: (PhextLib fetch: d atCoord: c1) = ''one'' asByteArray name: ''remove keeps neighbours''.
	self ok: (PhextLib explode: d) size = 2 name: ''gap survives explode after remove''.
	d := PhextLib insert: ByteArray new atCoord: far text: ''far away'' asByteArray.
	self ok: (PhextLib fetch: d atCoord: far) = ''far away'' asByteArray name: ''far coordinate''.
	self ok: (PhextLib normalize: d) = d name: ''far normalize idempotent''.
	self ok: (PhextLib sha256Hex: ''abc'' asByteArray) = ''ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'' name: ''sha256 vector''.
	self ok: (PhextLib b64Encode: ''hello world'' asByteArray) = ''aGVsbG8gd29ybGQ='' name: ''b64 encode''.
	self ok: (PhextLib b64Decode: ''aGVsbG8gd29ybGQ='') = ''hello world'' asByteArray name: ''b64 decode''.
	self ok: (JsonWtr write: (Dictionary new at: ''b'' put: 1; at: ''a'' put: ''x''; yourself)) = ''{"a":"x","b":1}'' name: ''canon sorts keys''.
	self ok: (JsonWtr write: (JsonRdr parse: ''{"z":[1,2,{"k":"v"}],"a":null}'')) = ''{"a":null,"z":[1,2,{"k":"v"}]}'' name: ''parse+canon round trip''.
	dyn := DynPhext fromBytes: ByteArray new.
	trn := TrnPhext fromBytes: ByteArray new.
	d := ByteArray new.
	{ { ''i''. ''1.1.1/1.1.1/1.1.1''. ''A'' }. { ''i''. ''1.1.1/1.1.1/1.1.2''. ''B'' }.
	  { ''i''. ''2.1.1/1.1.1/1.1.1''. ''C'' }. { ''i''. ''1.1.1/1.1.1/1.1.1''. ''A2'' }.
	  { ''r''. ''1.1.1/1.1.1/1.1.2''. ''B2'' }. { ''i''. ''1.1.1/1.1.1/2.1.1''. ''D'' }.
	  { ''x''. ''2.1.1/1.1.1/1.1.1''. '''' }. { ''i''. ''9.9.9/9.9.9/9.9.9''. ''Z'' }.
	  { ''r''. ''9.9.9/9.9.9/9.9.9''. '''' }. { ''i''. ''1.1.1/1.1.1/1.1.2''. ''B3'' } } do: [ :op |
		| coord |
		coord := PhextLib parseCoord: (op at: 2).
		(op at: 1) = ''i'' ifTrue: [
			d := PhextLib insert: d atCoord: coord text: (op at: 3) asByteArray.
			dyn insert: coord text: (op at: 3) asByteArray.
			trn insert: coord text: (op at: 3) asByteArray ].
		(op at: 1) = ''r'' ifTrue: [
			d := PhextLib replace: d atCoord: coord text: (op at: 3) asByteArray.
			dyn replace: coord text: (op at: 3) asByteArray.
			trn replace: coord text: (op at: 3) asByteArray ].
		(op at: 1) = ''x'' ifTrue: [
			d := PhextLib remove: d atCoord: coord.
			dyn remove: coord.
			trn remove: coord ] ].
	self ok: dyn serialize = d name: ''dynamic store == buffer''.
	self ok: trn serialize = d name: ''transitive store == buffer''.
	self ok: (dyn fetch: (PhextLib parseCoord: ''1.1.1/1.1.1/1.1.1'')) = ''AA2'' asByteArray name: ''dynamic fetch''.
	self ok: (trn fetch: (PhextLib parseCoord: ''1.1.1/1.1.1/1.1.2'')) = ''B2B3'' asByteArray name: ''transitive fetch''.
	self ok: trn length = 3 name: ''transitive length''.
	cap := DynPhext new.
	1 to: 64 do: [ :i | cap insert: (Array withAll: { 1. 1. 1. 1. 1. 1. 1. 1. i }) text: ''s'' asByteArray ].
	self ok: cap capacity = 64 name: ''capacity doubles to fit 64''.
	self ok: cap resizeCount <= 7 name: ''resize count is logarithmic''.
	fixturesDir isEmpty ifFalse: [
		listing := TelephoneCli shellOut: ''find '' , (TelephoneCli shq: fixturesDir) , '' -name input.phext | sort''.
		paths := (listing splitOn: (String with: Character lf)) select: [ :p | p notEmpty ].
		identical := 0.
		idem := 0.
		paths do: [ :p |
			| data |
			data := TelephoneCli readBytes: p.
			(PhextLib implode: (PhextLib explode: data)) = data ifTrue: [ identical := identical + 1 ].
			(PhextLib normalize: (PhextLib normalize: data)) = (PhextLib normalize: data) ifTrue: [ idem := idem + 1 ] ].
		out nextPutAll: ''fixtures: '' , paths size printString , '' input.phext, '' , identical printString , '' byte-identical round-trips, '' , idem printString , '' normalize-idempotent''; lf.
		self ok: paths size = 16 name: ''fixtures count is 16''.
		self ok: identical = 16 name: ''fixtures 16/16 byte-identical''.
		self ok: idem = 16 name: ''fixtures 16/16 normalize-idempotent'' ].
	out nextPutAll: ''smalltalk suite: '' , checks printString , '' checks, '' , failures printString , '' failures''; lf; flush'.
