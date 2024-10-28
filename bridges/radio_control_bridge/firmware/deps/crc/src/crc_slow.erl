%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(crc_slow).
-behaviour(crc_algorithm).

%% crc_algorithm callbacks
-export([calc/2]).
-export([init/1]).
-export([update/2]).
-export([final/1]).
-export([info/1]).
-export([residue/1]).

%%====================================================================
%% crc_algorithm callbacks
%%====================================================================

calc(Params, Iodata) ->
	crc_nif:crc_slow(Params, Iodata).

init(Params) ->
	crc_nif:crc_slow_init(Params).

update(Resource, Iodata) ->
	crc_nif:crc_slow_update(Resource, Iodata).

final(Resource) ->
	crc_nif:crc_slow_final(Resource).

info(Resource) ->
	crc_nif:crc_info(Resource).

residue(Resource) ->
	crc_nif:crc_residue(Resource).
