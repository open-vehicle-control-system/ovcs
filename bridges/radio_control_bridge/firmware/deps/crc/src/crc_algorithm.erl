%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(crc_algorithm).

-type params() :: term().
-type resource() :: term().
-type value() :: non_neg_integer().
-type info() :: #{
	width := non_neg_integer(),
	poly := non_neg_integer(),
	init := non_neg_integer(),
	refin := boolean(),
	refout := boolean(),
	xorout := non_neg_integer(),
	check := non_neg_integer(),
	residue := non_neg_integer(),
	sick := boolean(),
	atom() => term()
}.

-export_type([params/0]).
-export_type([resource/0]).
-export_type([value/0]).
-export_type([info/0]).

-callback calc(params(), iodata()) -> value().
-callback init(params()) -> resource().
-callback update(resource(), iodata()) -> resource().
-callback final(resource()) -> value().
-callback info(resource()) -> info().
-callback residue(resource()) -> value().

%% API
-export([verify_check/1]).
-export([verify_check/2]).
-export([verify_check/3]).
-export([verify_residue/1]).
-export([verify_residue/2]).
-export([verify_residue/3]).

%%====================================================================
%% API functions
%%====================================================================

verify_check(Module) ->
	verify_check(Module, #{}).

verify_check(Module, Models) when is_list(Models) ->
	verify_check(Module, Models, #{});
verify_check(Module, Options) when is_map(Options) ->
	verify_check(Module, maps:keys(crc_nif:crc_list()), Options).

verify_check(Module, Models, Options) ->
	Display = maps:get(display, Options, all),
	Message = maps:get(message, Options, <<"123456789">>),
	Reports = [begin
		Resource0 = Module:init(Model),
		#{ check := Check } = Module:info(Resource0),
		Resource1 =
			case Message of
				<< Head:4/binary, Tail/binary >> ->
					Resource1A = Module:update(Resource0, Head),
					Module:update(Resource1A, Tail);
				_ ->
					Module:update(Resource0, Message)
			end,
		Challenge0 = Module:final(Resource1),
		Challenge1 = Module:calc(Model, Message),
		#{
			model => Model,
			passed => ((Check =:= Challenge0) andalso (Check =:= Challenge1)),
			check => Check,
			challenge0 => Challenge0,
			challenge1 => Challenge1
		}
	end || Model <- Models],
	case Display of
		failed ->
			[Report || Report = #{ passed := false } <- Reports];
		passed ->
			[Report || Report = #{ passed := true } <- Reports];
		_ ->
			Reports
	end.

verify_residue(Module) ->
	verify_residue(Module, #{}).

verify_residue(Module, Models) when is_list(Models) ->
	verify_residue(Module, Models, #{});
verify_residue(Module, Options) when is_map(Options) ->
	verify_residue(Module, maps:keys(crc_nif:crc_list()), Options).

verify_residue(Module, Models, Options) ->
	Display = maps:get(display, Options, all),
	Reports = [begin
		Resource = Module:init(Model),
		#{ residue := Residue } = Module:info(Resource),
		Challenge = Module:residue(Resource),
		#{
			model => Model,
			passed => (Residue =:= Challenge),
			residue => Residue,
			challenge => Challenge
		}
	end || Model <- Models],
	case Display of
		failed ->
			[Report || Report = #{ passed := false } <- Reports];
		passed ->
			[Report || Report = #{ passed := true } <- Reports];
		_ ->
			Reports
	end.
