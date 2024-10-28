%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(crc_pure).
-behaviour(crc_algorithm).

%% crc_algorithm callbacks
-export([calc/2]).
-export([init/1]).
-export([update/2]).
-export([final/1]).
-export([info/1]).
-export([residue/1]).
%% Elixir API
-export(['__struct__'/0]).
-export(['__struct__'/1]).
%% CRC API
-export([crc_reflect/2]).
-export([crc_init/1]).
-export([crc_update/3]).
-export([crc_final/2]).
-export([crc_residue/1]).
%% SICK API
-export([sick_init/1]).
-export([sick_update/3]).
-export([sick_final/2]).

%%====================================================================
%% crc_algorithm callbacks
%%====================================================================

calc(Params, Iodata) ->
	Resource0 = init(Params),
	Resource1 = update(Resource0, Iodata),
	final(Resource1).

init(Params = {Width, Poly, Init, Refin, Refout, Xorout, Check0, Residue0, Sick0})
		when (is_integer(Width) andalso Width >= 0)
		andalso (is_integer(Poly) andalso Poly >= 0)
		andalso (is_integer(Init) andalso Init >= 0)
		andalso is_boolean(Refin) andalso is_boolean(Refout)
		andalso (is_integer(Xorout) andalso Xorout >= 0) ->
	Check =
		case Check0 of
			_ when is_integer(Check0) andalso Check0 >= 0 -> Check0;
			nil -> 0;
			_ -> erlang:error({badarg, [Params]})
		end,
	Residue =
		case Residue0 of
			_ when is_integer(Residue0) andalso Residue0 >= 0 -> Residue0;
			nil -> 0;
			_ -> erlang:error({badarg, [Params]})
		end,
	Sick =
		case Sick0 of
			_ when is_boolean(Sick0) -> Sick0;
			nil -> false;
			_ -> erlang:error({badarg, [Params]})
		end,
	MSBMask = 1 bsl (Width - 1),
	CRCMask = 1 bor ((MSBMask - 1) bsl 1),
	CRCShift = case Width < 8 of true -> (8 - Width); false -> 0 end,
	case Poly > CRCMask orelse Init > CRCMask orelse Xorout > CRCMask orelse Check > CRCMask orelse Residue > CRCMask of
		true ->
			erlang:error({badarg, [Params]});
		false ->
			Resource = '__struct__'(#{
				width => Width,
				poly => Poly,
				init => Init,
				refin => Refin,
				refout => Refout,
				xorout => Xorout,
				check => Check,
				residue => Residue,
				sick => Sick,
				msb_mask => MSBMask,
				crc_mask => CRCMask,
				crc_shift => CRCShift
			}),
			case Sick of
				false ->
					Resource#{ value := crc_init(Resource) };
				true ->
					{Value, Extra} = sick_init(Resource),
					Resource#{ value := Value, extra := Extra }
			end
	end;
init(Key) when is_atom(Key) ->
	Resource = crc_fast:init(Key),
	Params = crc_nif:crc_info(Resource),
	init(Params);
init(Params = #{
	width := Width,
	poly := Poly,
	init := Init,
	refin := Refin,
	refout := Refout,
	xorout := Xorout
})
		when (is_integer(Width) andalso Width >= 0)
		andalso (is_integer(Poly) andalso Poly >= 0)
		andalso (is_integer(Init) andalso Init >= 0)
		andalso is_boolean(Refin) andalso is_boolean(Refout)
		andalso (is_integer(Xorout) andalso Xorout >= 0) ->
	Check = maps:get(check, Params, nil),
	Residue = maps:get(residue, Params, nil),
	Sick = maps:get(sick, Params, nil),
	init({Width, Poly, Init, Refin, Refout, Xorout, Check, Residue, Sick});
init(BadParams) ->
	erlang:error({badarg, [BadParams]}).

update(Resource=#{ '__struct__' := ?MODULE, value := Value, sick := false }, Iodata) ->
	Resource#{ value := crc_update(Resource, Value, erlang:iolist_to_binary(Iodata)) };
update(Resource=#{ '__struct__' := ?MODULE, value := Value, extra := Extra, sick := true }, Iodata) ->
	{NewValue, NewExtra} = sick_update(Resource, {Value, Extra}, erlang:iolist_to_binary(Iodata)),
	Resource#{ value := NewValue, extra := NewExtra }.

final(Resource=#{ '__struct__' := ?MODULE, value := Value, sick := false }) ->
	crc_final(Resource, Value);
final(Resource=#{ '__struct__' := ?MODULE, value := Value, sick := true }) ->
	sick_final(Resource, Value).

info(#{
	'__struct__' := ?MODULE,
	width := Width,
	poly := Poly,
	init := Init,
	refin := Refin,
	refout := Refout,
	xorout := Xorout,
	check := Check,
	residue := Residue,
	sick := Sick
}) ->
	#{
		width => Width,
		poly => Poly,
		init => Init,
		refin => Refin,
		refout => Refout,
		xorout => Xorout,
		check => Check,
		residue => Residue,
		sick => Sick
	};
info(Params) ->
	info(init(Params)).

residue(Resource=#{ '__struct__' := ?MODULE, sick := false }) ->
	crc_residue(Resource);
residue(Resource=#{ '__struct__' := ?MODULE, width := Width, refout := Refout, xorout := Xorout0, sick := true }) ->
	Xorout =
		case Refout of
			true -> crc_reflect(Xorout0, Width);
			false -> Xorout0
		end,
	Copy = Resource#{ init := 0, xorout := 0, value := 0 },
	{CRC, _Extra} = sick_update(Copy, {0, 0}, << Xorout:Width >>),
	sick_final(Copy, CRC);
residue(Params) ->
	residue(init(Params)).

%%%===================================================================
%%% Elixir API functions
%%%===================================================================

'__struct__'() ->
	#{
		'__struct__' => ?MODULE,
		width => nil,
		poly => nil,
		init => nil,
		refin => nil,
		refout => nil,
		xorout => nil,
		check => nil,
		residue => nil,
		sick => nil,
		msb_mask => nil,
		crc_mask => nil,
		crc_shift => nil,
		value => nil,
		extra => nil
	}.

'__struct__'(List) when is_list(List) ->
	'__struct__'(maps:from_list(List));
'__struct__'(Map) when is_map(Map) ->
	maps:fold(fun maps:update/3, '__struct__'(), Map).

%%%===================================================================
%%% CRC API functions
%%%===================================================================

crc_reflect(Reg, Width)
		when (is_integer(Reg) andalso Reg >= 0)
		andalso (is_integer(Width) andalso Width >= 0) ->
	Res = Reg band 16#01,
	do_crc_reflect(Res, Reg, 0, Width - 1).

crc_init(#{
	width := Width,
	poly := Poly,
	init := Init,
	msb_mask := MSBMask,
	crc_mask := CRCMask
}) ->
	CRC = Init,
	do_crc_init(CRC, 0, Width, Poly, MSBMask, CRCMask).

crc_update(#{}, CRC, <<>>) ->
	CRC;
crc_update(#{
	poly := Poly,
	refin := Refin,
	msb_mask := MSBMask,
	crc_mask := CRCMask
}, CRC, Rest) ->
	do_crc_update(CRC, Rest, Poly, Refin, MSBMask, CRCMask).

crc_final(#{
	width := Width,
	poly := Poly,
	refout := Refout,
	xorout := Xorout,
	msb_mask := MSBMask,
	crc_mask := CRCMask
}, CRC) ->
	do_crc_final(CRC, 0, Width, Poly, Refout, Xorout, MSBMask, CRCMask).

crc_residue(Resource = #{
	'__struct__' := ?MODULE,
	width := Width,
	refin := Refin,
	refout := Refout,
	xorout := Xorout0
}) ->
	Copy = Resource#{ init := 0, xorout := 0, value := 0 },
	Xorout =
		case Refout of
			true -> crc_reflect(Xorout0, Width);
			false -> Xorout0
		end,
	Residue = do_crc_residue(Copy, Xorout),
	case Refin of
		true -> crc_reflect(Residue, Width);
		false -> Residue
	end.

%%%===================================================================
%%% SICK API functions
%%%===================================================================

sick_init(#{
	width := 16,
	init := Init
}) ->
	{Init, 0};
sick_init(Params) ->
	erlang:error({badarg, [Params]}).

sick_update(#{ width := 16 }, {CRC, PrevByte}, <<>>) ->
	{CRC, PrevByte};
sick_update(#{
	width := 16,
	poly := Poly,
	msb_mask := MSBMask,
	crc_mask := CRCMask,
	crc_shift := CRCShift
}, {CRC, PrevByte}, Rest) ->
	do_sick_update(CRC, Rest, PrevByte, Poly, MSBMask, CRCMask, CRCShift);
sick_update(Params, CRC, Rest) ->
	erlang:error({badarg, [Params, CRC, Rest]}).

sick_final(#{ width := 16 }, CRC) ->
	LowByte = (CRC band 16#ff00) bsr 8,
	HighByte = (CRC band 16#00ff) bsl 8,
	(LowByte bor HighByte);
sick_final(Params, CRC) ->
	erlang:error({badarg, [Params, CRC]}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
do_crc_reflect(Res, _Reg, Max, Max) ->
	Res;
do_crc_reflect(Res0, Reg0, I, Max) ->
	Reg1 = Reg0 bsr 1,
	Res1 = Res0 bsl 1,
	Res2 = Res1 bor (Reg1 band 16#01),
	do_crc_reflect(Res2, Reg1, I + 1, Max).

%% @private
do_crc_init(CRC, Width, Width, _Poly, _MSBMask, CRCMask) ->
	CRC band CRCMask;
do_crc_init(CRC0, I, Width, Poly, MSBMask, CRCMask) ->
	Bit = (CRC0 band 16#01),
	CRC1 =
		case Bit of
			0 -> CRC0;
			_ -> CRC0 bxor Poly
		end,
	CRC2 = CRC1 bsr 1,
	CRC3 =
		case Bit of
			0 -> CRC2;
			_ -> CRC2 bor MSBMask
		end,
	do_crc_init(CRC3, I + 1, Width, Poly, MSBMask, CRCMask).

%% @private
do_crc_update(CRC0, << Octet, Rest/binary >>, Poly, Refin = false, MSBMask, CRCMask) ->
	CRC1 = do_crc_update_once(CRC0, Octet, 0, 8, Poly, MSBMask, CRCMask),
	do_crc_update(CRC1, Rest, Poly, Refin, MSBMask, CRCMask);
do_crc_update(CRC0, << Octet0, Rest/binary >>, Poly, Refin = true, MSBMask, CRCMask) ->
	Octet = crc_reflect(Octet0, 8),
	CRC1 = do_crc_update_once(CRC0, Octet, 0, 8, Poly, MSBMask, CRCMask),
	do_crc_update(CRC1, Rest, Poly, Refin, MSBMask, CRCMask);
do_crc_update(CRC, <<>>, _Poly, _Refin, _MSBMask, _CRCMask) ->
	CRC.

%% @private
do_crc_update_once(CRC, _Octet, Max, Max, _Poly, _MSBMask, _CRCMask) ->
	CRC;
do_crc_update_once(CRC0, Octet, I, Max, Poly, MSBMask, CRCMask) ->
	Bit = (CRC0 band MSBMask),
	CRC1 = ((CRC0 bsl 1) band CRCMask) bor ((Octet bsr (7 - I)) band 16#01),
	CRC2 =
		case Bit of
			0 -> CRC1;
			_ -> CRC1 bxor Poly
		end,
	do_crc_update_once(CRC2, Octet, I + 1, Max, Poly, MSBMask, CRCMask).

%% @private
do_crc_final(CRC0, Width, Width, _Poly, _Refout = false, Xorout, _MSBMask, CRCMask) ->
	(CRC0 bxor Xorout) band CRCMask;
do_crc_final(CRC0, Width, Width, _Poly, _Refout = true, Xorout, _MSBMask, CRCMask) ->
	CRC1 = crc_reflect(CRC0, Width),
	(CRC1 bxor Xorout) band CRCMask;
do_crc_final(CRC0, I, Width, Poly, Refout, Xorout, MSBMask, CRCMask) ->
	Bit = (CRC0 band MSBMask),
	CRC1 = ((CRC0 bsl 1) band CRCMask),
	CRC2 =
		case Bit of
			0 -> CRC1;
			_ -> CRC1 bxor Poly
		end,
	do_crc_final(CRC2, I + 1, Width, Poly, Refout, Xorout, MSBMask, CRCMask).

%% @private
do_crc_residue(#{
	width := Width,
	poly := Poly,
	init := Init,
	xorout := Xorout,
	msb_mask := MSBMask,
	crc_mask := CRCMask
}, Message) ->
	do_crc_residue(Init bxor Message, 0, Width, Poly, Xorout, MSBMask, CRCMask).

%% @private
do_crc_residue(Rem, Max, Max, _Poly, Xorout, _MSBMask, CRCMask) ->
	(Rem bxor Xorout) band CRCMask;
do_crc_residue(Rem, I, Max, Poly, Xorout, MSBMask, CRCMask) ->
	case Rem band MSBMask of
		0 ->
			do_crc_residue(Rem bsl 1, I + 1, Max, Poly, Xorout, MSBMask, CRCMask);
		_ ->
			do_crc_residue((Rem bsl 1) bxor Poly, I + 1, Max, Poly, Xorout, MSBMask, CRCMask)
	end.

%% @private
do_sick_update(CRC0, << NextByte0, Rest/binary >>, PrevByte0, Poly, MSBMask, CRCMask, CRCShift) ->
	NextByte1 = 16#00ff band NextByte0,
	CRC1 =
		case (CRC0 band (MSBMask bsl CRCShift)) of
			0 ->
				CRC0 bsl 1;
			_ ->
				(CRC0 bsl 1) bxor (Poly bsl CRCShift)
		end,
	CRC2 = CRC1 bxor (NextByte1 bor PrevByte0),
	PrevByte1 = NextByte1 bsl 8,
	do_sick_update(CRC2, Rest, PrevByte1, Poly, MSBMask, CRCMask, CRCShift);
do_sick_update(CRC, <<>>, PrevByte, _Poly, _MSBMask, CRCMask, _CRCShift) ->
	{CRC band CRCMask, PrevByte}.
