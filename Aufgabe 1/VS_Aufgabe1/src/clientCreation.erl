%%%-------------------------------------------------------------------
%%% @author Leon
%%% @author Erwin
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. Okt 2013 14:56
%%%-------------------------------------------------------------------
-module(clientCreation).
-import(werkzeug, [get_config_value/2]).
-import(client, [clientStart/4]).

%% API
-export([start/2]).

%-------------------------------------------------------------------------------------%
% Einstiegsfunktion für die Clients                                                   %
% Liest die Configdatei client.cfg ein und stösst die Erstellung der Clients an       %
%-------------------------------------------------------------------------------------%
start(Host, Address) ->
  {ok, Config} = file:consult("client.cfg"),
  {ok, Amount} = get_config_value(clients, Config),
  createClients(Host, Address, Amount, Config).


%-------------------------------------------------------------------------------------%
% Erzeugt die Clients als eigene Prozesse                                             %
% Die Anzahl der Clients entspricht dem Parameter Amount                              %
%-------------------------------------------------------------------------------------%
createClients(Host, Address, Amount, Config) when Amount > 0 ->
  ClientName = list_to_atom((lists:concat(["client", Amount, "@", Address]))),

  Pid = whereis(ClientName),
  if Pid == undefined ->
    ClientPid = spawn(fun() -> client:clientStart(Host, Address, Config, Amount) end),
    register(ClientName, ClientPid),
    createClients(Host, Address, Amount - 1, Config);
  true -> clientStillRunning
  end;
createClients(_, _, _, _) -> done.



