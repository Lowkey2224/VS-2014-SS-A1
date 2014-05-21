%%%-------------------------------------------------------------------
%%% @author Leon Fausten
%%% @author Erwin Lang
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Okt 2013 16:31
%%%-------------------------------------------------------------------
-module(queueManagement).
-author("Leon Fausten").
-author("Erwin Lang").

%% API
-export([queueService/4, stop/0, getNextMessageId/2]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, pushSL/2, findneSL/2, popSL/1, findSL/2, minNrSL/1, to_String/1, lengthSL/1]).

-define(QUEUEPROCESSNAME, queueservice).

%------------------------------------------------------------------%
% Startet falls nicht schon geschehen den queue Management Prozess %
% Leitet Anfrage an den Prozess weiter                             %
%------------------------------------------------------------------%
queueService(Order, Arguments, ConfigDict, CommunicationProzessName) ->
  %Prozesskontrolle: Wird erst erzeugt, wenn benötigt
  Logfile = dict:fetch(logfile, ConfigDict),
  Known = erlang:whereis(?QUEUEPROCESSNAME),
  case Known of
    undefined ->
      PIDqueueservice = erlang:spawn(fun() -> queueServiceLoop(ConfigDict, [], [], 0, CommunicationProzessName) end),
      erlang:register(?QUEUEPROCESSNAME, PIDqueueservice),
      logging(Logfile, io_lib:format("~p Queue Service erfolgreich gestartet PID: ~p\n", [timeMilliSecond(), PIDqueueservice]));
    _NotUndef -> ok
  end,
  ?QUEUEPROCESSNAME ! {Order, Arguments}
.
%-----------------------------------%
% Hauptschleife des queue Prozesses %
%-----------------------------------%
queueServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, Communication) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  DLQLimit = dict:fetch(dlqlimit, ConfigDict),
  receive
    kill -> true;
    %message wird in HBQ getan und DLQ wird upgedated
    {dropmessage, {Message, Number}} ->
      NewMessage = Message ++ "; HBQ In: " ++ timeMilliSecond(),
      NewHBQ = pushSL(HBQ, {Number, NewMessage}),
      logging(Logfile, io_lib:format("~p dropMessage erhalten, Message: ~p, Number: ~p\n", [timeMilliSecond(), Message, Number])),

      HBQLength = length(NewHBQ),
      HalfDLQCapacity = DLQLimit / 2,
      if
%%  In DLQ übertragen wenn  anz(HBQ)> Kap (DLQ)/2 ODER wenn keine Lücke zwischen Nachricht und DLQ vorhanden ist.
        ((HBQLength > HalfDLQCapacity) or (LastDLQMsgNumber + 1 =:= Number)) ->
          {NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber} = transferToDLQ(NewHBQ, DLQ, LastDLQMsgNumber, ConfigDict),
          queueServiceLoop(ConfigDict, NewHBQafterTransfer, NewDLQ, NewLastDLQMsgNumber, Communication);
%% Schwellwert nicht erreicht und Lücke vorhanden
        (HBQLength =< HalfDLQCapacity) ->
          queueServiceLoop(ConfigDict, NewHBQ, DLQ, LastDLQMsgNumber, Communication)
      end;
    % message mit der msgid Number wird gelesen
    {getmessage, {Number}} ->
        NextMsgId = getNextMessageId(DLQ, Number),

        if NextMsgId =/= -1 ->
          {FinalMsgId, MsgText} = findneSL(DLQ, NextMsgId),
          Terminated = getNextMessageId(DLQ, NextMsgId) =:= -1,
          Message = {reply, FinalMsgId, MsgText, Terminated};
        NextMsgId =:= -1 ->
          Message = {reply, 0, "Keine Nachrichten zum senden verfügbar", true}
        end,
        Communication ! {reply, nextmsg, Message},
        queueServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, Communication);
    Any ->
      logging(Logfile, io_lib:format("~p Unbekannte Aufforderung erhalten: ~p\n", [timeMilliSecond(), Any])),
      queueServiceLoop(ConfigDict, HBQ, DLQ, LastDLQMsgNumber, Communication)
  end
.

%---------------------------%
% Beendet den queue Prozess %
%---------------------------%
stop() ->
  Known = erlang:whereis(?QUEUEPROCESSNAME),
  case Known of
    undefined -> false;
    _NotUndef -> ?QUEUEPROCESSNAME ! kill, true
  end
.

%--------------------------------------------------------------------------%
% Ruft die rekursive Übertragung in die DLQ auf,                           %
% vor der Übertragung wird überprüft ob eine Lücke vorhanden ist falls ja  %
% wird eine Fehlernachricht generiert                                      %
%--------------------------------------------------------------------------%
transferToDLQ(HBQ, DLQ, LastDLQMsgNumber, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  FirstMsgNumber = minNrSL(HBQ),
  ErrorMsgNumber = FirstMsgNumber - 1,
%%  Fehlermeldung für Lücke muss erzeugt werden
  if
    ErrorMsgNumber > LastDLQMsgNumber ->
      ErrorMsg = lists:concat(["***Fehlernachricht fuer Nachrichtennummern ", LastDLQMsgNumber + 1, " bis ", ErrorMsgNumber, " um ", timeMilliSecond()]),
      %% In der DLQ Platz für eine Nachricht schaffen
      DLQLimit = dict:fetch(dlqlimit, ConfigDict),
      NewDLQ = checkDLQLength(DLQ, DLQLimit-1),
      FinalDLQ = pushSL(NewDLQ, {ErrorMsgNumber, ErrorMsg}),
      logging(Logfile, io_lib:format("~p Fehlernachricht mit ID: ~p eingefügt: ~p\n", [timeMilliSecond(), LastDLQMsgNumber, ErrorMsg])),
      transferToDLQ(HBQ, FinalDLQ, FirstMsgNumber, ConfigDict, rekursive);
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
      logging(Logfile, io_lib:format("~p Nachricht übertragen von HBQ zu DLQ, MsgId: ~p \n", [timeMilliSecond(), Number])),
      {HBQ, DLQ, Number - 1};
%%     Keine Lücke vorhanden
    TransferMsgNumber =:= Number ->
      %% In der DLQ Platz für eine Nachricht schaffen
      DLQLimit = dict:fetch(dlqlimit, ConfigDict),
      NewDLQ = checkDLQLength(DLQ, DLQLimit-1),
      NewDLQMsgText = TransferMsgText ++ "; DLQ In: " ++ timeMilliSecond(),
      FinalDLQ = pushSL(NewDLQ, {TransferMsgNumber, NewDLQMsgText}),
      NewHBQ = popSL(HBQ),

      transferToDLQ(NewHBQ, FinalDLQ, Number + 1, ConfigDict, rekursive)
  end
.

%--------------------------------------------%
% Check length of DLQ, remove first messages %
% Gibt neue DLQ zurück                       %
%--------------------------------------------%
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

%-----------------------------------------------------------------%
% Gibt die nächste Nachrichtenid aus der Deliveryueue zurück,     %
% falls keine neue Nachricht existiert wird -1 zurück gegeben     %
% @return nöchste Nachrichtenid der DLQ, -1 falls keine vorhanden %
% ----------------------------------------------------------------%
getNextMessageId(DLQ, ActualNumber) ->
  NextNumber = ActualNumber + 1,
  DLQmin = minNrSL(DLQ),
  if
    DLQmin =:= -1 ->
      NN = -1;
    NextNumber =< DLQmin ->
      NN = DLQmin;
    NextNumber > DLQmin ->
      {NN, _} = findneSL(DLQ, NextNumber)
  end,
  NN
.

