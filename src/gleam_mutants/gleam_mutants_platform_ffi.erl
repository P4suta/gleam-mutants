%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(gleam_mutants_platform_ffi).
-include_lib("kernel/include/file.hrl").
-export([arguments/0, env/1, current_directory/0, temporary_directory/0,
         cache_directory/0, cpu_count/0, now_milliseconds/0, process_id/0,
         os_name/0, is_tty/0, is_reparse_point/1, exit/1, run_process/5, run_process_batch/2]).

arguments() ->
    Raw = init:get_plain_arguments(),
    ScriptResult = try escript:script_name() of
        Value -> {ok, Value}
    catch
        _:_ -> error
    end,
    Args = case ScriptResult of
        {ok, Script} when is_list(Script) ->
            case Raw of
[First | Rest] when First =:= Script ->
                    case filelib:is_regular(First) of
                        true -> Rest;
                        false -> Raw
                    end;
                _ -> Raw
            end;
        _ -> Raw
    end,
    [unicode:characters_to_binary(A) || A <- Args].

env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.

current_directory() ->
    {ok, Directory} = file:get_cwd(),
    unicode:characters_to_binary(Directory).

temporary_directory() ->
    case os:type() of
        {win32, _} -> first_env([<<"TEMP">>, <<"TMP">>], <<".">>);
        _ -> first_env([<<"TMPDIR">>], <<"/tmp">>)
    end.

cache_directory() ->
    case os:type() of
        {win32, _} -> first_env([<<"LOCALAPPDATA">>], temporary_directory());
        {unix, darwin} -> <<(first_env([<<"HOME">>], <<".">>))/binary, "/Library/Caches">>;
        _ -> first_env([<<"XDG_CACHE_HOME">>], <<(first_env([<<"HOME">>], <<".">>))/binary, "/.cache">>)
    end.

first_env([], Default) -> Default;
first_env([Name | Rest], Default) ->
    case env(Name) of <<>> -> first_env(Rest, Default); Value -> Value end.

cpu_count() ->
    case erlang:system_info(logical_processors_available) of
        unknown -> 1;
        Count when is_integer(Count), Count > 0 -> Count;
        _ -> 1
    end.

now_milliseconds() -> erlang:system_time(millisecond).
process_id() -> list_to_integer(os:getpid()).

os_name() ->
    case os:type() of
        {win32, _} -> <<"windows">>;
        {unix, darwin} -> <<"darwin">>;
        {unix, _} -> <<"linux">>;
        _ -> <<"unknown">>
    end.

is_tty() ->
    case io:columns() of {ok, _} -> true; _ -> false end.

is_reparse_point(Path) ->
    case file:read_link_info(unicode:characters_to_list(Path)) of
        {ok, Info} when Info#file_info.type =:= symlink -> true;
        _ -> false
    end.
exit(Code) -> erlang:halt(Code).

run_process(Executable0, Args0, WorkingDirectory, Environment, Timeout) ->
    Executable = resolve_executable(Executable0),
    Args = [unicode:characters_to_list(A) || A <- Args0],
    Env = [{unicode:characters_to_list(K), unicode:characters_to_list(V)} || {K, V} <- Environment],
    Options = [binary, exit_status, use_stdio, stderr_to_stdout, hide,
               {args, Args}, {cd, unicode:characters_to_list(WorkingDirectory)}, {env, Env}],
    Result = try erlang:open_port({spawn_executable, Executable}, Options) of
        Port -> collect(Port, Timeout, erlang:monotonic_time(millisecond), <<>>, undefined)
    catch
        Class:Reason -> {-2, <<>>, unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason])), false}
    end,
    preserve_interrupt(Result).

preserve_interrupt({130, _, _, _}) -> erlang:halt(130);
preserve_interrupt(Result) -> Result.

run_process_batch([], _Jobs) -> [];
run_process_batch(Requests, Jobs) ->
    Count = erlang:min(erlang:max(1, Jobs), length(Requests)),
    {Batch, Rest} = lists:split(Count, Requests),
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            Started = erlang:monotonic_time(millisecond),
            {Executable, Args, WorkingDirectory, Environment, Timeout} = Request,
            {Status, Stdout, Stderr, TimedOut} =
                run_process(Executable, Args, WorkingDirectory, Environment, Timeout),
            Duration = erlang:monotonic_time(millisecond) - Started,
            Parent ! {Ref, {Status, Stdout, Stderr, TimedOut, Duration}}
        end),
        Ref
    end || Request <- Batch],
    Results = [receive {Ref, Result} -> Result end || Ref <- Refs],
    Results ++ run_process_batch(Rest, Jobs).
resolve_executable(Name) ->
    NameList = unicode:characters_to_list(Name),
    case filename:pathtype(NameList) of
        absolute -> NameList;
        _ -> case os:find_executable(NameList) of false -> NameList; Path -> Path end
    end.

collect(Port, Timeout, Started, Output, Status) ->
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    Remaining = erlang:max(0, Timeout - Elapsed),
    receive
        {Port, {data, Chunk}} -> collect(Port, Timeout, Started, <<Output/binary, Chunk/binary>>, Status);
        {Port, {exit_status, Code}} -> {Code, Output, <<>>, false};
        {'EXIT', Port, _} -> {status_or_default(Status), Output, <<>>, false}
    after Remaining ->
        case Status of
            undefined ->
                kill_port_tree(Port),
                try erlang:port_close(Port) catch _:_ -> ok end,
                {-1, Output, <<"process timed out">>, true};
            _ -> {Status, Output, <<>>, false}
        end
    end.

status_or_default(undefined) -> -1;
status_or_default(Status) -> Status.

kill_port_tree(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> kill_tree(Pid);
        _ -> ok
    end.

kill_tree(Pid) ->
    case os:type() of
        {win32, _} ->
            os:cmd("taskkill /PID " ++ integer_to_list(Pid) ++ " /T /F >NUL 2>&1"), ok;
        _ ->
            Descendants = descendants(Pid),
            signal_all(Descendants ++ [Pid], "-TERM"),
            timer:sleep(250),
            signal_all(Descendants ++ [Pid], "-KILL")
    end.

signal_all(Pids, Signal) ->
    lists:foreach(fun(Pid) -> os:cmd("kill " ++ Signal ++ " " ++ integer_to_list(Pid) ++ " 2>/dev/null") end, Pids), ok.

descendants(Root) ->
    Lines = string:split(os:cmd("ps -eo pid=,ppid="), "\n", all),
    Pairs = lists:filtermap(fun parse_pair/1, Lines),
    descendants_loop([Root], Pairs, []).

parse_pair(Line) ->
    case string:tokens(Line, " \t") of
        [Pid, Parent] ->
            try {true, {list_to_integer(Pid), list_to_integer(Parent)}} catch _:_ -> false end;
        _ -> false
    end.

descendants_loop([], _Pairs, Found) -> lists:reverse(Found);
descendants_loop([Parent | Queue], Pairs, Found) ->
    Children = [Pid || {Pid, Ppid} <- Pairs, Ppid =:= Parent, not lists:member(Pid, Found)],
    descendants_loop(Queue ++ Children, Pairs, Children ++ Found).
