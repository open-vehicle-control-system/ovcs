use anyhow::{bail, Result};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::thread::sleep;
use std::time::Duration;

use crate::resolve_args::resolve_vehicle_app;
use crate::ui::{step, sub, sub_miss, sub_ok};
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
// mDNS (.local) resolution and a freshly-booting Nerves device are often
// transiently slow, so a single probe miss isn't conclusive. Retry several
// times with a small exponential backoff before giving up. Delays grow
// 0.5s, 1s, 2s, 4s, … capped at PROBE_RETRY_MAX. With these values the total
// wait before bailing is ~30s.
const PROBE_ATTEMPTS: u32 = 10;
const PROBE_RETRY_BASE: Duration = Duration::from_millis(500);
const PROBE_RETRY_MAX: Duration = Duration::from_secs(5);

pub fn run(
    vehicle: Option<String>,
    role: Option<String>,
    host_override: Option<String>,
) -> Result<()> {
    let args = resolve_vehicle_app(vehicle, role)?;
    let host =
        host_override.unwrap_or_else(|| vehicles::host_for(&args.vehicle.dir, &args.application));

    step(&format!("connecting → {}@{}", SSH_USER, host));
    if !probe_with_retry(&host) {
        sub_miss("no response on :22");
        bail!(
            "{} is unreachable — is the device powered and on the LAN?",
            host
        );
    }
    sub_ok("reachable");

    // Replace the CLI process with `ssh root@<host>` so OpenSSH owns
    // the terminal directly (PTY, raw mode, SIGWINCH, signal handling).
    // Nerves devices boot with IEx as the SSH login shell, so this drops
    // the user straight into an IEx prompt.
    let err = std::process::Command::new("ssh")
        .arg(format!("{}@{}", SSH_USER, host))
        .exec();
    Err(err.into())
}

/// Probe :22 up to [`PROBE_ATTEMPTS`] times with a small exponential backoff
/// ([`PROBE_RETRY_BASE`] doubling each try, capped at [`PROBE_RETRY_MAX`]).
/// Returns as soon as the port opens.
fn probe_with_retry(host: &str) -> bool {
    for attempt in 1..=PROBE_ATTEMPTS {
        if tcp_open(host, 22, PROBE_TIMEOUT) {
            return true;
        }
        if attempt < PROBE_ATTEMPTS {
            let delay = (PROBE_RETRY_BASE * 2u32.saturating_pow(attempt - 1)).min(PROBE_RETRY_MAX);
            sub(&format!(
                "no response on :22 — retrying ({}/{})",
                attempt, PROBE_ATTEMPTS
            ));
            sleep(delay);
        }
    }
    false
}

fn tcp_open(host: &str, port: u16, timeout: Duration) -> bool {
    let addrs = match (host, port).to_socket_addrs() {
        Ok(a) => a.collect::<Vec<_>>(),
        Err(_) => return false,
    };
    addrs
        .into_iter()
        .any(|a| TcpStream::connect_timeout(&a, timeout).is_ok())
}
