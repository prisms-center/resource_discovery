%%% ===================================================================
%%% @doc rd_host_resource takes care of caching each hosts resources.
%%% The server takes care of time to live, gossiping with the remote
%%% host, and monitoring for change events for that host.

%%% The service has a TTL. At expiration it verifies the resources for
%%% the host it is tracking.
%%% ===================================================================

-module(rd_resource_server).
-behaviour(gen_stomp).

-include("resource.hrl").
-include_lib("handyman/include/jsonerl.hrl").

%% API
-export([start_link/6, start_link/7, start/1, start/2, start/3,
            fetch/1, update/1, stop/1]).


%% gen_stomp callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
            code_change/3]).

-define(DEFAULT_LEASE_TIME, (60 * 60 * 24)). % 1 Day by DEFAULT_LEASE_TIME

-type seconds() :: integer().

-record(state,
    {
        rd,
        host :: string(),
        command_queue :: string(),
        broadcast_queue :: string(),
        lease_time :: seconds(),
        start_time :: seconds()
    }).

%% ===================================================================
%% API
%% ===================================================================

%% @doc start the server
start_link(StompHost, Port, Username, Password, LeaseTime, ResourceHost) ->
    start_link(StompHost, Port, Username, Password, LeaseTime, ResourceHost, []).

start_link(StompHost, Port, Username, Password, LeaseTime, ResourceHost, Resources) ->
    HostBroadcastTopic = string:concat("/topic/rd_", ResourceHost),
    HostCommandQueue = string:concat("/queue/rd_command_", ResourceHost),
    gen_stomp:start_link(?MODULE, StompHost, Port, Username, Password,
        [{HostBroadcastTopic, []}],
        [HostBroadcastTopic, HostCommandQueue, Resources, LeaseTime]).

start(Host, LeaseTime) when is_integer(LeaseTime) ->
    rd_sup:start_child(Host, [], LeaseTime);
start(Host, Resources) when is_list(Resources) ->
    rd_sup:start_child(Host, Resources, ?DEFAULT_LEASE_TIME).

start(Host) ->
    start(Host, ?DEFAULT_LEASE_TIME).

start(Host, Resources, LeaseTime) ->
    rd_sup:start_child(Host, Resources, LeaseTime).

fetch(Pid) ->
    gen_server:call(Pid, fetch).

stop(Pid) ->
    gen_server:cast(Pid, stop).

update(Pid) ->
    gen_server:cast(Pid, update).


%% ===================================================================
%% gen_stomp callbacks
%% ===================================================================

%% @doc No resources specified, need to query host for them.
init([HostBroadcastTopic, HostCommandQueue, Resources, LeaseTime]) ->
    Now = lease:seconds_now(),
    Rd = rd_resource_db:new(),

    %% Do initialization outside of init.
    gen_server:cast(self(), {startup, Resources}),

    State = #state{lease_time = LeaseTime, start_time = Now,
                    command_queue = HostCommandQueue,
                    broadcast_queue = HostBroadcastTopic, rd = Rd},
    TimeLeft = lease:time_left(Now, LeaseTime),
    {ok, State, TimeLeft}.


%% @doc Retrieve all resources
handle_call(fetch, _From,
        #state{lease_time = LeaseTime, start_time = StartTime, rd = Rd} = State) ->
    Resources = rd_resource_db:all(Rd),
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {reply, {ok, Resources}, State, TimeLeft}.

%% @doc
handle_cast(update,
        #state{lease_time = LeaseTime, start_time = StartTime} = State) ->
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {noreply, State, TimeLeft};

handle_cast([{message, Message}, {queue, Queue}],
        #state{start_time = StartTime, lease_time = LeaseTime,
                broadcast_queue = BroadcastQueue, rd = Rd} = State) ->
    handle_message(Rd, Message, Queue, BroadcastQueue),
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {noreply, State, TimeLeft};

%% @doc Complete startup when no resources were given by asking for
%% for the resources from the server.
handle_cast({startup, []}, #state{start_time = StartTime,
                                lease_time = LeaseTime,
                                command_queue = CommandQueue} = State) ->
    gen_stomp:send(CommandQueue, "RESOURCES", []),
    {noreply, State, lease:time_left(StartTime, LeaseTime)};

%% @doc Add resources that were specified in startup.
handle_cast({startup, Resources},
        #state{start_time = StartTime,
                lease_time = LeaseTime, rd = Rd} = State) ->
    add_resources(Rd, Resources),
    {noreply, State, lease:time_left(StartTime, LeaseTime)};

%% @doc Stop the server.
handle_cast(stop, State) ->
    {stop, normal, State}.

%% @doc On timeout go out and query for the resources.
handle_info(timeout, #state{lease_time = LeaseTime, rd = Rd,
                            command_queue = CommandQueue} = State) ->
    % On timeout we go and query for the resources.
    Now = lease:seconds_now(),
    NewTimeout = lease:time_left(Now, LeaseTime),
    rd_resource_db:delete_all(Rd),
    gen_stomp:send(CommandQueue, "RESOURCES", []),
    {noreply, State#state{start_time = Now}, NewTimeout}.

terminate(_Reason, _State) ->
    % Remove mapping for process
    rd_store:delete_by_pid(self()),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Local functions
%% ===================================================================

%% @doc handle messages on the message queues
handle_message(Rd, [{type, "MESSAGE"},
                    {header, _Header}, {body, Body}],
                Queue, BroadcastQueue) ->
    case from_broadcast_queue(Queue) of
        true -> add_message_as_resource(Rd, Body);
        false -> handle_commands(Body, BroadcastQueue, Rd)
    end;
%% @doc Handle non-message types
handle_message(_Rd, _Message, _Queue, _BroadcastQueue) ->
    ok.

%% @doc check if its from the topic queue
from_broadcast_queue(QueueName) ->
    string:str(QueueName, "/topic") =/= 0.

%% @doc Add a list of resources to our database of resources
add_resources(_Rd, []) ->
    ok;
add_resources(Rd, [R|T]) ->
    rd_resource_db:insert(Rd, R),
    add_resources(Rd, T).

%% @doc Resource comes in as JSON, turn back to record and add to database.
add_message_as_resource(Rd, Message) ->
    R = ?json_to_record(resource, Message),
    rd_resource_db:insert(Rd, R).

%% @doc Handle different types of commands.
handle_commands("RESOURCES", BroadcastQueue, Rd) ->
    broadcast_resources(BroadcastQueue, Rd),
    ok;
handle_commands(Command, Queue, _Rd) ->
    % Add error logging here.
    io:format("handle_commands fall through ~p:~p~n", [Command, Queue]),
    ok.

%% @doc Send each resource one at a time.
broadcast_resources(BroadcastQueue, Rd) ->
    Resources = rd_resource_db:all(Rd),
    lists:foreach(
        fun (Resource) ->
            broadcast_resource(Resource, BroadcastQueue)
        end, Resources).

%% @doc Transform resource to JSON and then broadcast out on STOMP
broadcast_resource(Resource, BroadcastQueue) ->
    J = ?record_to_json(resource, Resource),
    gen_stomp:send(BroadcastQueue, J, []).



