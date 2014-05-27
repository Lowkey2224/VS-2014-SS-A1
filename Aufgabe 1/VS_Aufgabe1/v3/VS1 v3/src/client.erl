%%%-------------------------------------------------------------------
%%% @author loki
%%% @author marilena
%%% @copyright (C) 2014, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 19. May 2014 14:56
%%%-------------------------------------------------------------------
-module(client).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, to_String/1]).

%% API
-export([clientStart/4]).

%-------------------------------------------------------------------------------------%
% Startfunktion des einzelnen clients                                                 %
% Konfiguration wird gelesen, Werte gesetzt und die Schleife gestartet                %
%-------------------------------------------------------------------------------------%
clientStart(Host, Address, Config, Number) ->
  ToSend = 5,
  {ok, Lifetime} = get_config_value(lifetime, Config),
  {ok, TimeInterval} = get_config_value(sendeintervall, Config),
  {ok, Server} = get_config_value(servername, Config),
  timer:exit_after(Lifetime * 1000, self(), timeout),
LogFile = lists:concat(["client_", Number, to_String(node()), ".log"]),
ServerName = list_to_atom(lists:concat([Host, "@", Address])),
% 	F2= global:whereis_name(ServerName),
  	Pid = global:whereis_name(Server),
 logging(LogFile, lists:concat(["ServerName: ",to_String(Server), " PID", to_String(Pid), "\n"])),
%   Pid = {Server, global:whereis_name(Server)},
  Text = lists:concat(["Gestartet: ",to_String(node()), "-", to_String(self()), "-0310 Startzeit: ", timeMilliSecond(), "\n"]),

  logging(LogFile, Text),
  loop(Pid, Number, LogFile, TimeInterval*1000, ToSend).


%---------------------------------------------------------------------------------------- %
% Hauptschleife des Clients                                                               %
% Die Logik des Clients, wie der Wechsel zwischen Redakteur und Leser, befindet sich hier %
%---------------------------------------------------------------------------------------- %
loop(Pid, Number, LogFile, TimeInterval, ToSend) ->

  if ToSend > 0 ->
    %Redakteur, Ids werden geholt und Nachrichten gesendet
	
    Pid ! {query_msgid, self()},

    receive {msgid, MsgId} -> 	
       logging(LogFile, lists:concat(["MsgId", "-", to_String(MsgId),"\n"])),
      Log = lists:concat([Number, "-", to_String(node()), "-", to_String(self()), "-0310 MsgId: ", MsgId, " von: ", to_String(Pid), " erhalten um: ", timeMilliSecond(), "\n"]),
      logging(LogFile, Log),
      Time = if ToSend =< 1 -> changeTimeInterval(TimeInterval, LogFile);
        ToSend > 1 -> TimeInterval
        end,
% logging(LogFile, lists:concat(["SleeptIme", "-", to_String(Time),"\n"])),
      timer:sleep(Time),

      if ToSend > 1 ->
        Msg = generateMessage([Number,to_String(node())],MsgId ),
        dropMessage(Pid, Msg, MsgId, LogFile);
      ToSend =< 1 ->
          Msg = lists:concat([Number, "-", to_String(node()), "-", to_String(self()), "-0310: ", MsgId, "te_Nachricht um ", timeMilliSecond(), " nicht gesendet ***vergessen***\n"]),
          logging(LogFile, Msg)
      end,
      loop(Pid, Number, LogFile, Time, ToSend - 1);

    Any -> logging(LogFile,io_lib:format("Unbekanntes Antwortformat:~p\n", [Any]))
    end;
  %Leser, alle Nachrichten werden geholt
  ToSend =:= 0 ->  getMessages(Pid, Number, LogFile, TimeInterval)
  end.

%-------------------------------------------------------------------------------------%
% Sendet Nachricht an den Server wie in der Schnittstelle vorgegeben                  %
%-------------------------------------------------------------------------------------%
dropMessage(Pid, Msg, MsgId, LogFile) ->
  Pid ! {new_message, {Msg, MsgId}},
  Log = lists:concat([Msg, "gesendet\n"]),
  logging(LogFile, Log).

%-------------------------------------------------------------------------------------%
% Erzeugt eine Nachricht bestehend aus Clientnummer, Host,                            %
% der Praktikumsgruppe/Teamnummer, der MsgId und der Zeit @return Nachricht           %
%-------------------------------------------------------------------------------------%
generateMessage(Client, MsgId) ->
  lists:concat([to_String(Client), "-0310-", to_String(self()),"-",
    to_String(MsgId),"te Nachricht" "-Sendezeit:",timeMilliSecond()]).

%-------------------------------------------------------------------------------------%
% Holt alle Nachrichten vom Server und fügt an vom eigenen Redakteur gesendete        %
% Nachricht "Nachricht vom eigenen Redakteur" an und loggt die Nachrichten            %
% %-----------------------------------------------------------------------------------%
getMessages(Pid, ClientNumber, LogFile, TimeInterval) ->
  Pid ! {query_messages, self()},
  LogDings = lists:concat(["send query_messages to ", to_String(Pid), "|\n"]),
  logging(LogFile, LogDings),
  receive {message, MsgId, Message, Terminated} ->
    IsOwn = isOwnMessage(Message, ClientNumber, LogFile),
    if IsOwn =:= true ->
      Append = "Nachricht vom eigenen Redakteur";
    IsOwn =:= false -> Append = ""
    end,

    Log = lists:concat(["-----",Message, ".", Append, "; Erhalten: ", timeMilliSecond(), "|\n"]),
    logging(LogFile, Log),

    if Terminated == false ->
      getMessages(Pid, ClientNumber, LogFile, TimeInterval);
    Terminated == true ->
        logging(LogFile, "All messages received\n"),
        loop(Pid, ClientNumber, LogFile, TimeInterval, 5)
    end
  end.

%-------------------------------------------------------------------------------------%
% Prüft ob die eigene ClientNr vorne in der Nachricht steht                           %
%  @return boolean                                                                    %
%-------------------------------------------------------------------------------------%
isOwnMessage(Message, ClientNumber, LogFile) ->
  string:str(Message, lists:concat(["[",ClientNumber])) =/= 0.

%-------------------------------------------------------------------------------------%
% Verändert die Wartezeit zwischen dem Senden um 50% auf minimal 2 Sekunden           %
% @return neue Wartezeit                                                              %
%-------------------------------------------------------------------------------------%
changeTimeInterval(CurrentTime, LogFile) ->
  Min = 2000,
  random:seed(erlang:now()),
  Factor = case random:uniform(2) of
    1 -> 1.5;
    2 -> 0.5
    end,
  NewTime = trunc(CurrentTime * Factor),
  if  NewTime =< Min ->UpdatedTime = Min;
      NewTime > Min -> UpdatedTime = NewTime
  end,
  logging(LogFile, lists:concat(["Neues Sendeintervall: ", trunc(UpdatedTime/1000), " Sekunden\n"])),
  UpdatedTime.