%%%-------------------------------------------------------------------
%%% @author Leon
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Okt 2013 17:16
%%%-------------------------------------------------------------------
-module(clientAdministration).
-author("Leon").

%% API
-export([getClientData/3]).
-import(werkzeug, [logging/2]).

getClientData(PID, ConfigDict, ClientDict) ->
  ClientLifetime = dict:fetch(clientlifetime, ConfigDict),
  Logfile = dict:fetch(logfile, ConfigDict),
  ClientExists = dict:is_key(PID, ClientDict),
  if
    ClientExists ->
      {LastRequestedMessage, ClientTimer} = dict:fetch(PID, ClientDict),
      logging(Logfile, io_lib:format("Client Timer aktuallisiert: ~p\n", [PID])),
      NewClientDict = ClientDict;
    not ClientExists ->
      NewClientDict = dict:store(PID, {2, abc}, ClientDict),
      logging(Logfile, io_lib:format("Client hinzugefügt: ~p\n", [PID]))

  end,
  io:format("~p\n", [NewClientDict]),
  {PID, 2, NewClientDict}.


