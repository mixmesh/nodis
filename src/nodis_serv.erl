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
-export([connect/2, connect/3]).
-export([accept/2, accept/3]).
-export([get_state/1, get_state/2]).
-export([get_location/1, get_location/2]).
-export([get_node_location/0, get_node_location/1]).
-export([set_node_location/1, set_node_location/2]).
-export([set_node_habitat/1, set_node_habitat/2]).

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
-type tick()    :: integer().
-type timer()   :: reference().
-type uint32()  :: 0..16#ffffffff.

%% subscriber for node events
-record(sub,
	{
	 ref :: reference(),
	 pid :: pid()
	}).

-record(node_counter,
	{
	 state = undefined,  %% keypos=2
	 count = 0
	}).

%% Ping Header defaults
-define(NODIS_MAGIC, <<"MIXMESH">>).
-define(NODIS_FEATURES,            16#000110F1).  %% 1xuint32()
-define(NODIS_FEATURE_NODEID,      16#00000001).  %% 32xbyte()
-define(NODIS_FEATURE_CACHE_TMO,   16#00000002).  %% 1xuint32()
-define(NODIS_FEATURE_LOCATION,    16#00000010).  %% 2xfloat()
-define(NODIS_FEATURE_SPEED,       16#00000020).  %% 1xfloat()
-define(NODIS_FEATURE_DELTA,       16#00000040).  %% 2xfloat()
-define(NODIS_FEATURE_DESTINATION, 16#00000080).  %% 2xfloat()
-define(NODIS_FEATURE_HABITAT,     16#00000100).  %% 5xfloat()
%% 2-bits for node size 
-define(NODIS_FEATURE_SIZE_MASK,   16#0000F000).
-define(NODIS_FEATURE_TINY,        16#00001000).
-define(NODIS_FEATURE_SMALL,       16#00002000).
-define(NODIS_FEATURE_MEDIUM,      16#00003000).
-define(NODIS_FEATURE_LARGE,       16#00004000).
-define(NODIS_FEATURE_HUGE,        16#00005000).
%% pure static node (ignore speed and delta)
-define(NODIS_FEATURE_TYPE_MASK,   16#000F0000).
-define(NODIS_FEATURE_GENERIC,     16#00010000).
-define(NODIS_FEATURE_STATIC,      16#00020000).
-define(NODIS_FEATURE_ROUTER,      16#00030000).
-define(NODIS_FEATURE_POSTBOX,     16#00040000).

-define(NODIS_LAT,        0.0).
-define(NODIS_LONG,       0.0).
-define(NODIS_SPEED,      0.0).
-define(NODIS_DELTA_LAT,  0.0).
-define(NODIS_DELTA_LONG, 0.0).
-define(NODIS_DEST_LAT,   0.0).
-define(NODIS_DEST_LONG,  0.0).
-define(NODIS_HAB_LAT1,   0.0).
-define(NODIS_HAB_LONG1,  0.0).
-define(NODIS_HAB_LAT2,   0.0).
-define(NODIS_HAB_LONG2,  0.0).
-define(NODIS_HAB_RADIUS, 0.0).

%% forwarding location

-define(NODIS_CACHE_TMO, 3600).  %% 1hour timeout

-define(NODIS_DEFAULT_PING_INTERVAL, 5000). %% 5s

-record(node_info,
	{
	 %% temporary node id (valid cache_timeout seconds)
	 nodeid :: <<_:(32*8)>>,
	 %% after that send with this interval
	 ping_interval = ?NODIS_DEFAULT_PING_INTERVAL :: time_ms(),
	 %% supported features
	 features = ?NODIS_FEATURES  :: uint32(),
	 %% 
	 cache_timeout = ?NODIS_CACHE_TMO :: uint32(),
	 lat           = ?NODIS_LAT  :: float(),
	 long          = ?NODIS_LONG :: float(),
	 spd           = ?NODIS_SPEED :: float(),
	 delta_lat     = ?NODIS_DELTA_LAT ::float(),
	 delta_long    = ?NODIS_DELTA_LONG :: float(),
	 dest_lat      = ?NODIS_DEST_LAT :: float(),
	 dest_long     = ?NODIS_DEST_LONG :: float(),
	 hab_lat1      = ?NODIS_HAB_LAT1 :: float(),
	 hab_long1     = ?NODIS_HAB_LONG1 :: float(),
	 hab_lat2      = ?NODIS_HAB_LAT2 :: float(),
	 hab_long2     = ?NODIS_HAB_LONG2 :: float(),
	 hab_radius    = ?NODIS_HAB_RADIUS :: float()
	}).

-record(node,
	{
	 addr :: nodis:addr(),  %% ip address of node (keypos=2)
	 state :: nodis:node_state(),
	 info  :: #node_info{},
	 con = none  :: none | connect | accept,
	 dt_ms = 0 :: time_ms(),  %% added to wait time / down time
	 ival  :: time_ms(),     %% node announce to send this often in ms
	 first_seen :: tick(),   %% first time around
	 last_seen :: tick(),    %% we have not seen the node since
	 up_tick :: tick(),      %% tick when ws sent up message
	 down_tick :: tick()     %% tick when marked as down
	}).

-type ifindex_t() :: non_neg_integer().
-type addr_map_t() ::
	#{ inet:ip_address() => [ifindex_t()],
	   string() => [ifindex_t()],
	   ifindex_t() => [inet:ip_address()] }.

-define(NODIS_DEFAULT_PING_DELAY, 1000). %% 1s before first ping
-define(NODIS_DEFAULT_MAX_PINGS_LOST, 3).   %% before being regarded as gone
-define(NODIS_DEFAULT_MIN_WAIT_TIME, 30000). %% test 30seconds
-define(NODIS_DEFAULT_MIN_DOWN_TIME, 60000). %% test 30seconds
%% -define(NODIS_DEFAULT_MIN_WAIT_TIME, (5*60*1000)).  %% 5min
%% -define(NODIS_DEFAULT_MIN_DOWN_TIME, (10*60*1000)). %% 10min
-define(NODIS_DEFAULT_MAX_UP_NODES,      10).
-define(NODIS_DEFAULT_MAX_DOWN_NODES,    2000).
-define(NODIS_DEFAULT_MAX_WAIT_NODES,    1000).



-record(conf,
	{
	 input = #{} :: nodis_option(), %% input options (override!)
	 simulation = false :: boolean(),
	 hops :: non_neg_integer(),   %% max number of hops (ttl)
	 loop :: boolean(),           %% loop on host (other applications)
	 magic :: <<_:(16*8)>>,         %% magic ping (zero padded to 16 bytes)
	 info  :: #node_info{},       %% own node info
	 %% delay until first ping
	 ping_delay = ?NODIS_DEFAULT_PING_DELAY :: time_ms(),
	 %% down if we missed this number of pings
	 max_pings_lost = ?NODIS_DEFAULT_MAX_PINGS_LOST :: non_neg_integer(),
	 %% resend up after min_wait_time
	 min_wait_time = ?NODIS_DEFAULT_MIN_WAIT_TIME :: time_ms(),  
	 %% allow down node to be up after min_down_time
	 min_down_time = ?NODIS_DEFAULT_MIN_DOWN_TIME :: time_ms(),  
	 %% max number of nodes in up state
	 max_up_nodes = ?NODIS_DEFAULT_MAX_UP_NODES :: non_neg_integer(),
	 %% max number of nodes that have been reschduled after up
	 max_wait_nodes = ?NODIS_DEFAULT_MAX_WAIT_NODES :: non_neg_integer(),
	 %% max number of remembered nodes that have been up
	 max_down_nodes = ?NODIS_DEFAULT_MAX_DOWN_NODES :: non_neg_integer()
	}).

-record(s,
	{
	 in,          %% incoming udp socket
	 out,         %% outgoing udp socket
	 maddr,       %% multicast address
	 ifaddr,      %% interface address
	 %% fixme: add 'multicast-port' 'source-port' in config
	 mport :: inet:port_number(), %% nodis multicast port
	 oport :: inet:port_number(), %% nodis sending port (mport+1)
	 conf  :: #conf{},
	 ping_tmr :: timer(),  %% multicase ping each timeout
	 tab :: ets:tid(),  %% node table
	 upq :: [nodis:addr()],
	 subs = #{} :: #{ reference() => #sub{} },
	 cons = #{} :: #{ reference() => nodis:addr() },
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

-define(NODIS_MULTICAST_ADDR4, {224,0,0,1}).
-define(NODIS_MULTICAST_ADDR6, {16#FF12,0,0,0,0,0,0,1234}).
-define(NODIS_DEFAULT_UDP_PORT, 9900).  %% match mixmesh sync port

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
-spec wait(Addr::nodis:addr()) -> ok.
wait(Addr) ->
    gen_server:call(?SERVER, {wait,Addr}).

-spec wait(Pid::pid(), Addr::nodis:addr()) -> ok.
wait(Pid,Addr) ->
    gen_server:call(Pid, {wait,Addr}).


-spec connect(Addr::nodis:addr(),SyncAddr::nodis:addr()) -> boolean().
connect(Addr,SyncAddr) ->
    gen_server:call(?SERVER, {connect,self(),Addr,SyncAddr}).

-spec connect(Pid::pid(),Addr::nodis:addr(),
	      SyncAddr::nodis:addr()) -> boolean().

connect(Pid,Addr,SyncAddr) ->
    gen_server:call(Pid, {connect,self(),Addr,SyncAddr}).

-spec accept(Addr::nodis:addr(),SyncAddr::nodis:addr()) -> boolean().
accept(Addr,SyncAddr) ->
    gen_server:call(?SERVER, {accept,self(),Addr,SyncAddr}).

-spec accept(Pid::pid(),Addr::nodis:addr(),SyncAddr::nodis:addr()) -> boolean().

accept(Pid,Addr,SyncAddr) ->
    gen_server:call(Pid, {accept,self(),Addr,SyncAddr}).

%% Get neighbour state
-spec get_state(Addr::nodis:addr()) -> nodis:node_state().
get_state(Addr) ->
    gen_server:call(?SERVER, {get_state,Addr}).

%% Get neighbour state
-spec get_state(Pid::pid(), Addr::nodis:addr()) -> nodis:node_state().
get_state(Pid,Addr) ->
    gen_server:call(Pid, {get_state,Addr}).

%% Get neighbour location info
-spec get_location(Addr::nodis:addr()) -> nodis:location().
get_location(Addr) ->
    gen_server:call(?SERVER, {get_location,Addr}).

%% Get neighbour location info
-spec get_location(Pid::pid(), Addr::nodis:addr()) -> nodis:location().
get_location(Pid,Addr) ->
    gen_server:call(Pid, {get_location,Addr}).

%% Get own location info
-spec get_node_location() -> nodis:location().
get_node_location() ->
    gen_server:call(?SERVER, get_node_location).

%% Get neighbour location info
-spec get_node_location(Pid::pid()) -> nodis:location().
get_node_location(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_node_location).

%% Set own location info
-spec set_node_location(Location::noids:location()) -> ok.
set_node_location(Location) when is_map(Location) ->
    gen_server:call(?SERVER, {set_node_location,Location}).

%% Get neighbour location info
-spec set_node_location(Pid::pid(), Loc::nodis:location()) -> ok.
set_node_location(Pid,Loc) when is_pid(Pid), is_map(Loc) ->
    gen_server:call(Pid, {set_node_location,Loc}).

%% Set own habitat info
-spec set_node_habitat(Hab::nodis:habitat()) -> ok.
set_node_habitat(Hab) when is_map(Hab) ->
    gen_server:call(?SERVER, {set_node_habitat,Hab}).

%% Get neighbour location info
-spec set_node_habitat(Pid::pid(), Location::nodis:location()) -> ok.
set_node_habitat(Pid,Hab) when is_pid(Pid), is_map(Hab) ->
    gen_server:call(Pid, {set_node_habitat,Hab}).

%% test - broadcast any message
send(Data) ->
    send(?SERVER, Data).
send(Pid, Data) ->
    gen_server:call(Pid,{send,Data}).
%%
%% simulation feed nodis_serv with simulated ping data
%% will show up with the player subscriver as
%% {up, Addr} | {missed, Addr} | {down, Addr}
%% NOT {wait,Addr} we must handle this from application
%%
simping(Pid, Addr, Port, IVal) when is_integer(IVal) ->
    simping_(Pid, Addr, Port, #{ ping_interval => IVal});
simping(Pid, Addr, Port, Opts) when is_list(Opts) ->
    simping_(Pid, Addr, Port, maps:from_list(Opts));
simping(Pid, Addr, Port, Opts) when is_map(Opts) ->
    simping_(Pid, Addr, Port, Opts).

simping_(Pid, {A,B,C,D}, Port, Opts) when
      (A bor B bor C bor D) band (bnot 16#ff) =:= 0,
      is_integer(Port) ->
    gen_server:cast(Pid, {simping,{{A,B,C,D},Port},Opts});
simping_(Pid, {A,B,C,D,E,F,G,H}, Port, Opts) when
      (A bor B bor C bor D bor E bor F bor G bor H) band (bnot 16#ffff) =:= 0,
      is_integer(Port) ->
    gen_server:cast(Pid, {simping,{{A,B,C,D,E,F,G,H},Port},Opts}).

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
    MPort  = maps:get(mport, Opts,  ?NODIS_DEFAULT_UDP_PORT),
    OPort  = maps:get(oport, Opts,  MPort+1),
    Mhops  = maps:get(hops, Opts, 1),
    Mloop  = maps:get(loop, Opts, true),
    Laddr0 = maps:get(ifaddr, Opts, Device),
    Magic  = maps:get(magic, Opts, ?NODIS_MAGIC),
    Simulation = maps:get(simulation, Opts, false),
    Tab = ets:new(nodes, [{keypos,#node.addr}]),
    ets:insert(Tab, #node_counter{state=up}),
    ets:insert(Tab, #node_counter{state=down}),
    ets:insert(Tab, #node_counter{state=wait}),
    Simulator = case config_lookup([simulator], false) of
		    false -> false;
		    _ -> true
		end,
    NodeID = crypto:strong_rand_bytes(32),
    %% NodeID = crypto:hash(sha256, ipv6-address + time)
    NodeInfo = #node_info { nodeid = NodeID },
    Conf0 = #conf {
	       input  = InputOpts,  %% keep override options
	       simulation = Simulation orelse Simulator,
	       hops  = Mhops,
	       loop  = Mloop,
	       magic = zero_pad(Magic, 16),
	       info  = NodeInfo
	      },
    Conf = read_conf(Conf0, Opts),

    case Simulation of
	true ->
	    PingTmr = start_ping(Conf#conf.ping_delay),
	    {ok, #s{ mport = MPort,
		     oport = OPort,
		     conf  = Conf,
		     tab   = Tab,
		     upq   = [],
		     ping_tmr = PingTmr
		   }};
	false ->
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
	    case gen_udp:open(OPort, SendOpts) of
		{ok,Out} ->
		    OutPort = 
			case inet:port(Out) of
			    {ok,OPort}  -> OPort;
			    {ok,OPort1} when OPort =:= 0 -> OPort1
			end,
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
				     tab   = Tab,
				     upq   = [],
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
    ets:foldl(
      fun(N, _Acc) when N#node.state =:= up ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, {up,N#node.addr}};
	 (_, Acc) ->
	      Acc
      end, ok, S#s.tab),
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
    case read_node(Addr, S) of
	false ->
	    {reply, {error, not_found}, S};
	N when N#node.state =:= up ->
	    notify_subs(S, {wait, N#node.addr}),
	    Now = tick(),
	    S1 = set_node(wait, N#node { up_tick=Now,con=none,last_seen=Now}, S),
	    {reply, ok, S1};
	_N ->
	    {reply, {error, not_up}, S}
    end;
%% accept connection to Addr?
handle_call({connect,SyncPid,Addr,_SyncAddr}, _From, S) ->
    case read_node(Addr, S) of
	false ->
	    {reply, false, S};
	N when N#node.state =:= up ->
	    if N#node.con =:= none ->
		    S1 = insert_node(N#node { con = connect }, S),
		    Mon = erlang:monitor(process, SyncPid),
		    ConMap = S1#s.cons,
		    ConMap1 = ConMap# { Mon => Addr },
		    {reply, true, S1#s { cons = ConMap1 }};
	       true ->
		    {reply, false, S}
	    end;
	N when N#node.state =:= wait ->
	    S1 = update_node(up, N#node { con=connect, up_tick=tick()}, S),
	    Mon = erlang:monitor(process, SyncPid),
	    ConMap = S1#s.cons,
	    ConMap1 = ConMap# { Mon => Addr },
	    {reply, true, S1#s { cons = ConMap1 }};
	_N ->
	    {reply, false, S}
    end;
%% accept connection from Addr?
handle_call({accept,SyncPid,Addr,_SyncAddr}, _From, S) ->
    case read_node(Addr, S) of
	false ->
	    {reply, false, S};
	N when N#node.state =:= up ->
	    if N#node.con =:= none ->
		    %% node maybe in upq?
		    S1 = remove_from_upq(N, S),
		    S2 = insert_node(N#node { con=accept, up_tick=tick() }, S1),
		    Mon = erlang:monitor(process, SyncPid),
		    ConMap = S2#s.cons,
		    ConMap1 = ConMap# { Mon => Addr },
		    {reply, true, S2#s { cons = ConMap1 }};
	       true ->
		    {reply, false, S}
	    end;
	N when N#node.state =:= wait ->
	    %% allow accept side to be in wait state
	    %% we should regulate this somehow...
	    S1 = update_node(up, N#node { con = accept }, S),
	    Mon = erlang:monitor(process, SyncPid),
	    ConMap = S1#s.cons,
	    ConMap1 = ConMap# { Mon => Addr },
	    {reply, true, S1#s { cons = ConMap1 }};
	_N ->
	    {reply, false, S}
    end;
handle_call({get_state,Addr}, _From, S) ->
    case read_node(Addr, S) of
	false ->
	    {reply, undefined, S};
	N ->
	    {reply, N#node.state, S}
    end;
handle_call({get_location,Addr}, _From, S) ->
    case read_node(Addr, S) of
	false ->
	    {reply, undefined, S};
	N ->
	    I = N#node.info,
	    Fs = decode_features(I#node_info.features),
	    H = #{ hab_lat1=> I#node_info.hab_lat1,
		   hab_long1=> I#node_info.hab_long1,
		   hab_lat2 => I#node_info.hab_lat2,
		   hab_long2 => I#node_info.hab_long2,
		   hab_radius => I#node_info.hab_radius },
	    Location = #{ features => Fs,
			  lat => I#node_info.lat,
			  long => I#node_info.long,
			  spd => I#node_info.spd,
			  delta_lat => I#node_info.delta_lat,
			  delta_long => I#node_info.delta_long,
			  dest_lat   => I#node_info.dest_lat,
			  dest_long  => I#node_info.dest_long,
			  hab => H },
	    {reply, Location, S}
    end;
handle_call(get_node_location, _From, S) ->
    I = (S#s.conf)#conf.info,
    Location = #{ lat => I#node_info.lat,
		  long => I#node_info.long,
		  spd => I#node_info.spd,
		  delta_lat => I#node_info.delta_lat,
		  delta_long => I#node_info.delta_long,
		  dest_lat   => I#node_info.dest_lat,
		  dest_long  => I#node_info.dest_long },
    {reply, Location, S};

handle_call({set_node_location, L}, _From, S) ->
    Conf = S#s.conf,
    I = Conf#conf.info,
    J =
	I#node_info { lat=maps:get(lat,L,I#node_info.lat),
		      long=maps:get(long,L,I#node_info.long),
		      spd=maps:get(spd,L,I#node_info.spd),
		      delta_lat=maps:get(delta_lat,L,I#node_info.delta_lat),
		      delta_long=maps:get(delta_long,L,I#node_info.delta_long),
		      dest_lat=maps:get(dest_lat,L,I#node_info.dest_lat),
		      dest_long=maps:get(dest_long,L,I#node_info.dest_long) },
    {reply, ok, S#s { conf = Conf#conf { info = J }}};

handle_call(get_node_habitat, _From, S) ->
    I = (S#s.conf)#conf.info,
    H = #{ hab_lat1=> I#node_info.hab_lat1,
	   hab_long1=> I#node_info.hab_long1,
	   hab_lat2 => I#node_info.hab_lat2,
	   hab_long2 => I#node_info.hab_long2,
	   hab_radius => I#node_info.hab_radius },
    {reply, H, S};

handle_call({set_node_habitat, H}, _From, S) ->
    Conf = S#s.conf,
    I = Conf#conf.info,
    J =
	I#node_info { hab_lat1=maps:get(hab_lat1,H,I#node_info.hab_lat1),
		      hab_long1=maps:get(hab_long1,H,I#node_info.hab_long1),
		      hab_lat2=maps:get(hab_lat2,H,I#node_info.hab_lat2),
		      hab_long2=maps:get(hab_long2,H,I#node_info.hab_long2),
		      hab_radius=maps:get(hab_radius,H,I#node_info.hab_radius)},
    {reply, ok, S#s { conf = Conf#conf { info = J }}};

handle_call(dump, _From, S) ->
    io:format("oport = ~w\n", [S#s.oport]),
    io:format("mport = ~w\n", [S#s.mport]),
    dump_conf(S#s.conf),
    dump_queue(S),
    dump_counters(S),
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
handle_cast({simping,{IP,Port},Opts}, S) ->
    NAddr = {IP,Port-1},
    IVal = maps:get(ping_interval, Opts),
    Lat  = maps:get(lat, Opts, 0.0),
    Long = maps:get(long, Opts, 0.0),
    Spd  = maps:get(spd, Opts, 0.0),
    DLat  = maps:get(delta_lat, Opts, 0.0),
    DLong = maps:get(delta_long, Opts, 0.0),
    DestLat  = maps:get(dest_lat, Opts, 0.0),
    DestLong = maps:get(dest_long, Opts, 0.0),
    NodeID = crypto:hash(sha256, term_to_binary({IP,Port})),
    NodeInfo = #node_info { nodeid = NodeID,
			    ping_interval = IVal,
			    lat = Lat, long = Long, spd = Spd,
			    delta_lat = DLat, delta_long = DLong,
			    dest_lat = DestLat, dest_long = DestLong
			  },
    handle_ping(NAddr,NodeInfo,S);
handle_cast(_Mesg, S) ->
    ?dbg("nodis: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,Addr,Port,Data}, S) when S#s.in == U ->
    IsLocalAddress = maps:get(Addr, S#s.addr_map, []) =/= [],
    ?dbg("nodis: udp ~s:~w (~s) ~p\n",
	 [inet:ntoa(Addr),Port, if IsLocalAddress -> "local";
				   true -> "remote" end, Data]),
    if IsLocalAddress, Port =:= S#s.oport -> %% this is our output! (loop=true)
	    %%?dbg("nodis: discard ~s:~w ~p\n",  [inet:ntoa(Addr),Port,Data]),
	    {noreply, S};
       true ->
	    NAddr = {Addr,Port-1},
	    case get_header(S#s.conf, Data) of
		false ->
		    ?dbg("ignored data from ~s = ~p\n",
			 [format_addr(NAddr),Data]),
		    {noreply, S};
		NodeInfo ->
		    handle_ping(NAddr,NodeInfo,S)
	    end
    end;
handle_info({timeout,Tmr,ping}, S) when Tmr =:= S#s.ping_tmr ->
    send_ping(S),
    PingInterval = ((S#s.conf)#conf.info)#node_info.ping_interval,
		    PingTmr = start_ping(PingInterval),
    S1 = gc_nodes(S),
    {noreply, S1#s { ping_tmr = PingTmr }};
handle_info(reload, S) ->
    Conf = read_conf(S#s.conf),
    %% FIXME: add code to adjust node lists according to above
    {noreply, S#s{conf=Conf}};
handle_info({'DOWN',Ref,process,_Pid,_Reason}, S) ->
    case maps:take(Ref, S#s.subs) of
	error ->
	    case maps:take(Ref,S#s.cons) of
		error ->
		    {noreply,S};
		{Addr,Cons} ->
		    ?dbg("connection from pid ~p deleted reason=~p",
			 [_Pid, _Reason]),
		    case read_node(Addr,S) of
			false ->
			    {noreply,S#s { cons=Cons }};
			N ->
			    if N#node.state =:= up,
			       N#node.con =/= none ->
				    %% auto wait 
				    notify_subs(S, {wait, N#node.addr}),
				    Now = tick(),
				    Dt = case rand:uniform(2) of
					     1 -> 0;
					     2 -> 500
					 end,
				    S1 = set_node(wait,
						  N#node { up_tick=Now,
							   dt_ms = Dt,
							   con=none,
							   last_seen=Now}, S),
				    {noreply,S1#s { cons=Cons}};
			       true  ->
				    insert_node(N#node{con=none},S),
				    {noreply,S#s { cons=Cons }}
			    end
		    end
	    end;
	{_Sub,Subs} ->
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

-define(FEATURE(F,Flag,Name),
	       if F band (Flag) =/= 0 -> [(Name)];
		  true -> []
	       end).

feature_map() ->
    #{
      nodeid => ?NODIS_FEATURE_NODEID,
      cache_timeout => ?NODIS_FEATURE_CACHE_TMO,
      location => ?NODIS_FEATURE_LOCATION,
      speed => ?NODIS_FEATURE_SPEED,
      delta => ?NODIS_FEATURE_DELTA,
      destination => ?NODIS_FEATURE_DESTINATION,
      habitat => ?NODIS_FEATURE_HABITAT,

      tiny => ?NODIS_FEATURE_TINY,
      small => ?NODIS_FEATURE_SMALL,
      medium => ?NODIS_FEATURE_MEDIUM,
      large => ?NODIS_FEATURE_LARGE,
      huge => ?NODIS_FEATURE_HUGE,
	
      generic => ?NODIS_FEATURE_GENERIC,
      static  => ?NODIS_FEATURE_STATIC,
      router  => ?NODIS_FEATURE_ROUTER,
      postbox => ?NODIS_FEATURE_POSTBOX
     }.

%% decode feature bits
decode_features(F) ->
    ?FEATURE(F,?NODIS_FEATURE_NODEID, nodeid) ++
    ?FEATURE(F,?NODIS_FEATURE_CACHE_TMO, cache_timeout) ++
    ?FEATURE(F,?NODIS_FEATURE_LOCATION,  location) ++
    ?FEATURE(F,?NODIS_FEATURE_SPEED,     speed) ++
    ?FEATURE(F,?NODIS_FEATURE_DELTA,     delta) ++
    ?FEATURE(F,?NODIS_FEATURE_DESTINATION, destination) ++
    ?FEATURE(F,?NODIS_FEATURE_HABITAT,     habitat) ++
    case F band ?NODIS_FEATURE_SIZE_MASK of
	?NODIS_FEATURE_TINY -> [tiny];
	?NODIS_FEATURE_SMALL -> [small];
	?NODIS_FEATURE_MEDIUM -> [medium];
	?NODIS_FEATURE_HUGE   -> [huge];
	_ -> []
    end ++
    case F band ?NODIS_FEATURE_TYPE_MASK of
	?NODIS_FEATURE_GENERIC -> [generic];
	?NODIS_FEATURE_STATIC  -> [static];
	?NODIS_FEATURE_ROUTER  -> [router];
	?NODIS_FEATURE_POSTBOX -> [postbox]
    end.

encode_features(Fs) ->    
    encode_features_(Fs, 0).

encode_features_([F|Fs], Flags) ->
    encode_features_(Fs, maps:get(F, feature_map(), 0) bor Flags);
encode_features_([], Flags) ->
    Flags.

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
    PingInterval0 = get_ping_interval(Conf),
    PingDelay = maps:get('ping-delay',Map,Conf#conf.ping_delay),
    PingInterval = maps:get('ping-interval',Map,PingInterval0),
    MaxPingsLost = maps:get('max-pings-lost',Map,Conf#conf.max_pings_lost),
    MinWaitTime  = maps:get('min-wait-time',Map, Conf#conf.min_wait_time),
    MinDownTime  = maps:get('min-down-time',Map, Conf#conf.min_down_time),
    MaxUpNodes = maps:get('max-up-nodes',Map,Conf#conf.max_up_nodes),
    MaxDownNodes = maps:get('max-down-nodes',Map,Conf#conf.max_down_nodes),
    MaxWaitNodes = maps:get('max-wait-nodes',Map,Conf#conf.max_wait_nodes),
    Info = set_ping_interval(Conf#conf.info, PingInterval),
    Conf#conf {
      info = Info,
      ping_delay = PingDelay,
      max_pings_lost = MaxPingsLost,
      min_wait_time = MinWaitTime,
      min_down_time = MinDownTime,
      max_up_nodes = MaxUpNodes,
      max_down_nodes = MaxDownNodes,
      max_wait_nodes = MaxWaitNodes
     }.

get_ping_interval(#conf{info=NodeInfo}) ->
    NodeInfo#node_info.ping_interval.

set_ping_interval(NodeInfo = #node_info {}, IVal) ->
    NodeInfo#node_info { ping_interval = IVal }.

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

%% start outbound ping timer
start_ping(Delay) when is_integer(Delay), Delay > 0 ->
    erlang:start_timer(Delay, self(), ping).

%% handle incoming node ping
handle_ping(Addr,NodeInfo,S) ->
    Now = tick(),
    case read_node(Addr, S) of
	false ->
	    N = make_node(Addr, NodeInfo, Now),
	    {noreply,wakeup_node(N, S)};
	N0 ->
	    IVal = NodeInfo#node_info.ping_interval,
	    N = N0#node { last_seen = Now, info = NodeInfo, ival = IVal },
	    case N#node.state of
		down ->
		    DTime = time_diff_ms(Now,N#node.down_tick),
		    if DTime > (S#s.conf)#conf.min_down_time ->
			    {noreply,wakeup_node(N, S)};
		       true ->
			    {noreply,insert_node(N, S)}
		    end;
		wait ->
		    UTime = time_diff_ms(Now,N#node.up_tick),
		    MinWaitTime = (S#s.conf)#conf.min_wait_time + N#node.dt_ms,
		    if UTime > MinWaitTime ->
			    {noreply,wakeup_node(N, S)};
		       true ->
			    {noreply,insert_node(N, S)}
		    end;
		up ->
		    {noreply,insert_node(N, S)}
	    end
    end.

%% Wakeup a node from down or wait state
%% if up state counter <= max_up_nodes then send notification
%% otherwise schedule node for notification

wakeup_node(N, S) ->
    set_node(up, N#node { up_tick=N#node.last_seen }, S).

read_node(Addr, S) ->
    case ets:lookup(S#s.tab, Addr) of
	[] -> false;
	[N] -> N
    end.

read_counter(State, S) ->
    [#node_counter{count=Count}] = ets:lookup(S#s.tab, State),
    Count.

set_node(State, N, S) when N#node.state =/= State ->
    %% state change
    case State of
	wait ->
	    Counter = read_counter(wait, S),
	    MaxWaitNodes = (S#s.conf)#conf.max_wait_nodes,
	    if Counter >= MaxWaitNodes ->
		    Remove = (Counter+1) - MaxWaitNodes,
		    remove_oldest(wait,Remove,S);
	       true ->
		    ok
	    end,
	    S1 = remove_from_upq(N, S),
	    S2 = update_node(wait, N, S1),
	    dequeue_from_upq(S2);
	down ->
	    Counter = read_counter(down, S),
	    MaxDownNodes = (S#s.conf)#conf.max_down_nodes, 
	    if Counter >= MaxDownNodes ->
		    Remove = (Counter+1) - MaxDownNodes,
		    remove_oldest(down,Remove,S);
	       true ->
		    ok
	    end,
	    S1 = remove_from_upq(N, S),
	    S2 = update_node(down, N, S1),
	    dequeue_from_upq(S2);
	up ->
	    Counter = read_counter(up, S),
	    Reported = Counter - length(S#s.upq),
	    if Reported >= (S#s.conf)#conf.max_up_nodes ->
		    Q = S#s.upq ++ [N#node.addr],
		    S1 = S#s { upq = Q },
		    update_node(up, N, S1);
	       true ->
		    notify_subs(S, {up, N#node.addr}),
		    update_node(up, N, S)
	    end
    end;
set_node(_State, N, S) -> %% no state change
    insert_node(N, S).

%% remove node (address) from upq when changing to wait and down states
remove_from_upq(N, S) ->
    Q = lists:delete(N#node.addr, S#s.upq),
    S#s { upq = Q }.

%% dequeue from upqueue
dequeue_from_upq(S=#s{upq=[NAddr|Q]}) ->
    Counter = read_counter(up,S),
    Reported = Counter - length(S#s.upq),
    if Reported < (S#s.conf)#conf.max_up_nodes ->
	    notify_subs(S, {up, NAddr}),
	    S#s{upq=Q};
       true ->
	    S
    end;
dequeue_from_upq(S) ->
    S.
		    
update_node(State, N, S) when  N#node.state =:= undefined ->
    ets:update_counter(S#s.tab, State, 1),
    insert_node(N#node{state=State}, S);
update_node(State, N, S) ->
    ets:update_counter(S#s.tab, N#node.state, -1),
    ets:update_counter(S#s.tab, State, 1),
    insert_node(N#node{state=State}, S).

insert_node(N, S) ->
    ets:insert(S#s.tab, N),
    S.

gc_nodes(S) ->
    Now = tick(),
    MaxPingsLost = (S#s.conf)#conf.max_pings_lost,
    Down = ets:foldl(
	     fun(N=#node{}, Acc) ->
		     LTime = time_diff_us(Now, N#node.last_seen),
		     if LTime > N#node.ival*MaxPingsLost*1000 ->
			     [N|Acc];
			true ->
			     Acc
		     end;
		(#node_counter{}, Acc) -> Acc
	     end, [], S#s.tab),
    lists:foldl(
      fun(N, Si) ->
	      if N#node.state =/= down ->
		      notify_subs(Si, {down, N#node.addr});
		 true ->
		      ok
	      end,
	      set_node(down, N#node{down_tick=Now}, Si)
      end, S, Down).

notify_subs(S, Message) ->
    %% io:format("notify: ~w\n", [Message]),
    maps:fold(
      fun(_Ref,Sub,_Acc) ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, Message}
      end, ok, S#s.subs).

dump_conf(C) ->
    io:format("simulation = ~w\n", [C#conf.simulation]),
    io:format("hops = ~w\n", [C#conf.hops]),
    io:format("loop = ~w\n", [C#conf.loop]),
    io:format("magic = ~p\n", [cstring(C#conf.magic)]),
    io:format("ping_interval  = ~w\n", [get_ping_interval(C)]),
    io:format("ping_delay  = ~w\n", [C#conf.ping_delay]),
    io:format("max_pings_lost = ~w\n", [C#conf.max_pings_lost]),
    io:format("min_wait_time = ~w\n", [C#conf.min_wait_time]),
    io:format("min_down_time = ~w\n", [C#conf.min_down_time]),
    io:format("max_up_nodes = ~w\n", [C#conf.max_up_nodes]),
    io:format("max_wait_nodes = ~w\n", [C#conf.max_wait_nodes]),
    io:format("max_down_nodes = ~w\n", [C#conf.max_down_nodes]).

cstring(<<0,_/binary>>) -> [];
cstring(<<>>) -> [];
cstring(<<C,Cs/binary>>) -> [C | cstring(Cs)].
    
dump_state(S) ->
    dump_nodes(S).

dump_counters(S) ->
    io:format("#up = ~w\n", [read_counter(up, S)]),
    io:format("#down = ~w\n", [read_counter(down, S)]),
    io:format("#wait = ~w\n", [read_counter(wait, S)]).

dump_queue(S) ->
    io:format("queue = ["),
    case S#s.upq of
	[] -> 
	    ok;
	[A] ->
	    io:format("~s", [format_addr(A)]);
	[A|As] ->
	    io:format("~s", [format_addr(A)]),
	    lists:foreach(
	      fun(Ai) ->
		      io:format(",~s", [format_addr(Ai)])
	      end, As)
    end,
    io:format("]\n").

dump_nodes(S=#s{conf=Conf}) ->
    Now = tick(),
    ets:foldl(
      fun(N=#node{},I) ->
	      Addr = format_addr(N#node.addr),
	      Lt = time_diff_us(Now,N#node.last_seen),
	      LTm = 
		  if Lt > N#node.ival*Conf#conf.max_pings_lost*1000 ->
			  down;
		     Lt > N#node.ival*1000 ->
			  missed;
		     true ->
			  ok
		  end,
	      Info = N#node.info,
	      case N#node.state of
		  up ->
		      Ut = time_diff_us(Now,N#node.up_tick),
		      format_node(I,up,Addr,
				  uptime,Ut,Lt,N,LTm,Info);
		  down ->
		      if LTm =:= down ->
			      Dt = time_diff_us(Now,N#node.down_tick),
			      format_node(I,down,Addr,
					  downtime,Dt,
					  Lt, N, LTm, Info);
			 true -> %% ok|missed
			      Dt_ms = time_diff_ms(Now,N#node.down_tick),
			      Dt =
				  if Dt_ms > Conf#conf.min_down_time ->
					  0;
				     true ->
					  Conf#conf.min_down_time - Dt_ms
				  end,
			      format_node(I,wait,Addr,
					  remain,Dt*1000,
					  Lt,N,LTm,Info)
		      end;
		  wait ->
		      Wt_ms = time_diff_ms(Now,N#node.up_tick),
		      MinWaitTime = Conf#conf.min_wait_time+N#node.dt_ms,
		      Wt = if Wt_ms > MinWaitTime ->
				   0;
			      true ->
				   MinWaitTime - Wt_ms
			   end,
		      format_node(I,wait,Addr,
				  remain,Wt*1000,Lt,N,LTm,Info)
	      end,
	      I+1;
	 (#node_counter{}, I) -> 
	      I
      end, 1, S#s.tab).

format_node(I,State, Addr,TimeType,Time, Lt, Node, LTm, Info) ->
    io:format("~w: state=~w ~s ~s: ~.2fs last: ~.2fs\n"
	      "    ival=~w con=~w ltm=~s\n"
	      "    features: ~w\n"
	      "    location: lat=~.4f,long=~.4f,spd=~.4f\n"
	      "    habitat: lat1=~.4f,long1=~.4f,lat2=~.4f,long2=~.4f,r=~.4f\n",
	      [I, State, Addr,
	       TimeType, Time/1000000,
	       Lt/1000000,
	       Info#node_info.ping_interval, %% == Node#node.ival
	       Node#node.con,
	       LTm,
	       decode_features(Info#node_info.features),
	       Info#node_info.lat,
	       Info#node_info.long,
	       Info#node_info.spd,
	       Info#node_info.hab_lat1,
	       Info#node_info.hab_long1,
	       Info#node_info.hab_lat2,
	       Info#node_info.hab_long2,
	       Info#node_info.hab_radius
	      ]).

time_diff_ms(A, B) ->
    erlang:convert_time_unit(A - B,native,millisecond).

time_diff_us(A, B) ->
    erlang:convert_time_unit(A - B,native,microsecond).

format_addr(NAddr) ->
    case NAddr of
	{Addr,Port} when tuple_size(Addr) =:= 4 -> 
	    inet:ntoa(Addr) ++ ":" ++ integer_to_list(Port);
	{Addr,Port} when tuple_size(Addr) =:= 6 -> 
	    "["++inet:ntoa(Addr) ++ "]:" ++ 
		integer_to_list(Port)
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
	    send_message(make_header(Conf), S)
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

%% current header size = 108 bytes
get_header(#conf{ magic=Magic },
	   <<Magic:16/binary, Features:32, NodeID:32/binary,
	     IVal:32, CacheTimeout:32,
	     Lat:32/float, Long:32/float, Spd:32/float,
	     DLat:32/float, DLong:32/float,
	     DestLat:32/float, DestLong:32/float,
	     HabLat1:32/float,HabLong1:32/float,
	     HabLat2:32/float,HabLong2:32/float,
	     HabRadius:32/float,_/binary>>) ->
    #node_info { ping_interval = IVal,
		 nodeid = NodeID,
		 features=Features,
		 lat=Lat, long=Long, spd=Spd,
		 delta_lat=DLat,delta_long=DLong,
		 dest_lat=DestLat,dest_long=DestLong,
		 hab_lat1=HabLat1, hab_long1=HabLong1,
		 hab_lat2=HabLat2, hab_long2=HabLong2,
		 hab_radius=HabRadius,
		 cache_timeout=CacheTimeout };
get_header(_Conf, _Data) -> %% No match
    false.

make_header(#conf{ magic=Magic,
		   info = #node_info {
			     nodeid=NodeID,
			     ping_interval=IVal,
			     features=Features,
			     lat=Lat, long=Long, spd=Spd,
			     delta_lat=DeltaLat,delta_long=DeltaLong,
			     dest_lat=DestLat,dest_long=DestLong,
			     hab_lat1=HabLat1, hab_long1=HabLong1,
			     hab_lat2=HabLat2, hab_long2=HabLong2,
			     hab_radius=HabRadius,
			     cache_timeout=CacheTimeout}}) ->
    <<Magic:16/binary, Features:32, NodeID:32/binary,
      IVal:32, CacheTimeout:32,
      Lat:32/float, Long:32/float, Spd:32/float,
      DeltaLat:32/float, DeltaLong:32/float,
      DestLat:32/float, DestLong:32/float,
      HabLat1:32/float,HabLong1:32/float,
      HabLat2:32/float,HabLong2:32/float,
      HabRadius:32/float>>.

tick() ->
    erlang:monotonic_time().

make_node(Addr, NodeInfo, Time) ->
    ?dbg("make_node: ~s ~s\n", [State, format_addr(Addr)]),
    IVal = NodeInfo#node_info.ping_interval,
    #node { addr=Addr, info=NodeInfo, ival=IVal, first_seen = Time, 
	    last_seen = Time, up_tick = Time }.

%% remove the oldest node that is also down 
remove_oldest(_State,0,S) ->
    S;
remove_oldest(State,N,S) ->
    Ls = get_last_seen(State, S),
    NR = case length(Ls) of
	     Len when N < Len -> N;
	     Len -> Len
	 end,
    {LsOld,_} = lists:split(NR,Ls),
    lists:foreach(
      fun({_Lt,NState,Addr}) ->
	      ets:update_counter(S#s.tab, NState, -1),
	      ets:delete(S#s.tab, Addr)
      end, LsOld),
    S.

%% get neighbours in state State sort by last_seen
get_last_seen(State, S) ->
    Ls = 
	ets:foldl(
	  fun(N, Acc) when 
		    ((N#node.state =:= State) orelse (State =:= undefined)) ->
		  [{N#node.last_seen,N#node.state,N#node.addr}|Acc];
	     (_N, Acc) ->
		  Acc
	  end, [], S#s.tab),
    lists:keysort(1, Ls).

%% zero pad or trunc
zero_pad(Bin, Size) when byte_size(Bin) > Size ->
    <<TruncBin:Size/binary,_/binary>> = Bin,
    TruncBin;
zero_pad(Bin, Size) ->
    PadSize = Size-byte_size(Bin),
    <<Bin/binary, 0:PadSize/unit:8>>.
