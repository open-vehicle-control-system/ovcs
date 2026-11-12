//! The HTP's performance profile: the power vote a Port holds from the context's creation to
//! its exit, after the profiles of QAIRT's HTP backend documentation, and the command line
//! that picks it.

use crate::ffi::*;

/// A performance profile. A profile's vote is made once and held, so the HTP stays at its
/// corner between requests too.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Performance {
    /// The highest voltage corner, DCVS off, RPC polling: the fastest execution.
    Burst,
    /// The TURBO corner, DCVS off, RPC polling.
    SustainedHighPerformance,
    /// The NOM_PLUS corner, DCVS off, no RPC polling.
    Balanced,
    /// The SVS corner, DCVS off, no RPC polling.
    PowerSaver,
    /// No vote: the HTP runs under its default power policy.
    NoVote,
}

/// The profile a Port runs at unless told otherwise.
pub const DEFAULT_PERFORMANCE: Performance = Performance::Burst;

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

/// A profile's DCVS_V3 vote and RPC polling time.
struct Vote {
    sleep_latency_micros: u32,
    corner: QnnHtpPerfInfrastructure_VoltageCorner_t,
    rpc_polling_micros: u32,
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
        let (sleep_latency_micros, corner, rpc_polling_micros) = match self {
            Performance::Burst => (
                40,
                DCVS_VOLTAGE_VCORNER_MAX_VOLTAGE_CORNER,
                QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIG_MAX_RPC_POLLING_TIME,
            ),
            Performance::SustainedHighPerformance => (
                100,
                DCVS_VOLTAGE_VCORNER_TURBO,
                QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIG_MAX_RPC_POLLING_TIME,
            ),
            Performance::Balanced => (1000, DCVS_VOLTAGE_VCORNER_NOM_PLUS, 0),
            Performance::PowerSaver => (1000, DCVS_VOLTAGE_VCORNER_SVS, 0),
            Performance::NoVote => return None,
        };
        Some(Vote {
            sleep_latency_micros,
            corner,
            rpc_polling_micros,
        })
    }

    /// The `setPowerConfig` calls the profile makes on the power config `id`, one config each:
    /// the DCVS_V3 vote, the RPC control latency, the RPC polling time; none for `NoVote`.
    pub(crate) fn power_configs(self, id: u32) -> Vec<QnnHtpPerfInfrastructure_PowerConfig_t> {
        let Some(vote) = self.vote() else {
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
                    rpcPollingTimeConfig: vote.rpc_polling_micros,
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

    /// What the profile votes, for the log.
    pub fn describe(self) -> String {
        match self.vote() {
            None => format!("{}: no power vote", self.name()),
            Some(vote) => format!(
                "{}: DCVS off, bus and core voltage corner {}, sleep latency {} us, \
                 RPC control latency {RPC_CONTROL_LATENCY_MICROS} us, RPC polling {} us",
                self.name(),
                corner_name(vote.corner),
                vote.sleep_latency_micros,
                vote.rpc_polling_micros
            ),
        }
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
    /// Serve requests: the Port's own positional arguments, then the performance profile, from
    /// an optional trailing `--performance <profile>`.
    Serve {
        arguments: &'a [String],
        performance: Performance,
    },
}

/// Reads `arguments`, the program's name excluded.
pub fn command_line(arguments: &[String]) -> Result<CommandLine<'_>, String> {
    match arguments {
        [flag, dlc] if flag == "--graph-names" => Ok(CommandLine::GraphNames(dlc)),
        [positional @ .., flag, profile] if flag == "--performance" => Ok(CommandLine::Serve {
            arguments: positional,
            performance: Performance::parse(profile)?,
        }),
        _ if arguments
            .iter()
            .any(|argument| argument == "--performance" || argument == "--graph-names") =>
        {
            Err("--performance <profile> comes last, --graph-names <dlc> alone".to_string())
        }
        _ => Ok(CommandLine::Serve {
            arguments,
            performance: DEFAULT_PERFORMANCE,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(arguments: &[&str]) -> Vec<String> {
        arguments.iter().map(|s| s.to_string()).collect()
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
    fn the_positional_arguments_default_to_burst() {
        let arguments = strings(&["model.bin", "0.5"]);
        assert_eq!(
            command_line(&arguments),
            Ok(CommandLine::Serve {
                arguments: &arguments,
                performance: Performance::Burst
            })
        );
    }

    #[test]
    fn a_trailing_performance_picks_the_profile() {
        let arguments = strings(&["model.bin", "19", "--performance", "balanced"]);
        assert_eq!(
            command_line(&arguments),
            Ok(CommandLine::Serve {
                arguments: &arguments[..2],
                performance: Performance::Balanced
            })
        );
        let arguments = strings(&["model.bin", "--performance", "none"]);
        assert_eq!(
            command_line(&arguments),
            Ok(CommandLine::Serve {
                arguments: &arguments[..1],
                performance: Performance::NoVote
            })
        );
    }

    #[test]
    fn a_misplaced_or_unknown_performance_is_refused() {
        for arguments in [
            &["model.bin", "--performance"][..],
            &["model.bin", "--performance", "burst", "19"],
            &["--graph-names", "model.dlc", "extra"],
        ] {
            assert!(command_line(&strings(arguments)).is_err(), "{arguments:?}");
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
        unsafe {
            (
                configs[1].__bindgen_anon_1.rpcControlLatencyConfig,
                configs[2].__bindgen_anon_1.rpcPollingTimeConfig,
            )
        }
    }

    #[test]
    fn burst_votes_the_highest_corner_with_dcvs_off_and_rpc_polling() {
        let configs = Performance::Burst.power_configs(7);
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
        assert_eq!(rpc(&configs), (100, 9999));
    }

    #[test]
    fn the_other_profiles_follow_qairts_table() {
        for (profile, sleep_latency, corner, polling) in [
            (
                Performance::SustainedHighPerformance,
                100,
                DCVS_VOLTAGE_VCORNER_TURBO,
                9999,
            ),
            (
                Performance::Balanced,
                1000,
                DCVS_VOLTAGE_VCORNER_NOM_PLUS,
                0,
            ),
            (Performance::PowerSaver, 1000, DCVS_VOLTAGE_VCORNER_SVS, 0),
        ] {
            let configs = profile.power_configs(1);
            let vote = dcvs(&configs);
            assert_eq!(vote.dcvsEnable, 0);
            assert_eq!(vote.sleepLatency, sleep_latency);
            assert_eq!(
                (vote.busVoltageCornerTarget, vote.coreVoltageCornerMax),
                (corner, corner)
            );
            assert_eq!(rpc(&configs), (100, polling));
        }
    }

    #[test]
    fn no_vote_makes_no_call() {
        assert!(Performance::NoVote.power_configs(1).is_empty());
        assert_eq!(Performance::NoVote.describe(), "none: no power vote");
    }

    #[test]
    fn a_failed_vote_is_a_warning_naming_the_call() {
        assert_eq!(
            Performance::NoVote.outcome(None),
            Ok("performance profile none: no power vote".to_string())
        );
        let warning = Performance::Burst
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
    fn the_description_names_the_vote() {
        assert_eq!(
            Performance::Burst.describe(),
            "burst: DCVS off, bus and core voltage corner MAX_VOLTAGE_CORNER, sleep latency \
             40 us, RPC control latency 100 us, RPC polling 9999 us"
        );
    }
}
