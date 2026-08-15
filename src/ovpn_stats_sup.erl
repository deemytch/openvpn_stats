-module(ovpn_stats_sup).
-behaviour(supervisor).
-export([start_link/0]).
-export([init/1]).
-include_lib("kernel/include/logger.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [
      #{id => reader, start => {reader, start_link, []}},
      #{id => publisher, start => {publisher, start_link, []}}
    ],
    ?LOG_DEBUG("Начинаем"),
    {ok, {SupFlags, ChildSpecs}}.
