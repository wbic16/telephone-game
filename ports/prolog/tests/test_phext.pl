% Test suite for libphext-prolog — plain assertions, no framework.
% Run: swipl -q -s tests/test_phext.pl -g main -- [fixtures_dir]

:- set_prolog_flag(double_quotes, codes).
:- use_module(library(rbtrees)).
:- use_module('../src/phext.pl').

:- dynamic failures/1, checks/1.
failures(0).
checks(0).

ok(Goal, Name) :-
    retract(checks(N)), N1 is N + 1, assertz(checks(N1)),
    ( catch(Goal, _, fail) ->
        true
    ; retract(failures(F)), F1 is F + 1, assertz(failures(F1)),
      format(user_output, "FAIL: ~w~n", [Name]) ).

eq(A, B, Name) :-
    ( A == B -> ok(true, Name) ; ok(false, Name) ).

c(String, Coord) :- phext:coord_parse(String, Coord).

cs(Coord, Codes) :-
    phext:coord_string(Coord, S),
    string_codes(S, Codes).

run :-
    % coordinate
    c("1.2.3/4.5.6/7.8.9", C1), cs(C1, S1),
    eq(S1, "1.2.3/4.5.6/7.8.9", coord_format),
    c("1.1.1/1.1.1/1.1.1", R1), c("1.1.1/1.1.1/1.1.2", R2),
    ok((R1 @< R2), order_scroll),
    c("1.1.1/1.1.1/1.1.9", R3), c("1.1.1/1.1.2/1.1.1", R4),
    ok((R3 @< R4), order_section),
    c("2.1.1/1.1.1/1.1.1", R5), c("1.9.9/9.9.9/9.9.9", R6),
    ok((R5 @> R6), order_library),
    phext:coord_root(Root), eq(R1, Root, root),
    ok((catch(c("0.1.1/1.1.1/1.1.1", _), _, fail) -> false ; true),
       coord_rejects_0),
    ok((catch(c("1.1/1.1.1/1.1.1", _), _, fail) -> false ; true),
       coord_rejects_short),

    % phokenize
    phext:phokenize("hello", Sc1),
    length(Sc1, LSc1), eq(LSc1, 1, one_scroll),
    Sc1 = [ps(FC, FT)],
    cs(FC, FCS), eq(FCS, "1.1.1/1.1.1/1.1.1", first_coord),
    eq(FT, "hello", first_text),
    append_lists(["a", [23], "b", [23, 23], "c\nline2"], Buf2),
    phext:phokenize(Buf2, Sc2),
    length(Sc2, LSc2), eq(LSc2, 3, scroll_breaks),
    Sc2 = [_, ps(C2, _), ps(C3, T3)],
    cs(C2, C2S), eq(C2S, "1.1.1/1.1.1/1.1.2", second_coord),
    cs(C3, C3S), eq(C3S, "1.1.1/1.1.1/1.1.4", gap_coord),
    eq(T3, "c\nline2", newline_text),
    append_lists(["x", [1], "y"], Buf3),
    phext:phokenize(Buf3, Sc3), Sc3 = [_, ps(C4, _)],
    cs(C4, C4S), eq(C4S, "2.1.1/1.1.1/1.1.1", library_break),
    append_lists(["x", [24], "y"], Buf4),
    phext:phokenize(Buf4, Sc4), Sc4 = [_, ps(C5, _)],
    cs(C5, C5S), eq(C5S, "1.1.1/1.1.1/1.2.1", section_break),
    phext:phokenize([], ScE), length(ScE, LScE), eq(LScE, 0, empty_buffer),
    phext:phokenize([97, 0, 255, 98], ScB),
    length(ScB, LScB), eq(LScB, 1, binary_one_scroll),
    ScB = [ps(_, TB)], length(TB, LTB), eq(LTB, 4, binary_preserved),

    % round trip
    append_lists(["alpha", [23], "beta", [24], "gamma", [1], "delta"], Sample),
    phext:phokenize(Sample, SampleSc),
    phext:dephokenize(SampleSc, SampleRT),
    eq(SampleRT, Sample, round_trip_sample),
    c("1.1.1/1.1.1/1.1.2", D2), c("1.1.1/1.1.1/1.1.1", D1),
    phext:dephokenize([ps(D2, "two"), ps(D1, "one")], Built),
    append_lists(["one", [23], "two"], BuiltWant),
    eq(Built, BuiltWant, dephokenize_sorts),
    append_lists([[23, 23], "lead"], Lead),
    phext:normalize(Lead, N1), phext:normalize(N1, N2),
    eq(N2, N1, normalize_idempotent),

    % fetch incl. gaps
    append_lists(["one", [23], "two", [23, 23], "four"], FBuf),
    phext:fetch_scroll(FBuf, D1, F1), eq(F1, "one", fetch_1),
    c("1.1.1/1.1.1/1.1.4", D4), phext:fetch_scroll(FBuf, D4, F4),
    eq(F4, "four", fetch_4),
    c("1.1.1/1.1.1/1.1.3", D3), phext:fetch_scroll(FBuf, D3, F3),
    eq(F3, [], gap_fetch_empty),
    c("9.9.9/9.9.9/9.9.9", D9), phext:fetch_scroll(FBuf, D9, F9),
    eq(F9, [], far_gap_fetch_empty),
    phext:fetch_scroll([], D1, FE), eq(FE, [], fetch_empty_buffer),

    % insert
    phext:insert_scroll("base", D1, "+more", I1),
    phext:fetch_scroll(I1, D1, I1F), eq(I1F, "base+more", insert_appends),
    phext:insert_scroll([], D3, "new", I2),
    phext:fetch_scroll(I2, D3, I2F), eq(I2F, "new", insert_creates_gap),
    append_lists([[23, 23], "new"], I2Want), eq(I2, I2Want, insert_gap_breaks),
    append_lists(["a", [23], "c"], ABuf),
    c("1.1.1/1.1.1/1.1.2", D2c),
    phext:insert_scroll(ABuf, D2c, "b", I3),
    phext:fetch_scroll(I3, D2c, I3F), eq(I3F, "cb", insert_merges),
    true.

length_(L, N) :- length(L, N).

append_lists([], []).
append_lists([H|T], Out) :-
    append(H, Rest, Out),
    append_lists(T, Rest).

run2 :-
    c("1.1.1/1.1.1/1.1.1", D1), c("1.1.1/1.1.1/1.1.2", D2),
    c("1.1.1/1.1.1/1.1.3", D3),
    % replace / remove — remove is coordinate-preserving
    append_lists(["old", [23], "keep"], RBuf),
    phext:replace_scroll(RBuf, D1, "new", Rp1),
    append_lists(["new", [23], "keep"], RpWant), eq(Rp1, RpWant, replace_overwrites),
    c("1.1.1/1.1.1/1.1.5", D5),
    phext:replace_scroll("a", D5, "deep", Rp2),
    phext:fetch_scroll(Rp2, D5, Rp2F), eq(Rp2F, "deep", replace_creates),
    append_lists(["a", [23], "b", [23], "c"], MBuf),
    phext:remove_scroll(MBuf, D2, Rm1),
    append_lists(["a", [23, 23], "c"], RmWant),
    eq(Rm1, RmWant, remove_leaves_gap),
    phext:fetch_scroll(Rm1, D2, RmF2), eq(RmF2, [], removed_coord_empty),
    phext:fetch_scroll(Rm1, D3, RmF3), eq(RmF3, "c", neighbour_keeps_coord),
    phext:remove_scroll("only", D1, Rm2), length(Rm2, LRm2), eq(LRm2, 0, remove_sole),
    c("5.5.5/5.5.5/5.5.5", D55),
    phext:remove_scroll("a", D55, Rm3), eq(Rm3, "a", remove_gap_noop),

    % explode / implode
    append_lists(["x", [23], "y"], XBuf),
    phext:explode(XBuf, XTree),
    rb_visit(XTree, XPairs), length(XPairs, LXP), eq(LXP, 2, explode_count),
    phext:implode(XTree, XRT), eq(XRT, XBuf, implode_round_trip).

store_step(Dyn, Trn, StrBuf0, Op, Coord, Text, StrBuf) :-
    ( Op == insert ->
        phext:insert_scroll(StrBuf0, Coord, Text, StrBuf),
        phext:dynamic_insert(Dyn, Coord, Text),
        phext:transitive_insert(Trn, Coord, Text)
    ; Op == replace ->
        phext:replace_scroll(StrBuf0, Coord, Text, StrBuf),
        phext:dynamic_replace(Dyn, Coord, Text),
        phext:transitive_replace(Trn, Coord, Text)
    ; phext:remove_scroll(StrBuf0, Coord, StrBuf),
      phext:dynamic_remove(Dyn, Coord),
      phext:transitive_remove(Trn, Coord) ),
    phext:dynamic_serialize(Dyn, DynSer),
    eq(DynSer, StrBuf, store_step_dynamic),
    phext:transitive_serialize(Trn, TrnSer),
    eq(TrnSer, StrBuf, store_step_transitive),
    phext:dynamic_fetch(Dyn, Coord, DynF),
    phext:fetch_scroll(StrBuf, Coord, StrF),
    eq(DynF, StrF, store_step_dyn_fetch),
    phext:transitive_fetch(Trn, Coord, TrnF),
    eq(TrnF, StrF, store_step_trn_fetch).

run3 :-
    phext:dynamic_new(Dyn, 4),
    phext:transitive_new(Trn),
    c("1.1.1/1.1.1/1.1.1", A), c("1.1.1/1.1.1/1.1.3", Cc),
    c("1.1.1/1.1.1/1.1.2", B), c("2.1.1/1.1.1/1.1.1", L2),
    store_step(Dyn, Trn, [], insert, A, "alpha", S1),
    store_step(Dyn, Trn, S1, insert, Cc, "gamma", S2),
    store_step(Dyn, Trn, S2, insert, B, "beta", S3),
    store_step(Dyn, Trn, S3, insert, B, "+", S4),
    store_step(Dyn, Trn, S4, replace, L2, "lib2", S5),
    store_step(Dyn, Trn, S5, remove, Cc, "", S6),
    phext:dynamic_fetch(Dyn, Cc, DF), eq(DF, [], dynamic_removed_gap),
    phext:transitive_fetch(Trn, Cc, TF), eq(TF, [], transitive_removed_gap),
    phext:dynamic_fetch(Dyn, L2, DF2), eq(DF2, "lib2", dynamic_neighbour_unmoved),
    phext:transitive_fetch(Trn, L2, TF2), eq(TF2, "lib2", transitive_neighbour_unmoved),
    store_step(Dyn, Trn, S6, insert, A, "", S7),
    store_step(Dyn, Trn, S7, replace, A, "", _S8),
    phext:dynamic_len(Dyn, DL), phext:transitive_len(Trn, TL),
    eq(DL, TL, store_lengths_agree),

    % capacity discipline
    phext:dynamic_new(Cap, 4),
    fill_dyn(Cap, 1, 64),
    phext:dynamic_capacity(Cap, CapVal), eq(CapVal, 64, capacity_doubles),
    phext:dynamic_resize_count(Cap, RC), ok((RC =< 7), resize_log).

fill_dyn(_, I, Max) :- I > Max, !.
fill_dyn(D, I, Max) :-
    phext:dynamic_append(D, [1, 1, 1, 1, 1, 1, 1, 1, I], "s"),
    I1 is I + 1,
    fill_dyn(D, I1, Max).

run_fixtures(Dir) :-
    ( Dir == none ->
        format("fixtures: skipped (no fixtures dir)~n")
    ; findall(Path, fixture_file(Dir, Path), Paths),
      length(Paths, Files),
      fixture_stats(Paths, Identical, Idem),
      format("fixtures: ~d input.phext, ~d byte-identical round-trips, ~d normalize-idempotent~n",
             [Files, Identical, Idem]),
      eq(Files, 16, fixtures_16),
      eq(Identical, Files, fixtures_identical),
      eq(Idem, Files, fixtures_idem) ).

fixture_file(Dir, Path) :-
    directory_files(Dir, Entries),
    member(E, Entries),
    E \= '.', E \= '..',
    atomic_list_concat([Dir, '/', E], Sub),
    ( exists_file(Sub) ->
        atom_concat(_, 'input.phext', Sub),
        Path = Sub
    ; exists_directory(Sub),
      fixture_file(Sub, Path) ).

fixture_stats([], 0, 0).
fixture_stats([Path|Rest], Identical, Idem) :-
    read_file_to_codes(Path, Data, []),
    phext:phokenize(Data, Sc),
    phext:dephokenize(Sc, RT),
    ( RT == Data -> I1 = 1 ; I1 = 0 ),
    phext:normalize(Data, N1),
    phext:normalize(N1, N2),
    ( N2 == N1 -> I2 = 1 ; I2 = 0 ),
    % The real-corpora fixture is 9.4 MB; several live copies of it
    % approach SWI's default 1 GB stack limit, so reclaim between
    % fixtures (the suite is also run with --stack_limit=4g).
    garbage_collect,
    fixture_stats(Rest, IRest, DRest),
    Identical is I1 + IRest,
    Idem is I2 + DRest.

main :-
    ( catch(run, E, (format("ERROR in run: ~w~n", [E]), fail)) -> true
    ; ok(false, run_completed) ),
    ( catch(run2, E2, (format("ERROR in run2: ~w~n", [E2]), fail)) -> true
    ; ok(false, run2_completed) ),
    ( catch(run3, E3, (format("ERROR in run3: ~w~n", [E3]), fail)) -> true
    ; ok(false, run3_completed) ),
    current_prolog_flag(argv, Argv),
    ( Argv = [Dir|_] -> run_fixtures(Dir) ; run_fixtures(none) ),
    checks(C), failures(F),
    format("prolog suite: ~d checks, ~d failures~n", [C, F]),
    ( F == 0 -> halt(0) ; halt(1) ).
