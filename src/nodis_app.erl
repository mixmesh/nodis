%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%    App
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-export([config_change/3]).

start(_StartType, _StartArgs) ->
    nodis_sup:start_link([]).

stop(_State) ->
    ok.

config_change(Changed,New,Removed) ->
    nodis:config_change(Changed,New,Removed).

