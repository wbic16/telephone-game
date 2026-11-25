%% Hub-side CLI for libphext-erlang (Exocortical Telephone Game,
%% contract v2). Transport: argument `serve` = one JSON request per
%% line on stdin, one response per line on stdout; no argument = ONE
%% JSON object on stdin, ONE response. State crosses the wire as
%% base64 under "state". Serve lines over 8 KB travel GZ1-framed:
%% "GZ1:" + base64(gzip(line)). Wraps only this port's own libphext.
%% PGP via subprocess gpg with per-port GNUPGHOME
%% (~/telephone-erlang/gnupg unless TELEPHONE_GNUPGHOME).
-module(telephone).
-export([boot/0]).

-define(IMPL, "erlang").
-define(INDEX, {1, 1, 1, 1, 1, 1, 1, 1, 1}).
-define(KEYS, {1, 1, 1, 1, 1, 1, 1, 1, 2}).
-define(KH, {1, 1, 1, 1, 1, 1, 1, 1, 3}).
-define(EVPREFIX, [1, 1, 1, 1, 1, 1, 2, 1]).

boot() ->
    Args = init:get_plain_arguments(),
    case Args of
        ["serve"] -> serve_loop(undefined);
        _ ->
            Input = read_all(),
            case string:trim(Input) of
                "" -> ok;
                Line ->
                    Out = handle_line(Line, undefined),
                    io:put_chars(Out ++ "\n")
            end
    end,
    init:stop().

read_all() -> read_all([]).
read_all(Acc) ->
    case io:get_line(standard_io, "") of
        eof -> lists:append(lists:reverse(Acc));
        Line -> read_all([Line | Acc])
    end.

serve_loop(Cache) ->
    case io:get_line(standard_io, "") of
        eof -> ok;
        Line ->
            case string:trim(Line) of
                "" -> serve_loop(Cache);
                Trimmed ->
                    {Out, Cache2} = handle_line_state(Trimmed, Cache),
                    io:put_chars(Out ++ "\n"),
                    serve_loop(Cache2)
            end
    end.

handle_line(Line, Cache) ->
    {Out, _} = handle_line_state(Line, Cache), Out.

handle_line_state(Line, Cache) ->
    try
        Req = wire:parse(unframe(Line)),
        {Resp, Cache2} = dispatch(Req, Cache),
        Out = wire:write(Resp),
        OutBin = wire:utf8_binary(Out),
        Framed = case byte_size(OutBin) > 8192 of
                     true -> "GZ1:" ++ wire:b64(wire:gzip(OutBin));
                     false -> Out
                 end,
        {Framed, Cache2}
    catch
        Class:Reason ->
            {wire:write(#{"error" => lists:flatten(
                           io_lib:format("~p: ~p", [Class, Reason]))}), Cache}
    end.

unframe("GZ1:" ++ Rest) ->
    binary_to_list(wire:gunzip(wire:unb64(Rest)));
unframe(Line) -> Line.

state_of(Req) ->
    S = case maps:find("state", Req) of
            {ok, V} -> V;
            error -> maps:get("state_b64", Req)
        end,
    wire:unb64(S).

%% ---------------- gpg ----------------
gnupg_home() ->
    Home = case os:getenv("TELEPHONE_GNUPGHOME") of
               false -> filename:join([os:getenv("HOME"), "telephone-" ++ ?IMPL, "gnupg"]);
               V -> V
           end,
    ok = filelib:ensure_dir(filename:join(Home, "dummy")),
    ok = file:change_mode(Home, 8#700),
    Home.

tmpdir() ->
    Dir = filename:join(["/tmp", "tel-erlang-" ++
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    Dir.

%% Run gpg with input from a temp file; returns {ok, OutBinary} | {error, ErrBinary}.
run_gpg(Home, Args, Input) ->
    Dir = tmpdir(),
    InF = filename:join(Dir, "in"),
    OutF = filename:join(Dir, "out"),
    ErrF = filename:join(Dir, "err"),
    ok = file:write_file(InF, Input),
    ArgStr = string:join([shell_quote(A) || A <- Args], " "),
    Cmd = lists:flatten(io_lib:format(
            "GNUPGHOME=~s gpg --batch --yes ~s < ~s > ~s 2> ~s; echo $?",
            [shell_quote(Home), ArgStr, shell_quote(InF),
             shell_quote(OutF), shell_quote(ErrF)])),
    Status = string:trim(os:cmd(Cmd)),
    Result = case Status of
                 "0" ->
                     {ok, Data} = file:read_file(OutF),
                     {ok, Data};
                 _ ->
                     Err = case file:read_file(ErrF) of
                               {ok, E} -> E;
                               _ -> <<>>
                           end,
                     {error, Err}
             end,
    file:del_dir_r(Dir),
    Result.

shell_quote(S) ->
    "'" ++ lists:flatmap(fun($') -> "'\\''"; (C) -> [C] end, S) ++ "'".

must_gpg(Home, Args, Input) ->
    case run_gpg(Home, Args, Input) of
        {ok, Out} -> Out;
        {error, Err} -> error({"gpg failed", Err})
    end.

keygen() ->
    Home = gnupg_home(),
    Uid = "telephone-" ++ ?IMPL,
    Keys = case run_gpg(Home, ["--list-keys", "--with-colons"], <<>>) of
               {ok, K} -> binary_to_list(K);
               _ -> ""
           end,
    case string:find(Keys, "pub") of
        nomatch ->
            must_gpg(Home, ["--pinentry-mode", "loopback", "--passphrase", "",
                            "--quick-generate-key", Uid, "ed25519", "sign", "never"],
                     <<>>);
        _ -> ok
    end,
    Pub = must_gpg(Home, ["--armor", "--export", Uid], <<>>),
    #{"impl" => ?IMPL, "pubkey" => binary_to_list(Pub)}.

attest(Descriptor) ->
    Home = gnupg_home(),
    Uid = "telephone-" ++ ?IMPL,
    Sig = must_gpg(Home, ["--pinentry-mode", "loopback", "--passphrase", "",
                          "--detach-sign", "--armor", "-u", Uid],
                   wire:canon(Descriptor)),
    #{"signature" => binary_to_list(Sig)}.

verify_signature(PubkeysText, Data, SigB64) ->
    Dir = tmpdir(),
    Home = filename:join(Dir, "gnupg"),
    ok = file:make_dir(Home),
    ok = file:change_mode(Home, 8#700),
    SigF = filename:join(Dir, "sig.asc"),
    DataF = filename:join(Dir, "data"),
    ok = file:write_file(SigF, wire:unb64(SigB64)),
    ok = file:write_file(DataF, Data),
    Res = case run_gpg(Home, ["--import"], wire:latin1_binary(PubkeysText)) of
              {ok, _} ->
                  Cmd = lists:flatten(io_lib:format(
                          "GNUPGHOME=~s gpg --batch --yes --verify ~s ~s 2>/dev/null; echo $?",
                          [shell_quote(Home), shell_quote(SigF), shell_quote(DataF)])),
                  string:trim(os:cmd(Cmd)) == "0";
              _ -> false
          end,
    file:del_dir_r(Dir),
    Res.

%% ---------------- game ----------------
do_echo(Ping) ->
    #{"impl" => ?IMPL,
      "echo" => wire:sha256hex(wire:canon(#{"impl" => ?IMPL, "ping" => Ping}))}.

do_elect(Position, Candidates, Turn) ->
    Names = Candidates,
    Pool0 = [C || C <- Names, C /= ?IMPL],
    Pool = case Pool0 of [] -> Names; _ -> Pool0 end,
    Seed = wire:sha256hex(list_to_binary(
             ?IMPL ++ "-elect:" ++ Position ++ ":" ++ integer_to_list(Turn)
             ++ ":" ++ string:join(Names, ","))),
    Idx = list_to_integer(lists:sublist(Seed, 8), 16) rem length(Pool),
    #{"elect" => lists:nth(Idx + 1, Pool)}.

do_choose(Data, Position, Turn) ->
    M = phext:explode(Data),
    Pos = bump(maps:is_key(phext:coord_parse(Position), M),
               phext:coord_parse(Position), M),
    #{"op" => "insert", "coordinate" => phext:coord_string(Pos),
      "text" => ?IMPL ++ " was here, turn " ++ integer_to_list(Turn)}.

bump(false, Pos, _M) -> Pos;
bump(true, Pos, M) ->
    L = tuple_to_list(Pos),
    Pos2 = list_to_tuple(lists:sublist(L, 8) ++ [lists:nth(9, L) + 1]),
    bump(maps:is_key(Pos2, M), Pos2, M).

do_apply(Data, Step) ->
    Coord = phext:coord_parse(maps:get("coordinate", Step)),
    M = phext:explode(Data),
    false = maps:is_key(Coord, M),
    M2 = maps:put(Coord, wire:latin1_binary(maps:get("text", Step)), M),
    Result = phext:implode(M2),
    #{"state_b64" => wire:b64(Result), "state_sha256" => wire:sha256hex(Result)}.

do_init(Data) ->
    {phext:explode(Data), #{"impl" => ?IMPL, "verdict" => "pass"}}.

vfail(Detail) -> #{"impl" => ?IMPL, "verdict" => "fail", "detail" => Detail}.

do_validate(Data, Step, EventCoordS, IndexLine, Old) ->
    New = phext:explode(Data),
    Coord = phext:coord_parse(maps:get("coordinate", Step)),
    Ev = phext:coord_parse(EventCoordS),
    Placed = maps:get(Coord, New, undefined),
    Text = maps:get("text", Step),
    case Placed /= undefined andalso wire:latin1_string(Placed) == Text of
        false -> {Old, vfail("placed scroll missing or altered")};
        true ->
            case check_prior(Old, New) of
                {fail, D} -> {Old, vfail(D)};
                ok ->
                    case check_new(Old, New, Coord, Ev) of
                        {fail, D} -> {Old, vfail(D)};
                        ok ->
                            Idx = wire:latin1_string(maps:get(?INDEX, New, <<>>)),
                            case lists:suffix(rstrip_nl(IndexLine),
                                              rstrip_nl_idx(Idx)) of
                                false -> {Old, vfail("index does not record the placement")};
                                true -> {New, #{"impl" => ?IMPL, "verdict" => "pass"}}
                            end
                    end
            end
    end.

rstrip_nl(S) -> lists:reverse(drop_nl(lists:reverse(S))).
drop_nl([$\n | T]) -> drop_nl(T);
drop_nl(S) -> S.
rstrip_nl_idx(S) -> rstrip_nl(S).

check_prior(Old, New) ->
    maps:fold(
      fun(C, T, ok) ->
              case C == ?INDEX of
                  true -> ok;
                  false ->
                      case maps:get(C, New, undefined) of
                          T -> ok;
                          _ -> {fail, "prior scroll overwritten at " ++ phext:coord_string(C)}
                      end
              end;
         (_, _, Acc) -> Acc
      end, ok, Old).

check_new(Old, New, Coord, Ev) ->
    maps:fold(
      fun(C, _, ok) ->
              case maps:is_key(C, Old) orelse C == Coord orelse C == Ev of
                  true -> ok;
                  false -> {fail, "unexpected new scroll at " ++ phext:coord_string(C)}
              end;
         (_, _, Acc) -> Acc
      end, ok, New).

vfail_n(N, Msg) ->
    #{"impl" => ?IMPL, "verdict" => "fail", "placements_checked" => N,
      "first_failure" => #{"detail" => Msg}}.

do_verify(Data) ->
    M = phext:explode(Data),
    KeysText = wire:utf8_cps(maps:get(?KEYS, M, <<>>)),
    KH = string:trim(wire:latin1_string(maps:get(?KH, M, <<>>))),
    case wire:sha256hex(wire:utf8_binary(KeysText)) == KH of
        false -> vfail_n(0, "keys-hash scroll does not match keys");
        true -> verify_events(M, KeysText)
    end.

verify_events(M, KeysText) ->
    Events = maps:fold(
               fun(C, T, Acc) ->
                       case lists:sublist(tuple_to_list(C), 8) == ?EVPREFIX of
                           true -> maps:put(lists:nth(9, tuple_to_list(C)),
                                            wire:parse(T), Acc);
                           false -> Acc
                       end
               end, #{}, M),
    Seqs = lists:sort(maps:keys(Events)),
    case verify_chain(Seqs, Events, M, KeysText, null, #{}, 1) of
        {ok, Placements} -> verify_index(M, Placements);
        {fail, N, Msg} -> vfail_n(N, Msg)
    end.

verify_chain([], _Events, _M, _Keys, _Prev, Placements, _Expect) ->
    {ok, Placements};
verify_chain([S | Rest], Events, M, Keys, Prev, Placements, Expect) ->
    N = maps:size(Placements),
    case S == Expect of
        false -> {fail, N, "event seq gap at " ++ integer_to_list(S)};
        true ->
            Ev = maps:get(S, Events),
            case maps:get("prev", Ev, null) == Prev of
                false -> {fail, N, "event chain broken at seq " ++ integer_to_list(S)};
                true ->
                    Body = maps:get("body", Ev),
                    Prev2 = wire:sha256hex(wire:canon(Body)),
                    case maps:get("type", Body, null) == "placement" of
                        false -> verify_chain(Rest, Events, M, Keys, Prev2, Placements, Expect + 1);
                        true ->
                            case check_placement(Body, M, Keys, Placements, S) of
                                {ok, Placements2} ->
                                    verify_chain(Rest, Events, M, Keys, Prev2, Placements2, Expect + 1);
                                {fail, Msg} -> {fail, N, Msg}
                            end
                    end
            end
    end.

check_placement(Body, M, Keys, Placements, S) ->
    Coord = phext:coord_parse(maps:get("coord", Body)),
    case maps:is_key(Coord, Placements) of
        true -> {fail, "coordinate reused at seq " ++ integer_to_list(S)};
        false ->
            T = maps:get(Coord, M, undefined),
            case T /= undefined andalso
                 wire:sha256hex(T) == maps:get("text_sha256", Body) of
                false -> {fail, "placement scroll hash mismatch seq " ++ integer_to_list(S)};
                true ->
                    Desc = #{"turn" => maps:get("turn", Body),
                             "coordinate" => maps:get("coord", Body),
                             "scroll_sha256" => maps:get("text_sha256", Body),
                             "file_sha256" => maps:get("file_sha256", Body)},
                    case verify_signature(Keys, wire:canon(Desc), maps:get("att", Body)) of
                        false -> {fail, "attestation fails at seq " ++ integer_to_list(S)};
                        true -> {ok, maps:put(Coord, Body, Placements)}
                    end
            end
    end.

verify_index(M, Placements) ->
    N = maps:size(Placements),
    IdxText = wire:latin1_string(maps:get(?INDEX, M, <<>>)),
    Lines = [L || L <- string:split(IdxText, "\n", all),
                  L /= "", not lists:prefix("#", L)],
    case length(Lines) == N of
        false -> vfail_n(N, "index lines != placements");
        true ->
            Bad = lists:filter(
                    fun(L) ->
                            Parts = string:split(L, " ", all),
                            case length(Parts) >= 3 of
                                false -> true;
                                true ->
                                    [_Turn, CS, H | _] = Parts,
                                    Body = maps:get(phext:coord_parse(CS), Placements, undefined),
                                    Body == undefined orelse maps:get("text_sha256", Body) /= H
                            end
                    end, Lines),
            case Bad of
                [] -> #{"impl" => ?IMPL, "verdict" => "pass",
                        "placements_checked" => N, "first_failure" => null};
                [L | _] -> vfail_n(N, "index hash mismatch: " ++ lists:sublist(L, 40))
            end
    end.

%% ---------------- dispatch ----------------
dispatch(Req, Cache) ->
    Cmd = maps:get("cmd", Req),
    case Cmd of
        "id" -> {#{"impl" => ?IMPL}, Cache};
        "keygen" -> {keygen(), Cache};
        "echo" -> {do_echo(maps:get("ping", Req)), Cache};
        "elect" ->
            {arr, Candidates} = maps:get("candidates", Req),
            {do_elect(maps:get("position", Req),
                      Candidates,
                      maps:get("turn", Req)), Cache};
        "choose" ->
            {do_choose(state_of(Req), maps:get("position", Req),
                       maps:get("turn", Req)), Cache};
        "apply" -> {do_apply(state_of(Req), maps:get("step", Req)), Cache};
        "attest" -> {attest(maps:get("descriptor", Req)), Cache};
        "init" ->
            {Map, Resp} = do_init(state_of(Req)),
            {Resp, Map};
        "validate" ->
            Old = case Cache of undefined -> error("validate before init"); M -> M end,
            {NewCache, VResp} = do_validate(state_of(Req), maps:get("step", Req),
                                            maps:get("event_coord", Req),
                                            maps:get("index_line", Req), Old),
            {VResp, NewCache};
        "verify" -> {do_verify(state_of(Req)), Cache};
        _ -> error({"unknown cmd", Cmd})
    end.
