%% Wire helpers for the Erlang telephone CLI: hand-written JSON
%% (canonical form matching Python json.dumps sort_keys + tight
%% separators + ensure_ascii), SHA-256 via crypto, base64 via the
%% base64 module, GZ1 framing via zlib.
%%
%% JSON terms: object -> map with string (codepoint list) keys;
%% array -> {arr, list} (tagged: a bare codepoint list is a string);
%% string -> codepoint list; integer -> integer;
%% float -> float; true/false/null -> atoms true/false/null.
-module(wire).
-export([parse/1, write/1, canon/1, sha256hex/1, b64/1, unb64/1,
         latin1_binary/1, latin1_string/1, utf8_binary/1, utf8_cps/1,
         gzip/1, gunzip/1]).

sha256hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [X])
                   || X <- binary_to_list(crypto:hash(sha256, Bin))]).

b64(Bin) -> binary_to_list(base64:encode(Bin)).
unb64(S) -> base64:decode(iolist_to_binary(S)).

gzip(Bin) -> zlib:gzip(Bin).
gunzip(Bin) -> zlib:gunzip(Bin).

%% codepoint list -> latin-1 binary (each codepoint must be =< 255)
latin1_binary(Cps) -> list_to_binary(Cps).
%% binary -> codepoint list, byte-wise (latin-1 view)
latin1_string(Bin) -> binary_to_list(Bin).
%% codepoint list -> utf-8 binary
utf8_binary(Cps) -> unicode:characters_to_binary(Cps).
%% utf-8 binary -> codepoint list
utf8_cps(Bin) -> unicode:characters_to_list(Bin).

%% ---------------- JSON parse ----------------
parse(Bin) when is_binary(Bin) -> parse(binary_to_list(Bin));
parse(S) ->
    {V, Rest} = value(skip_ws(S)),
    [] = skip_ws(Rest),
    V.

skip_ws([C | T]) when C == $\s; C == $\t; C == $\n; C == $\r -> skip_ws(T);
skip_ws(S) -> S.

value([${ | T]) -> object(skip_ws(T), #{});
value([$[ | T]) -> array(skip_ws(T), []);
value([$" | T]) -> string(T, []);
value([$t, $r, $u, $e | T]) -> {true, T};
value([$f, $a, $l, $s, $e | T]) -> {false, T};
value([$n, $u, $l, $l | T]) -> {null, T};
value(S) -> number(S, []).

object([$} | T], Acc) -> {Acc, T};
object(S, Acc) ->
    {Key, Rest1} = value(skip_ws(S)),
    [$: | Rest2] = skip_ws(Rest1),
    {Val, Rest3} = value(skip_ws(Rest2)),
    Acc2 = maps:put(Key, Val, Acc),
    case skip_ws(Rest3) of
        [$, | T] -> object(skip_ws(T), Acc2);
        [$} | T] -> {Acc2, T}
    end.

array([$] | T], Acc) -> {{arr, lists:reverse(Acc)}, T};
array(S, Acc) ->
    {Val, Rest} = value(skip_ws(S)),
    case skip_ws(Rest) of
        [$, | T] -> array(skip_ws(T), [Val | Acc]);
        [$] | T] -> {{arr, lists:reverse([Val | Acc])}, T}
    end.

string([$" | T], Acc) -> {lists:reverse(Acc), T};
string([$\\, $u, A, B, C, D | T], Acc) ->
    Cp = hex4([A, B, C, D]),
    case Cp >= 16#D800 andalso Cp =< 16#DBFF of
        true ->
            case T of
                [$\\, $u, E, F, G, H | T2] ->
                    Lo = hex4([E, F, G, H]),
                    case Lo >= 16#DC00 andalso Lo =< 16#DFFF of
                        true ->
                            Full = 16#10000 + ((Cp - 16#D800) bsl 10) + (Lo - 16#DC00),
                            string(T2, [Full | Acc]);
                        false -> string(T, [Cp | Acc])
                    end;
                _ -> string(T, [Cp | Acc])
            end;
        false -> string(T, [Cp | Acc])
    end;
string([$\\, E | T], Acc) ->
    Cp = case E of
             $n -> $\n; $r -> $\r; $t -> $\t; $b -> $\b; $f -> $\f;
             _ -> E
         end,
    string(T, [Cp | Acc]);
string([C | T], Acc) when C < 128 ->
    string(T, [C | Acc]);
string([C | T], Acc) ->
    %% raw UTF-8 byte in a JSON string: decode one codepoint
    <<Cp/utf8, Rest/binary>> = list_to_binary([C | T]),
    string(binary_to_list(Rest), [Cp | Acc]).

hex4(S) -> list_to_integer(S, 16).

number(S, Acc) ->
    case S of
        [C | T] when (C >= $0 andalso C =< $9) orelse C == $- orelse C == $+
                     orelse C == $. orelse C == $e orelse C == $E ->
            number(T, [C | Acc]);
        _ ->
            Txt = lists:reverse(Acc),
            case lists:any(fun(X) -> X == $. orelse X == $e orelse X == $E end, Txt) of
                true -> {list_to_float(ensure_float(Txt)), S};
                false -> {list_to_integer(Txt), S}
            end
    end.

ensure_float(Txt) ->
    case lists:member($., Txt) of
        true -> Txt;
        false ->
            {Int, Exp} = lists:splitwith(fun(X) -> X /= $e andalso X /= $E end, Txt),
            Int ++ ".0" ++ Exp
    end.

%% ---------------- JSON write (canonical) ----------------
canon(V) -> utf8_binary(write(V)).

write(V) when is_map(V) ->
    Keys = lists:sort(maps:keys(V)),
    "{" ++ string:join(
             [[escape(K), $:, write(maps:get(K, V))] || K <- Keys], ",") ++ "}";
write({arr, L}) ->
    "[" ++ string:join([write(X) || X <- L], ",") ++ "]";
write(V) when is_list(V) ->
    escape(V);
write(true) -> "true";
write(false) -> "false";
write(null) -> "null";
write(V) when is_integer(V) -> integer_to_list(V);
write(V) when is_float(V) -> float_str(V).

%% Distinguish JSON strings (codepoint lists) from arrays: strings are
%% tagged at parse time? No -- in this CLI, JSON strings are always
%% codepoint lists of integers and arrays are lists of terms; an array
%% of bare integers never occurs in the protocol. An empty list is a
%% string "" in our construction sites (we never build empty arrays).
is_codepoint_list([]) -> true;
is_codepoint_list(L) -> lists:all(fun(X) -> is_integer(X) end, L).

float_str(F) ->
    S = lists:flatten(io_lib:format("~p", [F])),
    S.

escape(Cps) ->
    [$"] ++ lists:flatmap(fun escape_cp/1, Cps) ++ [$"].

escape_cp($") -> "\\\"";
escape_cp($\\) -> "\\\\";
escape_cp($\n) -> "\\n";
escape_cp($\r) -> "\\r";
escape_cp($\t) -> "\\t";
escape_cp($\b) -> "\\b";
escape_cp($\f) -> "\\f";
escape_cp(Cp) when Cp < 16#20; Cp > 16#7E ->
    case Cp > 16#FFFF of
        true ->
            V = Cp - 16#10000,
            lists:flatten(io_lib:format("\\u~4.16.0b\\u~4.16.0b",
                                        [16#D800 + (V bsr 10), 16#DC00 + (V band 16#3FF)]));
        false ->
            lists:flatten(io_lib:format("\\u~4.16.0b", [Cp]))
    end;
escape_cp(Cp) -> [Cp].
