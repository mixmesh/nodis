%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Nodis start
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis).

-export([start/0, stop/0]).
-export([config_change/3]).
-export([subscribe/0, unsubscribe/1]).
-export([subscribe/1, unsubscribe/2]).
-export([i/0, i/1]).

-include_lib("apptools/include/log.hrl").

start() ->
    application:start(nodis).

stop() ->
    application:stop(nodis).

i() ->
    nodis_srv:i().

i(Pid) ->
    nodis_srv:i(Pid).

subscribe() ->
    nodis_srv:subscribe().

subscribe(Pid) ->
    nodis_srv:subscribe(Pid).

unsubscribe(Ref) ->
    nodis_srv:unsubscribe(Ref).

unsubscribe(Pid,Ref) ->
    nodis_srv:unsubscribe(Pid,Ref).

config_change(_Changed,_New,_Removed) ->
    ?dbg_log_fmt("config_change changed=~w, new=~w, removed=~w\n", 
		 [_Changed,_New,_Removed]),
    ok.
    
