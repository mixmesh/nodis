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
-export([wait/1, wait/2]).
-export([connect/2, connect/3]).
-export([accept/2, accept/3]).
-export([get_state/1, get_state/2]).
-export([i/0, i/1]).

-export_type([state/0]).
-export_type([addr/0]).

-include_lib("apptools/include/log.hrl").

-type state() :: undefined | up | down | wait.
-type addr() :: {inet:ip_address(), inet:port_number()}.

start() ->
    application:start(nodis).

stop() ->
    application:stop(nodis).

i() ->
    nodis_serv:i().

i(Pid) ->
    nodis_serv:i(Pid).

subscribe() ->
    nodis_serv:subscribe().

subscribe(Pid) ->
    nodis_serv:subscribe(Pid).

unsubscribe(Ref) ->
    nodis_serv:unsubscribe(Ref).

unsubscribe(Pid,Ref) ->
    nodis_serv:unsubscribe(Pid,Ref).

wait(Addr) ->
    nodis_serv:wait(Addr).

wait(Pid,Addr) ->
    nodis_serv:wait(Pid, Addr).

connect(Addr,SyncAddr) ->
    nodis_serv:connect(Addr,SyncAddr).

connect(Pid,Addr,SyncAddr) ->
    nodis_serv:connect(Pid,Addr,SyncAddr).

accept(Addr,SyncAddr) ->
    nodis_serv:accept(Addr,SyncAddr).

accept(Pid,Addr,SyncAddr) ->
    nodis_serv:accept(Pid,Addr,SyncAddr).

get_state(Addr) ->
    nodis_serv:get_state(Addr).

get_state(Pid,Addr) ->
    nodis_serv:get_state(Pid, Addr).

config_change(_Changed,_New,_Removed) ->
    ?dbg_log_fmt("config_change changed=~w, new=~w, removed=~w\n", 
		 [_Changed,_New,_Removed]),
    nodis_serv ! reload,
    ok.
    
