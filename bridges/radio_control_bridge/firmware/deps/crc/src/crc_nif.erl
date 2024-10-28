%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(crc_nif).

%% NIF Functions
-export([debug_table/1]).
-export([crc/2]).
-export([crc_init/1]).
-export([crc_update/2]).
-export([crc_final/1]).
-export([crc_fast/2]).
-export([crc_fast_init/1]).
-export([crc_fast_update/2]).
-export([crc_fast_final/1]).
-export([crc_slow/2]).
-export([crc_slow_init/1]).
-export([crc_slow_update/2]).
-export([crc_slow_final/1]).
-export([crc_info/1]).
-export([crc_list/0]).
-export([crc_residue/1]).
-export([checksum_xor/1]).
-export([crc_8/2]).
-export([crc_8_init/1]).
-export([crc_8_update/2]).
-export([crc_8_final/1]).

-on_load(init/0).

%%%===================================================================
%%% NIF Functions
%%%===================================================================

debug_table(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc(_Params, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_init(_Params) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_update(_Context, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_final(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_fast(_Params, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_fast_init(_Params) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_fast_update(_Context, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_fast_final(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_slow(_Params, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_slow_init(_Params) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_slow_update(_Context, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_slow_final(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_info(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_list() ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_residue(_Params) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

checksum_xor(_Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_8(_Seed, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_8_init(_Seed) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_8_update(_Context, _Input) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

crc_8_final(_Context) ->
	erlang:nif_error({nif_not_loaded, ?MODULE}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
init() ->
	SoName = filename:join(crc:priv_dir(), ?MODULE_STRING),
	erlang:load_nif(SoName, 0).
