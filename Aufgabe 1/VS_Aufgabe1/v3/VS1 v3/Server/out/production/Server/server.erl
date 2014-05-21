%%%-------------------------------------------------------------------
%%% @author Leon
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Okt 2013 18:36
%%%-------------------------------------------------------------------
-module(server).
-author("Leon").


%% API
-export([start/0, stop/0]).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0]).

-define(CONFIGFILE, "server.cfg").


%% Startet den Server
start() ->
  %Load Configs
  Cfg = dict:new(),
  {ok, ConfList} = file:consult(?CONFIGFILE),
  {ok, Servername} = get_config_value(servername, ConfList),
  {ok, Logfile} = get_config_value(serverlogfile, ConfList),
  {ok, DLQLimit} = get_config_value(dlqlimit, ConfList),
  {ok, ClientLifeTime} = get_config_value(clientlifetime, ConfList),
%% Add configurations to dictionary
  ConfigDict = dict:store(servername, Servername,
    dict:store(logfile, Logfile,
      dict:store(dlqlimit, DLQLimit,
        dict:store(clientlifetime, ClientLifeTime, Cfg)))),

%% Start server if not runnig
  Known = erlang:whereis(Servername),
  case Known of
    undefined ->
      Server = erlang:spawn(fun() -> initserver(ConfigDict, dict:new()) end),
      erlang:register(Servername, Server),
      logging(Logfile, io_lib:format("~p Server started successfully PID: ~p .\n", [timeMilliSecond(), Server]));
    _NotUndef -> logging(Logfile, io_lib:format("~p Server is already running PID: ~p \n", [timeMilliSecond(), Known]))
  end
.

initserver(ConfigDict, ClientDict) ->
  %% TODO: Timer Starten
  serverloop(ConfigDict, ClientDict, 1)
.

%% Stopt den Server und alle Unterprozesse
stop() ->
  {ok, ConfigList} = file:consult(?CONFIGFILE),
  {ok, Servername} = get_config_value(servername, ConfigList),
  {ok, Logfile} = get_config_value(serverlogfile, ConfigList),
%  msgid:msgidstop(),
  queueAdministration:stop(),
  Known = erlang:whereis(Servername),
  case Known of
    undefined -> false;
    _NotUndef -> Servername ! kill,
      logging(Logfile, io_lib:format("~p Server stopped successfully", [timeMilliSecond()])),
      logstop(),
      true
  end
.

%---------------Server--------------------------------
%% Serverschleife, die auf Anfragen wartet
serverloop(ConfigDict, ClientDict, MsgId) ->
  Logfile = dict:fetch(logfile, ConfigDict),
  receive
    kill -> true;
    {getmessages, PID} -> queueAdministration:queueService(getmessages, PID, ConfigDict, ClientDict),
      serverloop(ConfigDict, ClientDict, MsgId);
    {dropmessage, {Message, Number}} -> queueAdministration:queueService(dropmessage, {Message, Number}, ConfigDict, ClientDict),
      serverloop(ConfigDict, ClientDict, MsgId);
    {getmsgid, PID} -> msgid:sendmsgid(PID, MsgId),
      serverloop(ConfigDict, ClientDict, MsgId + 1);
    Any -> logging(Logfile, io_lib:format("~p received unknown command: ~p\n", [timeMilliSecond(), Any])),
      serverloop(ConfigDict, ClientDict, MsgId)
  end
.
