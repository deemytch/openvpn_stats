-module(ovpn_stats_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    io:setopts(standard_io, [{encoding, unicode}]),
    application:ensure_all_started([ssh]),
    ets:new(clients_list, [ordered_set, named_table, public, {keypos, 2}]),
    ovpn_stats_sup:start_link().

stop(_State) ->
    logger:notice("Вышел."),
    ok.
