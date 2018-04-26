-module(dmap_util).

%% API
-export([map_indexed/2]).


map_indexed(Fn, L)  when is_function(Fn), is_list(L) ->
  lists:map(fun(Index) ->
      Item = lists:nth(Index, L),
      Fn(Index, Item)
     end,
    lists:seq(1, length(L))).
