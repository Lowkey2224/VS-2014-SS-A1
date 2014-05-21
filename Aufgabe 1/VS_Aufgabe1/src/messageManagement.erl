%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. May 2014 16:31
%%%-------------------------------------------------------------------
-module(messageManagement).
-author("loki").
-author("marilena").

%% API
-export([messageService/3,messageService/1, stop/1, getNextMessageId/2]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, pushSL/2, findneSL/2, popSL/1, findSL/2, minNrSL/1, to_String/1, lengthSL/1]).

%------------------------------------------------------------------%
% Startet falls nicht schon geschehen den message Management Prozess %
% Leitet Anfrage an den Prozess weiter                             %
%------------------------------------------------------------------%
messageService(Order, Arguments, ConfigDict) ->
  %SingletonPattern
  Logfile = dict:fetch(logfile, ConfigDict),
ServiceName = dict:fetch((servicename, ConfigDict),
  Known = erlang:whereis(ServiceName),
  case Known of
    undefined ->
      PIDmsgservice = erlang:spawn(fun() -> msgServiceLoop(ConfigDict, [], [], 0, 1) end),
      erlang:register(ServiceName, PIDmsgservice),
      logging(Logfile, io_lib:format("~p Queue Service erfolgreich gestartet PID: ~p\n", [timeMilliSecond(), PIDmsgservice]));
    _NotUndef -> ok
  end,
  ServiceName ! {Order, Arguments}
;

messageService(ConfigDict) ->
Logfile = dict:fetch(logfile, ConfigDict),
ServiceName = dict:fetch((servicename, ConfigDict),
  Known = erlang:whereis(ServiceName),
  case Known of
    undefined ->
      PIDmsgservice = erlang:spawn(fun() -> msgServiceLoop(ConfigDict, [], [], 0, 1) end),
      erlang:register(ServiceName, PIDmsgservice),
      logging(Logfile, io_lib:format("~p Queue Service erfolgreich gestartet PID: ~p\n", [timeMilliSecond(), PIDmsgservice]));
    _NotUndef -> ok
  end
.
%-----------------------------------%
% Hauptschleife des message Prozesses %
%-----------------------------------%
msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, MaxMsgId) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  DLQLimit = dict:fetch(dlqlimit, ConfigDict),
  receive
    kill -> true;

    {query_messages, PID} ->
      logging(Logfile, io_lib:format("~p received query request from ~p \n", [werkzeug:timeMilliSecond(), PID])),
      sendMessageToClient(PID, ConfigDict, DLQ),
      msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, MaxMsgId);

    {new_message, {Message, Number}} ->
      NewMessage = Message ++ "; HBQ In: " ++ werkzeug:timeMilliSecond(),
      NewHBQ = werkzeug:pushSL(HBQ, {Number, NewMessage}),
      werkzeug:logging(Logfile, io_lib:format("~p received new message request, Message: ~p, Number: ~p, HBQ: ~p \n", [werkzeug:timeMilliSecond(), Message, Number, NewHBQ])),

      HBQLength = length(NewHBQ),
      HalfDLQCapacity = DLQLimit / 2,
      if
%%  In DLQ übertragen wenn  anz(HBQ)> Kap (DLQ)/2 ODER wenn keine Lücke zwischen Nachricht und DLQ vorhanden ist.
        ((HBQLength > HalfDLQCapacity) or (LastDLQMsgNumber + 1 =:= Number)) ->
          {NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber} = transferToDLQ(NewHBQ, DLQ, LastDLQMsgNumber, ConfigDict),
          msgServiceLoop(ConfigDict, NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber, MaxMsgId);
%% Schwellwert nicht erreicht und Lücke vorhanden
        (HBQLength =< HalfDLQCapacity) ->
          msgServiceLoop(ConfigDict, NewHBQ, DLQ, LastDLQMsgNumber, MaxMsgId)
      end;

    {query_msgid, Pid} ->
	Pid ! {msgid, MaxMsgId},
	werkzeug:logging(Logfile, io_lib:format("~p send new message id ~p to ~p", [werkzeug:timeMilliSecond(), Id, PID])),
	msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, MaxMsgId+1);

    Any ->
      logging(Logfile, io_lib:format("~p received unknown order: ~p\n", [timeMilliSecond(), Any])),
      msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, MaxMsgId)
  end
.

%---------------------------%
% Beendet den queue Prozess %
%---------------------------%
stop(ConfigDict) ->
ServiceName = dict:fetch((servicename, ConfigDict),
  Known = erlang:whereis(ServiceName),
  case Known of
    undefined -> false;
    _NotUndef -> ServiceName! kill, true
  end
.

%--------------------------------------------------------------------------%
% Ruft die rekursive Übertragung in die DLQ auf,                           %
% vor der Übertragung wird überprüft ob eine Lücke vorhanden ist falls ja  %
% wird eine Fehlernachricht generiert                                      %
%--------------------------------------------------------------------------%
transferToDLQ(HBQ, DLQ, LastDLQMsgNumber, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  FirstMsgNumber = werkzeug:minNrSL(HBQ), %kleinste nummer aus HBQ
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
%----------------------------------------------------------------------------------------------%
% Transferiert rekursive Nachrichten bis zur ersten Lücke in der HBQ in die DLQ,               %
% Nach der Übertragung wird die Länge der DLQ überprüft und im Notfall erste Elemente gelöscht %
%----------------------------------------------------------------------------------------------%
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
      FinalDLQ = trimToLimit(NewDLQ, DLQLimit),
      transferToDLQ(NewHBQ, FinalDLQ, Number + 1, ConfigDict, rekursive)
  end
.

%--------------------------------------------%
% Check length of DLQ, remove first messages %
% Gibt neue DLQ zurück                       %
%--------------------------------------------%
trimToLimit(DLQ, Limit) ->
  DLQLength = werkzeug:length(DLQ),
  if
    DLQLength > Limit ->
      FinalDLQ = werkzeug:popSL(DLQ),
      trimToLimit(FinalDLQ, Limit);
    DLQLength =< Limit ->
      FinalDLQ = DLQ
  end,
  FinalDLQ
.

%-----------------------------------------------------------------%
% Gibt die nächste Nachrichtenid aus der Deliveryueue zurück,     %
% falls keine neue Nachricht existiert wird -1 zurück gegeben     %
% @return nächste Nachrichtenid der DLQ, -1 falls keine vorhanden %
% ----------------------------------------------------------------%
getNextMessageId(DLQ, ActualNumber) ->
  NextNumber = ActualNumber + 1,
  DLQmin = werkzeug:minNrSL(DLQ),
  if
    DLQmin =:= -1 ->  %prüfen, ob nciht leer
      NN = -1;
    NextNumber =< DLQmin ->  %falls es eine gibt
      NN = DLQmin;
    NextNumber > DLQmin ->
      {NN, _} = werkzeug:findneSL(DLQ, NextNumber)
  end,
  NN
.

%-------------------------------------------------------------------------------------------%
% Neu eingefügt zur Entkopplung: Verwendet das messagemanagement und clientmanagement um eine %
% Nachricht an den Client PID zu senden                                                     %
%-------------------------------------------------------------------------------------------%
sendMessageToClient(PID, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),

  logging(Logfile, io_lib:format("~p queryMessages erhalten von ~p \n", [werkzeug:timeMilliSecond(), PID])),
  {ok, ClientManagement} = clientManagement:start(ConfigDict, self()),
  ClientManagement ! {get_last_msgid, PID},
  receive
    kill -> true;
    {reply, last_msgid, LastMsgId} ->
      messageManagement:messageService(query_messages, {LastMsgId} ,ConfigDict, self()),
      receive
        kill -> true;
        {reply, nextmsg, Message} ->
          sendMessage(PID, Message),
          {message, NewMsgId, _, _} = Message,
          logging(Logfile, io_lib:format("~p Nachricht wurde an Client ~p gesendet: ~p\n", [timeMilliSecond(), PID, Message])),
          ClientManagement ! {update_last_msgid_restart_timer, PID, NewMsgId}
        end
      end
  .