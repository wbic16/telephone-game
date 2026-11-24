// Command telephone is the Exocortical Telephone Game CLI (contract v2)
// for the Go libphext port. It speaks the adapter wire protocol: one JSON
// request in, one JSON response out. With no arguments it handles a
// single request on stdin; with the argument "serve" it loops over JSON
// lines on stdin/stdout for the driver's persistent mode.
//
// Commands (contract v2):
//
//	{"cmd":"id"}                        -> {"impl":"go"}
//	{"cmd":"echo","ping":{game,round,nonce}} -> {"impl":"go","echo":hex}
//	{"cmd":"elect","position":..,"candidates":[..],"turn":n} -> {"elect":id}
//	{"cmd":"choose","state":b64,"position":..,"turn":n} -> insert step
//	{"cmd":"apply","state":b64,"step":{...}} -> {"state_b64","state_sha256"}
//	{"cmd":"keygen"}                    -> {"impl":"go","pubkey":armored}
//	{"cmd":"attest","descriptor":{...}} -> {"signature":armored}
//	{"cmd":"init","state":b64}         -> {"impl","verdict":"pass"}
//	                                    (caches the state for the
//	                                    driver-form validate below)
//	{"cmd":"validate","state":b64,"step":{...},"prior_state":b64?}
//	                                    -> {"impl","verdict","detail"}
//	{"cmd":"validate","state":b64,"step":{...},"event_coord":..,
//	 "index_line":..}                   -> driver form: validate
//	                                    against the init cache
//	                                    (adapter_base semantics)
//	{"cmd":"verify","state":b64,"pubkeys":armored}
//	                                    -> {"impl","verdict","placements_checked","first_failure"}
//
// The state key is accepted as "state" (contract v2) or "state_b64".
//
// Echo rule (this port's idiom, deterministic given the ping):
// sha256 hex of "go|<game>|<round>|<nonce>".
//
// Elect rule (popcorn, this port's idiom): seed = sha256(position bytes
// || byte(turn) || candidates joined with ","); the winner is
// candidates[seed[0] % len(candidates)].
//
// Choose rule (this port's own deterministic adventure; insert-only per
// contract v2): seed = sha256(position || byte(turn) || state). The
// first candidate coordinate is the tracked position with component
// seed[1]%9 advanced by 1+seed[2]%3 (wrapping within 1..999). While the
// candidate holds a scroll in the given state, advance it by one scroll
// (lexicographic +1 within 999^9, carrying at 999). The step is
// {"op":"insert","coordinate":candidate,"text":"go turn <turn> at
// <candidate>"} — the coordinate is verified unused in the given state.
//
// Canonical JSON (for attest/verify): compact, keys sorted, strings
// escaped the way Python's json.dumps(ensure_ascii=True) escapes them —
// the harness's canon form.
//
// stress.phext layout (contract v2, pinned formats — the driver's
// inscription is canonical): index scroll at 1.1.1/1.1.1/1.1.1 with a
// header line, then one "<turn> <coordinate> <sha256hex> <actor id>"
// line per placement; participant public keys at 1.1.1/1.1.1/1.1.2;
// sha256 of the keys scroll text EXACTLY as inscribed (no trimming) at
// 1.1.1/1.1.1/1.1.3; event scrolls at 1.1.1/1.1.1/2.1.<seq> (seq from
// 1), each canonical JSON {"prev": <sha256 of previous event's body,
// or null>, "body": {...}}. A placement body carries type, turn,
// actor, elect_by, coord, text_sha256, file_sha256 (file hash after
// the placement insert, before inscription), att (base64 of the
// armored detached signature), echoes, consensus_prev. The signed
// attestation descriptor is the canonical JSON {"turn","coordinate",
// "scroll_sha256","file_sha256"} built from the body. Verify walks
// every event: chain integrity via prev, placement present with
// matching hash, index line matching (turn, hash, actor), signature
// valid against the inscribed public keys.
//
// PGP: gpg (2.4.4 on the hub) with the key home at
// $TELEPHONE_GNUPG_HOME or ~/telephone-go/gnupg. Private keys never
// leave that home and are never inscribed anywhere.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"libphext/phext"
)

const implID = "go"

var reservedCoords = []string{"1.1.1/1.1.1/1.1.1", "1.1.1/1.1.1/1.1.2", "1.1.1/1.1.1/1.1.3"}

// ------------------------------------------------------------ utilities

func sha256hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func b64decode(s string) []byte {
	b, _ := base64.StdEncoding.DecodeString(s)
	return b
}

func wrap999(v int) int { return (v-1)%999 + 1 }

// canonJSON renders v (decoded with UseNumber) in the harness canon
// form: compact, sorted keys, Python-style string escaping.
func canonJSON(v interface{}) string {
	var sb strings.Builder
	writeCanon(&sb, v)
	return sb.String()
}

func writeCanon(sb *strings.Builder, v interface{}) {
	switch t := v.(type) {
	case nil:
		sb.WriteString("null")
	case bool:
		if t {
			sb.WriteString("true")
		} else {
			sb.WriteString("false")
		}
	case json.Number:
		sb.WriteString(t.String())
	case float64:
		sb.WriteString(strconv.FormatFloat(t, 'g', -1, 64))
	case string:
		writeCanonString(sb, t)
	case []interface{}:
		sb.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				sb.WriteByte(',')
			}
			writeCanon(sb, e)
		}
		sb.WriteByte(']')
	case map[string]interface{}:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		sb.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				sb.WriteByte(',')
			}
			writeCanonString(sb, k)
			sb.WriteByte(':')
			writeCanon(sb, t[k])
		}
		sb.WriteByte('}')
	}
}

func writeCanonString(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\b':
			sb.WriteString("\\b")
		case '\f':
			sb.WriteString("\\f")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if r < 0x20 || r > 0x7e {
				if r > 0xffff {
					r1, r2 := utf16.EncodeRune(r)
					fmt.Fprintf(sb, "\\u%04x\\u%04x", r1, r2)
				} else {
					fmt.Fprintf(sb, "\\u%04x", r)
				}
			} else {
				sb.WriteRune(r)
			}
		}
	}
	sb.WriteByte('"')
}

func decodeJSON(raw []byte) (interface{}, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v interface{}
	err := dec.Decode(&v)
	return v, err
}

// ------------------------------------------------------------ gpg

func gnupgHome() string {
	if h := os.Getenv("TELEPHONE_GNUPG_HOME"); h != "" {
		return h
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "telephone-"+implID, "gnupg")
}

const keyUID = "libphext telephone " + implID

func runGPG(args ...string) (string, error) {
	home := gnupgHome()
	if err := os.MkdirAll(home, 0700); err != nil {
		return "", err
	}
	full := append([]string{"--batch", "--yes", "--pinentry-mode", "loopback",
		"--passphrase", "", "--homedir", home}, args...)
	cmd := exec.Command("gpg", full...)
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("gpg %v: %v: %s", args, err, errBuf.String())
	}
	return out.String(), nil
}

func keygen() (string, error) {
	home := gnupgHome()
	if err := os.MkdirAll(home, 0700); err != nil {
		return "", err
	}
	listing, err := runGPG("--list-keys", "--with-colons")
	if err != nil {
		return "", err
	}
	if !strings.Contains(listing, "pub:") {
		if _, err := runGPG("--quick-gen-key", keyUID, "ed25519", "sign", "never"); err != nil {
			return "", err
		}
	}
	return runGPG("--armor", "--export", keyUID)
}

func detachSign(data []byte) (string, error) {
	dir, err := os.MkdirTemp("", "telephone-"+implID+"-sign")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	plain := filepath.Join(dir, "descriptor.json")
	sig := filepath.Join(dir, "descriptor.asc")
	if err := os.WriteFile(plain, data, 0600); err != nil {
		return "", err
	}
	if _, err := runGPG("--detach-sign", "--armor", "--local-user", keyUID,
		"--output", sig, plain); err != nil {
		return "", err
	}
	b, err := os.ReadFile(sig)
	return string(b), err
}

func verifySignature(pubkeys string, data []byte, signature string) error {
	dir, err := os.MkdirTemp("", "telephone-"+implID+"-verify")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	home := filepath.Join(dir, "gnupg")
	if err := os.MkdirAll(home, 0700); err != nil {
		return err
	}
	keyFile := filepath.Join(dir, "keys.asc")
	plain := filepath.Join(dir, "descriptor.json")
	sig := filepath.Join(dir, "descriptor.asc")
	os.WriteFile(keyFile, []byte(pubkeys), 0600)
	os.WriteFile(plain, data, 0600)
	os.WriteFile(sig, []byte(signature), 0600)
	cmd := exec.Command("gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
		"--homedir", home, "--import", keyFile)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("gpg import: %v: %s", err, out)
	}
	cmd = exec.Command("gpg", "--batch", "--yes", "--homedir", home,
		"--verify", sig, plain)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("gpg verify: %v: %s", err, out)
	}
	return nil
}

// ------------------------------------------------------------ game logic

type step struct {
	Op         string `json:"op"`
	Coordinate string `json:"coordinate"`
	Text       string `json:"text,omitempty"`
}

func echoValue(ping map[string]interface{}) string {
	game, _ := ping["game"].(string)
	round := ping["round"]
	if round == nil {
		round = ping["turn"]
	}
	nonce, _ := ping["nonce"].(string)
	return sha256hex([]byte(fmt.Sprintf("%s|%s|%v|%s", implID, game, round, nonce)))
}

func electWinner(position string, candidates []string, turn int) string {
	seed := sha256.Sum256([]byte(position + string(rune(turn%256)) + strings.Join(candidates, ",")))
	return candidates[int(seed[0])%len(candidates)]
}

// nextCoord advances a coordinate by one scroll within 999^9 (lexicographic
// +1, carrying at 999; wraps from the maximum back to the minimum).
func nextCoord(c phext.Coordinate) phext.Coordinate {
	for d := 8; d >= 0; d-- {
		if c.Parts[d] < 999 {
			c.Parts[d]++
			return c
		}
		c.Parts[d] = 1
	}
	return c
}

func chooseAdventure(state []byte, position string, turn int) (step, error) {
	pos, err := phext.ParseCoordinate(position)
	if err != nil {
		return step{}, err
	}
	used := phext.Explode(state)
	for _, rc := range reservedCoords {
		// The stress.phext bookkeeping scrolls are never placements.
		used[coordOf(rc)] = []byte{0}
	}
	seed := sha256.Sum256(append(append([]byte(position), byte(turn)), state...))
	cand := pos
	dim := int(seed[1]) % 9
	cand.Parts[dim] = wrap999(cand.Parts[dim] + 1 + int(seed[2])%3)
	for {
		if _, taken := used[cand]; !taken {
			break
		}
		cand = nextCoord(cand)
	}
	st := step{Op: "insert", Coordinate: cand.String(),
		Text: fmt.Sprintf("%s turn %d at %s", implID, turn, cand.String())}
	return st, nil
}

func applyStep(state []byte, st step) ([]byte, *string) {
	coord, err := phext.ParseCoordinate(st.Coordinate)
	if err != nil {
		return state, nil
	}
	switch st.Op {
	case "insert":
		return phext.Insert(state, coord, []byte(st.Text)), nil
	case "replace":
		return phext.Replace(state, coord, []byte(st.Text)), nil
	case "remove":
		return phext.Remove(state, coord), nil
	case "fetch":
		h := sha256hex(phext.Fetch(state, coord))
		return state, &h
	default:
		return state, nil
	}
}

func coordOf(s string) phext.Coordinate {
	c, _ := phext.ParseCoordinate(s)
	return c
}

var (
	indexCoord    = coordOf("1.1.1/1.1.1/1.1.1")
	keysCoord     = coordOf("1.1.1/1.1.1/1.1.2")
	keysHashCoord = coordOf("1.1.1/1.1.1/1.1.3")
)

func eventCoord(seq int) phext.Coordinate {
	return phext.Coordinate{Parts: [9]int{1, 1, 1, 1, 1, 1, 2, 1, seq}}
}

func validateStep(newState []byte, st step, priorState []byte, hasPrior bool) (string, string) {
	if st.Op != "insert" {
		return "fail", "step op is not insert"
	}
	coord, err := phext.ParseCoordinate(st.Coordinate)
	if err != nil {
		return "fail", "unparseable coordinate"
	}
	if got := phext.Fetch(newState, coord); string(got) != st.Text {
		return "fail", "placed scroll absent or content differs at " + st.Coordinate
	}
	if hasPrior {
		if got := phext.Fetch(priorState, coord); len(got) != 0 {
			return "fail", "coordinate was not unused in the prior state"
		}
		before := phext.Explode(priorState)
		after := phext.Explode(newState)
		if len(after) != len(before)+1 {
			return "fail", "scroll count did not grow by exactly one"
		}
		for c, text := range before {
			got, ok := after[c]
			if !ok || !bytes.Equal(got, text) {
				return "fail", "a prior scroll was overwritten: " + c.String()
			}
		}
		return "pass", "placed at unused coordinate; all prior scrolls intact"
	}
	return "pass", "placed scroll present with attested content (no prior state supplied)"
}

// validateDriver implements the driver's validate form (telephone.py
// cmd_play): the file already carries the placement scroll, the
// appended index line and the event scroll; the prior state is the
// serve cache set by init (advanced by each passing validate).
// Semantics mirror harness/adapter_base.py validate.
func validateDriver(newState []byte, st step, eventCoordS, indexLine string) (string, string) {
	if st.Op != "insert" {
		return "fail", "step op is not insert"
	}
	coord, err := phext.ParseCoordinate(st.Coordinate)
	if err != nil {
		return "fail", "unparseable coordinate"
	}
	evCoord, err := phext.ParseCoordinate(eventCoordS)
	if err != nil {
		return "fail", "unparseable event coordinate"
	}
	if !cacheSet {
		return "fail", "no prior state (init not called)"
	}
	if got := phext.Fetch(newState, coord); string(got) != st.Text {
		return "fail", "placed scroll absent or content differs at " + st.Coordinate
	}
	before := phext.Explode(cacheState)
	after := phext.Explode(newState)
	if _, ok := before[coord]; ok {
		return "fail", "coordinate was not unused in the prior state"
	}
	for c, text := range before {
		if c == indexCoord {
			continue
		}
		got, ok := after[c]
		if !ok || !bytes.Equal(got, text) {
			return "fail", "prior scroll overwritten at " + c.String()
		}
	}
	for c := range after {
		if _, ok := before[c]; !ok && c != coord && c != evCoord {
			return "fail", "unexpected new scroll at " + c.String()
		}
	}
	idx := strings.TrimRight(string(after[indexCoord]), "\n")
	if !strings.HasSuffix(idx, strings.TrimRight(indexLine, "\n")) {
		return "fail", "index does not record the placement"
	}
	cacheState = newState
	return "pass", "placed at unused coordinate; all prior scrolls intact"
}

func verifyGame(state []byte, pubkeys string) map[string]interface{} {
	result := map[string]interface{}{"impl": implID, "verdict": "fail",
		"placements_checked": 0, "first_failure": nil}
	fail := func(msg string, checked int) map[string]interface{} {
		result["first_failure"] = map[string]interface{}{"detail": msg}
		result["placements_checked"] = checked
		return result
	}
	scrolls := phext.Explode(state)
	keysText, ok := scrolls[keysCoord]
	if !ok || len(keysText) == 0 {
		return fail("no public-keys scroll at 1.1.1/1.1.1/1.1.2", 0)
	}
	if strings.TrimRight(pubkeys, " \t\r\n") != strings.TrimRight(string(keysText), " \t\r\n") {
		return fail("supplied pubkeys do not match the inscribed keys scroll", 0)
	}
	keysHashScroll, ok := scrolls[keysHashCoord]
	if !ok {
		return fail("no keys-hash scroll at 1.1.1/1.1.1/1.1.3", 0)
	}
	// Pinned: keys-hash is sha256 of the keys scroll text exactly as
	// inscribed — no trimming.
	if strings.TrimSpace(string(keysHashScroll)) != sha256hex(keysText) {
		return fail("keys-hash scroll does not match the keys scroll", 0)
	}
	// Pinned index line: "<turn> <coordinate> <sha256> <actor id>",
	// after a "# ..." header line.
	type idxEntry struct{ turn, hash, actor string }
	index := map[string]idxEntry{}
	if indexText, ok := scrolls[indexCoord]; ok {
		for _, line := range strings.Split(string(indexText), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) != 4 {
				return fail("malformed index line: "+line, 0)
			}
			index[fields[1]] = idxEntry{fields[0], fields[2], fields[3]}
		}
	}
	checked := 0
	seen := map[string]bool{}
	prevHash := ""
	for seq := 1; ; seq++ {
		eventText, ok := scrolls[eventCoord(seq)]
		if !ok {
			break
		}
		v, err := decodeJSON(eventText)
		if err != nil {
			return fail(fmt.Sprintf("event %d is not JSON", seq), checked)
		}
		ev, ok := v.(map[string]interface{})
		if !ok {
			return fail(fmt.Sprintf("event %d is not an object", seq), checked)
		}
		body, ok := ev["body"].(map[string]interface{})
		if !ok {
			return fail(fmt.Sprintf("event %d lacks a body object", seq), checked)
		}
		// Pinned event chain: prev = sha256 of the previous event's
		// canonical body, null for the first event.
		if seq == 1 {
			if ev["prev"] != nil {
				return fail("event 1 prev is not null", checked)
			}
		} else if prevStr, _ := ev["prev"].(string); prevStr != prevHash {
			return fail(fmt.Sprintf("event chain broken at seq %d", seq), checked)
		}
		prevHash = sha256hex([]byte(canonJSON(body)))
		if body["type"] != "placement" {
			continue
		}
		coordStr, _ := body["coord"].(string)
		textHash, _ := body["text_sha256"].(string)
		fileHash, _ := body["file_sha256"].(string)
		attB64, _ := body["att"].(string)
		turnNum, _ := body["turn"].(json.Number)
		actor, _ := body["actor"].(string)
		if coordStr == "" || textHash == "" || fileHash == "" || attB64 == "" {
			return fail(fmt.Sprintf("event %d lacks coord/text_sha256/file_sha256/att", seq), checked)
		}
		if seen[coordStr] {
			return fail("coordinate reused at "+coordStr, checked)
		}
		placement, ok := scrolls[coordOf(coordStr)]
		if !ok {
			return fail("placement missing at "+coordStr, checked)
		}
		if sha256hex(placement) != textHash {
			return fail("placement hash mismatch at "+coordStr, checked)
		}
		ie, ok := index[coordStr]
		if !ok || ie.hash != textHash || ie.turn != turnNum.String() || ie.actor != actor {
			return fail("index mismatch at "+coordStr, checked)
		}
		// Pinned attestation descriptor, signed by the actor; att is
		// base64 of the armored detached signature.
		desc := map[string]interface{}{"turn": body["turn"],
			"coordinate": coordStr, "scroll_sha256": textHash,
			"file_sha256": fileHash}
		signature := string(b64decode(attB64))
		if err := verifySignature(pubkeys, []byte(canonJSON(desc)), signature); err != nil {
			return fail(fmt.Sprintf("event %d signature: %v", seq, err), checked)
		}
		seen[coordStr] = true
		checked++
	}
	if checked == 0 {
		return fail("no placement events found", 0)
	}
	for coordStr := range index {
		if !seen[coordStr] {
			return fail("index lists a placement with no event: "+coordStr, checked)
		}
	}
	result["verdict"] = "pass"
	result["placements_checked"] = checked
	return result
}

// ------------------------------------------------------------ dispatch

type request struct {
	Cmd         string                 `json:"cmd"`
	Ping        map[string]interface{} `json:"ping"`
	StateB64    string                 `json:"state_b64"`
	State       string                 `json:"state"`
	PriorB64    string                 `json:"prior_state"`
	Position    string                 `json:"position"`
	Turn        int                    `json:"turn"`
	Candidates  []string               `json:"candidates"`
	Step        *step                  `json:"step"`
	Descriptor  json.RawMessage        `json:"descriptor"`
	Pubkeys     string                 `json:"pubkeys"`
	EventCoord  string                 `json:"event_coord"`
	IndexLine   string                 `json:"index_line"`
}

// Serve-mode validator cache: init stores the state; a driver-form
// validate checks against it and advances it on pass. Mirrors
// harness/adapter_base.py (init_cache / validate).
var cacheState []byte
var cacheSet bool

func (r *request) stateBytes() []byte {
	if r.State != "" {
		return b64decode(r.State)
	}
	return b64decode(r.StateB64)
}

func emit(w io.Writer, v interface{}) {
	enc, _ := json.Marshal(v)
	w.Write(enc)
	w.Write([]byte("\n"))
}

func handle(raw []byte) (interface{}, error) {
	var req request
	if err := json.Unmarshal(raw, &req); err != nil {
		return nil, fmt.Errorf("parse request: %v", err)
	}
	switch req.Cmd {
	case "id":
		return map[string]string{"impl": implID}, nil
	case "echo":
		return map[string]string{"impl": implID, "echo": echoValue(req.Ping)}, nil
	case "elect":
		if len(req.Candidates) == 0 {
			return nil, fmt.Errorf("elect: no candidates")
		}
		return map[string]string{"elect": electWinner(req.Position, req.Candidates, req.Turn)}, nil
	case "choose":
		st, err := chooseAdventure(req.stateBytes(), req.Position, req.Turn)
		if err != nil {
			return nil, err
		}
		return st, nil
	case "apply":
		if req.Step == nil {
			return nil, fmt.Errorf("apply: missing step")
		}
		newState, fetchHash := applyStep(req.stateBytes(), *req.Step)
		resp := map[string]interface{}{
			"state_b64":    base64.StdEncoding.EncodeToString(newState),
			"state_sha256": sha256hex(newState),
		}
		if fetchHash != nil {
			resp["fetch_sha256"] = *fetchHash
		} else {
			resp["fetch_sha256"] = nil
		}
		return resp, nil
	case "keygen":
		pub, err := keygen()
		if err != nil {
			return nil, err
		}
		return map[string]string{"impl": implID, "pubkey": pub}, nil
	case "attest":
		v, err := decodeJSON(req.Descriptor)
		if err != nil {
			return nil, fmt.Errorf("attest: descriptor is not JSON: %v", err)
		}
		sig, err := detachSign([]byte(canonJSON(v)))
		if err != nil {
			return nil, err
		}
		return map[string]string{"signature": sig}, nil
	case "init":
		cacheState = req.stateBytes()
		cacheSet = true
		return map[string]string{"impl": implID, "verdict": "pass"}, nil
	case "validate":
		if req.Step == nil {
			return nil, fmt.Errorf("validate: missing step")
		}
		if req.EventCoord != "" || req.IndexLine != "" {
			if req.PriorB64 != "" {
				cacheState = b64decode(req.PriorB64)
				cacheSet = true
			}
			verdict, detail := validateDriver(req.stateBytes(), *req.Step,
				req.EventCoord, req.IndexLine)
			return map[string]string{"impl": implID, "verdict": verdict, "detail": detail}, nil
		}
		verdict, detail := validateStep(req.stateBytes(), *req.Step,
			b64decode(req.PriorB64), req.PriorB64 != "")
		return map[string]string{"impl": implID, "verdict": verdict, "detail": detail}, nil
	case "verify":
		return verifyGame(req.stateBytes(), req.Pubkeys), nil
	}
	return nil, fmt.Errorf("unknown cmd %q", req.Cmd)
}

func main() {
	serve := len(os.Args) > 1 && os.Args[1] == "serve"
	if serve {
		reader := bufio.NewReaderSize(os.Stdin, 1<<20)
		for {
			line, err := reader.ReadBytes('\n')
			line = bytes.TrimRight(line, "\r\n")
			if len(line) > 0 {
				resp, herr := handle(line)
				if herr != nil {
					emit(os.Stdout, map[string]string{"error": herr.Error()})
				} else {
					emit(os.Stdout, resp)
				}
			}
			if err != nil {
				return
			}
		}
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read stdin:", err)
		os.Exit(1)
	}
	resp, herr := handle(raw)
	if herr != nil {
		fmt.Fprintln(os.Stderr, herr)
		os.Exit(1)
	}
	emit(os.Stdout, resp)
}
