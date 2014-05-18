%%%-------------------------------------------------------------------
%%% @author Leon
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Okt 2013 16:31
%%%-------------------------------------------------------------------
-module(queueAdministration).
-author("Leon").

%% API
-export([queueService/4, stop/0]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, pushSL/2, findneSL/2, popSL/1, findSL/2, minNrSL/1, to_String/1, lengthSL/1]).

-define(QUEUEPROCESSNAME, queueservice).

queueService(Order, Arguments, ConfigDict, ClientDict) ->
  %Prozesskontrolle: Wird erst erzeugt, wenn benötigt
  Logfile = dict:fetch(logfile, ConfigDict),
  Known = erlang:whereis(?QUEUEPROCESSNAME),
  case Known of
    undefined ->
      PIDqueueservice = erlang:spawn(fun() -> queueServiceLoop(ConfigDict, ClientDict, [], [], 0) end),
      erlang:register(?QUEUEPROCESSNAME, PIDqueueservice),
      logging(Logfile, io_lib:format("~p Queue Service erfolgreich gestartet PID: ~p\n", [timeMilliSecond(), PIDqueueservice]));
    _NotUndef -> ok
  end,
  ?QUEUEPROCESSNAME ! {Order, Arguments}
.

queueServiceLoop(ConfigDict, ClientDict, HBQ, DLQ, LastDLQMsgNumber) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  DLQLimit = dict:fetch(dlqlimit, ConfigDict),
  receive
    kill -> true;
    {getmessages, PID} ->
      logging(Logfile, io_lib:format("~p received get request from ~p \n", [werkzeug:timeMilliSecond(), PID])),
%%       TODO: Wenn nötig Client hinzufügen, sonst client timer neu starten
      {PID, NextMsgId, NewClientDict} = clientAdministration:getClientData(PID, ConfigDict, ClientDict),
      queueServiceLoop(ConfigDict, NewClientDict, HBQ, DLQ, LastDLQMsgNumber);

    {dropmessage, {Message, Number}} ->
%% TODO: Check if number and string
      NewMessage = Message ++ "; HBQ In: " ++ timeMilliSecond(),
      NewHBQ = pushSL(HBQ, {Number, NewMessage}),
      logging(Logfile, io_lib:format("~p received drop request, Message: ~p, Number: ~p, HBQ: ~p \n", [timeMilliSecond(), Message, Number, NewHBQ])),

      HBQLength = length(NewHBQ),
      HalfDLQCapacity = DLQLimit / 2,
      if
%%  In DLQ übertragen wenn  anz(HBQ)> Kap (DLQ)/2 ODER wenn keine Lücke zwischen Nachricht und DLQ vorhanden ist.
        ((HBQLength > HalfDLQCapacity) or (LastDLQMsgNumber + 1 =:= Number)) ->
          {NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber} = transferToDLQ(NewHBQ, DLQ, LastDLQMsgNumber, ConfigDict),
          queueServiceLoop(ConfigDict, ClientDict, NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber);
%% Schwellwert nicht erreicht und Lücke vorhanden
        (HBQLength =< HalfDLQCapacity) ->
          queueServiceLoop(ConfigDict, ClientDict, NewHBQ, DLQ, LastDLQMsgNumber)
      end;


    Any ->
      logging(Logfile, io_lib:format("~p received unknown order: ~p\n", [timeMilliSecond(), Any])),
      queueServiceLoop(ConfigDict, ClientDict, HBQ, DLQ, LastDLQMsgNumber)
  end
.

stop() ->
  Known = erlang:whereis(?QUEUEPROCESSNAME),
  case Known of
    undefined -> false;
    _NotUndef -> ?QUEUEPROCESSNAME ! kill, true
  end
.

transferToDLQ(HBQ, DLQ, LastDLQMsgNumber, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  FirstMsgNumber = minNrSL(HBQ),
  ErrorMsgNumber = FirstMsgNumber - 1,
%%  Fehlermeldung für Lücke muss erzeugt werden
  if
    ErrorMsgNumber > LastDLQMsgNumber ->
      ErrorMsg = lists:concat(["***Fehlernachricht fuer Nachrichtennummern ", LastDLQMsgNumber + 1, " bis ", ErrorMsgNumber, " um ", timeMilliSecond()]),
      NewDLQ = pushSL(DLQ, {ErrorMsgNumber, ErrorMsg}),
      logging(Logfile, io_lib:format("~p Fehlernachricht mit ID: ~p eingefügt: ~p\n", [timeMilliSecond(), LastDLQMsgNumber, ErrorMsg])),
      transferToDLQ(HBQ, NewDLQ, FirstMsgNumber, ConfigDict, rekursive);
    ErrorMsgNumber =< LastDLQMsgNumber ->
      transferToDLQ(HBQ, DLQ, FirstMsgNumber, ConfigDict, rekursive)
  end
.

%% Rekursiv bis zur Lücke Elemente von der HBQ in die DLQ übertragen
transferToDLQ(HBQ, DLQ, Number, ConfigDict, rekursive) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  {TransferMsgNumber, TransferMsgText} = findSL(HBQ, Number),
  if
%%     Lücke gefunden
    TransferMsgNumber =:= -1 ->
      logging(Logfile, io_lib:format("~p Messages transfered from HBQ to DLQ, HBQ: ~p, DLQ: ~p \n", [timeMilliSecond(), HBQ, DLQ])),
      {HBQ, DLQ, Number - 1};
%%     Keine Lücke vorhanden
    TransferMsgNumber =:= Number ->
      NewDLQMsgText = TransferMsgText ++ "; DLQ In: " ++ timeMilliSecond(),
      NewDLQ = pushSL(DLQ, {TransferMsgNumber, NewDLQMsgText}),
      NewHBQ = popSL(HBQ),
%%       Prüfen ob DLQ Limit erreicht wurde, wenn ja erstes Element löschen
      DLQLimit = dict:fetch(dlqlimit, ConfigDict),
      FinalDLQ = checkDLQLength(NewDLQ, DLQLimit),
      transferToDLQ(NewHBQ, FinalDLQ, Number + 1, ConfigDict, rekursive)
  end
.

checkDLQLength(DLQ, Limit) ->
  DLQLength = length(DLQ),
  if
    DLQLength > Limit ->
      FinalDLQ = popSL(DLQ),
      checkDLQLength(FinalDLQ, Limit);
    DLQLength =< Limit ->
      FinalDLQ = DLQ
  end,
  FinalDLQ
.

sendDummyMessage() ->
  Message = "Aktuell keine neuen Nachrichten verfügbar",
  do
.
