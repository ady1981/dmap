-module(dmap_dmap).

%% API
-export([pmap/4]).


pmap({M, F}, Items, WorkersNodes, Timeout) ->
  WorkersNodes2 = maps:from_list(dmap_util:map_indexed(fun(Index, Node) -> {Index, Node} end, WorkersNodes)),
  Fn = fun(Item, WorkerIndex) ->
      Node = maps:get(WorkerIndex, WorkersNodes2),
      rpc:call(Node, M, F, [Item])
    end,
  dmap_pmap:pmap(Fn, Items, length(WorkersNodes), Timeout).


%% TODO: remove example
%% dmap_dmap:pmap({dmap_test, test}, lists:seq(1,2), ['n1@127.0.0.1', 'n2@127.0.0.1'], 5000).