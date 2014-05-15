import(werkzeug).
--export ([start/0]).

-record(state, {
  current_msg_id = 0,
  clients = [],
  hold_back_queue = [],
  delivery_queue = [],
  config
}).

-record(reader, {
  last_msg_id,
  kill_timer
}).

-record(message,{
  msg,
  time_at_hold_back_queue,
  time_at_delivery_queue
}).

-record(config,{
  server_lifetime,
  client_lifetime,
  server_name,
  delivery_queue_limit
}).


start() ->
.

query_message(Client, State) ->
	State.

new_message(Message, Number, State) ->
	State.

query_msg_id(Client, State) ->
	State.