%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2022, Tony Rogvall
%%% @doc
%%%    Utilities
%%% @end
%%% Created : 20 Jan 2022 by Tony Rogvall <tony@rogvall.se>

-module(nodis_util).

-compile(export_all).

-define(is_mac_addr(A),
	(((element(1,(A)) bor element(2,(A)) bor
	       element(3,(A)) bor element(4,(A)) bor
	       element(5,(A)) bor element(6,(A))) band (bnot 16#ff)) =:= 0)).
-define(is_ipv4_addr(A),
	(((element(1,(A)) bor element(2,(A)) bor
	       element(3,(A)) bor element(4,(A))) band (bnot 16#ff)) =:= 0)).
-define(is_ipv6_addr(A),
	(((element(1,(A)) bor element(2,(A)) bor
	       element(3,(A)) bor element(4,(A)) bor
	       element(5,(A)) bor element(6,(A)) bor
	       element(7,(A)) bor element(8,(A))) band (bnot 16#ffff)) =:= 0)).

-define(U16(X1,X0), (((X1) bsl 8) bor (X0))).
%% eui_64 from mac address


eui_64(HwAddr) ->
    eui_64("fd00::0", HwAddr).

%% unique local address
eui_64_random(SubnetID, HwAddr) ->
    <<P,Q,R,S,T>> = crypto:strong_rand_bytes(5), %% 40 bit random!
    eui_64({16#FD00+P,?U16(Q,R),?U16(S,T),SubnetID,0,0,0,0}, HwAddr).
eui_64_link(HwAddr) ->
    eui_64("fe80::", HwAddr).

eui_64(Prefix6, Name) when is_list(Prefix6) ->
    {ok,P6} = inet_parse:ipv6_address(Prefix6),
    eui_64(P6, Name);
eui_64(Prefix6, Name) when is_list(Name) ->
    {ok,[{hwaddr,[A,B,C,D,E,F]}]} = inet:ifget(Name, [hwaddr]),
    eui_64_(Prefix6, {A,B,C,D,E,F});
eui_64(Prefix6, HwAddr) when ?is_ipv6_addr(Prefix6), 
				     ?is_mac_addr(HwAddr) ->
    eui_64_(Prefix6, HwAddr).

eui_64_(_Prefix6={P1,P2,P3,P4,0,0,0,0}, _HwAddr={A,B,C,D,E,F}) ->
    AB = ?U16(A bxor 16#02,B),
    CX = ?U16(C,16#FF),
    YD = ?U16(16#FE,D),
    EF = ?U16(E,F),
    {P1,P2,P3,P4,AB,CX,YD,EF}.

format(Addr={A,B,C,D,E,F}) when ?is_mac_addr(Addr) ->
    [hx(A),lx(A),$:,hx(B),lx(B),$:,hx(C),lx(C),$:,
     hx(D),lx(D),$:,hx(E),lx(E),$:,hx(F),lx(F)];
format(Addr) ->
    inet_parse:ntoa(Addr).

xdigits() ->
    {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f}.

hx(A) ->
    element(((A bsr 4) band 16#f)+1, xdigits()).

lx(A) ->
    element((A band 16#f) +1, xdigits()).
