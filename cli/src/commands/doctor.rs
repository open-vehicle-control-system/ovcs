use anyhow::Result;
use owo_colors::OwoColorize;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::firmware::applications_for;
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
    cmd: &'static [&'static str],
    purpose: &'static str,
    level: Level,
}

const BINARIES: &[Binary] = &[
    Binary {
        name: "mise",
        cmd: &["mise", "--version"],
        purpose: "language-runtime manager",
        level: Level::Required,
    },
    Binary {
        name: "elixir",
        cmd: &["elixir", "--version"],
        purpose: "Elixir runtime (mise-managed)",
        level: Level::Required,
    },
    Binary {
        name: "mix",
        cmd: &["mix", "--version"],
        purpose: "Elixir build tool",
        level: Level::Required,
    },
    Binary {
        name: "node",
        cmd: &["node", "--version"],
        purpose: "VMS dashboard build",
        level: Level::Required,
    },
    Binary {
        name: "ruby",
        cmd: &["ruby", "--version"],
        purpose: "historical scripts",
        level: Level::Optional,
    },
    Binary {
        name: "python",
        cmd: &["python", "--version"],
        purpose: "PlatformIO + tooling",
        level: Level::Required,
    },
    Binary {
        name: "flutter",
        cmd: &["flutter", "--version"],
        purpose: "infotainment dashboard",
        level: Level::Optional,
    },
    Binary {
        name: "fwup",
        cmd: &["fwup", "--version"],
        purpose: "Nerves firmware packaging",
        level: Level::Required,
    },
    Binary {
        name: "cansend",
        cmd: &["cansend"],
        purpose: "can-utils",
        level: Level::Optional,
    },
    Binary {
        name: "candump",
        cmd: &["candump", "--version"],
        purpose: "can-utils",
        level: Level::Optional,
    },
    Binary {
        name: "pio",
        cmd: &["pio", "--version"],
        purpose: "PlatformIO (Arduino controllers)",
        level: Level::Optional,
    },
];

pub fn run() -> Result<()> {
    let mut any_required_fail = false;

    println!();
    step("Toolchain binaries");
    for b in BINARIES {
        let mark = check_binary(b);
        match mark {
            Mark::Ok => print_row(Mark::Ok, b.name, b.purpose),
            _ => print_row(mark, b.name, &format!("{} — not on PATH", b.purpose)),
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
    if candidates.iter().any(|p| Path::new(p).exists()) {
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
        for v in &list {
            let vms = vehicles::nerves_target(v, "vms")?;
            let info = vehicles::nerves_target(v, "infotainment")?;
            match (&vms, &info) {
                (None, None) => {
                    print_row(
                        Mark::Error,
                        &v.dir,
                        &format!(
                            "{}.vms_target/0 / .infotainment_target/0 returned nothing",
                            v.module
                        ),
                    );
                    any_required_fail = true;
                }
                _ => {
                    let mut parts = Vec::new();
                    if let Some(t) = &vms {
                        parts.push(format!("vms → {}", t));
                    }
                    if let Some(t) = &info {
                        parts.push(format!("infotainment → {}", t));
                    }
                    print_row(Mark::Ok, &v.dir, &parts.join(", "));
                }
            }
        }
    }

    println!();
    step("Vehicle SSH host keys");
    if list.is_empty() {
        print_row(Mark::Warn, "vehicles/", "no vehicle packages found");
    } else {
        for v in &list {
            let roles = applications_for(v).unwrap_or_default();
            let missing = missing_host_key_roles(v, &roles);
            if missing.is_empty() && !roles.is_empty() {
                print_row(Mark::Ok, &v.dir, "all roles configured");
            } else if roles.is_empty() {
                print_row(Mark::Warn, &v.dir, "no firmware roles");
            } else {
                print_row(
                    Mark::Warn,
                    &v.dir,
                    &format!(
                        "missing keys for: {} — run `./ovcs vehicle host-keys {}`",
                        missing.join(", "),
                        v.dir
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
        .filter(|role| !host_keys_present(vehicle, role))
        .cloned()
        .collect()
}

fn host_keys_present(vehicle: &Vehicle, role: &str) -> bool {
    let dir = host_keys_dir(vehicle, role);
    ["ssh_host_rsa_key", "ssh_host_ed25519_key"]
        .iter()
        .all(|name| dir.join(name).exists())
}

fn host_keys_dir(vehicle: &Vehicle, role: &str) -> std::path::PathBuf {
    let base = vehicle.path.join("priv").join("host_keys");
    match role {
        "vms" | "infotainment" => base.join(role),
        bridge_id => base.join("bridges").join(bridge_id),
    }
}

fn print_row(mark: Mark, name: &str, detail: &str) {
    let sym = match mark {
        Mark::Ok => format!("{}", "✓".green()),
        Mark::Warn => format!("{}", "⚠".yellow()),
        Mark::Error => format!("{}", "✗".red()),
    };
    println!("  {} {:<22} {}", sym, name, detail.dimmed());
}

// Matches Elixir CLI: existence on PATH (spawn succeeds) counts as ok;
// we don't check the exit code because e.g. `cansend` with no args exits
// non-zero but is still "installed and working."
fn check_binary(b: &Binary) -> Mark {
    let fail = match b.level {
        Level::Required => Mark::Error,
        Level::Optional => Mark::Warn,
    };
    match Command::new(b.cmd[0])
        .args(&b.cmd[1..])
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
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).contains("nerves_bootstrap")
        }
        _ => false,
    }
}
