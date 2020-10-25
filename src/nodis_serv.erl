%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Node discover and manager
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis_serv).

-behaviour(gen_server).

%% API
-export([start_link_local/0, start_link_local/1]).
-export([start_link/1]).
-export([stop/0, stop/1]).
-export([subscribe/0, unsubscribe/1]).
-export([subscribe/1, unsubscribe/2]).
-export([wait/1, wait/2]).
-export([get_state/1, get_state/2]).

%% test
-export([send/1, send/2]).
%% simulation
-export([simping/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).


-export([reuse_port/0]).

%% Test API
-export([i/0]).

-compile(export_all).

%% -define(dbg(F,A), io:format((F),(A))).
-define(dbg(F,A), ok).
-define(err(F,A), io:format((F),(A))).
-define(warn(F,A), io:format((F),(A))).

-define(SERVER, ?MODULE).

-type time_ms() :: non_neg_integer().
-type tick()    :: integer().  %% monotonic tick

%% subscriber for node events
-record(sub,
	{
	 ref :: reference(),
	 pid :: pid()
	}).



-record(node,
	{
	 state = undefined :: nodis:node_state(),
	 addr :: nodis:node_address(),  %% ip address of node
	 ival :: time_ms(),          %% node announce to send this often in ms
	 first_seen :: tick(),       %% first time around
	 last_seen :: tick(),        %% we have not seen the node since
	 up_tick :: tick(),          %% tick when ws sent up message
	 down_tick :: tick()         %% tick when marked as down
	}).

-type ifindex_t() :: non_neg_integer().
-type addr_map_t() ::
	#{ inet:ip_address() => [ifindex_t()],
	   string() => [ifindex_t()],
	   ifindex_t() => [inet:ip_address()] }.

-define(NODIS_DEFAULT_PING_DELAY, 1000). %% 1s before first ping
-define(NODIS_DEFAULT_PING_INTERVAL, 5000). %% 5s
-define(NODIS_DEFAULT_MAX_PINGS_LOST, 3).   %% before being regarded as gone
-define(NODIS_DEFAULT_MIN_WAIT_TIME, 30000). %% test 30seconds
-define(NODIS_DEFAULT_MIN_DOWN_TIME, 60000). %% test 30seconds
%% -define(NODIS_DEFAULT_MIN_WAIT_TIME, (5*60*1000)).  %% 5min
%% -define(NODIS_DEFAULT_MIN_DOWN_TIME, (10*60*1000)). %% 10min
-define(NODIS_DEFAULT_MAX_UP_NODES,      10).
-define(NODIS_DEFAULT_MAX_PENDING_NODES, 100).
-define(NODIS_DEFAULT_MAX_DOWN_NODES,    2000).
-define(NODIS_DEFAULT_MAX_WAIT_NODES,    1000).

-record(conf,
	{
	 input = #{} :: nodis_option(), %% input options (override!)
	 simulation = false :: boolean(),
	 hops :: non_neg_integer(),   %% max number of hops (ttl)
	 loop :: boolean(),           %% loop on host (other applications)
	 magic :: binary(),           %% magic ping
	 %% delay until first ping
	 ping_delay = ?NODIS_DEFAULT_PING_DELAY :: time_ms(),
	 %% after that send with this interval
	 ping_interval = ?NODIS_DEFAULT_PING_INTERVAL :: time_ms(),
	 %% down if we missed this number of pings
	 max_pings_lost = ?NODIS_DEFAULT_MAX_PINGS_LOST :: non_neg_integer(),
	 %% resend up after min_wait_time
	 min_wait_time = ?NODIS_DEFAULT_MIN_WAIT_TIME :: time_ms(),  
	 %% allow down node to be pending after min_down_time
	 min_down_time = ?NODIS_DEFAULT_MIN_DOWN_TIME :: time_ms(),  
	 %% max number of nodes in up state
	 max_up_nodes = ?NODIS_DEFAULT_MAX_UP_NODES :: non_neg_integer(),
	 %% max number of nodes in pending state, waiting to get up
	 max_pending_nodes = ?NODIS_DEFAULT_MAX_PENDING_NODES :: 
	   non_neg_integer(),
	 %% max number of nodes that have been reschduled after up
	 %% timeout or marked as done (but still up)
	 %% wait nodes will then be put on pending -> up state when possible
	 max_wait_nodes = ?NODIS_DEFAULT_MAX_WAIT_NODES :: non_neg_integer(),
	 %% max number of remembered nodes that have been pending|up
	 max_down_nodes = ?NODIS_DEFAULT_MAX_DOWN_NODES :: non_neg_integer()
	}).

-record(nodes, 
	{
	 up      = #{} :: #{ nodis:node_address() => #node {} },
	 pending = #{} :: #{ nodis:node_address() => #node {} },
	 wait    = #{} :: #{ nodis:node_address() => #node {} },
	 down    = #{} :: #{ nodis:node_address() => #node {} }
	}).

-record(s,
	{
	 in,          %% incoming udp socket
	 out,         %% outgoing udp socket
	 maddr,       %% multicast address
	 ifaddr,      %% interface address
	 mport,       %% port number used
	 oport,       %% output port number used
	 conf :: #conf{},
	 ping_tmr,    %% multicase ping each timeout
	 nodes = #nodes{} :: #nodes{},
	 subs = #{} :: #{ reference() => #sub{} },
	 %% string or ip-address-tuple to index-list map
	 addr_map = #{} :: addr_map_t()
	}).

%% MAC specific reuseport options
-define(SO_REUSEPORT, 16#0200).

-define(IPPROTO_IP,   0).
-define(IPPROTO_TCP,  6).
-define(IPPROTO_UDP,  17).
-define(SOL_SOCKET,   16#ffff).

-define(IPPROTO_IPV6, 41).

-define(IPV6_MULTICAST_IF,	17).
-define(IPV6_MULTICAST_HOPS,	18).
-define(IPV6_MULTICAST_LOOP,	19).
-define(IPV6_ADD_MEMBERSHIP,	20).
-define(IPV6_DROP_MEMBERSHIP,	21).

-define(ANY4, {0,0,0,0}).
-define(ANY6, {0,0,0,0,0,0,0,0}).

-define(NODIS_MAGIC, <<"ERLGAMAL">>).
-define(NODIS_MULTICAST_ADDR4, {224,0,0,1}).
-define(NODIS_MULTICAST_ADDR6, {16#FF12,0,0,0,0,0,0,1234}).
-define(NODIS_UDP_PORT,        51812).

-define(NODIS_MULTICAST_IF4,  ?ANY4).
-define(NODIS_MULTICAST_IF6,  ?ANY6).


-type nodis_option() ::
	#{ simulation => boolean(),
	   magic =>  binary(),
	   family => inet | inet6,          %% address family
	   device => undefined | string(),  %% interface name
	   maddr =>  inet:ip_address(),
	   ifaddr => inet:ip_address(),
	   hops   => non_neg_integer(),
	   loop   => boolean(),
	   timeout => ReopenTimeout::integer(),
	   ping_delay => time_ms(),
	   ping_interval => time_ms(),
	   min_wait_time => time_ms(),
	   min_down_time => time_ms(),
	   max_pings_lost => non_neg_integer(),
	   max_up_nodes => non_neg_integer(),
	   max_pending_nodes => non_neg_integer(),
	   max_down_nodes => non_neg_integer(),
	   max_wait_nodes => non_neg_integer()
	 }.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------

-spec start_link_local() -> {ok,pid()} | {error,Reason::term()}.
start_link_local() ->
    start_link_local(#{}).

-spec start_link_local(Opts::nodis_option()) ->
	  {ok,pid()} | {error,Reason::term()}.

start_link_local(Opts) ->
    gen_server:start_link({local,?SERVER}, ?MODULE, [Opts], []).

-spec start_link(Opts::nodis_option()) ->
	  {ok,pid()} | {error,Reason::term()}.

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

-spec i() -> ok | {error, Error::atom()}.
i() ->
    gen_server:call(?SERVER, dump).

-spec i(Pid::pid()) -> ok | {error, Error::atom()}.
i(Pid) ->
    gen_server:call(Pid, dump).

-spec stop() -> ok | {error, Error::atom()}.
stop() ->
    gen_server:call(?SERVER,stop).

-spec stop(Pid::pid()) -> ok | {error, Error::atom()}.

stop(Pid) ->
    gen_server:call(Pid,stop).

-spec subscribe() -> {ok,reference()} | {error, Error::atom()}.
subscribe() ->
    gen_server:call(?SERVER, {subscribe,self()}).

-spec subscribe(Pid::pid()) -> {ok,reference()} | {error, Error::atom()}.
subscribe(Pid) ->
    gen_server:call(Pid, {subscribe,self()}).

-spec unsubscribe(Ref::reference()) -> ok | {error, Error::atom()}.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe,Ref}).

-spec unsubscribe(Pid::pid(),Ref::reference()) -> ok | {error, Error::atom()}.
unsubscribe(Pid,Ref) ->
    gen_server:call(Pid, {unsubscribe,Ref}).

%% Put a node from up state into wait state
-spec wait(Addr::nodis:node_address()) -> ok.
wait(Addr) ->
    gen_server:call(?SERVER, {wait,Addr}).

-spec wait(Pid::pid(), Addr::nodis:node_address()) -> ok.
wait(Pid,Addr) ->
    gen_server:call(Pid, {wait,Addr}).

%% Get neighbour state
-spec get_state(Addr::nodis:node_address()) -> nodis:node_state().
get_state(Addr) ->
    gen_server:call(?SERVER, {get_state,Addr}).

%% Get neighbour state
-spec get_state(Pid::pid(), Addr::nodis:node_address()) -> nodis:node_state().
get_state(Pid,Addr) ->
    gen_server:call(Pid, {get_state,Addr}).

%% test - broadcast any message
send(Data) ->
    send(?SERVER, Data).
send(Pid, Data) ->
    gen_server:call(Pid,{send,Data}).
%%
%% simulation feed nodis_serv with simulated ping data
%% will show up with the player subscriver as
%% {pending,Addr} | {up, Addr} | {missed, Addr} | {down, Addr}
%% NOT {wait,Addr} we must handle this from application
%%
simping(Pid, {A,B,C,D}, Port, IVal) when
      (A bor B bor C bor D) band (bnot 16#ff) =:= 0,
      is_integer(Port),
      is_integer(IVal) ->
    gen_server:cast(Pid, {simping,{A,B,C,D,Port},IVal});
simping(Pid, {A,B,C,D,E,F,G,H}, Port, IVal) when
      (A bor B bor C bor D bor E bor F bor G bor H) band (bnot 16#ffff) =:= 0,
      is_integer(Port),
      is_integer(IVal) ->
    gen_server:cast(Pid, {simping,{A,B,C,D,E,F,G,H,Port},IVal}).

%% util
select_any(inet) -> ?ANY4;
select_any(inet6) -> ?ANY6.

select_if(inet) -> ?NODIS_MULTICAST_IF4;
select_if(inet6) -> ?NODIS_MULTICAST_IF6.

select_mcast(inet) -> ?NODIS_MULTICAST_ADDR4;
select_mcast(inet6) -> ?NODIS_MULTICAST_ADDR6.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([InputOpts]) ->
    Opts = read_options(InputOpts),
    ?dbg("init opts = ~p\n", [Opts]),
    Family = maps:get(family, Opts, inet),
    Device = maps:get(device, Opts, undefined),
    MAddr  = maps:get(maddr, Opts,  select_mcast(Family)),
    Mhops  = maps:get(hops, Opts, 1),
    Mloop  = maps:get(loop, Opts, true),
    Laddr0 = maps:get(ifaddr, Opts, Device),
    Magic  = maps:get(magic, Opts, ?NODIS_MAGIC),
    Simulation = maps:get(simulation, Opts, false),
    Simulator = case config_lookup([simulator], false) of
		    false -> false;
		    _ -> true
		end,
    Conf0 = #conf {
	       input  = InputOpts,  %% keep override options
	       simulation = Simulation orelse Simulator,
	       hops  = Mhops,
	       loop  = Mloop,
	       magic = Magic },
    Conf = read_conf(Conf0, Opts),

    case Simulation of
	true ->
	    PingTmr = start_ping(Conf#conf.ping_delay),
	    {ok, #s{
		     conf  = Conf,
		     ping_tmr = PingTmr
		   }};
	false ->
	    MPort = ?NODIS_UDP_PORT,
	    AddrMap = make_addr_map(),
	    Laddr = if is_tuple(Laddr0) ->
			    Laddr0;
		       is_list(Laddr0) ->
			    case lookup_ip(Laddr0, Family, AddrMap) of
				[] ->
				    ?warn("No such interface ~p",[Laddr0]),
				    select_any(Family);
				[IP|_] -> IP
			    end;
		       Laddr0 =:= any; Laddr0 =:= undefined ->
			    select_any(Family);
		       true ->
			    ?warn("No such interface ~p",[Laddr0]),
			    select_any(Family)
		    end,
	    SendOpts = [Family,{active,false}] ++
		multicast_if(Family,Laddr,AddrMap) ++
		multicast_ttl(Family,Mhops) ++
		multicast_loop(Family,Mloop),
	    ?dbg("Sendopt = ~p\n", [[Family,{active,false},
				     {multicast_if,Laddr},
				     {multicast_ttl,Mhops},
				     {multicast_loop,Mloop}]]),
	    case gen_udp:open(0, SendOpts) of
		{ok,Out} ->
		    {ok,OutPort} = inet:port(Out),
		    ?dbg("output port = ~w\n", [OutPort]),
		    RecvOpts = [Family,{reuseaddr,true},
				{mode,binary},{active,false}] ++
			reuse_port() ++
			add_membership(Family,MAddr,Laddr,AddrMap),
		    ?dbg("RecvOpts = ~p\n", [RecvOpts]),
		    case catch gen_udp:open(MPort,RecvOpts) of
			{ok,In} ->
			    inet:setopts(In, [{active, true}]),
			    PingTmr = start_ping(Conf#conf.ping_delay),
			    {ok, #s{ in    = In,
				     out   = Out,
				     maddr = MAddr,
				     mport = MPort,
				     oport = OutPort,
				     conf  = Conf,
				     ping_tmr = PingTmr,
				     addr_map = AddrMap
				   }};
			{error, _Reason} = Error ->
			    {stop, Error}
		    end;
		Error ->
		    {stop, Error}
	    end
    end.


%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call({subscribe,Pid}, _From, S) ->
    Mon = erlang:monitor(process, Pid),
    Sub = #sub { ref=Mon, pid=Pid },
    Subs = (S#s.subs)#{ Mon => Sub },
    %% deliver up events to new subscriber
    maps:fold(
      fun(Addr,_N,_Acc) ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, {up,Addr}}
      end, ok, (S#s.nodes)#nodes.up),
    {reply, {ok,Mon}, S#s { subs = Subs }};
handle_call({unsubscribe,Ref}, _From, S) ->
    case maps:take(Ref, S#s.subs) of
	error ->
	    {reply,ok,S};
	{Sub,Subs} ->
	    erlang:demonitor(Sub#sub.ref, [flush]),
	    {reply,ok,S#s { subs=Subs }}
    end;
handle_call({wait,Addr}, _From, S) ->
    case find_node(Addr, S#s.nodes) of
	false ->
	    {reply, {error, not_found}, S};  %% node not found
	N when N#node.state =:= up ->
	    %% maybe notify down message? probably not... depends
	    Now = erlang:monotonic_time(),
	    %% well we do not notify wait since we where informed to wait
	    Nodes = move_node_wait(N, S#s.nodes, Now),
	    {reply, ok, S#s { nodes = Nodes}};
	_N ->
	    {reply, {error, not_up}, S}
    end;
handle_call({get_state,Addr}, _From, S) ->
    case find_node(Addr, S#s.nodes) of
	false ->
	    {reply, undefined, S};
	N ->
	    {reply, N#node.state, S}
    end;
handle_call(dump, _From, S) ->
    dump_state(S),
    {reply, ok, S};
handle_call({send,Mesg}, _From, S) ->
    {Reply,S1} = send_message(Mesg,S),
    {reply, Reply, S1};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error,bad_call}, S}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({send,Mesg}, S) ->
    {_, S1} = send_message(Mesg, S),
    {noreply, S1};
handle_cast({simping,Addr,IVal}, S) ->
    handle_node(Addr,IVal,S);
handle_cast(_Mesg, S) ->
    ?dbg("nodis: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,Addr0,Port,Data}, S) when S#s.in == U ->
    IsLocalAddress = maps:get(Addr0, S#s.addr_map, []) =/= [],
    ?dbg("nodis: udp ~s:~w (~s) ~p\n",
	 [inet:ntoa(Addr),Port, if IsLocalAddress -> "local";
				   true -> "remote" end, Data]),
    if IsLocalAddress, Port =:= S#s.oport -> %% this is our output! (loop=true)
	    %%?dbg("nodis: discard ~s:~w ~p\n",  [inet:ntoa(Addr0),Port,Data]),
	    {noreply, S};
       true ->
	    Addr = if IsLocalAddress -> %% testing locally
			   erlang:append_element(Addr0, Port);
		      true ->
			   Addr0
		   end,
	    case Data of
		<<MLen:32, Magic:MLen/binary, IVal:32, _Garbage/binary>> when
		      Magic =:= (S#s.conf)#conf.magic ->
		    handle_node(Addr,IVal,S);
		_ ->
		    ?dbg("ignored data from ~s:~w = ~p\n",
			 [format_addr(Addr),Port,Data]),
		    {noreply, S}
	    end
    end;
handle_info({timeout,Tmr,ping}, S) when Tmr =:= S#s.ping_tmr ->
    send_ping(S),
    PingTmr = start_ping((S#s.conf)#conf.ping_interval),
    S1 = gc_nodes(S),
    {noreply, S1#s { ping_tmr = PingTmr }};
handle_info(reload, S) ->
    Conf = read_conf(S#s.conf),
    %% FIXME: add code to adjust node lists according to above
    {noreply, S#s{conf=Conf}};
handle_info({'DOWN',Ref,process,_Pid,_Reason}, S) ->
    case maps:take(Ref, S#s.subs) of
	error ->
	    {noreply,S};
	{_S,Subs} ->
	    ?dbg("subscription from pid ~p deleted reason=~p",
		 [_Pid, _Reason]),
	    {noreply,S#s { subs=Subs }}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

config_lookup(Keys, Default) ->
    try config:lookup(Keys, Default) of
	Value -> Value
    catch
	error:badarg ->
	    Default
    end.
    
read_conf(Conf) ->
    read_conf(Conf, Conf#conf.input).

read_conf(Conf, InputOpts) ->
    read_conf_(Conf, read_options(InputOpts)).

read_conf_(Conf, Map) ->
    PingDelay = maps:get('ping-delay',Map,Conf#conf.ping_delay),
    PingInterval = maps:get('ping-interval',Map,Conf#conf.ping_interval),
    MaxPingsLost = maps:get('max-pings-lost',Map,Conf#conf.max_pings_lost),
    MinWaitTime  = maps:get('min-wait-time',Map, Conf#conf.min_wait_time),
    MinDownTime  = maps:get('min-down-time',Map, Conf#conf.min_wait_time),
    MaxUpNodes = maps:get('max-up-nodes',Map,Conf#conf.max_up_nodes),
    MaxPendingNodes = maps:get('max-pending-nodes',Map,
			       Conf#conf.max_pending_nodes),
    MaxDownNodes = maps:get('max-down-nodes',Map,Conf#conf.max_down_nodes),
    MaxWaitNodes = maps:get('max-wait-nodes',Map,Conf#conf.max_wait_nodes),
    Conf#conf {
      ping_interval = PingInterval,
      ping_delay = PingDelay,
      max_pings_lost = MaxPingsLost,
      min_wait_time = MinWaitTime,
      min_down_time = MinDownTime,
      max_up_nodes = MaxUpNodes,
      max_pending_nodes = MaxPendingNodes,
      max_down_nodes = MaxDownNodes,
      max_wait_nodes = MaxWaitNodes
     }.

%% input options override environment options
read_options(InputOpts) ->
    Env = read_all_env(),
    if is_map(InputOpts) ->
	    maps:merge(Env, InputOpts);
       is_list(InputOpts) ->
	    maps:merge(Env, maps:from_list(InputOpts))
    end.

read_all_env() ->
    case application:get_env(nodis, nodis) of
	{ok,[{nodis,Opts}]} when is_list(Opts) ->
	    maps:from_list(Opts);
	_ -> %% assume application style options
	    maps:from_list(application:get_all_env(nodis))
    end.


start_ping(Delay) when is_integer(Delay), Delay > 0 ->
    erlang:start_timer(Delay, self(), ping).

handle_node(Addr,IVal,S) ->
    Nodes = S#s.nodes,
    case find_node(Addr, Nodes) of
	false ->
	    Nodes1 = add_node(Addr, IVal, Nodes, S),
	    {noreply, S#s { nodes = Nodes1 }};
	N0 ->
	    Now = erlang:monotonic_time(),
	    N = N0#node { last_seen = Now, ival = IVal },
	    case N#node.state of
		down ->
		    DTime = time_diff_ms(Now,N#node.down_tick),
		    if DTime > (S#s.conf)#conf.min_down_time ->
			    {noreply, S#s { nodes = handle_down(N, Nodes, Now, S)}};
		       true ->
			    {noreply, S#s { nodes = update_node(N, Nodes) }}
		    end;
		wait ->
		    UTime = time_diff_ms(Now,N#node.up_tick),
		    if UTime > (S#s.conf)#conf.min_wait_time ->
			    {noreply, S#s { nodes = handle_wait(N, Nodes, Now, S) }};
		       true ->
			    {noreply, S#s { nodes = update_node(N, Nodes) }}
		    end;
		pending ->
		    {noreply, S#s { nodes = handle_pending(N, Nodes, Now, S)}};
		up ->
		    {noreply, S#s { nodes = update_node(N, Nodes) }}
	    end
    end.

handle_pending(N, Nodes, Now, S) ->
    Conf = S#s.conf,
    if map_size(Nodes#nodes.up) < Conf#conf.max_up_nodes ->
	    notify_subs(S, {up, N#node.addr}),
	    move_node_up(N, Nodes, Now);
       true -> %% stay pending
	    update_node(N, Nodes)
    end.

%% node is in down state and we are in refresh_interval  down -> up
handle_down(N, Nodes, Now, S) ->
    Conf = S#s.conf,
    if map_size(Nodes#nodes.pending) =:= 0,
       map_size(Nodes#nodes.up) < Conf#conf.max_up_nodes ->
	    notify_subs(S, {up, N#node.addr}),
	    move_node_up(N, Nodes, Now);
       map_size(Nodes#nodes.pending) < Conf#conf.max_pending_nodes ->
	    notify_subs(S, {pending, N#node.addr}),
	    move_node_pending(N, Nodes);
       true -> %% stay down
	    update_node(N, Nodes)
    end.

handle_wait(N, Nodes, Now, S) ->
    Conf = S#s.conf,
    if map_size(Nodes#nodes.pending) =:= 0,
       map_size(Nodes#nodes.up) < Conf#conf.max_up_nodes ->
	    notify_subs(S, {up, N#node.addr}),
	    move_node_up(N, Nodes, Now);
       map_size(Nodes#nodes.pending) < Conf#conf.max_pending_nodes ->
	    notify_subs(S, {pending, N#node.addr}),
	    move_node_pending(N, Nodes);
       true ->
	    update_node(N, Nodes)
    end.

gc_nodes(S) ->
    Time = erlang:monotonic_time(),
    MaxPingsLost = (S#s.conf)#conf.max_pings_lost,
    Nodes = gc_nodes_(S#s.nodes, Time, MaxPingsLost, S),
    S#s{ nodes = Nodes }.

gc_nodes_(Nodes, Now, MaxPingsLost, S) ->
    %% scan node up and move them to down when not heard from
    Down0 = [],
    Down1 = down_nodes(Nodes#nodes.up, Down0, Now, MaxPingsLost, S),
    Down2 = down_nodes(Nodes#nodes.pending, Down1, Now, MaxPingsLost, S),
    Down3 = down_nodes(Nodes#nodes.wait, Down2, Now, MaxPingsLost, S),
    Nodes1 = lists:foldl(
	       fun(N, Ns) ->
		       move_node_down(N, Ns, Now, S#s.conf)
	       end, Nodes, Down3),
    Nodes2 = up_nodes(Nodes1#nodes.pending, Nodes1, Now, S),
    wakeup_nodes(Nodes2#nodes.wait, Nodes2, Now, S).

%% nodes that are in pending states shoule wake up and go to up
up_nodes(PendMap, Nodes, Now, S) ->
    maps:fold(
      fun(_Addr, N, Ns) ->
	      handle_pending(N, Ns, Now, S)
      end, Nodes, PendMap).

%% nodes that are in wait states shoule wake up and go to pending
wakeup_nodes(WaitMap, Nodes, Now, S) ->
    maps:fold(
      fun(_Addr, N, Ns) ->
	      UTime = time_diff_ms(Now,N#node.up_tick),
	      if UTime > (S#s.conf)#conf.min_wait_time ->
		      handle_wait(N, Ns, Now, S);
		 true ->
		      Ns
	      end
      end, Nodes, WaitMap).

%% Build a list over nodes that are down
down_nodes(NodeMap, Down, Now, MaxPingsLost, S) ->
    maps:fold(
      fun(_Addr, N=#node{last_seen=LastSeen}, Acc) ->
	      LTime = time_diff_us(Now, LastSeen),
	      if LTime > N#node.ival*MaxPingsLost*1000 ->
		      if N#node.state =:= up ->
			      notify_subs(S, {down, N#node.addr});
			 true ->
			      ok
		      end,
		      [N#node{down_tick=Now}|Acc];
		 LTime > N#node.ival*1000 ->
		      if N#node.state =:= up ->
			      notify_subs(S, {missed, N#node.addr});
			 true ->
			      ok
		      end,
		      Acc;
		 true ->
		      Acc
	      end
      end, Down, NodeMap).

notify_subs(S, Message) ->
    maps:fold(
      fun(_Ref,Sub,_Acc) ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, Message}
      end, ok, S#s.subs).

dump_state(S) ->
    Time = erlang:monotonic_time(),
    MaxPingsLost = (S#s.conf)#conf.max_pings_lost,
    Nodes = S#s.nodes,
    N0 = 1,
    N1 = dump_nodes(Nodes#nodes.up, N0, Time, MaxPingsLost),
    N2 = dump_nodes(Nodes#nodes.pending, N1, Time, MaxPingsLost),
    N3 = dump_nodes(Nodes#nodes.wait, N2, Time, MaxPingsLost),
    _N4 = dump_nodes(Nodes#nodes.down, N3, Time, MaxPingsLost),
    ok.

dump_nodes(Map, I0, Now, MaxPingsLost) ->
    maps:fold(
      fun(Addr,N=#node{state=State,first_seen=FT,last_seen=LT},I) ->
	      UTime = time_diff_us(Now,FT),
	      LTime = time_diff_us(Now,LT),
	      LTm = 
		  if LTime > N#node.ival*MaxPingsLost*1000 ->
			  dead;
		     LTime > N#node.ival*1000 ->
			  missed;
		     true ->
			  ok
		  end,
	      AddrString = format_addr(Addr),
	      io:format("~w: state=~w ~s uptime: ~.2fs last: ~.2fs ival=~w ltm=~s\n",
			[I, State, 
			 AddrString,
			 UTime/1000000,
			 LTime/1000000,
			 N#node.ival,
			 LTm]),
	      I+1
      end, I0, Map).

time_diff_ms(A, B) ->
    erlang:convert_time_unit(A - B,native,millisecond).

time_diff_us(A, B) ->
    erlang:convert_time_unit(A - B,native,microsecond).

format_addr(Addr) ->
    case Addr of
	{A,B,C,D,Port} -> %% from simulation/test
	    inet:ntoa({A,B,C,D}) ++ ":" ++ 
		integer_to_list(Port);
	{A,B,C,D,E,F,G,H,Port} -> %% from simulation/test
	    "["++inet:ntoa({A,B,C,D,E,F,G,H}) ++ "]:" ++ 
		integer_to_list(Port);
	Addr ->
	    inet:ntoa(Addr)
    end.

%% socket options
%%  reuse_port may be needed to allow host to listen to same port
%%  multiple times.
reuse_port() ->
    case os:type() of
	{unix,Type} when Type =:= darwin; Type =:= freebsd ->
	    [{raw,?SOL_SOCKET,?SO_REUSEPORT,<<1:32/native>>}];
	_ ->
	    []
    end.

%% multicast_if for ipv4 and ipv6
multicast_if(inet, Laddr, _AddrMap) -> [{multicast_if, Laddr}];
multicast_if(inet6, ?ANY6, _AddrMap) ->
    [{raw,?IPPROTO_IPV6,?IPV6_MULTICAST_IF,<<0:32/native>>}];
multicast_if(inet6, Laddr, AddrMap) ->
    IfIndexList = ifindex(Laddr, AddrMap),
    case IfIndexList of
	[IfIndex|Multi] ->
	    if Multi =/= [] ->
		    ?warn("address ~s exist on multiple interfaces ~w\n",
			  [inet:ntoa(Laddr), IfIndexList]);
	       true ->
		    ok
	    end,
	    [{raw,?IPPROTO_IPV6,?IPV6_MULTICAST_IF,<<IfIndex:32/native>>}];
	[] ->
	    ?warn("error ifindex: ~s : ~p\n", [inet:ntoa(Laddr), enoent]),
	    []
    end.

%% multicast_ttl for ipv4 and ipv6
multicast_ttl(inet, TTL) -> [{multicast_ttl, TTL}];
multicast_ttl(inet6, TTL) ->
    [{raw,?IPPROTO_IPV6,?IPV6_MULTICAST_HOPS,<<TTL:32/native>>}].

%% multicast_loop for ipv4 and ipv6, allow that sending
%% from one application also loopback to other (and self)
%% applications on the same host
multicast_loop(inet, Loop) -> [{multicast_loop, Loop}];
multicast_loop(inet6, Loop) ->
    L = if Loop -> 1; true -> 0 end,
    [{raw,?IPPROTO_IPV6,?IPV6_MULTICAST_LOOP,<<L:32/native>>}].

%% struct ipv6_mreq {
%%	/* IPv6 multicast address of group */
%%	struct in6_addr ipv6mr_multiaddr;
%%
%%	/* local IPv6 address of interface */
%%	int		ipv6mr_ifindex;
%% };
add_membership(inet,MAddr,LAddr,_AddrMap) ->
    [{add_membership,{MAddr,LAddr}}];
add_membership(inet6,MAddr,?ANY6,_AddrMap) ->
    Addr = ip_to_binary(MAddr),
    MReq = <<Addr/binary,0:32/native>>,
    [{raw,?IPPROTO_IPV6,?IPV6_ADD_MEMBERSHIP,MReq}];
add_membership(inet6,MAddr,LAddr,AddrMap) ->
    IfIndexList = ifindex(LAddr,AddrMap),
    case IfIndexList of
	[IfIndex|Multi] ->
	    if Multi =/= [] ->
		    ?warn("address ~s exist on multiple interfaces ~w\n",
			  [inet:ntoa(LAddr), IfIndexList]);
	       true ->
		    ok
	    end,
	    Addr = ip_to_binary(MAddr),
	    MReq = <<Addr/binary,IfIndex:32/native>>,
	    [{raw,?IPPROTO_IPV6,?IPV6_ADD_MEMBERSHIP,MReq}];
	[] ->
	    ?warn("error ifindex: ~s : ~p\n", [inet:ntoa(LAddr), enoent]),
	    []
    end.

ip_to_binary(IP) when tuple_size(IP) =:= 4 ->
    list_to_binary(tuple_to_list(IP));
ip_to_binary(IP) when tuple_size(IP) =:= 8 ->
    << << X:16 >> || X <- tuple_to_list(IP)>>.

lookup_ip(Name,Family,AddrMap) ->
    case inet:parse_address(Name) of
	{error,_} -> %% assume interface name
	    IndexList = ifindex(Name,AddrMap),
	    lists:append([filter_family_list(maps:get(I,AddrMap),Family) ||
			     I <- IndexList ]);
	IP ->
	    [IP]
    end.

%% lookup interface index from Address or Name
-spec ifindex(string()|inet:ip_address()) ->
	  [non_neg_integer()].

ifindex(Key) ->
    ifindex(Key, make_addr_map()).

-spec ifindex(string()|inet:ip_address(), Map::addr_map_t()) ->
	  [non_neg_integer()].

ifindex(Key, AddrMap) ->
    maps:get(Key, AddrMap, []).

make_addr_map() ->
    IndexMap = make_index_map(),
    case inet:getifaddrs() of
	{ok,List} ->
	    make_addr_map_(List, IndexMap, #{});
	{error,Reason} ->
	    ?warn("unable to get interface list: ~p\n", [Reason]),
	    #{}
    end.

make_addr_map_([], _IndexMap, Map) ->
    Map;
make_addr_map_([{IfName,Flags}|List], IndexMap, M0) ->
    Index = maps:get(IfName, IndexMap),
    AddrList = lists:filter(fun filter_ip/1,
			    proplists:get_all_values(addr, Flags)),
    M1 =
	lists:foldl(
	  fun(IP, Mi) ->
		  IndexList =
		      case maps:get(IP, Mi, undefined) of
			  undefined -> [Index];
			  Is -> [Index|Is]
		      end,
		  Mi#{ IP => IndexList }
	  end, M0, AddrList),
    M2 = M1#{ IfName => [Index], Index => AddrList },
    make_addr_map_(List, IndexMap, M2).

%% generate #{ "interface-name" => interface-index()
-spec make_index_map() -> #{ Name::string() => ifindex_t() }.

make_index_map() ->
    {ok,IfNames} = prim_net:if_names(),
    maps:from_list([{Name,Index} || {Index,Name} <- IfNames]).

filter_family_list(IPList, Family) ->
    lists:filter(fun(IP) -> filter_family(IP, Family) end, IPList).

filter_family(IP, inet6) -> tuple_size(IP) =:= 8;
filter_family(IP, inet) -> tuple_size(IP) =:= 4;
filter_family(_IP, _) -> false.

%% filter link local addresses we can not use yet,
%% erlang ipv6 do not support scope_index in bind!
%% filter_ip({A,_,_,_,_,_,_,_}) -> (A band 16#FE80 =/= 16#FE80);
filter_ip(_) -> true.

send_ping(S) ->
    Conf = S#s.conf,
    if Conf#conf.simulation ->
	    {ok,S};
       true ->
	    %% multicast magic + ping_interval
	    Magic = Conf#conf.magic,
	    IVal  = Conf#conf.ping_interval,
	    Ping  = <<(byte_size(Magic)):32, Magic/binary,  IVal:32>>,
	    send_message(Ping, S)
    end.

send_message(Data, S) ->
    %% ?dbg("gen_udp: send ~s:~w message ~p\n", [inet:ntoa(S#s.maddr),S#s.mport,Data]),
    case gen_udp:send(S#s.out, S#s.maddr, S#s.mport, Data) of
	ok ->
	    %% ?dbg("gen_udp: send message ~p\n", [Data]),
	    {ok,S};
	_Error ->
	    ?dbg("gen_udp: failure=~p\n", [_Error]),
	    {{error,_Error}, S}
    end.


%% find a node: 
-spec find_node(Addr::nodis:node_address(), #nodes{}) ->
	  false | #node{}.

find_node(Addr, Nodes) ->
    find_node_(Addr, [Nodes#nodes.up,
		      Nodes#nodes.pending,
		      Nodes#nodes.wait,
		      Nodes#nodes.down]).

find_node_(Addr, [Map|Ms]) ->
    case maps:find(Addr, Map) of
	error ->
	    find_node_(Addr, Ms);
	{ok,N} ->
	    N
    end;
find_node_(_Addr, []) ->
    false.


-spec take_node(Addr::nodis:node_address(), #nodes{}) ->
	  false | {#node{}, map()}.

take_node(Addr, Nodes) ->
    take_node_(Addr, [Nodes#nodes.up,
		      Nodes#nodes.pending,
		      Nodes#nodes.wait,
		      Nodes#nodes.down]).

take_node_(Addr, [Map|Ms]) ->
    case maps:take(Addr, Map) of
	error ->
	    take_node_(Addr, Ms);
	{N, Map1} ->
	    {N, Map1}
    end;
take_node_(_Addr, []) ->
    false.


%% a node can only be in one state at a time

add_node(Addr, IVal, Nodes = #nodes{ up = Up, pending = Pend }, S) ->
    Conf = S#s.conf,
    if map_size(Pend) =:= 0, map_size(Up) < Conf#conf.max_up_nodes ->
	    add_node_up(Addr, IVal, Nodes, S);
       map_size(Pend) < Conf#conf.max_pending_nodes -> %% add to pending
	    ?dbg("add_node: ~s\n", [format_addr(Addr)]),
	    Now = erlang:monotonic_time(),
	    notify_subs(S, {pending, Addr}),
	    Node = make_node(pending, Addr, IVal, Now),
	    Nodes#nodes { pending = Pend#{ Addr => Node } };
       true -> %% mark down? so we remember this node?
	    ?dbg("add_node: ~s no more room dropped\n",
		 [format_addr(Addr)]),
	    Nodes
    end.

%% create node in up state
add_node_up(Addr, IVal, Nodes = #nodes{ up = Up }, S) ->
    Node = make_node(up, Addr, IVal, erlang:monotonic_time()),
    notify_subs(S, {up, Addr}),
    Nodes#nodes { up = Up#{ Addr => Node } }.

make_node(State, Addr, IVal, Time) ->
    ?dbg("make_node: ~s ~s\n", [State, format_addr(Addr)]),
    #node { state = State, addr=Addr, ival=IVal,  
	    first_seen = Time, last_seen = Time, up_tick = Time }.

%% move node to up state, or insert in up state
move_node_up(Node, Nodes, Now) ->
    Nodes1 = remove_node(Node, Nodes),
    Node1 = Node#node { state = up, up_tick = Now },
    ?dbg("move: ~s:  ~s => ~s\n", 
	 [format_addr(Node#node.addr),
	  Node#node.state, Node1#node.state]),
    insert_node(Node1, Nodes1).

%% move node to pending state, or insert in pending state
move_node_pending(Node, Nodes) ->
    Nodes1 = remove_node(Node, Nodes),
    Node1 = Node#node { state = pending },
    ?dbg("move: ~s:  ~s => ~s\n", 
	 [format_addr(Node#node.addr),
	  Node#node.state, Node1#node.state]),
    insert_node(Node1, Nodes1).

%% move node to down state
move_node_down(Node, Nodes, Now, Conf) ->
    Nodes1 = remove_node(Node, Nodes),
    Node1 = Node#node { state = down, down_tick = Now },
    ?dbg("move: ~s:  ~s => ~s\n", 
	 [format_addr(Node1#node.addr), Node#node.state, Node1#node.state]),
    Nodes2 = if map_size(Nodes1#nodes.down) >= Conf#conf.max_down_nodes ->
		     Nodes1#nodes {down = remove_oldest_node(Nodes#nodes.down) };
		true ->
		     Nodes1
	     end,
    insert_node(Node1, Nodes2).

%% move node to wait state
move_node_wait(Node, Nodes, Now) ->
    Nodes1 = remove_node(Node, Nodes),
    Node1 = Node#node { state = wait, up_tick=Now },
    ?dbg("move: ~s:  ~s => ~s\n", 
	 [format_addr(Node#node.addr),
	  Node#node.state, Node1#node.state]),
    insert_node(Node1, Nodes1).

-spec update_node(Node::#node{}, Nodes::#nodes{}) -> #nodes{}.

update_node(Node, Nodes) ->
    Nodes1 = remove_node(Node, Nodes),
    NodeMap = get_node_map(Node#node.state, Nodes1),
    insert_node_(Node, NodeMap, Nodes1).

-spec remove_node(Node::#node{}, Nodes::#nodes{}) -> #nodes{}.

remove_node(Node, Nodes) ->
    NodeMap = get_node_map(Node#node.state, Nodes),
    NodeMap1 = maps:remove(Node#node.addr, NodeMap),
    set_node_map(Node#node.state, NodeMap1, Nodes).

-spec insert_node(Node::#node{}, Nodes::#nodes{}) -> #nodes{}.

insert_node(Node, Nodes) ->
    NodeMap = get_node_map(Node#node.state, Nodes),
    insert_node_(Node, NodeMap, Nodes).

insert_node_(Node, NodeMap, Nodes) ->
    Addr = Node#node.addr,
    NodeMap1 = NodeMap#{ Addr => Node },
    set_node_map(Node#node.state, NodeMap1, Nodes).

get_node_map(State, Nodes) ->
    case State of
	up -> Nodes#nodes.up;
	pending -> Nodes#nodes.pending;
	wait -> Nodes#nodes.wait;
	down -> Nodes#nodes.down
    end.    

set_node_map(State, Map, Nodes) ->
    case State of
	up      -> Nodes#nodes { up = Map };
	pending -> Nodes#nodes { pending = Map };
	wait    -> Nodes#nodes { wait = Map };
	down    -> Nodes#nodes { down = Map }
    end.

remove_oldest_node(Map) ->
    case find_oldest_node(Map) of
	{undefined,undefined} ->
	    Map;
	{Addr,_Time} ->
	    maps:remove(Addr, Map)
    end.

%% find the oldest entry in the map 
find_oldest_node(Map) ->
    maps:fold(
      fun(Addr, Node, {undefined,undefined}) ->
	      {Addr,Node#node.last_seen};
	 (Addr, Node, Old={_OldAddr,OldTime}) ->
	      if Node#node.last_seen < OldTime ->
		      {Addr,Node#node.last_seen};
		 true ->
		      Old
	      end
      end, {undefined,undefined}, Map).
