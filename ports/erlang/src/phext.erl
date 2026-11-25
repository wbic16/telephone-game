%% libphext-erlang -- an Erlang port of libphext (0.6.1 parity).
%%
%% Semantics normative from libphext-py: a phext is a byte buffer; nine
%% dimension-break bytes walk a 9-component coordinate; scroll text is
%% a maximal run of non-break bytes (newline 0x0A is ordinary text).
%% Buffers are binaries; coordinates are 9-tuples of integers, ordered
%% lexicographically; string form a.b.c/d.e.f/g.h.i.
-module(phext).
-export([coord_root/0, coord_parse/1, coord_string/1, coord_compare/2,
         phokenize/1, dephokenize/1, normalize/1, fetch/2, insert/3,
         replace/3, remove/2, explode/1, implode/1]).

breaks() -> [16#01, 16#1F, 16#1E, 16#1D, 16#1C, 16#1A, 16#19, 16#18, 16#17].

break_dim(B) ->
    case lists:member(B, breaks()) of
        false -> undefined;
        true -> dim_of(B, breaks(), 0)
    end.
dim_of(B, [B | _], D) -> D;
dim_of(B, [_ | T], D) -> dim_of(B, T, D + 1).

coord_root() -> {1, 1, 1, 1, 1, 1, 1, 1, 1}.

coord_parse(S) when is_binary(S) -> coord_parse(binary_to_list(S));
coord_parse(S) ->
    Groups = string:split(S, "/", all),
    true = (length(Groups) == 3),
    Nums = lists:flatmap(
             fun(G) -> [list_to_integer(string:trim(P))
                        || P <- string:split(G, ".", all)] end, Groups),
    true = (length(Nums) == 9),
    true = lists:all(fun(V) -> V >= 1 end, Nums),
    list_to_tuple(Nums).

coord_string(C) ->
    [A, B, Cc, D, E, F, G, H, I] = tuple_to_list(C),
    lists:flatten(io_lib:format("~B.~B.~B/~B.~B.~B/~B.~B.~B",
                                [A, B, Cc, D, E, F, G, H, I])).

coord_compare(A, B) ->
    LA = tuple_to_list(A), LB = tuple_to_list(B),
    cmp_list(LA, LB).
cmp_list([], []) -> 0;
cmp_list([X | XS], [Y | YS]) when X < Y -> -1;
cmp_list([X | _], [Y | _]) when X > Y -> 1;
cmp_list([_ | XS], [_ | YS]) -> cmp_list(XS, YS).

coord_apply_break(C, D) ->
    L = tuple_to_list(C),
    {Head, [_ | _Tail]} = lists:split(D, L),
    NewVal = lists:nth(D + 1, L) + 1,
    list_to_tuple(Head ++ [NewVal] ++ lists:duplicate(8 - D, 1)).

%% phokenize: binary -> [{Coord, TextBinary}] in walk order.
phokenize(Buffer) ->
    phok(Buffer, coord_root(), 0, 0, []).

phok(Buffer, Coord, I, RunStart, Acc) when I < byte_size(Buffer) ->
    B = binary:at(Buffer, I),
    case break_dim(B) of
        undefined -> phok(Buffer, Coord, I + 1, RunStart, Acc);
        D ->
            Acc2 = case I > RunStart of
                       true -> [{Coord, binary:part(Buffer, RunStart, I - RunStart)} | Acc];
                       false -> Acc
                   end,
            phok(Buffer, coord_apply_break(Coord, D), I + 1, I + 1, Acc2)
    end;
phok(Buffer, Coord, _I, RunStart, Acc) ->
    Acc2 = case byte_size(Buffer) > RunStart of
               true -> [{Coord, binary:part(Buffer, RunStart, byte_size(Buffer) - RunStart)} | Acc];
               false -> Acc
           end,
    lists:reverse(Acc2).

emit_advance(Loc, Target, Acc) ->
    case coord_compare(Loc, Target) of
        -1 ->
            LA = tuple_to_list(Loc), TA = tuple_to_list(Target),
            Dim = first_diff(LA, TA, 0),
            B = lists:nth(Dim + 1, breaks()),
            Acc1 = lists:duplicate(lists:nth(Dim + 1, TA) - lists:nth(Dim + 1, LA), B) ++ Acc,
            Acc2 = lists:foldl(
                     fun(Lower, A) ->
                         Bl = lists:nth(Lower + 1, breaks()),
                         lists:duplicate(lists:nth(Lower + 1, TA) - 1, Bl) ++ A
                     end, Acc1, lists:seq(Dim + 1, 8)),
            {Target, Acc2};
        _ -> {Loc, Acc}
    end.
first_diff([X | _], [Y | _], D) when X /= Y -> D;
first_diff([_ | XS], [_ | YS], D) -> first_diff(XS, YS, D + 1).

%% dephokenize over a reversed byte-list accumulator for speed.
dephokenize(Stack) ->
    Sorted = lists:sort(fun({C1, _}, {C2, _}) -> coord_compare(C1, C2) =< 0 end, Stack),
    {_, RevBytes} = lists:foldl(
        fun({_C, <<>>}, State) -> State;
           ({C, Text}, {Loc, Acc}) ->
                {Loc2, Acc2} = emit_advance(Loc, C, Acc),
                {Loc2, lists:reverse(binary_to_list(Text)) ++ Acc2}
        end, {coord_root(), []}, Sorted),
    list_to_binary(lists:reverse(RevBytes)).

dephokenize_in_order(Stack) ->
    {_, RevBytes} = lists:foldl(
        fun({C, Text}, {Loc, Acc}) ->
                {Loc2, Acc2} = emit_advance(Loc, C, Acc),
                {Loc2, lists:reverse(binary_to_list(Text)) ++ Acc2}
        end, {coord_root(), []}, Stack),
    list_to_binary(lists:reverse(RevBytes)).

normalize(Buffer) -> dephokenize(phokenize(Buffer)).

fetch(Buffer, Coord) ->
    case lists:keyfind(Coord, 1, phokenize(Buffer)) of
        {_, Text} -> Text;
        false -> <<>>
    end.

update(Buffer, Coord, Scroll, Overwrite) ->
    Items = phokenize(Buffer),
    New = {Coord, Scroll},
    {Result, _Appended} = lists:foldl(
        fun({C, _} = PS, {Acc, App}) ->
            Cmp = coord_compare(C, Coord),
            cond_append(Cmp, PS, New, Overwrite, Acc, App)
        end, {[], false}, Items),
    Result2 = case _Appended of true -> Result; false -> Result ++ [New] end,
    dephokenize_in_order(Result2).

cond_append(1, PS, New, _Ow, Acc, false) -> {Acc ++ [New, PS], true};
cond_append(0, {_C, Old}, {_Coord, Scroll}, false, Acc, false) ->
    {Acc ++ [{_Coord, <<Old/binary, Scroll/binary>>}], true};
cond_append(0, _PS, New, true, Acc, false) -> {Acc ++ [New], true};
cond_append(_, PS, _New, _Ow, Acc, App) -> {Acc ++ [PS], App}.

insert(Buffer, Coord, Scroll) -> update(Buffer, Coord, Scroll, false).
replace(Buffer, Coord, Scroll) -> update(Buffer, Coord, Scroll, true).

%% remove: replace with "" then normalize -- coordinate-preserving.
remove(Buffer, Coord) -> normalize(update(Buffer, Coord, <<>>, true)).

explode(Buffer) -> maps:from_list(phokenize(Buffer)).

implode(Map) -> dephokenize(maps:to_list(Map)).
