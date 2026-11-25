% libphext-prolog — a SWI-Prolog port of libphext (0.6.1 parity).
%
% Semantics are normative from libphext-py: a phext is a byte buffer;
% nine dimension-break bytes walk a 9-component coordinate; scroll text
% is a maximal run of non-break bytes (newline 0x0A is ordinary text).
% Buffers and scroll text are lists of byte codes; coordinates are
% lists of 9 integers (standard term order on lists is the
% lexicographic coordinate order). String form: a.b.c/d.e.f/g.h.i.

:- module(phext,
          [ coord_parse/2, coord_string/2, coord_root/1,
            phokenize/2, dephokenize/2, normalize/2, fetch_scroll/3,
            update_scroll/5, insert_scroll/4, replace_scroll/4,
            remove_scroll/3, explode/2, implode/2,
            dynamic_new/2, dynamic_load/2, dynamic_serialize/2,
            dynamic_fetch/3, dynamic_insert/3, dynamic_replace/3,
            dynamic_remove/2, dynamic_append/3, dynamic_len/2,
            dynamic_capacity/2, dynamic_resize_count/2,
            dynamic_elements_copied/2,
            transitive_new/1, transitive_new/2, transitive_load/2,
            transitive_serialize/2, transitive_fetch/3,
            transitive_insert/3, transitive_replace/3,
            transitive_remove/2, transitive_append/3,
            transitive_len/2, transitive_depth/2,
            branching_new/2, branching_fetch/3, branching_put/4,
            branching_remove/3, branching_items/2, branching_len/2
          ]).
:- use_module(library(rbtrees)).

% Dimension breaks in dimension order (library .. scroll).
dimension_breaks([1, 31, 30, 29, 28, 26, 25, 24, 23]).

break_dim(Byte, Dim) :-
    dimension_breaks(Breaks),
    nth0(Dim, Breaks, Byte), !.

% ------------------------------------------------------------------
% Coordinates

coord_root([1, 1, 1, 1, 1, 1, 1, 1, 1]).

coord_parse(String, Coord) :-
    ( string(String) -> string_codes(String, Codes)
    ; atom(String) -> atom_codes(String, Codes)
    ; Codes = String ),
    split_codes(Codes, 0'/, [G1, G2, G3]),
    split_codes(G1, 0'., P1),
    split_codes(G2, 0'., P2),
    split_codes(G3, 0'., P3),
    append([P1, P2, P3], NumCodes),
    length(NumCodes, 9),
    maplist(codes_number, NumCodes, Coord),
    maplist(coord_ge1, Coord), !.
coord_parse(String, _) :-
    throw(error(invalid_coordinate(String), _)).

coord_ge1(N) :- N >= 1.

codes_number(Codes, N) :-
    number_codes(N, Codes),
    integer(N).

split_codes([], _, [[]]) :- !.
split_codes([Sep|Rest], Sep, [[]|Groups]) :-
    !, split_codes(Rest, Sep, Groups).
split_codes([C|Rest], Sep, [[C|Head]|Groups]) :-
    split_codes(Rest, Sep, [Head|Groups]).

coord_string(Coord, String) :-
    Coord = [A, B, C, D, E, F, G, H, I],
    format(string(String), "~d.~d.~d/~d.~d.~d/~d.~d.~d",
           [A, B, C, D, E, F, G, H, I]).

coord_apply_break(Coord, Dim, Out) :-
    nth0(Dim, Coord, Old),
    New is Old + 1,
    replace_nth0(Coord, Dim, New, Mid),
    LowerStart is Dim + 1,
    reset_lowers(Mid, LowerStart, Out).

replace_nth0([_|T], 0, X, [X|T]) :- !.
replace_nth0([H|T], N, X, [H|R]) :-
    N1 is N - 1,
    replace_nth0(T, N1, X, R).

reset_lowers(Coord, From, Coord) :- From >= 9, !.
reset_lowers(Coord, From, Out) :-
    replace_nth0(Coord, From, 1, Mid),
    Next is From + 1,
    reset_lowers(Mid, Next, Out).

% ------------------------------------------------------------------
% Core buffer API. A positioned scroll is a term ps(Coord, Text).

% phokenize: ordered list of ps(Coord, Text) in Buffer.
phokenize(Buffer, Scrolls) :-
    coord_root(Root),
    phokenize_(Buffer, Root, [], [], RevScrolls),
    reverse(RevScrolls, Scrolls).

% RunRev accumulates the current run reversed; AccRev accumulates
% finished scrolls reversed. Every clause's recursive call is the
% last goal (a true loop): real phexts contain multi-megabyte runs
% of consecutive break bytes, and a frame per byte overflows the
% stack (the earlier if-then-else and post-recursion-emit forms both
% did exactly that).
phokenize_([], Coord, RunRev, AccRev, Scrolls) :-
    !,
    prepend_run(RunRev, Coord, AccRev, Scrolls).
phokenize_([Byte|Rest], Coord, RunRev, AccRev, Scrolls) :-
    break_dim(Byte, Dim), !,
    coord_apply_break(Coord, Dim, Next),
    prepend_run(RunRev, Coord, AccRev, AccRev1),
    phokenize_(Rest, Next, [], AccRev1, Scrolls).
phokenize_([Byte|Rest], Coord, RunRev, AccRev, Scrolls) :-
    phokenize_(Rest, Coord, [Byte|RunRev], AccRev, Scrolls).

prepend_run([], _, Scrolls, Scrolls) :- !.
prepend_run(RunRev, Coord, Scrolls, [ps(Coord, Text)|Scrolls]) :-
    reverse(RunRev, Text).

first_diff([A|_], [B|_], Dim, Dim) :- A \= B, !.
first_diff([_|As], [_|Bs], N, Dim) :-
    N1 is N + 1,
    first_diff(As, Bs, N1, Dim).

advance_lowers(Loc, _, From, [], Loc) :- From >= 9, !.
advance_lowers(Loc, Target, From, Breaks, Final) :-
    nth0(From, Target, Want),
    dimension_breaks(DB),
    nth0(From, DB, Break),
    Count is Want - 1,
    length(Rep, Count), maplist(=(Break), Rep),
    replace_nth0(Loc, From, Want, Mid),
    Next is From + 1,
    advance_lowers(Mid, Target, Next, Rest, Final),
    append(Rep, Rest, Breaks).

concat_all(Chunks, Out) :-
    concat_rev(Chunks, [], Rev),
    reverse(Rev, Out).

% Accumulate the output reversed (tail-recursive consing), then
% reverse once at the end. (Difference-list append via append_dl
% grew the stack linearly on multi-megabyte scrolls.)
concat_rev([], Acc, Acc).
concat_rev([H|T], Acc, Out) :-
    prepend_rev(H, Acc, Acc1),
    concat_rev(T, Acc1, Out).

prepend_rev([], Acc, Acc).
prepend_rev([X|Xs], Acc, Out) :-
    prepend_rev(Xs, [X|Acc], Out).

% dephokenize: canonical bytes — sorted coordinate order, advancing
% from the root; empty scrolls contribute nothing.
dephokenize(Stack, Bytes) :-
    sort(Stack, Sorted),
    coord_root(Root),
    dephokenize_(Sorted, Root, Chunks),
    concat_all(Chunks, Bytes).

dephokenize_([], _, []).
dephokenize_([ps(_, Text)|Rest], Loc, Chunks) :-
    Text = [], !,
    dephokenize_(Rest, Loc, Chunks).
dephokenize_([ps(Coord, Text)|Rest], Loc, [Breaks, Text|Chunks]) :-
    advance_to(Loc, Coord, Breaks, NewLoc),
    dephokenize_(Rest, NewLoc, Chunks).

% normalize = phokenize then dephokenize.
normalize(Buffer, Out) :-
    phokenize(Buffer, Scrolls),
    dephokenize(Scrolls, Out).

% fetch: text at Coord, or [] for a gap coordinate.
fetch_scroll(Buffer, Coord, Text) :-
    phokenize(Buffer, Scrolls),
    ( member(ps(Coord, Found), Scrolls) -> Text = Found ; Text = [] ).

update_scroll(Buffer, Coord, Scroll, Overwrite, Out) :-
    phokenize(Buffer, Items),
    update_items(Items, Coord, Scroll, Overwrite, Result),
    serialize_in_order(Result, Out).

update_items([], Coord, Scroll, _, [ps(Coord, Scroll)]).
update_items([ps(C, Text)|Rest], Coord, Scroll, Overwrite, Result) :-
    ( C == Coord ->
        ( Overwrite == true ->
            Merged = Scroll
        ; append(Text, Scroll, Merged) ),
        Result = [ps(Coord, Merged)|Rest]
    ; C @> Coord ->
        Result = [ps(Coord, Scroll), ps(C, Text)|Rest]
    ; Result = [ps(C, Text)|Tail],
      update_items(Rest, Coord, Scroll, Overwrite, Tail) ).

% Serialize a coordinate-ordered ps list without re-sorting (the
% update path's placed order), exactly as libphext-py's update.
serialize_in_order(Stack, Bytes) :-
    coord_root(Root),
    serialize_(Stack, Root, Chunks),
    concat_all(Chunks, Bytes).

serialize_([], _, []).
serialize_([ps(Coord, Text)|Rest], Loc, [Breaks, Text|Chunks]) :-
    advance_to(Loc, Coord, Breaks, NewLoc),
    serialize_(Rest, NewLoc, Chunks).

advance_to(Loc, Target, Breaks, NewLoc) :-
    ( Loc @>= Target ->
        Breaks = [], NewLoc = Loc
    ; first_diff(Loc, Target, 0, Dim),
      nth0(Dim, Loc, Here), nth0(Dim, Target, There),
      dimension_breaks(DB),
      nth0(Dim, DB, Break),
      Count is There - Here,
      length(Rep, Count), maplist(=(Break), Rep),
      replace_nth0(Loc, Dim, There, Mid),
      LowerStart is Dim + 1,
      reset_lowers(Mid, LowerStart, Reset),
      advance_lowers(Reset, Target, LowerStart, Rest, _),
      append(Rep, Rest, Breaks),
      NewLoc = Target ).

% insert: existing text is prepended to the inserted text.
insert_scroll(Buffer, Coord, Scroll, Out) :-
    update_scroll(Buffer, Coord, Scroll, false, Out).

% replace: overwrite the scroll at Coord.
replace_scroll(Buffer, Coord, Scroll, Out) :-
    update_scroll(Buffer, Coord, Scroll, true, Out).

% remove: replace with "" then normalize — coordinate-preserving:
% the removed coordinate reads "" and neighbours do not shift.
remove_scroll(Buffer, Coord, Out) :-
    update_scroll(Buffer, Coord, [], true, Mid),
    normalize(Mid, Out).

% explode: map form — an rb-tree from Coord to Text.
explode(Buffer, Tree) :-
    phokenize(Buffer, Scrolls),
    rb_empty(Tree0),
    fold_ps(Scrolls, Tree0, Tree).

fold_ps([], Tree, Tree).
fold_ps([ps(C, T)|Rest], Tree0, Tree) :-
    rb_insert(Tree0, C, T, Tree1),
    fold_ps(Rest, Tree1, Tree).

pair_ps(K-V, ps(K, V)).

% implode: canonical bytes from a Coord -> Text rb-tree.
implode(Tree, Bytes) :-
    rb_visit(Tree, Pairs),
    maplist(pair_ps, Pairs, Stack),
    dephokenize(Stack, Bytes).

% ------------------------------------------------------------------
% DynamicPhext: capacity-managed dynamic array scroll store.
% The store is a mutable compound dyn(Slots, Cap, N, ShrinkDiv, RC,
% EC); Slots is a compound slots/Arity whose args are ps terms.
% Start at capacity 1, double when full, shrink only at quarter load.

dynamic_new(D, ShrinkDivisor) :-
    ShrinkDivisor >= 2,
    Slots =.. [slots, nil],
    D = dyn(Slots, 1, 0, ShrinkDivisor, 0, 0).

dynamic_new(D) :- dynamic_new(D, 4).

dynamic_capacity(D, Cap) :- arg(2, D, Cap).
dynamic_len(D, N) :- arg(3, D, N).
dynamic_resize_count(D, RC) :- arg(5, D, RC).
dynamic_elements_copied(D, EC) :- arg(6, D, EC).

dyn_resize(D, NewCap) :-
    arg(1, D, Slots), arg(3, D, N),
    length(Args, NewCap),
    NewSlots =.. [slots|Args],
    copy_slots(Slots, NewSlots, 1, N),
    Start is N + 1,
    fill_slots(NewSlots, Start, NewCap),
    nb_setarg(1, D, NewSlots),
    nb_setarg(2, D, NewCap),
    arg(5, D, RC), RC1 is RC + 1, nb_setarg(5, D, RC1),
    arg(6, D, EC), EC1 is EC + N, nb_setarg(6, D, EC1).

copy_slots(_, _, I, N) :- I > N, !.
copy_slots(From, To, I, N) :-
    arg(I, From, V), nb_setarg(I, To, V),
    I1 is I + 1,
    copy_slots(From, To, I1, N).

fill_slots(_, I, Cap) :- I > Cap, !.
fill_slots(Slots, I, Cap) :-
    nb_setarg(I, Slots, nil),
    I1 is I + 1,
    fill_slots(Slots, I1, Cap).

dyn_grow_if_full(D) :-
    arg(2, D, Cap), arg(3, D, N),
    ( N =:= Cap -> NewCap is Cap * 2, dyn_resize(D, NewCap) ; true ).

dyn_shrink_if_sparse(D) :-
    arg(2, D, Cap), arg(3, D, N), arg(4, D, SD),
    ( Cap > 1, N =< Cap // SD ->
        NewCap is max(1, Cap // 2), dyn_resize(D, NewCap)
    ; true ).

dyn_push(D, PS) :-
    dyn_grow_if_full(D),
    arg(1, D, Slots), arg(3, D, N),
    I is N + 1,
    nb_setarg(I, Slots, PS),
    N1 is N + 1, nb_setarg(3, D, N1).

dynamic_load(D, Buffer) :-
    arg(4, D, SD),
    Slots =.. [slots, nil],
    nb_setarg(1, D, Slots), nb_setarg(2, D, 1), nb_setarg(3, D, 0),
    nb_setarg(5, D, 0), nb_setarg(6, D, 0),
    nb_setarg(4, D, SD),
    phokenize(Buffer, Scrolls),
    maplist(dyn_push(D), Scrolls).

dynamic_scrolls(D, Scrolls) :-
    arg(1, D, Slots), arg(3, D, N),
    dyn_collect(Slots, 1, N, Scrolls).

dyn_collect(_, I, N, []) :- I > N, !.
dyn_collect(Slots, I, N, [PS|Rest]) :-
    arg(I, Slots, PS),
    I1 is I + 1,
    dyn_collect(Slots, I1, N, Rest).

dynamic_serialize(D, Bytes) :-
    dynamic_scrolls(D, Scrolls),
    dephokenize(Scrolls, Bytes).

% Binary search over the coordinate-ordered slots: Index is 0-based;
% Found is true/false.
dyn_find(D, Coord, Index, Found) :-
    arg(3, D, N),
    dyn_find_(D, Coord, 0, N, Index, Found).

dyn_find_(_, _, Lo, Hi, Lo, false) :- Lo >= Hi, !.
dyn_find_(D, Coord, Lo, Hi, Index, Found) :-
    Mid is (Lo + Hi) // 2,
    arg(1, D, Slots),
    I is Mid + 1,
    arg(I, Slots, ps(Here, _)),
    ( Here == Coord ->
        Index = Mid, Found = true
    ; Here @< Coord ->
        Lo1 is Mid + 1,
        dyn_find_(D, Coord, Lo1, Hi, Index, Found)
    ; dyn_find_(D, Coord, Lo, Mid, Index, Found) ).

dynamic_fetch(D, Coord, Text) :-
    dyn_find(D, Coord, Index, Found),
    ( Found == true ->
        arg(1, D, Slots), I is Index + 1,
        arg(I, Slots, ps(_, Text))
    ; Text = [] ).

dynamic_append(D, Coord, Text) :-
    arg(3, D, N),
    ( N > 0 ->
        arg(1, D, Slots), arg(N, Slots, ps(Tail, _)),
        ( Coord @> Tail -> true
        ; throw(error(append_past_tail(Coord), _)) )
    ; true ),
    ( Text == [] -> true ; dyn_push(D, ps(Coord, Text)) ).

dyn_remove_at(D, Index) :-
    arg(1, D, Slots), arg(3, D, N),
    Start is Index + 1,
    dyn_shift_left(Slots, Start, N),
    nb_setarg(N, Slots, nil),
    N1 is N - 1,
    nb_setarg(3, D, N1),
    dyn_shrink_if_sparse(D).

dyn_shift_left(_, I, N) :- I >= N, !.
dyn_shift_left(Slots, I, N) :-
    I1 is I + 1,
    arg(I1, Slots, V),
    nb_setarg(I, Slots, V),
    dyn_shift_left(Slots, I1, N).

dynamic_update(D, Coord, Text, Overwrite) :-
    dyn_find(D, Coord, Index, Found),
    ( Found == true ->
        ( Text == [] ->
            ( Overwrite == true -> dyn_remove_at(D, Index) ; true )
        ; arg(1, D, Slots), I is Index + 1,
          ( Overwrite == true ->
              nb_setarg(I, Slots, ps(Coord, Text))
          ; arg(I, Slots, ps(_, Old)),
            append(Old, Text, Merged),
            nb_setarg(I, Slots, ps(Coord, Merged)) ) )
    ; Text == [] ->
        true
    ; dyn_grow_if_full(D),
      arg(1, D, Slots), arg(3, D, N),
      dyn_shift_right(Slots, N, Index),
      I is Index + 1,
      nb_setarg(I, Slots, ps(Coord, Text)),
      N1 is N + 1, nb_setarg(3, D, N1) ).

dyn_shift_right(_, I, Index) :- I =< Index, !.
dyn_shift_right(Slots, I, Index) :-
    arg(I, Slots, V),
    I1 is I + 1,
    nb_setarg(I1, Slots, V),
    I0 is I - 1,
    dyn_shift_right(Slots, I0, Index).

dynamic_insert(D, Coord, Text) :- dynamic_update(D, Coord, Text, false).
dynamic_replace(D, Coord, Text) :- dynamic_update(D, Coord, Text, true).

dynamic_remove(D, Coord) :-
    dyn_find(D, Coord, Index, Found),
    ( Found == true -> dyn_remove_at(D, Index) ; true ).

% ------------------------------------------------------------------
% BranchingMap: a hash map (rb-tree) of dimension Depth branching
% into maps of one fewer dimension, recursively, down to leaves.
% Store term: bm(RootTree, Depth, Count). Internal values are
% node(Tree) compounds; leaves are code lists.
branching_new(BM, Depth) :-
    Depth >= 1,
    rb_empty(Tree),
    BM = bm(Tree, Depth, 0).

branching_len(BM, Count) :- arg(3, BM, Count).

branching_fetch(BM, Key, Value) :-
    arg(1, BM, Tree), arg(2, BM, Depth),
    bm_fetch(Tree, Key, 1, Depth, Value).

bm_fetch(Tree, [K], Depth, Depth, Value) :-
    rb_lookup(K, Value, Tree), !.
bm_fetch(Tree, [K|Rest], Level, Depth, Value) :-
    Level < Depth,
    rb_lookup(K, node(Child), Tree),
    Level1 is Level + 1,
    bm_fetch(Child, Rest, Level1, Depth, Value).

branching_put(BM, Key, Value, Created) :-
    arg(1, BM, Tree), arg(2, BM, Depth),
    bm_put(Tree, Key, 1, Depth, Value, NewTree, Created),
    nb_setarg(1, BM, NewTree),
    ( Created == true ->
        arg(3, BM, Count), Count1 is Count + 1,
        nb_setarg(3, BM, Count1)
    ; true ).

bm_put(Tree, [K], Depth, Depth, Value, NewTree, Created) :-
    ( rb_lookup(K, _, Tree) -> Created = false ; Created = true ),
    rb_insert(Tree, K, Value, NewTree).
bm_put(Tree, [K|Rest], Level, Depth, Value, NewTree, Created) :-
    Level < Depth,
    ( rb_lookup(K, node(Child), Tree) -> true
    ; rb_empty(Child) ),
    Level1 is Level + 1,
    bm_put(Child, Rest, Level1, Depth, Value, NewChild, Created),
    rb_insert(Tree, K, node(NewChild), NewTree).

branching_remove(BM, Key, Removed) :-
    arg(1, BM, Tree), arg(2, BM, Depth),
    ( bm_remove(Tree, Key, 1, Depth, NewTree) ->
        Removed = true,
        nb_setarg(1, BM, NewTree),
        arg(3, BM, Count), Count1 is Count - 1,
        nb_setarg(3, BM, Count1)
    ; Removed = false ).

bm_remove(Tree, [K], Depth, Depth, NewTree) :-
    rb_delete(Tree, K, NewTree).
bm_remove(Tree, [K|Rest], Level, Depth, NewTree) :-
    Level < Depth,
    rb_lookup(K, node(Child), Tree),
    Level1 is Level + 1,
    bm_remove(Child, Rest, Level1, Depth, NewChild),
    ( rb_empty(NewChild) ->
        rb_delete(Tree, K, NewTree)
    ; rb_insert(Tree, K, node(NewChild), NewTree) ).

branching_items(BM, Items) :-
    arg(1, BM, Tree), arg(2, BM, Depth),
    bm_items(Tree, [], 1, Depth, Items).

bm_leaf_item(Prefix, K-V, Key-V) :-
    append(Prefix, [K], Key).

bm_items(Tree, Prefix, Depth, Depth, Items) :-
    rb_visit(Tree, Pairs),
    maplist(bm_leaf_item(Prefix), Pairs, Items).
bm_items(Tree, Prefix, Level, Depth, Items) :-
    Level < Depth,
    rb_visit(Tree, Pairs),
    Level1 is Level + 1,
    bm_items_(Pairs, Prefix, Level1, Depth, Items).

bm_items_([], _, _, _, []).
bm_items_([K-node(Child)|Rest], Prefix, Level, Depth, Items) :-
    append(Prefix, [K], Prefix1),
    bm_items(Child, Prefix1, Level, Depth, Head),
    bm_items_(Rest, Prefix, Level, Depth, Tail),
    append(Head, Tail, Items).

% ------------------------------------------------------------------
% TransitivePhext: scroll store over a BranchingMap at depth 9 — one
% hash-map layer per coordinate dimension, leaves holding scroll
% text. Serialization walks sorted keys at every level, which is
% coordinate order, so serialize is byte-identical to the string
% path over any edit sequence.
transitive_new(TP) :-
    branching_new(BM, 9),
    TP = tp(BM).

transitive_new(TP, Buffer) :-
    transitive_new(TP),
    transitive_load(TP, Buffer).

transitive_depth(TP, Depth) :-
    arg(1, TP, BM), arg(2, BM, Depth).

transitive_len(TP, N) :-
    arg(1, TP, BM), branching_len(BM, N).

tp_put(BM, ps(C, T)) :- branching_put(BM, C, T, _).

transitive_load(TP, Buffer) :-
    branching_new(BM, 9),
    nb_setarg(1, TP, BM),
    phokenize(Buffer, Scrolls),
    maplist(tp_put(BM), Scrolls).

transitive_serialize(TP, Bytes) :-
    arg(1, TP, BM),
    branching_items(BM, Items),
    maplist(pair_ps, Items, Stack),
    dephokenize(Stack, Bytes).

transitive_fetch(TP, Coord, Text) :-
    arg(1, TP, BM),
    ( branching_fetch(BM, Coord, Found) -> Text = Found ; Text = [] ).

transitive_update(TP, Coord, Text, Overwrite) :-
    arg(1, TP, BM),
    ( Text == [] ->
        ( Overwrite == true -> branching_remove(BM, Coord, _) ; true )
    ; Overwrite == true ->
        branching_put(BM, Coord, Text, _)
    ; ( branching_fetch(BM, Coord, Existing) ->
          append(Existing, Text, Merged),
          branching_put(BM, Coord, Merged, _)
      ; branching_put(BM, Coord, Text, _) ) ).

transitive_insert(TP, Coord, Text) :- transitive_update(TP, Coord, Text, false).
transitive_replace(TP, Coord, Text) :- transitive_update(TP, Coord, Text, true).
transitive_remove(TP, Coord) :-
    arg(1, TP, BM), branching_remove(BM, Coord, _).
transitive_append(TP, Coord, Text) :- transitive_insert(TP, Coord, Text).
