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
		   typical = 1000,
                   transform = fun simulator_scaling/1,
                   untransform = fun simulator_unscaling/1}},
       {'ping-interval',
	#json_type{name = {integer,50,1000000},
		   info = "Interval in ms between multicast pings",
		   typical = 5000,
                   transform = fun simulator_scaling/1,
                   untransform = fun simulator_unscaling/1}},
       {'max-pings-lost',
	#json_type{name = {integer,1,1000},
		   info = "Number of pings missing before nodes are regarded "
		   "as down.",
		   typical = 3 }},
       {'min-wait-time',
	#json_type{name = {integer,50,1000000},
		   info = "Minimum time to wait before a node can be up again.",
		   typical = 300000,
                   transform = fun simulator_scaling/1,
                   untransform = fun simulator_unscaling/1 }}, %% 5 min
       {'min-down-time',
	#json_type{name = {integer,50,1000000},
		   info = "Minimum time to wait before a failed node is allowed back.",
		   typical = 600000,
                   transform = fun simulator_scaling/1,
                   untransform = fun simulator_unscaling/1 }}, %% 10 min
       {'max-up-nodes',
	#json_type {name = {integer,1,10000},
		    info = "Max number of nodes that can be in state up,"
		    "this limits the amount of parallel encryption work "
		    "that needs to be running at any given moment.",
		    typical = 10 }},
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

simulator_scaling(Value) ->
    SimulatorScaleFactor =
        case os:getenv("SCALEFACTOR") of
            false ->
                1;
            ScaleFactorString ->
                ?l2i(ScaleFactorString)
        end,
    round(Value / SimulatorScaleFactor).

simulator_unscaling(Value) ->
    SimulatorScaleFactor =
        case os:getenv("SCALEFACTOR") of
            false ->
                1;
            ScaleFactorString ->
                ?l2i(ScaleFactorString)
        end,
    round(Value * SimulatorScaleFactor).
