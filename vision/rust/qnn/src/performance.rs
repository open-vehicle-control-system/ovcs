//! The HTP's power vote a Port holds from the context's creation to its exit: a performance
//! profile, after the profiles of QAIRT's HTP backend documentation, and the RPC polling; and
//! the command line that picks them.

use crate::ffi::*;

/// A performance profile: the clocks a vote holds. A vote is made once and held, so the HTP
/// stays at its corner between requests too.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Performance {
    /// The highest voltage corner, DCVS off: the fastest execution.
    Burst,
    /// The TURBO corner, DCVS off.
    SustainedHighPerformance,
    /// The NOM_PLUS corner, DCVS off.
    Balanced,
    /// The SVS corner, DCVS off.
    PowerSaver,
    /// No vote: the HTP runs under its default power policy.
    NoVote,
}

/// The profile a Port runs at unless told otherwise.
pub const DEFAULT_PERFORMANCE: Performance = Performance::Burst;

/// The RPC polling a Port votes unless told otherwise: none, the waiting thread sleeps until
/// the HTP signals the execution's end.
const DEFAULT_RPC_POLLING_MICROS: u32 = 0;

/// The longest RPC polling QNN takes, in µs.
const MAX_RPC_POLLING_MICROS: u32 = QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIG_MAX_RPC_POLLING_TIME;

const PROFILES: [(&str, Performance); 5] = [
    ("burst", Performance::Burst),
    (
        "sustained_high_performance",
        Performance::SustainedHighPerformance,
    ),
    ("balanced", Performance::Balanced),
    ("power_saver", Performance::PowerSaver),
    ("none", Performance::NoVote),
];

/// The RPC control latency every vote requests, in µs.
const RPC_CONTROL_LATENCY_MICROS: u32 = 100;

/// The power vote a Port holds: its profile's clocks and its RPC polling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Power {
    pub performance: Performance,
    /// How long the thread waiting on an execution polls for its end, in µs, before it sleeps
    /// until the HTP signals it. Polling spends that thread's core to wake up sooner.
    pub rpc_polling_micros: u32,
}

/// A profile's DCVS_V3 vote.
struct Vote {
    sleep_latency_micros: u32,
    corner: QnnHtpPerfInfrastructure_VoltageCorner_t,
}

impl Performance {
    /// The profile named `name`.
    pub fn parse(name: &str) -> Result<Performance, String> {
        PROFILES
            .iter()
            .find(|(profile_name, _)| *profile_name == name)
            .map(|&(_, profile)| profile)
            .ok_or_else(|| {
                let names: Vec<&str> = PROFILES.iter().map(|(name, _)| *name).collect();
                format!(
                    "unknown performance profile {name}, not one of {}",
                    names.join(", ")
                )
            })
    }

    pub fn name(self) -> &'static str {
        PROFILES
            .iter()
            .find(|(_, profile)| *profile == self)
            .map(|(name, _)| *name)
            .unwrap_or_default()
    }

    fn vote(self) -> Option<Vote> {
        let (sleep_latency_micros, corner) = match self {
            Performance::Burst => (40, DCVS_VOLTAGE_VCORNER_MAX_VOLTAGE_CORNER),
            Performance::SustainedHighPerformance => (100, DCVS_VOLTAGE_VCORNER_TURBO),
            Performance::Balanced => (1000, DCVS_VOLTAGE_VCORNER_NOM_PLUS),
            Performance::PowerSaver => (1000, DCVS_VOLTAGE_VCORNER_SVS),
            Performance::NoVote => return None,
        };
        Some(Vote {
            sleep_latency_micros,
            corner,
        })
    }
}

impl Power {
    /// The `setPowerConfig` calls the vote makes on the power config `id`, one config each:
    /// the DCVS_V3 vote, the RPC control latency, the RPC polling time; none for `NoVote`.
    pub(crate) fn power_configs(self, id: u32) -> Vec<QnnHtpPerfInfrastructure_PowerConfig_t> {
        let Some(vote) = self.performance.vote() else {
            return Vec::new();
        };
        let dcvs = QnnHtpPerfInfrastructure_DcvsV3_t {
            contextId: id,
            setDcvsEnable: 1,
            dcvsEnable: 0,
            powerMode: QNN_HTP_PERF_INFRASTRUCTURE_POWERMODE_PERFORMANCE_MODE,
            setSleepLatency: 1,
            sleepLatency: vote.sleep_latency_micros,
            setSleepDisable: 0,
            sleepDisable: 0,
            setBusParams: 1,
            busVoltageCornerMin: vote.corner,
            busVoltageCornerTarget: vote.corner,
            busVoltageCornerMax: vote.corner,
            setCoreParams: 1,
            coreVoltageCornerMin: vote.corner,
            coreVoltageCornerTarget: vote.corner,
            coreVoltageCornerMax: vote.corner,
        };
        vec![
            QnnHtpPerfInfrastructure_PowerConfig_t {
                option: QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_DCVS_V3,
                __bindgen_anon_1: QnnHtpPerfInfrastructure_PowerConfig_t__bindgen_ty_1 {
                    dcvsV3Config: dcvs,
                },
            },
            QnnHtpPerfInfrastructure_PowerConfig_t {
                option: QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_RPC_CONTROL_LATENCY,
                __bindgen_anon_1: QnnHtpPerfInfrastructure_PowerConfig_t__bindgen_ty_1 {
                    rpcControlLatencyConfig: RPC_CONTROL_LATENCY_MICROS,
                },
            },
            QnnHtpPerfInfrastructure_PowerConfig_t {
                option: QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_RPC_POLLING_TIME,
                __bindgen_anon_1: QnnHtpPerfInfrastructure_PowerConfig_t__bindgen_ty_1 {
                    rpcPollingTimeConfig: self.rpc_polling_micros,
                },
            },
        ]
    }

    /// The line a Port logs once the vote is made: `Ok` when it holds whole, `Err`, to log as
    /// a warning, with `error`, `Model::power_vote_error`, otherwise.
    pub fn outcome(self, error: Option<&str>) -> Result<String, String> {
        match error {
            None => Ok(format!("performance profile {}", self.describe())),
            Some(error) => Err(format!(
                "performance profile {}, not applied: {error}",
                self.describe()
            )),
        }
    }

    /// What the vote holds, for the log.
    pub fn describe(self) -> String {
        let name = self.performance.name();
        let Some(vote) = self.performance.vote() else {
            return format!("{name}: no power vote");
        };
        let rpc_polling = match self.rpc_polling_micros {
            0 => "0 us (interrupt)".to_string(),
            micros => format!("{micros} us"),
        };
        format!(
            "{name}: DCVS off, bus and core voltage corner {}, sleep latency {} us, \
             RPC control latency {RPC_CONTROL_LATENCY_MICROS} us, RPC polling {rpc_polling}",
            corner_name(vote.corner),
            vote.sleep_latency_micros
        )
    }
}

fn corner_name(corner: QnnHtpPerfInfrastructure_VoltageCorner_t) -> &'static str {
    match corner {
        DCVS_VOLTAGE_VCORNER_MAX_VOLTAGE_CORNER => "MAX_VOLTAGE_CORNER",
        DCVS_VOLTAGE_VCORNER_TURBO => "TURBO",
        DCVS_VOLTAGE_VCORNER_NOM_PLUS => "NOM_PLUS",
        DCVS_VOLTAGE_VCORNER_SVS => "SVS",
        _ => "other",
    }
}

/// What a Port's command line asks for.
#[derive(Debug, PartialEq, Eq)]
pub enum CommandLine<'a> {
    /// `--graph-names <dlc>`: print the DLC's graph names, one a line, and exit.
    GraphNames(&'a str),
    /// Serve requests: the Port's own positional arguments, then the power vote, from an
    /// optional trailing `--performance <profile>` and `--rpc-polling-us <us>`, in either order.
    Serve {
        arguments: &'a [String],
        power: Power,
    },
}

const OPTIONS: [&str; 3] = ["--performance", "--rpc-polling-us", "--graph-names"];

/// Reads `arguments`, the program's name excluded.
pub fn command_line(arguments: &[String]) -> Result<CommandLine<'_>, String> {
    if let [flag, dlc] = arguments {
        if flag == "--graph-names" {
            return Ok(CommandLine::GraphNames(dlc));
        }
    }
    let mut positional = arguments;
    let (mut performance, mut rpc_polling_micros) = (None, None);
    while let [rest @ .., flag, value] = positional {
        match flag.as_str() {
            "--performance" if performance.is_none() => {
                performance = Some(Performance::parse(value)?);
            }
            "--rpc-polling-us" if rpc_polling_micros.is_none() => {
                rpc_polling_micros = Some(parse_rpc_polling(value)?);
            }
            _ => break,
        }
        positional = rest;
    }
    if positional
        .iter()
        .any(|argument| OPTIONS.contains(&argument.as_str()))
    {
        return Err(
            "--performance <profile> and --rpc-polling-us <us> come last, once each, \
                    --graph-names <dlc> alone"
                .to_string(),
        );
    }
    let performance = performance.unwrap_or(DEFAULT_PERFORMANCE);
    if performance == Performance::NoVote && rpc_polling_micros.is_some() {
        return Err(
            "--rpc-polling-us is part of the power vote, which --performance none does not make"
                .to_string(),
        );
    }
    Ok(CommandLine::Serve {
        arguments: positional,
        power: Power {
            performance,
            rpc_polling_micros: rpc_polling_micros.unwrap_or(DEFAULT_RPC_POLLING_MICROS),
        },
    })
}

fn parse_rpc_polling(micros: &str) -> Result<u32, String> {
    micros
        .parse::<u32>()
        .ok()
        .filter(|&parsed| parsed <= MAX_RPC_POLLING_MICROS)
        .ok_or_else(|| {
            format!("RPC polling {micros} us is not an integer from 0 to {MAX_RPC_POLLING_MICROS}")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(arguments: &[&str]) -> Vec<String> {
        arguments.iter().map(|s| s.to_string()).collect()
    }

    fn serve(arguments: &[String], positional: usize, power: Power) -> CommandLine<'_> {
        CommandLine::Serve {
            arguments: &arguments[..positional],
            power,
        }
    }

    fn power(performance: Performance, rpc_polling_micros: u32) -> Power {
        Power {
            performance,
            rpc_polling_micros,
        }
    }

    #[test]
    fn profiles_are_named_as_qairt_names_them() {
        for (name, profile) in PROFILES {
            assert_eq!(Performance::parse(name), Ok(profile));
            assert_eq!(profile.name(), name);
        }
        let error = Performance::parse("turbo").unwrap_err();
        assert!(
            error.contains("burst, sustained_high_performance"),
            "{error}"
        );
    }

    #[test]
    fn the_positional_arguments_default_to_burst_without_rpc_polling() {
        let arguments = strings(&["model.bin", "0.5"]);
        assert_eq!(
            command_line(&arguments),
            Ok(serve(&arguments, 2, power(Performance::Burst, 0)))
        );
    }

    #[test]
    fn a_trailing_performance_picks_the_profile() {
        let arguments = strings(&["model.bin", "19", "--performance", "balanced"]);
        assert_eq!(
            command_line(&arguments),
            Ok(serve(&arguments, 2, power(Performance::Balanced, 0)))
        );
        let arguments = strings(&["model.bin", "--performance", "none"]);
        assert_eq!(
            command_line(&arguments),
            Ok(serve(&arguments, 1, power(Performance::NoVote, 0)))
        );
    }

    #[test]
    fn a_trailing_rpc_polling_sets_it_from_0_to_9999_us() {
        for micros in [0, 1, 9999] {
            let arguments = strings(&["model.bin", "--rpc-polling-us", &micros.to_string()]);
            assert_eq!(
                command_line(&arguments),
                Ok(serve(&arguments, 1, power(Performance::Burst, micros)))
            );
        }
    }

    #[test]
    fn performance_and_rpc_polling_come_in_either_order() {
        for arguments in [
            &[
                "ctx.bin",
                "0.4",
                "--performance",
                "balanced",
                "--rpc-polling-us",
                "9999",
            ][..],
            &[
                "ctx.bin",
                "0.4",
                "--rpc-polling-us",
                "9999",
                "--performance",
                "balanced",
            ],
        ] {
            let arguments = strings(arguments);
            assert_eq!(
                command_line(&arguments),
                Ok(serve(&arguments, 2, power(Performance::Balanced, 9999)))
            );
        }
    }

    #[test]
    fn an_rpc_polling_out_of_bounds_or_no_integer_is_refused() {
        for micros in ["10000", "-1", "abc", "1.5", ""] {
            let error =
                command_line(&strings(&["model.bin", "--rpc-polling-us", micros])).unwrap_err();
            assert_eq!(
                error,
                format!("RPC polling {micros} us is not an integer from 0 to 9999")
            );
        }
    }

    #[test]
    fn rpc_polling_without_a_vote_is_refused() {
        let error = command_line(&strings(&[
            "model.bin",
            "--performance",
            "none",
            "--rpc-polling-us",
            "0",
        ]))
        .unwrap_err();
        assert_eq!(
            error,
            "--rpc-polling-us is part of the power vote, which --performance none does not make"
        );
    }

    #[test]
    fn a_misplaced_repeated_or_unknown_option_is_refused() {
        for arguments in [
            &["model.bin", "--performance"][..],
            &["model.bin", "--rpc-polling-us"],
            &["model.bin", "--performance", "burst", "19"],
            &["model.bin", "--rpc-polling-us", "0", "19"],
            &[
                "model.bin",
                "--performance",
                "burst",
                "--performance",
                "none",
            ],
            &[
                "model.bin",
                "--rpc-polling-us",
                "0",
                "--rpc-polling-us",
                "1",
            ],
            &["--graph-names", "model.dlc", "extra"],
            &["--graph-names", "model.dlc", "--performance", "burst"],
        ] {
            assert_eq!(
                command_line(&strings(arguments)),
                Err(
                    "--performance <profile> and --rpc-polling-us <us> come last, once each, \
                     --graph-names <dlc> alone"
                        .to_string()
                ),
                "{arguments:?}"
            );
        }
        assert!(
            command_line(&strings(&["model.bin", "--performance", "fast"]))
                .unwrap_err()
                .contains("unknown performance profile fast")
        );
    }

    #[test]
    fn graph_names_take_the_dlc() {
        let arguments = strings(&["--graph-names", "model.dlc"]);
        assert_eq!(
            command_line(&arguments),
            Ok(CommandLine::GraphNames("model.dlc"))
        );
    }

    fn dcvs(
        configs: &[QnnHtpPerfInfrastructure_PowerConfig_t],
    ) -> QnnHtpPerfInfrastructure_DcvsV3_t {
        assert_eq!(
            configs[0].option,
            QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_DCVS_V3
        );
        // SAFETY: the option just checked says which field of the union is set.
        unsafe { configs[0].__bindgen_anon_1.dcvsV3Config }
    }

    fn rpc(configs: &[QnnHtpPerfInfrastructure_PowerConfig_t]) -> (u32, u32) {
        assert_eq!(
            configs[1].option,
            QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_RPC_CONTROL_LATENCY
        );
        assert_eq!(
            configs[2].option,
            QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIGOPTION_RPC_POLLING_TIME
        );
        // SAFETY: the options just checked say which fields of the unions are set.
        unsafe {
            (
                configs[1].__bindgen_anon_1.rpcControlLatencyConfig,
                configs[2].__bindgen_anon_1.rpcPollingTimeConfig,
            )
        }
    }

    #[test]
    fn burst_votes_the_highest_corner_with_dcvs_off() {
        let configs = power(Performance::Burst, 0).power_configs(7);
        assert_eq!(configs.len(), 3);
        let vote = dcvs(&configs);
        assert_eq!(vote.contextId, 7);
        assert_eq!((vote.setDcvsEnable, vote.dcvsEnable), (1, 0));
        assert_eq!((vote.setSleepLatency, vote.sleepLatency), (1, 40));
        assert_eq!(vote.setSleepDisable, 0);
        assert_eq!((vote.setBusParams, vote.setCoreParams), (1, 1));
        for corner in [
            vote.busVoltageCornerMin,
            vote.busVoltageCornerTarget,
            vote.busVoltageCornerMax,
            vote.coreVoltageCornerMin,
            vote.coreVoltageCornerTarget,
            vote.coreVoltageCornerMax,
        ] {
            assert_eq!(corner, DCVS_VOLTAGE_VCORNER_MAX_VOLTAGE_CORNER);
        }
        assert_eq!(rpc(&configs), (100, 0));
    }

    #[test]
    fn the_other_profiles_follow_qairts_table() {
        for (profile, sleep_latency, corner) in [
            (
                Performance::SustainedHighPerformance,
                100,
                DCVS_VOLTAGE_VCORNER_TURBO,
            ),
            (Performance::Balanced, 1000, DCVS_VOLTAGE_VCORNER_NOM_PLUS),
            (Performance::PowerSaver, 1000, DCVS_VOLTAGE_VCORNER_SVS),
        ] {
            let configs = power(profile, 0).power_configs(1);
            let vote = dcvs(&configs);
            assert_eq!(vote.dcvsEnable, 0);
            assert_eq!(vote.sleepLatency, sleep_latency);
            assert_eq!(
                (vote.busVoltageCornerTarget, vote.coreVoltageCornerMax),
                (corner, corner)
            );
            assert_eq!(rpc(&configs), (100, 0));
        }
    }

    #[test]
    fn the_rpc_polling_is_voted_whatever_the_profile() {
        for profile in [Performance::Burst, Performance::PowerSaver] {
            for micros in [0, 500, 9999] {
                let configs = power(profile, micros).power_configs(1);
                assert_eq!(rpc(&configs), (100, micros));
            }
        }
    }

    #[test]
    fn no_vote_makes_no_call() {
        let no_vote = power(Performance::NoVote, 0);
        assert!(no_vote.power_configs(1).is_empty());
        assert_eq!(no_vote.describe(), "none: no power vote");
    }

    #[test]
    fn a_failed_vote_is_a_warning_naming_the_call() {
        assert_eq!(
            power(Performance::NoVote, 0).outcome(None),
            Ok("performance profile none: no power vote".to_string())
        );
        let warning = power(Performance::Burst, 0)
            .outcome(Some("setPowerConfig DCVS_V3 failed with QNN error 1002"))
            .unwrap_err();
        assert!(
            warning.starts_with("performance profile burst: DCVS off"),
            "{warning}"
        );
        assert!(
            warning.ends_with("not applied: setPowerConfig DCVS_V3 failed with QNN error 1002"),
            "{warning}"
        );
    }

    #[test]
    fn the_description_names_the_vote_and_the_rpc_polling() {
        assert_eq!(
            power(Performance::Burst, 0).describe(),
            "burst: DCVS off, bus and core voltage corner MAX_VOLTAGE_CORNER, sleep latency \
             40 us, RPC control latency 100 us, RPC polling 0 us (interrupt)"
        );
        assert_eq!(
            power(Performance::Balanced, 9999).describe(),
            "balanced: DCVS off, bus and core voltage corner NOM_PLUS, sleep latency \
             1000 us, RPC control latency 100 us, RPC polling 9999 us"
        );
    }
}
