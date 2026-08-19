-module(publisher).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("include/client.hrl").

-export([start_link/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {widget_socket, conn_ref}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}, {continue, connect}}.

handle_continue(connect, State) ->
  {ok, Cfg} = application:get_env(ovpn_stats, publisher),
  Opts      = maps:get(opts, Cfg, []),
  {ok, ConnRef} = ssh:connect(maps:get(host, Cfg), maps:get(port, Cfg), Opts),
  {
   noreply,
   State#state{
     conn_ref = ConnRef,
     widget_socket = maps:get(widget_socket, Cfg)
  }}.

handle_info({report, ClientList}, #state{conn_ref = ConnRef, widget_socket = WidgetSocket} = State) ->
  Data         = make_report(ClientList),
  WidgetSocket = State#state.widget_socket,
  Ctrl         = <<(byte_size(WidgetSocket)):32, WidgetSocket/binary, 0:32, 0:32>>,
  {ok, ChanId} = ssh_connection:open_channel(ConnRef, "direct-streamlocal@openssh.com", Ctrl, 500),
  ssh_connection:send(ConnRef, ChanId, Data),
  case ssh_connection:send_eof(ConnRef, ChanId) of
    ok ->
      ?LOG_NOTICE("Данные '~p' записаны в удалённый сокет.", [Data]);
    {error, closed} ->
      ?LOG_ERROR("Ошибка записи '~p' в удалённый сокет.", [Data])
  end,
  ssh_connection:close(ConnRef, ChanId),
  {noreply, State};
handle_info({ssh_cm, _Conn, _Msg}, State) ->
  {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% забираем всю таблицу и отправляем виджету, для выполнения в генсервере
make_report(ClientList) ->
  ClientListBin = lists:foldl(
    fun(Rec, Output) ->
      ?LOG_INFO("report: ~p", [Rec]),
      PeerStr = <<
        (list_to_binary(Rec#client.cn))/binary, " ",
        (list_to_binary(Rec#client.local_ip))/binary, " ",
        (list_to_binary(Rec#client.remote_ip))/binary
      >>,
      Len     = byte_size(PeerStr),
      <<Output/binary, Len:8, PeerStr/binary>>
    end,
    <<16#FF, (length(ClientList)):8>>,
    ClientList),
  <<ClientListBin/binary, 0:16>>.
