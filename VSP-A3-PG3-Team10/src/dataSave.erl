-module(dataSave).
-import(werkzeug, [get_config_value/2, logging/2, logstop/0, timeMilliSecond/0, delete_last/1, shuffle/1, type_is/1, to_String/1, bestimme_mis/2]).
-behaviour(gen_server).

%Functions needed by gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([getData/0, startLink/0, stop/0]).

%Saves current data
-record(datarecord, {logdatei, data}).

startLink() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
getData() -> gen_server:call(?MODULE, {get_data}).

init([]) ->
  LogDatei = lists:concat(["dataSave.log"]),
  werkzeug:logging(LogDatei, "DataSave started\n"),
  spawn(fun() -> pollData(LogDatei) end),
  {ok, #datarecord{logdatei = LogDatei, data = ""}}.


pollData(LogDatei) ->
  NewData = io:get_chars("", 24),
  gen_server:call(?MODULE, {newData, LogDatei, NewData}),
  pollData(LogDatei).


handle_call({get_data}, _From, DataRecord) ->
  {reply, DataRecord#datarecord.data, DataRecord};


handle_call({newData, LogDatei, Data}, _From, DataRecord) ->
  {reply, Data, DataRecord#datarecord{logdatei = LogDatei, data = Data}}.


stop() -> gen_server:cast(?MODULE, stop).
terminate(normal, _State) -> ok.
handle_cast(stop, State) -> {stop, normal, State};
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.
code_change(_OldVersion, State, _Extra) -> {ok, State}.