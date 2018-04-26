-module(dmap_dmap).

%% API
-export([map/3, map/4]).

map({M, F}, Items, WorkersNodes) ->
  map({M, F}, Items, WorkersNodes, 5000).

map({M, F}, Items, WorkersNodes, Timeout) ->
  Fn = fun(Item, WorkerIndex) ->
      Node = lists:nth(WorkerIndex, WorkersNodes),
      rpc:call(Node, M, F, [Item])
    end,
  dmap_pmap:map(Fn, Items, length(WorkersNodes), Timeout).


%% TODO: remove example
%% dmap_dmap:map({dmap_test, test}, lists:seq(1,2), ['n1@127.0.0.1', 'n2@127.0.0.1'], 5000).