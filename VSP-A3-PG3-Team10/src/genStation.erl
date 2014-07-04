-module(genStation).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, delete_last/1, shuffle/1, type_is/1, to_String/1, bestimme_mis/2]).
-behaviour(gen_server).
-define(LIFETIME, 3333330000).
-define(SLOTLIST, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25]).
-define(A_TYPE_TIME_CHANGE_STEP, 1).
-define(A_TYPE_TIME_TOLERANCE, 2).
-define(TTL, 1).
-define(MILLISECOND_TO_SECONDS_FACTOR, 1000).
-define(MICROSECOND_TO_SECONDS_FACTOR, 1000000).
-define(SENDER_LOG, logFileSender).
-define(DICT_SLOT, slot).
-define(DICT_NEXT_SLOT, nextSlot).
-define(DICT_CLOCK_TYPE, clockType).
-define(DICT_TIME_BALANCE, timeBalance).
-define(DICT_DELAY, delay).

%Functions needed by gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start/1]).

%Saves current data
%% -record(data, {slot, nextSlot, clockType, timeBalance = 0, delay = 0}).

start([Delay, ClockType, IP, MULTICAST, PORT]) -> gen_server:start_link({local, ?MODULE}, ?MODULE, [Delay, ClockType, IP, MULTICAST, PORT], []).

init([Delay, ClockType, Addr, Multi, PortNr]) ->
  {ok, IP} = inet_parse:address(atom_to_list(Addr)),
  {ok, MULTICAST} = inet_parse:address(atom_to_list(Multi)),
  PORT = list_to_integer(atom_to_list(PortNr)),
  dataSave:startLink(),
  LogDatei = lists:concat(["genStation.log"]),
  Sender = openSe(IP, PORT),
  Empfaenger = openRec(MULTICAST, IP, PORT),

  PidRec = spawn(fun() -> listen(LogDatei, Empfaenger, [], 0) end),  %%Prozess lauschen starten
  gen_udp:controlling_process(Empfaenger, PidRec),
  timer:exit_after(?LIFETIME, PidRec, "Timeout Receiver erreicht!\n"),
  timer:apply_after(?LIFETIME, gen_udp, close, [Empfaenger]),


  PidSend = spawn(fun() -> sender(LogDatei, Sender, MULTICAST, PORT, -1) end),  %%Prozess senden starten
  gen_udp:controlling_process(Sender, PidSend),
  timer:exit_after(?LIFETIME, PidSend, "Timeout Sender erreicht!\n"),
  timer:apply_after(?LIFETIME, gen_udp, close, [Sender]),

  random:seed(now()),
  werkzeug:logging(LogDatei, "Station started\n"),
  State = dict:store(?DICT_SLOT, random:uniform(25),
    dict:store(?DICT_NEXT_SLOT, random:uniform(25),
      dict:store(?DICT_CLOCK_TYPE, atom_to_list(ClockType),
        dict:store(?DICT_TIME_BALANCE, 0,
          dict:store(?DICT_DELAY, list_to_integer(atom_to_list(Delay)), dict:new()))))),
  {ok, State}.


%% Frame lauschen
listen(LogDatei, Socket, BookedSlots, FrameNr) ->
  ClockType = gen_server:call(?MODULE, {get_clockType}),
  {ok, {_Address, _Port, Packet}} = gen_udp:recv(Socket, 0),  %%Paket annehmen

  ArriveTime = now_milli(),
  {StationClass, _StationName, _Data, SlotNumber, Time} = decomposeMessage(Packet),  %%Paketdaten
%%   werkzeug:logging(logDatei, io:format("~nNachricht ~p von ~p erhalten", [lists:flatten(Data), StationName])),

  if ClockType =:= "B" -> %% Uhr synchronisieren.
    syncBTime(StationClass, Time, ArriveTime);
    true ->
      syncATime(StationClass, Time, ArriveTime),
      true
  end,

  NextSlot = gen_server:call(?MODULE, {get_nextSlot}),  %%call an station, Slot raussuchen

  Frame = now_milli() / ?MILLISECOND_TO_SECONDS_FACTOR, %%aktuellen Frame feststellen

  %%guckt das hier nach, in welchem Frame wir sind, sodass wir schon für den naechsten Frame, der dann unten NewFrame heisst, einen Slot waehlen?
  if 0.0 > (Frame - trunc(Frame)) ->  %%Wenn Frame angefangen hat
    NowFrame = trunc(Frame) - 1;
    true ->
      NowFrame = trunc(Frame) end,

  if NowFrame > FrameNr ->   %% wenn ein neuer Frame angefangen hat
    NewFrame = NowFrame,    %%naechster Frame
    NewBookedSlots = lists:append([SlotNumber], []),  %% Slotnummer, die im Packet stand, in Liste eintragen
    gen_server:call(?MODULE, {set_slot, NextSlot}),   %%naechsten Slot fuer nächsten Frame eintragen
    random:seed(erlang:now()),
    Slot = random:uniform(25),        %%Slot zufaellig auswaehlen, in dem wir im naechsten frame senden wollen
    gen_server:call(?MODULE, {set_nextSlot, Slot});  
    true ->
      NewFrame = FrameNr,  %%naechster Frame
      NewBookedSlots = lists:append([SlotNumber], BookedSlots), %%Slotnummer fuer naechsten Frame in Liste der gebuchten eintragen
      Slot = NextSlot  %%neuen Slot als naecshten markieren, um beim nächsten Durchlauf in Record zu schreiben (z.80)
  end,

  Res = (lists:any(fun(X) -> X =:= Slot end, NewBookedSlots)),  %%ist Slot fuer next Frame schon in liste der neuen gebuchten?

  if Res ->  %%wenn Slot schon belegt
    NewList = ?SLOTLIST -- NewBookedSlots,  %%neue liste mit allen freien slots erstellen
    random:seed(erlang:now()),
    if length(NewList) > 0 -> %%wenn liste nicht leer
      NewSlot = lists:nth(random:uniform(length(NewList)), NewList);  %%neuen slot aus freien waehlen
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
    Frame = trunc(Time / ?MILLISECOND_TO_SECONDS_FACTOR),
    TimeToSleep = ?MILLISECOND_TO_SECONDS_FACTOR - (Time - (Frame * ?MILLISECOND_TO_SECONDS_FACTOR)),
    timer:sleep(TimeToSleep + ?MILLISECOND_TO_SECONDS_FACTOR),

    RSlot = gen_server:call(?MODULE, {get_nextSlot});
    true ->
      Time = now_milli(),
      Frame = trunc(Time / ?MILLISECOND_TO_SECONDS_FACTOR),
      TimeToSleep = ?MILLISECOND_TO_SECONDS_FACTOR - (Time - (Frame * ?MILLISECOND_TO_SECONDS_FACTOR)),
      timer:sleep(TimeToSleep),
      RSlot = Slot
  end,




%% Zeit berechnen bis unser Slot dran ist.
  SleepDuration =(RSlot-1) * 40 + 10,
  timer:sleep(SleepDuration),
  NextSlot = gen_server:call(?MODULE, {get_nextSlot}),

  gen_udp:send(Socket, Addr, Port, composeMessage(NextSlot)),

  sender(LogDatei, Socket, Addr, Port, NextSlot).


syncBTime(StationClass, PackageTime, ArriveTime) ->
  if StationClass =:= "A" ->
    CurrTimeBal = gen_server:call(?MODULE, {get_timeBalance}),
    %% 
    TimeBal = PackageTime - ArriveTime + CurrTimeBal,
    gen_server:call(?MODULE, {set_timeBalance, TimeBal});
    true -> true
  end,
  true.

syncATime(StationClass, PackageTime, ArriveTime) ->
  if StationClass =:= "A" ->
    CurrTimeBal = gen_server:call(?MODULE, {get_timeBalance}),
   %%  Time= 7,2 -  5,0 = 2,2  Arrive time liegt VOR Sendezeit
    if (PackageTime - ArriveTime) > ?A_TYPE_TIME_TOLERANCE ->  %%unsere Zeit geht nach
      gen_server:call(?MODULE, {set_timeBalance, CurrTimeBal + ?A_TYPE_TIME_CHANGE_STEP});

    %% 7,3  -  5,1 = 2,2    Paket kam sehr spaet an, groesser tolerance. uhrzeit des senders frueher
      (ArriveTime - PackageTime) > ?A_TYPE_TIME_TOLERANCE ->    %%unsere Zeit geht vor
        gen_server:call(?MODULE, {set_timeBalance, CurrTimeBal - ?A_TYPE_TIME_CHANGE_STEP});
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
  trunc(((MegaSecs * ?MICROSECOND_TO_SECONDS_FACTOR + Secs) * ?MICROSECOND_TO_SECONDS_FACTOR + MicroSecs) / ?MILLISECOND_TO_SECONDS_FACTOR)
    + TimeBal
    + TimeDelay
.

composeMessage(NextSlot) ->
  Data = list_to_binary(dataSave:getData()),
  StationType = list_to_bitstring(gen_server:call(?MODULE, {get_clockType})),
  Time = now_milli(),
  <<StationType:8/bitstring, Data:24/binary, NextSlot:8/integer, Time:64 / integer - big>>.

decomposeMessage(Package) ->
  <<BinStationClass:8/bitstring,
  BinStationName:10/binary,
  BinData:14/binary,
  SlotNumber:8/integer,
  Time:64 / integer - big>> = Package,

  StationName = binary_to_list(BinStationName),
  Data = binary_to_list(BinData),
  StationClass = bitstring_to_list(BinStationClass),
  {StationClass, StationName, Data, SlotNumber, Time}.



handle_call({get_slot}, _From, State) ->
  {reply, dict:fetch(?DICT_SLOT, State), State};

handle_call({set_slot, Slot}, _From, State) ->
  {reply, {ok}, dict:store(?DICT_SLOT, Slot, State)};

handle_call({get_nextSlot}, _From, State) ->
  {reply, dict:fetch(?DICT_NEXT_SLOT, State), State};

handle_call({set_nextSlot, Slot}, _From, State) ->
  {reply, {ok}, dict:store(?DICT_NEXT_SLOT, Slot, State)};

handle_call({get_timeBalance}, _From, State) ->
  {reply, dict:fetch(?DICT_TIME_BALANCE, State), State};

handle_call({set_timeBalance, Time}, _From, State) ->
  {reply, {ok}, dict:store(?DICT_TIME_BALANCE, Time, State)};

handle_call({get_delay}, _From, State) ->
  {reply, dict:fetch(?DICT_DELAY, State), State};

handle_call({get_delayTimes}, _From, State) ->
  {reply, {dict:fetch(?DICT_DELAY, State), dict:fetch(?DICT_TIME_BALANCE, State)}, State};

handle_call({get_clockType}, _From, State) ->
  {reply, dict:fetch(?DICT_CLOCK_TYPE, State), State}.

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