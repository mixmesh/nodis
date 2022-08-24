-module(nodis_listener_serv).
-export([start_link/0, stop/0]).
-export([message_handler/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("apptools/include/serv.hrl").
-include_lib("apptools/include/shorthand.hrl").

%%
%% Exported: start_link
%%

-spec start_link() ->
          serv:spawn_server_result().

start_link() ->
    ?spawn_server(
       fun init/1,
       fun message_handler/1,
       #serv_options{name = ?MODULE}).

%%
%% Exported: stop
%%

-spec stop() -> ok.

stop() ->
    serv:call(?MODULE, stop).


%%
%% Server
%%

init(Parent) ->
    {ok, NodisSubscription} = nodis_serv:subscribe(),
    ?LOG_INFO("Gaia Nodis listener server has been started"),
    {ok, #{parent => Parent,
           nodis_subscription => NodisSubscription}}.

message_handler(#{parent := Parent,
                  nodis_subscription := NodisSubscription} = _State) ->
    receive
        {call, From, stop = Call} ->
            ?LOG_DEBUG(#{call => Call}),
            ok = gaia_nif:stop(),
            {stop, From, ok};
        {nodis, NodisSubscription, {pending, _NodisAddress} = NodisEvent} ->
            ?LOG_DEBUG(#{nodis_event => NodisEvent}),
            noreply;
        {nodis, NodisSubscription, {up, _NodisAddress} = NodisEvent} ->
            ?LOG_DEBUG(#{nodis_event => NodisEvent}),
            noreply;
        {nodis, NodisSubscription,
         {change, _NodisAddress, _Info} = NodisEvent} ->
            ?LOG_DEBUG(#{nodis_event => NodisEvent}),
            noreply;
        {nodis, NodisSubscription, {wait, _NodisAddress} = NodisEvent} ->
            ?LOG_DEBUG(#{nodis_event => NodisEvent}),
            noreply;
        {nodis, NodisSubscription, {down, _NodisAddress} = NodisEvent} ->
            ?LOG_DEBUG(#{nodis_event => NodisEvent}),
            noreply;
        {system, From, Request} ->
            ?LOG_DEBUG(#{system => Request}),
            {system, From, Request};
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        UnknownMessage ->
            ?LOG_ERROR(#{unknown_message => UnknownMessage}),
            noreply
    end.
