%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Node discover and manager
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis_srv).

-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1]).
-export([stop/0]).
-export([send/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([reuse_port/0]).

%% Test API
-export([dump/0]).

-compile(export_all).

-define(dbg(F,A), io:format((F),(A))).
-define(err(F,A), io:format((F),(A))).
-define(warn(F,A), io:format((F),(A))).

-define(SERVER, ?MODULE).

%% subscriber for node events
-record(sub,
	{
	 pid,
	 mon
	}).

-record(node,
	{
	 addr,
	 last_seen
	}).

-type ifindex_t() :: non_neg_integer().
-type addr_map_t() ::
	#{ inet:ip_address() => [ifindex_t()],
	   string() => [ifindex_t()],
	   ifindex_t() => [inet:ip_address()] }.

-record(s, 
	{
	 in,          %% incoming udp socket
	 out,         %% outgoing udp socket
	 maddr,       %% multicast address
	 ifaddr,      %% interface address
	 mport,       %% port number used
	 oport,       %% output port number used
	 hops :: non_neg_integer(), %% max number of hops (ttl)
	 loop :: boolean(),  %% loop on host (other applications)
	 magic :: binary(),  %% magic ping
	 node_list = [] :: [#node{}],
	 sub_list = [] :: [#sub{}],
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

-type noder_option() ::
	#{ name  =>  IfName::string(),
	   magic =>  binary(),
	   family => inet | inet6,          %% address family
	   device => undefined | string(),  %% network device used
	   maddr =>  inet:ip_address(),
	   ifaddr => inet:ip_address(),
	   hops   => non_neg_integer(),
	   loop   => boolean(),
	   timeout => ReopenTimeout::integer(),
	   status_interval => Time::timeout()
	 }.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------

-spec start_link() -> {ok,pid()} | {error,Reason::term()}.
start_link() ->
    start_link(#{}).

-spec start_link(Opts::noder_option()) ->
	  {ok,pid()} | {error,Reason::term()}.

start_link(Opts) ->
    gen_server:start_link({local,?SERVER}, ?MODULE, [Opts], []).
    
-spec dump() -> ok | {error, Error::atom()}.
dump() ->
    call(dump).

-spec stop() -> ok | {error, Error::atom()}.
stop() ->
    call(stop).

send(Data) ->
    call({send,Data}).

call(Request) -> 
    gen_server:call(?SERVER, Request).

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
init([Opts0]) ->
    Opts = if is_map(Opts0)->Opts0; is_list(Opts0)->maps:from_list(Opts0) end,
    ?dbg("init opts = ~p\n", [Opts]),
    Family = maps:get(family, Opts, inet),
    Device = maps:get(device, Opts, undefined),
    MAddr  = maps:get(maddr, Opts,  select_mcast(Family)),
    Mhops  = maps:get(hops, Opts, 1),
    Mloop  = maps:get(loop, Opts, true),
    Laddr0 = maps:get(ifaddr, Opts, Device),
    Magic  = maps:get(magic, Opts, ?NODIS_MAGIC),
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

    io:format("Sendopt = ~p\n", [[Family,{active,false},
				  {multicast_if,Laddr},
				  {multicast_ttl,Mhops},
				  {multicast_loop,Mloop}]]),
				  
    io:format("Sendopt = ~p\n", [SendOpts]),

    case gen_udp:open(0, SendOpts) of
	{ok,Out} ->
	    {ok,OutPort} = inet:port(Out),
	    io:format("output port = ~w\n", [OutPort]),
	    RecvOpts = [Family,{reuseaddr,true},{mode,binary},{active,false}]
		++ reuse_port() ++ add_membership(Family,MAddr,Laddr,AddrMap),
	    io:format("RecvOpts = ~p\n", [RecvOpts]),
	    case catch gen_udp:open(MPort,RecvOpts) of
		{ok,In} ->
		    inet:setopts(In, [{active, true}]),
		    {ok, #s{ in    = In,
			     out   = Out, 
			     maddr = MAddr,
			     mport = MPort,
			     oport = OutPort,
			     hops  = Mhops,
			     loop  = Mloop,
			     magic = Magic,
			     addr_map = AddrMap
			   }};
		{error, _Reason} = Error ->
		    {stop, Error}
	    end;
	Error ->
	    {stop, Error}
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
handle_call({send,Mesg}, _From, S) ->
    {Reply,S1} = send_message(Mesg,S),
    {reply, Reply, S1};
handle_call(dump, _From, S) ->
    dump_state(S),
    {reply, ok, S};
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
handle_cast(_Mesg, S) ->
    ?dbg("noder: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({udp,U,Addr,Port,Data}, S) when S#s.in == U ->
    IsLocalAddress = maps:get(Addr, S#s.addr_map, []) =/= [],
    ?dbg("noder: udp ~s:~w (~s) ~p\n", 
	 [inet:ntoa(Addr),Port, if IsLocalAddress -> "local";
				   true -> "remote" end, Data]),
    if IsLocalAddress, Port =:= S#s.oport -> %% this is our output! (loop=true)
	    ?dbg("noder: discard ~s:~w ~p\n",  [inet:ntoa(Addr),Port,Data]),
	    {noreply, S};
       true ->
	    %% if Data == MAGIC then add Addr to the list of  node
	    if Data =:= ?NODIS_MAGIC ->
		    handle_node(Addr, S);
	       true ->
		    ?dbg("ignored data from ~s:~w = ~p\n",
			 [inet:ntoa(Addr),Port,Data]),
		    {noreply, S}
	    end
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

handle_node(Addr, S) ->
    NodeList0 = S#s.node_list,
    case lists:keytake(Addr, #node.addr, NodeList0) of
	false ->
	    Time = erlang:monotonic_time(),
	    Node = #node { addr = Addr, last_seen = Time },
	    {noreply, S#s { node_list = [Node | NodeList0] }};
	{value, Node0, NodeList} ->
	    Time = erlang:monotonic_time(),
	    Node = Node0#node { addr = Addr, last_seen = Time },
	    {noreply, S#s { node_list = [Node | NodeList ]}}
    end.

dump_state(S) ->
    Time = erlang:monotonic_time(),
    dump_nodes(S#s.node_list, 1, Time).

dump_nodes([N|Ns], I, Now) ->
    UpTime = erlang:convert_time_unit(Now-N#node.last_seen,native,microsecond),
    io:format("~w: ~s uptime: ~.2fs\n", 
	      [I, inet:ntoa(N#node.addr),UpTime/1000000]),
    dump_nodes(Ns,I+1,Now);
dump_nodes([], _I, _Now) ->
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

send_message(Data, S) ->
    ?dbg("gen_udp: send ~s:~w message ~p\n", [inet:ntoa(S#s.maddr),S#s.mport,
					      Data]),
    case gen_udp:send(S#s.out, S#s.maddr, S#s.mport, Data) of
	ok ->
	    ?dbg("gen_udp: send message ~p\n", [Data]),
	    {ok,S};
	_Error ->
	    ?dbg("gen_udp: failure=~p\n", [_Error]),
	    {{error,_Error}, S}
    end.
