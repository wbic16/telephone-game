% Hub-side CLI for libphext-prolog (Exocortical Telephone Game,
% contract v2).
%
% Transport: with the argument `serve`, stdin carries one JSON
% request per line and stdout carries one JSON response per line.
% With no argument, stdin carries ONE JSON object and stdout ONE
% response. This CLI serves the four libphext hooks the local adapter
% (ports/prolog/adapter, harness/adapter_base.py) plugs into its
% shared game machinery: explode / implode / insert / fetch.
% Requests carry phext state as base64 under "state" (v2) or
% "state_b64". JSON is library(http/json), Base64 is library(base64),
% SHA-256 is library(sha) — all SWI-Prolog built-ins.

:- use_module(library(http/json)).
:- use_module(library(base64)).
:- use_module(library(sha)).
:- use_module(library(rbtrees)).
:- use_module(library(zlib)).
:- use_module(library(memfile)).
:- prolog_load_context(directory, CliDir),
   atomic_list_concat([CliDir, '/phext.pl'], PhextFile),
   use_module(PhextFile).

impl(prolog).

% Wire compression (see ports/prolog/adapter): requests over 64 KiB
% may arrive as {"gz_b64": "<base64 gzip of the request JSON>"} and
% large responses are returned the same way. Gzip is library(zlib)
% over memory files with octet encoding.
gz_decompress(Codes, Plain) :-
    new_memory_file(MF),
    open_memory_file(MF, write, W, [encoding(octet)]),
    format(W, "~s", [Codes]),
    close(W),
    open_memory_file(MF, read, In0, [encoding(octet),
                                     free_on_close(true)]),
    zopen(In0, In, [format(gzip)]),
    read_stream_to_codes(In, Plain),
    close(In).

gz_compress(Codes, Out) :-
    new_memory_file(MF),
    open_memory_file(MF, write, W0, [encoding(octet)]),
    zopen(W0, W, [format(gzip), close_parent(true)]),
    format(W, "~s", [Codes]),
    close(W),
    memory_file_to_codes(MF, Out),
    free_memory_file(MF).

codes_hex([], "").
codes_hex([B|Rest], Hex) :-
    codes_hex(Rest, Tail),
    format(string(H), "~|~`0t~16r~2+", [B]),
    string_concat(H, Tail, Hex).

sha256hex(Codes, Hex) :-
    sha_hash(Codes, Hash, [algorithm(sha256), encoding(octet)]),
    codes_hex(Hash, Hex).

b64_encode(Codes, String) :-
    base64_encoded(Codes, Encoded, [encoding(octet)]),
    string_codes(String, Encoded).

b64_decode(String, Codes) :-
    % SWI 10 has no base64_decoded/*; base64_encoded/3 is
    % bidirectional but wants the encoded side as an atom or string
    % (a codes list makes it fail silently).
    ( string(String) -> Encoded = String
    ; atom(String) -> Encoded = String
    ; string_codes(Encoded, String) ),
    base64_encoded(Plain, Encoded, [encoding(octet)]),
    % The decoded side comes back as a string for text-y payloads;
    % the port's currency is byte codes.
    ( string(Plain) -> string_codes(Plain, Codes)
    ; atom(Plain) -> atom_codes(Plain, Codes)
    ; Codes = Plain ).

state_of(Dict, Codes) :-
    ( get_dict(state, Dict, S) -> true
    ; get_dict(state_b64, Dict, S) ),
    b64_decode(S, Codes).

dispatch(Dict, Response) :-
    get_dict(cmd, Dict, Cmd),
    ( string(Cmd) -> atom_string(CmdAtom, Cmd) ; CmdAtom = Cmd ),
    dispatch_cmd(CmdAtom, Dict, Response).

dispatch_cmd(id, _, _{impl: prolog}) :- !.
dispatch_cmd(explode, Dict, _{map: MapDict}) :- !,
    state_of(Dict, Codes),
    phext:explode(Codes, Tree),
    rb_visit(Tree, Pairs),
    foldl(add_map_entry, Pairs, _{}, MapDict).
dispatch_cmd(implode, Dict, Response) :- !,
    get_dict(map, Dict, MapIn),
    rb_empty(Tree0),
    dict_pairs(MapIn, _, Pairs),
    foldl(add_tree_entry, Pairs, Tree0, Tree),
    phext:implode(Tree, Bytes),
    b64_encode(Bytes, B64),
    sha256hex(Bytes, Sha),
    Response = _{state_b64: B64, state_sha256: Sha}.
dispatch_cmd(insert, Dict, Response) :- !,
    % Game insert (adapter_base hook semantics): unused coord only.
    coord_of(Dict, Coord),
    state_of(Dict, Codes),
    phext:explode(Codes, Tree0),
    ( rb_lookup(Coord, _, Tree0) ->
        Response = _{error: "coordinate already occupied"}
    ; get_dict(text_b64, Dict, TextB64),
      b64_decode(TextB64, Text),
      rb_insert(Tree0, Coord, Text, Tree),
      phext:implode(Tree, Bytes),
      b64_encode(Bytes, B64),
      sha256hex(Bytes, Sha),
      Response = _{state_b64: B64, state_sha256: Sha} ).
dispatch_cmd(fetch, Dict, _{text_b64: B64}) :- !,
    coord_of(Dict, Coord),
    state_of(Dict, Codes),
    phext:fetch_scroll(Codes, Coord, Text),
    b64_encode(Text, B64).
dispatch_cmd(Cmd, _, _{error: Msg}) :-
    format(string(Msg), "unknown cmd ~w", [Cmd]).

add_map_entry(Coord-Text, Dict0, Dict) :-
    phext:coord_string(Coord, KeyString),
    atom_string(Key, KeyString),
    b64_encode(Text, B64),
    put_dict(Key, Dict0, B64, Dict).

add_tree_entry(Key-TextB64, Tree0, Tree) :-
    atom_codes(Key, CoordCodes),
    phext:coord_parse(CoordCodes, Coord),
    b64_decode(TextB64, Text),
    rb_insert(Tree0, Coord, Text, Tree).

read_json_string(Text, Dict) :-
    % SWI 10's json_read_dict has no value_string_as(codes); JSON
    % strings arrive as SWI strings and are converted at the seams
    % (b64_decode and coord_of handle both).
    setup_call_cleanup(
        open_string(Text, In),
        json_read_dict(In, Dict, []),
        close(In)).

coord_of(Dict, Coord) :-
    get_dict(coordinate, Dict, C),
    ( string(C) -> string_codes(C, Codes) ; Codes = C ),
    phext:coord_parse(Codes, Coord).

handle_line(Line, Out) :-
    ( catch(read_json_string(Line, Raw), _, fail) ->
        ( get_dict(gz_b64, Raw, GzB64) ->
            ( catch(( b64_decode(GzB64, Gz),
                      gz_decompress(Gz, Plain),
                      string_codes(PlainText, Plain),
                      read_json_string(PlainText, Dict) ), _, fail) ->
                true
            ; Dict = Raw )
        ; Dict = Raw ),
        ( catch(dispatch(Dict, Response), _, fail) ->
            true
        ; Response = _{error: "dispatch failed"} )
    ; Response = _{error: "bad json"} ),
    with_output_to(string(RawOut),
                   json_write_dict(current_output, Response, [width(0)])),
    ( string_length(RawOut, Len), Len > 65536 ->
        string_codes(RawOut, RawCodes),
        gz_compress(RawCodes, GzOut),
        b64_encode(GzOut, B64Out),
        with_output_to(string(Out),
                       json_write_dict(current_output,
                                       _{gz_b64: B64Out}, [width(0)]))
    ; Out = RawOut ).

serve_loop :-
    read_line_to_string(user_input, Line),
    ( Line == end_of_file ->
        true
    ; ( Line == "" ->
          true
      ; handle_line(Line, Out),
        format("~s~n", [Out]),
        flush_output ),
      serve_loop ).

main :-
    current_prolog_flag(argv, Argv),
    ( memberchk(serve, Argv) ->
        serve_loop
    ; read_line_to_string(user_input, Line),
      ( Line == end_of_file ->
          true
      ; handle_line(Line, Out),
        format("~s~n", [Out]),
        flush_output ) ),
    halt.
