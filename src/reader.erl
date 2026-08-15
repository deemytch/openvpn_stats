-module(reader).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

-define(PASSWORD_REQ, <<"ENTER PASSWORD:">>).
-define(SUCCESS_CONNECT, <<"SUCCESS: password is correct", _/binary>>).
-define(REMOTE_EXIT, <<">NOTIFY:info,remote-exit,EXIT", _/binary>>).
-define(CLIENT_ESTABLISHED, <<">CLIENT:ESTABLISHED,", _/binary>>).

% prompt, await_success, await_status, ok
-record(state, {socket, cfg, stage = prompt}).
-record(client, {cn, state, local_ip, remote_ip}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}, {continue, connect}}.

handle_continue(connect, State) ->
  {ok, Cfg}  = application:get_env(ovpn_stats, reader),
  {ok, Sock} = gen_tcp:connect({local, maps:get(socket_path, Cfg)}, 0, [binary, {active, true}]),
  {noreply, State#state{socket = Sock, cfg = Cfg}}.

handle_info({tcp, Sock, ?PASSWORD_REQ}, #state{socket = Sock, stage = prompt} = State) ->
  gen_tcp:send(Sock, <<(maps:get(password, State#state.cfg))/binary>>),
  {noreply, State#state{stage = await_success}};

handle_info({tcp, Sock, ?SUCCESS_CONNECT}, #state{socket = Sock, stage = await_success} = State) ->
  gen_tcp:send(Sock, <<"log on\nstatus on\nstatus\n">>),
  {noreply, State#state{stage = await_status}};

handle_info({tcp, Sock, OvpnStatusText}, #state{socket = Sock, stage = await_status} = State) ->
  StatusStr   = binary_to_list(OvpnStatusText),
  StatusLines = string:split(StatusStr, "\n", all),
  lists:map(fun(L) ->
    case re:run(L, "^CLIENT_LIST,") of
      nomatch -> nil;
      {match, _} ->
          Cols = string:split(L, ",", all),
          client_update(up, lists:nth(2, Cols), lists:nth(4, Cols), lists:nth(3, Cols))
    end
  end, StatusLines),
  publisher ! report,
  {noreply, State#state{stage = ok}};

handle_info({tcp, Sock, ?REMOTE_EXIT}, #state{socket = Sock, stage = ok} = State) ->
  gen_tcp:send(Sock, <<"status\n">>),
  {noreply, State#state{stage = await_status}};

handle_info({tcp, Sock, ?CLIENT_ESTABLISHED = Data}, #state{socket = Sock, stage = ok} = State) ->
  Log = string:split(Data, "\n"),
  Client = lists:foldl(
    fun(L, Rec) ->
      case L of
        <<"^>CLIENT:ENV,common_name=", CN/binary>> ->
          Rec#client{cn = CN};
        <<"CLIENT:ENV,ifconfig_pool_remote_ip=", LocalIP/binary>> ->
          Rec#client{local_ip = LocalIP};
        <<"CLIENT:ENV,trusted_ip=", RemoteIP/binary>> ->
          Rec#client{remote_ip = RemoteIP};
        _ ->
          Rec
      end
    end, #client{state = up}, Log),
  client_update(Client),
  publisher ! report,
  {noreply, State#state{stage = ok}};

handle_info({tcp, Sock, Other}, #state{socket = Sock, stage = ChannelStage}) ->
  ?LOG_ERROR("State: ~tp, Что-то пришло не то на управляющем интерфейсе: ~tp", [ChannelStage, Other]),
  erlang:halt(1);

handle_info({stuur, Bin}, #state{socket = Sock} = State) ->
  gen_tcp:send(Sock, Bin),
  {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% атомарное обновление, для выполнения в генсервере
client_update(#client{state = up} = Client) ->
  ets:insert(clients_list, Client),
  Client.

client_update(up, CN, LocalIP, RemoteIP) ->
  Client = #client{
      state = up,
      cn = check2binary(CN),
      local_ip = check2binary(LocalIP),
      remote_ip = check2binary(RemoteIP)
    },
  ets:insert(clients_list, Client),
  Client;
client_update(down, CN, _, _) ->
  ets:delete(clients_list, CN);
client_update(ClientState, CN, _, _) ->
  ?LOG_ERROR("Неизвестное состояние ~p клиента ~p", [ClientState, CN]).

check2binary(L) when is_list(L) -> list_to_binary(L);
check2binary(L) when is_binary(L) -> L.
