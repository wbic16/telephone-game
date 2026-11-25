%% TransitivePhext: scroll store over a BranchingMap at depth 9.
%% A BranchingMap is a map of dimension `depth` branching into maps of
%% one fewer dimension, recursively, down to leaves holding scroll
%% text. One map lookup per dimension. Here the branching map is a
%% nested Erlang map; leaves are binaries.
-module(transitive_phext).
-export([new/0, new/1, load/2, depth/1, length/1, scrolls/1, serialize/1,
         fetch/2, contains/2, insert/3, replace/3, remove/2, append/3,
         branching_new/1, branching_fetch/3, branching_put/3,
         branching_remove/2, branching_items/2]).

-record(tp, {map = #{}, depth = 9, count = 0}).

%% ---- BranchingMap primitives (nested maps) ----
branching_new(Depth) when Depth >= 1 -> {branching, Depth, #{}}.

branching_fetch({branching, Depth, Root}, Key, Default) ->
    case fetch_rec(Root, tuple_to_list(Key), Depth) of
        {ok, V} -> V;
        not_found -> Default
    end.

fetch_rec(Node, [Comp], 1) ->
    case maps:find(Comp, Node) of
        {ok, V} -> {ok, V};
        error -> not_found
    end;
fetch_rec(Node, [Comp | Rest], Level) ->
    case maps:find(Comp, Node) of
        {ok, Child} -> fetch_rec(Child, Rest, Level - 1);
        error -> not_found
    end.

%% returns {NewBranching, Created}
branching_put({branching, Depth, Root}, Key, Value) ->
    {NewRoot, Created} = put_rec(Root, tuple_to_list(Key), Depth, Value),
    {{branching, Depth, NewRoot}, Created}.

put_rec(Node, [Comp], 1, Value) ->
    Created = not maps:is_key(Comp, Node),
    {maps:put(Comp, Value, Node), Created};
put_rec(Node, [Comp | Rest], Level, Value) ->
    Child = maps:get(Comp, Node, #{}),
    {NewChild, Created} = put_rec(Child, Rest, Level - 1, Value),
    {maps:put(Comp, NewChild, Node), Created}.

%% returns {NewBranching, Removed}
branching_remove({branching, Depth, Root}, Key) ->
    {NewRoot, Removed} = remove_rec(Root, tuple_to_list(Key), Depth),
    {{branching, Depth, NewRoot}, Removed}.

remove_rec(Node, [Comp], 1) ->
    case maps:is_key(Comp, Node) of
        true -> {maps:remove(Comp, Node), true};
        false -> {Node, false}
    end;
remove_rec(Node, [Comp | Rest], Level) ->
    case maps:find(Comp, Node) of
        error -> {Node, false};
        {ok, Child} ->
            {NewChild, Removed} = remove_rec(Child, Rest, Level - 1),
            case Removed andalso map_size(NewChild) == 0 of
                true -> {maps:remove(Comp, Node), true};
                false -> {maps:put(Comp, NewChild, Node), Removed}
            end
    end.

branching_items({branching, Depth, Root}, _Unused) ->
    lists:sort(items_rec(Root, [], Depth)).
items_rec(Node, Prefix, 1) ->
    [{list_to_tuple(Prefix ++ [Comp]), V} || {Comp, V} <- maps:to_list(Node)];
items_rec(Node, Prefix, Level) ->
    lists:flatmap(fun({Comp, Child}) -> items_rec(Child, Prefix ++ [Comp], Level - 1) end,
                  maps:to_list(Node)).

%% ---- TransitivePhext ----
new() -> new(<<>>).
new(Buffer) ->
    TP = #tp{map = branching_new(9)},
    case Buffer of
        <<>> -> TP;
        _ -> load(TP, Buffer)
    end.

load(_TP, Buffer) ->
    lists:foldl(
      fun({C, T}, Acc) ->
          {M, Created} = branching_put(Acc#tp.map, C, T),
          Acc#tp{map = M, count = Acc#tp.count + bool_int(Created)}
      end, #tp{map = branching_new(9)}, phext:phokenize(Buffer)).

bool_int(true) -> 1;
bool_int(false) -> 0.

depth(#tp{depth = D}) -> D.
length(#tp{count = N}) -> N.
scrolls(TP) -> branching_items(TP#tp.map, none).
serialize(TP) -> phext:dephokenize(scrolls(TP)).

fetch(TP, Coord) -> branching_fetch(TP#tp.map, Coord, <<>>).
contains(TP, Coord) ->
    branching_fetch(TP#tp.map, Coord, undefined) /= undefined.

update(TP, Coord, Text, Overwrite) ->
    case Text of
        <<>> ->
            case Overwrite of
                true -> remove(TP, Coord);
                false -> TP
            end;
        _ ->
            NewText = case Overwrite of
                          true -> Text;
                          false ->
                              Old = branching_fetch(TP#tp.map, Coord, <<>>),
                              <<Old/binary, Text/binary>>
                      end,
            {M, Created} = branching_put(TP#tp.map, Coord, NewText),
            TP#tp{map = M, count = TP#tp.count + bool_int(Created)}
    end.

insert(TP, Coord, Text) -> update(TP, Coord, Text, false).
replace(TP, Coord, Text) -> update(TP, Coord, Text, true).
append(TP, Coord, Text) -> insert(TP, Coord, Text).

remove(TP, Coord) ->
    {M, Removed} = branching_remove(TP#tp.map, Coord),
    TP#tp{map = M, count = TP#tp.count - bool_int(Removed)}.
