%%
%% Licensed to the Apache Software Foundation (ASF) under one
%% or more contributor license agreements. See the NOTICE file
%% distributed with this work for additional information
%% regarding copyright ownership. The ASF licenses this file
%% to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance
%% with the License. You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
-module(thrift_sslsocket_transport).

-include("thrift_transport_behaviour.hrl").

-behaviour(thrift_transport).

-export([new/3,
         write/2, read/2, flush/1, close/1,

         new_transport_factory/3]).

%% Export only for the transport factory
-export([new/2]).

-record(data, {socket,
               recv_timeout=infinity}).
-type state() :: #data{}.

%% The following "local" record is filled in by parse_factory_options/2
%% below. These options can be passed to new_protocol_factory/3 in a
%% proplists-style option list. They're parsed like this so it is an O(n)
%% operation instead of O(n^2)
-record(factory_opts, {connect_timeout = infinity,
                       sockopts = [],
                       framed = false,
                       ssloptions = []}).

parse_factory_options([], FactoryOpts, TransOpts) -> {FactoryOpts, TransOpts};
parse_factory_options([{framed, Bool}|Rest], FactoryOpts, TransOpts)
when is_boolean(Bool) ->
  parse_factory_options(Rest, FactoryOpts#factory_opts{framed = Bool}, TransOpts);
parse_factory_options([{sockopts, OptList}|Rest], FactoryOpts, TransOpts)
when is_list(OptList) ->
  parse_factory_options(Rest, FactoryOpts#factory_opts{sockopts = OptList}, TransOpts);
parse_factory_options([{connect_timeout, TO}|Rest], FactoryOpts, TransOpts)
when TO =:= infinity; is_integer(TO) ->
  parse_factory_options(Rest, FactoryOpts#factory_opts{connect_timeout = TO}, TransOpts);
parse_factory_options([{ssloptions, SslOptions} | Rest], FactoryOpts, TransOpts) when is_list(SslOptions) ->
    parse_factory_options(Rest, FactoryOpts#factory_opts{ssloptions=SslOptions}, TransOpts);
parse_factory_options([{recv_timeout, TO}|Rest], FactoryOpts, TransOpts)
when TO =:= infinity; is_integer(TO) ->
  parse_factory_options(Rest, FactoryOpts, [{recv_timeout, TO}] ++ TransOpts).

new(Socket, SockOpts, SslOptions) when is_list(SockOpts), is_list(SslOptions) ->
    inet:setopts(Socket, [{active, false}]), %% => prevent the ssl handshake messages get lost

    %% upgrade to an ssl socket
    case catch ssl:ssl_handshake(Socket, SslOptions) of % infinite timeout
        {ok, SslSocket} ->
            new(SslSocket, SockOpts);
        {error, Reason} ->
            exit({error, Reason});
        Other ->
            error_logger:error_report(
              [{application, thrift},
               "SSL accept failed error",
               lists:flatten(io_lib:format("~p", [Other]))]),
            exit({error, ssl_accept_failed})
    end.

new(SslSocket, Opts) ->
    State =
        case lists:keysearch(recv_timeout, 1, Opts) of
            {value, {recv_timeout, Timeout}}
              when is_integer(Timeout), Timeout > 0 ->
                #data{socket=SslSocket, recv_timeout=Timeout};
            _ ->
                #data{socket=SslSocket}
        end,
    thrift_transport:new(?MODULE, State).

%% Data :: iolist()
write(This = #data{socket = Socket}, Data) ->
    {This, ssl:send(Socket, Data)}.

read(This = #data{socket=Socket, recv_timeout=Timeout}, Len)
  when is_integer(Len), Len >= 0 ->
    case ssl:recv(Socket, Len, Timeout) of
        Err = {error, timeout} ->
            error_logger:info_msg("read timeout: peer conn ~p", [Socket]),
            ssl:close(Socket),
            {This, Err};
        Data ->
            {This, Data}
    end.

%% We can't really flush - everything is flushed when we write
flush(This) ->
    {This, ok}.

close(This = #data{socket = Socket}) ->
    {This, ssl:close(Socket)}.

%%%% FACTORY GENERATION %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%
%% Generates a "transport factory" function - a fun which returns a thrift_transport()
%% instance.
%% This can be passed into a protocol factory to generate a connection to a
%% thrift server over a socket.
%%
new_transport_factory(Host, Port, Options) ->
    {FactoryOpts, TransOpts} = parse_factory_options(Options, #factory_opts{}, []),

    F = fun() ->
                SockOpts = [binary,
                            {packet, 0},
                            {active, false},
                            {nodelay, true} |
                            FactoryOpts#factory_opts.sockopts],
                case catch gen_tcp:connect(Host, Port, SockOpts,
                                           FactoryOpts#factory_opts.connect_timeout) of
                    {ok, Sock} ->
                        SslSock = case catch ssl:connect(Sock, FactoryOpts#factory_opts.ssloptions,
                                                         FactoryOpts#factory_opts.connect_timeout) of
                                      {ok, SslSocket} ->
                                          SslSocket;
                                      {error, Error} = Error ->
                                          Error;
                                      Other ->
                                          catch gen_tcp:close(Sock),
                                          {error, Other}
                                  end,
                        {ok, Transport} = thrift_sslsocket_transport:new(SslSock, TransOpts),
                        {ok, BufTransport} =
                            case FactoryOpts#factory_opts.framed of
                                true  -> thrift_framed_transport:new(Transport);
                                false -> thrift_buffered_transport:new(Transport)
                            end,
                        {ok, BufTransport};
                    {error, Error} = Error ->
                       Error;
                    Error  ->
                        {error, Error}
                end
        end,
    {ok, F}.
