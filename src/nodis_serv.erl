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

-type sim_address() :: {byte(), byte(), byte(), byte(), inet:port_number()}.

-record(node,
	{
	 state = undefined :: up | down | wait | pending,
	 addr :: inet:ip_address() | sim_address(),  %% ip address of node
	 ival :: time_ms(),          %% node announce to send this often in ms
	 first_seen :: tick(),       %% first time around
	 last_seen :: tick(),        %% we have not seen the node since
	 last_up :: tick()           %& since we sent up message
	}).

-type ifindex_t() :: non_neg_integer().
-type addr_map_t() ::
	#{ inet:ip_address() => [ifindex_t()],
	   string() => [ifindex_t()],
	   ifindex_t() => [inet:ip_address()] }.

-define(NODIS_DEFAULT_PING_DELAY, 1000). %% 1s before first ping
-define(NODIS_DEFAULT_PING_INTERVAL, 5000). %% 5s
-define(NODIS_DEFAULT_MAX_PINGS_LOST, 3).   %% before being regarded as gone
-define(NODIS_DEFAULT_REFRESH_INTERVAL, 30000). %% test 30seconds
%% -define(NODIS_DEFAULT_REFRESH_INTERVAL, (5*60*1000)). %% 5min

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
	 %% resend up after refresh_interval
	 refresh_interval = ?NODIS_DEFAULT_REFRESH_INTERVAL :: time_ms(),  
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
	 node_list = [] :: [#node{}],
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
	   refresh_interval => time_ms(),
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

%% test - broadcast any message
send(Data) ->
    send(?SERVER, Data).
send(Pid, Data) ->
    gen_server:call(Pid,{send,Data}).

%% simulation feed nodis_serv with simulated ping data
%% will show up with the player subscriver as
%% {up, {A,B,C,D,Port}}
%% {missed, {A,B,C,D,Port}}
%% {down, {A,B,C,D,Port}}
simping(Pid, {A,B,C,D}, Port, IVal) when
      (A bor B bor C bor D) band (bnot 16#ff) =:= 0, %% = 4 bytes!
      is_integer(Port),
      is_integer(IVal) ->
    gen_server:cast(Pid, {simping,{A,B,C,D,Port},IVal}).

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
    Simulator = case config:lookup([simulator], false) of
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
    %% deliver current nodes
    lists:foreach(
      fun(N) ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, {up,N#node.addr}}
      end, S#s.node_list),
    {reply, {ok,Mon}, S#s { subs = Subs }};
handle_call({unsubscribe,Ref}, _From, S) ->
    case maps:take(Ref, S#s.subs) of
	error ->
	    {reply,ok,S};
	{Sub,Subs} ->
	    erlang:demonitor(Sub#sub.ref, [flush]),
	    {reply,ok,S#s { subs=Subs }}
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
handle_info({udp,U,Addr,Port,Data}, S) when S#s.in == U ->
    IsLocalAddress = maps:get(Addr, S#s.addr_map, []) =/= [],
    ?dbg("nodis: udp ~s:~w (~s) ~p\n",
	 [inet:ntoa(Addr),Port, if IsLocalAddress -> "local";
				   true -> "remote" end, Data]),
    if IsLocalAddress, Port =:= S#s.oport -> %% this is our output! (loop=true)
	    %%?dbg("nodis: discard ~s:~w ~p\n",  [inet:ntoa(Addr),Port,Data]),
	    {noreply, S};
       true ->
	    case Data of
		<<MLen:32, Magic:MLen/binary, IVal:32, _Garbage/binary>> when
		      Magic =:= (S#s.conf)#conf.magic ->
		    handle_node(Addr,IVal,S);
		_ ->
		    ?dbg("ignored data from ~s:~w = ~p\n",
			 [inet:ntoa(Addr),Port,Data]),
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

read_conf(Conf) ->
    read_conf(Conf, Conf#conf.input).

read_conf(Conf, InputOpts) ->
    read_conf_(Conf, read_options(InputOpts)).

read_conf_(Conf, Map) ->
    PingDelay = maps:get('ping-delay',Map,Conf#conf.ping_delay),
    PingInterval = maps:get('ping-interval',Map,Conf#conf.ping_interval),
    MaxPingsLost = maps:get('max-pings-lost',Map,Conf#conf.max_pings_lost),
    RefreshInterval = maps:get('refresh-interval',Map,
			       Conf#conf.refresh_interval),
    MaxUpNodes = maps:get('max-up-nodes',Map,Conf#conf.max_up_nodes),
    MaxPendingNodes = maps:get('max-pending-nodes',Map,
			       Conf#conf.max_pending_nodes),
    MaxDownNodes = maps:get('max-down-nodes',Map,Conf#conf.max_down_nodes),
    MaxWaitNodes = maps:get('max-wait-nodes',Map,Conf#conf.max_wait_nodes),
    Conf#conf {
      ping_interval = PingInterval,
      ping_delay = PingDelay,
      max_pings_lost = MaxPingsLost,
      refresh_interval = RefreshInterval,
      max_up_nodes = MaxUpNodes,
      max_pending_nodes = MaxPendingNodes,
      max_down_nodes = MaxDownNodes,
      max_wait_nodes = MaxWaitNodes
     }.

%% input options override environment options
read_options(InputOpts) ->
    Env = read_all_env(),
    io:format("Env = ~p\n", [Env]),
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
    NodeList0 = S#s.node_list,
    case lists:keytake(Addr, #node.addr, NodeList0) of
	false ->
	    Time = erlang:monotonic_time(),
	    Node = #node { state = up, 
			   addr = Addr, ival = IVal,
			   first_seen = Time, last_seen = Time,
			   last_up = Time },
	    notify_subs(S, {up, Addr}),
	    {noreply, S#s { node_list = [Node | NodeList0] }};
	{value, Node0, NodeList} ->
	    Time = erlang:monotonic_time(),
	    Node = Node0#node { addr = Addr, ival = IVal, last_seen = Time },
	    {noreply, S#s { node_list = [Node | NodeList ]}}
    end.

gc_nodes(S) ->
    Time = erlang:monotonic_time(),
    MaxPingsLost = (S#s.conf)#conf.max_pings_lost,
    Ns = gc_nodes_(S#s.node_list, Time, MaxPingsLost, S),
    S#s{ node_list = Ns }.

gc_nodes_([N|Ns], Now, MaxPingsLost, S) ->
    LTime = erlang:convert_time_unit(Now-N#node.last_seen,native,microsecond),
    if LTime > N#node.ival*MaxPingsLost*1000 ->
	    notify_subs(S, {down, N#node.addr}),
	    gc_nodes_(Ns, Now, MaxPingsLost, S);
       LTime > N#node.ival*1000 ->
	    notify_subs(S, {missed, N#node.addr}),
	    [N | gc_nodes_(Ns, Now, MaxPingsLost, S)];
       true ->
	    UTime = erlang:convert_time_unit(Now-N#node.last_up,native,millisecond),
	    %% should keep refresh_interal > N#node.ival*MaxPingsLost
	    if UTime > (S#s.conf)#conf.refresh_interval ->
		    notify_subs(S, {up, N#node.addr}),
		    [ N#node { last_up = Now } | 
		      gc_nodes_(Ns, Now, MaxPingsLost,S)];
	       true ->
		    [N | gc_nodes_(Ns, Now, MaxPingsLost,S)]
	    end
    end;
gc_nodes_([], _Now, _MaxPingsLost, _S) ->
    [].

notify_subs(S, Message) ->
    maps:fold(
      fun(_Ref,Sub,_Acc) ->
	      Sub#sub.pid ! {nodis, Sub#sub.ref, Message}
      end, ok, S#s.subs).

dump_state(S) ->
    Time = erlang:monotonic_time(),
    MaxPingsLost = (S#s.conf)#conf.max_pings_lost,
    dump_nodes(S#s.node_list, 1, Time, MaxPingsLost).

dump_nodes([N|Ns], I, Now, MaxPingsLost) ->
    UTime = erlang:convert_time_unit(Now-N#node.first_seen,native,microsecond),
    LTime = erlang:convert_time_unit(Now-N#node.last_seen,native,microsecond),
    Status = if LTime > N#node.ival*MaxPingsLost*1000 ->
		     dead;
		LTime > N#node.ival*1000 ->
		     missed;
		true ->
		     ok
	     end,
    AddrString =
	case N#node.addr of
	    {A,B,C,D,Port} -> %% from simulation
		inet:ntoa({A,B,C,D}) ++ ":" ++ integer_to_list(Port);
	    Addr ->
		inet:ntoa(Addr)
	end,
    io:format("~w: ~w ~s uptime: ~.2fs last: ~.2fs ival=~w status=~s\n",
	      [I, N#node.state, 
	       AddrString,
	       UTime/1000000,
	       LTime/1000000,
	       N#node.ival,
	       Status]),
    dump_nodes(Ns,I+1,Now,MaxPingsLost);
dump_nodes([], _I, _Now, _MaxPingsLost) ->
    ok.

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

%% FIXME
%% Map "real" interface index number
%% replace with netlink when code is fixed!
%%
%% generate #{ "interface-name" => interface-index()
-spec make_index_map() -> #{ Name::string() => ifindex_t() }.

make_index_map() ->
    IfListBin = list_to_binary(os:cmd("ip -o link show")),
    IfList = binary:split(IfListBin, <<"\n">>, [global,trim]),
    maps:from_list(
      [case binary:split(IfBin, <<": ">>, [global]) of
	   [IndexBin,NameBin | _] ->
	       {binary_to_list(NameBin),erlang:binary_to_integer(IndexBin)}
       end || IfBin <- IfList]).

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

%% insert in various queues
%% a node can only be in one state at a time

%% move node to up state, or insert in up state
node_up(_Node, _Nodes) ->
    ok.

%% move node to pending state, or insert in pending state
node_pending(_Node, _Nodes) ->
    ok.

%% move node to down state
node_down(_Node, _Nodes) ->
    ok.

%% move node to wait state
node_wait(_Node, _Nodes) ->
    ok.
