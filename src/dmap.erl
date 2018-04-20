-module(dmap).

%% API exports
-export([start/0]).

%%%% API

start() ->
  application:ensure_all_started(dmap).
