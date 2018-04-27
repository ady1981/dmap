С целью увеличить счетчик статей про "редкий" язык Erlang еще на одну, расскажем как на коленке собрать Erlang кластер и запустить на нем распараллеленное вычисление. 

<cut>
Для понимания происходящего, читателю возможно понадобится знание основ Erlang (без OTP). Которые, кстати, можно получить ~~не отходя от кассы~~ не уходя из уютного Хабра, прямо тут:
- [Erlang для самых маленьких. Глава 1. Типы данных, переменные, списки и кортежи](https://habr.com/post/195542/)   
- [Глава 2: Модули и функции](https://habr.com/post/197364/)
- [Глава 3: Базовый синтаксис функций](https://habr.com/post/211815/)
- [Глава 4: Система типов](https://habr.com/post/230551/)
 
Но, не будем умничать раньше времени и сначала сделаем...

### Лирическое отступление

Как мы сейчас понимаем, по мере развития IT-индустрии совершенно разные языки программирования находят свое применение. Не стал исключением и язык Erlang, изначально разрабатывавшийся как язык для отказоустойчивых систем, но завоевавший свою нишу в нашем мире распределенных многопроцессорных систем благодаря:
- удобной модели многопоточного программирования ([concurrency](https://ru.wikipedia.org/wiki/%D0%9F%D0%B0%D1%80%D0%B0%D0%BB%D0%BB%D0%B5%D0%BB%D0%B8%D0%B7%D0%BC_(%D0%B8%D0%BD%D1%84%D0%BE%D1%80%D0%BC%D0%B0%D1%82%D0%B8%D0%BA%D0%B0)));
- удачному расширению этой модели на распределенные системы, состоящие из узлов на разных устройствах ([distributed computing](https://ru.wikipedia.org/wiki/%D0%A0%D0%B0%D1%81%D0%BF%D1%80%D0%B5%D0%B4%D0%B5%D0%BB%D1%91%D0%BD%D0%BD%D1%8B%D0%B5_%D0%B2%D1%8B%D1%87%D0%B8%D1%81%D0%BB%D0%B5%D0%BD%D0%B8%D1%8F));
- эффективной реализации этой модели, позволяющей малыми усилиями разрабатывать [highly available](https://ru.wikipedia.org/wiki/%D0%92%D1%8B%D1%81%D0%BE%D0%BA%D0%B0%D1%8F_%D0%B4%D0%BE%D1%81%D1%82%D1%83%D0%BF%D0%BD%D0%BE%D1%81%D1%82%D1%8C) системы;
- со встроенными механизмами “горячей замены кода” ([hot swapping](https://ru.wikipedia.org/wiki/%D0%93%D0%BE%D1%80%D1%8F%D1%87%D0%B0%D1%8F_%D0%B7%D0%B0%D0%BC%D0%B5%D0%BD%D0%B0));
- с большим количеством средств разработки.

И при этом оставаясь:
- функциональным языком программирования общего назначения,
- для разработки отказоустойчивых систем ([fault-tolerant](https://ru.wikipedia.org/wiki/%D0%9E%D1%82%D0%BA%D0%B0%D0%B7%D0%BE%D1%83%D1%81%D1%82%D0%BE%D0%B9%D1%87%D0%B8%D0%B2%D0%BE%D1%81%D1%82%D1%8C)),
- со своей методологией, позволяющей эффективно разрабатывать сложные системы.

Перечислим компании и проекты, использующих Erlang в production:
- WhatsApp - мессенджер,
- RabbitMQ - брокер сообщений,
- Bet365 - букмекерская онлайн контора, у которой 20+ млн клиентов,
- Riak - распределенная NoSQL база,
- Couchbase  - распределенная NoSQL база,
- Ejabberd - XMPP-сервер,
- Goldman Sachs - крупный американский банк.

Не будем скрывать от читателя, что, и на наш взгляд, у языка есть слабые места, о которые хорошо описаны у других авторов, например: [Erlang в Wargaming](https://habr.com/company/wargaming/blog/279621/)

Ну а теперь давайте по-программируем, и напишем функцию, которая делает...

### Параллельное вычисление значений функции (с ограничением количества одновременно работающих процессов и таймаутом на вычисление)

##### Функция map

Сигнатуру этой функции сделаем похожей на `lists:map`:

`map(Fn, Items, WorkersN, Timeout) -> {ok, [FnResult]} | {error, timeout}, throws {'EXIT', Reason}`, где:
- `Fn` - функция, значения которой нужно вычислить,
- `Items` - список значений аргументов для этой функции,
- `WorkersN` - максимальное количество одноврменно работающих процессов,
- `Timeout` - таймаут для вычисления значения функции, который мы готовы ждать,
- `FnResult` - вычисленное значение фунции `Fn`,
- `Reason` - причина завершения (exit reason) воркер-процесса.

Реализация функции:
```erlang
map(Fn, Items, WorkersN, Timeout) ->
  Total = length(Items),
  Context = #{fn => Fn, 
              items => Items, 
              results => #{}, 
              counter => 1, 
              total => Total, 
              workers => 0, 
              workers_max => min(WorkersN, Total), 
              pids => #{}, 
              timeout => Timeout},
  Self = self(),
  spawn(fun() ->
    Self ! map_loop(Context)
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
```

Вот основные моменты в коде:
- инициализируем значения контекста `Context`, который будем прокидывать дальше в цикле (`map_loop`);
- создаем процесс-супервайзер, который будет запускать процессы-воркеры и ждать от них результата;
- запускаем функцию-цикл `map_loop` для выполнение этого супервайзера;
- ждем результат от супервайзера и возвращаем результат функции;
- приватная функция `get_error` - возращает ошибку в вычислениях или `undefined`, если ошибок не было.

##### Функция map_loop

Сигнатура этой функции: `map_loop(Context) -> [FnResult]`

Реализация:

```erlang
map_loop(#{counter := Counter, 
           total := Total, 
           workers := Workers, 
           workers_max := WorkersMax, 
           fn := Fn, 
           items := Items, 
           pids := PIDs} = Context) when Workers < WorkersMax, Counter =< Total ->
  Self = self(),
  Index = Counter,
  WorkerIndex = Workers + 1,
  PID = spawn(fun() ->
      WorkerPID = self(),
      io:fwrite("{Index, PID, {W, WMax}}: ~p~n", 
                [{Index, WorkerPID, {Workers + 1, WorkersMax}}]),
      Item = lists:nth(Index, Items),
      Self ! {Index, WorkerPID, catch Fn(Item, WorkerIndex)}
    end),
  Context2 = Context#{counter => Counter + 1, 
                      workers => Workers + 1, 
                      pids => PIDs#{PID => Index}},
  map_loop(Context2);
map_loop(#{workers := Workers, timeout := Timeout, pids := _PIDs} = Context) 
  when Workers > 0 ->
  receive
    {Index, PID, {'EXIT', _Reason} = Result} when is_integer(Index) ->%% error case
      io:fwrite("got error: ~p~n", [{Index, PID, Result}]),
      Context2 = set_worker_result(PID, {Index, Result}, Context),
      Context3 = kill_workers(Context2, error),
      create_result(Context3);

    {Index, PID, Result} when is_integer(Index) -> %% ok case
      io:fwrite("got result: ~p~n", [{Index, PID, Result}]),
      Context2 = set_worker_result(PID, {Index, Result}, Context),
      map_loop(Context2)

  after Timeout -> %% timeout case
      io:fwrite("timeout: ~p~n", [#{context => Context}]),
      Context3 = kill_workers(Context, {error, timeout}),
      create_result(Context3)
  end;
map_loop(#{workers := Workers, pids := PIDs} = Context) 
  when Workers == 0, PIDs == #{} ->
  create_result(Context).
```

Пройдемся по реализации:

- первая реализация функции `map_loop` последовательно запускает не больше `WorkersMax` воркеров. Воркер запускается через `spawn` и внутри анонимной функции описана его логика: вычислить значение функции `Fn` и отправить результат супервайзеру;
- вторая реализация функции (которая, как мы напомним, вызывается если не выполнились условия для вызова первой реализации): ждет результат от воркеров. При получении результата она принимает решение, что делать дальше: или продолжать цикл или завершить работу;
- в третью реализацию функции мы приходим, когда больше нет активных воркеров (и это означает, что все вычисления выполнены) и она просто возвращает результат вычислений.

Пробежимся по приватным функциям, которые мы тут использовали:
- `set_worker_result` - сохраняет результат вычисления в `Context` супервайзера;
- `kill_workers` - убивает все процессы с воркерами (для случая прерывания работы);
- `create_result` - выдает результат вычислений, полученных от воркеров.

Полный листинг функции можно посмотреть на GitHub: [тут](https://github.com/ady1981/dmap/blob/master/src/dmap_pmap.erl)

##### Тестирование

Теперь чуть потестируем нашу функцию через Erlang REPL.

1) Запустим вычисление для 2-х воркеров, так чтобы результат от второго воркера пришел раньше, чем от первого:

`>catch dmap_pmap:map(fun(1, _) -> timer:sleep(2000), 1; (2, _) -> timer:sleep(1000), 2 end, [1, 2], 2, 5000).`

В последней строчке - результат вычислений.

```erlang
{Index, PID, {W, WMax}}: {1,<0.1010.0>,{1,2}}
{Index, PID, {W, WMax}}: {2,<0.1011.0>,{2,2}}
got result: {2,<0.1011.0>,2}
got result: {1,<0.1010.0>,1}
{ok,[1,2]}
```

2) Запустим вычисление для 2-х воркеров, так, чтобы в первом воркере случился креш:
 
`>catch dmap_pmap:map(fun(1, _) -> timer:sleep(100), erlang:exit(terrible_error); (2, _) -> timer:sleep(100), 2 end, lists:seq(1, 2), 2, 5000).`
 
```erlang
{Index, PID, {W, WMax}}: {1,<0.2149.0>,{1,2}}
{Index, PID, {W, WMax}}: {2,<0.2150.0>,{2,2}}
got error: {1,<0.2149.0>,{'EXIT',terrible_error}}
kill: <0.2150.0>
{'EXIT',terrible_error}
```

3) Запустим вычисление для 2-х воркеров, так, чтобы время вычисления функции превысило разрешенный таймаут:

`> catch dmap_pmap:map(fun(1, _) -> timer:sleep(2000), erlang:exit(terrible_error); (2, _) -> timer:sleep(100), 2 end, lists:seq(1, 2), 2, 1000).`

```erlang
{Index, PID, {W, WMax}}: {1,<0.3184.0>,{1,2}}
{Index, PID, {W, WMax}}: {2,<0.3185.0>,{2,2}}
got result: {2,<0.3185.0>,2}
timeout: #{context =>
               #{counter => 3,fn => #Fun<erl_eval.12.99386804>,
                 items => [1,2],
                 pids => #{<0.3184.0> => 1},
                 results => #{2 => 2},
                 timeout => 1000,total => 2,workers => 1,workers_max => 2}}
kill: <0.3184.0>
{error,timeout}
``` 

### Вычисления на кластере

Результаты тестирования выглядят разумно, но при чем же тут кластер, может спросить внимательный читатель.
На самом деле, оказывается, что у нас уже есть почти все, что нужно, чтобы запустить вычисления на кластере, где под кластером мы понимаем набор связанных Erlang нод.

В отдельном модуле `dmap_dmap` заведем еще одну функцию, со следующей сигнатурой:

`map({M, F}, Items, WorkersNodes, Timeout) -> {ok, [FnResult]} | {error, timeout}, throws {'EXIT', Reason}`, где:
- `{M, F}` - модуль и имя функции, к которую нужно применить аргументы (аля `F:M(Item)`),
- `Items` - список значений аргументов для этой функции,
- `WorkersNodes` - список имен нод, на которых нужно запустить вычисление,
- `Timeout` - таймаут для вычисления значения функции, который мы готовы ждать.

Реализация:

```
map({M, F}, Items, WorkersNodes, Timeout) ->
  Fn = fun(Item, WorkerIndex) ->
      Node = lists:nth(WorkerIndex, WorkersNodes),
      rpc:call(Node, M, F, [Item])
    end,
  dmap_pmap:map(Fn, Items, length(WorkersNodes), Timeout).
```

Для теста в отдельном модуле заведем функцию, которая возвращает имя своей ноды: 
```
-module(dmap_test).

test(X) ->
  {ok, {node(), X}}.

```

#### Тестирование

Для тестирования нам нужно в двух терминалах запустить по ноде, например, вот так (из рабочего каталога проекта):

`make run NODE_NAME=n1@127.0.0.1`

`make run NODE_NAME=n2@127.0.0.1`

Запустим вычисление на первой ноде:

`(n1@127.0.0.1)1> dmap_dmap:map({dmap_test, test}, lists:seq(1,2), ['n1@127.0.0.1', 'n2@127.0.0.1'], 5000).`

И получим результат:

```
{Index, PID, {W, WMax}}: {1,<0.1400.0>,{1,2}}
{Index, PID, {W, WMax}}: {2,<0.1401.0>,{2,2}}
got result: {1,<0.1400.0>,{ok,{'n1@127.0.0.1',1}}}
got result: {2,<0.1401.0>,{ok,{'n2@127.0.0.1',2}}}
{ok,[{ok,{'n1@127.0.0.1',1}},{ok,{'n2@127.0.0.1',2}}]}
```

Как можно заменить, результаты прилетели от двух нод, как мы и заказывали.


### Вместо заключения

Наш простой пример показывает, что в своей сфере применения Erlang позволяет относительно просто решать полезные задачи (которые не так просто решить с помощью других языков программирования).  

В рамках этой статьи были вопросы относительно кода и сборки библиотеки, которые остались за кадром.

Какие-то детали можно посмотреть в GitHub: [тут](https://github.com/ady1981/dmap).

Остальные детали мы обещаем осветить в следующих статьях.
</cut>