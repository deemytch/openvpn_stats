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
-record(state, {socket, cfg, stage = prompt, outcache = []}).
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

handle_info({tcp, Sock, ?SUCCESS_CONNECT = Input}, #state{socket = Sock, stage = await_success} = State) ->
  ?LOG_DEBUG("подключились к сокету OpenVPN. ~ts~n----", [Input]),
  gen_tcp:send(Sock, <<"log on\n">>),
  {noreply, State#state{stage = ok, outcache = [<<"status\n">>]}};

handle_info({tcp, Sock, ?REMOTE_EXIT}, #state{socket = Sock, stage = ok} = State) ->
  gen_tcp:send(Sock, <<"status\n">>),
  {noreply, State#state{stage = ok}};

handle_info({tcp, Sock, InputText}, #state{socket = Sock, stage = ok} = State) ->
  ?LOG_DEBUG("Текст приехал ~ts~n---", [InputText]),
  parse_client_list(InputText),
  publisher ! report,
  {noreply, send_next(State)};

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
client_save(#client{state = up, cn = CN, local_ip = LocalIP, remote_ip = RemoteIP} = Client)
when CN /= undefined, LocalIP /= undefined, RemoteIP /= undefined ->
  ?LOG_DEBUG("Вставляю запись ~p", [Client]),
  ets:insert(clients_list, #client{
    state = up,
    cn = check2binary(CN),
    local_ip = check2binary(LocalIP),
    remote_ip = check2binary(RemoteIP)
  }),
  #client{state = up};

client_save(#client{} = Rec) -> Rec.

% client_save(down, CN, _, _) ->
%   ?LOG_DEBUG("Удаляю запись (2) ~p", [CN]),
%   ets:delete(clients_list, CN).

check2binary(L) when is_list(L) -> list_to_binary(L);
check2binary(L) when is_binary(L) -> L.

send_next(#state{outcache = []} = State) -> State;
send_next(#state{outcache = [Line| Rest]} = State) ->
  gen_tcp:send(State#state.socket, Line),
  State#state{outcache = Rest}.

parse_client_list(Data) when is_binary(Data) ->
  Text = re:split(binary_to_list(Data), "[\n\r]+", [{return, list}]),
  case lists:any(fun("CLIENT_LIST" ++ _) -> true; (_) -> false end, Text) of
    true -> % это статус
      ets:delete_all_objects(clients_list),
      parse_status_log(Text);
    false -> % это длинный лог
      parse_env_log(Text)
  end.

parse_env_log(Text) ->
  lists:foldl(
    fun(L, #client{cn = CN, local_ip = LocalIP, remote_ip = RemoteIP} = Rec) ->
      Rec1 = client_save(Rec),
      case L of
        ">CLIENT:ENV,common_name=" ++ CN = FullLineCN ->
          ?LOG_DEBUG("common name ~ts", [FullLineCN]),
          Rec1#client{cn = CN};

        ">CLIENT:ENV,ifconfig_pool_remote_ip=" ++ LocalIP = FullLineLIP->
          ?LOG_DEBUG("local ip ~ts", [FullLineLIP]),
          Rec1#client{local_ip = LocalIP};

        ">CLIENT:ENV,trusted_ip=" ++ RemoteIP = FullLineRIP ->
          ?LOG_DEBUG("remote ip ~ts", [FullLineRIP]),
          Rec1#client{remote_ip = RemoteIP};

        SkipLine ->
          ?LOG_DEBUG("skip ~ts", [SkipLine]),
          Rec1
      end
    end,
    #client{state = up},
    Text).

parse_status_log(Text) ->
  lists:map(
    fun("CLIENT_LIST" ++ _ = L) ->
      Fields = re:split(L, "[[:blank:]]+", [{return, list}]),
      client_save(
        #client{state = up,
                cn = lists:nth(2, Fields),
                local_ip = lists:nth(4, Fields),
                remote_ip = lists:nth(3, Fields)});
      (_) -> nil
      end,
    Text).
