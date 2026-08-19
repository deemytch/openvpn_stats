-module(reader).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").
-include("include/client.hrl").

-define(PASSWORD_REQ, <<"ENTER PASSWORD:">>).
-define(SUCCESS_CONNECT, <<"SUCCESS: password is correct", _/binary>>).
-define(REMOTE_EXIT, <<">NOTIFY:info,remote-exit,EXIT", _/binary>>).
-define(CLIENT_ESTABLISHED, <<">CLIENT:ESTABLISHED,", _/binary>>).

% prompt, await_success, await_status, ok
-record(state, {socket, cfg, stage = prompt}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}, {continue, connect}}.

handle_continue(connect, State) ->
  {ok, Cfg}  = application:get_env(ovpn_stats, reader),
  {ok, Sock} = gen_tcp:connect({local, maps:get(socket_path, Cfg)}, 0, [binary, {active, true}]),
  {noreply, State#state{socket = Sock, cfg = Cfg}}.

handle_info({tcp, Sock, ?PASSWORD_REQ}, #state{stage = prompt} = State) ->
  gen_tcp:send(Sock, <<(maps:get(password, State#state.cfg))/binary>>),
  {noreply, State#state{stage = await_success}};

handle_info({tcp, Sock, ?SUCCESS_CONNECT = Input}, #state{stage = await_success} = State) ->
  ?LOG_DEBUG("подключились к сокету OpenVPN. ~ts~n----", [Input]),
  gen_tcp:send(Sock, <<"log on\n">>),
  {noreply, State#state{stage = ok}};

handle_info({tcp, Sock, ?REMOTE_EXIT}, #state{stage = ok} = State) ->
  gen_tcp:send(Sock, <<"status\n">>),
  {noreply, State#state{stage = ok}};

handle_info({tcp, Sock, InputText}, #state{stage = ok} = State) ->
  ?LOG_DEBUG("Текст приехал ~ts~n---", [InputText]),
  Text = re:split(binary_to_list(InputText), "[\n\r]+", [{return, list}]),
  case is_status_log(Text)  of
    true ->
      ClientsList = parse_status_log(Text),
      ?LOG_DEBUG("Sending clients list ~p", [ClientsList]),
      publisher ! {report, ClientsList};
    false ->
      gen_tcp:send(Sock, <<"status\n">>)
  end,
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

parse_status_log(Text) ->
  lists:foldl(
    fun("CLIENT_LIST" ++ _ = L, List) when is_list(L) ->
          ?LOG_DEBUG("splitting ~ts", [L]),
          Fields = string:split(L, "\t", all),
          ?LOG_DEBUG("splitted list ~p", [Fields]),
          [#client{ state = up,
                    cn = lists:nth(2, Fields),
                    local_ip = lists:nth(4, Fields),
                    remote_ip = lists:nth(3, Fields)}
          | List];
          (_, List) -> List
    end,
    [],
    Text).

is_status_log(Text)->
  lists:any(fun("HEADER\tCLIENT_LIST\tCommon Name" ++ _) -> true; (_) -> false end, Text).
