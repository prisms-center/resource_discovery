%%% ===================================================================
%%% @doc
%%% ===================================================================

-module(rd_ping_server).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, ping/1, ping_all/0]).

%% Exported for spawn
-export([ping_host/2]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
            terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(DEFAULT_LEASE_TIME, (60 * 60)). % Check every hour

-record(state, {lease_time, start_time}).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    start_link(?DEFAULT_LEASE_TIME).

start_link(LeaseTime) ->
    gen_server:start_link({local, ?SERVER}, [LeaseTime], []).

ping(Host) ->
    gen_server:cast(?SERVER, {ping, Host}).

ping_all() ->
    gen_server:cast(?SERVER, ping_all).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([LeaseTime]) ->
    %% Trap exits and handle ourselves.
    process_flag(trap_exit, true),
    Now = lease:seconds_now(),
    TimeLeft = lease:time_left(Now, LeaseTime),
    {ok, #state{lease_time = LeaseTime, start_time = Now}, TimeLeft}.

handle_call(_Msg, _From, #state{lease_time = LeaseTime,
                                start_time = StartTime} = State) ->
    % Error log unknown message
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {reply, ok, State, TimeLeft}.

handle_cast({ping, Host}, #state{lease_time = LeaseTime,
                                    start_time = StartTime} = State) ->
    case rd_store:lookup(Host) of
        {ok, Pid} -> start_pinger(Host, Pid);
        {error, not_found} -> ok
    end,
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {noreply, State, TimeLeft};
handle_cast(ping_all, #state{lease_time = LeaseTime,
                                start_time = StartTime} = State) ->
    start_pingers(),
    TimeLeft = lease:time_left(StartTime, LeaseTime),
    {noreply, State, TimeLeft};
handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};
handle_info(timeout, #state{lease_time = LeaseTime} = State)->
    start_pingers(),
    Now = lease:seconds_now(),
    NewTimeout = lease:time_left(Now, LeaseTime),
    {noreply, State#state{start_time = Now}, NewTimeout}.

 terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Local
%% ===================================================================

start_pingers() ->
    lists:foreach(fun start_pinger/1, rd_store:all()).

start_pinger({Host, Pid}) ->
    start_pinger(Host, Pid).

start_pinger(Host, Pid) ->
    spawn(?MODULE, ping_host, [Host, Pid]).

ping_host(Host, Pid) ->
    try
        {ok, Sock} = gen_tcp:connect(Host, 12233, [{active, false}]),
        gen_tcp:send(Sock, "PING"),
        % wait 10 seconds for a response
        {ok, _Response} = gen_tcp:recv(Sock, 0, [10 * 1000])
    catch
        _:_ ->
            %% Socket communication error. Host must be down.
            %% Remove host by having its resource tracker exit.
            rd_resource_server:stop(Pid)
    end.




