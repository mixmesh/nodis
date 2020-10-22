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
      [{'ping-interval',
	#json_type{name = {integer,50,1000000},
		   info = "Interval in ms between multicast pings",
		   typical = 5000 }}
      ]
     }].
