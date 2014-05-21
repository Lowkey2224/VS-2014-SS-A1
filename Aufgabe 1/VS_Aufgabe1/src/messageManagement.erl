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
-export([messageService/3, stop/0, getNextMessageId/2]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, pushSL/2, findneSL/2, popSL/1, findSL/2, minNrSL/1, to_String/1, lengthSL/1]).

-define(MESSAGEPROCESSNAME, msgservice).

%------------------------------------------------------------------%
% Startet falls nicht schon geschehen den message Management Prozess %
% Leitet Anfrage an den Prozess weiter                             %
%------------------------------------------------------------------%
messageService(Order, Arguments, ConfigDict) ->
  %SingletonPattern
  Logfile = dict:fetch(logfile, ConfigDict),
  Known = erlang:whereis(?MESSAGEPROCESSNAME),
  case Known of
    undefined ->
      PIDmsgservice = erlang:spawn(fun() -> msgServiceLoop(ConfigDict, [], [], 0) end),
      erlang:register(?MESSAGEPROCESSNAME, PIDmsgservice),
      logging(Logfile, io_lib:format("~p Queue Service erfolgreich gestartet PID: ~p\n", [timeMilliSecond(), PIDmsgservice]));
    _NotUndef -> ok
  end,
  ?MESSAGEPROCESSNAME ! {Order, Arguments}
.
%-----------------------------------%
% Hauptschleife des message Prozesses %
%-----------------------------------%
msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  DLQLimit = dict:fetch(dlqlimit, ConfigDict),
  receive
    kill -> true;

    {query_messages, PID} ->
      logging(Logfile, io_lib:format("~p received get request from ~p \n", [werkzeug:timeMilliSecond(), PID])),
      communication:sendMessageToClient(PID, ConfigDict, DLQ),
      msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber);

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
          msgServiceLoop(ConfigDict, NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber);
%% Schwellwert nicht erreicht und Lücke vorhanden
        (HBQLength =< HalfDLQCapacity) ->
          msgServiceLoop(ConfigDict, NewHBQ, DLQ, LastDLQMsgNumber)
      end;

    {query_msgid, Pid} ->
	

    Any ->
      logging(Logfile, io_lib:format("~p received unknown order: ~p\n", [timeMilliSecond(), Any])),
      msgServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber)
  end
.

%---------------------------%
% Beendet den queue Prozess %
%---------------------------%
stop() ->
  Known = erlang:whereis(?MESSAGEPROCESSNAME),
  case Known of
    undefined -> false;
    _NotUndef -> ?MESSAGEPROCESSNAME ! kill, true
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

%--------------------------------------------------------------------%
% Sendet und berechnet die nächste freie Nachrichtenid an den Client %
% @return neue Nachrichten id                                        %
%--------------------------------------------------------------------%
sendmsgid(PID, Id) ->
  Message = {nnr, Id, Logfile},
  communication:sendMessage(PID, Message),
  werkzeug:logging(Logfile, io_lib:format("~p send new message id ~p to ~p", [werkzeug:timeMilliSecond(), Id, PID])),
  Id+1
.

