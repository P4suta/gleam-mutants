%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(smartest_shell_ffi).
-include_lib("kernel/include/file.hrl").
-export([random_nonce/0, arguments/0, current_directory/0,
         now_milliseconds/0, workspace_fingerprint/1,
         run_foreground_watch/5, exit/1]).

random_nonce() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

arguments() ->
    [unicode:characters_to_binary(Argument) || Argument <- init:get_plain_arguments()].

current_directory() ->
    {ok, Directory} = file:get_cwd(),
    unicode:characters_to_binary(Directory).

now_milliseconds() -> erlang:system_time(millisecond).

workspace_fingerprint(Root0) ->
    Root = filename:absname(unicode:characters_to_list(Root0)),
    case filelib:is_dir(Root) of
        false -> {false, unicode:characters_to_binary(
            io_lib:format("watch root is not a directory: ~ts", [Root]))};
        true ->
            try
                Entries = lists:sort(watch_entries(Root)),
                Digest = crypto:hash(sha256, [framed(Name, Contents) || {Name, Contents} <- Entries]),
                {true, binary:encode_hex(Digest, lowercase)}
            catch
                Class:Reason ->
                    {false, unicode:characters_to_binary(io_lib:format(
                        "could not fingerprint watch workspace: ~p:~p", [Class, Reason]))}
            end
    end.

watch_entries(Root) ->
    Directories = lists:flatmap(fun(Name) ->
        Absolute = filename:join(Root, Name),
        case filelib:is_dir(Absolute) of
            true -> collect_watch_entries(Absolute, Name);
            false -> []
        end
    end, ["src", "test"]),
    Config = lists:flatmap(fun(Name) ->
        Absolute = filename:join(Root, Name),
        case file:read_file(Absolute) of
            {ok, Contents} -> [{unicode:characters_to_binary(Name), Contents}];
            {error, enoent} -> [];
            {error, Reason} -> erlang:error({read_failed, Absolute, Reason})
        end
    end, ["gleam.toml", "manifest.toml"]),
    Directories ++ Config.

collect_watch_entries(Absolute, Relative) ->
    case file:read_link_info(Absolute) of
        {ok, Info} when Info#file_info.type =:= directory ->
            case file:list_dir(Absolute) of
                {ok, Names} -> lists:flatmap(fun(Name) ->
                    collect_watch_entries(
                        filename:join(Absolute, Name),
                        filename:join(Relative, Name))
                end, lists:sort(Names));
                {error, Reason} -> erlang:error({list_failed, Absolute, Reason})
            end;
        {ok, Info} when Info#file_info.type =:= regular ->
            case file:read_file(Absolute) of
                {ok, Contents} -> [{watch_relative(Relative), Contents}];
                {error, Reason} -> erlang:error({read_failed, Absolute, Reason})
            end;
        {ok, Info} when Info#file_info.type =:= symlink ->
            case file:read_link(Absolute) of
                {ok, Target} -> [{watch_relative(Relative),
                    unicode:characters_to_binary(["symlink:", Target])}];
                {error, Reason} -> erlang:error({read_link_failed, Absolute, Reason})
            end;
        {ok, _} -> [];
        {error, Reason} -> erlang:error({stat_failed, Absolute, Reason})
    end.

watch_relative(Relative) ->
    unicode:characters_to_binary(string:replace(Relative, "\\", "/", all)).

framed(Name, Contents) ->
    [integer_to_binary(byte_size(Name)), <<":">>, Name,
     integer_to_binary(byte_size(Contents)), <<":">>, Contents].

run_foreground_watch(Root0, Command0, Arguments0, PollMs, GraceMs) ->
    Root = filename:absname(unicode:characters_to_list(Root0)),
    CommandName = unicode:characters_to_list(Command0),
    Command = case os:find_executable(CommandName) of
        false ->
            io:format(standard_error, "could not find watch command ~ts~n", [CommandName]),
            erlang:halt(2);
        Path -> Path
    end,
    Arguments = [unicode:characters_to_list(Argument) || Argument <- Arguments0],
    case workspace_fingerprint(Root0) of
        {false, Reason} ->
            io:format(standard_error, "~ts~n", [Reason]),
            erlang:halt(2);
        {true, Fingerprint} ->
            process_flag(trap_exit, true),
            Now = erlang:monotonic_time(millisecond),
            State0 = #{
                root => Root,
                command => Command,
                arguments => Arguments,
                poll_ms => erlang:max(25, PollMs),
                grace_ms => GraceMs,
                fingerprint => Fingerprint,
                revision => 0,
                completed => 0,
                maximum => watch_maximum_revisions(),
                port => undefined,
                pending => true,
                cancel_deadline => undefined,
                next_poll => Now + erlang:max(25, PollMs)
            },
            watch_loop(watch_start_latest(State0))
    end.

watch_maximum_revisions() ->
    case os:getenv("SMARTEST_WATCH_MAX_REVISIONS") of
        false -> 0;
        Value ->
            try
                Parsed = list_to_integer(Value),
                case Parsed > 0 of true -> Parsed; false -> 0 end
            catch _:_ -> 0 end
    end.

watch_start_latest(State = #{pending := false}) -> State;
watch_start_latest(State = #{port := Port}) when Port =/= undefined -> State;
watch_start_latest(State) ->
    Revision = maps:get(revision, State),
    Command = maps:get(command, State),
    Arguments = maps:get(arguments, State),
    io:format("[smartest] revision ~B: ~ts ~ts~n", [
        Revision, Command, string:join(Arguments, " ")]),
    Options = [binary, exit_status, eof, use_stdio, stderr_to_stdout, hide,
               {args, Arguments}, {cd, maps:get(root, State)}],
    try erlang:open_port({spawn_executable, Command}, Options) of
        Port -> State#{port => Port, pending => false, cancel_deadline => undefined}
    catch
        Class:Reason ->
            io:format(standard_error, "could not start watch job: ~p:~p~n", [Class, Reason]),
            erlang:halt(2)
    end.

watch_loop(State0) ->
    State = watch_apply_deadlines(State0),
    Timeout = watch_timeout(State),
    Port = maps:get(port, State),
    receive
        {Port, {data, Chunk}} when Port =/= undefined ->
            io:put_chars(Chunk),
            watch_loop(State);
        {Port, {exit_status, Code}} when Port =/= undefined ->
            watch_complete(State, Code);
        {Port, eof} when Port =/= undefined ->
            watch_loop(State);
        {'EXIT', Port, _Reason} when Port =/= undefined ->
            watch_complete(State, 1)
    after Timeout ->
        watch_loop(State)
    end.

watch_apply_deadlines(State0) ->
    Now = erlang:monotonic_time(millisecond),
    State1 = case maps:get(cancel_deadline, State0) of
        Deadline when is_integer(Deadline), Now >= Deadline ->
            watch_signal_port(maps:get(port, State0), "-KILL"),
            State0#{cancel_deadline => undefined};
        _ -> State0
    end,
    case Now >= maps:get(next_poll, State1) of
        false -> State1;
        true -> watch_observe(State1, Now)
    end.

watch_observe(State, Now) ->
    Root = unicode:characters_to_binary(maps:get(root, State)),
    Next = Now + maps:get(poll_ms, State),
    CurrentFingerprint = maps:get(fingerprint, State),
    case workspace_fingerprint(Root) of
        {false, Reason} ->
            watch_signal_port(maps:get(port, State), "-KILL"),
            io:format(standard_error, "~ts~n", [Reason]),
            erlang:halt(2);
        {true, Fingerprint} when Fingerprint =:= CurrentFingerprint ->
            State#{next_poll => Next};
        {true, Fingerprint} ->
            Edited = State#{
                fingerprint => Fingerprint,
                revision => maps:get(revision, State) + 1,
                pending => true,
                next_poll => Next
            },
            case maps:get(port, Edited) of
                undefined -> watch_start_latest(Edited);
                Port ->
                    case maps:get(cancel_deadline, Edited) of
                        undefined ->
                            watch_signal_port(Port, "-TERM"),
                            Edited#{cancel_deadline => Now + maps:get(grace_ms, Edited)};
                        _ -> Edited
                    end
            end
    end.

watch_complete(State, Code) ->
    Completed = maps:get(completed, State) + 1,
    Maximum = maps:get(maximum, State),
    case Maximum > 0 andalso Completed >= Maximum of
        true -> erlang:halt(Code);
        false ->
            Next = State#{
                port => undefined,
                completed => Completed,
                cancel_deadline => undefined
            },
            watch_loop(watch_start_latest(Next))
    end.

watch_timeout(State) ->
    Now = erlang:monotonic_time(millisecond),
    PollWait = erlang:max(0, maps:get(next_poll, State) - Now),
    case maps:get(cancel_deadline, State) of
        Deadline when is_integer(Deadline) ->
            erlang:min(PollWait, erlang:max(0, Deadline - Now));
        _ -> PollWait
    end.

watch_signal_port(undefined, _Signal) -> ok;
watch_signal_port(Port, Signal) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> watch_signal_tree(Pid, Signal);
        _ -> ok
    end.

watch_signal_tree(Pid, Signal) ->
    case os:type() of
        {win32, _} ->
            Force = case Signal of "-KILL" -> " /F"; _ -> "" end,
            os:cmd("taskkill /PID " ++ integer_to_list(Pid) ++ " /T" ++ Force ++ " >NUL 2>&1"),
            ok;
        _ ->
            Pids = watch_descendants(Pid) ++ [Pid],
            lists:foreach(fun(Member) ->
                os:cmd("kill " ++ Signal ++ " " ++ integer_to_list(Member) ++ " 2>/dev/null")
            end, Pids),
            ok
    end.

watch_descendants(Root) ->
    Lines = string:split(os:cmd("ps -eo pid=,ppid="), "\n", all),
    Pairs = lists:filtermap(fun watch_parse_pair/1, Lines),
    watch_descendants_loop([Root], Pairs, []).

watch_parse_pair(Line) ->
    case string:tokens(Line, " \t") of
        [Pid, Parent] ->
            try {true, {list_to_integer(Pid), list_to_integer(Parent)}}
            catch _:_ -> false end;
        _ -> false
    end.

watch_descendants_loop([], _Pairs, Found) -> lists:reverse(Found);
watch_descendants_loop([Parent | Queue], Pairs, Found) ->
    Children = [Pid || {Pid, Ppid} <- Pairs,
        Ppid =:= Parent, not lists:member(Pid, Found)],
    watch_descendants_loop(Queue ++ Children, Pairs, Children ++ Found).

exit(Code) -> erlang:halt(Code).
