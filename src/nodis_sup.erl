%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2020, Tony Rogvall
%%% @doc
%%%     Sup
%%% @end
%%% Created : 28 Sep 2020 by Tony Rogvall <tony@rogvall.se>

-module(nodis_sup).

-behaviour(supervisor).

%% external exports
-export([start_link/0, start_link/1, stop/0]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link(Args) ->
    case supervisor:start_link({local, ?MODULE}, ?MODULE, Args) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error ->
	    Error
    end.

start_link() ->
    supervisor:start_link({local,?MODULE}, ?MODULE, []).

stop() ->
    exit(normal).

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%----------------------------------------------------------------------
init(Args) ->
    Nodis = {nodis_serv_0, {nodis_serv, start_link_local, [Args]},
	     permanent, 5000, worker, [nodis_serv_0]},
    NodisListenerServ =
        #{id => nodis_listener_serv,
          start => {nodis_listener_serv, start_link, []}},
    {ok,{{one_for_all,3,5}, [Nodis, NodisListenerServ]}}.
