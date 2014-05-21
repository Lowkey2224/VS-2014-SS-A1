%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. May 2014 14:56
%%%-------------------------------------------------------------------
-module(msgidManagement).
-author("Leon Fausten").
-author("Erwin Lang").

%% API
-export([sendmsgid/2]).
-import(werkzeug, [timeMilliSecond/0, logging/2]).

-define(LOGFILE, "server.log").
-define(MSGIDPROCESSNAME, msgidservice).

%--------------------------------------------------------------------%
% Sendet und berechnet die nächste freie Nachrichtenid an den Client %
% @return neue Nachrichten id                                        %
%--------------------------------------------------------------------%
sendmsgid(PID, Id) ->
  Message = {nid, Id},
  communication:sendMessage(PID, Message),
  logging(?LOGFILE, io_lib:format("~p sende neue MessageId ~p an ~p\n", [timeMilliSecond(), Id, PID])),
  Id+1
.