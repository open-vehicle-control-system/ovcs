use anyhow::{anyhow, bail, Context, Result};
use std::io::{BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use russh::keys::ssh_key::PublicKey;

use crate::ansi::strip_ansi;
use crate::commands::connect::tcp_open;
use crate::commands::run_ui::{self, Message, NodeHandle};
use crate::commands::vehicle_host_keys;
use crate::erlang_cookie;
use crate::firmware;
use crate::lines::lossy_lines;
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_miss, sub_ok};
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
/// Long enough not to hammer a node that just crashed, short enough to
/// reconnect promptly when it comes back.
const BACKOFF_CAP: Duration = Duration::from_secs(10);
/// So an unresponsive host doesn't block shutdown.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Idle time after which a keepalive probes a session; a board that misses
/// `russh`'s default three in a row is treated as gone and reconnected.
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(5);
/// Grows by `next_backoff` up to `BACKOFF_CAP`.
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
/// A session is considered "healthy" (and backoff is reset to
/// `INITIAL_BACKOFF`) only if it stayed up this long.
const HEALTHY_SESSION: Duration = Duration::from_secs(30);
/// How long a local session waits on stdin before checking its
/// children, epmd and the shutdown flag.
const STDIN_RECV_TIMEOUT: Duration = Duration::from_millis(200);
/// Interval between epmd re-checks while a local trio is up.
const EPMD_RECHECK_INTERVAL: Duration = Duration::from_secs(1);
/// How often `interruptible_sleep` checks the shutdown flag.
const SHUTDOWN_POLL: Duration = Duration::from_millis(100);
/// How often `wait_until_registered` polls epmd for a BEAM.
const EPMD_REGISTER_POLL: Duration = Duration::from_millis(250);

pub fn run(vehicle_arg: Option<String>) -> Result<()> {
    let vehicle = resolve_vehicle(vehicle_arg)?;

    step(&format!("vehicle: {} ({})", vehicle.module, vehicle.dir));

    let expected = expected_devices(&vehicle)?;

    step(&format!(
        "probing {} device{} on LAN (TCP :22, {}ms timeout)…",
        expected.len(),
        if expected.len() == 1 { "" } else { "s" },
        PROBE_TIMEOUT.as_millis(),
    ));
    let reachable = probe_reachable(&expected);

    if !reachable.is_empty() {
        step(&format!(
            "attaching (deployed) → {} device{}",
            reachable.len(),
            if reachable.len() == 1 { "" } else { "s" }
        ));
        attach_deployed(&vehicle, reachable)
    } else {
        step("no deployed devices reachable — checking local epmd…");
        let local = find_local_beams(&vehicle.dir);
        if local.is_empty() {
            sub("epmd has no matching BEAMs registered");
            bail!(
                "no vehicle running — start one with `./ovcs run {}` or flash + power a firmware.",
                vehicle.dir
            );
        }
        for (label, node) in &local {
            sub_ok(&format!("{:<14} → {}", label, node));
        }
        step(&format!(
            "attaching (local) → {} BEAM{}",
            local.len(),
            if local.len() == 1 { "" } else { "s" }
        ));
        attach_local(local)
    }
}

// ---------- device enumeration ----------

fn expected_devices(vehicle: &vehicles::Vehicle) -> Result<Vec<(String, String)>> {
    step("enumerating declared roles (this spawns short `mix run` probes)…");

    let mut devices: Vec<(String, String)> = Vec::new();

    let vms_host = vehicles::host_for(&vehicle.dir, "vms");
    sub_ok(&format!("{:<14} {}", "vms", vms_host));
    devices.push(("vms".into(), vms_host));

    match vehicles::has_infotainment(vehicle) {
        Ok(true) => {
            let host = vehicles::host_for(&vehicle.dir, "infotainment");
            sub_ok(&format!("{:<14} {}", "infotainment", host));
            devices.push(("infotainment".into(), host));
        }
        Ok(false) => sub(&format!(
            "{:<14} skipped (vehicle declares no infotainment side)",
            "infotainment"
        )),
        Err(error) => sub(&format!(
            "{:<14} skipped ({})",
            "infotainment",
            error.to_string().lines().next().unwrap_or("probe failed")
        )),
    }

    match vehicles::bridge_firmwares(vehicle) {
        Ok(bridges) if bridges.is_empty() => {
            sub(&format!("{:<14} none declared", "bridges"));
        }
        Ok(bridges) => {
            let mut ids: Vec<_> = bridges.iter().collect();
            ids.sort_by(|a, b| a.0.cmp(b.0));
            for (id, bridge) in ids {
                let label = format!("bridge-{}", id);
                if bridge.target.contains("arduino") {
                    sub(&format!(
                        "{:<14} skipped (arduino target has no SSH)",
                        label
                    ));
                    continue;
                }
                let host = vehicles::host_for(&vehicle.dir, &format!("bridge-{}", id));
                sub_ok(&format!("{:<14} {}", label, host));
                devices.push((label, host));
            }
        }
        Err(error) => sub(&format!(
            "{:<14} probe failed ({})",
            "bridges",
            error.to_string().lines().next().unwrap_or("?")
        )),
    }

    Ok(devices)
}

fn probe_reachable(devices: &[(String, String)]) -> Vec<(String, String)> {
    // In parallel, each result printed as soon as its probe finishes.
    let (tx, rx) = std::sync::mpsc::channel();

    let handles: Vec<_> = devices
        .iter()
        .cloned()
        .enumerate()
        .map(|(index, (label, host))| {
            let tx = tx.clone();
            thread::spawn(move || {
                let reachable = tcp_open(&host, 22, PROBE_TIMEOUT);
                let _ = tx.send((index, label, host, reachable));
            })
        })
        .collect();
    drop(tx);

    let mut results: Vec<Option<(String, String, bool)>> = vec![None; devices.len()];
    for (index, label, host, reachable) in rx {
        if reachable {
            sub_ok(&format!("{:<14} reachable", label));
        } else {
            sub_miss(&format!("{:<14} no response", label));
        }
        results[index] = Some((label, host, reachable));
    }
    for handle in handles {
        let _ = handle.join();
    }

    results
        .into_iter()
        .flatten()
        .filter_map(|(label, host, reachable)| reachable.then_some((label, host)))
        .collect()
}

/// Every local BEAM of the vehicle registered with epmd, as
/// `(role, sname@host)`, in `local_beams_for`'s order.
fn find_local_beams(vehicle_dir: &str) -> Vec<(String, String)> {
    let Ok(epmd) = Command::new("epmd").arg("-names").output() else {
        return Vec::new();
    };
    let stdout = String::from_utf8_lossy(&epmd.stdout);

    let hostname = Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|name| name.trim().to_string())
        .unwrap_or_else(|| "localhost".to_string());

    local_beams_for(vehicle_dir, &epmd_snames(&stdout))
        .into_iter()
        .map(|(role, sname)| (role, format!("{}@{}", sname, hostname)))
        .collect()
}

/// The snames registered in `epmd -names` output, one per
/// `name <sname> at port <port>` line.
fn epmd_snames(output: &str) -> Vec<&str> {
    output
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("name ")
                .and_then(|registration| registration.split(" at").next())
        })
        .collect()
}

/// The snames `./ovcs run` gives `vehicle_dir`'s BEAMs
/// (`vehicles::local_sname`), as `(role, sname)`: vms first, then
/// infotainment, then bridges in sname order.
fn local_beams_for<'a>(vehicle_dir: &str, snames: &[&'a str]) -> Vec<(String, &'a str)> {
    let mut sorted = snames.to_vec();
    sorted.sort();

    let prefix = vehicles::local_sname_prefix(vehicle_dir);

    let mut vms = None;
    let mut infotainment = None;
    let mut bridges: Vec<(String, &str)> = Vec::new();

    for sname in sorted {
        if let Some(role) = sname.strip_prefix(&prefix) {
            match role {
                "vms" => vms = Some((role.to_string(), sname)),
                "infotainment" => infotainment = Some((role.to_string(), sname)),
                _ if firmware::bridge_id(role).is_some_and(|id| !id.is_empty()) => {
                    bridges.push((role.to_string(), sname))
                }
                // Another vehicle whose name extends this one, e.g. `ovcs-mini-vms` for `ovcs`.
                _ => {}
            }
        }
    }

    vms.into_iter().chain(infotainment).chain(bridges).collect()
}

// ---------- local transport: three remsh subprocesses (logs + shell + monitor) -
//
// Like the deployed path's three SSH channels: one remsh streams
// `RingLogger.attach()` logs, one drives the IEx pane, and one streams the
// monitor's tagged lines into the bus and CAN panes.

macro_rules! log_ready_marker {
    () => {
        "OVCS_LOG_READY"
    };
}

/// Printed by the log snippet once `RingLogger.attach/0` has succeeded.
/// The log reader drops every line until it, hiding the IEx banner, the
/// echoed snippet and the prompt that follows it.
const LOG_READY_MARKER: &str = log_ready_marker!();

/// Input of the log channel. `RingLogger.attach/0` raises until
/// ring_logger is up, which a reconnect usually races, so it retries.
const LOG_INIT_SNIPPET: &str = concat!(
    r#"Enum.reduce_while(1..120, :retry, fn _, _ ->
  try do
    case RingLogger.attach() do
      :ok -> {:halt, :ok}
      _ ->
        Process.sleep(500)
        {:cont, :retry}
    end
  rescue
    _ ->
      Process.sleep(500)
      {:cont, :retry}
  catch
    _, _ ->
      Process.sleep(500)
      {:cont, :retry}
  end
end)
IO.puts(""#,
    log_ready_marker!(),
    r#"")
Process.sleep(:infinity)
"#
);

/// Elixir snippet injected into the monitor channel on every node.
///
/// - Subscribes to `OvcsBus` messages on the VMS node only: `OvcsBus.Cluster`
///   fans them out cluster-wide, so every node would print each one.
/// - Runs `candump` on every CAN interface the node's Cantastic networks
///   declare, decoding frames with the node's own frame specifications.
///
/// Emits tab-separated lines on `:stdio`:
/// - `OVCS_BUS\t<source>\t<name>\t<inspect(value)>`
/// - `OVCS_CAN\t<network>\t<frame>\t<key=val key=val …>`
///
/// The Rust side splits on `\t` and dispatches to the bus / can pane.
const MONITOR_SNIPPET: &str = r##"defmodule OvcsAttachDiag do
  # Once attach disconnects, stdio is gone and `IO.puts` raises; the
  # unsupervised monitor processes exit quietly instead of flooding the
  # logger. The next attach spawns fresh ones.
  def log(line) do
    IO.puts(line)
  rescue
    ErlangError -> exit(:normal)
  end
end

OvcsAttachDiag.log("OVCS_CAN\t[mon]\talive\tnode=#{inspect(node())}")

Enum.reduce_while(1..120, :retry, fn _, _ ->
  if Code.ensure_loaded?(OvcsBus.Message) and Code.ensure_loaded?(Cantastic.Frame) do
    {:halt, :ok}
  else
    Process.sleep(500)
    {:cont, :retry}
  end
end)

OvcsAttachDiag.log("OVCS_CAN\t[mon]\tdeps_loaded\tok")

defmodule OvcsAttachMonitor do
  @moduledoc false

  # One `candump -tz` Port per declared interface: `Cantastic.Receiver`
  # forwards only a network's `received_frames`, so it misses what the
  # node emits itself. Frames with a known id are decoded with `Frame.interpret/2`.

  def start do
    build_spec_cache()

    OvcsAttachDiag.log(
      "OVCS_BUS\t[mon]\tnode\tself=#{inspect(node())} vms?=#{vms?()} peers=#{inspect(Node.list())} bus?=#{bus_running?()}"
    )

    if subscribe_locally?() do
      spawn(&bus_loop/0)
    end

    case interfaces() do
      [] ->
        OvcsAttachDiag.log("OVCS_CAN\t[mon]\tno_interfaces\tok")

      interfaces ->
        OvcsAttachDiag.log("OVCS_CAN\t[mon]\tstarting\t#{Enum.join(interfaces, ",")}")
        for interface <- interfaces, do: spawn(fn -> candump_loop(interface) end)
    end
  end

  defp vms?, do: String.contains?(Atom.to_string(node()), "-vms")

  defp bus_running?, do: Process.whereis(OvcsBus) != nil

  # Only the VMS node subscribes, as `OvcsBus.Cluster` fans messages out;
  # a node without distribution is isolated, so it subscribes too.
  defp subscribe_locally? do
    bus_running?() and (vms?() or node() == :nonode@nohost)
  end

  defp interfaces do
    try do
      networks() |> Enum.map(& &1.interface) |> Enum.uniq()
    catch
      _, _ -> []
    end
  end

  defp networks do
    try do
      Cantastic.ConfigurationStore.networks()
    catch
      _, _ -> []
    end
  end

  # -- spec cache -----------------------------------------------------
  #
  # Built from the network's YAML rather than read from the Receiver,
  # which holds only received frames.

  defp build_spec_cache do
    Enum.each(networks(), fn network ->
      emitted =
        build_specs(network.network_name, network.network_config[:emitted_frames] || [], :emit)

      received =
        build_specs(network.network_name, network.network_config[:received_frames] || [], :receive)

      :persistent_term.put({:ovcs_attach_specs, network.interface}, %{
        network_name: network.network_name,
        specs: Map.merge(received, emitted)
      })
    end)
  end

  defp build_specs(network_name, yaml_specs, direction) do
    Enum.reduce(yaml_specs, %{}, fn yaml, specs ->
      try do
        {:ok, spec} = Cantastic.FrameSpecification.from_yaml(network_name, yaml, direction)
        Map.put(specs, spec.id, spec)
      rescue
        _ -> specs
      catch
        _, _ -> specs
      end
    end)
  end

  defp lookup_spec(interface, id) do
    case :persistent_term.get({:ovcs_attach_specs, interface}, nil) do
      nil -> {to_string(interface), nil}
      %{network_name: network_name, specs: specs} -> {Atom.to_string(network_name), Map.get(specs, id)}
    end
  end

  # -- OvcsBus --------------------------------------------------------

  defp bus_loop do
    subscribed? =
      Enum.reduce_while(1..120, false, fn _, _ ->
        try do
          OvcsBus.subscribe("messages")
          {:halt, true}
        rescue
          _ -> Process.sleep(500); {:cont, false}
        catch
          _, _ -> Process.sleep(500); {:cont, false}
        end
      end)

    OvcsAttachDiag.log("OVCS_BUS\t[mon]\tsubscribed\t#{subscribed?}")
    bus_receive()
  end

  defp bus_receive do
    receive do
      %OvcsBus.Message{source: source, name: name, value: value} ->
        OvcsAttachDiag.log("OVCS_BUS\t#{inspect(source)}\t#{name}\t#{inspect(value)}")

      _ ->
        :ok
    end

    bus_receive()
  end

  # -- candump --------------------------------------------------------

  defp candump_loop(interface) do
    candump = System.find_executable("candump") || "/usr/bin/candump"

    port =
      Port.open({:spawn_executable, candump}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-tz", interface]
      ])

    read_port(port, interface, "")
  end

  defp read_port(port, interface, pending) do
    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(pending <> chunk)
        Enum.each(lines, &process_line(interface, &1))
        read_port(port, interface, rest)

      {^port, {:exit_status, code}} ->
        OvcsAttachDiag.log("OVCS_CAN\t[mon]\tcandump_exit\t#{interface} code=#{code}")
    end
  end

  defp split_lines(text) do
    parts = String.split(text, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  # candump -tz produces lines like:
  #   " (0.000123)  vcan0  1A0   [8]  00 00 01 FF FF FF 7F 00"
  defp process_line(interface, line) do
    case Regex.run(~r/^\s*\([\d.]+\)\s+\S+\s+([0-9A-Fa-f]+)\s+\[(\d+)\]\s*(.*)$/, line) do
      [_, id_hex, dlc, data_hex] ->
        id = String.to_integer(id_hex, 16)
        byte_number = String.to_integer(dlc)
        raw_data = hex_bytes_to_binary(data_hex)
        {network, spec} = lookup_spec(interface, id)

        emit_frame(network, id_hex, byte_number, raw_data, data_hex, spec)

      _ ->
        :ok
    end
  end

  defp hex_bytes_to_binary(hex_bytes) do
    hex_bytes
    |> String.split()
    |> Enum.reduce(<<>>, fn byte_hex, bytes ->
      <<bytes::binary, String.to_integer(byte_hex, 16)>>
    end)
  end

  # Signals and raw hex are separate fields so the CAN pane can toggle
  # between them. A frame that fails to decode has no signals.
  defp emit_frame(network, id_hex, _byte_number, _raw_data, data_hex, nil) do
    OvcsAttachDiag.log(
      "OVCS_CAN\t#{network}\t0x#{String.upcase(id_hex)}\t\t#{String.trim(data_hex)}"
    )
  end

  defp emit_frame(network, id_hex, byte_number, raw_data, data_hex, spec) do
    frame = %Cantastic.Frame{
      id: String.to_integer(id_hex, 16),
      name: spec.name,
      network_name: String.to_atom(network),
      byte_number: byte_number,
      raw_data: raw_data,
      signals: %{}
    }

    raw = String.trim(data_hex)

    signals =
      try do
        {:ok, interpreted} = Cantastic.Frame.interpret(frame, spec)

        interpreted.signals
        |> Enum.map(fn {name, signal} -> "#{name}=#{inspect(signal.value)}" end)
        |> Enum.join(" ")
      rescue
        _ -> ""
      catch
        _, _ -> ""
      end

    OvcsAttachDiag.log("OVCS_CAN\t#{network}\t#{spec.name}\t#{signals}\t#{raw}")
  end
end

OvcsAttachMonitor.start()
Process.sleep(:infinity)
"##;

/// Below `MAX_CANON`, past which an SSH PTY in canonical mode truncates a line.
const CHUNK_BYTES: usize = 1024;

/// Wrap a multi-line Elixir snippet so it reaches the remote IEx as short
/// input lines: the base64 payload is appended to an IEx variable in
/// chunks, then evaluated; each line returns `:ok`, which the readers drop
/// along with the echoed `iex(` prompts.
fn wrap_snippet(snippet: &str, channel: &str) -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let encoded = STANDARD.encode(snippet.as_bytes());
    let variable = format!("ovcs_attach_{}", channel);
    let mut input = String::with_capacity(encoded.len() + 256);
    input.push_str(&format!("{variable} = \"\"; :ok\n"));
    for chunk in encoded.as_bytes().chunks(CHUNK_BYTES) {
        let chunk_text = std::str::from_utf8(chunk).expect("base64 alphabet is ASCII");
        input.push_str(&format!(
            "{variable} = {variable} <> Base.decode64!(\"{chunk_text}\"); :ok\n"
        ));
    }
    input.push_str(&format!("Code.eval_string({variable})\n"));
    input
}

fn attach_local(nodes: Vec<(String, String)>) -> Result<()> {
    erlang_cookie::ensure()?;
    let (tx, rx) = mpsc::channel::<Message>();
    let mut handles: Vec<NodeHandle> = Vec::new();
    let pid = std::process::id();
    let shutdown = Arc::new(AtomicBool::new(false));
    let mut supervisors: Vec<thread::JoinHandle<()>> = Vec::new();

    for (index, (label, full_node)) in nodes.iter().enumerate() {
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
        sub(&format!("supervisor for {} ({})", label, full_node));

        let supervisor_tx = tx.clone();
        let supervisor_label = label.clone();
        let supervisor_node = full_node.clone();
        let supervisor_shutdown = shutdown.clone();
        let supervisor = thread::spawn(move || {
            run_local_node(
                supervisor_label,
                supervisor_node,
                pid,
                index,
                stdin_rx,
                supervisor_tx,
                supervisor_shutdown,
            );
        });
        supervisors.push(supervisor);

        handles.push(NodeHandle {
            name: label.clone(),
            stdin: stdin_tx,
        });
    }

    step("attached — handing off to TUI. (Ctrl-C or q to quit)");

    let ui_result = run_ui::run(rx, handles);

    shutdown.store(true, Ordering::Relaxed);
    for supervisor in supervisors {
        let _ = supervisor.join();
    }

    ui_result
}

/// Per-node supervisor. Owns one `Trio` of remsh children at a time; when
/// one of them dies it kills the others, reports `NodeDown`, and retries
/// with exponential backoff until `shutdown` is set.
fn run_local_node(
    label: String,
    full_node: String,
    pid: u32,
    index: usize,
    stdin_rx: Receiver<String>,
    tx: Sender<Message>,
    shutdown: Arc<AtomicBool>,
) {
    let mut backoff = INITIAL_BACKOFF;
    let mut attempt: u64 = 0;

    while !shutdown.load(Ordering::Relaxed) {
        // `iex --remsh` outlives its remote node, so epmd is what tells
        // whether the BEAM is up.
        if !wait_until_registered(&full_node, &shutdown) {
            break;
        }

        match spawn_trio(&label, &full_node, pid, index, attempt, &tx) {
            Ok(trio) => {
                // Fresh session: discard any input queued while down.
                while stdin_rx.try_recv().is_ok() {}

                let _ = tx.send(Message::NodeUp(label.clone()));
                let session_elapsed = run_one_session(trio, &full_node, &stdin_rx, &shutdown);
                if session_elapsed > HEALTHY_SESSION {
                    backoff = INITIAL_BACKOFF;
                }
                let _ = tx.send(Message::NodeDown(label.clone()));
            }
            Err(error) => {
                let _ = tx.send(Message::Log {
                    node: label.clone(),
                    line: format!("[ovcs] spawn failed: {:#}", error),
                });
            }
        }

        if shutdown.load(Ordering::Relaxed) {
            break;
        }

        attempt += 1;
        let _ = tx.send(Message::Log {
            node: label.clone(),
            line: format!("[ovcs] reconnecting in {}s…", backoff.as_secs()),
        });
        interruptible_sleep(backoff, &shutdown);
        backoff = next_backoff(backoff);
    }
}

/// Pump stdin into the trio's shell and watch for child death or the remote
/// node disappearing from epmd. Returns the total session duration so the
/// caller can decide whether to reset the reconnect backoff.
fn run_one_session(
    mut trio: Trio,
    full_node: &str,
    stdin_rx: &Receiver<String>,
    shutdown: &Arc<AtomicBool>,
) -> Duration {
    let started = Instant::now();
    let mut last_epmd = Instant::now();

    loop {
        if shutdown.load(Ordering::Relaxed) {
            break;
        }
        match stdin_rx.recv_timeout(STDIN_RECV_TIMEOUT) {
            Ok(line) => {
                if trio.shell_stdin.write_all(line.as_bytes()).is_err() {
                    break;
                }
                let _ = trio.shell_stdin.flush();
            }
            Err(RecvTimeoutError::Timeout) => {
                if trio.any_dead() {
                    break;
                }
                if last_epmd.elapsed() >= EPMD_RECHECK_INTERVAL {
                    last_epmd = Instant::now();
                    if !node_registered(full_node) {
                        break;
                    }
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    trio.kill_all();
    started.elapsed()
}

/// A connected trio of remsh subprocesses plus the shell's stdin handle.
struct Trio {
    log_child: Child,
    shell_child: Child,
    mon_child: Child,
    shell_stdin: ChildStdin,
    // Held open, never written: EOF on a remsh's stdin halts the remote
    // node. They close only after `kill_all` has SIGKILLed the children.
    _log_stdin: ChildStdin,
    _mon_stdin: ChildStdin,
}

impl Trio {
    fn any_dead(&mut self) -> bool {
        [
            &mut self.log_child,
            &mut self.shell_child,
            &mut self.mon_child,
        ]
        .into_iter()
        .any(|child| matches!(child.try_wait(), Ok(Some(_))))
    }

    fn kill_all(&mut self) {
        for child in [
            &mut self.log_child,
            &mut self.shell_child,
            &mut self.mon_child,
        ] {
            // The whole group (stdbuf → iex → beam): an orphaned remsh BEAM
            // would see EOF and halt the remote node. The pid is the pgid.
            unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
            let _ = child.wait();
        }
    }
}

/// Build a fresh `Trio` for one node: three `iex --remsh` subprocesses,
/// each with stdout and stderr readers feeding the TUI. `attempt` is in
/// each sname so a reconnect doesn't collide with a lingering epmd entry.
fn spawn_trio(
    label: &str,
    full_node: &str,
    pid: u32,
    index: usize,
    attempt: u64,
    tx: &Sender<Message>,
) -> Result<Trio> {
    let log_sname = format!("ovcs_attach_log_{}_{}_{}", pid, index, attempt);
    let mut log_child =
        spawn_remsh(&log_sname, full_node).with_context(|| format!("log remsh for {}", label))?;
    let log_stdout = log_child.stdout.take().unwrap();
    let log_stderr = log_child.stderr.take().unwrap();
    let mut log_stdin = log_child.stdin.take().unwrap();
    let _ = log_stdin.write_all(wrap_snippet(LOG_INIT_SNIPPET, "log").as_bytes());
    let _ = log_stdin.flush();
    spawn_reader(log_stdout, label, tx, forward_log);
    spawn_reader(log_stderr, label, tx, forward_log);

    let shell_sname = format!("ovcs_attach_sh_{}_{}_{}", pid, index, attempt);
    let mut shell_child = spawn_remsh(&shell_sname, full_node)
        .with_context(|| format!("shell remsh for {}", label))?;
    let shell_stdout = shell_child.stdout.take().unwrap();
    let shell_stderr = shell_child.stderr.take().unwrap();
    let shell_stdin = shell_child.stdin.take().unwrap();
    spawn_reader(shell_stdout, label, tx, forward_shell);
    spawn_reader(shell_stderr, label, tx, forward_shell);

    let mon_sname = format!("ovcs_attach_mon_{}_{}_{}", pid, index, attempt);
    let mut mon_child = spawn_remsh(&mon_sname, full_node)
        .with_context(|| format!("monitor remsh for {}", label))?;
    let mon_stdout = mon_child.stdout.take().unwrap();
    let mon_stderr = mon_child.stderr.take().unwrap();
    let mut mon_stdin = mon_child.stdin.take().unwrap();
    let _ = mon_stdin.write_all(wrap_snippet(MONITOR_SNIPPET, "mon").as_bytes());
    let _ = mon_stdin.flush();
    spawn_reader(mon_stdout, label, tx, forward_monitor);
    spawn_reader(mon_stderr, label, tx, forward_monitor);

    Ok(Trio {
        log_child,
        shell_child,
        mon_child,
        shell_stdin,
        _log_stdin: log_stdin,
        _mon_stdin: mon_stdin,
    })
}

fn spawn_reader<R, F>(reader: R, label: &str, tx: &Sender<Message>, forward: F)
where
    R: std::io::Read + Send + 'static,
    F: Fn(R, &str, &Sender<Message>) + Send + 'static,
{
    let tx = tx.clone();
    let label = label.to_string();
    thread::spawn(move || forward(reader, &label, &tx));
}

fn interruptible_sleep(total: Duration, shutdown: &AtomicBool) {
    let start = Instant::now();
    while start.elapsed() < total {
        if shutdown.load(Ordering::Relaxed) {
            return;
        }
        thread::sleep(SHUTDOWN_POLL);
    }
}

fn next_backoff(current: Duration) -> Duration {
    (current.saturating_mul(2)).min(BACKOFF_CAP)
}

/// Whether the sname of `full_node` (`sname@hostname`) is listed by
/// `epmd -names` (`name ovcs1-vms at port 35123`). An unanswerable
/// question counts as registered, so it can't cause a reconnect storm.
fn node_registered(full_node: &str) -> bool {
    let Some((sname, _)) = full_node.split_once('@') else {
        return true;
    };
    let Ok(epmd) = Command::new("epmd").arg("-names").output() else {
        // A dead remsh still ends the session.
        return true;
    };
    let stdout = String::from_utf8_lossy(&epmd.stdout);
    epmd_snames(&stdout).contains(&sname)
}

/// Poll epmd until `full_node` is registered, sleeping briefly between
/// checks. Returns `false` if `shutdown` flipped before the node came
/// up — the caller should exit in that case.
fn wait_until_registered(full_node: &str, shutdown: &AtomicBool) -> bool {
    loop {
        if shutdown.load(Ordering::Relaxed) {
            return false;
        }
        if node_registered(full_node) {
            return true;
        }
        thread::sleep(EPMD_REGISTER_POLL);
    }
}

fn spawn_remsh(local_sname: &str, full_node: &str) -> Result<std::process::Child> {
    // `-hidden` keeps the remsh out of the vehicle's cluster: as a full
    // member, each connect and disconnect makes `:global` report
    // overlapping partitions.
    Command::new("stdbuf")
        .args([
            "-oL",
            "-eL",
            "iex",
            "--erl",
            "-hidden",
            "--sname",
            local_sname,
            "--remsh",
            full_node,
        ])
        // Its own process group, for `kill_all`.
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(Into::into)
}

// ---------- deployed transport: SSH via russh ----------

fn attach_deployed(vehicle: &vehicles::Vehicle, devices: Vec<(String, String)>) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Message>();
    let mut handles = Vec::new();
    let shutdown = Arc::new(AtomicBool::new(false));
    let aborts: Arc<Mutex<Vec<tokio::task::AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));

    // One dedicated tokio runtime thread for all SSH sessions.
    let (rt_tx, rt_rx) = mpsc::channel::<DeployedJob>();
    let tx_for_rt = tx.clone();
    let shutdown_for_rt = shutdown.clone();
    let aborts_for_rt = aborts.clone();
    let rt_thread = thread::spawn(move || {
        run_ssh_runtime(rt_rx, tx_for_rt, shutdown_for_rt, aborts_for_rt);
    });

    for (label, host) in devices {
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
        let pinned_host_keys = pinned_host_keys(vehicle, &label)?;
        rt_tx
            .send(DeployedJob {
                label: label.clone(),
                host: host.clone(),
                pinned_host_keys,
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

    let ui_result = run_ui::run(rx, handles);

    // Unblock every supervisor task on any await point (connect, sleep,
    // select!) so they drop before the runtime thread joins.
    shutdown.store(true, Ordering::Relaxed);
    for abort in aborts.lock().unwrap().drain(..) {
        abort.abort();
    }
    let _ = rt_thread.join();

    ui_result
}

struct DeployedJob {
    label: String,
    host: String,
    pinned_host_keys: Vec<PublicKey>,
    stdin_rx: Receiver<String>,
}

fn run_ssh_runtime(
    jobs: Receiver<DeployedJob>,
    tx: Sender<Message>,
    shutdown: Arc<AtomicBool>,
    aborts: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            let _ = tx.send(Message::Log {
                node: "ovcs".into(),
                line: format!("failed to start tokio runtime: {}", error),
            });
            return;
        }
    };

    runtime.block_on(async move {
        let mut tasks = Vec::new();
        while let Ok(job) = jobs.recv() {
            let tx = tx.clone();
            let shutdown = shutdown.clone();
            let task = tokio::spawn(async move {
                run_device_supervisor(
                    job.label,
                    job.host,
                    job.pinned_host_keys,
                    job.stdin_rx,
                    tx,
                    shutdown,
                )
                .await;
            });
            aborts.lock().unwrap().push(task.abort_handle());
            tasks.push(task);
        }
        for task in tasks {
            let _ = task.await;
        }
    });
}

/// Persistent per-device loop: connect, run the session, and on any
/// disconnect (a clean remote EOF included) retry with exponential backoff
/// until `shutdown` is set. The caller aborts in-flight awaits on exit.
async fn run_device_supervisor(
    label: String,
    host: String,
    pinned_host_keys: Vec<PublicKey>,
    stdin_rx: Receiver<String>,
    tx: Sender<Message>,
    shutdown: Arc<AtomicBool>,
) {
    // Each session gets a fresh async channel behind this slot; while the
    // node is down the slot is `None` and typed input is dropped.
    let active: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedSender<String>>>> =
        Arc::new(Mutex::new(None));
    let active_bridge = active.clone();
    std::thread::spawn(move || {
        while let Ok(line) = stdin_rx.recv() {
            if let Some(session_input) = active_bridge.lock().unwrap().as_ref() {
                let _ = session_input.send(line);
            }
        }
    });

    let mut backoff = INITIAL_BACKOFF;

    while !shutdown.load(Ordering::Relaxed) {
        let (input_tx, input_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        *active.lock().unwrap() = Some(input_tx);

        let started = tokio::time::Instant::now();
        let session = run_device_once(&label, &host, &pinned_host_keys, input_rx, &tx).await;
        *active.lock().unwrap() = None;

        if let Err(error) = session {
            let _ = tx.send(Message::Log {
                node: label.clone(),
                line: format!("[ovcs] session: {:#}", error),
            });
        } else if started.elapsed() > HEALTHY_SESSION {
            backoff = INITIAL_BACKOFF;
        }
        let _ = tx.send(Message::NodeDown(label.clone()));

        if shutdown.load(Ordering::Relaxed) {
            break;
        }

        let _ = tx.send(Message::Log {
            node: label.clone(),
            line: format!("[ovcs] reconnecting in {}s…", backoff.as_secs()),
        });
        interruptible_sleep_async(backoff, &shutdown).await;
        backoff = next_backoff(backoff);
    }
}

async fn interruptible_sleep_async(total: Duration, shutdown: &AtomicBool) {
    let start = tokio::time::Instant::now();
    while start.elapsed() < total {
        if shutdown.load(Ordering::Relaxed) {
            return;
        }
        tokio::time::sleep(SHUTDOWN_POLL).await;
    }
}

/// One SSH session for a device: opens the three channels, announces
/// `NodeUp`, and pumps data until a channel ends or the remote dies.
async fn run_device_once(
    label: &str,
    host: &str,
    pinned_host_keys: &[PublicKey],
    mut input_rx: tokio::sync::mpsc::UnboundedReceiver<String>,
    tx: &Sender<Message>,
) -> Result<()> {
    use russh::ChannelMsg;

    let mut handle = connect_ssh(host, pinned_host_keys).await?;
    let (mut log_channel, mut shell_channel, mut mon_channel) =
        open_ssh_channels(&mut handle).await?;

    let _ = tx.send(Message::NodeUp(label.to_string()));

    let label_owned = label.to_string();
    let tx_owned = tx.clone();
    // Same readiness gate as the local `forward_log`.
    let mut log_ready = false;
    let (mut log_out, mut log_err) = (LineBuffer::default(), LineBuffer::default());
    let (mut mon_out, mut mon_err) = (LineBuffer::default(), LineBuffer::default());
    let forward_log_line = |line: String, ready: &mut bool, tx: &Sender<Message>| {
        if !*ready {
            if strip_ansi(&line).contains(LOG_READY_MARKER) {
                *ready = true;
            }
            return;
        }
        if is_iex_noise(&line) {
            return;
        }
        let _ = tx.send(Message::Log {
            node: label_owned.clone(),
            line,
        });
    };
    loop {
        tokio::select! {
            message = log_channel.wait() => {
                match message {
                    Some(ChannelMsg::Data { data }) => {
                        for line in log_out.feed(&data) {
                            forward_log_line(line, &mut log_ready, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in log_err.feed(&data) {
                            forward_log_line(line, &mut log_ready, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) => break,
                    Some(_) => {}
                    None => break,
                }
            }
            message = shell_channel.wait() => {
                match message {
                    Some(ChannelMsg::Data { data }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Message::Shell {
                                node: label_owned.clone(),
                                line,
                            });
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in split_lines(&data) {
                            let _ = tx_owned.send(Message::Shell {
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
            message = mon_channel.wait() => {
                match message {
                    Some(ChannelMsg::Data { data }) => {
                        for line in mon_out.feed(&data) {
                            let _ = dispatch_monitor_line(&line, &label_owned, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in mon_err.feed(&data) {
                            let _ = dispatch_monitor_line(&line, &label_owned, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) => break,
                    Some(_) => {}
                    None => break,
                }
            }
            input = input_rx.recv() => {
                match input {
                    Some(line) => {
                        if shell_channel.data(line.as_bytes()).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
        }
    }

    let _ = log_channel.close().await;
    let _ = shell_channel.close().await;
    let _ = mon_channel.close().await;
    Ok(())
}

/// The role's public host keys from `./ovcs host-keys`, empty when the
/// vehicle has none for it.
fn pinned_host_keys(vehicle: &vehicles::Vehicle, label: &str) -> Result<Vec<PublicKey>> {
    let dir = vehicle_host_keys::role_dir(vehicle, label);
    let mut keys = Vec::new();
    for kind in ["ed25519", "rsa"] {
        let path = dir.join(format!("ssh_host_{}_key.pub", kind));
        if path.exists() {
            keys.push(
                PublicKey::read_openssh_file(&path)
                    .with_context(|| format!("reading {}", path.display()))?,
            );
        }
    }
    Ok(keys)
}

/// Accepts the server only if its host key is one of the role's pinned
/// keys or, when none are pinned, if `~/.ssh/known_hosts` lists it for the
/// host. The TUI cannot prompt, so anything else is refused.
struct VerifiedHostKey {
    host: String,
    pinned: Vec<PublicKey>,
}

impl VerifiedHostKey {
    fn accepts(&self, key: &PublicKey) -> bool {
        if self.pinned.is_empty() {
            russh::keys::check_known_hosts(&self.host, 22, key).unwrap_or(false)
        } else {
            self.pinned
                .iter()
                .any(|pinned| pinned.key_data() == key.key_data())
        }
    }
}

impl russh::client::Handler for VerifiedHostKey {
    type Error = russh::Error;
    async fn check_server_key(&mut self, key: &PublicKey) -> Result<bool, Self::Error> {
        Ok(self.accepts(key))
    }
}

/// The usable public key from an agent identity, or `None` to skip it.
/// Certificates are skipped: they need `authenticate_openssh_cert`, and
/// vehicles do not use them.
fn agent_identity_public_key(
    identity: russh::keys::agent::AgentIdentity,
) -> Option<russh::keys::ssh_key::PublicKey> {
    match identity {
        russh::keys::agent::AgentIdentity::PublicKey { key, .. } => Some(key),
        russh::keys::agent::AgentIdentity::Certificate { .. } => None,
    }
}

/// The hash algorithm to sign with for `key`.
///
/// nerves_ssh rejects SHA-1 `ssh-rsa` signatures, which is what russh
/// signs with when the hash is `None`, so RSA keys carry the `rsa-sha2-*`
/// hash the server advertises, as OpenSSH does. Every other algorithm
/// (ed25519, ecdsa) has one signature scheme and must be left `None`.
fn signing_hash_for(
    key: &russh::keys::ssh_key::PublicKey,
    rsa_hash: Option<russh::keys::ssh_key::HashAlg>,
) -> Option<russh::keys::ssh_key::HashAlg> {
    match key.algorithm() {
        russh::keys::ssh_key::Algorithm::Rsa { .. } => rsa_hash,
        _ => None,
    }
}

/// Connect and authenticate an SSH session against `host` with the
/// user's ssh-agent identities.
async fn connect_ssh(
    host: &str,
    pinned_host_keys: &[PublicKey],
) -> Result<russh::client::Handle<VerifiedHostKey>> {
    let config = Arc::new(russh::client::Config {
        keepalive_interval: Some(KEEPALIVE_INTERVAL),
        ..Default::default()
    });
    let verifier = VerifiedHostKey {
        host: host.to_string(),
        pinned: pinned_host_keys.to_vec(),
    };
    let mut handle = match tokio::time::timeout(
        CONNECT_TIMEOUT,
        russh::client::connect(config, (host, 22), verifier),
    )
    .await
    .with_context(|| format!("connect {} timed out after {:?}", host, CONNECT_TIMEOUT))?
    {
        Ok(handle) => handle,
        Err(russh::Error::UnknownKey) if pinned_host_keys.is_empty() => bail!(
            "{} is not in ~/.ssh/known_hosts and the vehicle pins no host key for it; \
             run `./ovcs connect` once to accept its key",
            host
        ),
        Err(russh::Error::UnknownKey) => bail!(
            "{}'s host key does not match the vehicle's pinned keys; \
             reflash it or update them with `./ovcs host-keys import`",
            host
        ),
        Err(error) => return Err(error).with_context(|| format!("connect {} failed", host)),
    };

    let mut agent = connect_ssh_agent(host).await?;
    let identities = agent
        .request_identities()
        .await
        .context("ssh-agent identities request failed")?;
    if identities.is_empty() {
        bail!(
            "ssh-agent has no identities loaded for {}@{} — `ssh-add -l` to check, \
             or point SSH_AUTH_SOCK at the agent your `ssh` uses (e.g. 1Password)",
            SSH_USER,
            host
        );
    }
    // See `signing_hash_for`; SHA-256 when the server advertises none.
    let rsa_hash = handle
        .best_supported_rsa_hash()
        .await
        .ok()
        .flatten()
        .unwrap_or(Some(russh::keys::ssh_key::HashAlg::Sha256));
    for identity in identities {
        let Some(key) = agent_identity_public_key(identity) else {
            continue;
        };
        let hash_alg = signing_hash_for(&key, rsa_hash);
        let auth = handle
            .authenticate_publickey_with(SSH_USER, key, hash_alg, &mut agent)
            .await?;
        if auth.success() {
            return Ok(handle);
        }
    }
    bail!("ssh auth failed for {}@{}", SSH_USER, host);
}

/// Connect to the ssh-agent that plain `ssh` would use for `host`: the
/// `IdentityAgent` that `ssh -G <host>` resolves (e.g. 1Password's), or
/// `$SSH_AUTH_SOCK` when none is set.
async fn connect_ssh_agent(
    host: &str,
) -> Result<russh::keys::agent::client::AgentClient<tokio::net::UnixStream>> {
    if let Some(path) = resolve_identity_agent(host) {
        return russh::keys::agent::client::AgentClient::connect_uds(&path)
            .await
            .with_context(|| format!("ssh-agent unreachable at {}", path.display()));
    }
    russh::keys::agent::client::AgentClient::connect_env()
        .await
        .context(
            "ssh-agent unreachable — is SSH_AUTH_SOCK set, or `IdentityAgent` in ~/.ssh/config?",
        )
}

/// Parse `ssh -G <host>`'s `identityagent` line. Returns `None` if the
/// directive is absent, set to `none`/`SSH_AUTH_SOCK`, or `ssh` itself
/// can't be invoked — the caller falls back to `$SSH_AUTH_SOCK`.
fn resolve_identity_agent(host: &str) -> Option<std::path::PathBuf> {
    let output = Command::new("ssh")
        .arg("-G")
        .arg(host)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let value = stdout.lines().find_map(|line| {
        let mut words = line.splitn(2, char::is_whitespace);
        match (words.next(), words.next()) {
            (Some(keyword), Some(argument)) if keyword.eq_ignore_ascii_case("identityagent") => {
                Some(argument.trim())
            }
            _ => None,
        }
    })?;
    if value.is_empty() || value.eq_ignore_ascii_case("none") || value == "SSH_AUTH_SOCK" {
        return None;
    }
    let expanded = if let Some(rest) = value.strip_prefix("~/") {
        std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(rest))?
    } else {
        std::path::PathBuf::from(value)
    };
    Some(expanded)
}

/// Open the three session-shell channels used by `run_device_once`, in
/// `(log, shell, monitor)` order:
///
/// - log: `LOG_INIT_SNIPPET`, feeding the log pane.
/// - shell: interactive IEx.
/// - monitor: `MONITOR_SNIPPET`, whose tagged `OVCS_BUS` / `OVCS_CAN`
///   lines feed the bus and CAN panes.
async fn open_ssh_channels(
    handle: &mut russh::client::Handle<VerifiedHostKey>,
) -> Result<(
    russh::Channel<russh::client::Msg>,
    russh::Channel<russh::client::Msg>,
    russh::Channel<russh::client::Msg>,
)> {
    let log_channel = handle.channel_open_session().await?;
    log_channel
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    log_channel.request_shell(false).await?;
    log_channel
        .data(wrap_snippet(LOG_INIT_SNIPPET, "log").as_bytes())
        .await?;

    let shell_channel = handle.channel_open_session().await?;
    shell_channel
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    shell_channel.request_shell(false).await?;

    let mon_channel = handle.channel_open_session().await?;
    mon_channel
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    mon_channel.request_shell(false).await?;
    mon_channel
        .data(wrap_snippet(MONITOR_SNIPPET, "mon").as_bytes())
        .await?;

    Ok((log_channel, shell_channel, mon_channel))
}

/// One SSH stream's bytes, cut into lines even when a line or a UTF-8
/// character straddles two packets.
#[derive(Default)]
struct LineBuffer {
    pending: Vec<u8>,
}

impl LineBuffer {
    /// Appends `bytes` and returns the non-blank lines they complete.
    fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(bytes);
        let Some(last_newline) = self.pending.iter().rposition(|&byte| byte == b'\n') else {
            return Vec::new();
        };
        let complete: Vec<u8> = self.pending.drain(..=last_newline).collect();
        split_lines(&complete)
    }
}

fn split_lines(bytes: &[u8]) -> Vec<String> {
    let output = String::from_utf8_lossy(bytes);
    output
        .split('\n')
        .map(|line| line.trim_end_matches('\r').to_string())
        // A blank Logger line may still carry colour resets.
        .filter(|line| !strip_ansi(line).trim().is_empty())
        .collect()
}

// ---------- local stdio → Message dispatch ----------

/// Read `reader` line by line, calling `handle_line(line, node, tx)` on
/// each until it returns `false` (the TUI channel is gone).
fn forward_stream<Reader, Handle>(
    reader: Reader,
    node: &str,
    tx: &Sender<Message>,
    handle_line: Handle,
) where
    Reader: std::io::Read + Send + 'static,
    Handle: Fn(&str, &str, &Sender<Message>) -> bool,
{
    let buffered = BufReader::new(reader);
    for line in lossy_lines(buffered) {
        if !handle_line(&line, node, tx) {
            break;
        }
    }
}

fn forward_log<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Message>) {
    let mut ready = false;
    let buffered = BufReader::new(reader);
    for line in lossy_lines(buffered) {
        if !ready {
            if strip_ansi(&line).contains(LOG_READY_MARKER) {
                ready = true;
            }
            continue;
        }
        if is_iex_noise(&line) {
            continue;
        }
        if tx
            .send(Message::Log {
                node: node.to_string(),
                line,
            })
            .is_err()
        {
            break;
        }
    }
}

/// IEx output on the log channel rather than log events: prompts, the
/// banner, the snippet's return values and stack frames. The log channel
/// is an IEx session because `RingLogger.attach()` binds to the calling,
/// long-lived process.
pub fn is_iex_noise(line: &str) -> bool {
    let stripped = strip_ansi(line);
    let trimmed = stripped.trim();
    const NOISE_PREFIXES: &[&str] = &[
        "iex(",               // interactive prompt
        "iex:",               // stacktrace frame (file:line) from iex eval
        "...(",               // continuation prompt
        "Erlang/OTP",         // erlang banner
        "Interactive Elixir", // iex banner
        ":ok",                // the init snippet's return value
        "Compiling ",         // mix recompile chatter under --remsh
        "** (",               // leading error header from IEx evaluation
        "Code.eval_string(",  // the snippet wrapper, echoed by IEx
    ];
    if trimmed.is_empty()
        || NOISE_PREFIXES
            .iter()
            .any(|prefix| trimmed.starts_with(prefix))
    {
        return true;
    }
    // Stack frames: `(ring_logger 0.11.5) RingLogger.attach()`.
    if let Some(inside) = trimmed.strip_prefix('(') {
        if let Some((library, _)) = inside.split_once(')') {
            if is_library_tag(library) {
                return true;
            }
        }
    }
    false
}

/// Heuristic for `(name 1.2.3)` / `(name)` stack frame library tags:
/// a lowercase identifier, optionally followed by a version.
fn is_library_tag(tag: &str) -> bool {
    let Some(name) = tag.split_whitespace().next() else {
        return false;
    };
    name.chars().all(|character| {
        character.is_ascii_lowercase() || character.is_ascii_digit() || character == '_'
    })
}

fn forward_shell<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Message>) {
    forward_stream(reader, node, tx, dispatch_shell_line);
}

fn dispatch_shell_line(line: &str, node: &str, tx: &Sender<Message>) -> bool {
    tx.send(Message::Shell {
        node: node.to_string(),
        line: line.to_string(),
    })
    .is_ok()
}

/// Reader thread for the monitor remsh's output: `MONITOR_SNIPPET`'s tagged
/// lines; anything else (IEx banner, return values) is dropped.
fn forward_monitor<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Message>) {
    forward_stream(reader, node, tx, dispatch_monitor_line);
}

/// Parse one monitor line. Returns `false` if the channel is gone and the
/// caller should stop reading.
fn dispatch_monitor_line(raw: &str, node: &str, tx: &Sender<Message>) -> bool {
    let stripped = strip_ansi(raw);
    let line = stripped.trim();
    if line.is_empty() {
        return true;
    }
    // OVCS_CAN has four fields after the tag, OVCS_BUS three.
    let mut parts = line.splitn(5, '\t');
    let tag = parts.next().unwrap_or("");
    match tag {
        "OVCS_BUS" => {
            let source = parts.next().unwrap_or("").to_string();
            let name = parts.next().unwrap_or("").to_string();
            let value = parts.next().unwrap_or("").to_string();
            tx.send(Message::Bus {
                node: node.to_string(),
                source,
                name,
                value,
            })
            .is_ok()
        }
        "OVCS_CAN" => {
            let network = parts.next().unwrap_or("").to_string();
            let frame = parts.next().unwrap_or("").to_string();
            let signals = parts.next().unwrap_or("").to_string();
            let raw = parts.next().unwrap_or("").to_string();
            tx.send(Message::CanFrame {
                node: node.to_string(),
                network,
                frame,
                signals,
                raw,
            })
            .is_ok()
        }
        _ => true, // drop iex banner / return values / stray noise
    }
}

#[cfg(test)]
mod tests {
    use super::{
        agent_identity_public_key, epmd_snames, local_beams_for, next_backoff, signing_hash_for,
        wrap_snippet, LineBuffer, VerifiedHostKey, BACKOFF_CAP, INITIAL_BACKOFF, LOG_INIT_SNIPPET,
        LOG_READY_MARKER, MONITOR_SNIPPET,
    };
    use russh::keys::agent::AgentIdentity;
    use russh::keys::ssh_key::{Certificate, HashAlg, PublicKey};
    use std::time::Duration;

    // Real keys, generated with ssh-keygen: `signing_hash_for` treats RSA
    // and ed25519 differently, and an agent can hold a certificate.
    const RSA_PUB: &str = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDTWmLO2CvI4j2ezTng0rokboMmTWIOlPR+0/UpKbcOnjcXdgdhJ/8VAnx0FDq+dSVFncrKOa8iAbMVwt/tKvCP1AIwAvjJBN69lI2/4lfnjqbj5g17MlRVptbvV6w2zmDcPwylfYRIrHpy/fFRlS2C5vVOkSTbTDHRKecb+xudXxgHewhniWND5CXV2v7/Cr9IzwhxZdkVQZfZD3+m6KBoNgLcTQc8Xaz+3T8zVLHiDC+xO6TTwy7EZl4NbCGiTd3kq/mwfWKmUP7eTU03lm27rF9VeKtWML/+Nz84rDwfEAJt9If2WmROZvfo4biI3eDhv/nJeTxdgBNw6aMrl3wd rsa-test";
    const ED25519_PUB: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF/eYwj/hUv77wpjCuHT3q+GEw8d/vaNbSs69AK1hQSz ed-test";
    const ED25519_CERT: &str = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIBMKEKd2q57TWpdbaAz8TByhepJvF3RqwGLD58ghFnTrAAAAIF/eYwj/hUv77wpjCuHT3q+GEw8d/vaNbSs69AK1hQSzAAAAAAAAAAAAAAABAAAAB3Rlc3QtaWQAAAAIAAAABG92Y3MAAAAAapm5JAAAAABseZtkAAAAAAAAAIIAAAAVcGVybWl0LVgxMS1mb3J3YXJkaW5nAAAAAAAAABdwZXJtaXQtYWdlbnQtZm9yd2FyZGluZwAAAAAAAAAWcGVybWl0LXBvcnQtZm9yd2FyZGluZwAAAAAAAAAKcGVybWl0LXB0eQAAAAAAAAAOcGVybWl0LXVzZXItcmMAAAAAAAAAAAAAADMAAAALc3NoLWVkMjU1MTkAAAAgw2IjtmxriCcNYGvbIdJBRL1v4jGnPaMvWPRbnqBSqlcAAABTAAAAC3NzaC1lZDI1NTE5AAAAQMdGqW/z5BmuU1I/y5eJkU1kxoJ9rJyjtTrfxoC5igz3Mo40+6x4w++dlWdqwBRNTOY0p6X1jqSxBWP4bORsZAs= ed-test";

    fn rsa() -> PublicKey {
        PublicKey::from_openssh(RSA_PUB).expect("parse rsa test key")
    }

    fn ed25519() -> PublicKey {
        PublicKey::from_openssh(ED25519_PUB).expect("parse ed25519 test key")
    }

    #[test]
    fn rsa_keys_sign_with_the_negotiated_hash() {
        // Whatever the server advertised is passed straight through.
        assert_eq!(
            signing_hash_for(&rsa(), Some(HashAlg::Sha256)),
            Some(HashAlg::Sha256)
        );
        assert_eq!(
            signing_hash_for(&rsa(), Some(HashAlg::Sha512)),
            Some(HashAlg::Sha512)
        );
    }

    #[test]
    fn non_rsa_keys_never_carry_a_hash() {
        // Even when the server advertised an RSA hash for other keys.
        assert_eq!(signing_hash_for(&ed25519(), Some(HashAlg::Sha256)), None);
        assert_eq!(signing_hash_for(&ed25519(), None), None);
    }

    #[test]
    fn a_public_key_identity_is_usable() {
        let key = ed25519();
        let identity = AgentIdentity::PublicKey {
            key: key.clone(),
            comment: "ed-test".to_string(),
        };
        assert_eq!(agent_identity_public_key(identity), Some(key));
    }

    #[test]
    fn a_certificate_identity_is_skipped() {
        // Certificates need authenticate_openssh_cert, not
        // authenticate_publickey_with.
        let certificate = Certificate::from_openssh(ED25519_CERT).expect("parse test certificate");
        let identity = AgentIdentity::Certificate {
            certificate,
            comment: "ed-test".to_string(),
        };
        assert_eq!(agent_identity_public_key(identity), None);
    }

    #[test]
    fn a_line_split_across_packets_comes_out_whole() {
        let mut buffer = LineBuffer::default();
        assert!(buffer.feed(b"OVCS_CAN\tmisc\t0x1").is_empty());
        assert_eq!(
            buffer.feed(b"23\tframe\r\nOVCS_LOG_"),
            vec!["OVCS_CAN\tmisc\t0x123\tframe"]
        );
        assert_eq!(buffer.feed(b"READY\n"), vec!["OVCS_LOG_READY"]);
    }

    #[test]
    fn a_character_split_across_packets_is_not_mangled() {
        let mut buffer = LineBuffer::default();
        let bytes = "temp 21 \u{b0}C\n".as_bytes();
        let split = bytes.len() - 3;
        assert!(buffer.feed(&bytes[..split]).is_empty());
        assert_eq!(buffer.feed(&bytes[split..]), vec!["temp 21 \u{b0}C"]);
    }

    #[test]
    fn blank_lines_are_dropped() {
        let mut buffer = LineBuffer::default();
        assert_eq!(buffer.feed(b"one\n\n\x1b[0m\ntwo\n"), vec!["one", "two"]);
    }

    const OTHER_ED25519_PUB: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtxw/nkOAcL+gOJR7+N1dGpblfk3Wpxr3LAagzlArUG other-test";

    fn verifier(pinned: &[&str]) -> VerifiedHostKey {
        VerifiedHostKey {
            host: "vehicle-vms.local".to_string(),
            pinned: pinned
                .iter()
                .map(|key| PublicKey::from_openssh(key).unwrap())
                .collect(),
        }
    }

    #[test]
    fn a_pinned_host_key_is_accepted_whatever_its_comment() {
        let served =
            PublicKey::from_openssh(&ED25519_PUB.replace("ed-test", "root@device")).unwrap();
        assert!(verifier(&[RSA_PUB, ED25519_PUB]).accepts(&served));
    }

    #[test]
    fn a_host_key_that_is_not_pinned_is_refused() {
        let served = PublicKey::from_openssh(OTHER_ED25519_PUB).unwrap();
        assert!(!verifier(&[RSA_PUB, ED25519_PUB]).accepts(&served));
    }

    #[test]
    fn the_log_snippet_prints_the_ready_marker() {
        assert!(LOG_INIT_SNIPPET.contains(&format!("IO.puts(\"{LOG_READY_MARKER}\")")));
    }

    #[test]
    fn a_wrapped_snippet_fits_the_pty_line_limit() {
        for line in wrap_snippet(MONITOR_SNIPPET, "mon").lines() {
            assert!(line.len() < 4096, "{} bytes", line.len());
        }
    }

    const EPMD_NAMES: &str = "epmd: up and running on port 4369 with data:
name ovcs-mini-bridge-ros at port 40125
name ovcs-mini-vms at port 35123
name ovcs_attach_log_4242_0_0 at port 41001
";

    #[test]
    fn epmd_output_yields_every_registered_sname() {
        assert_eq!(
            epmd_snames(EPMD_NAMES),
            vec![
                "ovcs-mini-bridge-ros",
                "ovcs-mini-vms",
                "ovcs_attach_log_4242_0_0"
            ]
        );
        assert!(epmd_snames("epmd: Cannot connect to local epmd").is_empty());
    }

    #[test]
    fn local_beams_come_vms_first_then_infotainment_then_bridges() {
        let snames = [
            "ovcs-mini-bridge-ros",
            "ovcs-mini-infotainment",
            "ovcs-mini-bridge-radio-control",
            "ovcs-mini-vms",
            "ovcs_attach_sh_4242_0_0",
        ];
        assert_eq!(
            local_beams_for("ovcs_mini", &snames),
            vec![
                ("vms".to_string(), "ovcs-mini-vms"),
                ("infotainment".to_string(), "ovcs-mini-infotainment"),
                (
                    "bridge-radio-control".to_string(),
                    "ovcs-mini-bridge-radio-control"
                ),
                ("bridge-ros".to_string(), "ovcs-mini-bridge-ros"),
            ]
        );
    }

    #[test]
    fn another_vehicle_sharing_the_prefix_is_not_picked_up() {
        let snames = [
            "ovcs-mini-vms",
            "ovcs-mini-bridge-ros",
            "ovcs-vms",
            "ovcs-bridge-",
        ];
        assert_eq!(
            local_beams_for("ovcs", &snames),
            vec![("vms".to_string(), "ovcs-vms")]
        );
    }

    #[test]
    fn backoff_doubles_up_to_its_cap() {
        assert_eq!(next_backoff(INITIAL_BACKOFF), INITIAL_BACKOFF * 2);
        assert_eq!(next_backoff(BACKOFF_CAP), BACKOFF_CAP);
        assert_eq!(
            next_backoff(BACKOFF_CAP - Duration::from_millis(1)),
            BACKOFF_CAP
        );
        let mut backoff = INITIAL_BACKOFF;
        for _ in 0..64 {
            backoff = next_backoff(backoff);
        }
        assert_eq!(backoff, BACKOFF_CAP);
    }
}
