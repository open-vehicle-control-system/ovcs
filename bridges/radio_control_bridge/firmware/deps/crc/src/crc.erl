%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(crc).

%% Public API
-export([crc/2]).
-export([crc_init/1]).
-export([crc_update/2]).
-export([crc_final/1]).
-export([crc_8/1]).
-export([crc_8/2]).
-export([crc_16/1]).
-export([ccitt_16/1]).
-export([ccitt_16/2]).
-export([ccitt_16_kermit/1]).
-export([ccitt_16_kermit/2]).
-export([ccitt_16_xmodem/1]).
-export([ccitt_16_1D0F/1]).
-export([crc_16_dnp/1]).
-export([crc_16_modbus/1]).
-export([crc_16_sick/1]).
-export([crc_32/1]).
-export([checksum_xor/1]).
%% Internal API
-export([priv_dir/0]).

%% Types
-type uint8_t() :: 16#00..16#FF.
-type uint16_t() :: 16#0000..16#FFFF.
-type uint32_t() :: 16#00000000..16#FFFFFFFF.

%%%===================================================================
%%% Public API Functions
%%%===================================================================

-spec crc(crc_algorithm:model(), iodata()) -> crc_algorithm:value().
crc(Model, Input) ->
	crc_fast:calc(Model, Input).

-spec crc_init(crc_algorithm:model()) -> crc_algorithm:resource().
crc_init(Model) ->
	crc_fast:init(Model).

-spec crc_update(crc_algorithm:resource(), iodata()) -> crc_algorithm:resource().
crc_update(Resource, Input) ->
	crc_fast:update(Resource, Input).

-spec crc_final(crc_algorithm:resource()) -> crc_algorithm:value().
crc_final(Resource) ->
	crc_fast:final(Resource).

-spec crc_8(binary()) -> uint8_t().
crc_8(Input) ->
	crc_8(Input, 16#FF).

-spec crc_8(binary(), uint8_t()) -> uint8_t().
crc_8(Input, Seed) ->
	crc_nif:crc_8(Seed, Input).

-spec crc_16(binary()) -> uint16_t().
crc_16(Input) ->
	crc_fast:calc(crc_16, Input).

-spec ccitt_16(binary()) -> uint16_t().
ccitt_16(Input) ->
	crc_fast:calc(crc_16_ccitt_false, Input).

-spec ccitt_16(binary(), uint16_t()) -> uint16_t().
ccitt_16(Input, Seed) ->
	crc_fast:calc(#{extend => crc_16_ccitt_false, init => Seed}, Input).

-spec ccitt_16_kermit(binary()) -> uint16_t().
ccitt_16_kermit(Input) ->
	crc_fast:calc(crc_16_kermit, Input).

-spec ccitt_16_kermit(binary(), uint16_t()) -> uint16_t().
ccitt_16_kermit(Input, Seed) ->
	crc_fast:calc(#{extend => crc_16_kermit, init => Seed}, Input).

-spec ccitt_16_xmodem(binary()) -> uint16_t().
ccitt_16_xmodem(Input) ->
	crc_fast:calc(xmodem, Input).

-spec ccitt_16_1D0F(binary()) -> uint16_t().
ccitt_16_1D0F(Input) ->
	crc_fast:calc(#{extend => crc_16_ccitt_false, init => 16#1D0F}, Input).

-spec crc_16_dnp(binary()) -> uint16_t().
crc_16_dnp(Input) ->
	crc_fast:calc(crc_16_dnp, Input).

-spec crc_16_modbus(binary()) -> uint16_t().
crc_16_modbus(Input) ->
	crc_fast:calc(crc_16_modbus, Input).

-spec crc_16_sick(binary()) -> uint16_t().
crc_16_sick(Input) ->
	crc_fast:calc(crc_16_sick, Input).

-spec crc_32(binary()) -> uint32_t().
crc_32(Input) ->
	crc_fast:calc(crc_32, Input).

-spec checksum_xor(binary()) -> uint8_t().
checksum_xor(Input) ->
	crc_nif:checksum_xor(Input).

%%%===================================================================
%%% Internal API Functions
%%%===================================================================

-spec priv_dir() -> file:filename_all().
priv_dir() ->
	case code:priv_dir(?MODULE) of
		{error, bad_name} ->
			case code:which(?MODULE) of
				Filename when is_list(Filename) ->
					filename:join([filename:dirname(Filename), "../priv"]);
				_ ->
					"../priv"
			end;
		Dir ->
			Dir
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
