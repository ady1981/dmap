-module(dmap_pmap).

%% API
-export([pmap/3, pmap/4]).


pmap(Fn, Items, WorkersN) ->
  pmap(Fn, Items, WorkersN, 5000).

%% @doc Функция запускает вычисление функции Fn для значений Items одновременно в WorkersN потоках. Функция ждет не больше времени Timeout для вычисления Fn(Item, WorkerIndex).
%% until_first_error(Fn, Items, WorkersN, Timeout) -> {ok, [FnResult]} | {error, timeout}, throws {'EXIT', Reason} - результат выполненых вычислений.
%% Fn(Item, WorkerIndex) -> FnResult, throws {'EXIT', Reason}.
%% Детали вычислений:
%%   - если во время вычисления Fn(Item, WorkerIndex) возникает ошибка {'EXIT', Reason}, то вычисление останавливается и бросается {'EXIT', Reason};
%%   - если время вычисления хотя бы одного значения Fn(Item, WorkerIndex) превышает Timeout, то результат такого вычисления будет {error, timeout} и вычисление останавливается. Максимальное время вычисления без {error, timeout}
%% может немного превышать Timeout.
pmap(Fn, Items, WorkersN, Timeout) when is_function(Fn), is_integer(WorkersN), WorkersN >= 1, is_list(Items) -> %% [FnResult], Result = FnResult | killed, length(Results) <= length(Items)
  Total = length(Items),
  State = #{fn => Fn, items => Items, results => #{}, counter => 1, total => Total, workers => 0, workers_max => min(WorkersN, Total), pids => #{}, timeout => Timeout},
  Self = self(),
  spawn(fun() ->
    Self ! pmap_loop(State)
  end),
  Result = receive
             Any -> Any
           end,
  case get_error(Result) of
    undefined ->
      {ok, Result};
    {'EXIT', Reason} ->
      throw({'EXIT', Reason});
    {error, timeout} ->
      {error, timeout}
  end.

%% private

get_error([] = _FnResults) ->
  undefined;

get_error([{'EXIT', _Reason} = Error | _] ) ->
  Error;

get_error([{error, timeout} = Error | _] ) ->
  Error;

get_error([_ | Tail] ) ->
  get_error(Tail).


kill_workers(#{pids := PIDs} = State, Reason) ->
  lists:foldl(fun({CurrentPID, CurrentIndex}, Current) ->
    %%io:fwrite("kill: ~p~n", [CurrentPID]),
    true = erlang:exit(CurrentPID, kill),
    set_worker_result(CurrentPID, {CurrentIndex, Reason}, Current)
    end,
    State,
    maps:to_list(PIDs)).


pmap_loop(#{counter := Counter, total := Total, workers := Workers, workers_max := WorkersMax, fn := Fn, items := Items, pids := PIDs} = State) when Workers < WorkersMax, Counter =< Total ->
  Self = self(),
  Index = Counter,
  WorkerIndex = Workers + 1,
  PID = spawn(fun() ->
    WorkerPID = self(),
    %%io:fwrite("{Index, PID, {W, WMax}}: ~p~n", [{Index, WorkerPID, {Workers + 1, WorkersMax}}]),
    Item = lists:nth(Index, Items),
    Self ! {Index, WorkerPID, catch Fn(Item, WorkerIndex)}
    end),
  State2 = State#{counter => Counter + 1, workers => Workers + 1, pids => PIDs#{PID => Index}},
  pmap_loop(State2);

pmap_loop(#{workers := Workers, timeout := Timeout, pids := _PIDs} = State) when Workers > 0 ->
  receive
    {Index, PID, {'EXIT', _Reason} = Result} when is_integer(Index) -> %% error case
      %%io:fwrite("got error: ~p~n", [{Index, PID, Result}]),
      State2 = set_worker_result(PID, {Index, Result}, State),
      State3 = kill_workers(State2, error),
      create_result(State3);

    {Index, PID, Result} when is_integer(Index) -> %% ok case
      %%io:fwrite("got result: ~p~n", [{Index, PID, Result}]),
      State2 = set_worker_result(PID, {Index, Result}, State),
      pmap_loop(State2)

  after Timeout -> %% timeout case
      %%io:fwrite("timeout: ~p~n", [#{state => State}]),
      State3 = kill_workers(State, {error, timeout}),
      create_result(State3)
  end;

pmap_loop(#{workers := Workers, pids := PIDs} = State) when Workers == 0, PIDs == #{} ->
  create_result(State).


set_worker_result(PID, {Index, Result}, #{results := Results, workers := Workers, pids := PIDs} = State) ->
  State#{results => Results#{Index => Result}, workers => Workers - 1, pids => maps:remove(PID, PIDs)}.


create_result(#{results := Results, pids := _PIDs} = _State) ->
  Results2 = maps:to_list(Results),
  Results3 = lists:sort(fun({A, _}, {B, _}) -> A < B end, Results2),
  lists:map(fun({_, R}) -> R end, Results3).


%% TODO: remove example
%% catch dmap_pmap:pmap(fun(1, _) -> timer:sleep(100), exit(error); (2, _) -> timer:sleep(100), ok end, lists:seq(1, 2), 3, 1000).