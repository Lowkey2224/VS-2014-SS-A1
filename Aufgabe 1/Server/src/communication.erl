%%%-------------------------------------------------------------------
%%% @author Leon
%%% @author Erwin Lang
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 13. Okt 2013 11:04
%%%-------------------------------------------------------------------
-module(communication).
-author("Leon Fausten").
-author("Erwin Lang").

%% API
-export([]).
%% API
-export([startServer/0, stopServer/0, sendMessage/2]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0]).

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
  {ok, ServerInitLifeTime} = get_config_value(serverinitlifetime, ConfList),
%% Add configurations to dictionary
  ConfigDict = dict:store(servername, Servername,
    dict:store(logfile, Logfile,
      dict:store(dlqlimit, DLQLimit,
        dict:store(clientlifetime, ClientLifeTime,
          dict:store(serverinitlifetime, ServerInitLifeTime, Cfg))))),

  %----------------------------%
  % Start server if not runnig %
  %----------------------------%
  Known = erlang:whereis(Servername),
  case Known of
    undefined ->
      Server = erlang:spawn(fun() -> initServer(ConfigDict) end),
      erlang:register(Servername, Server),
      logging(Logfile, io_lib:format("~p Server started successfully PID: ~p .\n", [timeMilliSecond(), Server])),
      Server;
    _NotUndef -> logging(Logfile, io_lib:format("~p Server is already running PID: ~p \n", [timeMilliSecond(), Known])),
      Known
  end
.


%--------------------------------------------------------%
% Startet die Serverschleife und den dazugehörigen Timer %
%--------------------------------------------------------%
initServer(ConfigDict) ->
  %% TODO: Timer Starten
%%   Lifetime = dict:fetch(serverinitlifetime, ConfigDict),
%%   {ok,ServerTimer} = timer:exit_after(Lifetime * 1000, self(), io:format("Server Timeout erreicht!\n")),
  communicationLoop(ConfigDict, 1)
.

%----------------------------------------------------------%
% Beendet den Server und falls gestartet auch die Prozesse %
% zur queue und Client verwaltung                          %
%----------------------------------------------------------%
stopServer() ->
  {ok, ConfigList} = file:consult(?CONFIGFILE),
  {ok, Servername} = get_config_value(servername, ConfigList),
  {ok, Logfile} = get_config_value(serverlogfile, ConfigList),
%  msgid:msgidstop(),
  clientManagement:stopClientManagement(),
  queueManagement:stop(),
  Known = erlang:whereis(Servername),
  case Known of
    undefined -> false;
    _NotUndef -> Servername ! kill,
      logging(Logfile, io_lib:format("~p Server stopped successfully\n", [timeMilliSecond()])),
      logstop(),
      true
  end
.

%----------------------------------------------------%
% Die eigentliche Serverschleife                     %
% Diese wird als einzelner Prozess gestartet         %
% Hier werden alle eingehenden Nachrichten empfangen %
%----------------------------------------------------%
communicationLoop(ConfigDict, MsgId) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  receive
    kill -> true;
    {query_messages, PID} -> queueManagement:queueService(query_messages, PID, ConfigDict),
      communicationLoop(ConfigDict, MsgId);
    {new_message, {Message, Number}} -> queueManagement:queueService(new_message, {Message, Number}, ConfigDict),
      communicationLoop(ConfigDict, MsgId);
    {query_msgid, PID} -> NewMsgId = queueManagement:queueService(query_msgid, PID, MsgId),
      communicationLoop(ConfigDict, NewMsgId);
    Any -> logging(Logfile, io_lib:format("~p received unknown command: ~p\n", [timeMilliSecond(), Any])),
      communicationLoop(ConfigDict, MsgId)
  end
.

%-------------------------------------------------%
% Eine Nachricht wird an ein Zielprozess gesendet %
%-------------------------------------------------%
sendMessage(Target, Message) ->
  Target ! Message
.