%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(smartest_discovery_ffi).
-export([main/0]).

main() ->
    Package = package_name(),
    Filter = env(<<"SMARTEST_FILTER">>),
    Files = filelib:wildcard("test/**/*.{erl,gleam}"),
    Modules = lists:sort([module_from_path(File) || File <- Files]),
    {Passed0, Failed0, Bindings, ManifestComplete, Results} = lists:foldl(
      fun(Module, Counts) -> run_module(Package, Module, Filter, Counts) end,
      {0, 0, [], true, []},
      Modules
    ),
    {Passed1, Failed1} = write_evidence_report(Results, Passed0, Failed0),
    {Passed, Failed} = maybe_write_manifest(
      Filter, Bindings, ManifestComplete, Passed1, Failed1),
    io:format("~n~B passed, ~B failed~n", [Passed, Failed]),
    case Failed of
        0 -> erlang:halt(0);
        _ -> erlang:halt(1)
    end.

run_module(Package, Module, Filter, Counts) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Exports = lists:sort([
              Function || {Function, 0} <- Module:module_info(exports),
                          is_test_name(Function),
                          selected(Module, Function, Filter)
            ]),
            lists:foldl(
              fun(Function, Acc) -> run_export(Package, Module, Function, Acc) end,
              Counts,
              Exports
            );
        {error, Reason} ->
            io:format("FAIL ~tp could not load: ~tp~n", [Module, Reason]),
            mark_incomplete(increment_failed(Counts))
    end.

run_export(Package, Module, Function, Counts) ->
    try apply(Module, Function, []) of
        Value when is_tuple(Value), tuple_size(Value) =:= 3,
                   element(1, Value) =:= test ->
            Entry = 'smartest@runner':entry(
              Package,
              atom_to_binary(Module, utf8),
              atom_to_binary(Function, utf8),
              Value
            ),
            Bindings = 'smartest@runner':generator_bindings(Entry),
            Reports = 'smartest@runner':run_entry(
              Entry,
              workspace_options()
            ),
            lists:foldl(fun report/2, add_bindings(Counts, Bindings), Reports);
        _LegacyValue ->
            io:put_chars("."),
            Legacy = 'smartest@runner':legacy_result(
              Package,
              atom_to_binary(Module, utf8),
              atom_to_binary(Function, utf8),
              true,
              <<"opaque legacy test">>
            ),
            increment_passed(add_result(Counts, Legacy))
    catch
        Class:Reason:Stack ->
            Message = smartest_runtime_ffi:format_failure(Class, Reason, Stack),
            io:format(
              "~nFAIL ~ts/~ts~n~ts~n",
              [atom_to_binary(Module, utf8), atom_to_binary(Function, utf8),
               Message]
            ),
            Legacy = 'smartest@runner':legacy_result(
              Package,
              atom_to_binary(Module, utf8),
              atom_to_binary(Function, utf8),
              false,
              Message
            ),
            mark_incomplete(increment_failed(add_result(Counts, Legacy)))
    end.

report(Result, Counts) ->
    WithResult = add_result(Counts, Result),
    case 'smartest@runner':succeeded(Result) of
        true ->
            io:put_chars("."),
            increment_passed(WithResult);
        false ->
            io:format("~n~ts", ['smartest@runner':render_result(Result)]),
            increment_failed(WithResult)
    end.

increment_passed({Passed, Failed, Bindings, Complete, Results}) ->
    {Passed + 1, Failed, Bindings, Complete, Results}.
increment_failed({Passed, Failed, Bindings, Complete, Results}) ->
    {Passed, Failed + 1, Bindings, Complete, Results}.

add_bindings({Passed, Failed, Existing, Complete, Results}, Bindings) ->
    {Passed, Failed, Existing ++ Bindings, Complete, Results}.

add_result({Passed, Failed, Bindings, Complete, Results}, Result) ->
    {Passed, Failed, Bindings, Complete, Results ++ [Result]}.

mark_incomplete({Passed, Failed, Bindings, _, Results}) ->
    {Passed, Failed, Bindings, false, Results}.

write_evidence_report(Results, Passed, Failed) ->
    {ok, Directory} = file:get_cwd(),
    Root = unicode:characters_to_binary(Directory),
    case 'smartest@report':write(Root, {report, Results}) of
        {ok, _} -> {Passed, Failed};
        {error, Reason} ->
            io:format("~nFAIL evidence report~n~ts~n", [Reason]),
            {Passed, Failed + 1}
    end.

maybe_write_manifest(Filter, _Bindings, _Complete, Passed, Failed)
  when Filter =/= <<>> -> {Passed, Failed};
maybe_write_manifest(_Filter, _Bindings, false, Passed, Failed) ->
    io:format("~nGenerator manifest was not replaced because discovery was incomplete.~n"),
    {Passed, Failed};
maybe_write_manifest(_Filter, Bindings, true, Passed, Failed) ->
    {ok, Directory} = file:get_cwd(),
    Root = unicode:characters_to_binary(Directory),
    case 'smartest@storage':write_generator_manifest(Root, Bindings) of
        {ok, _} -> {Passed, Failed};
        {error, Reason} ->
            io:format("~nFAIL generator manifest~n~ts~n", [Reason]),
            {Passed, Failed + 1}
    end.

is_test_name(Function) ->
    lists:suffix("_test", atom_to_list(Function)).

selected(_Module, _Function, <<>>) -> true;
selected(Module, Function, Filter) ->
    Name = <<(atom_to_binary(Module, utf8))/binary, "/",
             (atom_to_binary(Function, utf8))/binary>>,
    binary:match(Name, Filter) =/= nomatch.

module_from_path(Path) ->
    Relative0 = lists:flatten(string:replace(Path, "\\", "/", all)),
    Relative1 = case lists:prefix("test/", Relative0) of
        true -> lists:nthtail(length("test/"), Relative0);
        false -> Relative0
    end,
    Relative2 = filename:rootname(Relative1),
    list_to_atom(lists:flatten(string:replace(Relative2, "/", "@", all))).

package_name() ->
    case file:read_file("gleam.toml") of
        {ok, Source} ->
            case re:run(
              Source,
              <<"(?m)^\\s*name\\s*=\\s*\"([a-z][a-z0-9_]*)\"">>,
              [{capture, [1], binary}]
            ) of
                {match, [Name]} -> Name;
                _ -> <<"unknown-package">>
            end;
        _ -> <<"unknown-package">>
    end.

env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.

workspace_options() ->
    {ok, Directory} = file:get_cwd(),
    Root = unicode:characters_to_binary(Directory),
    Now = erlang:system_time(millisecond),
    case env(<<"SMARTEST_REPLAY_ID">>) of
        <<>> -> 'smartest@runner':workspace_options(Root, Now);
        Id -> 'smartest@runner':replay_options(Root, Id, Now)
    end.
