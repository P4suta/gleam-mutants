%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(smartest_runtime_ffi).
-export([capture/2, attempt/2, runtime_name/0, format_failure/3]).

runtime_name() -> <<"erlang">>.

capture(Callback, Timeout0) ->
    {Status, _Value, Message, Duration} = attempt(Callback, Timeout0),
    {Status, Message, Duration}.

attempt(Callback, Timeout0) ->
    Timeout = erlang:max(0, Timeout0),
    Started = erlang:monotonic_time(millisecond),
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Answer = try
            {passed, Callback()}
        catch
            Class:Reason:Stack ->
                {failed, format_failure(Class, Reason, Stack)}
        end,
        Parent ! {Ref, Answer}
    end),
    receive
        {Ref, {passed, Value}} ->
            erlang:demonitor(Monitor, [flush]),
            {<<"passed">>, Value, <<>>, elapsed(Started)};
        {Ref, {failed, Message}} ->
            erlang:demonitor(Monitor, [flush]),
            {<<"failed">>, nil, Message, elapsed(Started)};
        {'DOWN', Monitor, process, Pid, Reason} ->
            {<<"failed">>, nil, format_failure(exit, Reason, []), elapsed(Started)}
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok after 1000 -> ok end,
        {<<"timed-out">>, nil, <<"test exceeded its timeout">>, elapsed(Started)}
    end.

elapsed(Started) ->
    erlang:monotonic_time(millisecond) - Started.

format_failure(error, Reason = #{gleam_error := Kind}, Stack)
  when Kind =:= assert; Kind =:= let_assert ->
    File = maps:get(file, Reason, <<"unknown">>),
    Line = maps:get(line, Reason, 0),
    Expression = assertion_expression(File, Reason),
    Arguments = maps:get(arguments, Reason, []),
    unicode:characters_to_binary(
      io_lib:format(
        "~ts:~B: ~tp failed~nexpression: ~ts~nvalues: ~tp~n~tp",
        [File, Line, Kind, Expression, Arguments, Stack]
      )
    );
format_failure(Class, Reason, Stack) ->
    unicode:characters_to_binary(
      io_lib:format("~tp: ~tp~n~tp", [Class, Reason, Stack])
    ).

assertion_expression(File0, Reason) ->
    File = unicode:characters_to_list(File0),
    Start = maps:get(expression_start, Reason, maps:get(start, Reason, 0)),
    End = maps:get('end', Reason, Start),
    case file:read_file(File) of
        {ok, Source} when is_integer(Start), is_integer(End),
                          Start >= 0, End >= Start, End =< byte_size(Source) ->
            binary:part(Source, Start, End - Start);
        _ -> <<"<source unavailable>">>
    end.
