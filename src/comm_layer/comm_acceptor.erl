% @copyright 2008-2011 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Acceptor.
%%
%%      This module accepts new connections and starts corresponding 
%%      comm_connection processes.
%% @version $Id$
-module(comm_acceptor).
-author('schuett@zib.de').
-vsn('$Id$').

-export([start_link/1, init/2, check_config/0]).

-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(GroupName) ->
    Pid = spawn_link(comm_acceptor, init, [self(), GroupName]),
    receive
        {started} ->
            {ok, Pid}
    end.

-spec init(pid(), pid_groups:groupname()) -> any().
init(Supervisor, GroupName) ->
    erlang:register(comm_layer_acceptor, self()),
    pid_groups:join_as(GroupName, comm_acceptor),

    log:log(info,"[ CC ] listening on ~p:~p", [config:read(listen_ip), config:read(port)]),
    case util:app_get_env(verbose, false) of
        true -> io:format("Listening on ~p:~p.~n", [config:read(listen_ip), config:read(port)]);
        false -> ok
    end,

    LS = case config:read(listen_ip) of
             undefined ->
                 open_listen_port(config:read(port), first_ip());
             _ ->
                 open_listen_port(config:read(port), config:read(listen_ip))
         end,
    {ok, {_LocalAddress, LocalPort}} = inet:sockname(LS),
    comm_server:set_local_address(undefined, LocalPort),
    %io:format("this() == ~w~n", [{LocalAddress, LocalPort}]),
    Supervisor ! {started},
    server(LS).

server(LS) ->
    case gen_tcp:accept(LS) of
        {ok, S} ->
            case comm_server:get_local_address_port() of
                {undefined, LocalPort} ->
                    {ok, {MyIP, _LocalPort}} = inet:sockname(S),
                    comm_server:set_local_address(MyIP, LocalPort);
                _ -> ok
            end,
            % receive first message on the channel (generated by
            % comm_connection to get the listen port of the other side in order
            % to use the same connection for sending messages)
            receive
                {tcp, S, Msg} ->
                    {endpoint, Address, Port, Channel} = binary_to_term(Msg),
                    % auto determine remote address, if not sent correctly
                    NewAddress =
                        if Address =:= {0,0,0,0}
                           orelse Address =:= {127,0,0,1} ->
                                case inet:peername(S) of
                                    {ok, {PeerAddress, _Port}} -> PeerAddress;
                                    {error, _Why} -> Address
                                end;
                           true -> Address
                        end,
                    ConnPid =
                        comm_server:create_connection(NewAddress, Port, S, Channel),
                    % note: need to set controlling process from here as we created the socket
                    _ = gen_tcp:controlling_process(S, ConnPid),
                    _ = inet:setopts(S, comm_server:tcp_options(Channel)),
                    ok
            end;
        Other ->
            log:log(warn,"[ CC ] unknown message ~p", [Other])
    end,
    server(LS).

open_listen_port({From, To}, IP) ->
    open_listen_port(lists:seq(From, To), IP);
open_listen_port([Port | Rest], IP) ->
    case gen_tcp:listen(Port, [binary, {packet, 4}, {ip, IP}, {backlog, 128000}]
                        ++ comm_server:tcp_options(main)) of
        {ok, Socket} ->
            log:log(info,"[ CC ] listening on ~p:~p", [IP, Port]),
            Socket;
        {error, Reason} ->
            log:log(error,"[ CC ] can't listen on ~p: ~p", [Port, Reason]),
            open_listen_port(Rest, IP)
    end;
open_listen_port([], _) ->
    abort;
open_listen_port(Port, IP) ->
    open_listen_port([Port], IP).

-include_lib("kernel/include/inet.hrl").

first_ip() ->
    {ok, Hostname} = inet:gethostname(),
    {ok, HostEntry} = inet:gethostbyname(Hostname),
    erlang:hd(HostEntry#hostent.h_addr_list).

%% @doc Checks whether config parameters of the cyclon process exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_port(port).
