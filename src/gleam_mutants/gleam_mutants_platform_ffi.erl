%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(gleam_mutants_platform_ffi).
-include_lib("kernel/include/file.hrl").
-export([arguments/0, env/1, current_directory/0, temporary_directory/0,
         cache_directory/0, cpu_count/0, now_milliseconds/0, monotonic_milliseconds/0,
         resolve_path/1, architecture/0, environment/0, random_nonce/0,
         delete_tree/1,
         acquire_lock/4, release_lock/2, process_id/0,
         os_name/0, is_tty/0, is_reparse_point/1, exit/1, run_process/5, run_process_batch/2]).

delete_tree(Path) -> delete_tree(unicode:characters_to_list(Path), 40).

delete_tree(Path, Attempts) ->
    case delete_tree_once(Path) of
        ok -> <<>>;
        {error, enoent} -> <<>>;
        {error, _} when Attempts > 0 ->
            timer:sleep(50),
            delete_tree(Path, Attempts - 1);
        {error, Reason} ->
            unicode:characters_to_binary(io_lib:format("~tp", [Reason]))
    end.

delete_tree_once(Path) ->
    case file:read_link_info(Path) of
        {error, enoent} -> ok;
        {error, Reason} -> {error, Reason};
        {ok, Info} when Info#file_info.type =:= symlink ->
            delete_symlink(Path);
        {ok, Info} when Info#file_info.type =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    case delete_children(Path, Names) of
                        ok -> file:del_dir(Path);
                        Error -> Error
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> file:delete(Path)
    end.

delete_symlink(Path) ->
    case file:delete(Path) of
        {error, eperm} -> file:del_dir(Path);
        {error, eisdir} -> file:del_dir(Path);
        Result -> Result
    end.

delete_children(_Path, []) -> ok;
delete_children(Path, [Name | Rest]) ->
    case delete_tree_once(filename:join(Path, Name)) of
        ok -> delete_children(Path, Rest);
        Error -> Error
    end.

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
monotonic_milliseconds() -> erlang:monotonic_time(millisecond).
resolve_path(Path) -> unicode:characters_to_binary(filename:absname(unicode:characters_to_list(Path))).
architecture() -> unicode:characters_to_binary(erlang:system_info(system_architecture)).
environment() ->
    Entries = lists:sort(os:getenv()),
    unicode:characters_to_binary(lists:flatten([
        integer_to_list(length(Entry)) ++ ":" ++ Entry || Entry <- Entries
    ])).
random_nonce() ->
    Bytes = crypto:strong_rand_bytes(16),
    unicode:characters_to_binary(binary:encode_hex(Bytes, lowercase)).

acquire_lock(Path0, RunId, Started, WaitMs) ->
    Path = unicode:characters_to_list(Path0),
    ok = filelib:ensure_dir(Path),
    Token = random_nonce(),
    Deadline = erlang:monotonic_time(millisecond) + WaitMs,
    acquire_lock_loop(Path, Token, RunId, Started, Deadline).

acquire_lock_loop(Path, Token, RunId, Started, Deadline) ->
    case file:open(Path, [write, exclusive, binary]) of
        {ok, File} ->
            Metadata = <<Token/binary, "\n", (integer_to_binary(process_id()))/binary,
                         "\n", RunId/binary, "\n", (integer_to_binary(Started))/binary, "\n">>,
            Result = case file:write(File, Metadata) of
                ok -> file:sync(File);
                Error -> Error
            end,
            ok = file:close(File),
            case Result of
                ok -> <<"ok:", Token/binary>>;
                {error, Reason} ->
                    _ = file:delete(Path),
                    unicode:characters_to_binary(io_lib:format("error:could not write workspace lock: ~p", [Reason]))
            end;
        {error, eexist} ->
            case read_lock(Path) of
                {ok, _OldToken, Pid, _OldRunId, _OldStarted} ->
                    case lock_process_alive(Pid) of
                        false -> _ = file:delete(Path), acquire_lock_loop(Path, Token, RunId, Started, Deadline);
                        true -> wait_for_lock(Path, Token, RunId, Started, Deadline)
                    end;
                error -> wait_for_lock(Path, Token, RunId, Started, Deadline)
            end;
        {error, Reason} ->
            unicode:characters_to_binary(io_lib:format("error:could not create workspace lock: ~p", [Reason]))
    end.

wait_for_lock(Path, Token, RunId, Started, Deadline) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            case read_lock(Path) of
                {ok, _, Pid, OldRunId, OldStarted} ->
                    <<"error:workspace is locked by pid ", (integer_to_binary(Pid))/binary,
                      ", run ", OldRunId/binary, ", started ", OldStarted/binary>>;
                error -> <<"error:workspace lock is busy">>
            end;
        false -> timer:sleep(50), acquire_lock_loop(Path, Token, RunId, Started, Deadline)
    end.

read_lock(Path) ->
    case file:read_file(Path) of
        {ok, Data} ->
            case binary:split(Data, <<"\n">>, [global]) of
                [Token, Pid, RunId, Started | _] ->
                    try {ok, Token, binary_to_integer(Pid), RunId, Started}
                    catch _:_ -> error end;
                _ -> error
            end;
        _ -> error
    end.

lock_process_alive(Pid) ->
    Command = case os:type() of
        {win32, _} -> "tasklist /FI \"PID eq " ++ integer_to_list(Pid) ++ "\" /NH";
        _ -> "kill -0 " ++ integer_to_list(Pid) ++ " 2>/dev/null && echo alive"
    end,
    string:find(os:cmd(Command), case os:type() of {win32, _} -> integer_to_list(Pid); _ -> "alive" end) =/= nomatch.

release_lock(Path0, Token) ->
    Path = unicode:characters_to_list(Path0),
    case read_lock(Path) of
        {ok, Token, _, _, _} ->
            case file:delete(Path) of
                ok -> <<>>;
                {error, Reason} -> unicode:characters_to_binary(io_lib:format("could not release workspace lock: ~p", [Reason]))
            end;
        {ok, _, _, _, _} -> <<"workspace lock ownership changed">>;
        error -> <<"could not read workspace lock during release">>
    end.
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
    Options = [binary, exit_status, eof, use_stdio, stderr_to_stdout, hide,
               {args, Args}, {cd, unicode:characters_to_list(WorkingDirectory)}, {env, Env}],
    Result = try erlang:open_port({spawn_executable, Executable}, Options) of
        Port -> collect(Port, Timeout, erlang:monotonic_time(millisecond), <<>>, undefined, false)
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

collect(Port, Timeout, Started, Output, Status, Eof) ->
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    Remaining0 = erlang:max(0, Timeout - Elapsed),
    Remaining = case Status of undefined -> Remaining0; _ -> erlang:min(Remaining0, 5000) end,
    receive
        {Port, {data, Chunk}} ->
            collect(Port, Timeout, Started, bounded_append(Output, Chunk), Status, Eof);
        {Port, {exit_status, Code}} when Eof =:= true ->
            {Code, Output, <<>>, false};
        {Port, {exit_status, Code}} ->
            collect(Port, Timeout, Started, Output, Code, Eof);
        {Port, eof} when Status =/= undefined ->
            {Status, Output, <<>>, false};
        {Port, eof} ->
            collect(Port, Timeout, Started, Output, Status, true);
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

bounded_append(Output, Chunk) ->
    Combined = <<Output/binary, Chunk/binary>>,
    Limit = 131072,
    Half = Limit div 2,
    case byte_size(Combined) =< Limit of
        true -> Combined;
        false ->
            Head = binary:part(Combined, 0, Half),
            Tail = binary:part(Combined, byte_size(Combined) - Half, Half),
            <<Head/binary, "\n... output truncated ...\n", Tail/binary>>
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
