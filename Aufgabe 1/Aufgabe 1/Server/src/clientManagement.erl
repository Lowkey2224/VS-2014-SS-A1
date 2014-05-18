%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <acme>
%%% @doc
%%%
%%% @end
%%% Created : 15. May 2014 17:16
%%%-------------------------------------------------------------------
-module(clientManagement).
-author("loki").
-author("marilena").

%% API
-export([sendMessageToClient/3, stopClientManagement/0]).
-import(werkzeug, [logging/2, timeMilliSecond/0, maxNrSL/1, findneSL/2, minNrSL/1]).

-define(CLIENTPROCESSNAME, clientservice).

%-------------------------------------------------------------------------------------%
% Startet falls nicht schon geschehen den client Management Prozess                   %
% Anschließend wird er die Nachricht an den client Management Prozess weitergeleitet %
%-------------------------------------------------------------------------------------%
sendMessageToClient(PID, ConfigDict, DLQ) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  Known = erlang:whereis(?CLIENTPROCESSNAME),
  case Known of
    undefined ->
    %wenn keine INstanz vom CLientmngmt vorhanden
      PIDclientservice = erlang:spawn(fun() -> clientManagerloop(ConfigDict, dict:new()) end),  
      erlang:register(?CLIENTPROCESSNAME, PIDclientservice),
      logging(Logfile, io_lib:format("~p Client service started successfully PID: ~p\n", [timeMilliSecond(), PIDclientservice]));
    _NotUndef -> ok
  end,
  ?CLIENTPROCESSNAME ! {send_messages, PID, DLQ}
.

%----------------------------%
% Beendet den client Prozess %
%----------------------------%
stopClientManagement() ->
  ?CLIENTPROCESSNAME ! kill,
  true
.
%----------------------%
% Hauptclient Schleife %
%----------------------%
clientManagerloop(ConfigDict, ClientDict) ->
  receive
    kill -> true;
    {send_messages, PID, DLQ} ->
      NewClientDict = sendMessage(PID, ClientDict, DLQ, ConfigDict),
      clientManagerloop(ConfigDict, NewClientDict);
    {remove_client, PID} ->
      NewClientDict = removeClient(ClientDict, PID, ConfigDict),
      clientManagerloop(ConfigDict, NewClientDict)
  end
.

%------------------------------------------------------------------------------------%
% Sendet eine Nachricht an den Client                                                %
% Falls der Client noch nicht existiert wird er der Clientliste hinzugefügt          %
% Falls keine Nachrichten zum senden vorhanden sind wir eine Dummynachricht gesendet %
% @return neue Client Liste
%------------------------------------------------------------------------------------%
sendMessage(PID, ClientDict, DLQ, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  ClientLifetime = dict:fetch(clientlifetime, ConfigDict),
  ExistsClient = dict:is_key(PID, ClientDict),
  if
    ExistsClient ->
      {LastRequestedMessage, OldTimer} = dict:fetch(PID, ClientDict),
      NewClientDict = dict:erase(PID, ClientDict),
      timer:cancel(OldTimer),
      %Timer neu starten
      {ok, Timer} = timer:send_after(ClientLifetime, ?CLIENTPROCESSNAME, {remove_client, PID}),
      timer:start(),
      logging(Logfile, io_lib:format("~p Client ~p updated\n", [timeMilliSecond(), PID]));
    not ExistsClient ->
      LastRequestedMessage = -1,
      NewClientDict = ClientDict,
      %Timer starten
      {ok, Timer} = timer:send_after(ClientLifetime, ?CLIENTPROCESSNAME, {remove_client, PID}),
      %timer:start(),
      logging(Logfile, io_lib:format("~p Client ~p added\n", [timeMilliSecond(), PID]))
  end,
  NextMsgId = queueManagement:getNextMessageId(DLQ, LastRequestedMessage),
  if
  %Es sind keine neuen Nachrichten verfügbar
    NextMsgId =:= -1 ->
      FinalMsgId = LastRequestedMessage,
      sendDummyMessage(PID), %nicht leere Dummynachricht schicken, da keine nachrichten da
      logging(Logfile, io_lib:format("~p Dummynachricht an ~p gesendet\n", [timeMilliSecond(), PID]));
    NextMsgId =/= -1 ->
      {FinalMsgId, MsgText} = findneSL(DLQ, NextMsgId),
      Terminated = queueManagement:getNextMessageId(DLQ, NextMsgId) =:= -1,
      Message = {message, FinalMsgId, MsgText, Terminated},
      communication:sendMessage(PID, Message),
      logging(Logfile, io_lib:format("~p Die Nachricht #~p wurde an Client ~p gesendet: ~p\n", [timeMilliSecond(), FinalMsgId, PID, Message]))
  end,
  FinalClientDict = dict:store(PID, {FinalMsgId, Timer}, NewClientDict), %in NewClientDict den finalclinet schreiben
  logging(Logfile, io_lib:format("~p Aktuelle Clientlist: ~p\n", [timeMilliSecond(), FinalClientDict])),
  FinalClientDict

.

%----------------------------------------------------------------------------------%
% Sendet die Dummynachricht wenn keine neuen Nachrichten zum senden vorhanden sind %
%----------------------------------------------------------------------------------%
sendDummyMessage(PID) ->
  Message = {message, 0, "Keine neuen Nachrichten vorhanden", true},
  communication:sendMessage(PID, Message)
.

removeClient(ClientDict, PID, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  logging(Logfile, io_lib:format("~p Client ~p wurde entfernt\n", [timeMilliSecond(), PID])),
  dict:erase(PID, ClientDict)
.