%% DynamicPhext: capacity-managed dynamic array scroll store.
%% Start at capacity 1, double when full on append, shrink only at
%% quarter load (never half -- that thrashes). Backing store is a
%% tuple (random access for binary search); state is an immutable
%% record threaded through calls, in the Erlang functional idiom.
-module(dynamic_phext).
-export([new/0, new/1, new/2, load/2, length/1, capacity/1, resize_count/1,
         elements_copied/1, scrolls/1, serialize/1, fetch/2, contains/2,
         append/3, insert/3, replace/3, remove/2]).
-record(dp, {data = {}, n = 0, capacity = 1, resize_count = 0,
             elements_copied = 0, shrink_divisor = 4}).

new() -> new(<<>>).
new(Buffer) -> new(Buffer, 4).
new(Buffer, ShrinkDivisor) ->
    true = (ShrinkDivisor >= 2),
    DP = #dp{data = {undefined}, shrink_divisor = ShrinkDivisor},
    case Buffer of
        <<>> -> DP;
        _ -> load(DP, Buffer)
    end.

load(DP, Buffer) ->
    Fresh = #dp{data = {undefined}, shrink_divisor = DP#dp.shrink_divisor},
    lists:foldl(fun(PS, Acc) -> push(Acc, PS) end, Fresh,
                phext:phokenize(Buffer)).

length(#dp{n = N}) -> N.
capacity(#dp{capacity = C}) -> C.
resize_count(#dp{resize_count = R}) -> R.
elements_copied(#dp{elements_copied = E}) -> E.

resize(DP = #dp{data = Data, n = N}, NewCap) ->
    NewData = list_to_tuple(
                [element_at(Data, I) || I <- lists:seq(1, N)]
                ++ lists:duplicate(NewCap - N, undefined)),
    DP#dp{data = NewData, capacity = NewCap,
          resize_count = DP#dp.resize_count + 1,
          elements_copied = DP#dp.elements_copied + N}.

element_at(_Data, I) when I < 1 -> undefined;
element_at(Data, I) when I =< tuple_size(Data) -> element(I, Data);
element_at(_Data, _I) -> undefined.

grow_if_full(DP = #dp{n = N, capacity = C}) when N == C ->
    resize(DP, 2 * C);
grow_if_full(DP) -> DP.

shrink_if_sparse(DP = #dp{n = N, capacity = C, shrink_divisor = SD})
  when C > 1, N =< C div SD ->
    resize(DP, max(1, C div 2));
shrink_if_sparse(DP) -> DP.

push(DP0, PS) ->
    DP = grow_if_full(DP0),
    DP#dp{data = setelement(DP#dp.n + 1, DP#dp.data, PS), n = DP#dp.n + 1}.

scrolls(#dp{data = Data, n = N}) ->
    [element(I, Data) || I <- lists:seq(1, N)].

serialize(DP) -> phext:dephokenize(scrolls(DP)).

%% binary search: {Index0Based, Found}
find(#dp{data = Data, n = N}, Coord) -> find(Data, Coord, 0, N).
find(_Data, _Coord, Lo, Hi) when Lo >= Hi -> {Lo, false};
find(Data, Coord, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    {C, _} = element(Mid + 1, Data),
    case phext:coord_compare(C, Coord) of
        -1 -> find(Data, Coord, Mid + 1, Hi);
        1 -> find(Data, Coord, Lo, Mid);
        0 -> {Mid, true}
    end.

fetch(DP, Coord) ->
    case find(DP, Coord) of
        {Idx, true} -> {_, Text} = element(Idx + 1, DP#dp.data), Text;
        _ -> <<>>
    end.

contains(DP, Coord) -> {_, F} = find(DP, Coord), F.

append(DP = #dp{data = Data, n = N}, Coord, Text) ->
    case N > 0 of
        true ->
            {Tail, _} = element(N, Data),
            true = (phext:coord_compare(Coord, Tail) > 0);
        false -> ok
    end,
    case Text of
        <<>> -> DP;
        _ -> push(DP, {Coord, Text})
    end.

update(DP, Coord, Text, Overwrite) ->
    {Idx, Found} = find(DP, Coord),
    case Found of
        true ->
            case Text of
                <<>> ->
                    case Overwrite of
                        true -> remove_at(DP, Idx);
                        false -> DP
                    end;
                _ ->
                    {_, Old} = element(Idx + 1, DP#dp.data),
                    NewText = case Overwrite of
                                  true -> Text;
                                  false -> <<Old/binary, Text/binary>>
                              end,
                    DP#dp{data = setelement(Idx + 1, DP#dp.data, {Coord, NewText})}
            end;
        false ->
            case Text of
                <<>> -> DP;
                _ ->
                    DP1 = grow_if_full(DP),
                    Shifted = lists:foldl(
                        fun(I, D) -> setelement(I + 1, D, element(I, D)) end,
                        DP1#dp.data, lists:seq(DP1#dp.n, Idx + 1, -1)),
                    DP1#dp{data = setelement(Idx + 1, Shifted, {Coord, Text}),
                           n = DP1#dp.n + 1}
            end
    end.

insert(DP, Coord, Text) -> update(DP, Coord, Text, false).
replace(DP, Coord, Text) -> update(DP, Coord, Text, true).

remove_at(DP = #dp{data = Data, n = N}, Idx) ->
    Shifted = lists:foldl(
        fun(I, D) -> setelement(I, D, element(I + 1, D)) end,
        Data, lists:seq(Idx + 1, N - 1)),
    DP2 = DP#dp{data = setelement(N, Shifted, undefined), n = N - 1},
    shrink_if_sparse(DP2).

remove(DP, Coord) ->
    case find(DP, Coord) of
        {Idx, true} -> remove_at(DP, Idx);
        _ -> DP
    end.
