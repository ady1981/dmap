-module(dmap_test).

%% API
-export([]).

-compile([export_all]). %% TODO: dev only

who_am_i() ->
  {ok, node()}.
