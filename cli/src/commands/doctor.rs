use anyhow::Result;
use owo_colors::OwoColorize;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::commands::vehicle_host_keys;
use crate::firmware::roles_for;
use crate::repo_root::repo_root;
use crate::ui::step;
use crate::vehicles::{self, Vehicle};

#[derive(Debug, Clone, Copy)]
enum Level {
    Required,
    Optional,
}

#[derive(Debug, Clone, Copy)]
enum Mark {
    Ok,
    Warn,
    Error,
}

struct Binary {
    name: &'static str,
    command: &'static [&'static str],
    purpose: &'static str,
    level: Level,
}

const BINARIES: &[Binary] = &[
    Binary {
        name: "mise",
        command: &["mise", "--version"],
        purpose: "language-runtime manager",
        level: Level::Required,
    },
    Binary {
        name: "elixir",
        command: &["elixir", "--version"],
        purpose: "Elixir runtime (mise-managed)",
        level: Level::Required,
    },
    Binary {
        name: "mix",
        command: &["mix", "--version"],
        purpose: "Elixir build tool",
        level: Level::Required,
    },
    Binary {
        name: "node",
        command: &["node", "--version"],
        purpose: "VMS dashboard build",
        level: Level::Required,
    },
    Binary {
        name: "ruby",
        command: &["ruby", "--version"],
        purpose: "historical scripts",
        level: Level::Optional,
    },
    Binary {
        name: "python",
        command: &["python", "--version"],
        purpose: "PlatformIO + tooling",
        level: Level::Required,
    },
    Binary {
        name: "flutter",
        command: &["flutter", "--version"],
        purpose: "infotainment dashboard",
        level: Level::Optional,
    },
    Binary {
        name: "fwup",
        command: &["fwup", "--version"],
        purpose: "Nerves firmware packaging",
        level: Level::Required,
    },
    Binary {
        name: "cansend",
        command: &["cansend"],
        purpose: "can-utils",
        level: Level::Optional,
    },
    Binary {
        name: "candump",
        command: &["candump", "--version"],
        purpose: "can-utils",
        level: Level::Optional,
    },
    Binary {
        name: "balena",
        command: &["balena", "--version"],
        purpose: "compute node push",
        level: Level::Optional,
    },
    Binary {
        name: "docker",
        command: &["docker", "--version"],
        purpose: "compute node image check",
        level: Level::Optional,
    },
    Binary {
        name: "pio",
        command: &["pio", "--version"],
        purpose: "PlatformIO (Arduino controllers)",
        level: Level::Optional,
    },
];

pub fn run() -> Result<()> {
    let mut any_required_fail = false;

    println!();
    step("Toolchain binaries");
    for binary in BINARIES {
        let mark = check_binary(binary);
        match mark {
            Mark::Ok => print_row(Mark::Ok, binary.name, binary.purpose),
            _ => print_row(
                mark,
                binary.name,
                &format!("{} — not on PATH", binary.purpose),
            ),
        }
        if matches!(mark, Mark::Error) {
            any_required_fail = true;
        }
    }

    println!();
    step("Nerves bootstrap");
    if check_nerves_bootstrap() {
        print_row(Mark::Ok, "nerves_bootstrap", "installed as Mix archive");
    } else {
        print_row(
            Mark::Error,
            "nerves_bootstrap",
            "not installed; run `mise run bootstrap`",
        );
        any_required_fail = true;
    }

    println!();
    step("libsocketcan");
    let candidates = [
        "/usr/include/libsocketcan.h",
        "/usr/local/include/libsocketcan.h",
    ];
    if candidates.iter().any(|path| Path::new(path).exists()) {
        print_row(Mark::Ok, "libsocketcan", "header present");
    } else {
        print_row(
            Mark::Warn,
            "libsocketcan",
            "header not found — needed for Cantastic on physical CAN",
        );
    }

    println!();
    step("Vehicle packages");
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    if list.is_empty() {
        print_row(Mark::Warn, "vehicles/", "no vehicle packages found");
    } else {
        for vehicle in &list {
            let targets = vehicles::nerves_target(vehicle, "vms").and_then(|vms_target| {
                Ok((
                    vms_target,
                    vehicles::nerves_target(vehicle, "infotainment")?,
                ))
            });
            let (vms_target, infotainment_target) = match targets {
                Ok(targets) => targets,
                Err(error) => {
                    let summary = error.to_string();
                    let first_line = summary.lines().next().unwrap_or("probe failed");
                    print_row(Mark::Error, &vehicle.dir, first_line);
                    any_required_fail = true;
                    continue;
                }
            };
            match (&vms_target, &infotainment_target) {
                (None, None) => {
                    print_row(
                        Mark::Error,
                        &vehicle.dir,
                        &format!(
                            "{}.vms_target/0 / .infotainment_target/0 returned nothing",
                            vehicle.module
                        ),
                    );
                    any_required_fail = true;
                }
                _ => {
                    let mut parts = Vec::new();
                    if let Some(target) = &vms_target {
                        parts.push(format!("vms → {}", target));
                    }
                    if let Some(target) = &infotainment_target {
                        parts.push(format!("infotainment → {}", target));
                    }
                    print_row(Mark::Ok, &vehicle.dir, &parts.join(", "));
                }
            }
        }
    }

    println!();
    step("Vehicle SSH host keys");
    if list.is_empty() {
        print_row(Mark::Warn, "vehicles/", "no vehicle packages found");
    } else {
        for vehicle in &list {
            let roles = roles_for(vehicle).unwrap_or_default();
            let missing = missing_host_key_roles(vehicle, &roles);
            if missing.is_empty() && !roles.is_empty() {
                print_row(Mark::Ok, &vehicle.dir, "all roles configured");
            } else if roles.is_empty() {
                print_row(Mark::Warn, &vehicle.dir, "no firmware roles");
            } else {
                print_row(
                    Mark::Warn,
                    &vehicle.dir,
                    &format!(
                        "missing keys for: {} — run `./ovcs host-keys generate {}`",
                        missing.join(", "),
                        vehicle.dir
                    ),
                );
            }
        }
    }

    println!();
    if any_required_fail {
        println!("{}", "Some checks failed — see above.".yellow());
        println!(
            "  Required failures block builds; optional ones only matter for the relevant side."
        );
        std::process::exit(1);
    }
    println!("{}", "All checks passed.".green());
    Ok(())
}

fn missing_host_key_roles(vehicle: &Vehicle, roles: &[String]) -> Vec<String> {
    roles
        .iter()
        .filter(|role| !vehicle_host_keys::missing_host_keys(vehicle, role).is_empty())
        .cloned()
        .collect()
}

fn print_row(mark: Mark, name: &str, detail: &str) {
    let symbol = match mark {
        Mark::Ok => format!("{}", "✓".green()),
        Mark::Warn => format!("{}", "⚠".yellow()),
        Mark::Error => format!("{}", "✗".red()),
    };
    println!("  {} {:<22} {}", symbol, name, detail.dimmed());
}

// Spawning is the check: `cansend` without arguments exits non-zero.
fn check_binary(binary: &Binary) -> Mark {
    let fail = match binary.level {
        Level::Required => Mark::Error,
        Level::Optional => Mark::Warn,
    };
    match Command::new(binary.command[0])
        .args(&binary.command[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(_) => Mark::Ok,
        Err(_) => fail,
    }
}

fn check_nerves_bootstrap() -> bool {
    match Command::new("mix").arg("archive").output() {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).contains("nerves_bootstrap")
        }
        _ => false,
    }
}
