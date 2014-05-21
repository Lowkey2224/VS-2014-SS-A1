%%%-------------------------------------------------------------------
%%% @author Loki
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Okt 2013 15:03
%%%-------------------------------------------------------------------
-module(serverStarter).
-author("Loki").

%% API
-export([compilefiles/0]).
-define(CMPATH, "").
-define(SRVPATH, "").

compilefiles() ->
  c:c(?SRVPATH ++ communication),
  c:c(?SRVPATH ++ clientManagement),
  c:c(?SRVPATH ++ messageManagement),
  c:c(?SRVPATH ++ werkzeug),
  c:c(?CMPATH ++ client),
  c:c(?CMPATH ++ clientCreation).
