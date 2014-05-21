%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. May 2014 14:56
%%%-------------------------------------------------------------------
-module(clientManagement).
-author("Leon Fausten").
-author("Erwin Lang").

%% API
-export([start/2, stop/0]).
-import(werkzeug, [logging/2, timeMilliSecond/0, maxNrSL/1, findneSL/2, minNrSL/1]).

-define(CLIENTPROCESSNAME, clientservice).
-record(clients, {name = "", list = []}).

%------------------------------------------------------------------%
% Startet falls nicht schon geschehen den clientManagement Prozess %
%------------------------------------------------------------------%
start(ConfigDict, CommunicationProzessName) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  Known = erlang:whereis(?CLIENTPROCESSNAME),
  #clients{name = "clientlist", list = []},
  case Known of
    undefined ->
      PIDclientservice = erlang:spawn(fun() -> clientManagerloop([], ConfigDict, CommunicationProzessName) end),
      erlang:register(?CLIENTPROCESSNAME, PIDclientservice),
      logging(Logfile, io_lib:format("~p Client service erfolgreich gestartet mit PID: ~p\n", [timeMilliSecond(), PIDclientservice]));
    _NotUndef -> ok
  end,
  {ok, ?CLIENTPROCESSNAME}
.


%----------------------------%
% Beendet den client Prozess %
%----------------------------%
stop() ->
  Known = erlang:whereis(?CLIENTPROCESSNAME),
  case Known of
    undefined -> false;
    _NotUndef -> ?CLIENTPROCESSNAME ! kill
  end
.

%------------------------------------%
% Hauptschleife des ClientManagement %
%------------------------------------%
clientManagerloop(ClientList, ConfigDict, Communication) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  receive
    kill -> true;

    {get_last_msgid, PID} ->
      LastMsgId = getLastMsgid(PID, ClientList),
      Communication ! {reply, last_msgid, LastMsgId},
      clientManagerloop(ClientList, ConfigDict, Communication);

    {update_last_msgid_restart_timer, PID, ID} ->
      NewClientList = updateOrCreateClient(PID, ID, ConfigDict, ClientList),
      clientManagerloop(NewClientList, ConfigDict, Communication);

    {remove_client, PID} ->
      NewClientList = removeClient(PID, ConfigDict, ClientList),
      clientManagerloop(NewClientList, ConfigDict, Communication);


    Any ->
      logging(Logfile, io_lib:format("~p Client Management: Unbekante Nachricht eingetroffen: ~p \n", [timeMilliSecond(), Any]))

  end
.

%-----------------------------------------------------------%
% Entfernt den Client mit der ClientPID aus der Clientliste %
%-----------------------------------------------------------%
removeClient(ClientPID, ConfigDict, ClientList) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  Client = lists:keyfind(ClientPID, 1, ClientList),
  NewClientList = lists:delete(Client, ClientList),
  logging(Logfile, io_lib:format("Client gelöscht ~p \n", [ClientPID])),
  NewClientList
.

%--------------------------------------------------------------------------------%
% Erstellt einen Client oder updatet einen bestehenden mit einer neuen LastMsgId %
%--------------------------------------------------------------------------------%
updateOrCreateClient(ClientPID, LastMessageID, ConfigDict, ClientList) ->
  ClientLifeTime = dict:fetch(clientlifetime, ConfigDict),
  Logfile = dict:fetch(logfile, ConfigDict),
  Client = lists:keyfind(ClientPID, 1, ClientList),
  {ok, Timer} = timer:send_after(ClientLifeTime, ?CLIENTPROCESSNAME, {remove_client, ClientPID}),
  if
    Client =/= false ->
      {_, _, OldTimer} = Client,
      {ok, cancel} = timer:cancel(OldTimer); %cancel old timer
    true -> ok
  end,
  NewClient = {ClientPID, LastMessageID, Timer},
  NewClientList = lists:keystore(ClientPID, 1, ClientList, NewClient),        %create or replace client tuple in list
  logging(Logfile, io_lib:format("ClientListe aktuallisiet, updated Client ~p \n", [ClientPID])),
  NewClientList
.

%--------------------------------------------------------------------------------%
% Gibt die MsgId für die zuletzt erhaltenen Nachricht eines Clients zurück       %
%--------------------------------------------------------------------------------%
getLastMsgid(PID, ClientList) ->
  Client = lists:keyfind(PID, 1, ClientList),
  if
    Client =:= false ->
      LastRequestedMessage = -1;
    Client =/= false ->
      {_, LastRequestedMessage, _} = Client
  end,
  LastRequestedMessage
.