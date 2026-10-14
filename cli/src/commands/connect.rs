use anyhow::{bail, Result};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::thread::sleep;
use std::time::Duration;

use crate::resolve_args::resolve_vehicle_role;
use crate::ui::{step, sub, sub_miss, sub_ok};
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
// mDNS resolution and a booting Nerves device are often transiently slow,
// so one probe miss isn't conclusive.
const PROBE_ATTEMPTS: u32 = 10;
const PROBE_RETRY_BASE: Duration = Duration::from_millis(500);
const PROBE_RETRY_MAX: Duration = Duration::from_secs(5);

pub fn run(
    vehicle: Option<String>,
    role: Option<String>,
    host_override: Option<String>,
) -> Result<()> {
    let args = resolve_vehicle_role(vehicle, role)?;
    let host = host_override.unwrap_or_else(|| vehicles::host_for(&args.vehicle.dir, &args.role));

    step(&format!("connecting → {}@{}", SSH_USER, host));
    if !probe_with_retry(&host) {
        sub_miss("no response on :22");
        bail!(
            "{} is unreachable — is the device powered and on the LAN?",
            host
        );
    }
    sub_ok("reachable");

    // exec so OpenSSH owns the terminal (PTY, raw mode, SIGWINCH, signals).
    // The device's SSH login shell is IEx.
    let error = std::process::Command::new("ssh")
        .arg(format!("{}@{}", SSH_USER, host))
        .exec();
    Err(error.into())
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

/// True when a TCP connection to `host:port` opens within `timeout`.
pub(crate) fn tcp_open(host: &str, port: u16, timeout: Duration) -> bool {
    let addresses = match (host, port).to_socket_addrs() {
        Ok(addresses) => addresses.collect::<Vec<_>>(),
        Err(_) => return false,
    };
    addresses
        .into_iter()
        .any(|address| TcpStream::connect_timeout(&address, timeout).is_ok())
}
