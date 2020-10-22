%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Nodis general config
%%% @end
%%% Created : 22 Oct 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis_schema).

-export([get/0]).

-include_lib("apptools/include/config_schema.hrl").
-include_lib("apptools/include/shorthand.hrl").

get() ->
    [{nodis,
      [{'ping-delay',
	#json_type{name = {integer,50,1000000},
		   info = "Time in ms until first ping",
		   typical = 1000 }},
       {'ping-interval',
	#json_type{name = {integer,50,1000000},
		   info = "Interval in ms between multicast pings",
		   typical = 5000 }},
       {'max-pings-lost',
	#json_type{name = {integer,1,1000},
		   info = "Number of pings missing before nodes are regarded "
		   "as down",
		   typical = 3 }},
       {'refresh-interval',
	#json_type{name = {integer,50,1000000},
		   info = "Interval in ms between reactivation of nodes, "
		   "from wait state to pending.",
		   typical = 300000 }}, %% 5 min
       {'max-up-nodes',
	#json_type {name = {integer,1,10000},
		    info = "Max number of nodes that can be in state up,"
		    "this limits the amount of parallel encryption work "
		    "that needs to be running at any given moment.",
		    typical = 10 }},
       {'max-pending-nodes',
	#json_type {name = {integer,1,10000},
		    info = "Max number of nodes that are waiting to connect "
		    "and exchange messages, the nodes are served in first "
		    "come first serv fashion.",
		    typical = 100 }},
       {'max-wait-nodes',
	#json_type {name = {integer,1,10000},
		    info = "Max number of nodes that have been up, and are "
		    "waiting to be served again, after refresh interval "
		    "the node will then enter pending state if possible.",
		    typical = 1000 }},
       {'max-down-nodes',
	#json_type {name = {integer,1,10000},
		    info = "Max number of nodes to remember, nodes coming "
		    "back rapidly can be treated like they are in wait state.",
		    typical = 2000 }}
      ]
     }].
