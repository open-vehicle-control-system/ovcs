use anyhow::{bail, Result};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::time::Duration;

use crate::resolve_args::resolve_vehicle_app;
use crate::ui::{step, sub_miss, sub_ok};
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

pub fn run(
    vehicle: Option<String>,
    role: Option<String>,
    host_override: Option<String>,
) -> Result<()> {
    let args = resolve_vehicle_app(vehicle, role)?;
    let host =
        host_override.unwrap_or_else(|| vehicles::host_for(&args.vehicle.dir, &args.application));

    step(&format!("connecting → {}@{}", SSH_USER, host));
    if !tcp_open(&host, 22, PROBE_TIMEOUT) {
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

fn tcp_open(host: &str, port: u16, timeout: Duration) -> bool {
    let addrs = match (host, port).to_socket_addrs() {
        Ok(a) => a.collect::<Vec<_>>(),
        Err(_) => return false,
    };
    addrs
        .into_iter()
        .any(|a| TcpStream::connect_timeout(&a, timeout).is_ok())
}
