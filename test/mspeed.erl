%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2022, Tony Rogvall
%%% @doc
%%%    Determine max multicast speed
%%% @end
%%% Created :  8 Aug 2022 by Tony Rogvall <tony@rogvall.se>

-module(mspeed).

-compile(export_all).

-define(debug(_Format), ?debug(_Format, [])).
-define(debug(_Format, _Args), io:format((_Format),(_Args))).

-define(warning(_Format), ?warning(_Format, [])).
-define(warning(_Format, _Args), io:format((_Format),(_Args))).

-define(info(_Format), ?info(_Format, [])).
-define(info(_Format, _Args), io:format((_Format),(_Args))).

-define(error(_Format), ?error(_Format, [])).
-define(error(_Format, _Args), io:format((_Format),(_Args))). 

%% MAC specific reuseport options
-define(SO_REUSEPORT, 16#0200).

-define(SOL_SOCKET,   16#ffff).

-define(MULTICAST_ADDR, {224,0,0,1}).
-define(MULTICAST_IF,   {0,0,0,0}).
-define(UDP_PORT, 11111).

-define(DEFAULT_IF,0).

send() ->
    send(#{}).

send(Opts) ->
    LAddr0 = maps:get(ifaddr, Opts, ?MULTICAST_IF),
    Mttl   = maps:get(ttl, Opts, 1),
    LAddr = if is_tuple(LAddr0) -> 
		    LAddr0;
	       is_list(LAddr0) ->
		     case lookup_ip(LAddr0, inet) of
			 {error,_} ->
			     ?warning("No such interface ~p",[LAddr0]),
			     {0,0,0,0};
			 {ok,IP} -> IP
		     end;
	       LAddr0 =:= any -> 
		    {0,0,0,0};
	       true ->
		    ?warning("No such interface ~p",[LAddr0]),
		    {0,0,0,0}
	    end,
    SendOpts = [{active,false},{multicast_if,LAddr},
		{multicast_ttl,Mttl},{multicast_loop,true}],
    case gen_udp:open(0, SendOpts) of
	{ok,Out} ->    
	    {ok,OPort} = inet:port(Out),
	    MAddr  = maps:get(maddr, Opts, ?MULTICAST_ADDR),
	    MPort = ?UDP_PORT,
	    send_loop(Out, 1, MAddr, MPort, OPort, Opts);
	Error ->
	    Error
    end.

send_loop(Socket, I, MAddr, MPort, OPort, Opts) ->
    gen_udp:send(Socket, MAddr, MPort,
		 "Packet " ++ integer_to_list(I) ++ " from " ++ integer_to_list(OPort) ++ "\r\n"),
    timer:sleep(1000),
    send_loop(Socket, I+1, MAddr, MPort, OPort, Opts).

recv() ->
    recv(#{}).

recv(Opts) ->
    MAddr  = maps:get(maddr, Opts, ?MULTICAST_ADDR),
    MPort = ?UDP_PORT,
    LAddr0 = maps:get(ifaddr, Opts, ?MULTICAST_IF),
    LAddr = if is_tuple(LAddr0) -> 
		    LAddr0;
	       is_list(LAddr0) ->
		     case lookup_ip(LAddr0, inet) of
			 {error,_} ->
			     ?warning("No such interface ~p",[LAddr0]),
			     {0,0,0,0};
			 {ok,IP} -> IP
		     end;
		LAddr0 =:= any -> 
		    {0,0,0,0};
		true ->
		     ?warning("No such interface ~p",[LAddr0]),
		    {0,0,0,0}
	    end,
    RAddr = ?MULTICAST_IF,
    RecvOpts = [{reuseaddr,true},{mode,binary},{active,false},
		{ifaddr,RAddr}] ++reuse_port(),
    MultiOpts = [{add_membership,{MAddr,LAddr}},{active,true}],
    case catch gen_udp:open(MPort,RecvOpts++MultiOpts) of
	{ok,Socket} ->    
	    recv_loop(Socket);
	Error ->
	    Error
    end.

recv_loop(Socket) -> 
    receive
	{udp,Socket,Addr,Port,Data} ->
	    ?debug("mpspeed: got ~p:~w got ~s\n", [Addr, Port, Data]),
	    recv_loop(Socket)
    end.


reuse_port() ->
    case os:type() of
	{unix,Type} when Type =:= darwin; Type =:= freebsd ->
	    [{raw,?SOL_SOCKET,?SO_REUSEPORT,<<1:32/native>>}];
	_ ->
	    []
    end.

lookup_ip(Name,Family) ->
    case inet_parse:address(Name) of
	{error,_} ->
	    lookup_ifaddr(Name,Family);
	Res -> Res
    end.

lookup_ifaddr(Name,Family) ->
    case inet:getifaddrs() of
	{ok,List} ->
	    case lists:keyfind(Name, 1, List) of
		false -> {error, enoent};
		{_, Flags} ->
		    AddrList = proplists:get_all_values(addr, Flags),
		    get_family_addr(AddrList, Family)
	    end;
	_ ->
	    {error, enoent}
    end.

get_family_addr([IP|_IPs], inet) when tuple_size(IP) =:= 4 -> {ok,IP};
get_family_addr([IP|_IPs], inet6) when tuple_size(IP) =:= 8 -> {ok,IP};
get_family_addr([_|IPs],Family) -> get_family_addr(IPs,Family);
get_family_addr([],_Family) -> {error, enoent}.

