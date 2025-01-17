%% -------------------------------------------------------------------
%%
%% riakc_pb_socket: protocol buffer client
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Manages a connection to Riak via the Protocol Buffers
%% transport and executes the commands that can be performed over that
%% connection.
%% @end

-module(riakc_pb_socket).
-include_lib("kernel/include/inet.hrl").
-include_lib("riak_pb/include/riak_pb.hrl").
-include_lib("riak_pb/include/riak_kv_pb.hrl").
-include_lib("riak_pb/include/riak_pb_kv_codec.hrl").
-include_lib("riak_pb/include/riak_search_pb.hrl").
-include_lib("riak_pb/include/riak_yokozuna_pb.hrl").
-include_lib("riak_pb/include/riak_dt_pb.hrl").
-include("riakc.hrl").
-behaviour(gen_server).

-export([start_link/2, start_link/3,
         start/2, start/3,
         stop/1,
         set_options/2, set_options/3,
         is_connected/1, is_connected/2,
         ping/1, ping/2,
         get_client_id/1, get_client_id/2,
         set_client_id/2, set_client_id/3,
         get_server_info/1, get_server_info/2,
         get/3, get/4, get/5,
         put/2, put/3, put/4,
         delete/3, delete/4, delete/5,
         delete_vclock/4, delete_vclock/5, delete_vclock/6,
         delete_obj/2, delete_obj/3, delete_obj/4,
         list_buckets/1, list_buckets/2, list_buckets/3,
         stream_list_buckets/1, stream_list_buckets/2, stream_list_buckets/3,
         legacy_list_buckets/2,
         list_keys/2, list_keys/3,
         stream_list_keys/2, stream_list_keys/3,
         get_bucket/2, get_bucket/3, get_bucket/4,
         get_bucket_type/2, get_bucket_type/3,
         set_bucket/3, set_bucket/4, set_bucket/5,
         set_bucket_type/3, set_bucket_type/4,
         reset_bucket/2, reset_bucket/3, reset_bucket/4,
         mapred/3, mapred/4, mapred/5,
         mapred_stream/4, mapred_stream/5, mapred_stream/6,
         mapred_bucket/3, mapred_bucket/4, mapred_bucket/5,
         mapred_bucket_stream/5, mapred_bucket_stream/6,
         search/3, search/4, search/5, search/6,
         get_index/4, get_index/5, get_index/6, get_index/7, %% @deprecated
         get_index_eq/4, get_index_range/5, get_index_eq/5, get_index_range/6,
         cs_bucket_fold/3,
         default_timeout/1,
         tunnel/4,
         get_preflist/3, get_preflist/4]).

%% Counter API
-export([counter_incr/4, counter_val/3]).
%% with options
-export([counter_incr/5, counter_val/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Yokozuna admin commands
-export([list_search_indexes/1, list_search_indexes/2,
         create_search_index/2, create_search_index/3, create_search_index/4,
         get_search_index/2, get_search_index/3,
         delete_search_index/2, delete_search_index/3,
         set_search_index/3,
         get_search_schema/2, get_search_schema/3,
         create_search_schema/3, create_search_schema/4]).

%% Datatypes API
-export([fetch_type/3, fetch_type/4,
         update_type/4, update_type/5,
         modify_type/5]).


-deprecated({get_index,'_', eventually}).

-type ctx() :: any().
-type rpb_req() :: {tunneled, msg_id(), binary()} | atom() | tuple().
-type rpb_resp() :: atom() | tuple().
-type msg_id() :: non_neg_integer(). %% Request identifier for tunneled message types
-type search_admin_opt() :: {timeout, timeout()} |
                     {call_timeout, timeout()}.
-type search_admin_opts() :: [search_admin_opt()].
-type index_opt() :: {timeout, timeout()} |
                     {call_timeout, timeout()} |
                     {stream, boolean()} |
                     {continuation, binary()} |
                     {pagination_sort, boolean()} |
                     {max_results, non_neg_integer() | all}.
-type index_opts() :: [index_opt()].
-type range_index_opt() :: {return_terms, boolean()} |
                           {term_regex, binary()}.
-type range_index_opts() :: [index_opt() | range_index_opt()].
-type cs_opt() :: {timeout, timeout()} |
                  {continuation, binary()} |
                  {max_results, non_neg_integer() | all} |
                  {start_key, binary()} |
                  {start_incl, boolean()} |
                  {end_key, binary()} |
                  {end_incl, boolean()}.
-type cs_opts() :: [cs_opt()].

%% Which client operation the default timeout is being requested
%% for. `timeout' is the global default timeout. Any of these defaults
%% can be overridden by setting the application environment variable
%% of the same name on the `riakc' application, for example:
%% `application:set_env(riakc, ping_timeout, 5000).'
-record(request, {ref :: reference(), msg :: rpb_req(), from, ctx :: ctx(), timeout :: timeout(),
                  tref :: reference() | undefined }).

-type portnum() :: non_neg_integer(). %% The TCP port number of the Riak node's Protocol Buffers interface
-type address() :: string() | atom() | inet:ip_address(). %% The TCP/IP host name or address of the Riak node
-record(state, {address :: address(),    % address to connect to
                port :: portnum(),       % port to connect to
                auto_reconnect = false :: boolean(), % if true, automatically reconnects to server
                                        % if false, exits on connection failure/request timeout
                queue_if_disconnected = false :: boolean(), % if true, add requests to queue if disconnected
                sock :: port() | ssl:sslsocket(),       % gen_tcp socket
                keepalive = false :: boolean(), % if true, enabled TCP keepalive for the socket
                transport = gen_tcp :: 'gen_tcp' | 'ssl',
                active :: #request{} | undefined,     % active request
                queue :: queue:queue() | undefined,      % queue of pending requests
                connects=0 :: non_neg_integer(), % number of successful connects
                failed=[] :: [connection_failure()],  % breakdown of failed connects
                connect_timeout=infinity :: timeout(), % timeout of TCP connection
                credentials :: undefined | {string(), string()}, % username/password
                cacertfile,    % Path to CA certificate file
                certfile,      % Path to client certificate file, when using
                               % certificate authentication
                keyfile,       % Path to certificate keyfile, when using
                               % certificate authentication
                ssl_opts = [], % Arbitrary SSL options, see the erlang SSL
                               % documentation.
                reconnect_interval=?FIRST_RECONNECT_INTERVAL :: non_neg_integer()}).

%% @private Like `gen_server:call/3', but with the timeout hardcoded
%% to `infinity'.
call_infinity(Pid, Msg) ->
    gen_server:call(Pid, Msg, infinity).

%% @doc Create a linked process to talk with the riak server on Address:Port
%%      Client id will be assigned by the server.
-spec start_link(address(), portnum()) -> {ok, pid()} | {error, term()}.
start_link(Address, Port) ->
    start_link(Address, Port, []).

%% @doc Create a linked process to talk with the riak server on Address:Port with Options.
%%      Client id will be assigned by the server.
-spec start_link(address(), portnum(), client_options()) -> {ok, pid()} | {error, term()}.
start_link(Address, Port, Options) when is_list(Options) ->
    gen_server:start_link(?MODULE, [Address, Port, Options], []).

%% @doc Create a process to talk with the riak server on Address:Port.
%%      Client id will be assigned by the server.
-spec start(address(), portnum()) -> {ok, pid()} | {error, term()}.
start(Address, Port) ->
    start(Address, Port, []).

%% @doc Create a process to talk with the riak server on Address:Port with Options.
-spec start(address(), portnum(), client_options()) -> {ok, pid()} | {error, term()}.
start(Address, Port, Options) when is_list(Options) ->
    gen_server:start(?MODULE, [Address, Port, Options], []).

%% @doc Disconnect the socket and stop the process.
-spec stop(pid()) -> ok.
stop(Pid) ->
    call_infinity(Pid, stop).

%% @doc Change the options for this socket.  Allows you to connect with one
%%      set of options then run with another (e.g. connect with no options to
%%      make sure the server is there, then enable queue_if_disconnected).
%% @equiv set_options(Pid, Options, infinity)
%% @see start_link/3
-spec set_options(pid(), client_options()) -> ok.
set_options(Pid, Options) ->
    call_infinity(Pid, {set_options, Options}).

%% @doc Like set_options/2, but with a gen_server timeout.
%% @see start_link/3
%% @deprecated
-spec set_options(pid(), client_options(), timeout()) -> ok.
set_options(Pid, Options, Timeout) ->
    gen_server:call(Pid, {set_options, Options}, Timeout).

%% @doc Determines whether the client is connected. Returns true if
%% connected, or false and a list of connection failures and frequencies if
%% disconnected.
%% @equiv is_connected(Pid, infinity)
-spec is_connected(pid()) -> true | {false, [connection_failure()]}.
is_connected(Pid) ->
    call_infinity(Pid, is_connected).

%% @doc Determines whether the client is connected, with the specified
%% timeout to the client process. Returns true if connected, or false
%% and a list of connection failures and frequencies if disconnected.
%% @see is_connected/1
%% @deprecated
-spec is_connected(pid(), timeout()) -> true | {false, [connection_failure()]}.
is_connected(Pid, Timeout) ->
    gen_server:call(Pid, is_connected, Timeout).

%% @doc Ping the server
%% @equiv ping(Pid, default_timeout(ping_timeout))
-spec ping(pid()) -> pong.
ping(Pid) ->
    call_infinity(Pid, {req, rpbpingreq, default_timeout(ping_timeout)}).

%% @doc Ping the server specifying timeout
-spec ping(pid(), timeout()) -> pong.
ping(Pid, Timeout) ->
    call_infinity(Pid, {req, rpbpingreq, Timeout}).

%% @doc Get the client id for this connection
%% @equiv get_client_id(Pid, default_timeout(get_client_id_timeout))
-spec get_client_id(pid()) -> {ok, client_id()} | {error, term()}.
get_client_id(Pid) ->
    get_client_id(Pid, default_timeout(get_client_id_timeout)).

%% @doc Get the client id for this connection specifying timeout
-spec get_client_id(pid(), timeout()) -> {ok, client_id()} | {error, term()}.
get_client_id(Pid, Timeout) ->
    call_infinity(Pid, {req, rpbgetclientidreq, Timeout}).

%% @doc Set the client id for this connection
%% @equiv set_client_id(Pid, ClientId, default_timeout(set_client_id_timeout))
-spec set_client_id(pid(), client_id()) -> {ok, client_id()} | {error, term()}.
set_client_id(Pid, ClientId) ->
    set_client_id(Pid, ClientId, default_timeout(set_client_id_timeout)).

%% @doc Set the client id for this connection specifying timeout
-spec set_client_id(pid(), client_id(), timeout()) -> {ok, client_id()} | {error, term()}.
set_client_id(Pid, ClientId, Timeout) ->
    call_infinity(Pid,
                  {req, #rpbsetclientidreq{client_id = ClientId},
                   Timeout}).

%% @doc Get the server information for this connection
%% @equiv get_server_info(Pid, default_timeout(get_server_info_timeout))
-spec get_server_info(pid()) -> {ok, server_info()} | {error, term()}.
get_server_info(Pid) ->
    get_server_info(Pid, default_timeout(get_server_info_timeout)).

%% @doc Get the server information for this connection specifying timeout
-spec get_server_info(pid(), timeout()) -> {ok, server_info()} | {error, term()}.
get_server_info(Pid, Timeout) ->
    call_infinity(Pid, {req, rpbgetserverinforeq, Timeout}).

%% @doc Get bucket/key from the server.
%%      Will return {error, notfound} if the key is not on the server.
%% @equiv get(Pid, Bucket, Key, [], default_timeout(get_timeout))
-spec get(pid(), bucket(), key()) -> {ok, riakc_obj()} | {error, term()}.
get(Pid, Bucket, Key) ->
    get(Pid, Bucket, Key, [], default_timeout(get_timeout)).

%% @doc Get bucket/key from the server specifying timeout.
%%      Will return {error, notfound} if the key is not on the server.
%% @equiv get(Pid, Bucket, Key, Options, Timeout)
-spec get(pid(), bucket(), key(), TimeoutOrOptions::timeout() |  get_options()) ->
                 {ok, riakc_obj()} | {error, term()} | unchanged.
get(Pid, Bucket, Key, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    get(Pid, Bucket, Key, [], Timeout);
get(Pid, Bucket, Key, Options) ->
    get(Pid, Bucket, Key, Options, default_timeout(get_timeout)).

%% @doc Get bucket/key from the server supplying options and timeout.
%%      <code>unchanged</code> will be returned when the
%%      <code>{if_modified, Vclock}</code> option is specified and the
%%      object is unchanged.
-spec get(pid(), bucket(), key(), get_options(), timeout()) ->
                 {ok, riakc_obj()} | {error, term()} | unchanged.
get(Pid, Bucket, Key, Options, Timeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = get_options(Options, #rpbgetreq{type =T, bucket = B, key = Key}),
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Put the metadata/value in the object under bucket/key
%% @equiv put(Pid, Obj, [])
%% @see put/4
-spec put(pid(), riakc_obj()) ->
                 ok | {ok, riakc_obj()} | {ok, key()} | {error, term()}.
put(Pid, Obj) ->
    put(Pid, Obj, []).

%% @doc Put the metadata/value in the object under bucket/key with options or timeout.
%% @equiv put(Pid, Obj, Options, Timeout)
%% @see put/4
-spec put(pid(), riakc_obj(), TimeoutOrOptions::timeout() | put_options()) ->
                 ok | {ok, riakc_obj()} |  riakc_obj() | {ok, key()} | {error, term()}.
put(Pid, Obj, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    put(Pid, Obj, [], Timeout);
put(Pid, Obj, Options) ->
    put(Pid, Obj, Options, default_timeout(put_timeout)).

%% @doc Put the metadata/value in the object under bucket/key with
%%      options and timeout. Put throws `siblings' if the
%%      riakc_obj contains siblings that have not been resolved by
%%      calling {@link riakc_obj:select_sibling/2.} or {@link
%%      riakc_obj:update_value/2} and {@link
%%      riakc_obj:update_metadata/2}.  If the object has no key and
%%      the Riak node supports it, `{ok, Key::key()}' will be returned
%%      when the object is created, or `{ok, Obj::riakc_obj()}' if
%%      `return_body' was specified.
%% @throws siblings
%% @end
-spec put(pid(), riakc_obj(), put_options(), timeout()) ->
                 ok | {ok, riakc_obj()} | riakc_obj() | {ok, key()} | {error, term()}.
put(Pid, Obj, Options, Timeout) ->
    Content = riak_pb_kv_codec:encode_content({riakc_obj:get_update_metadata(Obj),
                                               riakc_obj:get_update_value(Obj)}),
    Req = put_options(Options,
                      #rpbputreq{bucket = riakc_obj:only_bucket(Obj),
                                 type = riakc_obj:bucket_type(Obj),
                                 key = riakc_obj:key(Obj),
                                 vclock = riakc_obj:vclock(Obj),
                                 content = Content}),
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Delete the key/value
%% @equiv delete(Pid, Bucket, Key, [])
-spec delete(pid(), bucket(), key()) -> ok | {error, term()}.
delete(Pid, Bucket, Key) ->
    delete(Pid, Bucket, Key, []).

%% @doc Delete the key/value specifying timeout or options. <em>Note that the rw quorum is deprecated, use r and w.</em>
%% @equiv delete(Pid, Bucket, Key, Options, Timeout)
-spec delete(pid(), bucket(), key(), TimeoutOrOptions::timeout() | delete_options()) ->
                    ok | {error, term()}.
delete(Pid, Bucket, Key, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    delete(Pid, Bucket, Key, [], Timeout);
delete(Pid, Bucket, Key, Options) ->
    delete(Pid, Bucket, Key, Options, default_timeout(delete_timeout)).

%% @doc Delete the key/value with options and timeout. <em>Note that the rw quorum is deprecated, use r and w.</em>
-spec delete(pid(), bucket(), key(), delete_options(), timeout()) -> ok | {error, term()}.
delete(Pid, Bucket, Key, Options, Timeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = delete_options(Options, #rpbdelreq{type = T, bucket = B, key = Key}),
    call_infinity(Pid, {req, Req, Timeout}).


%% @doc Delete the object at Bucket/Key, giving the vector clock.
%% @equiv delete_vclock(Pid, Bucket, Key, VClock, [])
-spec delete_vclock(pid(), bucket(), key(), riakc_obj:vclock()) -> ok | {error, term()}.
delete_vclock(Pid, Bucket, Key, VClock) ->
    delete_vclock(Pid, Bucket, Key, VClock, []).

%% @doc Delete the object at Bucket/Key, specifying timeout or options and giving the vector clock.
%% @equiv delete_vclock(Pid, Bucket, Key, VClock, Options, Timeout)
-spec delete_vclock(pid(), bucket(), key(), riakc_obj:vclock(), TimeoutOrOptions::timeout() | delete_options()) ->
                           ok | {error, term()}.
delete_vclock(Pid, Bucket, Key, VClock, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    delete_vclock(Pid, Bucket, Key, VClock, [], Timeout);
delete_vclock(Pid, Bucket, Key, VClock, Options) ->
    delete_vclock(Pid, Bucket, Key, VClock, Options, default_timeout(delete_timeout)).

%% @doc Delete the key/value with options and timeout and giving the
%% vector clock. This form of delete ensures that subsequent get and
%% put requests will be correctly ordered with the delete.
%% @see delete_obj/4
-spec delete_vclock(pid(), bucket(), key(), riakc_obj:vclock(), delete_options(), timeout()) ->
                           ok | {error, term()}.
delete_vclock(Pid, Bucket, Key, VClock, Options, Timeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = delete_options(Options, #rpbdelreq{type = T, bucket = B, key = Key,
            vclock=VClock}),
    call_infinity(Pid, {req, Req, Timeout}).


%% @doc Delete the riak object.
%% @equiv delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj), riakc_obj:vclock(Obj))
%% @see delete_vclock/6
-spec delete_obj(pid(), riakc_obj()) -> ok | {error, term()}.
delete_obj(Pid, Obj) ->
    delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj),
        riakc_obj:vclock(Obj), [], default_timeout(delete_timeout)).

%% @doc Delete the riak object with options.
%% @equiv delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj), riakc_obj:vclock(Obj), Options)
%% @see delete_vclock/6
-spec delete_obj(pid(), riakc_obj(), delete_options()) -> ok | {error, term()}.
delete_obj(Pid, Obj, Options) ->
    delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj),
        riakc_obj:vclock(Obj), Options, default_timeout(delete_timeout)).

%% @doc Delete the riak object with options and timeout.
%% @equiv delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj), riakc_obj:vclock(Obj), Options, Timeout)
%% @see delete_vclock/6
-spec delete_obj(pid(), riakc_obj(), delete_options(), timeout()) -> ok | {error, term()}.
delete_obj(Pid, Obj, Options, Timeout) ->
    delete_vclock(Pid, riakc_obj:bucket(Obj), riakc_obj:key(Obj),
        riakc_obj:vclock(Obj), Options, Timeout).

%% @doc List all buckets on the server.
%% <em>This is a potentially expensive operation and should not be used in production.</em>
%% @equiv list_buckets(Pid, default_timeout(list_buckets_timeout))
-spec list_buckets(pid()) -> {ok, [bucket()]} | {error, term()}.
list_buckets(Pid) ->
    list_buckets(Pid, <<"default">>, []).

%% @doc List all buckets on the server specifying server-side timeout.
%% <em>This is a potentially expensive operation and should not be used in production.</em>
-spec list_buckets(pid(), timeout()|list()|binary()) -> {ok, [bucket()]} |
                                                   {error, term()}.
list_buckets(Pid, Type) when is_binary(Type) ->
    list_buckets(Pid, Type, []);
list_buckets(Pid, Timeout) when is_integer(Timeout) ->
    list_buckets(Pid, <<"default">>, [{timeout, Timeout}]);
list_buckets(Pid, Options) ->
    list_buckets(Pid, <<"default">>, Options).

list_buckets(Pid, Type, Options) when is_binary(Type), is_list(Options) ->
    case stream_list_buckets(Pid, Type, Options) of
        {ok, ReqId} ->
            wait_for_list(ReqId);
        Error ->
            Error
    end.

stream_list_buckets(Pid) ->
    stream_list_buckets(Pid, <<"default">>, []).

stream_list_buckets(Pid, Type) when is_binary(Type) ->
    stream_list_buckets(Pid, Type, []);
stream_list_buckets(Pid, Timeout) when is_integer(Timeout) ->
    stream_list_buckets(Pid, <<"default">>,[{timeout, Timeout}]);
stream_list_buckets(Pid, Options) ->
    stream_list_buckets(Pid, <<"default">>, Options).

stream_list_buckets(Pid, Type, Options) ->
    ServerTimeout =
        case proplists:get_value(timeout, Options, none) of
            none -> ?DEFAULT_PB_TIMEOUT;
            ST -> ST
        end,
    ReqId = mk_reqid(),
    call_infinity(Pid, {req, #rpblistbucketsreq{timeout=ServerTimeout,
                                                  type=Type,
                                                  stream=true},
                          ServerTimeout, {ReqId, self()}}).

legacy_list_buckets(Pid, Options) ->
    ServerTimeout =
        case proplists:get_value(timeout, Options, none) of
            none -> ?DEFAULT_PB_TIMEOUT;
            ST -> ST
        end,
    call_infinity(Pid, {req, #rpblistbucketsreq{timeout=ServerTimeout},
                        ServerTimeout}).


%% @doc List all keys in a bucket
%% <em>This is a potentially expensive operation and should not be used in production.</em>
%% @equiv list_keys(Pid, Bucket, default_timeout(list_keys_timeout))
-spec list_keys(pid(), bucket()) -> {ok, [key()]} | {error, term()}.
list_keys(Pid, Bucket) ->
    list_keys(Pid, Bucket, []).

%% @doc List all keys in a bucket specifying timeout. This is
%% implemented using {@link stream_list_keys/3} and then waiting for
%% the results to complete streaming.
%% <em>This is a potentially expensive operation and should not be used in production.</em>
-spec list_keys(pid(), bucket(), list()|timeout()) -> {ok, [key()]} |
                                                      {error, term()}.
list_keys(Pid, Bucket, infinity) ->
    list_keys(Pid, Bucket, [{timeout, undefined}]);
list_keys(Pid, Bucket, Timeout) when is_integer(Timeout) ->
    list_keys(Pid, Bucket, [{timeout, Timeout}]);
list_keys(Pid, Bucket, Options) ->
    case stream_list_keys(Pid, Bucket, Options) of
        {ok, ReqId} ->
            wait_for_list(ReqId);
        Error ->
            Error
    end.

%% @doc Stream list of keys in the bucket to the calling process.  The
%%      process receives these messages.
%% ```    {ReqId::req_id(), {keys, [key()]}}
%%        {ReqId::req_id(), done}'''
%% <em>This is a potentially expensive operation and should not be used in production.</em>
%% @equiv stream_list_keys(Pid, Bucket, default_timeout(stream_list_keys_timeout))
-spec stream_list_keys(pid(), bucket()) -> {ok, req_id()} | {error, term()}.
stream_list_keys(Pid, Bucket) ->
    stream_list_keys(Pid, Bucket, []).

%% @doc Stream list of keys in the bucket to the calling process specifying server side
%%      timeout.
%%      The process receives these messages.
%% ```    {ReqId::req_id(), {keys, [key()]}}
%%        {ReqId::req_id(), done}'''
%% <em>This is a potentially expensive operation and should not be used in production.</em>
%% @equiv stream_list_keys(Pid, Bucket, Timeout, default_timeout(stream_list_keys_call_timeout))
-spec stream_list_keys(pid(), bucket(), integer()|list()) ->
                              {ok, req_id()} |
                              {error, term()}.
stream_list_keys(Pid, Bucket, infinity) ->
    stream_list_keys(Pid, Bucket, [{timeout, undefined}]);
stream_list_keys(Pid, Bucket, Timeout) when is_integer(Timeout) ->
    stream_list_keys(Pid, Bucket, [{timeout, Timeout}]);
stream_list_keys(Pid, Bucket, Options) ->
    ServerTimeout =
        case proplists:get_value(timeout, Options, none) of
            none -> ?DEFAULT_PB_TIMEOUT;
            ST -> ST
        end,
    {T, B} = maybe_bucket_type(Bucket),
    ReqMsg = #rpblistkeysreq{type = T, bucket = B, timeout = ServerTimeout},
    ReqId = mk_reqid(),
    call_infinity(Pid, {req, ReqMsg, ServerTimeout, {ReqId, self()}}).

%% @doc Get bucket properties.
%% @equiv get_bucket(Pid, Bucket, default_timeout(get_bucket_timeout))
-spec get_bucket(pid(), bucket()) -> {ok, bucket_props()} | {error, term()}.
get_bucket(Pid, Bucket) ->
    get_bucket(Pid, Bucket, default_timeout(get_bucket_timeout)).

%% @doc Get bucket properties specifying a server side timeout.
%% @equiv get_bucket(Pid, Bucket, Timeout, default_timeout(get_bucket_call_timeout))
-spec get_bucket(pid(), bucket(), timeout()) -> {ok, bucket_props()} | {error, term()}.
get_bucket(Pid, Bucket, Timeout) ->
    get_bucket(Pid, Bucket, Timeout, default_timeout(get_bucket_call_timeout)).

%% @doc Get bucket properties specifying a server side and local call timeout.
%% @deprecated because `CallTimeout' is ignored
-spec get_bucket(pid(), bucket(), timeout(), timeout()) -> {ok, bucket_props()} |
                                                           {error, term()}.
get_bucket(Pid, Bucket, Timeout, _CallTimeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = #rpbgetbucketreq{type = T, bucket = B},
    call_infinity(Pid, {req, Req, Timeout}).

get_bucket_type(Pid, BucketType) ->
    get_bucket_type(Pid, BucketType, default_timeout(get_bucket_timeout)).

get_bucket_type(Pid, BucketType, Timeout) ->
    Req = #rpbgetbuckettypereq{type = BucketType},
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Set bucket properties.
%% @equiv set_bucket(Pid, Bucket, BucketProps, default_timeout(set_bucket_timeout))
-spec set_bucket(pid(), bucket(), bucket_props()) -> ok | {error, term()}.
set_bucket(Pid, Bucket, BucketProps) ->
    set_bucket(Pid, Bucket, BucketProps, default_timeout(set_bucket_timeout)).

%% @doc Set bucket properties specifying a server side timeout.
%% @equiv set_bucket(Pid, Bucket, BucketProps, Timeout, default_timeout(set_bucket_call_timeout))
-spec set_bucket(pid(), bucket(), bucket_props(), timeout()) -> ok | {error, term()}.
set_bucket(Pid, Bucket, BucketProps, Timeout) ->
    set_bucket(Pid, Bucket, BucketProps, Timeout,
               default_timeout(set_bucket_call_timeout)).

%% @doc Set bucket properties specifying a server side and local call timeout.
%% @deprecated because `CallTimeout' is ignored
-spec set_bucket(pid(), bucket(), bucket_props(), timeout(), timeout()) -> ok | {error, term()}.
set_bucket(Pid, Bucket, BucketProps, Timeout, _CallTimeout) ->
    PbProps = riak_pb_codec:encode_bucket_props(BucketProps),
    {T, B} = maybe_bucket_type(Bucket),
    Req = #rpbsetbucketreq{type = T, bucket = B, props = PbProps},
    call_infinity(Pid, {req, Req, Timeout}).

set_bucket_type(Pid, BucketType, BucketProps) ->
    set_bucket_type(Pid, BucketType, BucketProps, default_timeout(set_bucket_timeout)).

set_bucket_type(Pid, BucketType, BucketProps, Timeout) ->
    PbProps = riak_pb_codec:encode_bucket_props(BucketProps),
    Req = #rpbsetbuckettypereq{type = BucketType, props = PbProps},
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Reset bucket properties back to the defaults.
%% @equiv reset_bucket(Pid, Bucket, default_timeout(reset_bucket_timeout), default_timeout(reset_bucket_call_timeout))
-spec reset_bucket(pid(), bucket) -> ok | {error, term()}.
reset_bucket(Pid, Bucket) ->
    reset_bucket(Pid, Bucket, default_timeout(reset_bucket_timeout), default_timeout(reset_bucket_call_timeout)).

%% @doc Reset bucket properties back to the defaults.
%% @equiv reset_bucket(Pid, Bucket, Timeout, default_timeout(reset_bucket_call_timeout))
-spec reset_bucket(pid(), bucket, timeout()) -> ok | {error, term()}.
reset_bucket(Pid, Bucket, Timeout) ->
    reset_bucket(Pid, Bucket, Timeout, default_timeout(reset_bucket_call_timeout)).

%% @doc Reset bucket properties back to the defaults.
%% @deprecated because `CallTimeout' is ignored
-spec reset_bucket(pid(), bucket, timeout(), timeout()) -> ok | {error, term()}.
reset_bucket(Pid, Bucket, Timeout, _CallTimeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = #rpbresetbucketreq{type = T, bucket = B},
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Perform a MapReduce job across the cluster.
%%      See the MapReduce documentation for explanation of behavior.
%% @equiv mapred(Inputs, Query, default_timeout(mapred))
-spec mapred(pid(), mapred_inputs(), [mapred_queryterm()]) ->
                    {ok, mapred_result()} |
                    {error, {badqterm, mapred_queryterm()}} |
                    {error, timeout} |
                    {error, term()}.
mapred(Pid, Inputs, Query) ->
    mapred(Pid, Inputs, Query, default_timeout(mapred_timeout)).

%% @doc Perform a MapReduce job across the cluster with a job timeout.
%%      See the MapReduce documentation for explanation of behavior.
%% @equiv mapred(Pid, Inputs, Query, Timeout, default_timeout(mapred_call_timeout))
-spec mapred(pid(), mapred_inputs(), [mapred_queryterm()], timeout()) ->
                    {ok, mapred_result()} |
                    {error, {badqterm, mapred_queryterm()}} |
                    {error, timeout} |
                    {error, term()}.
mapred(Pid, Inputs, Query, Timeout) ->
    mapred(Pid, Inputs, Query, Timeout, default_timeout(mapred_call_timeout)).

%% @doc Perform a MapReduce job across the cluster with a job and
%%      local call timeout.  See the MapReduce documentation for
%%      explanation of behavior. This is implemented by using
%%      <code>mapred_stream/6</code> and then waiting for all results.
%% @see mapred_stream/6
-spec mapred(pid(), mapred_inputs(), [mapred_queryterm()], timeout(), timeout()) ->
                    {ok, mapred_result()} |
                    {error, {badqterm, mapred_queryterm()}} |
                    {error, timeout} |
                    {error, term()}.
mapred(Pid, Inputs, Query, Timeout, CallTimeout) ->
    case mapred_stream(Pid, Inputs, Query, self(), Timeout, CallTimeout) of
        {ok, ReqId} ->
            wait_for_mapred(ReqId, Timeout);
        Error ->
            Error
    end.

%% @doc Perform a streaming MapReduce job across the cluster sending results
%%      to ClientPid.
%%      See the MapReduce documentation for explanation of behavior.
%%      The ClientPid will receive messages in this format:
%% ```  {ReqId::req_id(), {mapred, Phase::non_neg_integer(), mapred_result()}}
%%      {ReqId::req_id(), done}'''
%% @equiv mapred_stream(ConnectionPid, Inputs, Query, ClientPid, default_timeout(mapred_stream_timeout))
-spec mapred_stream(ConnectionPid::pid(),Inputs::mapred_inputs(),Query::[mapred_queryterm()], ClientPid::pid()) ->
                           {ok, req_id()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_stream(Pid, Inputs, Query, ClientPid) ->
    mapred_stream(Pid, Inputs, Query, ClientPid, default_timeout(mapred_stream_timeout)).

%% @doc Perform a streaming MapReduce job with a timeout across the cluster.
%%      sending results to ClientPid.
%%      See the MapReduce documentation for explanation of behavior.
%%      The ClientPid will receive messages in this format:
%% ```  {ReqId::req_id(), {mapred, Phase::non_neg_integer(), mapred_result()}}
%%      {ReqId::req_id(), done}'''
%% @equiv mapred_stream(ConnectionPid, Inputs, Query, ClientPid, Timeout, default_timeout(mapred_stream_call_timeout))
-spec mapred_stream(ConnectionPid::pid(),Inputs::mapred_inputs(),Query::[mapred_queryterm()], ClientPid::pid(), Timeout::timeout()) ->
                           {ok, req_id()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_stream(Pid, Inputs, Query, ClientPid, Timeout) ->
    mapred_stream(Pid, Inputs, Query, ClientPid, Timeout,
                  default_timeout(mapred_stream_call_timeout)).

%% @doc Perform a streaming MapReduce job with a map/red timeout across the cluster,
%%      a local call timeout and sending results to ClientPid.
%%      See the MapReduce documentation for explanation of behavior.
%%      The ClientPid will receive messages in this format:
%% ```  {ReqId::req_id(), {mapred, Phase::non_neg_integer(), mapred_result()}}
%%      {ReqId::req_id(), done}'''
%% @deprecated because `CallTimeout' is ignored
-spec mapred_stream(ConnectionPid::pid(),Inputs::mapred_inputs(),
                    Query::[mapred_queryterm()], ClientPid::pid(),
                    Timeout::timeout(), CallTimeout::timeout()) ->
                           {ok, req_id()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_stream(Pid, {index,Bucket,Name,Key}, Query, ClientPid, Timeout, CallTimeout) when is_tuple(Name) ->
    Index = riakc_obj:index_id_to_bin(Name),
    mapred_stream(Pid, {index,Bucket,Index,Key}, Query, ClientPid, Timeout, CallTimeout);
mapred_stream(Pid, {index,Bucket,Name,StartKey,EndKey}, Query, ClientPid, Timeout, CallTimeout) when is_tuple(Name) ->
    Index = riakc_obj:index_id_to_bin(Name),
    mapred_stream(Pid, {index,Bucket,Index,StartKey,EndKey}, Query, ClientPid, Timeout, CallTimeout);
mapred_stream(Pid, {index,Bucket,Name,Key}, Query, ClientPid, Timeout, CallTimeout) when is_binary(Name) andalso is_integer(Key) ->
    BinKey = list_to_binary(integer_to_list(Key)),
    mapred_stream(Pid, {index,Bucket,Name,BinKey}, Query, ClientPid, Timeout, CallTimeout);
mapred_stream(Pid, {index,Bucket,Name,StartKey,EndKey}, Query, ClientPid, Timeout, CallTimeout) when is_binary(Name) andalso is_integer(StartKey) ->
    BinStartKey = list_to_binary(integer_to_list(StartKey)),
    mapred_stream(Pid, {index,Bucket,Name,BinStartKey,EndKey}, Query, ClientPid, Timeout, CallTimeout);
mapred_stream(Pid, {index,Bucket,Name,StartKey,EndKey}, Query, ClientPid, Timeout, CallTimeout) when is_binary(Name) andalso is_integer(EndKey) ->
    BinEndKey = list_to_binary(integer_to_list(EndKey)),
    mapred_stream(Pid, {index,Bucket,Name,StartKey,BinEndKey}, Query, ClientPid, Timeout, CallTimeout);
mapred_stream(Pid, Inputs, Query, ClientPid, Timeout, _CallTimeout) ->
    MapRed = [{'inputs', Inputs},
              {'query', Query},
              {'timeout', Timeout}],
    send_mapred_req(Pid, MapRed, ClientPid).

%% @doc Perform a MapReduce job against a bucket across the cluster.
%%      See the MapReduce documentation for explanation of behavior.
%% <em>This uses list_keys under the hood and so is potentially an expensive operation that should not be used in production.</em>
%% @equiv mapred_bucket(Pid, Bucket, Query, default_timeout(mapred_bucket_timeout))
-spec mapred_bucket(Pid::pid(), Bucket::bucket(), Query::[mapred_queryterm()]) ->
                           {ok, mapred_result()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_bucket(Pid, Bucket, Query) ->
    mapred_bucket(Pid, Bucket, Query, default_timeout(mapred_bucket_timeout)).

%% @doc Perform a MapReduce job against a bucket with a timeout
%%      across the cluster.
%%      See the MapReduce documentation for explanation of behavior.
%% <em>This uses list_keys under the hood and so is potentially an expensive operation that should not be used in production.</em>
%% @equiv mapred_bucket(Pid, Bucket, Query, Timeout, default_timeout(mapred_bucket_call_timeout))
-spec mapred_bucket(Pid::pid(), Bucket::bucket(), Query::[mapred_queryterm()], Timeout::timeout()) ->
                           {ok, mapred_result()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_bucket(Pid, Bucket, Query, Timeout) ->
    mapred_bucket(Pid, Bucket, Query, Timeout, default_timeout(mapred_bucket_call_timeout)).

%% @doc Perform a MapReduce job against a bucket with a timeout
%%      across the cluster and local call timeout.
%%      See the MapReduce documentation for explanation of behavior.
%% <em>This uses list_keys under the hood and so is potentially an expensive operation that should not be used in production.</em>
-spec mapred_bucket(Pid::pid(), Bucket::bucket(), Query::[mapred_queryterm()],
                    Timeout::timeout(), CallTimeout::timeout()) ->
                           {ok, mapred_result()} |
                           {error, {badqterm, mapred_queryterm()}} |
                           {error, timeout} |
                           {error, Err :: term()}.
mapred_bucket(Pid, Bucket, Query, Timeout, CallTimeout) ->
    case mapred_bucket_stream(Pid, Bucket, Query, self(), Timeout, CallTimeout) of
        {ok, ReqId} ->
            wait_for_mapred(ReqId, Timeout);
        Error ->
            Error
    end.

%% @doc Perform a streaming MapReduce job against a bucket with a timeout
%%      across the cluster.
%%      See the MapReduce documentation for explanation of behavior.
%% <em>This uses list_keys under the hood and so is potentially an expensive operation that should not be used in production.</em>
%%      The ClientPid will receive messages in this format:
%% ```  {ReqId::req_id(), {mapred, Phase::non_neg_integer(), mapred_result()}}
%%      {ReqId::req_id(), done}'''
%% @equiv     mapred_bucket_stream(Pid, Bucket, Query, ClientPid, Timeout, default_timeout(mapred_bucket_stream_call_timeout))
-spec mapred_bucket_stream(ConnectionPid::pid(), bucket(), [mapred_queryterm()], ClientPid::pid(), timeout()) ->
                                  {ok, req_id()} |
                                  {error, term()}.
mapred_bucket_stream(Pid, Bucket, Query, ClientPid, Timeout) ->
    mapred_bucket_stream(Pid, Bucket, Query, ClientPid, Timeout,
                         default_timeout(mapred_bucket_stream_call_timeout)).

%% @doc Perform a streaming MapReduce job against a bucket with a server timeout
%%      across the cluster and a call timeout.
%%      See the MapReduce documentation for explanation of behavior.
%% <em>This uses list_keys under the hood and so is potentially an expensive operation that should not be used in production.</em>
%%      The ClientPid will receive messages in this format:
%% ```  {ReqId::req_id(), {mapred, Phase::non_neg_integer(), mapred_result()}}
%%      {ReqId::req_id(), done}'''
%% @deprecated because `CallTimeout' is ignored
-spec mapred_bucket_stream(ConnectionPid::pid(), bucket(), [mapred_queryterm()], ClientPid::pid(), timeout(), timeout()) ->
                                  {ok, req_id()} | {error, term()}.
mapred_bucket_stream(Pid, Bucket, Query, ClientPid, Timeout, _CallTimeout) ->
    MapRed = [{'inputs', Bucket},
              {'query', Query},
              {'timeout', Timeout}],
    send_mapred_req(Pid, MapRed, ClientPid).


%% @doc Execute a search query. This command will return an error
%%      unless executed against a Riak Search cluster.
-spec search(pid(), binary(), binary()) ->
                    {ok, search_result()} | {error, term()}.
search(Pid, Index, SearchQuery) ->
    search(Pid, Index, SearchQuery, []).

%% @doc Execute a search query. This command will return an error
%%      unless executed against a Riak Search cluster.
-spec search(pid(), binary(), binary(), search_options()) ->
                    {ok, search_result()} | {error, term()}.
search(Pid, Index, SearchQuery, Options) ->
    Timeout = default_timeout(search_timeout),
    search(Pid, Index, SearchQuery, Options, Timeout).

%% @doc Execute a search query. This command will return an error
%%      unless executed against a Riak Search cluster.
-spec search(pid(), binary(), binary(), search_options(), timeout()) ->
                    {ok, search_result()} | {error, term()}.
search(Pid, Index, SearchQuery, Options, Timeout) ->
    CallTimeout = default_timeout(search_call_timeout),
    search(Pid, Index, SearchQuery, Options, Timeout, CallTimeout).

%% @doc Execute a search query. This command will return an error
%%      unless executed against a Riak Search cluster.
%% @deprecated because `CallTimeout' is ignored
-spec search(pid(), binary(), binary(), search_options(), timeout(), timeout()) ->
                    {ok, search_result()} | {error, term()}.
search(Pid, Index, SearchQuery, Options, Timeout, _CallTimeout) ->
    Req = search_options(Options, #rpbsearchqueryreq{q = SearchQuery, index = Index}),
    call_infinity(Pid, {req, Req, Timeout}).

-spec get_search_schema(pid(), binary(), search_admin_opts()) ->
                    {ok, search_schema()} | {error, term()}.
get_search_schema(Pid, SchemaName, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    Req = #rpbyokozunaschemagetreq{ name = SchemaName },
    call_infinity(Pid, {req, Req, Timeout}).

-spec get_search_schema(pid(), binary()) ->
                    {ok, search_schema()} | {error, term()}.
get_search_schema(Pid, SchemaName) ->
    get_search_schema(Pid, SchemaName, []).

-spec get_search_index(pid(), binary(), search_admin_opts()) ->
                    {ok, search_index()} | {error, term()}.
get_search_index(Pid, Index, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    Req = #rpbyokozunaindexgetreq{ name = Index },
    Results = call_infinity(Pid, {req, Req, Timeout}),
    case Results of
        {ok, [Result]} ->
            {ok, Result};
        {ok, []} ->
            {error, notfound};
        X -> X
    end.

-spec get_search_index(pid(), binary()) ->
                    {ok, search_index()} | {error, term()}.
get_search_index(Pid, Index) ->
    get_search_index(Pid, Index, []).

-spec list_search_indexes(pid(), search_admin_opts()) ->
                    {ok, [search_index()]} | {error, term()}.
list_search_indexes(Pid, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    call_infinity(Pid, {req, #rpbyokozunaindexgetreq{}, Timeout}).

-spec list_search_indexes(pid()) ->
                    {ok, [search_index()]} | {error, term()}.
list_search_indexes(Pid) ->
    list_search_indexes(Pid, []).

%% @doc Create a schema, which is a required component of an index.
-spec create_search_schema(pid(), binary(), binary()) ->
                    ok | {error, term()}.
create_search_schema(Pid, SchemaName, Content) ->
    create_search_schema(Pid, SchemaName, Content, []).

%% @doc Create a schema, which is a required component of an index.
-spec create_search_schema(pid(), binary(), binary(), search_admin_opts()) ->
                    ok | {error, term()}.
create_search_schema(Pid, SchemaName, Content, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    Req = #rpbyokozunaschemaputreq{
        schema = #rpbyokozunaschema{name = SchemaName, content = Content}
    },
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc Create a search index.
-spec create_search_index(pid(), binary()) ->
                    ok | {error, term()}.
create_search_index(Pid, Index) ->
    create_search_index(Pid, Index, <<>>, []).

-spec create_search_index(pid(), binary(), timeout() | search_admin_opts()) ->
                                 ok | {error, term()}.
create_search_index(Pid, Index, Timeout)
  when is_integer(Timeout); Timeout =:= infinity ->
    create_search_index(Pid, Index, <<>>, [{timeout, Timeout}]);
create_search_index(Pid, Index, Opts) ->
    create_search_index(Pid, Index, <<>>, Opts).

-spec create_search_index(pid(), binary(), binary(),
                          timeout()|search_admin_opts()) ->
                                 ok | {error, term()}.
create_search_index(Pid, Index, SchemaName, Timeout)
  when is_integer(Timeout); Timeout =:= infinity  ->
    create_search_index(Pid, Index, SchemaName, [{timeout, Timeout}]);
create_search_index(Pid, Index, SchemaName, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    NVal = proplists:get_value(n_val, Opts),
    Req = set_index_create_req_nval(NVal, Index, SchemaName),
    Req1 = set_index_create_req_timeout(Timeout, Req),

    Timeout1 = if
                   is_integer(Timeout) ->
                       %% Add an extra 500ms to the create_search_index timeout
                       %% and use that for the socket timeout.
                       %% This should give the creation process time to throw
                       %% back a proper response.
                       Timeout + 500;
                   true ->
                       Timeout
               end,
    call_infinity(Pid, {req, Req1, Timeout1}).

%% @doc Delete a search index.
-spec delete_search_index(pid(), binary()) ->
                    ok | {error, term()}.
delete_search_index(Pid, Index) ->
    delete_search_index(Pid, Index, []).

%% @doc Delete a search index.
-spec delete_search_index(pid(), binary(), search_admin_opts()) ->
                    ok | {error, term()}.
delete_search_index(Pid, Index, Opts) ->
    Timeout = proplists:get_value(timeout, Opts, default_timeout(search_timeout)),
    Req = #rpbyokozunaindexdeletereq{name = Index},
    call_infinity(Pid, {req, Req, Timeout}).

-spec set_search_index(pid(), bucket(), binary()) ->
                    ok | {error, term()}.
set_search_index(Pid, Bucket, Index) ->
    set_bucket(Pid, Bucket, [{search_index, Index}]).


%% Deprecated, argument explosion functions for indexes

%% @doc Execute a secondary index equality query.
%%
%% @deprecated use {@link get_index_eq/4}
%% @see get_index_eq/4
-spec get_index(pid(), bucket(), binary() | secondary_index_id(), key() | integer()) ->
                       {ok, index_results()} | {error, term()}.
get_index(Pid, Bucket, Index, Key) ->
    get_index_eq(Pid, Bucket, Index, Key).

%% @doc Execute a secondary index equality query with specified
%% timeouts.
%%
%% @deprecated use {@link get_index_eq/5}
%% @see get_index_eq/5
-spec get_index(pid(), bucket(), binary() | secondary_index_id(), key() | integer(), timeout(), timeout()) ->
                       {ok, index_results()} | {error, term()}.
get_index(Pid, Bucket, Index, Key, Timeout, _CallTimeout) ->
    get_index_eq(Pid, Bucket, Index, Key, [{timeout, Timeout}]).

%% @doc Execute a secondary index range query.
%%
%% @deprecated use {@link get_index_range/5}
%% @see get_index_range/5
-spec get_index(pid(), bucket(), binary() | secondary_index_id(), key() | integer(), key() | integer()) ->
                       {ok, index_results()} | {error, term()}.
get_index(Pid, Bucket, Index, StartKey, EndKey) ->
    get_index_range(Pid, Bucket, Index, StartKey, EndKey).

%% @doc Execute a secondary index range query with specified
%% timeouts.
%%
%% @deprecated use {@link get_index_range/6}
%% @see get_index_range/6
-spec get_index(pid(), bucket(), binary() | secondary_index_id(), key() | integer() | list(),
                key() | integer() | list(), timeout(), timeout()) ->
                       {ok, index_results()} | {error, term()}.
get_index(Pid, Bucket, Index, StartKey, EndKey, Timeout, _CallTimeout) ->
    get_index_range(Pid, Bucket, Index, StartKey, EndKey, [{timeout, Timeout}]).

%% @doc Execute a secondary index equality query.
%% equivalent to all defaults for the options.
%% @see get_index_eq/5. for options and their effect
-spec get_index_eq(pid(), bucket(), binary() | secondary_index_id(), key() | integer()) ->
                       {ok, index_results()} | {error, term()}.
get_index_eq(Pid, Bucket, Index, Key) ->
    get_index_eq(Pid, Bucket, Index, Key, []).

%% @doc Execute a secondary index equality query with specified options
%% <dl>
%% <dt>timeout:</dt> <dd>milliseconds to wait for a response from riak</dd>
%% <dt>stream:</dt> <dd> true | false. Stream results to calling process</dd>
%% <dt>continuation:</dt> <dd> The opaque, binary continuation returned from a previous query.
%%                             Requests the next results.</dd>
%% <dt>max_results:</dt> <dd>Positive integer, maximum number of results to return.
%%                           Expect a <code>continuation</code> in the response if this option is used.</dd>
%% </dl>
%% @end
-spec get_index_eq(pid(), bucket(), binary() | secondary_index_id(), key() | integer(), index_opts()) ->
                       {ok, index_results()} | {error, term()}.
get_index_eq(Pid, Bucket, {binary_index, Name}, Key, Opts) when is_binary(Key) ->
    Index = list_to_binary(lists:append([Name, "_bin"])),
    get_index_eq(Pid, Bucket, Index, Key, Opts);
get_index_eq(Pid, Bucket, {integer_index, Name}, Key, Opts) when is_integer(Key) ->
    Index = list_to_binary(lists:append([Name, "_int"])),
    BinKey = list_to_binary(integer_to_list(Key)),
    get_index_eq(Pid, Bucket, Index, BinKey, Opts);
get_index_eq(Pid, Bucket, Index, Key, Opts) ->
    Timeout = proplists:get_value(timeout, Opts),
    MaxResults = proplists:get_value(max_results, Opts),
    PgSort = proplists:get_value(pagination_sort, Opts),
    Stream = proplists:get_value(stream, Opts, false),
    Continuation = proplists:get_value(continuation, Opts),

    {T, B} = maybe_bucket_type(Bucket),

    Req = #rpbindexreq{type=T, bucket=B, index=Index, qtype=eq,
                       key=encode_2i(Key),
                       max_results=MaxResults,
                       pagination_sort=PgSort,
                       stream=Stream,
                       continuation=Continuation,
                       timeout=Timeout},
    Call = case Stream of
               true ->
                   ReqId = mk_reqid(),
                   {req, Req, Timeout, {ReqId, self()}};
               false ->
                   {req, Req, Timeout}
           end,
    call_infinity(Pid, Call).

%% @doc Execute a secondary index range query.
-spec get_index_range(pid(), bucket(), binary() | secondary_index_id(), key() | integer(), key() | integer()) ->
                       {ok, index_results()} | {error, term()}.
get_index_range(Pid, Bucket, Index, StartKey, EndKey) ->
    get_index_range(Pid, Bucket, Index, StartKey, EndKey, []).

%% @doc Execute a secondary index range query with specified options.
%% As well as the options documented for `get_index_eq/5', there is a further options
%% `{return_terms, boolean{}'. When `true' the indexed values will be returned
%% as well as the primary key. The formt of the returned values is
%% `{results, [{value, primary_key}]}'
%% @end
%% @see get_index_eq/5. for effect of options.
-spec get_index_range(pid(), bucket(), binary() | secondary_index_id(), key() | integer() | list(),
                key() | integer() | list(), range_index_opts()) ->
                       {ok, index_results()} | {error, term()}.
get_index_range(Pid, Bucket, {binary_index, Name}, StartKey, EndKey, Opts) when is_binary(StartKey) andalso is_binary(EndKey) ->
    Index = list_to_binary(lists:append([Name, "_bin"])),
    get_index_range(Pid, Bucket, Index, StartKey, EndKey, Opts);
get_index_range(Pid, Bucket, {integer_index, Name}, StartKey, EndKey, Opts) when is_integer(StartKey) andalso is_integer(EndKey) ->
    Index = list_to_binary(lists:append([Name, "_int"])),
    BinStartKey = list_to_binary(integer_to_list(StartKey)),
    BinEndKey = list_to_binary(integer_to_list(EndKey)),
    get_index_range(Pid, Bucket, Index, BinStartKey, BinEndKey, Opts);
get_index_range(Pid, Bucket, Index, StartKey, EndKey, Opts) ->
    Timeout = proplists:get_value(timeout, Opts),
    ReturnTerms = proplists:get_value(return_terms, Opts),
    TermRegex = proplists:get_value(term_regex, Opts),
    MaxResults = proplists:get_value(max_results, Opts),
    PgSort = proplists:get_value(pagination_sort, Opts),
    Stream = proplists:get_value(stream, Opts, false),
    Continuation = proplists:get_value(continuation, Opts),

    {T, B} = maybe_bucket_type(Bucket),

    Req = #rpbindexreq{type=T, bucket=B, index=Index, qtype=range,
                       range_min=encode_2i(StartKey),
                       range_max=encode_2i(EndKey),
                       return_terms=ReturnTerms,
                       term_regex=TermRegex,
                       max_results=MaxResults,
                       pagination_sort = PgSort,
                       stream=Stream,
                       continuation=Continuation,
                       timeout=Timeout},
    Call = case Stream of
               true ->
                   ReqId = mk_reqid(),
                   {req, Req, Timeout, {ReqId, self()}};
               false ->
                   {req, Req, Timeout}
           end,
    call_infinity(Pid, Call).

encode_2i(Value) when is_integer(Value) ->
    list_to_binary(integer_to_list(Value));
encode_2i(Value) when is_list(Value) ->
    list_to_binary(Value);
encode_2i(Value) when is_binary(Value) ->
    Value.

%% @doc secret function, do not use, or I come to your house and keeel you.
-spec cs_bucket_fold(pid(), bucket(), cs_opts()) -> {ok, reference()} | {error, term()}.
cs_bucket_fold(Pid, Bucket, Opts) when is_pid(Pid), (is_binary(Bucket) orelse
                                                     is_tuple(Bucket)), is_list(Opts) ->
    Timeout = proplists:get_value(timeout, Opts),
    StartKey = proplists:get_value(start_key, Opts, <<>>),
    EndKey = proplists:get_value(end_key, Opts),
    MaxResults = proplists:get_value(max_results, Opts),
    StartIncl = proplists:get_value(start_incl, Opts, true),
    EndIncl = proplists:get_value(end_incl, Opts, false),
    Continuation = proplists:get_value(continuation, Opts),

    {T, B} = maybe_bucket_type(Bucket),

    Req = #rpbcsbucketreq{type=T, bucket=B,
                          start_key=StartKey,
                          end_key=EndKey,
                          start_incl=StartIncl,
                          end_incl=EndIncl,
                          max_results=MaxResults,
                          continuation=Continuation,
                          timeout=Timeout},
    ReqId = mk_reqid(),
    Call = {req, Req, Timeout, {ReqId, self()}},
    call_infinity(Pid, Call).

%% @doc Return the default timeout for an operation if none is provided.
%%      Falls back to the default timeout.
-spec default_timeout(timeout_name()) -> timeout().
default_timeout(OpTimeout) ->
    case application:get_env(riakc, OpTimeout) of
        {ok, EnvTimeout} ->
            EnvTimeout;
        undefined ->
            case application:get_env(riakc, timeout) of
                {ok, Timeout} ->
                    Timeout;
                undefined ->
                    ?DEFAULT_PB_TIMEOUT
            end
    end.

%% @doc Send a pre-encoded msg over the protocol buffer connection
%% Returns {ok, Response} or {error, Reason}
-spec tunnel(pid(), msg_id(), iolist(), timeout()) -> {ok, binary()} | {error, term()}.
tunnel(Pid, MsgId, Pkt, Timeout) ->
    Req = {tunneled, MsgId, Pkt},
    call_infinity(Pid, {req, Req, Timeout}).

%% @doc increment the counter at `bucket', `key' by `amount'
-spec counter_incr(pid(), bucket(), key(), integer()) -> ok.
counter_incr(Pid, Bucket, Key, Amount) ->
    counter_incr(Pid, Bucket, Key, Amount, []).

%% @doc increment the counter at `Bucket', `Key' by `Amount'.
%% use the provided `write_quorum()' `Options' for the operation.
%% A counter increment is a lot like a riak `put' so the semantics
%% are the same for the given options.
-spec counter_incr(pid(), bucket(), key(), integer(), [write_quorum()]) ->
    ok | {error, term()}.
counter_incr(Pid, Bucket, Key, Amount, Options) ->
    {_, B} = maybe_bucket_type(Bucket),
    Req = counter_incr_options(Options, #rpbcounterupdatereq{bucket=B, key=Key, amount=Amount}),
    call_infinity(Pid, {req, Req, default_timeout(put_timeout)}).

%% @doc get the current value of the counter at `Bucket', `Key'.
-spec counter_val(pid(), bucket(), key()) ->
                         {ok, integer()} | {error, notfound}.
counter_val(Pid, Bucket, Key) ->
    counter_val(Pid, Bucket, Key, []).

%% @doc get the current value of the counter at `Bucket', `Key' using
%% the `read_qurom()' `Options' provided.
-spec counter_val(pid(), bucket(), key(), [read_quorum()]) ->
                         {ok, integer()} | {error, term()}.
counter_val(Pid, Bucket, Key, Options) ->
    {_, B} = maybe_bucket_type(Bucket),
    Req = counter_val_options(Options, #rpbcountergetreq{bucket=B, key=Key}),
    call_infinity(Pid, {req, Req, default_timeout(get_timeout)}).


%% @doc Fetches the representation of a convergent datatype from Riak.
-spec fetch_type(pid(), {BucketType::binary(), Bucket::binary()}, Key::binary()) ->
                        {ok, riakc_datatype:datatype()} | {error, term()}.
fetch_type(Pid, BucketAndType, Key) ->
    fetch_type(Pid, BucketAndType, Key, []).

%% @doc Fetches the representation of a convergent datatype from Riak,
%% using the given request options.
-spec fetch_type(pid(), {BucketType::binary(), Bucket::binary()}, Key::binary(), [proplists:property()]) ->
                        {ok, riakc_datatype:datatype()} | {error, term()}.
fetch_type(Pid, BucketAndType, Key, Options) ->
    Req = riak_pb_dt_codec:encode_fetch_request(BucketAndType, Key, Options),
    call_infinity(Pid, {req, Req, default_timeout(get_timeout)}).

%% @doc Updates the convergent datatype in Riak with local
%% modifications stored in the container type.
-spec update_type(pid(), {BucketType::binary(), Bucket::binary()}, Key::binary(), Update::riakc_datatype:update(term())) ->
                         ok | {ok, Key::binary()} | {ok, riakc_datatype:datatype()} |
                         {ok, Key::binary(), riakc_datatype:datatype()} | {error, term()}.
update_type(Pid, BucketAndType, Key, Update) ->
    update_type(Pid, BucketAndType, Key, Update, []).

%% @doc Updates the convergent datatype in Riak with local
%% modifications stored in the container type, using the given request
%% options.
-spec update_type(pid(), {BucketType::binary(), Bucket::binary()}, Key::binary(),
                  Update::riakc_datatype:update(term()), [proplists:property()]) ->
                         ok | {ok, Key::binary()} | {ok, riakc_datatype:datatype()} |
                         {ok, Key::binary(), riakc_datatype:datatype()} | {error, term()}.
update_type(_Pid, _BucketAndType, _Key, undefined, _Options) ->
    {error, unmodified};
update_type(Pid, BucketAndType, Key, {Type, Op, Context}, Options) ->
    Req = riak_pb_dt_codec:encode_update_request(BucketAndType, Key, {Type, Op, Context}, Options),
    call_infinity(Pid, {req, Req, default_timeout(put_timeout)}).

%% @doc Fetches, applies the given function to the value, and then
%% updates the datatype in Riak. If an existing value is not found,
%% but you want the updates to apply anyway, use the 'create' option.
-spec modify_type(pid(), fun((riakc_datatype:datatype()) -> riakc_datatype:datatype()),
                  {BucketType::binary(), Bucket::binary()}, Key::binary(), [proplists:property()]) ->
                         ok | {ok, riakc_datatype:datatype()} | {error, term()}.
modify_type(Pid, Fun, BucketAndType, Key, Options) ->
    Create = proplists:get_value(create, Options, true),
    case fetch_type(Pid, BucketAndType, Key, Options) of
        {ok, Data} ->
            NewData = Fun(Data),
            Mod = riakc_datatype:module_for_term(NewData),
            update_type(Pid, BucketAndType, Key, Mod:to_op(NewData), Options);
        {error, {notfound, Type}} when Create ->
            %% Not found, but ok to create it
            Mod = riakc_datatype:module_for_type(Type),
            NewData = Fun(Mod:new()),
            update_type(Pid, BucketAndType, Key, Mod:to_op(NewData), Options);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Get active preflist.
%% @equiv get_preflist(Pid, Bucket, Key, default_timeout(get_preflist_timeout))
-spec get_preflist(pid(), bucket(), key()) -> {ok, preflist()}
                                                 | {error, term()}.
get_preflist(Pid, Bucket, Key) ->
    get_preflist(Pid, Bucket, Key, default_timeout(get_preflist_timeout)).

%% @doc Get active preflist specifying a server side timeout.
%% @equiv get_preflist(Pid, Bucket, Key, default_timeout(get_preflist_timeout))
-spec get_preflist(pid(), bucket(), key(), timeout()) -> {ok, preflist()}
                                                            | {error, term()}.
get_preflist(Pid, Bucket, Key, Timeout) ->
    {T, B} = maybe_bucket_type(Bucket),
    Req = #rpbgetbucketkeypreflistreq{type = T, bucket = B, key = Key},
    call_infinity(Pid, {req, Req, Timeout}).


%% ====================================================================
%% gen_server callbacks
%% ====================================================================

%% @private
init([Address, Port, Options]) ->
    %% Schedule a reconnect as the first action.  If the server is up then
    %% the handle_info(reconnect) will run before any requests can be sent.
    State = parse_options(Options, #state{address = Address,
                                          port = Port,
                                          queue = queue:new()}),
    case connect(State) of
        {error, Reason} when State#state.auto_reconnect /= true ->
            {stop, {tcp, Reason}};
        {error, _Reason} ->
            erlang:send_after(State#state.reconnect_interval, self(), reconnect),
            {ok, State};
        Ok ->
            Ok
    end.

%% @private
handle_call({req, Msg, Timeout}, From, State) when State#state.sock =:= undefined ->
    case State#state.queue_if_disconnected of
        true ->
            {noreply, queue_request(new_request(Msg, From, Timeout), State)};
        false ->
            {reply, {error, disconnected}, State}
    end;
handle_call({req, Msg, Timeout, Ctx}, From, State) when State#state.sock =:= undefined ->
    case State#state.queue_if_disconnected of
        true ->
            {noreply, queue_request(new_request(Msg, From, Timeout, Ctx), State)};
        false ->
            {reply, {error, disconnected}, State}
    end;
handle_call({req, Msg, Timeout}, From, State) when State#state.active =/= undefined ->
    {noreply, queue_request(new_request(Msg, From, Timeout), State)};
handle_call({req, Msg, Timeout, Ctx}, From, State) when State#state.active =/= undefined ->
    {noreply, queue_request(new_request(Msg, From, Timeout, Ctx), State)};
handle_call({req, Msg, Timeout}, From, State) ->
    {noreply, send_request(new_request(Msg, From, Timeout), State)};
handle_call({req, Msg, Timeout, Ctx}, From, State) ->
    {noreply, send_request(new_request(Msg, From, Timeout, Ctx), State)};
handle_call(is_connected, _From, State) ->
    case State#state.sock of
        undefined ->
            {reply, {false, State#state.failed}, State};
        _ ->
            {reply, true, State}
    end;
handle_call({set_options, Options}, _From, State) ->
    {reply, ok, parse_options(Options, State)};
handle_call(stop, _From, State) ->
    _ = disconnect(State),
    {stop, normal, ok, State}.

%% @private
handle_info({tcp_error, _Socket, Reason}, State) ->
    error_logger:error_msg("PBC client TCP error for ~p:~p - ~p\n",
                           [State#state.address, State#state.port, Reason]),
    disconnect(State);

handle_info({tcp_closed, _Socket}, State) ->
    disconnect(State);

handle_info({ssl_error, _Socket, Reason}, State) ->
    error_logger:error_msg("PBC client SSL error for ~p:~p - ~p\n",
                           [State#state.address, State#state.port, Reason]),
    disconnect(State);

handle_info({ssl_closed, _Socket}, State) ->
    disconnect(State);

%% Make sure the two Sock's match.  If a request timed out, but there was
%% a response queued up behind it we do not want to process it.  Instead
%% it should drop through and be ignored.
handle_info({Proto, Sock, Data}, State=#state{sock = Sock, active = Active})
        when Proto == tcp; Proto == ssl ->
    <<MsgCode:8, MsgData/binary>> = Data,
    Resp = case Active#request.msg of
        {tunneled, _MsgID} ->
            %% don't decode tunneled replies, we may not recognize the msgid
            {MsgCode, MsgData};
        _ ->
            riak_pb_codec:decode(MsgCode, MsgData)
    end,
    NewState = case Resp of
        #rpberrorresp{} ->
            NewState1 = maybe_reply(on_error(Active, Resp, State)),
            dequeue_request(NewState1#state{active = undefined});
        _ ->
            case process_response(Active, Resp, State) of
                {reply, Response, NewState0} ->
                    %% Send reply and get ready for the next request - send the next request
                    %% if one is queued up
                    cancel_req_timer(Active#request.tref),
                    _ = send_caller(Response, NewState0#state.active),
                    dequeue_request(NewState0#state{active = undefined});
                {pending, NewState0} -> %% Request is still pending - do not queue up a new one
                    NewActive = restart_req_timer(Active),
                    NewState0#state{active = NewActive}
            end
    end,
    case State#state.transport of
        gen_tcp ->
            ok = inet:setopts(Sock, [{active, once}]);
        ssl ->
            ok = ssl:setopts(Sock, [{active, once}])
    end,
    {noreply, NewState};
handle_info({req_timeout, Ref}, State) ->
    case State#state.active of %%
        undefined ->
            {noreply, remove_queued_request(Ref, State)};
        Active ->
            case Ref == Active#request.ref of
                true ->  %% Matches the current operation
                    NewState = maybe_reply(on_timeout(State#state.active, State)),
                    disconnect(NewState#state{active = undefined});
                false ->
                    {noreply, remove_queued_request(Ref, State)}
            end
    end;
handle_info(reconnect, State) ->
    case connect(State) of
        {ok, NewState} ->
            {noreply, dequeue_request(NewState)};
        {error, Reason} ->
            %% Update the failed count and reschedule a reconnection
            NewState = State#state{failed = orddict:update_counter(Reason, 1, State#state.failed)},
            disconnect(NewState)
    end;
handle_info(_, State) ->
    {noreply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ====================================================================
%% internal functions
%% ====================================================================

%% @private
%% Parse options
parse_options([], State) ->
    %% Once all options are parsed, make sure auto_reconnect is enabled
    %% if queue_if_disconnected is enabled.
    case State#state.queue_if_disconnected of
        true ->
            State#state{auto_reconnect = true};
        _ ->
            State
    end;
parse_options([{connect_timeout, T}|Options], State) when is_integer(T) ->
    parse_options(Options, State#state{connect_timeout = T});
parse_options([{queue_if_disconnected,Bool}|Options], State) when
      Bool =:= true; Bool =:= false ->
    parse_options(Options, State#state{queue_if_disconnected = Bool});
parse_options([queue_if_disconnected|Options], State) ->
    parse_options([{queue_if_disconnected, true}|Options], State);
parse_options([{auto_reconnect,Bool}|Options], State) when
      Bool =:= true; Bool =:= false ->
    parse_options(Options, State#state{auto_reconnect = Bool});
parse_options([auto_reconnect|Options], State) ->
    parse_options([{auto_reconnect, true}|Options], State);
parse_options([{keepalive,Bool}|Options], State) when is_boolean(Bool) ->
    parse_options(Options, State#state{keepalive = Bool});
parse_options([keepalive|Options], State) ->
    parse_options([{keepalive, false}|Options], State);
parse_options([{credentials, User, Pass}|Options], State) ->
    parse_options(Options, State#state{credentials={User, Pass}});
parse_options([{certfile, File}|Options], State) ->
    parse_options(Options, State#state{certfile=File});
parse_options([{cacertfile, File}|Options], State) ->
    parse_options(Options, State#state{cacertfile=File});
parse_options([{keyfile, File}|Options], State) ->
    parse_options(Options, State#state{keyfile=File});
parse_options([{ssl_opts, Opts}|Options], State) ->
    parse_options(Options, State#state{ssl_opts=Opts}).

maybe_reply({reply, Reply, State}) ->
    Request = State#state.active,
    NewRequest = send_caller(Reply, Request),
    State#state{active = NewRequest};
maybe_reply({noreply, State}) ->
    State.

%% @private
%% Reply to caller - form clause first in case a ReqId/Client was passed
%% in as the context and gen_server:reply hasn't been called yet.
send_caller(Msg, #request{ctx = {ReqId, Client},
                          from = undefined}=Request) ->
    Client ! {ReqId, Msg},
    Request;
send_caller(Msg, #request{from = From}=Request) when From /= undefined ->
    gen_server:reply(From, Msg),
    Request#request{from = undefined}.

get_options([], Req) ->
    Req;
get_options([{basic_quorum, BQ} | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{basic_quorum = BQ});
get_options([{notfound_ok, NFOk} | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{notfound_ok = NFOk});
get_options([{r, R} | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{r = riak_pb_kv_codec:encode_quorum(R)});
get_options([{pr, PR} | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{pr = riak_pb_kv_codec:encode_quorum(PR)});
get_options([{timeout, T} | Rest], Req) when is_integer(T)->
    get_options(Rest, Req#rpbgetreq{timeout = T});
get_options([{timeout, _T} | _Rest], _Req) ->
    erlang:error(badarg);
get_options([{if_modified, VClock} | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{if_modified = VClock});
get_options([head | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{head = true});
get_options([deletedvclock | Rest], Req) ->
    get_options(Rest, Req#rpbgetreq{deletedvclock = true});
get_options([{n_val, N} | Rest], Req)
  when is_integer(N), N > 0 ->
    get_options(Rest, Req#rpbgetreq{n_val = N});
get_options([{sloppy_quorum, Bool} | Rest], Req)
  when Bool == true; Bool == false ->
    get_options(Rest, Req#rpbgetreq{sloppy_quorum = Bool});
get_options([{_, _} | _Rest], _Req) ->
    erlang:error(badarg).

put_options([], Req) ->
    Req;
put_options([{w, W} | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{w = riak_pb_kv_codec:encode_quorum(W)});
put_options([{dw, DW} | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{dw = riak_pb_kv_codec:encode_quorum(DW)});
put_options([{pw, PW} | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{pw = riak_pb_kv_codec:encode_quorum(PW)});
put_options([{timeout, T} | Rest], Req) when is_integer(T) ->
    put_options(Rest, Req#rpbputreq{timeout = T});
put_options([{timeout, _T} | _Rest], _Req) ->
    erlang:error(badarg);
put_options([return_body | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{return_body = 1});
put_options([return_head | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{return_head = true});
put_options([if_not_modified | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{if_not_modified = true});
put_options([if_none_match | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{if_none_match = true});
put_options([asis | Rest], Req) ->
    put_options(Rest, Req#rpbputreq{asis = true});
put_options([{asis, Val} | Rest], Req) when is_boolean(Val) ->
    put_options(Rest, Req#rpbputreq{asis = Val});
put_options([{n_val, N} | Rest], Req)
  when is_integer(N), N > 0 ->
    put_options(Rest, Req#rpbputreq{n_val = N});
put_options([{sloppy_quorum, Bool} | Rest], Req)
  when Bool == true; Bool == false ->
    put_options(Rest, Req#rpbputreq{sloppy_quorum = Bool});
put_options([{_, _} | _Rest], _Req) ->
    erlang:error(badarg).


delete_options([], Req) ->
    Req;
delete_options([{rw, RW} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{rw = riak_pb_kv_codec:encode_quorum(RW)});
delete_options([{r, R} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{r = riak_pb_kv_codec:encode_quorum(R)});
delete_options([{w, W} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{w = riak_pb_kv_codec:encode_quorum(W)});
delete_options([{pr, PR} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{pr = riak_pb_kv_codec:encode_quorum(PR)});
delete_options([{pw, PW} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{pw = riak_pb_kv_codec:encode_quorum(PW)});
delete_options([{dw, DW} | Rest], Req) ->
    delete_options(Rest, Req#rpbdelreq{dw = riak_pb_kv_codec:encode_quorum(DW)});
delete_options([{timeout, T} | Rest], Req) when is_integer(T) ->
    delete_options(Rest, Req#rpbdelreq{timeout = T});
delete_options([{timeout, _T} | _Rest], _Req) ->
    erlang:error(badarg);
delete_options([{n_val, N} | Rest], Req)
  when is_integer(N), N > 0 ->
    delete_options(Rest, Req#rpbdelreq{n_val = N});
delete_options([{sloppy_quorum, Bool} | Rest], Req)
  when Bool == true; Bool == false ->
    delete_options(Rest, Req#rpbdelreq{sloppy_quorum = Bool});
delete_options([{_, _} | _Rest], _Req) ->
    erlang:error(badarg).

search_options([], Req) ->
    Req;
search_options([{rows, Rows} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{rows=Rows});
search_options([{start, Start} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{start=Start});
search_options([{sort, Sort} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{sort=Sort});
search_options([{filter, Filter} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{filter=Filter});
search_options([{df, DF} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{df=DF});
search_options([{op, OP} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{op=OP});
search_options([{fl, FL} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{fl=FL});
search_options([{presort, Presort} | Rest], Req) ->
    search_options(Rest, Req#rpbsearchqueryreq{presort=Presort});
search_options([{_, _} | _Rest], _Req) ->
    erlang:error(badarg).

counter_incr_options([], Req) ->
    Req;
counter_incr_options([{w, W} | Rest], Req) ->
    counter_incr_options(Rest, Req#rpbcounterupdatereq{w=riak_pb_kv_codec:encode_quorum(W)});
counter_incr_options([{dw, DW} | Rest], Req) ->
    counter_incr_options(Rest, Req#rpbcounterupdatereq{dw=riak_pb_kv_codec:encode_quorum(DW)});
counter_incr_options([{pw, PW} | Rest], Req) ->
    counter_incr_options(Rest, Req#rpbcounterupdatereq{pw=riak_pb_kv_codec:encode_quorum(PW)});
counter_incr_options([returnvalue | Rest], Req) ->
    counter_incr_options(Rest, Req#rpbcounterupdatereq{returnvalue=true});
counter_incr_options([_ | _Rest], _Req) ->
    erlang:error(badarg).

counter_val_options([], Req) ->
    Req;
counter_val_options([{basic_quorum, BQ} | Rest], Req) ->
    counter_val_options(Rest, Req#rpbcountergetreq{basic_quorum=BQ});
counter_val_options([{notfound_ok, NFOK} | Rest], Req) ->
    counter_val_options(Rest, Req#rpbcountergetreq{notfound_ok=NFOK});
counter_val_options([{r, R} | Rest], Req) ->
    counter_val_options(Rest, Req#rpbcountergetreq{r=riak_pb_kv_codec:encode_quorum(R)});
counter_val_options([{pr, PR} | Rest], Req) ->
    counter_val_options(Rest, Req#rpbcountergetreq{pr=riak_pb_kv_codec:encode_quorum(PR)});
counter_val_options([_ | _Rest], _Req) ->
    erlang:error(badarg).

%% Process response from the server - passes back in the request and
%% context the request was issued with.
%% Return noreply if the request is completed, but no reply needed
%%        reply if the request is completed with a reply to the caller
%%        pending if the request has not completed yet (streaming op)
%% @private
-spec process_response(#request{}, rpb_resp(), #state{}) ->
                              {reply, term(), #state{}} |
                              {pending, #state{}}.
process_response(#request{msg = rpbpingreq}, rpbpingresp, State) ->
    {reply, pong, State};
process_response(#request{msg = rpbgetclientidreq},
                 #rpbgetclientidresp{client_id = ClientId}, State) ->
    {reply, {ok, ClientId}, State};
process_response(#request{msg = #rpbsetclientidreq{}},
                 rpbsetclientidresp, State) ->
    {reply, ok, State};
process_response(#request{msg = rpbgetserverinforeq},
                 #rpbgetserverinforesp{node = Node, server_version = ServerVersion}, State) ->
    NodeInfo = case Node of
        undefined ->
            [];
        Node ->
            [{node, Node}]
    end,
    VersionInfo = case ServerVersion of
        undefined ->
            [];
        ServerVersion ->
            [{server_version, ServerVersion}]
    end,
    {reply, {ok, NodeInfo++VersionInfo}, State};
process_response(#request{msg = #rpbgetreq{}}, rpbgetresp, State) ->
    %% server just returned the rpbgetresp code - no message was encoded
    {reply, {error, notfound}, State};
process_response(#request{msg = #rpbgetreq{deletedvclock=true}},
                 #rpbgetresp{vclock=VC, content=[]}, State) ->
    %% server returned a notfound with a vector clock, meaning a tombstone
    {reply, {error, notfound, VC}, State};
process_response(#request{msg = #rpbgetreq{}}, #rpbgetresp{unchanged=true}, State) ->
    %% object was unchanged
    {reply, unchanged, State};
process_response(#request{msg = #rpbgetreq{type = Type, bucket = Bucket, key = Key}},
                 #rpbgetresp{content = RpbContents, vclock = Vclock}, State) ->
    Contents = riak_pb_kv_codec:decode_contents(RpbContents),
    B = maybe_make_bucket_type(Type, Bucket),
    {reply, {ok, riakc_obj:new_obj(B, Key, Vclock, Contents)}, State};

process_response(#request{msg = #rpbputreq{}},
                 rpbputresp, State) ->
    %% server just returned the rpbputresp code - no message was encoded
    {reply, ok, State};
process_response(#request{ msg = #rpbputreq{}},
                 #rpbputresp{key = Key, content=undefined, vclock=undefined},
                 State) when is_binary(Key) ->
    %% server generated a key and the client didn't request return_body, but
    %% the created key is returned
    {reply, {ok, Key}, State};
process_response(#request{msg = #rpbputreq{type = Type, bucket = Bucket, key = Key}},
                 #rpbputresp{content = RpbContents, vclock = Vclock,
                             key = NewKey}, State) ->
    Contents = riak_pb_kv_codec:decode_contents(RpbContents),
    ReturnKey = case NewKey of
                    undefined -> Key;
                    _ -> NewKey
                end,
    B = maybe_make_bucket_type(Type, Bucket),
    {reply, {ok, riakc_obj:new_obj(B, ReturnKey, Vclock, Contents)}, State};

process_response(#request{msg = #rpbdelreq{}},
                 rpbdelresp, State) ->
    %% server just returned the rpbdelresp code - no message was encoded
    {reply, ok, State};

process_response(#request{msg = #rpblistbucketsreq{}}=Request,
                 #rpblistbucketsresp{buckets = Buckets, done = undefined},
                 State) ->
    _ = send_caller({buckets, Buckets}, Request),
    {pending, State};

process_response(#request{msg = #rpblistbucketsreq{}},
                 #rpblistbucketsresp{done = true},
                 State) ->
    {reply, done, State};

process_response(#request{msg = #rpblistkeysreq{}}=Request,
                 #rpblistkeysresp{done = Done, keys = Keys}, State) ->
    _ = case Keys of
            undefined ->
                ok;
            _ ->
                %% Have to directly use send_caller as may want to reply with done below.
                send_caller({keys, Keys}, Request)
        end,
    case Done of
        true ->
            {reply, done, State};
        _ ->
            {pending, State}
    end;

process_response(#request{msg = #rpbgetbucketreq{}},
                 #rpbgetbucketresp{props = PbProps}, State) ->
    Props = riak_pb_codec:decode_bucket_props(PbProps),
    {reply, {ok, Props}, State};

process_response(#request{msg = #rpbgetbuckettypereq{}},
                 #rpbgetbucketresp{props = PbProps}, State) ->
    Props = riak_pb_codec:decode_bucket_props(PbProps),
    {reply, {ok, Props}, State};

process_response(#request{msg = #rpbsetbucketreq{}},
                 rpbsetbucketresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbsetbuckettypereq{}},
                 rpbsetbucketresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbmapredreq{content_type = ContentType}}=Request,
                 #rpbmapredresp{done = Done, phase=PhaseId, response=Data}, State) ->
    _ = case Data of
            undefined ->
                ok;
            _ ->
                Response = decode_mapred_resp(Data, ContentType),
                send_caller({mapred, PhaseId, Response}, Request)
        end,
    case Done of
        true ->
            {reply, done, State};
        _ ->
            {pending, State}
    end;

process_response(#request{msg = #rpbindexreq{}}, rpbindexresp, State) ->
    Results = ?INDEX_RESULTS{keys=[], continuation=undefined},
    {reply, {ok, Results}, State};
process_response(#request{msg = #rpbindexreq{stream=true, return_terms=Terms}}=Request,
                 #rpbindexresp{results=Results, keys=Keys, done=Done, continuation=Cont}, State) ->
    ToSend = process_index_response(Terms, Keys, Results),
    _ = send_caller(ToSend, Request),
    DoneResponse = {reply, {done, Cont}, State},
    case Done of
                true -> DoneResponse;
                _ -> {pending, State}
    end;
process_response(#request{msg = #rpbindexreq{return_terms=Terms}}, #rpbindexresp{results=Results, keys=Keys, continuation=Cont}, State) ->
    StreamResponse = process_index_response(Terms, Keys, Results),
    RegularResponse = index_stream_result_to_index_result(StreamResponse),
    RegularResponseWithContinuation = RegularResponse?INDEX_RESULTS{continuation=Cont},
    {reply, {ok, RegularResponseWithContinuation}, State};
process_response(#request{msg = #rpbcsbucketreq{}}, rpbcsbucketresp, State) ->
    {pending, State};
process_response(#request{msg = #rpbcsbucketreq{bucket=Bucket}}=Request, #rpbcsbucketresp{objects=Objects, done=Done, continuation=Cont}, State) ->
    %% TEMP - cs specific message for fold_objects
    ToSend =  case Objects of
                  undefined -> {ok, []};
                  _ ->
                      %% make client objects
                      CObjects = lists:foldr(fun(#rpbindexobject{key=Key,
                                                                 object=#rpbgetresp{content=Contents, vclock=VClock}}, Acc) ->
                                                     DContents = riak_pb_kv_codec:decode_contents(Contents),
                                                     [riakc_obj:new_obj(Bucket, Key, VClock, DContents) | Acc] end,
                                             [],
                                             Objects),
                      {ok, CObjects}
              end,
    _ = send_caller(ToSend, Request),
    DoneResponse = {reply, {done, Cont}, State},
    case Done of
        true -> DoneResponse;
        _ -> {pending, State}
    end;
process_response(#request{msg = #rpbsearchqueryreq{}}, prbsearchqueryresp, State) ->
    {reply, {error, notfound}, State};
process_response(#request{msg = #rpbsearchqueryreq{index=Index}},
                 #rpbsearchqueryresp{docs=PBDocs,max_score=MaxScore,
                                     num_found=NumFound}, State) ->
    Values = [ {Index, [ riak_pb_codec:decode_pair(Field) || Field <- Doc#rpbsearchdoc.fields] }
               || Doc <- PBDocs ],
    Result = #search_results{docs=Values, max_score=MaxScore, num_found=NumFound},
    {reply, {ok, Result}, State};

process_response(#request{msg=#rpbresetbucketreq{}}, rpbresetbucketresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbcounterupdatereq{returnvalue=true}},
                 #rpbcounterupdateresp{value=Value}, State) ->
    {reply, {ok, Value}, State};
process_response(#request{msg = #rpbcounterupdatereq{}},
                 rpbcounterupdateresp, State) ->
    %% server just returned the rpbcounterupdateresp code - no message was encoded
    {reply, ok, State};
process_response(#request{msg = #rpbcountergetreq{}},
                 rpbcountergetresp, State) ->
    {reply, {error, notfound}, State};
process_response(#request{msg = #rpbcountergetreq{}},
                 #rpbcountergetresp{value=Value}, State) ->
    {reply, {ok, Value}, State};

process_response(#request{msg = #dtfetchreq{}}, #dtfetchresp{}=Resp,
                 State) ->
    Reply = case riak_pb_dt_codec:decode_fetch_response(Resp) of
                {Type, Value, Context}  ->
                    Mod = riakc_datatype:module_for_type(Type),
                    {ok, Mod:new(Value, Context)};
                {notfound, _Type}=NF ->
                    {error, NF}
            end,
    {reply, Reply, State};

process_response(#request{msg = #dtupdatereq{}},
                 dtupdateresp,
                 State) ->
    {reply, ok, State};

process_response(#request{msg = #dtupdatereq{op=Op, return_body=RB}},
                 #dtupdateresp{}=Resp,
                 State) ->
    OpType = riak_pb_dt_codec:operation_type(Op),
    Reply = case riak_pb_dt_codec:decode_update_response(Resp, OpType, RB) of
                ok -> ok;
                {ok, Key} -> {ok, Key};
                {OpType, Value, Context} ->
                    Mod = riakc_datatype:module_for_type(OpType),
                    {ok, Mod:new(Value, Context)};
                {Key, {OpType, Value, Context}} when is_binary(Key) ->
                    Mod = riakc_datatype:module_for_type(OpType),
                    {ok, Key, Mod:new(Value, Context)}
            end,
    {reply, Reply, State};

process_response(#request{msg={tunneled,_MsgId}}, Reply, State) ->
    %% Tunneled msg response
    {reply, {ok, Reply}, State};

process_response(#request{msg = #rpbyokozunaschemaputreq{}},
                 rpbputresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbyokozunaindexputreq{}},
                 rpbputresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbyokozunaindexdeletereq{}},
                 rpbdelresp, State) ->
    {reply, ok, State};

process_response(#request{msg = #rpbyokozunaindexgetreq{}},
                 rpbyokozunaindexgetresp, State) ->
    {reply, {ok, []}, State};

process_response(#request{msg = #rpbyokozunaindexgetreq{}},
                 #rpbyokozunaindexgetresp{index=Indexes}, State) ->
    Results = [[{index,Index#rpbyokozunaindex.name},
                {schema,Index#rpbyokozunaindex.schema},
                {n_val,Index#rpbyokozunaindex.n_val}]
        || Index <- Indexes ],
    {reply, {ok, Results}, State};

process_response(#request{msg = #rpbyokozunaschemagetreq{}},
                 #rpbyokozunaschemagetresp{schema=Schema}, State) ->
    Result = [{name,Schema#rpbyokozunaschema.name}, {content,Schema#rpbyokozunaschema.content}],
    {reply, {ok, Result}, State};

process_response(#request{msg = #rpbgetbucketkeypreflistreq{}},
                 #rpbgetbucketkeypreflistresp{preflist=Preflist}, State) ->
    Result = [#preflist_item{partition=T#rpbbucketkeypreflistitem.partition,
                             node=T#rpbbucketkeypreflistitem.node,
                             primary=T#rpbbucketkeypreflistitem.primary}
              || T <- Preflist],
    {reply, {ok, Result}, State};

process_response(Request, Reply, State) ->
    %% Unknown request/response combo
    {reply, {error, {unknown_response, Request, Reply}}, State}.

%% Helper for index responses
-spec process_index_response(undefined | boolean(), list(), list()) ->
    index_stream_result().
process_index_response(undefined, Keys, _) ->
    ?INDEX_STREAM_RESULT{keys=Keys};
process_index_response(false, Keys, _) ->
    ?INDEX_STREAM_RESULT{keys=Keys};
process_index_response(true, [], Results) ->
    %% rpbpair is abused to send Value,Key pairs as Key, Value pairs
    %% in a 2i query the 'key' is the index value and the 'value'
    %% the indexed objects primary key
    Res = [{V, K} ||  #rpbpair{key=V, value=K} <- Results],
    ?INDEX_STREAM_RESULT{terms=Res};
process_index_response(true, Keys, []) ->
    ?INDEX_STREAM_RESULT{keys=Keys}.

-spec index_stream_result_to_index_result(index_stream_result()) ->
    index_results().
index_stream_result_to_index_result(?INDEX_STREAM_RESULT{keys=Keys,
                                                         terms=Terms}) ->
    ?INDEX_RESULTS{keys=Keys,
                   terms=Terms}.

%% Called after sending a message - supports returning a
%% request id for streaming calls
%% @private
after_send(#request{msg = #rpblistbucketsreq{}, ctx = {ReqId, _Client}},
           State) ->
    {reply, {ok, ReqId}, State};
after_send(#request{msg = #rpblistkeysreq{}, ctx = {ReqId, _Client}}, State) ->
    {reply, {ok, ReqId}, State};
after_send(#request{msg = #rpbmapredreq{}, ctx = {ReqId, _Client}}, State) ->
    {reply, {ok, ReqId}, State};
after_send(#request{msg = #rpbindexreq{stream=true}, ctx = {ReqId, _Client}}, State) ->
    {reply, {ok, ReqId}, State};
after_send(#request{msg = #rpbcsbucketreq{}, ctx = {ReqId, _Client}}, State) ->
    {reply, {ok, ReqId}, State};
after_send(_Request, State) ->
    {noreply, State}.

%% Called on timeout for an operation
%% @private
on_timeout(_Request, State) ->
    {reply, {error, timeout}, State}.
%%
%% Called after receiving an error message - supports reruning
%% an error for streaming calls
%% @private
on_error(_Request, ErrMsg, State) ->
    {reply, fmt_err_msg(ErrMsg), State}.

%% Format the PB encoded error message
fmt_err_msg(ErrMsg) ->
    case ErrMsg#rpberrorresp.errcode of
        Code when Code =:= 0; Code =:= 1; Code =:= undefined ->
            {error, ErrMsg#rpberrorresp.errmsg};
        Code ->
            {error, {Code, ErrMsg#rpberrorresp.errmsg}}
    end.

%% deliberately crash if the handling an error response after
%% the client has been replied to

%% Common code for sending a single bucket or multiple inputs map/request
%% @private
send_mapred_req(Pid, MapRed, ClientPid) ->
    ReqMsg = #rpbmapredreq{request = encode_mapred_req(MapRed),
                           content_type = <<"application/x-erlang-binary">>},
    ReqId = mk_reqid(),
    Timeout = proplists:get_value(timeout, MapRed, default_timeout(mapred_timeout)),
    Timeout1 = if
           is_integer(Timeout) ->
               %% Add an extra 100ms to the mapred timeout and use that
               %% for the socket timeout. This should give the
               %% map/reduce a chance to fail and let us know.
               Timeout + 100;
           true ->
               Timeout
           end,
    call_infinity(Pid, {req, ReqMsg, Timeout1, {ReqId, ClientPid}}).

%% @private
%% Make a new request that can be sent or queued
new_request(Msg, From, Timeout) ->
    Ref = make_ref(),
    #request{ref = Ref, msg = Msg, from = From, timeout = Timeout,
             tref = create_req_timer(Timeout, Ref)}.
new_request(Msg, From, Timeout, Context) ->
    Ref = make_ref(),
    #request{ref =Ref, msg = Msg, from = From, ctx = Context, timeout = Timeout,
             tref = create_req_timer(Timeout, Ref)}.

%% @private
%% Create a request timer if desired, otherwise return undefined.
create_req_timer(infinity, _Ref) ->
    undefined;
create_req_timer(undefined, _Ref) ->
    undefined;
create_req_timer(Msecs, Ref) ->
    erlang:send_after(Msecs, self(), {req_timeout, Ref}).

%% @private
%% Cancel a request timer made by create_timer/2
cancel_req_timer(undefined) ->
    ok;
cancel_req_timer(Tref) ->
    _ = erlang:cancel_timer(Tref),
    ok.

%% @private
%% Restart a request timer
-spec restart_req_timer(#request{}) -> #request{}.
restart_req_timer(Request) ->
    case Request#request.tref of
        undefined ->
            Request;
        Tref ->
            cancel_req_timer(Tref),
            NewTref = create_req_timer(Request#request.timeout,
                                       Request#request.ref),
            Request#request{tref = NewTref}
    end.

%% @private
%% Connect the socket if disconnected
connect(State) when State#state.sock =:= undefined ->
    #state{address = Address, port = Port, connects = Connects} = State,
    case gen_tcp:connect(Address, Port,
                         [binary, {active, once}, {packet, 4},
                          {keepalive, State#state.keepalive}],
                         State#state.connect_timeout) of
        {ok, Sock} ->
            State1 = State#state{sock = Sock, connects = Connects+1,
                                 reconnect_interval = ?FIRST_RECONNECT_INTERVAL},
            case State#state.credentials of
                undefined ->
                    {ok, State1};
                _ ->
                    start_tls(State1)
            end;
        Error ->
            Error
    end.

-spec start_tls(#state{}) -> {ok, #state{}} | {error, term()}.
start_tls(State=#state{sock=Sock}) ->
    %% Send STARTTLS
    StartTLSCode = riak_pb_codec:msg_code(rpbstarttls),
    ok = gen_tcp:send(Sock, <<StartTLSCode:8>>),
    receive
        {tcp_error, Sock, Reason} ->
            {error, Reason};
        {tcp_closed, Sock} ->
            {error, closed};
        {tcp, Sock, Data} ->
            <<MsgCode:8, MsgData/binary>> = Data,
            case riak_pb_codec:decode(MsgCode, MsgData) of
                rpbstarttls ->
                    Options = [{verify, verify_peer},
                               {cacertfile, State#state.cacertfile}] ++
                              [{K, V} || {K, V} <- [{certfile,
                                                     State#state.certfile},
                                                    {keyfile,
                                                     State#state.keyfile}],
                                         V /= undefined] ++
                              State#state.ssl_opts,
                    case ssl:connect(Sock, Options, 1000) of
                        {ok, SSLSock} ->
                            ok = ssl:setopts(SSLSock, [{active, once}]),
                            start_auth(State#state{sock=SSLSock, transport=ssl});
                        {error, Reason2} ->
                            {error, Reason2}
                    end;
                #rpberrorresp{} ->
                    %% Server doesn't know about STARTTLS or security is
                    %% disabled. We can't fall back to the regular old
                    %% protocol here because then SSL could be stripped by a
                    %% man-in-the-middle proxy that presents insecure
                    %% communication to the client, but does secure
                    %% communication to the server.
                    {error, no_security}
            end
    end.

start_auth(State=#state{credentials={User,Pass}, sock=Sock}) ->
    ok = ssl:send(Sock, riak_pb_codec:encode(#rpbauthreq{user=User,
                                                         password=Pass})),
    receive
        {ssl_error, Sock, Reason} ->
            {error, Reason};
        {ssl_closed, Sock} ->
            {error, closed};
        {ssl, Sock, Data} ->
            <<MsgCode:8, MsgData/binary>> = Data,
            case riak_pb_codec:decode(MsgCode, MsgData) of
                rpbauthresp ->
                    ok = ssl:setopts(Sock, [{active, once}]),
                    {ok, State};
                #rpberrorresp{} = Err ->
                    fmt_err_msg(Err)
            end
    end.

%% @private
%% Disconnect socket if connected
disconnect(State) ->
    %% Tell any pending requests we've disconnected
    _ = case State#state.active of
            undefined ->
                ok;
            Request ->
                send_caller({error, disconnected}, Request)
        end,

    %% Make sure the connection is really closed
    case State#state.sock of
        undefined ->
            ok;
        Sock ->
            Transport = State#state.transport,
            Transport:close(Sock)
    end,

    %% Decide whether to reconnect or exit
    NewState = State#state{sock = undefined, active = undefined},
    case State#state.auto_reconnect of
        true ->
            %% Schedule the reconnect message and return state
            erlang:send_after(State#state.reconnect_interval, self(), reconnect),
            {noreply, increase_reconnect_interval(NewState)};
        false ->
            {stop, disconnected, NewState}
    end.

%% Double the reconnect interval up to the maximum
increase_reconnect_interval(State) ->
    case State#state.reconnect_interval of
        Interval when Interval < ?MAX_RECONNECT_INTERVAL ->
            NewInterval = min(Interval+Interval, ?MAX_RECONNECT_INTERVAL),
            State#state{reconnect_interval = NewInterval};
        _ ->
            State
    end.

%% Send a request to the server and prepare the state for the response
%% @private
send_request(Request0, State) when State#state.active =:= undefined ->
    {Request, Pkt} = encode_request_message(Request0),
    Transport = State#state.transport,
    case Transport:send(State#state.sock, Pkt) of
        ok ->
            maybe_reply(after_send(Request, State#state{active = Request}));
        {error, Reason} ->
            error_logger:warning_msg("Socket error while sending riakc request: ~p.", [Reason]),
            Transport:close(State#state.sock),
            maybe_enqueue_and_reconnect(Request, State#state{sock=undefined})
    end.

%% Already encoded (for tunneled messages), but must provide Message Id
%% for responding to the second form of send_request.
encode_request_message(#request{msg={tunneled,MsgId,Pkt}}=Req) ->
    {Req#request{msg={tunneled,MsgId}},[MsgId|Pkt]};
%% Unencoded Request (the normal PB client path)
encode_request_message(#request{msg=Msg}=Req) ->
    {Req, riak_pb_codec:encode(Msg)}.

%% If the socket was closed, see if we can enqueue the request and
%% trigger a reconnect. Otherwise, return an error to the requestor.
maybe_enqueue_and_reconnect(Request, State) ->
    maybe_reconnect(State),
    enqueue_or_reply_error(Request, State).

%% Trigger an immediate reconnect if automatic reconnection is
%% enabled.
maybe_reconnect(#state{auto_reconnect=true}) -> self() ! reconnect;
maybe_reconnect(_) -> ok.

%% If we can queue while disconnected, do so, otherwise tell the
%% caller that the socket was disconnected.
enqueue_or_reply_error(Request, #state{queue_if_disconnected=true}=State) ->
    queue_request(Request, State);
enqueue_or_reply_error(Request, State) ->
    _ = send_caller({error, disconnected}, Request),
    State.

%% Queue up a request if one is pending
%% @private
queue_request(Request, State) ->
    State#state{queue = queue:in(Request, State#state.queue)}.

%% Try and dequeue request and send onto the server if one is waiting
%% @private
dequeue_request(State) ->
    case queue:out(State#state.queue) of
        {empty, _} ->
            State;
        {{value, Request}, Q2} ->
            send_request(Request, State#state{queue = Q2})
    end.

%% Remove a queued request by reference - returns same queue if ref not present
%% @private
remove_queued_request(Ref, State) ->
    L = queue:to_list(State#state.queue),
    case lists:keytake(Ref, #request.ref, L) of
        false -> % Ref not queued up
            State;
        {value, Req, L2} ->
            {reply, Reply, NewState} = on_timeout(Req, State),
            _ = send_caller(Reply, Req),
            NewState#state{queue = queue:from_list(L2)}
    end.

%% @private
mk_reqid() -> erlang:phash2(erlang:timestamp()). % only has to be unique per-pid

%% @private
wait_for_list(ReqId) ->
    wait_for_list(ReqId, []).
%% @private
wait_for_list(ReqId, Acc) ->
    receive
        {ReqId, done} -> {ok, lists:flatten(Acc)};
        {ReqId, {error, Reason}} -> {error, Reason};
        {ReqId, {_, Res}} -> wait_for_list(ReqId, [Res|Acc])
    end.


%% @private
wait_for_mapred(ReqId, Timeout) ->
    wait_for_mapred_first(ReqId, Timeout).

%% Wait for the first mapred result, so we know at least one phase
%% that will be delivering results.
wait_for_mapred_first(ReqId, Timeout) ->
    case receive_mapred(ReqId, Timeout) of
        done ->
            {ok, []};
        {mapred, Phase, Res} ->
            wait_for_mapred_one(ReqId, Timeout, Phase,
                                acc_mapred_one(Res, []));
        {error, _}=Error ->
            Error;
        timeout ->
            {error, {timeout, []}}
    end.

%% So far we have only received results from one phase.  This method
%% of accumulating a single phases's outputs will be more efficient
%% than the repeated orddict:append_list/3 used when accumulating
%% outputs from multiple phases.
wait_for_mapred_one(ReqId, Timeout, Phase, Acc) ->
    case receive_mapred(ReqId, Timeout) of
        done ->
            {ok, finish_mapred_one(Phase, Acc)};
        {mapred, Phase, Res} ->
            %% still receiving for just one phase
            wait_for_mapred_one(ReqId, Timeout, Phase,
                                acc_mapred_one(Res, Acc));
        {mapred, NewPhase, Res} ->
            %% results from a new phase have arrived - track them all
            Dict = [{NewPhase, Res},{Phase, Acc}],
            wait_for_mapred_many(ReqId, Timeout, Dict);
        {error, _}=Error ->
            Error;
        timeout ->
            {error, {timeout, finish_mapred_one(Phase, Acc)}}
    end.

%% Single-phase outputs are kept as a reverse list of results.
acc_mapred_one([R|Rest], Acc) ->
    acc_mapred_one(Rest, [R|Acc]);
acc_mapred_one([], Acc) ->
    Acc.

finish_mapred_one(Phase, Acc) ->
    [{Phase, lists:reverse(Acc)}].

%% Tracking outputs from multiple phases.
wait_for_mapred_many(ReqId, Timeout, Acc) ->
    case receive_mapred(ReqId, Timeout) of
        done ->
            {ok, finish_mapred_many(Acc)};
        {mapred, Phase, Res} ->
            wait_for_mapred_many(
              ReqId, Timeout, acc_mapred_many(Phase, Res, Acc));
        {error, _}=Error ->
            Error;
        timeout ->
            {error, {timeout, finish_mapred_many(Acc)}}
    end.

%% Many-phase outputs are kepts as a proplist of reversed lists of
%% results.
acc_mapred_many(Phase, Res, Acc) ->
    case lists:keytake(Phase, 1, Acc) of
        {value, {Phase, PAcc}, RAcc} ->
            [{Phase,acc_mapred_one(Res,PAcc)}|RAcc];
        false ->
            [{Phase,acc_mapred_one(Res,[])}|Acc]
    end.

finish_mapred_many(Acc) ->
    [ {P, lists:reverse(A)} || {P, A} <- lists:keysort(1, Acc) ].

%% Receive one mapred message.
-spec receive_mapred(req_id(), timeout()) ->
         done | {mapred, integer(), [term()]} | {error, term()} | timeout.
receive_mapred(ReqId, Timeout) ->
    receive {ReqId, Msg} ->
            %% Msg should be `done', `{mapred, Phase, Results}', or
            %% `{error, Reason}'
            Msg
    after Timeout ->
            timeout
    end.


%% Encode the MapReduce request using term to binary
%% @private
-spec encode_mapred_req(term()) -> binary().
encode_mapred_req(Req) ->
    term_to_binary(Req).

%% Decode a partial phase response
%% @private
-spec decode_mapred_resp(binary(), binary()) -> term().
decode_mapred_resp(Data, <<"application/x-erlang-binary">>) ->
    try
        binary_to_term(Data)
    catch
        _:Error -> % On error, merge in with the other results
            [{error, Error}]
    end.

maybe_bucket_type({Type, Bucket}) ->
    {Type, Bucket};
maybe_bucket_type(Bucket) ->
    {undefined, Bucket}.

maybe_make_bucket_type(undefined, Bucket) ->
    Bucket;
maybe_make_bucket_type(Type, Bucket) ->
    {Type, Bucket}.

%% @private
%% @doc Create/Set record based on NVal value or throw an error.
-spec set_index_create_req_nval(pos_integer()|undefined, binary(), binary()) ->
                                 #rpbyokozunaindexputreq{}.
set_index_create_req_nval(NVal, Index, SchemaName) when is_integer(NVal) ->
    #rpbyokozunaindexputreq{index = #rpbyokozunaindex{
                                       name = Index,
                                       schema = SchemaName,
                                       n_val = NVal}};
set_index_create_req_nval(NVal, Index, SchemaName) when NVal =:= undefined ->
    #rpbyokozunaindexputreq{index = #rpbyokozunaindex{
                                       name = Index,
                                       schema = SchemaName}};
set_index_create_req_nval(NVal, _Index, _SchemaName)
  when not is_integer(NVal); NVal =/= undefined ->
    erlang:error(badarg).

%% @private
%% @doc Set record based on Timeout value or throw an error.
-spec set_index_create_req_timeout(timeout(), #rpbyokozunaindexputreq{}) ->
                                    #rpbyokozunaindexputreq{}.
set_index_create_req_timeout(Timeout, Req) when is_integer(Timeout) ->
    Req#rpbyokozunaindexputreq{timeout = Timeout};
set_index_create_req_timeout(Timeout, Req) when Timeout =:= infinity ->
    Req;
set_index_create_req_timeout(Timeout, _Req) when not is_integer(Timeout) ->
    erlang:error(badarg).


%% ====================================================================
%% unit tests
%% ====================================================================

%% Tests disabled until they can be prevented from running when included
%% as a dependency.
%%
-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

%% Get the test host - check env RIAK_TEST_PB_HOST then env 'RIAK_TEST_HOST_1'
%% falling back to 127.0.0.1
test_ip() ->
    case os:getenv("RIAK_TEST_PB_HOST") of
        false ->
            case os:getenv("RIAK_TEST_HOST_1") of
                false ->
                    "127.0.0.1";
                Host ->
                    Host
            end;
        Host ->
            Host
    end.

%% Test port - check env RIAK_TEST_PBC_1
test_port() ->
    case os:getenv("RIAK_TEST_PBC_1") of
        false ->
            8087;
        PortStr ->
            list_to_integer(PortStr)
    end.

%% Riak node under test - used to setup/configure/tweak it for tests
test_riak_node() ->
    case os:getenv("RIAK_TEST_NODE_1") of
        false ->
            'riak@127.0.0.1';
        NodeStr ->
            list_to_atom(NodeStr)
    end.

%% Node for the eunit node for distributed erlang
test_eunit_node() ->
    case os:getenv("RIAK_EUNIT_NODE") of
        false ->
            'eunit@127.0.0.1';
        EunitNodeStr ->
            list_to_atom(EunitNodeStr)
    end.

%% Cookie for distributed erlang
test_cookie() ->
    case os:getenv("RIAK_TEST_COOKIE") of
        false ->
            'riak';
        CookieStr ->
            list_to_atom(CookieStr)
    end.

%% Get the riak version from the init boot script, turn it into a list
%% of integers.
riak_version() ->
    StrVersion = element(2, rpc:call(test_riak_node(), init, script_id, [])),
    {match, [Major, Minor, Patch|_]} = re:run(StrVersion, "\\d+", [global, {capture, first, list}]),
    [ list_to_integer(V) || [V] <- [Major, Minor, Patch]].

%% Compare the first three part version array with the second.
%% returns `greater', `less', or `equal'.
compare_versions([M1,N1,P1], [M2,N2,P2]) ->
    V1 = (M1*1000000)+(N1*1000)+(P1),
    V2 = (M2*1000000)+(N2*1000)+(P2),
    case {V1 > V2, V1 == V2} of
        {true,_} ->
            greater;
        {false,false} ->
            less;
        {false,true} ->
            equal
    end.

%% Resets the riak node
reset_riak() ->
    %% sleep because otherwise we're going to kill the vnodes too fast
    %% for the supervisor's maximum restart frequency, which will bring
    %% down the entire node
    ?assertEqual(ok, maybe_start_network()),
    case compare_versions(riak_version(), [1,2,0]) of
        less ->
            reset_riak_legacy();
        _ ->
            reset_riak_12()
    end.

reset_solr(Pid) ->
    %% clear indexes
    {ok, Indexes} = ?MODULE:list_search_indexes(Pid),
    [ ?MODULE:delete_search_index(Pid, proplists:get_value(index,Index)) || Index <- Indexes ],
    wait_until( fun() ->
        {ok, []} == ?MODULE:list_search_indexes(Pid)
    end, 20, 1000),
    ok.

%% Resets a Riak 1.2+ node, which can run the memory backend in 'test'
%% mode.
reset_riak_12() ->
    set_test_backend(),
    ok = rpc:call(test_riak_node(), riak_kv_memory_backend, reset, []),
    reset_ring().

%% Sets up the memory/test backend, leaving it alone if already set properly.
set_test_backend() ->
    Env = rpc:call(test_riak_node(), application, get_all_env, [riak_kv]),
    Backend = proplists:get_value(storage_backend, Env),
    Test = proplists:get_value(test, Env),
    case {Backend, Test} of
        {riak_kv_memory_backend, true} ->
            ok;
        _ ->
            ok = rpc:call(test_riak_node(), application, set_env, [riak_kv, storage_backend, riak_kv_memory_backend]),
            ok = rpc:call(test_riak_node(), application, set_env, [riak_kv, test, true]),
            Vnodes = rpc:call(test_riak_node(), riak_core_vnode_manager, all_vnodes, [riak_kv_vnode]),
            [ ok = rpc:call(test_riak_node(), supervisor, terminate_child, [riak_core_vnode_sup, Pid]) ||
                {_, _, Pid} <- Vnodes ]
    end.

%% Resets a Riak 1.1 and earlier node.
reset_riak_legacy() ->
    timer:sleep(500),
    %% Until there is a good way to empty the vnodes, require the
    %% test to run with ETS and kill the vnode master/sup to empty all the ETS tables
    %% and the ring manager to remove any bucket properties
    ok = rpc:call(test_riak_node(), application, set_env, [riak_kv, storage_backend, riak_kv_memory_backend]),

    %% Restart the vnodes so they come up with ETS
    ok = supervisor:terminate_child({riak_kv_sup, test_riak_node()}, riak_kv_vnode_master),
    ok = supervisor:terminate_child({riak_core_sup, test_riak_node()}, riak_core_vnode_sup),
    {ok, _} = supervisor:restart_child({riak_core_sup, test_riak_node()}, riak_core_vnode_sup),
    {ok, _} = supervisor:restart_child({riak_kv_sup, test_riak_node()}, riak_kv_vnode_master),

    %% Clear the MapReduce cache
    ok = rpc:call(test_riak_node(), riak_kv_mapred_cache, clear, []),

    %% Now reset the ring so bucket properties are default
    reset_ring().

%% Resets the ring to a fresh one, effectively deleting any bucket properties.
reset_ring() ->
    Ring = rpc:call(test_riak_node(), riak_core_ring, fresh, []),
    ok = rpc:call(test_riak_node(), riak_core_ring_manager, set_my_ring, [Ring]).


%% Finds the pid of the PB listener process
riak_pb_listener_pid() ->
    {Children, Proc} = case compare_versions(riak_version(), [1,2,0]) of
                            less ->
                               {supervisor:which_children({riak_kv_sup, test_riak_node()}),
                                riak_kv_pb_listener};
                            _ ->
                               {supervisor:which_children({riak_api_sup, test_riak_node()}),
                                riak_api_pb_listener}
                        end,
    hd([Pid || {_,Pid,_,[Mod]} <- Children, Mod == Proc]).

pause_riak_pb_listener() ->
    Pid = riak_pb_listener_pid(),
    rpc:call(test_riak_node(), sys, suspend, [Pid]).

resume_riak_pb_listener() ->
    Pid = riak_pb_listener_pid(),
    rpc:call(test_riak_node(), sys, resume, [Pid]).

kill_riak_pb_sockets() ->
    Children = case compare_versions(riak_version(), [1,2,0]) of
                   less ->
                       supervisor:which_children({riak_kv_pb_socket_sup, test_riak_node()});
                   _ ->
                       supervisor:which_children({riak_api_pb_sup, test_riak_node()})
               end,
    case Children of
        [] ->
            ok;
        [_|_] ->
            Pids = [Pid || {_,Pid,_,_} <- Children],
            [rpc:call(test_riak_node(), erlang, exit, [Pid, kill]) || Pid <- Pids],
            erlang:yield(),
            kill_riak_pb_sockets()
    end.

maybe_start_network() ->
    %% Try to spin up net_kernel
    os:cmd("epmd -daemon"),
    case net_kernel:start([test_eunit_node(), longnames]) of
        {ok, _} ->
            erlang:set_cookie(test_riak_node(), test_cookie()),
            ok;
        {error, {already_started, _}} ->
            ok;
        X ->
            X
    end.

bad_connect_test() ->
    %% Start with an unlikely port number
    ?assertEqual({error, {tcp, econnrefused}}, start({127,0,0,1}, 65535)).

queue_disconnected_test() ->
    %% Start with an unlikely port number
    {ok, Pid} = start({127,0,0,1}, 65535, [queue_if_disconnected]),
    ?assertEqual({error, timeout}, ping(Pid, 10)),
    ?assertEqual({error, timeout}, list_keys(Pid, <<"b">>, 10)),
    stop(Pid).

auto_reconnect_bad_connect_test() ->
    %% Start with an unlikely port number
    {ok, Pid} = start({127,0,0,1}, 65535, [auto_reconnect]),
    ?assertEqual({false, []}, is_connected(Pid)),
    ?assertEqual({error, disconnected}, ping(Pid)),
    ?assertEqual({error, disconnected}, list_keys(Pid, <<"b">>)),
    stop(Pid).

server_closes_socket_test() ->
    %% Silence SASL junk when socket closes.
    error_logger:tty(false),
    %% Set up a dummy socket to send requests on
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false}]),
    {ok, Port} = inet:port(Listen),
    {ok, Pid} = start("127.0.0.1", Port),
    {ok, Sock} = gen_tcp:accept(Listen),
    ?assertMatch(true, is_connected(Pid)),

    %% Send a ping request in another process so the test doesn't block
    Self = self(),
    spawn(fun() -> Self ! ping(Pid, infinity) end),

    %% Make sure request received then close the socket
    {ok, _ReqMsg} = gen_tcp:recv(Sock, 0),
    ok = gen_tcp:close(Sock),
    ok = gen_tcp:close(Listen),
    receive
        Msg1 -> % result of ping from spawned process above
            ?assertEqual({error, disconnected}, Msg1)
    end,
    %% Wait for spawned process to exit
    Mref = erlang:monitor(process, Pid),
    receive
        Msg2 ->
            ?assertMatch({'DOWN', Mref, process, _, _}, Msg2)
    end.

auto_reconnect_server_closes_socket_test() ->
    %% Set up a dummy socket to send requests on
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false}]),
    {ok, Port} = inet:port(Listen),
    {ok, Pid} = start_link("127.0.0.1", Port, [auto_reconnect]),
    {ok, Sock} = gen_tcp:accept(Listen),
    ?assertMatch(true, is_connected(Pid)),

    %% Send a ping request in another process so the test doesn't block
    Self = self(),
    spawn(fun() -> Self ! ping(Pid, infinity) end),

    %% Make sure request received then close the socket
    {ok, _ReqMsg} = gen_tcp:recv(Sock, 0),
    ok = gen_tcp:close(Sock),
    ok = gen_tcp:close(Listen),
    receive
        Msg ->
            ?assertEqual({error, disconnected}, Msg)
    end,
    %% Server will not have had a chance to reconnect yet, reason counters empty.
    ?assertMatch({false, []}, is_connected(Pid)),
    stop(Pid).

dead_socket_pid_returns_to_caller_test() ->
    %% Set up a dummy socket to send requests on
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false}]),
    {ok, Port} = inet:port(Listen),
    {ok, Pid} = start("127.0.0.1", Port),
    {ok, Sock} = gen_tcp:accept(Listen),
    ?assertMatch(true, is_connected(Pid)),

    %% Send a ping request in another process so the test doesn't block
    Self = self(),
    spawn(fun() -> Self ! (catch ping(Pid, infinity)) end),

    %% Make sure request received then kill the process
    {ok, _ReqMsg} = gen_tcp:recv(Sock, 0),
    exit(Pid, kill),
    receive
        Msg ->
            ?assertMatch({'EXIT', {killed, _}}, Msg)
    end,
    %% Cleanup
    ok = gen_tcp:close(Sock),
    ok = gen_tcp:close(Listen).

pb_socket_test_() ->
    {setup,
     fun() ->
             %% Grab the riakclient_pb.proto file
             code:add_pathz("../ebin"),
             ok = maybe_start_network()
     end,
     fun(_) ->
             net_kernel:stop()
     end,
     {generator,
     fun() ->
             case catch net_adm:ping(test_riak_node()) of
                 pong ->
                     live_node_tests();
                 _ ->
                     [] %% {skipped, need_live_server};
             end
     end}}.


%% Check the reconnect interval increases up to the max and sticks there
increase_reconnect_interval_test() ->
    increase_reconnect_interval_test(#state{}).

increase_reconnect_interval_test(State) ->
    CurrInterval = State#state.reconnect_interval,
    NextState = increase_reconnect_interval(State),
    case NextState#state.reconnect_interval of
        ?MAX_RECONNECT_INTERVAL ->
            FinalState = increase_reconnect_interval(NextState),
            ?assertEqual(?MAX_RECONNECT_INTERVAL, FinalState#state.reconnect_interval);
        NextInterval->
            ?assert(NextInterval > CurrInterval),
            increase_reconnect_interval_test(NextState)
    end.

%% Retry `Fun' until it returns `Retry' times, waiting `Delay'
%% milliseconds between retries. This is our eventual consistency bread
%% and butter
wait_until(Fun) when is_function(Fun) ->
    wait_until(Fun, 20, 500).
wait_until(_, 0, _) ->
    fail;
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Pass = Fun(),
    case Pass of
        true ->
            ok;
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

%%
%% Tests to run against a live node - NB the node gets reconfigured and generally messed with
%%
live_node_tests() ->
    [{"ping",
      ?_test( begin
                  {ok, Pid} = start_link(test_ip(), test_port()),
                  ?assertEqual(pong, ?MODULE:ping(Pid)),
                  ?assertEqual(true, is_connected(Pid)),
                  stop(Pid)
              end)},
     {"reconnect test",
      ?_test( begin
                  %% Make sure originally there
                  {ok, Pid} = start_link(test_ip(), test_port()),

                  %% Change the options to allow reconnection/queueing
                  set_options(Pid, [queue_if_disconnected]),

                  %% Kill the socket
                  kill_riak_pb_sockets(),
                  ?assertEqual(pong, ?MODULE:ping(Pid)),
                  stop(Pid)
              end)},

     {"set client id",
      ?_test(
         begin
             {ok, Pid} = start_link(test_ip(), test_port()),
             {ok, <<OrigId:32>>} = ?MODULE:get_client_id(Pid),

             NewId = <<(OrigId+1):32>>,
             ok = ?MODULE:set_client_id(Pid, NewId),
             {ok, NewId} = ?MODULE:get_client_id(Pid)
         end)},

     {"version",
      ?_test(
         begin
             {ok, Pid} = start_link(test_ip(), test_port()),
             {ok, ServerInfo} = ?MODULE:get_server_info(Pid),
             [{node, _}, {server_version, _}] = lists:sort(ServerInfo)
         end)},

     {"get_should_read_put_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, PO} = ?MODULE:put(Pid, O, [return_body]),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"k">>),
                 ?assertEqual(riakc_obj:get_contents(PO), riakc_obj:get_contents(GO))
             end)},

     {"get should read put with timeout",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, PO} = ?MODULE:put(Pid, O, [{w, 1}, {dw, 1}, return_body]),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"k">>, 500),
                 ?assertEqual(riakc_obj:get_contents(PO), riakc_obj:get_contents(GO))
             end)},

     {"get should read put with options",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, PO} = ?MODULE:put(Pid, O, [{w, 1}, {dw, 1}, return_body]),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"k">>, [{r, 1}]),
                 ?assertEqual(riakc_obj:get_contents(PO), riakc_obj:get_contents(GO))
             end)},

     {"get should read put with non integer options",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, PO} = ?MODULE:put(Pid, O, [{w, all}, {dw, quorum}, return_body]),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"k">>, [{r, one}]),
                 ?assertEqual(riakc_obj:get_contents(PO), riakc_obj:get_contents(GO))
             end)},

     {"put and delete with timeout",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 PO = riakc_obj:new(<<"b">>, <<"puttimeouttest">>, <<"value">>),
                 ok = ?MODULE:put(Pid, PO, 500),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"puttimeouttest">>, 500),
                 ?assertEqual(<<"value">>, riakc_obj:get_value(GO)),
                 ok = ?MODULE:delete(Pid, <<"b">>, <<"puttimeouttest">>, 500),
                 {error, notfound} = ?MODULE:get(Pid, <<"b">>, <<"puttimeouttest">>)
             end)},

     {"update_should_change_value_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, PO} = ?MODULE:put(Pid, O, [return_body]),
                 PO2 = riakc_obj:update_value(PO, <<"v2">>),
                 ok = ?MODULE:put(Pid, PO2),
                 {ok, GO} = ?MODULE:get(Pid, <<"b">>, <<"k">>),
                 ?assertEqual(<<"v2">>, riakc_obj:get_value(GO))
             end)},

     {"key_should_be_missing_after_delete_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 %% Put key/value
                 O0 = riakc_obj:new(<<"b">>, <<"k">>),
                 O = riakc_obj:update_value(O0, <<"v">>),
                 {ok, _PO} = ?MODULE:put(Pid, O, [return_body]),
                 %% Prove it really got stored
                 {ok, GO1} = ?MODULE:get(Pid, <<"b">>, <<"k">>),
                 ?assertEqual(<<"v">>, riakc_obj:get_value(GO1)),
                 %% Delete and check no longer found
                 ok = ?MODULE:delete(Pid, <<"b">>, <<"k">>),
                 {error, notfound} = ?MODULE:get(Pid, <<"b">>, <<"k">>)
             end)},

    {"delete missing key test",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                  %% Delete and check no longer found
                 ok = ?MODULE:delete(Pid, <<"notabucket">>, <<"k">>, [{rw, 1}]),
                 {error, notfound} = ?MODULE:get(Pid, <<"notabucket">>, <<"k">>)
             end)},

     {"empty_list_buckets_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 ?assertEqual({ok, []}, ?MODULE:list_buckets(Pid))
             end)},

     {"list_buckets_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Bs = lists:sort([list_to_binary(["b"] ++ integer_to_list(N)) || N <- lists:seq(1, 10)]),
                 F = fun(B) ->
                             O=riakc_obj:new(B, <<"key">>),
                             ?MODULE:put(Pid, riakc_obj:update_value(O, <<"val">>))
                     end,
                 [F(B) || B <- Bs],
                 {ok, LBs} = ?MODULE:list_buckets(Pid),
                 ?assertEqual(Bs, lists:sort(LBs))
             end)},

     {"list_keys_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Bucket = <<"listkeys">>,
                 Ks = lists:sort([list_to_binary(integer_to_list(N)) || N <- lists:seq(1, 10)]),
                 F = fun(K) ->
                             O=riakc_obj:new(Bucket, K),
                             ?MODULE:put(Pid, riakc_obj:update_value(O, <<"val">>))
                     end,
                 [F(K) || K <- Ks],
                 {ok, LKs} = ?MODULE:list_keys(Pid, Bucket),
                 ?assertEqual(Ks, lists:sort(LKs)),

                 %% Make sure it works with an infinite timeout (will reset the timeout
                 %% timer after each packet)
                 {ok, LKs2} = ?MODULE:list_keys(Pid, Bucket, infinity),
                 ?assertEqual(Ks, lists:sort(LKs2))
             end)},

     {"get bucket properties test",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 {ok, Props} = get_bucket(Pid, <<"b">>),
                 ?assertEqual(3, proplists:get_value(n_val, Props)),
                 ?assertEqual(false, proplists:get_value(allow_mult, Props))
             end)},

     {"set bucket properties test",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 ok = set_bucket(Pid, <<"b">>, [{n_val, 2}, {allow_mult, false}]),
                 {ok, Props} = get_bucket(Pid, <<"b">>),
                 ?assertEqual(2, proplists:get_value(n_val, Props)),
                 ?assertEqual(false, proplists:get_value(allow_mult, Props))
             end)},

     {"allow_mult should allow dupes",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid1} = start_link(test_ip(), test_port()),
                 {ok, Pid2} = start_link(test_ip(), test_port()),
                 ok = set_bucket(Pid1, <<"multibucket">>, [{allow_mult, true}]),
                 ?MODULE:delete(Pid1, <<"multibucket">>, <<"foo">>),
                 {error, notfound} = ?MODULE:get(Pid1, <<"multibucket">>, <<"foo">>),
                 O = riakc_obj:new(<<"multibucket">>, <<"foo">>),
                 O1 = riakc_obj:update_value(O, <<"pid1">>),
                 O2 = riakc_obj:update_value(O, <<"pid2">>),
                 ok = ?MODULE:put(Pid1, O1),

                 ok = ?MODULE:put(Pid2, O2),
                 {ok, O3} = ?MODULE:get(Pid1, <<"multibucket">>, <<"foo">>),
                 ?assertEqual([<<"pid1">>, <<"pid2">>], lists:sort(riakc_obj:get_values(O3))),
                 O4 = riakc_obj:update_value(riakc_obj:select_sibling(1, O3), <<"resolved">>),
                 ok = ?MODULE:put(Pid1, O4),
                 {ok, GO} = ?MODULE:get(Pid1, <<"multibucket">>, <<"foo">>),
                 ?assertEqual([<<"resolved">>], lists:sort(riakc_obj:get_values(GO))),
                 ?MODULE:delete(Pid1, <<"multibucket">>, <<"foo">>)
             end)},

     {"update object test",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O0 = riakc_obj:new(<<"b">>, <<"k">>, <<"d">>),
                 io:format("O0: ~p\n", [O0]),
                 {ok, O1} = riakc_pb_socket:put(Pid, O0, [return_body]),
                 io:format("O1: ~p\n", [O1]),
                 M1 = riakc_obj:get_metadata(O1),
                 M2 = dict:store(?MD_LINKS, [{{<<"b">>, <<"k1">>}, <<"t1">>}], M1),
                 O2 = riakc_obj:update_metadata(O1, M2),
                 riakc_pb_socket:put(Pid, O2)
             end)},

     {"queue test",
      ?_test(begin
                 %% Would really like this in a nested {setup, blah} structure
                 %% but eunit does not allow
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 pause_riak_pb_listener(),
                 Me = self(),
                 %% this request will block as
                 spawn(fun() -> Me ! {1, ping(Pid)} end),
                 %% this request should be queued as socket will not be created
                 spawn(fun() -> Me ! {2, ping(Pid)} end),
                 resume_riak_pb_listener(),
                 receive {1,Ping1} -> ?assertEqual(Ping1, pong) end,
                 receive {2,Ping2} -> ?assertEqual(Ping2, pong) end
             end)},

    {"timeout queue test",
      ?_test(begin
                 %% Would really like this in a nested {setup, blah} structure
                 %% but eunit does not allow
                 pause_riak_pb_listener(),
                 {ok, Pid} = start_link(test_ip(), test_port(), [queue_if_disconnected]),
                 Me = self(),
                 %% this request will block as
                 spawn(fun() -> Me ! {1, ping(Pid, 0)} end),
                 %% this request should be queued as socket will not be created
                 spawn(fun() -> Me ! {2, ping(Pid, 0)},  Me ! running end),
                 receive running -> ok end,
                 resume_riak_pb_listener(),
                 receive {1,Ping1} -> ?assertEqual({error, timeout}, Ping1) end,
                 receive {2,Ping2} -> ?assertEqual({error, timeout}, Ping2) end
             end)},

    {"ignore stale tref test",
      ?_test(begin
                 %% Would really like this in a nested {setup, blah} structure
                 %% but eunit does not allow
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Pid ! {req_timeout, make_ref()},
                 ?assertEqual(pong, ping(Pid))
             end)},

   {"infinite timeout ping test",
      ?_test(begin
                 %% Would really like this in a nested {setup, blah} structure
                 %% but eunit does not allow
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 ?assertEqual(pong, ping(Pid, infinity)),
                 ?assertEqual(pong, ping(Pid, undefined))
             end)},

     {"javascript_source_map_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 B = <<"bucket">>,
                 K = <<"foo">>,
                 O=riakc_obj:new(B, K),
                 ?MODULE:put(Pid, riakc_obj:update_value(O, <<"2">>, "application/json")),

                 ?assertEqual({ok, [{0, [2]}]},
                              ?MODULE:mapred(Pid,
                                             [{B, K}],
                                             [{map, {jsanon, <<"function (v) { return [JSON.parse(v.values[0].data)]; }">>},
                                               undefined, true}]))
             end)},

     {"javascript_named_map_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 B = <<"bucket">>,
                 K = <<"foo">>,
                 O=riakc_obj:new(B, K),
                 ?MODULE:put(Pid, riakc_obj:update_value(O, <<"99">>, "application/json")),

                 ?assertEqual({ok, [{0, [99]}]},
                              ?MODULE:mapred(Pid,
                                             [{B, K}],
                                             [{map, {jsfun, <<"Riak.mapValuesJson">>},
                                               undefined, true}]))
             end)},

     {"javascript_source_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>},
                                      {<<"bar">>, <<"3">>},
                                      {<<"baz">>, <<"4">>}]],

                 ?assertEqual({ok, [{1, [3]}]},
                              ?MODULE:mapred(Pid,
                                             [{<<"bucket">>, <<"foo">>},
                                              {<<"bucket">>, <<"bar">>},
                                              {<<"bucket">>, <<"baz">>}],
                                             [{map, {jsanon, <<"function (v) { return [1]; }">>},
                                               undefined, false},
                                              {reduce, {jsanon,
                                                        <<"function(v) {
                                                             total = v.reduce(
                                                               function(prev,curr,idx,array) {
                                                                 return prev+curr;
                                                               }, 0);
                                                             return [total];
                                                           }">>},
                                               undefined, true}]))
             end)},

     {"javascript_named_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>},
                                      {<<"bar">>, <<"3">>},
                                      {<<"baz">>, <<"4">>}]],

                 ?assertEqual({ok, [{1, [9]}]},
                              ?MODULE:mapred(Pid,
                                             [{<<"bucket">>, <<"foo">>},
                                              {<<"bucket">>, <<"bar">>},
                                              {<<"bucket">>, <<"baz">>}],
                                             [{map, {jsfun, <<"Riak.mapValuesJson">>}, undefined, false},
                                              {reduce, {jsfun, <<"Riak.reduceSum">>}, undefined, true}]))
             end)},

     {"javascript_bucket_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>},
                                      {<<"bar">>, <<"3">>},
                                      {<<"baz">>, <<"4">>}]],

                 ?assertEqual({ok, [{1, [9]}]},
                              ?MODULE:mapred_bucket(Pid, <<"bucket">>,
                                                    [{map, {jsfun, <<"Riak.mapValuesJson">>}, undefined, false},
                                                     {reduce, {jsfun, <<"Riak.reduceSum">>}, undefined, true}]))
             end)},

     {"javascript_arg_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 O=riakc_obj:new(<<"bucket">>, <<"foo">>),
                 ?MODULE:put(Pid, riakc_obj:update_value(O, <<"2">>, "application/json")),
                 ?assertEqual({ok, [{1, [10]}]},
                              ?MODULE:mapred(Pid,
                                             [{{<<"bucket">>, <<"foo">>}, 5},
                                              {{<<"bucket">>, <<"foo">>}, 10},
                                              {{<<"bucket">>, <<"foo">>}, 15},
                                              {{<<"bucket">>, <<"foo">>}, -15},
                                              {{<<"bucket">>, <<"foo">>}, -5}],
                                             [{map, {jsanon, <<"function(v, arg) { return [arg]; }">>},
                                               undefined, false},
                                              {reduce, {jsfun, <<"Riak.reduceSum">>}, undefined, true}]))
             end)},
     {"erlang_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>},
                                      {<<"bar">>, <<"3">>},
                                      {<<"baz">>, <<"4">>}]],

                 {ok, [{1, Results}]} = ?MODULE:mapred(Pid,
                                                       [{<<"bucket">>, <<"foo">>},
                                                        {<<"bucket">>, <<"bar">>},
                                                        {<<"bucket">>, <<"baz">>}],
                                                       [{map, {modfun, riak_kv_mapreduce,
                                                               map_object_value},
                                                         undefined, false},
                                                        {reduce, {modfun, riak_kv_mapreduce,
                                                                  reduce_set_union},
                                                         undefined, true}]),
                 ?assertEqual([<<"2">>, <<"3">>, <<"4">>], lists:sort(Results))
             end)},
     {"erlang_map_reduce_binary_2i_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V,I}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 MD=riakc_obj:add_secondary_index(dict:new(), I),
                                 O2=riakc_obj:update_metadata(O,MD),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O2, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>, {{binary_index, "idx"}, [<<"a">>]}},
                                      {<<"bar">>, <<"3">>, {{binary_index, "idx"}, [<<"b">>]}},
                                      {<<"baz">>, <<"4">>, {{binary_index, "idx"}, [<<"a">>]}}]],

                 {ok, [{1, Results}]} = ?MODULE:mapred(Pid,
                                                       {index,<<"bucket">>,{binary_index, "idx"}, <<"a">>},
                                                       [{map, {modfun, riak_kv_mapreduce,
                                                               map_object_value},
                                                         undefined, false},
                                                        {reduce, {modfun, riak_kv_mapreduce,
                                                                  reduce_set_union},
                                                         undefined, true}]),
                 ?assertEqual([<<"2">>, <<"4">>], lists:sort(Results))
             end)},
     {"erlang_map_reduce_integer_2i_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Store = fun({K,V,I}) ->
                                 O=riakc_obj:new(<<"bucket">>, K),
                                 MD=riakc_obj:add_secondary_index(dict:new(), I),
                                 O2=riakc_obj:update_metadata(O,MD),
                                 ?MODULE:put(Pid,riakc_obj:update_value(O2, V, "application/json"))
                         end,
                 [Store(KV) || KV <- [{<<"foo">>, <<"2">>, {{integer_index, "idx"}, [4]}},
                                      {<<"bar">>, <<"3">>, {{integer_index, "idx"}, [7]}},
                                      {<<"baz">>, <<"4">>, {{integer_index, "idx"}, [4]}}]],

                 {ok, [{1, Results}]} = ?MODULE:mapred(Pid,
                                                       {index,<<"bucket">>,{integer_index, "idx"},3,5},
                                                       [{map, {modfun, riak_kv_mapreduce,
                                                               map_object_value},
                                                         undefined, false},
                                                        {reduce, {modfun, riak_kv_mapreduce,
                                                                  reduce_set_union},
                                                         undefined, true}]),
                 ?assertEqual([<<"2">>, <<"4">>], lists:sort(Results))
             end)},
     {"missing_key_erlang_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = {ok, Pid} = start_link(test_ip(), test_port()),
                 {ok, Results} = ?MODULE:mapred(Pid, [{<<"bucket">>, <<"foo">>},
                                                      {<<"bucket">>, <<"bar">>},
                                                      {<<"bucket">>, <<"baz">>}],
                                                [{map, {modfun, riak_kv_mapreduce,
                                                        map_object_value},
                                                  <<"include_notfound">>, false},
                                                 {reduce, {modfun, riak_kv_mapreduce,
                                                           reduce_set_union},
                                                  undefined, true}]),
                 [{1, [{error, notfound}|_]}] = Results end)},
     {"missing_key_javascript_map_reduce_test()",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = {ok, Pid} = start_link(test_ip(), test_port()),
                 {ok, Results} = ?MODULE:mapred(Pid, [{<<"bucket">>, <<"foo">>},
                                                      {<<"bucket">>, <<"bar">>},
                                                      {<<"bucket">>, <<"baz">>}],
                                                [{map, {jsfun, <<"Riak.mapValuesJson">>},
                                                  undefined, false},
                                                 {reduce, {jsfun, <<"Riak.reduceSort">>},
                                                  undefined, true}]),
                 [{1, [{not_found, {_, _},<<"undefined">>}|_]}] = Results end)},
     {"map reduce bad inputs",
      ?_test(begin
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Res = ?MODULE:mapred(Pid, undefined,
                                             [{map, {jsfun, <<"Riak.mapValuesJson">>},
                                               undefined, false},
                                              {reduce, {jsfun, <<"Riak.reduceSum">>},
                                               undefined, true}]),
                 ?assertEqual({error, <<"{inputs,{\"Inputs must be a binary bucket, a tuple of bucket and key-filters, a list of target tuples, or a search, index, or modfun tuple:\",\n         undefined}}">>},
                              Res )
             end)},
     {"map reduce bad input keys",
      ?_test(begin
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Res = ?MODULE:mapred(Pid, [<<"b">>], % no {B,K} tuple
                                      [{map, {jsfun, <<"Riak.mapValuesJson">>},
                                        undefined, false},
                                       {reduce, {jsfun, <<"Riak.reduceSum">>},
                                        undefined, true}]),
                 ?assertEqual({error,<<"{inputs,{\"Inputs target tuples must be {B,K} or {{B,K},KeyData}:\",[<<\"b\">>]}}">>},
                              Res)
             end)},
     {"map reduce bad query",
      ?_test(begin
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 Res = ?MODULE:mapred(Pid, [{<<"b">>,<<"k">>}], % no {B,K} tuple
                                      undefined),
                 ?assertEqual({error,<<"{query,{\"Query takes a list of step tuples\",undefined}}">>},
                              Res)
             end)},
     {"get should convert erlang terms",
      ?_test(begin
                 reset_riak(),
                 TestNode = test_riak_node(),
                 MyBin = <<"some binary">>,
                 MyTerm = [<<"b">>,<<"a_term">>,{some_term, ['full', "of", 123, 654.321]}],
                 BinObj = rpc:call(TestNode, riak_object, new,
                                   [<<"b">>, <<"a_bin">>, MyBin]),
                 TermObj = rpc:call(TestNode, riak_object, new,
                                    [<<"b">>, <<"a_term">>, MyTerm]),
                 {ok, C} = rpc:call(TestNode, riak, local_client, []),
                 %% parameterized module trickery - stick it as the last argument
                 ok = rpc:call(TestNode, riak_client, put, [BinObj, 1, C]),
                 ok = rpc:call(TestNode, riak_client, put, [TermObj, 1, C]),

                 {ok, Pid} = start_link(test_ip(), test_port()),
                 {ok, GotBinObj} = ?MODULE:get(Pid, <<"b">>, <<"a_bin">>),
                 {ok, GotTermObj} = ?MODULE:get(Pid, <<"b">>, <<"a_term">>),

                 ?assertEqual(riakc_obj:get_value(GotBinObj), MyBin),
                 ?assertEqual(riakc_obj:get_content_type(GotTermObj),
                              "application/x-erlang-binary"),
                 ?assertEqual(binary_to_term(riakc_obj:get_value(GotTermObj)), MyTerm)
             end)},
     {"putting without a key should generate one",
         ?_test(begin
                     reset_riak(),
                     {ok, Pid} = start_link(test_ip(), test_port()),
                     PO = riakc_obj:new(<<"b">>, undefined, <<"value">>),
                     Res1 = ?MODULE:put(Pid, PO),
                     Res2 = ?MODULE:put(Pid, PO),
                     ?assertMatch({ok, _Key}, Res1),
                     % Make sure the same key isn't generated twice
                     ?assert(Res1 =/= Res2)
             end)},
     {"putting without a key should generate one with return_body",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, undefined, <<"value">>),
                    {ok, Obj1} = ?MODULE:put(Pid, PO, [return_body]),
                    {ok, Obj2} = ?MODULE:put(Pid, PO, [return_body]),
                    %% Make sure the same key isn't generated twice
                    ?assertEqual(element(1, Obj1), riakc_obj),
                    ?assertEqual(element(1, Obj2), riakc_obj),
                    ?assert(riakc_obj:key(Obj1) /= riakc_obj:key(Obj2))
             end)},
     {"conditional gets should return unchanged if the vclock matches",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    ?MODULE:put(Pid, PO),
                    {ok, Obj} = ?MODULE:get(Pid, <<"b">>, <<"key">>),
                    VClock = riakc_obj:vclock(Obj),
                    %% object hasn't changed
                    ?assertEqual(unchanged, ?MODULE:get(Pid, <<"b">>, <<"key">>,
                            [{if_modified, VClock}])),
                    %% change the object and make sure unchanged isn't returned
                    P1 = riakc_obj:update_value(Obj, <<"newvalue">>),
                    ?MODULE:put(Pid, P1),
                    ?assertMatch({ok, _}, ?MODULE:get(Pid, <<"b">>, <<"key">>,
                            [{if_modified, VClock}]))
             end)},
     {"the head get option should return the object metadata without the value",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    ?MODULE:put(Pid, PO),
                    {ok, Obj} = ?MODULE:get(Pid, <<"b">>, <<"key">>, [head]),
                    ?assertEqual(<<>>, riakc_obj:get_value(Obj)),
                    {ok, Obj2} = ?MODULE:get(Pid, <<"b">>, <<"key">>, []),
                    ?assertEqual(<<"value">>, riakc_obj:get_value(Obj2))
             end)},
     {"conditional put should allow you to avoid overwriting a value if it already exists",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    ?assertEqual(ok, ?MODULE:put(Pid, PO, [if_none_match])),
                    ?assertEqual({error, <<"match_found">>}, ?MODULE:put(Pid, PO, [if_none_match]))
             end)},
     {"conditional put should allow you to avoid overwriting a value if its been updated",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    {ok, Obj} = ?MODULE:put(Pid, PO, [return_body]),
                    Obj2 = riakc_obj:update_value(Obj, <<"newvalue">>),
                    ?assertEqual(ok, ?MODULE:put(Pid, Obj2, [if_not_modified])),
                    ?assertEqual({error, <<"modified">>}, ?MODULE:put(Pid, Obj2, [if_not_modified]))
             end)},
     {"if_not_modified should fail if the object is not found",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    ?assertEqual({error, <<"notfound">>}, ?MODULE:put(Pid, PO, [if_not_modified]))
             end)},
     {"return_head should empty out the value in the riak object",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    {ok, Obj} = ?MODULE:put(Pid, PO, [return_head]),
                    ?assertEqual(<<>>, riakc_obj:get_value(Obj))
             end)},
     {"return_head should empty out all values when there's siblings",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = set_bucket(Pid, <<"b">>, [{allow_mult, true}]),
                    PO = riakc_obj:new(<<"b">>, <<"key">>, <<"value">>),
                    {ok, Obj} = ?MODULE:put(Pid, PO, [return_head]),
                    ?assertEqual(<<>>, riakc_obj:get_value(Obj)),
                    {ok, Obj2} = ?MODULE:put(Pid, PO, [return_head]),
                    ?assertEqual([<<>>, <<>>], riakc_obj:get_values(Obj2))
             end)},

    {"user metadata manipulation",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    O0 = riakc_obj:new(<<"b">>, <<"key0">>, <<"value0">>),
                    MD0 = riakc_obj:get_update_metadata(O0),
                    MD1 = riakc_obj:set_user_metadata_entry(MD0, {<<"Key1">>,<<"Val1">>}),
                    O1 = riakc_obj:update_metadata(O0, MD1),
                    ?assertEqual(ok, ?MODULE:put(Pid, O1)),
                    {ok, O2} = ?MODULE:get(Pid, <<"b">>, <<"key0">>),
                    MD2 = riakc_obj:get_update_metadata(O2),
                    ?assertEqual([{<<"Key1">>,<<"Val1">>}], riakc_obj:get_user_metadata_entries(MD2)),
                    MD3 = riakc_obj:set_user_metadata_entry(MD2, {<<"Key2">>,<<"Val2">>}),
                    O3 = riakc_obj:update_metadata(O2, MD3),
                    ?assertEqual(ok, ?MODULE:put(Pid, O3)),
                    {ok, O4} = ?MODULE:get(Pid, <<"b">>, <<"key0">>),
                    ?assertEqual(2, length(riakc_obj:get_user_metadata_entries(riakc_obj:get_update_metadata(O4))))
             end)},
    {"binary secondary index manipulation",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    O0 = riakc_obj:new(<<"b">>, <<"key1">>, <<"value1">>),
                    MD0 = riakc_obj:get_update_metadata(O0),
                    MD1 = riakc_obj:set_secondary_index(MD0, [{{binary_index, "idx"},[<<"aaa">>]}]),
                    O1 = riakc_obj:update_metadata(O0, MD1),
                    ?assertEqual(ok, ?MODULE:put(Pid, O1)),
                    {ok, O2} = ?MODULE:get(Pid, <<"b">>, <<"key1">>),
                    MD2 = riakc_obj:get_update_metadata(O2),
                    ?assertEqual([<<"aaa">>], lists:sort(riakc_obj:get_secondary_index(MD2,{binary_index,"idx"}))),
                    MD3 = riakc_obj:add_secondary_index(MD2, [{{binary_index, "idx"},[<<"bbb">>,<<"aaa">>,<<"ccc">>]}]),
                    O3 = riakc_obj:update_metadata(O2, MD3),
                    ?assertEqual(ok, ?MODULE:put(Pid, O3)),
                    ?assertEqual({ok,?INDEX_RESULTS{keys=[<<"key1">>]}},
                                 ?MODULE:get_index(Pid, <<"b">>, {binary_index, "idx"}, <<"bbb">>)),
                    {ok, O4} = ?MODULE:get(Pid, <<"b">>, <<"key1">>),
                    MD4 = riakc_obj:get_update_metadata(O4),
                    ?assertEqual([<<"aaa">>,<<"bbb">>,<<"ccc">>], lists:sort(riakc_obj:get_secondary_index(MD4, {binary_index, "idx"}))),
                    MD5 = riakc_obj:delete_secondary_index(MD4,{binary_index,"idx"}),
                    O5 = riakc_obj:update_metadata(O4, MD5),
                    ?assertEqual(ok, ?MODULE:put(Pid, O5))
             end)},
     {"integer secondary index manipulation",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    O0 = riakc_obj:new(<<"b">>, <<"key2">>, <<"value2">>),
                    MD0 = riakc_obj:get_update_metadata(O0),
                    MD1 = riakc_obj:set_secondary_index(MD0, [{{integer_index, "idx"},[67]}]),
                    O1 = riakc_obj:update_metadata(O0, MD1),
                    ?assertEqual(ok, ?MODULE:put(Pid, O1)),
                    {ok, O2} = ?MODULE:get(Pid, <<"b">>, <<"key2">>),
                    MD2 = riakc_obj:get_update_metadata(O2),
                    ?assertEqual([67], lists:sort(riakc_obj:get_secondary_index(MD2,{integer_index,"idx"}))),
                    MD3 = riakc_obj:add_secondary_index(MD2, [{{integer_index, "idx"},[56,10000,100]}]),
                    O3 = riakc_obj:update_metadata(O2, MD3),
                    ?assertEqual(ok, ?MODULE:put(Pid, O3)),
                    ?assertEqual({ok,?INDEX_RESULTS{keys=[<<"key2">>]}},
                                 ?MODULE:get_index(Pid, <<"b">>, {integer_index, "idx"}, 50, 60)),
                    {ok, O4} = ?MODULE:get(Pid, <<"b">>, <<"key2">>),
                    MD4 = riakc_obj:get_update_metadata(O4),
                    ?assertEqual([56,67,100,10000], lists:sort(riakc_obj:get_secondary_index(MD4, {integer_index, "idx"}))),
                    MD5 = riakc_obj:delete_secondary_index(MD4,{integer_index,"idx"}),
                    O5 = riakc_obj:update_metadata(O4, MD5),
                    ?assertEqual(ok, ?MODULE:put(Pid, O5))
             end)},
     {"counter increment / decrement / get value",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 unlink(Pid),
                 Bucket = <<"counter_test_bucket">>,
                 Key = <<"test_counter">>,
                 %% counters require allow_mult to be true
                 ok = set_bucket(Pid, Bucket, [{allow_mult, true}]),
                 ok = ?MODULE:counter_incr(Pid, Bucket, Key, 10),
                 ?assertEqual({ok, 10}, ?MODULE:counter_val(Pid, Bucket, Key)),
                 ok = ?MODULE:counter_incr(Pid, Bucket, Key, -5, [{w, quorum}, {pw, one}, {dw, all}]),
                 ?assertEqual({ok, 5}, ?MODULE:counter_val(Pid, Bucket, Key, [{pr, one}]))
             end)},
     {"create a search index / get / list / delete with default timeout",
     {timeout, 30, ?_test(begin
                reset_riak(),
                {ok, Pid} = start_link(test_ip(), test_port()),
                reset_solr(Pid),
                Index = <<"indextest">>,
                SchemaName = <<"_yz_default">>,
                ?assertEqual(ok,
                    ?MODULE:create_search_index(Pid,
                                                Index,
                                                SchemaName,
                                                [{n_val,2}])),
                    case ?MODULE:get_search_index(Pid, Index) of
                        {ok, IndexData} ->
                            ?assertEqual(proplists:get_value(
                                         index, IndexData), Index),
                            ?assertEqual(proplists:get_value(
                                         schema, IndexData), SchemaName),
                            ?assertEqual(proplists:get_value(
                                         n_val, IndexData), 2);
                        {error, <<"notfound">>} ->
                            false
                    end,
                ?assertEqual({ok, [[{index,Index},
                                    {schema,SchemaName},
                                    {n_val,2}]]},
                             ?MODULE:list_search_indexes(Pid)),
                ?assertEqual(ok, ?MODULE:delete_search_index(Pid, Index))
             end)}},
     {"create a search index / get with user-set timeout",
     {timeout, 30, ?_test(begin
                reset_riak(),
                {ok, Pid} = start_link(test_ip(), test_port()),
                reset_solr(Pid),
                Index = <<"indexwithintimeouttest">>,
                SchemaName = <<"_yz_default">>,
                ?assertEqual(ok,
                    ?MODULE:create_search_index(Pid,
                                                Index,
                                                SchemaName,
                                                20000)),
                    case ?MODULE:get_search_index(Pid, Index) of
                        {ok, IndexData} ->
                            ?assertEqual(proplists:get_value(
                                         index, IndexData), Index),
                            ?assertEqual(proplists:get_value(
                                         schema, IndexData), SchemaName);
                        {error, <<"notfound">>} ->
                            false
                    end
             end)}},
     {"create a search schema / get",
      {timeout, 30, ?_test(begin
                reset_riak(),
                {ok, Pid} = start_link(test_ip(), test_port()),
                reset_solr(Pid),
                Schema = <<"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>
<schema name=\"test\" version=\"1.5\">
<fields>
   <field name=\"_yz_id\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" required=\"true\" multiValued=\"false\"/>
   <field name=\"_yz_ed\" type=\"_yz_str\" indexed=\"true\" stored=\"false\" multiValued=\"false\"/>
   <field name=\"_yz_pn\" type=\"_yz_str\" indexed=\"true\" stored=\"false\" multiValued=\"false\"/>
   <field name=\"_yz_fpn\" type=\"_yz_str\" indexed=\"true\" stored=\"false\" multiValued=\"false\"/>
   <field name=\"_yz_vtag\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>
   <field name=\"_yz_rt\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>
   <field name=\"_yz_rk\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>
   <field name=\"_yz_rb\" type=\"_yz_str\" indexed=\"true\" stored=\"true\" multiValued=\"false\"/>
   <field name=\"_yz_err\" type=\"_yz_str\" indexed=\"true\" stored=\"false\" multiValued=\"false\"/>
</fields>
<uniqueKey>_yz_id</uniqueKey>
<types>
    <fieldType name=\"_yz_str\" class=\"solr.StrField\" sortMissingLast=\"true\" />
</types>
</schema>">>,
                Index = <<"schemaindex">>,
                SchemaName = <<"myschema">>,
                ?assertEqual(ok, ?MODULE:create_search_schema(Pid, SchemaName, Schema)),
                ?assertEqual(ok, ?MODULE:create_search_index(Pid, Index, SchemaName, [])),
                wait_until( fun() ->
                    case ?MODULE:list_search_indexes(Pid) of
                        {ok, []} ->
                            false;
                        {ok, [IndexData|_]} ->
                            proplists:get_value(index, IndexData) == Index andalso
                            proplists:get_value(schema, IndexData) == SchemaName andalso
                            proplists:get_value(n_val, IndexData) == 3
                    end
                end, 20, 1000 ),
                wait_until( fun() ->
                    case ?MODULE:get_search_schema(Pid, SchemaName) of
                        {ok, SchemaData} ->
                            proplists:get_value(name, SchemaData) == SchemaName andalso
                            proplists:get_value(content, SchemaData) == Schema;
                        {error, <<"notefound">>} ->
                            false
                    end
                end, 20, 1000 )
         end)}},
     {"create a search index and tie to a bucket",
     {timeout, 30, ?_test(begin
                reset_riak(),
                {ok, Pid} = start_link(test_ip(), test_port()),
                Index = <<"myindex">>,
                Bucket = <<"mybucket">>,
                ?assertEqual(ok, ?MODULE:create_search_index(Pid, Index)),
                ok = ?MODULE:set_search_index(Pid, Bucket, Index),
                PO = riakc_obj:new(Bucket, <<"fred">>, <<"{\"name_s\":\"Freddy\"}">>, "application/json"),
                {ok, _Obj} = ?MODULE:put(Pid, PO, [return_head]),
                wait_until( fun() ->
                    {ok, Result} = search(Pid, Index, <<"*:*">>),
                    1 == Result#search_results.num_found
                end, 20, 1000 )
         end)}},
     {"search utf8",
     {timeout, 30, ?_test(begin
                reset_riak(),
                {ok, Pid} = start_link(test_ip(), test_port()),
                reset_solr(Pid),
                Index = <<"myindex">>,
                Bucket = <<"mybucket">>,
                ?assertEqual(ok, ?MODULE:create_search_index(Pid, Index)),
                ok = ?MODULE:set_search_index(Pid, Bucket, Index),
                PO = riakc_obj:new(Bucket, <<"fred">>, <<"{\"name_s\":\"בָּרָא\"}">>, "application/json"),
                {ok, _Obj} = ?MODULE:put(Pid, PO, [return_head]),
                wait_until( fun() ->
                    {ok, Result} = search(Pid, Index, <<"name_s:בָּרָא">>),
                    1 == Result#search_results.num_found
                end )
         end)}},
     {"trivial set delete",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>, riakc_set:new()))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 1),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:del_element(<<"X">>, S0))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assertNot(riakc_set:is_element(<<"X">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 0)
             end)},
     {"add and remove items in nested set in map",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(riakc_map:update({<<"set">>, set},
                                                                      fun(S) ->
                                                                              riakc_set:add_element(<<"X">>,
                                                                                                    riakc_set:add_element(<<"Y">>, S))
                                                                      end, riakc_map:new()))),
                    {ok, M0} = riakc_pb_socket:fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L0 = riakc_map:fetch({<<"set">>, set}, M0),
                    ?assert(lists:member(<<"X">>, L0)),
                    ?assert(lists:member(<<"Y">>, L0)),
                    ?assertEqual(length(L0), 2),

                    M1 = riakc_map:update({<<"set">>, set},
                                          fun(S) -> riakc_set:del_element(<<"X">>,
                                                                          riakc_set:add_element(<<"Z">>, S)) end,
                                          M0),

                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M1)),
                    {ok, M2} = riakc_pb_socket:fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L1 = riakc_map:fetch({<<"set">>, set}, M2),

                    ?assert(lists:member(<<"Y">>, L1)),
                    ?assert(lists:member(<<"Z">>, L1)),
                    ?assertEqual(length(L1), 2)
             end)},
     {"increment nested counter",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(riakc_map:update({<<"counter">>, counter},
                                                                      fun(C) ->
                                                                              riakc_counter:increment(5, C)
                                                                      end, riakc_map:new()))),
                    {ok, M0} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    C0 = riakc_map:fetch({<<"counter">>, counter}, M0),
                    ?assertEqual(C0, 5),

                    M1 = riakc_map:update({<<"counter">>, counter},
                                          fun(C) -> riakc_counter:increment(200, C) end,
                                          M0),
                    M2 = riakc_map:update({<<"counter">>, counter},
                                          fun(C) -> riakc_counter:decrement(117, C) end,
                                          M1),
                    M3 = riakc_map:update({<<"counter">>, counter},
                                          fun(C) -> riakc_counter:increment(256, C) end,
                                          M2),

                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M3)),
                    {ok, M4} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    C1 = riakc_map:fetch({<<"counter">>, counter}, M4),
                    ?assertEqual(C1, 344)
             end)},
     {"updated nested lww register",
         ?_test(begin
                    reset_riak(),
                    %% The word "stone" translated into Russian and Thai
                    StoneInRussian = [1051,1102,1082,32,1082,1072,1084,1085,1077,1091,1083,1086,
                                      1074,1080,1090,1077,1083,1103],
                    StoneInThai = [3627,3636,3609],
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = riakc_pb_socket:update_type(Pid,
                                                     {<<"map_bucket">>, <<"bucket">>},
                                                     <<"key">>,
                                     riakc_map:to_op(
                                       riakc_map:update(
                                       {<<"register">>, register},
                                       fun(R) ->
                                               riakc_register:set(
                                                 term_to_binary({"barney", "rubble", StoneInRussian}),
                                                 R)
                                       end, riakc_map:new()))),
                    {ok, M0} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    R0 = riakc_map:fetch({<<"register">>, register}, M0),
                    ?assertEqual(binary_to_term(R0), {"barney", "rubble", StoneInRussian}),

                    ok = riakc_pb_socket:update_type(Pid,
                                                     {<<"map_bucket">>, <<"bucket">>},
                                                     <<"key">>,
                                     riakc_map:to_op(
                                       riakc_map:update(
                                       {<<"register">>, register},
                                       fun(R) ->
                                               riakc_register:set(
                                                 term_to_binary({"barney", "rubble", StoneInThai}),
                                                 R)
                                       end, M0))),

                    {ok, M1} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    R1 = riakc_map:fetch({<<"register">>, register}, M1),
                    ?assertEqual(binary_to_term(R1), {"barney", "rubble", StoneInThai})
             end)},
     {"throw exception for undefined context for delete",
         ?_test(begin
                    reset_riak(),
                    ?assertThrow(context_required, riakc_set:del_element(<<"X">>,
                                                                         riakc_set:add_element(<<"X">>,
                                                                                               riakc_set:new()))),
                    ?assertThrow(context_required, riakc_map:erase({<<"counter">>, counter}, riakc_map:new())),
                    ?assertThrow(context_required, riakc_map:erase({<<"set">>, set}, riakc_map:new())),
                    ?assertThrow(context_required, riakc_map:erase({<<"map">>, map}, riakc_map:new())),
                    ?assertThrow(context_required, riakc_map:update({<<"set">>, set}, fun(S) -> riakc_set:del_element(<<"Y">>, S) end, riakc_map:new())),
                    ?assertThrow(context_required, riakc_flag:disable(riakc_flag:new()))
             end)},
     {"delete bogus item from set",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>, riakc_set:new()))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 1),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:del_element(<<"Y">>, S0))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 1)
             end)},
     {"add redundant item to set",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>, riakc_set:new()))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 1),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>, S0))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 1)
             end)},
     {"add and remove redundant item to/from set",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>,
                                                                           riakc_set:add_element(<<"Y">>, riakc_set:new())))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assert(riakc_set:is_element(<<"Y">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 2),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:del_element(<<"X">>, riakc_set:add_element(<<"X">>, S0)))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S1)),
                    ?assert(riakc_set:is_element(<<"Y">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 2)
             end)},
     {"remove then add redundant item from/to set",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>,
                                                                           riakc_set:add_element(<<"Y">>, riakc_set:new())))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assert(riakc_set:is_element(<<"Y">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 2),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>, riakc_set:del_element(<<"X">>, S0)))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S1)),
                    ?assert(riakc_set:is_element(<<"Y">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 2)
             end)},
     {"remove item from set with outdated context",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"X">>,
                                                                           riakc_set:add_element(<<"Y">>, riakc_set:new())))),
                    {ok, S0} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S0)),
                    ?assert(riakc_set:is_element(<<"Y">>, S0)),
                    ?assertEqual(riakc_set:size(S0), 2),
                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:add_element(<<"Z">>, riakc_set:new()))),

                    ok = update_type(Pid,
                                     {<<"set_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_set:to_op(riakc_set:del_element(<<"Z">>, S0))),
                    {ok, S1} = fetch_type(Pid, {<<"set_bucket">>, <<"bucket">>}, <<"key">>),
                    ?assert(riakc_set:is_element(<<"X">>, S1)),
                    ?assert(riakc_set:is_element(<<"Y">>, S1)),
                    ?assert(riakc_set:is_element(<<"Z">>, S1)),
                    ?assertEqual(riakc_set:size(S1), 3)
             end)},
     {"add item to nested set in map while also removing set",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(riakc_map:update({<<"set">>, set},
                                                                      fun(S) ->
                                                                              riakc_set:add_element(<<"X">>,
                                                                                                    riakc_set:add_element(<<"Y">>, S))
                                                                      end, riakc_map:new()))),
                    {ok, M0} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L0 = riakc_map:fetch({<<"set">>, set}, M0),
                    ?assert(lists:member(<<"X">>, L0)),
                    ?assert(lists:member(<<"Y">>, L0)),
                    ?assertEqual(length(L0), 2),

                    M1 = riakc_map:update({<<"set">>, set},
                                          fun(S) -> riakc_set:add_element(<<"Z">>, S) end,
                                          M0),
                    M2 = riakc_map:erase({<<"set">>, set}, M1),

                    ok = update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M2)),
                    {ok, M3} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L1 = riakc_map:fetch({<<"set">>, set}, M3),

                    ?assert(lists:member(<<"Z">>, L1)),
                    ?assertEqual(length(L1), 1)
             end)},
     {"increment nested counter in map while also removing counter",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(riakc_map:update({<<"counter">>, counter},
                                                                      fun(C) ->
                                                                              riakc_counter:increment(5, C)
                                                                      end, riakc_map:new()))),
                    {ok, M0} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    C0 = riakc_map:fetch({<<"counter">>, counter}, M0),
                    ?assertEqual(C0, 5),

                    M1 = riakc_map:update({<<"counter">>, counter},
                                          fun(C) -> riakc_counter:increment(2, C) end,
                                          M0),
                    M2 = riakc_map:erase({<<"counter">>, counter}, M1),

                    ok = update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M2)),
                    {ok, M3} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    C1 = riakc_map:fetch({<<"counter">>, counter}, M3),

                    %% Expected result depends on combination of vnodes involved, so accept either answer
                    ?assert(C1 =:= 2 orelse C1 =:= 7)
             end)},
     {"add item to nested set in nested map in map while also removing nested map",
         ?_test(begin
                    reset_riak(),
                    {ok, Pid} = start_link(test_ip(), test_port()),
                    M0 = riakc_map:update({<<"map">>, map},
                                          fun(M) ->
                                                  riakc_map:update({<<"set">>, set},
                                                                   fun(S) ->
                                                                           riakc_set:add_element(<<"X">>,
                                                                                                 riakc_set:add_element(<<"Y">>, S))
                                                                   end,
                                                                   M)
                                          end,
                                          riakc_map:new()),
                    ok = riakc_pb_socket:update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M0)),

                    {ok, M1} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L0 = orddict:fetch({<<"set">>, set}, riakc_map:fetch({<<"map">>, map}, M1)),

                    ?assert(lists:member(<<"X">>, L0)),
                    ?assert(lists:member(<<"Y">>, L0)),
                    ?assertEqual(length(L0), 2),

                    M2 = riakc_map:update({<<"map">>, map},
                                          fun(M) -> riakc_map:update({<<"set">>, set},
                                                                     fun(S) -> riakc_set:add_element(<<"Z">>, S) end,
                                                                     M)
                                          end,
                                          M1),
                    M3 = riakc_map:erase({<<"map">>, map}, M2),

                    ok = update_type(Pid,
                                     {<<"map_bucket">>, <<"bucket">>}, <<"key">>,
                                     riakc_map:to_op(M3)),
                    {ok, M4} = fetch_type(Pid, {<<"map_bucket">>, <<"bucket">>}, <<"key">>),
                    L1 = orddict:fetch({<<"set">>, set}, riakc_map:fetch({<<"map">>, map}, M4)),

                    ?assert(lists:member(<<"Z">>, L1)),
                    ?assertEqual(length(L1), 1)
                end)},
     {"get preflist test",
      ?_test(begin
                 reset_riak(),
                 {ok, Pid} = start_link(test_ip(), test_port()),
                 {ok, Preflist} = get_preflist(Pid, <<"b">>, <<"f">>),
                 ?assertEqual([#preflist_item{partition = 52,
                                              node = <<"riak@127.0.0.1">>,
                                              primary = true},
                               #preflist_item{partition = 53,
                                              node = <<"riak@127.0.0.1">>,
                                              primary = true},
                               #preflist_item{partition = 54,
                                              node = <<"riak@127.0.0.1">>,
                                              primary = true}],
                              Preflist)
             end)}
     ].

-endif.
