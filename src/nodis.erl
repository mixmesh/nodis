%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    Nodis start
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis).

-export([start/0, stop/0]).
-export([subscribe/0]).
-export([unsubscribe/1]).
-export([i/0]).

start() ->
    application:start(nodis).

stop() ->
    application:stop(nodis).

i() ->
    nodis_srv:i().

subscribe() ->
    nodis_srv:subscribe().

unsubscribe(Ref) ->
    nodis_srv:unsubscribe(Ref).
