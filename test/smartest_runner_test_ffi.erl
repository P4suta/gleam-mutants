%% SPDX-FileCopyrightText: 2026 gleam_mutants contributors
%% SPDX-License-Identifier: MIT OR Apache-2.0

-module(smartest_runner_test_ffi).
-export([block/1]).

block(Milliseconds) ->
    timer:sleep(Milliseconds),
    nil.
