-ifndef(CLIENT_RECORD).
-define(CLIENT_RECORD, true).

-record(client, {cn, state, local_ip, remote_ip}).

-endif.
