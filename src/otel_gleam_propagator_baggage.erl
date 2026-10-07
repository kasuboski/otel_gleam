-module(otel_gleam_propagator_baggage).
-export([fields/1, inject/4, extract/5]).

-define(MAX_MEMBERS, 64).
-define(MAX_BYTES, 8192).

fields(_Config) -> [<<"baggage">>].

inject(Context, Carrier, Setter, _Config) ->
    Entries = lists:sort(maps:to_list(otel_baggage:get_all(Context))),
    Candidates = [{K, Entry} || {K, Entry} <- Entries,
        valid_key(K), valid_properties(element(2, Entry)), valid_utf8_entry(Entry)],
    case length(Candidates) > ?MAX_MEMBERS orelse raw_lower_bound(Candidates) > ?MAX_BYTES of
        true -> Carrier;
        false ->
            Members = [encode_entry(K, Entry) || {K, Entry} <- Candidates],
            Value = iolist_to_binary(lists:join(<<",">>, Members)),
            case byte_size(Value) =< ?MAX_BYTES of
                true when Value =:= <<>> -> Carrier;
                true -> Setter(<<"baggage">>, Value, Carrier);
                false -> Carrier
            end
    end.

extract(Context, Carrier, _CarrierKeysFun, Getter, _Config) ->
    case standard_carrier_size(Carrier) of
        {reject, _Reason} -> Context;
        _ -> extract_with_getter(Context, Carrier, Getter)
    end.

extract_with_getter(Context, Carrier, Getter) ->
    case Getter(<<"baggage">>, Carrier) of
        undefined -> Context;
        Combined when is_binary(Combined), byte_size(Combined) =< ?MAX_BYTES ->
            Candidates = binary:split(Combined, <<",">>, [global]),
            case length(Candidates) =< ?MAX_MEMBERS of
                false -> Context;
                true ->
                    Parsed = lists:foldl(fun parse_member/2, #{}, Candidates),
                    otel_baggage:set_to(Context, maps:to_list(Parsed))
            end;
        _OverLimitOrInvalid -> Context
    end.

%% The standard list carrier can be bounded without invoking its joining Getter.
%% Custom carriers must bound their own storage; their Getter result is checked below.
standard_carrier_size(Carrier) when is_list(Carrier) ->
    case lists:all(fun({K, V}) -> is_binary(K) andalso is_binary(V); (_) -> false end, Carrier) of
        true ->
            Values = [V || {K, V} <- Carrier, lower_ascii(K) =:= <<"baggage">>],
            Bytes = lists:sum([byte_size(V) || V <- Values]) + erlang:max(0, length(Values) - 1),
            case Bytes > ?MAX_BYTES of
                true -> {reject, over_limit};
                false ->
                    Candidates = lists:sum([count_commas(V) + 1 || V <- Values]),
                    case Candidates > ?MAX_MEMBERS of
                        true -> {reject, over_limit};
                        false -> ok
                    end
            end;
        false -> custom
    end;
standard_carrier_size(_) -> custom.

lower_ascii(Bin) -> << <<(lower_ascii_byte(C))>> || <<C>> <= Bin >>.
lower_ascii_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_ascii_byte(C) -> C.
count_commas(Bin) -> length(binary:matches(Bin, <<$,>>)).

raw_lower_bound(Entries) ->
    lists:sum([raw_entry_lower_bound(K, Entry) || {K, Entry} <- Entries]) + erlang:max(0, length(Entries) - 1).
raw_entry_lower_bound(K, {V, Props}) ->
    byte_size(K) + 1 + byte_size(V) + lists:sum([raw_property_lower_bound(P) || P <- Props]).
raw_property_lower_bound(P) when is_binary(P) -> 1 + byte_size(P);
raw_property_lower_bound({K, V}) -> 2 + byte_size(K) + byte_size(V).

valid_utf8_entry({V, Props}) -> valid_utf8(V) andalso lists:all(fun
    (P) when is_binary(P) -> valid_utf8(P);
    ({K, PV}) -> valid_utf8(K) andalso valid_utf8(PV)
end, Props).
valid_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    end;
valid_utf8(_) -> false.

parse_member(Member0, Acc) ->
    Member = trim_ows(Member0),
    case binary:split(Member, <<"=">>) of
        [Key0, Rest] ->
            Key = trim_ows(Key0),
            case valid_key(Key) of
                false -> Acc;
                true -> parse_value_and_properties(Key, Rest, Acc)
            end;
        _ -> Acc
    end.

parse_value_and_properties(Key, Rest, Acc) ->
    Parts = binary:split(Rest, <<";">>, [global]),
    [Value0 | Props0] = Parts,
    Value = trim_ows(Value0),
    case decode(Value) of
        error -> Acc;
        {ok, Decoded} ->
            case parse_properties(Props0, []) of
                error -> Acc;
                {ok, Props} -> maps:put(Key, {Decoded, Props}, Acc)
            end
    end.

parse_properties([], Acc) -> {ok, lists:reverse(Acc)};
parse_properties([P0 | Ps], Acc) ->
    P = trim_ows(P0),
    case P of
        <<>> -> error;
        _ -> case binary:split(P, <<"=">>) of
            [K0] ->
                K = trim_ows(K0),
                case valid_key(K) of
                    true -> parse_properties(Ps, [K | Acc]);
                    false -> error
                end;
            [K0, V0] ->
                K = trim_ows(K0),
                V = trim_ows(V0),
                case valid_key(K) of
                    false -> error;
                    true -> case decode(V) of
                        {ok, DV} -> parse_properties(Ps, [{K, DV} | Acc]);
                        error -> error
                    end
                end;
            _ -> error
        end
    end.

encode_entry(Key, {Value, Props}) ->
    [Key, <<"=">>, encode(Value), [[<<";">>, encode_property(P)] || P <- Props]].
valid_properties(Props) -> lists:all(fun valid_property/1, Props).
valid_property(P) when is_binary(P) -> valid_key(P);
valid_property({K, _V}) -> valid_key(K).
encode_property(P) when is_binary(P) -> P;
encode_property({K, V}) -> [K, <<"=">>, encode(V)].

encode(Bin) ->
    << <<(encode_byte(B))/binary>> || <<B>> <= unicode:characters_to_binary(Bin) >>.
encode_byte(B) when B >= 33, B =< 33 -> <<B>>;
encode_byte(B) when B >= 35, B =< 36 -> <<B>>;
encode_byte(B) when B >= 38, B =< 43 -> <<B>>;
encode_byte(B) when B >= 45, B =< 58 -> <<B>>;
encode_byte(B) when B >= 60, B =< 91 -> <<B>>;
encode_byte(B) when B >= 93, B =< 126 -> <<B>>;
encode_byte(B) -> <<"%", (hex(B bsr 4)), (hex(B band 15))>>.
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

valid_key(<<>>) -> false;
valid_key(Bin) when is_binary(Bin) -> lists:all(fun key_char/1, binary_to_list(Bin));
valid_key(_) -> false.
key_char(C) when C >= $a, C =< $z -> true;
key_char(C) when C >= $A, C =< $Z -> true;
key_char(C) when C >= $0, C =< $9 -> true;
key_char(C) -> lists:member(C, "!#$%&'*+-.^_`|~").

trim_ows(Bin) -> trim_right(trim_left(Bin)).
trim_left(<<C, Rest/binary>>) when C =:= 32; C =:= 9 -> trim_left(Rest);
trim_left(B) -> B.
trim_right(B) when byte_size(B) =:= 0 -> B;
trim_right(B) ->
    case binary:last(B) of
        C when C =:= 32; C =:= 9 -> trim_right(binary:part(B, 0, byte_size(B)-1));
        _ -> B
    end.

decode(Bin) ->
    try
        Decoded = percent_decode(Bin),
        case unicode:characters_to_list(Decoded, utf8) of
            List when is_list(List) -> {ok, Decoded};
            {error, _, _} -> {ok, replace_invalid_utf8(Decoded)};
            {incomplete, _, _} -> {ok, replace_invalid_utf8(Decoded)}
        end
    catch
        error:bad_percent -> error;
        error:invalid_raw_byte -> error
    end.
percent_decode(<<>>) -> <<>>;
percent_decode(<<"%", A, B, Rest/binary>>) ->
    <<((unhex(A) bsl 4) bor unhex(B)), (percent_decode(Rest))/binary>>;
percent_decode(<<"%", _/binary>>) -> erlang:error(bad_percent);
percent_decode(<<C, Rest/binary>>) when C >= 33, C =< 126, C =/= $;, C =/= $,, C =/= $\", C =/= $\\ -> <<C, (percent_decode(Rest))/binary>>;
percent_decode(<<_, _/binary>>) -> erlang:error(invalid_raw_byte).

replace_invalid_utf8(Bin) ->
    case unicode:characters_to_list(Bin, utf8) of
        List when is_list(List) -> unicode:characters_to_binary(List);
        {error, Good, Rest} ->
            <<(unicode:characters_to_binary(Good))/binary, 16#EF, 16#BF, 16#BD,
              (replace_invalid_utf8(drop_invalid_sequence(Rest)))/binary>>;
        {incomplete, Good, _Rest} ->
            <<(unicode:characters_to_binary(Good))/binary, 16#EF, 16#BF, 16#BD>>
    end.

drop_invalid_sequence(<<C, Rest/binary>>) when C band 16#C0 =:= 16#80 -> drop_invalid_sequence(Rest);
drop_invalid_sequence(<<_, Rest/binary>>) -> Rest;
drop_invalid_sequence(<<>>) -> <<>>.
unhex(C) when C >= $0, C =< $9 -> C-$0;
unhex(C) when C >= $A, C =< $F -> C-$A+10;
unhex(C) when C >= $a, C =< $f -> C-$a+10;
unhex(_) -> erlang:error(bad_percent).
