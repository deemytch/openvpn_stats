# ovpn_stats

Minimal version is OTP 28.
It is used for pushing stats from remote openvpn to desktop widget.
Look at https://github.com/deemytch/list_widget

Build
-----

    rebar3 compile
    rebar3 as prod release

Then you know what to do.

## OpenVPN management interface

https://openvpn.net/community-docs/management-interface.html

Those lines should be added to your openvpn server configuration,
for ex. `/etc/openvpn/server/mijnserveur.conf`

    explicit-exit-notify 1
    management /run/openvpn-server/localhost.socket unix /etc/openvpn/server/mijnserveur.pw

where `mijserveur.pw` contains plaintext password for the management socket.
Then add that password and the socket file path to the `sys.config`.

## OpenSSH protocol extensions

https://www.openssh.org/specs.html
https://github.com/openssh/openssh-portable/blob/master/PROTOCOL

ssh now knows how to connect to remote unix-socket, so we can throwing socat from the pipe.
