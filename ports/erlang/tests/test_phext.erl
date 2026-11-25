%% Test suite for libphext-erlang -- plain assertions, no framework.
%% Run via -run test_phext boot -- [fixtures_dir]; counts in the
%% process dictionary; exit status via init:stop(1) on failure is not
%% available from -run, so failures raise after printing the tally
%% and the runner greps the tally line.
-module(test_phext).
-export([boot/0]).

boot() ->
    put(checks, 0), put(failures, 0),
    run(),
    Args = init:get_plain_arguments(),
    case Args of
        [Fixtures] -> fixtures(Fixtures);
        _ -> io:format("fixtures: skipped (no fixtures dir)~n")
    end,
    io:format("erlang suite: ~B checks, ~B failures~n",
              [get(checks), get(failures)]),
    case get(failures) of
        0 -> init:stop();
        _ -> init:stop(1)
    end.

ok(true, _Name) -> put(checks, get(checks) + 1);
ok(false, Name) ->
    put(checks, get(checks) + 1),
    put(failures, get(failures) + 1),
    io:format("FAIL: ~s~n", [Name]).

eq(A, B, Name) -> ok(A == B, Name).
c(S) -> phext:coord_parse(S).
b(S) -> list_to_binary(S).

raises(F) ->
    try F(), false catch _:_ -> true end.

run() ->
    %% coordinate
    eq(phext:coord_string(c("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format"),
    ok(phext:coord_compare(c("1.1.1/1.1.1/1.1.1"), c("1.1.1/1.1.1/1.1.2")) < 0, "order scroll"),
    ok(phext:coord_compare(c("1.1.1/1.1.1/1.1.9"), c("1.1.1/1.1.2/1.1.1")) < 0, "order section"),
    ok(phext:coord_compare(c("2.1.1/1.1.1/1.1.1"), c("1.9.9/9.9.9/9.9.9")) > 0, "order library"),
    eq(c("1.1.1/1.1.1/1.1.1"), phext:coord_root(), "root"),
    ok(raises(fun() -> c("0.1.1/1.1.1/1.1.1") end), "coord rejects 0"),
    ok(raises(fun() -> c("1.1/1.1.1/1.1.1") end), "coord rejects short"),
    %% phokenize
    Sc = phext:phokenize(b("hello")),
    eq(length(Sc), 1, "one scroll"),
    eq(phext:coord_string(element(1, hd(Sc))), "1.1.1/1.1.1/1.1.1", "first coord"),
    eq(element(2, hd(Sc)), b("hello"), "first text"),
    Sc2 = phext:phokenize(<<"a", 16#17, "b", 16#17, 16#17, "c\nline2">>),
    eq(length(Sc2), 3, "scroll breaks"),
    eq(phext:coord_string(element(1, lists:nth(2, Sc2))), "1.1.1/1.1.1/1.1.2", "second coord"),
    eq(phext:coord_string(element(1, lists:nth(3, Sc2))), "1.1.1/1.1.1/1.1.4", "gap coord advance"),
    eq(element(2, lists:nth(3, Sc2)), b("c\nline2"), "newline is ordinary text"),
    Sc3 = phext:phokenize(<<"x", 16#01, "y">>),
    eq(phext:coord_string(element(1, lists:nth(2, Sc3))), "2.1.1/1.1.1/1.1.1", "library break resets"),
    Sc4 = phext:phokenize(<<"x", 16#18, "y">>),
    eq(phext:coord_string(element(1, lists:nth(2, Sc4))), "1.1.1/1.1.1/1.2.1", "section break"),
    eq(length(phext:phokenize(<<>>)), 0, "empty buffer"),
    Sc5 = phext:phokenize(<<16#61, 0, 16#FF, 16#62>>),
    eq(length(Sc5), 1, "binary text is one scroll"),
    eq(byte_size(element(2, hd(Sc5))), 4, "binary text preserved"),
    %% round trip
    Sample = <<"alpha", 16#17, "beta", 16#18, "gamma", 16#01, "delta">>,
    eq(phext:dephokenize(phext:phokenize(Sample)), Sample, "round trip sample"),
    Built = phext:dephokenize([{c("1.1.1/1.1.1/1.1.2"), b("two")},
                               {c("1.1.1/1.1.1/1.1.1"), b("one")}]),
    eq(Built, <<"one", 16#17, "two">>, "dephokenize sorts canonically"),
    eq(phext:normalize(phext:normalize(<<16#17, 16#17, "lead">>)),
       phext:normalize(<<16#17, 16#17, "lead">>), "normalize idempotent"),
    %% fetch incl. gaps
    Buf = <<"one", 16#17, "two", 16#17, 16#17, "four">>,
    eq(phext:fetch(Buf, c("1.1.1/1.1.1/1.1.1")), b("one"), "fetch 1"),
    eq(phext:fetch(Buf, c("1.1.1/1.1.1/1.1.4")), b("four"), "fetch 4"),
    eq(phext:fetch(Buf, c("1.1.1/1.1.1/1.1.3")), <<>>, "gap fetch is empty"),
    eq(phext:fetch(Buf, c("9.9.9/9.9.9/9.9.9")), <<>>, "far gap fetch is empty"),
    eq(phext:fetch(<<>>, c("1.1.1/1.1.1/1.1.1")), <<>>, "fetch empty buffer"),
    %% insert
    R1 = phext:insert(b("base"), c("1.1.1/1.1.1/1.1.1"), b("+more")),
    eq(phext:fetch(R1, c("1.1.1/1.1.1/1.1.1")), b("base+more"), "insert appends after existing"),
    R2 = phext:insert(<<>>, c("1.1.1/1.1.1/1.1.3"), b("new")),
    eq(phext:fetch(R2, c("1.1.1/1.1.1/1.1.3")), b("new"), "insert creates at gap"),
    eq(R2, <<16#17, 16#17, "new">>, "insert at gap emits breaks"),
    R3 = phext:insert(<<"a", 16#17, "c">>, c("1.1.1/1.1.1/1.1.2"), b("b")),
    eq(phext:fetch(R3, c("1.1.1/1.1.1/1.1.2")), b("cb"), "insert merges existing + inserted"),
    %% replace / remove -- coordinate-preserving
    eq(phext:replace(<<"old", 16#17, "keep">>, c("1.1.1/1.1.1/1.1.1"), b("new")),
       <<"new", 16#17, "keep">>, "replace overwrites"),
    R4 = phext:replace(b("a"), c("1.1.1/1.1.1/1.1.5"), b("deep")),
    eq(phext:fetch(R4, c("1.1.1/1.1.1/1.1.5")), b("deep"), "replace creates"),
    R5 = phext:remove(<<"a", 16#17, "b", 16#17, "c">>, c("1.1.1/1.1.1/1.1.2")),
    eq(R5, <<"a", 16#17, 16#17, "c">>, "remove leaves a gap (no renumbering)"),
    eq(phext:fetch(R5, c("1.1.1/1.1.1/1.1.2")), <<>>, "removed coordinate reads empty"),
    eq(phext:fetch(R5, c("1.1.1/1.1.1/1.1.3")), b("c"), "neighbour keeps its coordinate"),
    eq(byte_size(phext:remove(b("only"), c("1.1.1/1.1.1/1.1.1"))), 0, "remove sole scroll"),
    eq(phext:remove(b("a"), c("5.5.5/5.5.5/5.5.5")), b("a"), "remove gap is a no-op"),
    %% explode / implode
    Map = phext:explode(<<"x", 16#17, "y">>),
    eq(map_size(Map), 2, "explode count"),
    eq(phext:implode(Map), <<"x", 16#17, "y">>, "implode round trip"),
    %% Dynamic + Transitive equivalence
    Steps = [{"insert", "1.1.1/1.1.1/1.1.1", "alpha"},
             {"insert", "1.1.1/1.1.1/1.1.3", "gamma"},
             {"insert", "1.1.1/1.1.1/1.1.2", "beta"},
             {"insert", "1.1.1/1.1.1/1.1.2", "+"},
             {"replace", "2.1.1/1.1.1/1.1.1", "lib2"},
             {"remove", "1.1.1/1.1.1/1.1.3", ""}],
    {Dyn, Trn, _Str} = lists:foldl(
        fun({Op, Coord, Text}, {D, T, S}) ->
            CC = c(Coord), TT = b(Text),
            {D2, T2, S2} = case Op of
                "insert" -> {dynamic_phext:insert(D, CC, TT),
                             transitive_phext:insert(T, CC, TT),
                             phext:insert(S, CC, TT)};
                "replace" -> {dynamic_phext:replace(D, CC, TT),
                              transitive_phext:replace(T, CC, TT),
                              phext:replace(S, CC, TT)};
                "remove" -> {dynamic_phext:remove(D, CC),
                             transitive_phext:remove(T, CC),
                             phext:remove(S, CC)}
            end,
            eq(dynamic_phext:serialize(D2), S2, "dynamic == string after " ++ Op ++ " " ++ Coord),
            eq(transitive_phext:serialize(T2), S2, "transitive == string after " ++ Op ++ " " ++ Coord),
            eq(dynamic_phext:fetch(D2, CC), phext:fetch(S2, CC), "dynamic fetch after op"),
            eq(transitive_phext:fetch(T2, CC), phext:fetch(S2, CC), "transitive fetch after op"),
            {D2, T2, S2}
        end, {dynamic_phext:new(), transitive_phext:new(), <<>>}, Steps),
    eq(dynamic_phext:fetch(Dyn, c("1.1.1/1.1.1/1.1.3")), <<>>, "dynamic removed coord is gap"),
    eq(transitive_phext:fetch(Trn, c("1.1.1/1.1.1/1.1.3")), <<>>, "transitive removed coord is gap"),
    eq(dynamic_phext:fetch(Dyn, c("2.1.1/1.1.1/1.1.1")), b("lib2"), "dynamic neighbour unmoved"),
    eq(transitive_phext:fetch(Trn, c("2.1.1/1.1.1/1.1.1")), b("lib2"), "transitive neighbour unmoved"),
    Dyn2 = dynamic_phext:insert(Dyn, c("1.1.1/1.1.1/1.1.1"), <<>>),
    Trn2 = transitive_phext:insert(Trn, c("1.1.1/1.1.1/1.1.1"), <<>>),
    Dyn3 = dynamic_phext:replace(Dyn2, c("1.1.1/1.1.1/1.1.1"), <<>>),
    Trn3 = transitive_phext:replace(Trn2, c("1.1.1/1.1.1/1.1.1"), <<>>),
    eq(dynamic_phext:length(Dyn3), transitive_phext:length(Trn3), "store lengths agree"),
    %% capacity discipline
    Cap = lists:foldl(
        fun(I, D) -> dynamic_phext:append(D, {1, 1, 1, 1, 1, 1, 1, 1, I}, b("s")) end,
        dynamic_phext:new(), lists:seq(1, 64)),
    eq(dynamic_phext:capacity(Cap), 64, "capacity doubles to fit 64"),
    ok(dynamic_phext:resize_count(Cap) =< 7, "resize count is logarithmic").

fixtures(Dir) ->
    Files = filelib:wildcard(filename:join([Dir, "**", "input.phext"])),
    {Ident, Idem} = lists:foldl(
        fun(Path, {I1, I2}) ->
            {ok, Data} = file:read_file(Path),
            I1b = case phext:dephokenize(phext:phokenize(Data)) == Data of
                      true -> I1 + 1; false -> I1 end,
            N1 = phext:normalize(Data),
            I2b = case phext:normalize(N1) == N1 of
                      true -> I2 + 1; false -> I2 end,
            {I1b, I2b}
        end, {0, 0}, Files),
    io:format("fixtures: ~B input.phext, ~B byte-identical round-trips, ~B normalize-idempotent~n",
              [length(Files), Ident, Idem]),
    eq(length(Files), 16, "16 fixtures found"),
    eq(Ident, length(Files), "fixtures byte-identical round-trips"),
    eq(Idem, length(Files), "all fixtures normalize idempotently").
