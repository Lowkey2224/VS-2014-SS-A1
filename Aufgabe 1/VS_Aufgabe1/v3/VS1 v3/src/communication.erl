%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. May 2014 14:56
%%%-------------------------------------------------------------------
-module(communication).
-author("loki").
-author("marilena").

%% API
-export([startServer/0, stopServer/0, sendMessage/2]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, to_String/1]).

-define(CONFIGFILE, "server.cfg").


%-----------------------------------------------------------------------%
% Der Server wird gestartet                                             %
% Die notwendige Konfiguration wird aus der Konfigurationsdatei geladen %
% Falls der Server schon läuft wird er nicht erneut gestartet           %
% @return PID                                                           %
%-----------------------------------------------------------------------%
startServer() ->
  %--------------------%
  % Load Configuration %
  %--------------------%
  Cfg = dict:new(),
  {ok, ConfList} = file:consult(?CONFIGFILE),
  {ok, Servername} = get_config_value(servername, ConfList),
  {ok, Logfile} = get_config_value(serverlogfile, ConfList),
  {ok, DLQLimit} = get_config_value(dlqlimit, ConfList),
  {ok, ClientLifeTime} = get_config_value(clientlifetime, ConfList),
  {ok, ServerLifeTime} = get_config_value(serverlifetime, ConfList),
%% Add configurations to dictionary
  ConfigDict = dict:store(servername, Servername,
    dict:store(logfile, Logfile,
      dict:store(dlqlimit, DLQLimit,
        dict:store(clientlifetime, ClientLifeTime * 1000,
          dict:store(serverlifetime, ServerLifeTime * 1000,Cfg))))),

  %----------------------------%
  % Start server if not runnig %
  %----------------------------%
  Known = global:whereis_name(Servername),
  case Known of
    undefined ->
      Server = erlang:spawn(fun() -> initServer(ConfigDict) end),
      global:register_name(Servername, Server),
      logging(Logfile, io_lib:format("~p Server erfolgreich gestartet mit PID: ~p .\n", [timeMilliSecond(), Server])),
      Server;
    _NotUndef -> logging(Logfile, io_lib:format("~p Server läuft bereits mit PID: ~p \n", [timeMilliSecond(), to_String(Known)])),
      Known
  end
.


%--------------------------------------------------------%
% Startet die Serverschleife und den dazugehörigen Timer %
%--------------------------------------------------------%
initServer(ConfigDict) ->
  Lifetime = dict:fetch(serverlifetime, ConfigDict),
  {ok, ServerTimer} = timer:apply_after(Lifetime, communication, stopServer, []),

  communicationLoop(ConfigDict, 1, ServerTimer)
.

%----------------------------------------------------------%
% Beendet den Server und falls gestartet auch die Prozesse %
% zur queue und Client verwaltung                          %
%----------------------------------------------------------%
stopServer() ->
  {ok, ConfigList} = file:consult(?CONFIGFILE),
  {ok, Servername} = get_config_value(servername, ConfigList),
  {ok, Logfile} = get_config_value(serverlogfile, ConfigList),
  clientManagement:stop(),
  queueManagement:stop(),
  Known = global:whereis_name(Servername),
  logging(Logfile, io_lib:format("~p Server: ~p \n", [timeMilliSecond(), to_String(Known)])),
  case Known of
    undefined -> false;
	 
    	_Else -> Known ! kill,
      logging(Logfile, io_lib:format("~p Server erfolgreich gestoppt \n", [timeMilliSecond()]))
  end,
  logstop()
.

%----------------------------------------------------%
% Die eigentliche Serverschleife                     %
% Diese wird als einzelner Prozess gestartet         %
% Hier werden alle eingehenden Nachrichten empfangen %
%----------------------------------------------------%
communicationLoop(ConfigDict, MsgId, ServerTimer) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  receive
    kill -> true;
    {query_messages, PID} -> sendMessageToClient(PID, ConfigDict),
      Timer = restartTimer(ServerTimer, ConfigDict),
      communicationLoop(ConfigDict, MsgId, Timer);

    {new_message, {Message, Number}} ->
      queueManagement:queueService(new_message, {Message, Number}, ConfigDict, self()),
      Timer = restartTimer(ServerTimer, ConfigDict),
      communicationLoop(ConfigDict, MsgId, Timer);

    {query_msgid, PID} -> NewMsgId = msgidManagement:sendmsgid(PID, MsgId),
      Timer = restartTimer(ServerTimer, ConfigDict),
      communicationLoop(ConfigDict, NewMsgId, Timer);
    Any -> logging(Logfile, io_lib:format("~p Unbekannte Anforderung erhalten: ~p\n", [timeMilliSecond(), Any])),
      Timer = restartTimer(ServerTimer, ConfigDict),
      communicationLoop(ConfigDict, MsgId, Timer)
  end

.
%-------------------------------------------------------------------------------------------%
% Neu eingefügt zur Entkopplung: Verwendet das queuemanagement und clientmanagement um eine %
% Nachricht an den Client PID zu senden                                                     %
%-------------------------------------------------------------------------------------------%
sendMessageToClient(PID, ConfigDict) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  logging(Logfile, io_lib:format("~p query_messages erhalten von ~p \n", [werkzeug:timeMilliSecond(), PID])),
  {ok, ClientManagement} = clientManagement:start(ConfigDict, self()),
  ClientManagement ! {get_last_msgid, PID},
  receive
    kill -> true;
    {reply, last_msgid, LastMsgId} ->
      queueManagement:queueService(query_msgid, {LastMsgId} ,ConfigDict, self()),
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

%---------------------------------------------------%
% Startet den Timer für die Serverlebenszeit neu    %
%---------------------------------------------------%
restartTimer(TimerRef, ConfigDict) ->
  {ok, cancel} = timer:cancel(TimerRef),
  ServerLifetime = dict:fetch(serverlifetime, ConfigDict),
  {ok, NewTimer} = timer:apply_after(ServerLifetime, communication, stopServer, []),
  NewTimer
.

%---------------------------------------------------%
% Eine Nachricht wird an einen Zielprozess gesendet %
%---------------------------------------------------%
sendMessage(Target, Message) ->
  Target ! Message
.