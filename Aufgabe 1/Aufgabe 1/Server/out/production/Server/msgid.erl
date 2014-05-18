%%%-------------------------------------------------------------------
%%% @author Leon
%%% @copyright (C) 2013, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Okt 2013 12:52
%%%-------------------------------------------------------------------
-module(msgid).
-author("Leon").

%% API
-export([sendmsgid/2]).
-import(werkzeug, [timeMilliSecond/0, logging/2]).

-define(LOGFILE, "mgsid.log").
-define(MSGIDPROCESSNAME, msgidservice).


sendmsgid(PID, Id) ->
  Message = {nnr, Id},
  communication:sendMessage(PID, Message),
  logging(?LOGFILE, io_lib:format("~p send new message id ~p to ~p", [timeMilliSecond(), Id, PID])),
  Id+1
.
%% %----------Message Id Service--------------------
%% %% Liefert eindeutige Nachrichtenummer zurück
%% getnewid(PID) ->
%%   %Prozesskontrolle: Wird erst erzeugt, wenn benötigt
%%   Known = erlang:whereis(?MSGIDPROCESSNAME),
%%   case Known of
%%     undefined ->
%%       PIDmsgidservice = erlang:spawn(fun() -> msgIdServiceLoop(1) end),
%%       erlang:register(?MSGIDPROCESSNAME, PIDmsgidservice),
%%       werkzeug:logging(?LOGFILE, io_lib:format("~p Message Id Service wurde erfolgreich gestartet PID: ~p \n" ,[werkzeug:timeMilliSecond(), PIDmsgidservice]));
%%     _NotUndef -> ok
%%   end,
%%   ?MSGIDPROCESSNAME ! PID
%% .
%%
%% msgIdServiceLoop(MsgId) ->
%%   receive
%%     kill -> true;
%%     PID -> PID ! {nid, MsgId},
%%       werkzeug:logging(?LOGFILE, io_lib:format("~p requestet new message id from ~p, New ID: ~p \n", [werkzeug:timeMilliSecond(), PID, MsgId])),
%%       msgIdServiceLoop(MsgId+1)
%%   end
%% .
%%
%% msgidstop()->
%%   Known = erlang:whereis(?MSGIDPROCESSNAME),
%%   case Known of
%%     undefined -> false;
%%     _NotUndef -> ?MSGIDPROCESSNAME ! kill, true
%%   end
%% .