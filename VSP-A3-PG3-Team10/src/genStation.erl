-module(genStation).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, delete_last/1, shuffle/1, type_is/1, to_String/1, bestimme_mis/2]).
-behaviour(gen_server).
-define(LIFETIME, 3333330000).
-define(SLOTLIST, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24]).
-define(ATIMECHANGE, 1).
-define(ATIMETOLERANCE, 2).
-define(TTL, 1).

%Functions needed by gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start/1]).

%Saves current data
-record(data, {slot, nextSlot, clockType, timeBalance = 0, delay = 0}).

start([Delay, ClockType, IP, MULTICAST, PORT]) -> gen_server:start_link({local, ?MODULE}, ?MODULE, [Delay, ClockType, IP, MULTICAST, PORT], []).

init([Delay, ClockType, Addr, Multi, PortNr]) ->
  {ok, IP} = inet_parse:address(atom_to_list(Addr)),
  {ok, MULTICAST} = inet_parse:address(atom_to_list(Multi)),
  PORT = list_to_integer(atom_to_list(PortNr)),
  dataSave:startLink(),
  LogDatei = lists:concat(["genStation.log"]),

  Sender = openSe(IP, PORT),
  Empfaenger = openRec(MULTICAST, IP, PORT),

  PidRec = spawn(fun() -> listen(LogDatei, Empfaenger, [], 0) end),
  gen_udp:controlling_process(Empfaenger, PidRec),
  timer:exit_after(?LIFETIME, PidRec, "Timeout Receiver erreicht!\n"),
  timer:apply_after(?LIFETIME, gen_udp, close, [Empfaenger]),


  PidSend = spawn(fun() -> sender(LogDatei, Sender, MULTICAST, PORT, -1) end),
  gen_udp:controlling_process(Sender, PidSend),
  timer:exit_after(?LIFETIME, PidSend, "Timeout Sender erreicht!\n"),
  timer:apply_after(?LIFETIME, gen_udp, close, [Sender]),

  random:seed(now()),
  werkzeug:logging(LogDatei, "Station started\n"),
  Record = #data{slot = random:uniform(25) - 1, nextSlot = random:uniform(25) - 1, clockType = atom_to_list(ClockType), timeBalance = 0, delay = list_to_integer(atom_to_list(Delay))},
  {ok, Record}.

listen(LogDatei, Socket, BookedSlots, FrameNr) ->
  ClockType = gen_server:call(?MODULE, {get_clockType}),
  {ok, {_Address, _Port, Packet}} = gen_udp:recv(Socket, 0),

  ArriveTime = now_milli(),
  {_StationName, _Data, StationClass, SlotNumber, Time} = decomposeMessage(Packet),


  if ClockType =:= "B" ->
    syncBTime(StationClass, Time, ArriveTime);
    true ->
      syncATime(StationClass, Time, ArriveTime),
      true
  end,

  NextSlot = gen_server:call(?MODULE, {get_nextSlot}),

  Frame = now_milli() / 1000,
  if 0.0 > (Frame - trunc(Frame)) ->
    NowFrame = trunc(Frame) - 1;
    true ->
      NowFrame = trunc(Frame) end,

  if NowFrame > FrameNr ->
    NewFrame = NowFrame,
    NewBookedSlots = lists:append([SlotNumber], []),
    gen_server:call(?MODULE, {set_slot, NextSlot}),
    random:seed(erlang:now()),
    Slot = random:uniform(25) - 1,
    gen_server:call(?MODULE, {set_nextSlot, Slot});
    true ->
      NewFrame = FrameNr,
      NewBookedSlots = lists:append([SlotNumber], BookedSlots),
      Slot = NextSlot
  end,

  Res = (lists:any(fun(X) -> X =:= Slot end, NewBookedSlots)),

  if Res ->
    NewList = ?SLOTLIST -- NewBookedSlots,
    random:seed(erlang:now()),
    if length(NewList) > 0 ->
      NewSlot = lists:nth(random:uniform(length(NewList)), NewList);
      true -> NewSlot = Slot
    end,
    gen_server:call(?MODULE, {set_nextSlot, NewSlot});
    true -> true

  end,

  listen(LogDatei, Socket, NewBookedSlots, NewFrame).

sender(LogDatei, Socket, Addr, Port, Slot) ->
%-1 bei initialisierung
  if Slot =:= -1 ->

    Time = now_milli(),

% Wie lange müssen wir noch warten, bis der Frame zu Ende ist
    Frame = trunc(Time / 1000),
    TimeToSleep = 1000 - (Time - (Frame * 1000)),
    timer:sleep(TimeToSleep + 1000),

    RSlot = gen_server:call(?MODULE, {get_nextSlot});
    true ->
      Time = now_milli(),
      Frame = trunc(Time / 1000),
      TimeToSleep = 1000 - (Time - (Frame * 1000)),
      timer:sleep(TimeToSleep),
      RSlot = Slot
  end,


%%   %% Zeitdifferenz zwischen dem wirklichen Frameanfang und dem gewarteten Anfang

  timer:sleep((RSlot * 40 + 10)),
  NextSlot = gen_server:call(?MODULE, {get_nextSlot}),

  gen_udp:send(Socket, Addr, Port, composeMessage(NextSlot)),

  sender(LogDatei, Socket, Addr, Port, NextSlot).


syncBTime(StationClass, Time, ArriveTime) ->
  if StationClass =:= "A" ->
    CurrTimeBal = gen_server:call(?MODULE, {get_timeBal}),
    TimeBal = Time - ArriveTime + CurrTimeBal,
    gen_server:call(?MODULE, {set_timeBal, TimeBal});
    true -> true
  end,
  true.

syncATime(StationClass, Time, ArriveTime) ->
  if StationClass =:= "A" ->
    CurrTimeBal = gen_server:call(?MODULE, {get_timeBal}),
%ArriveTime = CurrTimeBal+ArriveTimeWBal,
    if (Time - ArriveTime) > ?ATIMETOLERANCE ->
      gen_server:call(?MODULE, {set_timeBal, CurrTimeBal + ?ATIMECHANGE});


      (ArriveTime - Time) > ?ATIMETOLERANCE ->
        gen_server:call(?MODULE, {set_timeBal, CurrTimeBal - ?ATIMECHANGE});
      true -> true
    end;
    true -> true
  end,
  true.

openSe(Addr, Port) ->
  io:format("~nAddr: ~p~nPort: ~p~n", [Addr, Port]),
  {ok, Socket} = gen_udp:open(Port, [binary, {active, false}, {reuseaddr, true}, {ip, Addr}, {multicast_ttl, ?TTL}, inet, {multicast_loop, true}, {multicast_if, Addr}]),
  Socket.

openRec(MultiCast, Addr, Port) ->
  io:format("~nMultiCast: ~p~nAddr: ~p~nPort: ~p~n", [MultiCast, Addr, Port]),
  {ok, Socket} = gen_udp:open(Port, [binary, {active, false}, {reuseaddr, true}, {multicast_if, Addr}, inet, {multicast_ttl, ?TTL}, {multicast_loop, true}, {add_membership, {MultiCast, Addr}}]),
  Socket.

now_milli() ->
  {TimeDelay, TimeBal} = gen_server:call(?MODULE, {get_delayTimes}),
  {MegaSecs, Secs, MicroSecs} = erlang:now(),
  trunc(((MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs) / 1000)
    + TimeBal
    + TimeDelay
.

composeMessage(NextSlot) ->
  Data = list_to_binary(dataSave:getData()),
  StationType = list_to_bitstring(gen_server:call(?MODULE, {get_clockType})),
  Time = now_milli(),
  <<Data:24/binary, StationType:8/bitstring, NextSlot:8/integer, Time:64 / integer - big>>.

decomposeMessage(Package) ->
  <<BinStationName:10/binary,
  BinData:14/binary,
  BinStationClass:8/bitstring,
  SlotNumber:8/integer,
  Time:64 / integer - big>> = Package,

  StationName = binary_to_list(BinStationName),
  Data = binary_to_list(BinData),
  StationClass = bitstring_to_list(BinStationClass),
  {StationName, Data, StationClass, SlotNumber, Time}.



handle_call({get_slot}, _From, DataRecord) ->
  {reply, DataRecord#data.slot, DataRecord};

handle_call({set_slot, Slot}, _From, DataRecord) ->
  {reply, {ok}, DataRecord#data{slot = Slot}};

handle_call({get_nextSlot}, _From, DataRecord) ->
  {reply, DataRecord#data.nextSlot, DataRecord};

handle_call({set_nextSlot, Slot}, _From, DataRecord) ->
  {reply, {ok}, DataRecord#data{nextSlot = Slot}};

handle_call({get_timeBal}, _From, DataRecord) ->
  {reply, DataRecord#data.timeBalance, DataRecord};

handle_call({set_timeBal, Time}, _From, DataRecord) ->
  {reply, {ok}, DataRecord#data{timeBalance = Time}};

handle_call({get_delay}, _From, DataRecord) ->
  {reply, DataRecord#data.delay, DataRecord};

handle_call({get_delayTimes}, _From, DataRecord) ->
  {reply, {DataRecord#data.delay, DataRecord#data.timeBalance}, DataRecord};

handle_call({get_clockType}, _From, DataRecord) ->
  {reply, DataRecord#data.clockType, DataRecord}.

%% stop() ->
%%   gen_server:cast(?MODULE, stop).
%
terminate(normal, _State) ->
  ok.
%
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Msg, State) -> {noreply, State}.
code_change(_OldVersion, State, _Extra) -> {ok, State}.