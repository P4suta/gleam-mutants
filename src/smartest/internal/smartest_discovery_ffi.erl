%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(smartest_discovery_ffi).
-export([main/0]).

main() ->
    reset_protocol_state(),
    case load_selection() of
        {error, Reason} ->
            io:format("FAIL test selection protocol~n~ts~n", [Reason]),
            erlang:halt(2);
        Selection -> erlang:put(smartest_selection, Selection)
    end,
    Package = package_name(),
    Filter = env(<<"SMARTEST_FILTER">>),
    Files = filelib:wildcard("test/**/*.{erl,gleam}"),
    Modules = lists:sort([module_from_path(File) || File <- Files]),
    {Passed0, Failed0, Bindings, ManifestComplete, Results} = lists:foldl(
      fun(Module, Counts) -> run_module(Package, Module, Filter, Counts) end,
      {0, 0, [], true, []},
      Modules
    ),
    {Passed1, Failed1} = validate_selected(Passed0, Failed0),
    {Passed2, Failed2} = write_evidence_report(Results, Passed1, Failed1),
    {Passed3, Failed3} = maybe_write_manifest(
      Filter, Bindings, ManifestComplete, Passed2, Failed2),
    {Passed, Failed} = maybe_write_impact(
      Filter, ManifestComplete, Passed3, Failed3),
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
    Root = test_id(Package, Module, Function),
    case selected_export(Root) of
        false -> Counts;
        true -> run_selected_export(Package, Module, Function, Root, Counts)
    end.

run_selected_export(Package, Module, Function, Root, Counts) ->
    try smartest_runtime_ffi:with_test_context(
          Root, fun() -> apply(Module, Function, []) end) of
        Value when is_tuple(Value), tuple_size(Value) =:= 3,
                   element(1, Value) =:= test ->
            Entry = 'smartest@runner':entry(
              Package,
              atom_to_binary(Module, utf8),
              atom_to_binary(Function, utf8),
              Value
            ),
            Ids = case protocol_enabled() of
                true -> ['smartest@evidence':test_id_to_string(Id)
                         || Id <- 'smartest@runner':test_ids(Entry)];
                false -> []
            end,
            add_descriptors(Ids, <<"smartest-leaf">>),
            Bindings = 'smartest@runner':generator_bindings(Entry),
            Reports = case selection() of
                all -> 'smartest@runner':run_entry(Entry, workspace_options());
                {selected, Selectors} ->
                    Matching = [Id || Id <- Ids, lists:member(Id, Selectors)],
                    mark_matched(Matching),
                    'smartest@runner':run_entry_selected(
                      Entry, workspace_options(), Matching)
            end,
            lists:foldl(fun report/2, add_bindings(Counts, Bindings), Reports);
        _LegacyValue ->
            add_descriptor(Root, <<"legacy-export">>),
            mark_matched([Root]),
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
            add_descriptor(Root, <<"legacy-export">>),
            mark_matched([Root]),
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

maybe_write_manifest(Filter, Bindings, Complete, Passed, Failed) ->
    case selection() of
        {selected, _} -> {Passed, Failed};
        all -> maybe_write_full_manifest(Filter, Bindings, Complete, Passed, Failed)
    end.

maybe_write_full_manifest(Filter, _Bindings, _Complete, Passed, Failed)
  when Filter =/= <<>> -> {Passed, Failed};
maybe_write_full_manifest(_Filter, _Bindings, false, Passed, Failed) ->
    io:format("~nGenerator manifest was not replaced because discovery was incomplete.~n"),
    {Passed, Failed};
maybe_write_full_manifest(_Filter, Bindings, true, Passed, Failed) ->
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

%% Adaptive protocol ---------------------------------------------------------

reset_protocol_state() ->
    erlang:put(smartest_descriptors, []),
    erlang:put(smartest_matched_selectors, []),
    case ets:whereis(gleam_mutants_test_impact) of
        undefined -> ok;
        Table -> ets:delete(Table)
    end,
    %% The discovery process owns the table for the whole suite. Test bodies
    %% may run in short-lived child processes, so lazily creating it there
    %% would discard their observations when the child exits.
    case env(<<"GLEAM_MUTANTS_TEST_IMPACT_FILE">>) of
        <<>> -> ok;
        _ -> ets:new(gleam_mutants_test_impact, [named_table, public, set])
    end,
    ok.

protocol_enabled() ->
    env(<<"GLEAM_MUTANTS_TEST_IMPACT_FILE">>) =/= <<>> orelse
      env(<<"GLEAM_MUTANTS_TEST_SELECTION_FILE">>) =/= <<>>.

selection() ->
    case erlang:get(smartest_selection) of
        undefined -> all;
        Value -> Value
    end.

load_selection() ->
    case env(<<"GLEAM_MUTANTS_TEST_SELECTION_FILE">>) of
        <<>> -> all;
        Path ->
            case valid_protocol_path(Path) of
                false -> {error, <<"selection file must be below .gleam_mutants">>};
                true -> decode_selection(Path)
            end
    end.

decode_selection(Path) ->
    try
        {ok, Source} = file:read_file(Path),
        Document = json:decode(Source),
        #{<<"schema_version">> := 1,
          <<"runner">> := <<"smartest">>,
          <<"runtime">> := Runtime,
          <<"selectors">> := Selectors} = Document,
        true = Runtime =:= runtime_name(),
        true = is_list(Selectors),
        true = lists:all(fun is_binary/1, Selectors),
        true = length(Selectors) =:= length(lists:usort(Selectors)),
        {selected, Selectors}
    catch
        _:_ -> {error, <<"invalid or incompatible test selection file">>}
    end.

valid_protocol_path(Path0) ->
    {ok, Directory} = file:get_cwd(),
    Path = filename:absname(unicode:characters_to_list(Path0)),
    Base = filename:join(filename:absname(Directory), ".gleam_mutants"),
    Path =:= Base orelse lists:prefix(Base ++ "/", Path)
      orelse lists:prefix(Base ++ "\\", Path).

runtime_name() ->
    case env(<<"GLEAM_MUTANTS_RUNTIME">>) of
        <<>> -> <<"erlang">>;
        Runtime -> Runtime
    end.

test_id(Package, Module, Function) ->
    Id = 'smartest@evidence':test_id(
      Package, atom_to_binary(Module, utf8), atom_to_binary(Function, utf8)),
    'smartest@evidence':test_id_to_string(Id).

selected_export(Root) ->
    case selection() of
        all -> true;
        {selected, Selectors} ->
            Prefix = binary_to_list(<<Root/binary, "/">>),
            lists:any(fun(Selector) ->
              Selector =:= Root orelse lists:prefix(Prefix, binary_to_list(Selector))
            end, Selectors)
    end.

add_descriptors(Ids, Kind) ->
    lists:foreach(fun(Id) -> add_descriptor(Id, Kind) end, Ids).

add_descriptor(Id, Kind) ->
    case protocol_enabled() of
        false -> ok;
        true ->
            Existing = erlang:get(smartest_descriptors),
            erlang:put(smartest_descriptors, [{Id, Id, Kind} | Existing]),
            ok
    end.

mark_matched(Ids) ->
    case protocol_enabled() of
        false -> ok;
        true ->
            Existing = erlang:get(smartest_matched_selectors),
            erlang:put(smartest_matched_selectors, Ids ++ Existing),
            ok
    end.

validate_selected(Passed, Failed) ->
    case selection() of
        all -> {Passed, Failed};
        {selected, Selectors} ->
            Matched = lists:usort(erlang:get(smartest_matched_selectors)),
            Unknown = [Selector || Selector <- Selectors,
                                    not lists:member(Selector, Matched)],
            case Unknown of
                [] -> {Passed, Failed};
                _ ->
                    io:format("~nFAIL unknown test selector~n~tp~n", [Unknown]),
                    {Passed, Failed + 1}
            end
    end.

maybe_write_impact(_Filter, Complete0, Passed, Failed) ->
    case env(<<"GLEAM_MUTANTS_TEST_IMPACT_FILE">>) of
        <<>> -> {Passed, Failed};
        Path ->
            %% A runner filter is part of the configured test command, so its
            %% selected tests are the complete suite that a later full-suite
            %% confirmation will execute as well.
            Complete = Complete0 andalso selection() =:= all,
            case write_impact(Path, Complete) of
                ok -> {Passed, Failed};
                {error, Reason} ->
                    io:format("~nFAIL test impact manifest~n~ts~n", [Reason]),
                    {Passed, Failed + 1}
            end
    end.

write_impact(Path, Complete) ->
    case valid_protocol_path(Path) of
        false -> {error, <<"impact file must be below .gleam_mutants">>};
        true ->
            Descriptors = lists:reverse(erlang:get(smartest_descriptors)),
            Hits = case ets:whereis(gleam_mutants_test_impact) of
                undefined -> [];
                Table -> ets:tab2list(Table)
            end,
            Tests = [#{<<"selector">> => Selector,
                       <<"test_id">> => TestId,
                       <<"kind">> => Kind}
                     || {Selector, TestId, Kind} <- Descriptors],
            Reaches = [#{<<"test_id">> => TestId,
                         <<"mutant_ids">> => lists:sort([
                           Mutant || {{HitTest, Mutant}} <- Hits,
                                     HitTest =:= TestId])}
                       || {_Selector, TestId, _Kind} <- Descriptors],
            Document = #{<<"schema_version">> => 1,
                         <<"runner">> => <<"smartest">>,
                         <<"runtime">> => runtime_name(),
                         <<"complete">> => Complete,
                         <<"tests">> => Tests,
                         <<"reaches">> => Reaches},
            atomic_write(Path, iolist_to_binary(json:encode(Document)))
    end.

atomic_write(Path0, Contents) ->
    Path = unicode:characters_to_list(Path0),
    Temporary = Path ++ ".tmp-" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(Path),
    case file:write_file(Temporary, Contents, [binary, sync]) of
        ok ->
            case file:rename(Temporary, Path) of
                ok -> ok;
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, unicode:characters_to_binary(io_lib:format("~tp", [Reason]))}
            end;
        {error, Reason} ->
            _ = file:delete(Temporary),
            {error, unicode:characters_to_binary(io_lib:format("~tp", [Reason]))}
    end.
