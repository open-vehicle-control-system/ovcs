use anyhow::{Context, Result, anyhow, bail};
use owo_colors::OwoColorize;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use crate::commands::run_ui::{self, Msg, NodeHandle};
use crate::prompt::choose;
use crate::repo_root::repo_root;
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

pub fn run(vehicle_arg: Option<String>) -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    let names: Vec<String> = list.iter().map(|v| v.dir.clone()).collect();
    let vehicle_dir = match vehicle_arg {
        Some(v) => v,
        None => choose("vehicle", &names)?,
    };
    let vehicle = list
        .into_iter()
        .find(|v| v.dir == vehicle_dir)
        .ok_or_else(|| anyhow!("Unknown vehicle {}", vehicle_dir))?;

    step("querying vehicle composer (mix snippet, may take a few seconds)…");
    let expected = expected_devices(&vehicle)?;
    step(&format!(
        "probing {} device{} on LAN…",
        expected.len(),
        if expected.len() == 1 { "" } else { "s" }
    ));
    let reachable = probe_reachable(&expected);

    if !reachable.is_empty() {
        step(&format!(
            "attaching (deployed) → {}",
            reachable
                .iter()
                .map(|(label, host)| format!("{}={}", label, host))
                .collect::<Vec<_>>()
                .join(", ")
        ));
        attach_deployed(reachable)
    } else {
        let local = find_local_beams(&vehicle.dir);
        if local.is_empty() {
            bail!(
                "no vehicle running — start one with `./ovcs run {}` or flash + power a firmware.",
                vehicle.dir
            );
        }
        step(&format!(
            "attaching (local) → {}",
            local
                .iter()
                .map(|(label, node)| format!("{}={}", label, node))
                .collect::<Vec<_>>()
                .join(", ")
        ));
        attach_local(local)
    }
}

fn step(msg: &str) {
    println!("{} {}", "•".cyan().bold(), msg);
}

// ---------- device enumeration ----------

fn expected_devices(vehicle: &vehicles::Vehicle) -> Result<Vec<(String, String)>> {
    let mut out: Vec<(String, String)> = Vec::new();
    out.push(("vms".into(), vehicles::host_for(&vehicle.dir, "vms")));
    if vehicles::has_infotainment(vehicle).unwrap_or(false) {
        out.push((
            "infotainment".into(),
            vehicles::host_for(&vehicle.dir, "infotainment"),
        ));
    }
    if let Ok(bridges) = vehicles::bridge_firmwares(vehicle) {
        for (id, fw) in bridges {
            // Skip non-Nerves bridges (e.g. Arduino targets) — they have no
            // nerves_ssh to attach to.
            if fw.target.contains("arduino") {
                continue;
            }
            let label = format!("bridge-{}", id);
            let host = vehicles::host_for(&vehicle.dir, &format!("bridge-{}", id));
            out.push((label, host));
        }
    }
    Ok(out)
}

fn probe_reachable(devices: &[(String, String)]) -> Vec<(String, String)> {
    // Probe each hostname in parallel so a slow/unreachable entry doesn't
    // stack with the others (each adds up to PROBE_TIMEOUT).
    let handles: Vec<_> = devices
        .iter()
        .cloned()
        .map(|(label, host)| {
            thread::spawn(move || {
                if tcp_open(&host, 22, PROBE_TIMEOUT) {
                    Some((label, host))
                } else {
                    None
                }
            })
        })
        .collect();
    handles
        .into_iter()
        .filter_map(|h| h.join().ok().flatten())
        .collect()
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

/// Return every local BEAM that belongs to `<vehicle>` as registered with
/// epmd, in a stable order (vms first, then infotainment, then bridges).
///
/// Recognises:
/// - `<vehicle>-vms`                       — VMS role.
/// - `<vehicle>-infotainment`              — infotainment role.
/// - `<vehicle>-bridge-<id>`               — each bridge.
fn find_local_beams(vehicle_dir: &str) -> Vec<(String, String)> {
    let Ok(out) = Command::new("epmd").arg("-names").output() else {
        return Vec::new();
    };
    let stdout = String::from_utf8_lossy(&out.stdout);

    let hostname = Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "localhost".to_string());

    // Walk each epmd registration line of the form: `name <sname> at port ...`.
    let mut snames: Vec<String> = stdout
        .lines()
        .filter_map(|l| l.trim().strip_prefix("name ").and_then(|s| s.split(" at").next()))
        .map(|s| s.to_string())
        .collect();
    snames.sort();

    let prefix = format!("{}-", vehicle_dir);

    let mut vms = None;
    let mut infotainment = None;
    let mut bridges: Vec<(String, String)> = Vec::new();

    for sname in snames {
        if let Some(rest) = sname.strip_prefix(&prefix) {
            let label = rest.to_string();
            let full = format!("{}@{}", sname, hostname);
            match label.as_str() {
                "vms" => vms = Some((label, full)),
                "infotainment" => infotainment = Some((label, full)),
                _ => bridges.push((label, full)),
            }
        }
    }

    let mut out_list = Vec::new();
    if let Some(e) = vms {
        out_list.push(e);
    }
    if let Some(e) = infotainment {
        out_list.push(e);
    }
    out_list.extend(bridges);
    out_list
}

// ---------- local transport: two remsh subprocesses (logs + shell) ----------
//
// Mirrors the deployed path (two SSH channels): one remsh subscribes to
// `RingLogger.attach()` and only streams log lines; the other is interactive
// and owns the IEx pane. Both target the single source BEAM (started by
// `./ovcs run`), which registers RingLogger as a `:logger` handler at boot.

fn attach_local(nodes: Vec<(String, String)>) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Msg>();
    let mut handles: Vec<NodeHandle> = Vec::new();
    let mut children: Vec<std::process::Child> = Vec::new();
    let pid = std::process::id();

    for (idx, (label, full_node)) in nodes.iter().enumerate() {
        step(&format!("spawning remshes for {}…", label));

        // Log-side remsh: RingLogger.attach + sleep, stdout feeds log pane.
        let log_sname = format!("ovcs_attach_log_{}_{}", pid, idx);
        let mut log_child = spawn_remsh(&log_sname, full_node)
            .with_context(|| format!("log remsh for {}", label))?;
        let log_stdout = log_child.stdout.take().unwrap();
        let log_stderr = log_child.stderr.take().unwrap();
        let mut log_stdin = log_child.stdin.take().unwrap();
        let _ = log_stdin.write_all(b"RingLogger.attach()\nProcess.sleep(:infinity)\n");
        let _ = log_stdin.flush();
        {
            let tx = tx.clone();
            let label = label.clone();
            thread::spawn(move || forward_log(log_stdout, &label, &tx));
        }
        {
            let tx = tx.clone();
            let label = label.clone();
            thread::spawn(move || forward_log(log_stderr, &label, &tx));
        }
        children.push(log_child);

        // Shell-side remsh: interactive, bound to the shell pane.
        let shell_sname = format!("ovcs_attach_sh_{}_{}", pid, idx);
        let mut shell_child = spawn_remsh(&shell_sname, full_node)
            .with_context(|| format!("shell remsh for {}", label))?;
        let shell_stdout = shell_child.stdout.take().unwrap();
        let shell_stderr = shell_child.stderr.take().unwrap();
        let shell_stdin = shell_child.stdin.take().unwrap();
        {
            let tx = tx.clone();
            let label = label.clone();
            thread::spawn(move || forward_shell(shell_stdout, &label, &tx));
        }
        {
            let tx = tx.clone();
            let label = label.clone();
            thread::spawn(move || forward_shell(shell_stderr, &label, &tx));
        }
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
        thread::spawn(move || {
            let mut stdin = shell_stdin;
            while let Ok(line) = stdin_rx.recv() {
                if stdin.write_all(line.as_bytes()).is_err() {
                    break;
                }
                let _ = stdin.flush();
            }
        });
        children.push(shell_child);

        let _ = tx.send(Msg::NodeUp(label.clone()));
        handles.push(NodeHandle {
            name: label.clone(),
            stdin: stdin_tx,
        });
    }

    step("attached — handing off to TUI. (Ctrl-C or q to quit)");

    let ui_result = run_ui::run(rx, handles);

    for mut child in children {
        let _ = child.kill();
        let _ = child.wait();
    }

    ui_result
}

fn spawn_remsh(local_sname: &str, full_node: &str) -> Result<std::process::Child> {
    Command::new("stdbuf")
        .args([
            "-oL",
            "-eL",
            "iex",
            "--sname",
            local_sname,
            "--cookie",
            "ovcs",
            "--remsh",
            full_node,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(Into::into)
    }

// ---------- deployed transport: SSH via russh ----------

fn attach_deployed(devices: Vec<(String, String)>) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Msg>();
    let mut handles = Vec::new();

    // One dedicated tokio runtime thread for all SSH sessions.
    let (rt_tx, rt_rx) = mpsc::channel::<DeployedJob>();
    let tx_for_rt = tx.clone();
    thread::spawn(move || run_ssh_runtime(rt_rx, tx_for_rt));

    for (label, host) in devices {
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
        rt_tx
            .send(DeployedJob {
                label: label.clone(),
                host: host.clone(),
                stdin_rx,
            })
            .map_err(|_| anyhow!("runtime thread died before we could send a job"))?;
        handles.push(NodeHandle {
            name: label,
            stdin: stdin_tx,
        });
    }

    // Close the jobs channel so the runtime can exit after final disconnects.
    drop(rt_tx);

    run_ui::run(rx, handles)
}

struct DeployedJob {
    label: String,
    host: String,
    stdin_rx: Receiver<String>,
}

fn run_ssh_runtime(jobs: Receiver<DeployedJob>, tx: Sender<Msg>) {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            let _ = tx.send(Msg::Log {
                node: "ovcs".into(),
                line: format!("failed to start tokio runtime: {}", e),
            });
            return;
        }
    };

    rt.block_on(async move {
        let mut joins = Vec::new();
        while let Ok(job) = jobs.recv() {
            let tx = tx.clone();
            joins.push(tokio::spawn(async move {
                if let Err(e) = run_device(&job.label, &job.host, job.stdin_rx, tx.clone()).await {
                    let _ = tx.send(Msg::Log {
                        node: job.label.clone(),
                        line: format!("[ovcs] session error: {}", e),
                    });
                    let _ = tx.send(Msg::NodeDown(job.label));
                }
            }));
        }
        for j in joins {
            let _ = j.await;
        }
    });
}

async fn run_device(
    label: &str,
    host: &str,
    stdin_rx: Receiver<String>,
    tx: Sender<Msg>,
) -> Result<()> {
    use russh::ChannelMsg;
    use russh::client;
    use russh::keys::ssh_key::PublicKey;
    use std::sync::Arc;

    struct H;
    impl client::Handler for H {
        type Error = russh::Error;
        async fn check_server_key(
            &mut self,
            _: &PublicKey,
        ) -> Result<bool, Self::Error> {
            Ok(true)
        }
    }

    let config = Arc::new(client::Config::default());
    let mut handle = client::connect(config, (host, 22), H)
        .await
        .with_context(|| format!("connect {} failed", host))?;

    // Authenticate with ssh-agent identities.
    let mut agent = russh::keys::agent::client::AgentClient::connect_env()
        .await
        .context("ssh-agent unreachable — is SSH_AUTH_SOCK set?")?;
    let identities = agent
        .request_identities()
        .await
        .context("ssh-agent identities request failed")?;
    let mut authed = false;
    for key in identities {
        let auth = handle
            .authenticate_publickey_with(SSH_USER, key, None, &mut agent)
            .await?;
        if auth.success() {
            authed = true;
            break;
        }
    }
    if !authed {
        bail!("ssh auth failed for {}@{}", SSH_USER, host);
    }

    // Two channels: one streams logs (RingLogger.attach + sleep), one hosts
    // the interactive IEx for user input. Both use the shell subsystem.
    let mut log_ch = handle.channel_open_session().await?;
    log_ch.request_pty(false, "xterm", 120, 40, 0, 0, &[]).await?;
    log_ch.request_shell(false).await?;
    log_ch
        .data(&b"RingLogger.attach()\n"[..])
        .await?;

    let mut shell_ch = handle.channel_open_session().await?;
    shell_ch.request_pty(false, "xterm", 120, 40, 0, 0, &[]).await?;
    shell_ch.request_shell(false).await?;

    let _ = tx.send(Msg::NodeUp(label.to_string()));

    // Stdin forwarder: bridge sync mpsc → async channel write.
    let (ain_tx, mut ain_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let blocking_tx = ain_tx.clone();
    std::thread::spawn(move || {
        while let Ok(line) = stdin_rx.recv() {
            if blocking_tx.send(line).is_err() {
                break;
            }
        }
    });

    let label_owned = label.to_string();
    let tx_owned = tx.clone();
    loop {
        tokio::select! {
            maybe = log_ch.wait() => {
                match maybe {
                    Some(ChannelMsg::Data { data }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Msg::Log {
                                node: label_owned.clone(),
                                line,
                            });
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Msg::Log {
                                node: label_owned.clone(),
                                line,
                            });
                        }
                    }
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) => break,
                    Some(_) => {}
                    None => break,
                }
            }
            maybe = shell_ch.wait() => {
                match maybe {
                    Some(ChannelMsg::Data { data }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Msg::Shell {
                                node: label_owned.clone(),
                                line,
                            });
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Msg::Shell {
                                node: label_owned.clone(),
                                line,
                            });
                        }
                    }
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) => break,
                    Some(_) => {}
                    None => break,
                }
            }
            msg = ain_rx.recv() => {
                match msg {
                    Some(line) => {
                        if shell_ch.data(line.as_bytes()).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
        }
    }

    let _ = tx.send(Msg::NodeDown(label.to_string()));
    let _ = log_ch.close().await;
    let _ = shell_ch.close().await;
    Ok(())
}

fn split_lines(bytes: &[u8]) -> Vec<String> {
    let s = String::from_utf8_lossy(bytes);
    s.split('\n')
        .filter(|l| !l.is_empty())
        .map(|l| l.trim_end_matches('\r').to_string())
        .collect()
}

// ---------- local stdio → Msg dispatch ----------

fn forward_log<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Msg>) {
    let buf = BufReader::new(reader);
    for line in buf.lines().map_while(|l| l.ok()) {
        if is_iex_noise(&line) {
            continue;
        }
        if tx
            .send(Msg::Log {
                node: node.to_string(),
                line,
            })
            .is_err()
        {
            break;
        }
    }
}

/// The log-side remsh is an IEx session we hijacked for log streaming — its
/// stdout carries real log events but also IEx's own banner / prompt / return
/// values. Drop those so they don't clutter the log pane.
fn is_iex_noise(line: &str) -> bool {
    let t = line.trim();
    t.is_empty()
        || t.starts_with("iex(")
        || t.starts_with("...(")
        || t.starts_with("Erlang/OTP")
        || t.starts_with("Interactive Elixir")
}

fn forward_shell<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Msg>) {
    let buf = BufReader::new(reader);
    for line in buf.lines().map_while(|l| l.ok()) {
        if tx
            .send(Msg::Shell {
                node: node.to_string(),
                line,
            })
            .is_err()
        {
            break;
        }
    }
}
