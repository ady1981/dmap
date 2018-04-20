-module(dmap).

%% API exports
-export([start/0]).

-compile([export_all]). %% TODO: dev only

%%%% API

start() ->
  application:ensure_all_started(dmap).
