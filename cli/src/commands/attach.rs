use anyhow::{anyhow, bail, Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::ansi::strip_ansi;
use crate::commands::run_ui::{self, Msg, NodeHandle};
use crate::resolve_args::resolve_vehicle;
use crate::ui::{step, sub, sub_miss, sub_ok};
use crate::vehicles;

const SSH_USER: &str = "root";
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
/// Cap reconnect backoff at 10s — long enough to avoid hammering a node
/// that just crashed, short enough that the user doesn't wait forever when
/// the far side comes back.
const BACKOFF_CAP: Duration = Duration::from_secs(10);
/// Connect timeout on SSH sessions so we don't sit forever on an
/// unresponsive host and miss shutdown signals.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Initial reconnect backoff — bumps by `next_backoff` up to `BACKOFF_CAP`.
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
/// A session is considered "healthy" (and backoff is reset to
/// `INITIAL_BACKOFF`) only if it stayed up this long.
const HEALTHY_SESSION: Duration = Duration::from_secs(30);
/// How long `run_local_node` waits on stdin before polling for
/// child death / epmd deregistration / shutdown.
const STDIN_RECV_TIMEOUT: Duration = Duration::from_millis(200);
/// Interval between epmd re-checks while a local trio is up.
const EPMD_RECHECK_INTERVAL: Duration = Duration::from_secs(1);
/// Poll step used by `interruptible_sleep` / `interruptible_sleep_async`
/// — the tick at which the shutdown flag is checked during backoff.
const SHUTDOWN_POLL: Duration = Duration::from_millis(100);
/// Poll step used by `wait_until_registered` while waiting for a BEAM
/// to appear in epmd after boot / reconnect.
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
        attach_deployed(reachable)
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

    let mut out: Vec<(String, String)> = Vec::new();

    let vms_host = vehicles::host_for(&vehicle.dir, "vms");
    sub_ok(&format!("{:<14} {}", "vms", vms_host));
    out.push(("vms".into(), vms_host));

    match vehicles::has_infotainment(vehicle) {
        Ok(true) => {
            let host = vehicles::host_for(&vehicle.dir, "infotainment");
            sub_ok(&format!("{:<14} {}", "infotainment", host));
            out.push(("infotainment".into(), host));
        }
        Ok(false) => sub(&format!(
            "{:<14} skipped (vehicle declares no infotainment side)",
            "infotainment"
        )),
        Err(e) => sub(&format!(
            "{:<14} skipped ({})",
            "infotainment",
            e.to_string().lines().next().unwrap_or("probe failed")
        )),
    }

    match vehicles::bridge_firmwares(vehicle) {
        Ok(bridges) if bridges.is_empty() => {
            sub(&format!("{:<14} none declared", "bridges"));
        }
        Ok(bridges) => {
            let mut ids: Vec<_> = bridges.iter().collect();
            ids.sort_by(|a, b| a.0.cmp(b.0));
            for (id, fw) in ids {
                let label = format!("bridge-{}", id);
                if fw.target.contains("arduino") {
                    sub(&format!(
                        "{:<14} skipped (arduino target has no SSH)",
                        label
                    ));
                    continue;
                }
                let host = vehicles::host_for(&vehicle.dir, &format!("bridge-{}", id));
                sub_ok(&format!("{:<14} {}", label, host));
                out.push((label, host));
            }
        }
        Err(e) => sub(&format!(
            "{:<14} probe failed ({})",
            "bridges",
            e.to_string().lines().next().unwrap_or("?")
        )),
    }

    Ok(out)
}

fn probe_reachable(devices: &[(String, String)]) -> Vec<(String, String)> {
    // Probe each hostname in parallel so a slow/unreachable entry doesn't
    // stack with the others. Each worker streams its result through a
    // channel so we can print "reachable"/"unreachable" as soon as the
    // probe finishes rather than after the whole batch completes.
    let (tx, rx) = std::sync::mpsc::channel();

    let handles: Vec<_> = devices
        .iter()
        .cloned()
        .enumerate()
        .map(|(idx, (label, host))| {
            let tx = tx.clone();
            thread::spawn(move || {
                let ok = tcp_open(&host, 22, PROBE_TIMEOUT);
                let _ = tx.send((idx, label, host, ok));
            })
        })
        .collect();
    drop(tx);

    let mut results: Vec<Option<(String, String, bool)>> = vec![None; devices.len()];
    for (idx, label, host, ok) in rx {
        if ok {
            sub_ok(&format!("{:<14} reachable", label));
        } else {
            sub_miss(&format!("{:<14} no response", label));
        }
        results[idx] = Some((label, host, ok));
    }
    for h in handles {
        let _ = h.join();
    }

    results
        .into_iter()
        .flatten()
        .filter_map(|(label, host, ok)| if ok { Some((label, host)) } else { None })
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
        .filter_map(|l| {
            l.trim()
                .strip_prefix("name ")
                .and_then(|s| s.split(" at").next())
        })
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

// ---------- local transport: three remsh subprocesses (logs + shell + monitor) -
//
// Mirrors the deployed path (three SSH channels): one remsh subscribes to
// `RingLogger.attach()` and only streams log lines; the second is interactive
// and owns the IEx pane; the third subscribes to OvcsBus + every Cantastic
// network and streams tagged lines into the bus/can panes. All three target
// the single source BEAM (started by `./ovcs run`), which registers
// RingLogger as a `:logger` handler at boot.

/// Init piped to the log-side remsh. `RingLogger.attach/0` can raise
/// during the narrow window between the remote BEAM registering with
/// epmd and ring_logger's backend being fully up (this is the common
/// case on reconnect — the supervisor spots the new registration
/// eagerly). Retry for up to ~60s so logs start flowing as soon as the
/// remote is ready, and keep the process alive forever once attached.
/// Printed by the log snippet once `RingLogger.attach/0` has succeeded.
/// The log reader drops every line it sees until this marker arrives,
/// hiding the Nerves/IEx banner, the echoed snippet input, and the
/// prompt that follows it.
const LOG_READY_MARKER: &str = "OVCS_LOG_READY";

const LOG_INIT_SNIPPET: &str = r#"Enum.reduce_while(1..120, :retry, fn _, _ ->
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
IO.puts("OVCS_LOG_READY")
Process.sleep(:infinity)
"#;

/// Elixir snippet injected into the monitor remsh on every node.
///
/// Subscribes to:
/// - `OvcsBus` messages — but only when running on the VMS node, because
///   `OvcsBus.Cluster` fans out cluster-wide and subscribing on every BEAM
///   would yield N duplicates of every message.
/// - Every Cantastic network the local BEAM knows about (per-BEAM — each
///   side has its own YAML).
///
/// Emits tab-separated lines on `:stdio`:
/// - `OVCS_BUS\t<source>\t<name>\t<inspect(value)>`
/// - `OVCS_CAN\t<network>\t<frame>\t<key=val key=val …>`
///
/// The Rust side splits on `\t` and dispatches to the bus / can pane.
const MONITOR_SNIPPET: &str = r##"defmodule OvcsAttachDiag do
  # On a Pi with a busy CAN bus a sync `File.write!` per message
  # serialises the bus/can loops and the SSH pane lags seconds behind
  # real time. Stick to `IO.puts` and rely on the TUI panes only.
  #
  # When the Rust attach harness tears down the remsh, `:standard_io`
  # terminates and every subsequent `IO.puts` raises `:terminated` —
  # which the BEAM's logger backend would then itself try to write
  # via the same dead stdio, cascading into a noisy crash storm. The
  # spawned monitor processes are orphans without supervisors, so the
  # right answer when stdio is gone is to silently exit them; the
  # next attach attempt spawns fresh ones.
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

  # CAN traffic is observed via `candump -tz <iface>` one Port per
  # unique vcan interface. We bypass `Cantastic.Receiver` — it only
  # forwards frames whose ID is in a network's `received_frames` list
  # and silently drops everything else (including frames the same node
  # emits). candump taps the kernel CAN socket directly and sees every
  # frame on the bus regardless of YAML declarations. Bus (OvcsBus)
  # stays on a Phoenix.PubSub subscribe since it's node-local.
  #
  # Observed frames are decoded into named signals by looking up the
  # Cantastic frame spec and running it through `Frame.interpret/2`,
  # so the output reads the same way as the bus pane rather than raw
  # hex bytes. Unknown IDs fall back to hex.

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

      ifs ->
        OvcsAttachDiag.log("OVCS_CAN\t[mon]\tstarting\t#{Enum.join(ifs, ",")}")
        for iface <- ifs, do: spawn(fn -> candump_loop(iface) end)
    end
  end

  defp vms?, do: String.contains?(Atom.to_string(node()), "-vms")

  defp bus_running?, do: Process.whereis(OvcsBus) != nil

  # Subscribe locally when OvcsBus is alive AND either we're VMS (the
  # canonical sink in a clustered host-dev setup, avoids duplicates
  # from `OvcsBus.Cluster` fan-out) or distribution isn't started at
  # all (deployed Nerves devices today — each BEAM is isolated, so we
  # need a subscriber on every one to surface its local broadcasts).
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
  # Each iface gets one `{network_name, %{frame_id => FrameSpecification}}`
  # entry keyed under `:persistent_term`. We build the specs ourselves
  # via `Cantastic.FrameSpecification.from_yaml/3` from the raw YAML
  # blobs on `network_config` — that way we get both emitted and
  # received frames (the Receiver GenServer state only holds received
  # ones) and we don't depend on the Receiver having drained its
  # mailbox, which we can't assume on host dev.

  defp build_spec_cache do
    Enum.each(networks(), fn net ->
      emitted =
        build_specs(net.network_name, net.network_config[:emitted_frames] || [], :emit)

      received =
        build_specs(net.network_name, net.network_config[:received_frames] || [], :receive)

      :persistent_term.put({:ovcs_attach_specs, net.interface}, %{
        network_name: net.network_name,
        specs: Map.merge(received, emitted)
      })
    end)
  end

  defp build_specs(network_name, yaml_specs, direction) do
    Enum.reduce(yaml_specs, %{}, fn yaml, acc ->
      try do
        {:ok, spec} = Cantastic.FrameSpecification.from_yaml(network_name, yaml, direction)
        Map.put(acc, spec.id, spec)
      rescue
        _ -> acc
      catch
        _, _ -> acc
      end
    end)
  end

  defp lookup_spec(iface, id) do
    case :persistent_term.get({:ovcs_attach_specs, iface}, nil) do
      nil -> {to_string(iface), nil}
      %{network_name: net, specs: specs} -> {Atom.to_string(net), Map.get(specs, id)}
    end
  end

  # -- OvcsBus --------------------------------------------------------

  defp bus_loop do
    ok? =
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

    OvcsAttachDiag.log("OVCS_BUS\t[mon]\tsubscribed\t#{ok?}")
    bus_receive()
  end

  defp bus_receive do
    receive do
      %OvcsBus.Message{source: s, name: n, value: v} ->
        OvcsAttachDiag.log("OVCS_BUS\t#{inspect(s)}\t#{n}\t#{inspect(v)}")

      _ ->
        :ok
    end

    bus_receive()
  end

  # -- candump --------------------------------------------------------

  defp candump_loop(iface) do
    candump = System.find_executable("candump") || "/usr/bin/candump"

    port =
      Port.open({:spawn_executable, candump}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-tz", iface]
      ])

    read_port(port, iface, "")
  end

  defp read_port(port, iface, buf) do
    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(buf <> chunk)
        Enum.each(lines, &process_line(iface, &1))
        read_port(port, iface, rest)

      {^port, {:exit_status, code}} ->
        OvcsAttachDiag.log("OVCS_CAN\t[mon]\tcandump_exit\t#{iface} code=#{code}")
    end
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  # candump -tz produces lines like:
  #   " (0.000123)  vcan0  1A0   [8]  00 00 01 FF FF FF 7F 00"
  defp process_line(iface, line) do
    case Regex.run(~r/^\s*\([\d.]+\)\s+\S+\s+([0-9A-Fa-f]+)\s+\[(\d+)\]\s*(.*)$/, line) do
      [_, id_hex, dlc, data_hex] ->
        id = String.to_integer(id_hex, 16)
        byte_number = String.to_integer(dlc)
        raw_data = hex_bytes_to_binary(data_hex)
        {network, spec} = lookup_spec(iface, id)

        emit_frame(network, id_hex, byte_number, raw_data, data_hex, spec)

      _ ->
        :ok
    end
  end

  defp hex_bytes_to_binary(hex_bytes) do
    hex_bytes
    |> String.split()
    |> Enum.reduce(<<>>, fn b, acc ->
      <<acc::binary, String.to_integer(b, 16)>>
    end)
  end

  # Build a bare Frame and let Cantastic.Frame.interpret/2 populate
  # the signals map. Emit signals and raw hex as two separate
  # tab-separated fields so the Rust side can toggle which half of
  # the row is shown without reparsing. If decoding raises, signals
  # is empty.
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
        |> Enum.map(fn {k, sig} -> "#{k}=#{inspect(sig.value)}" end)
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

/// Wrap a multi-line Elixir snippet so it reaches the remote IEx as a
/// series of short input lines, each well under the cooked-mode PTY
/// line-discipline cap (`MAX_CANON` = 4096 on Linux).
///
/// Two constraints meet here:
/// - IEx echoes every input line back with a prompt prefix, so we want
///   as few input lines as possible — that pushed us to base64 the
///   whole snippet into a single `Code.eval_string(...)` call.
/// - For deployed attach we run over an SSH PTY in canonical mode, and
///   a single 10 KB line is silently truncated mid-base64; the eval
///   fails to parse and the bus/can monitor never starts. Local attach
///   uses pipes (no line discipline) so it didn't surface there.
///
/// Compromise: stream the base64 payload into `/tmp/ovcs_attach.exs`
/// in ~1 KB chunks via `File.write!`, then `Code.require_file/1` it.
/// Each input line stays small. The monitor channel's reader only
/// forwards `OVCS_BUS\t…` / `OVCS_CAN\t…` lines, so the echoed
/// `File.write!` calls are dropped naturally. The log channel relies
/// on the `OVCS_LOG_READY` gate, which still works.
const CHUNK_BYTES: usize = 1024;

fn wrap_snippet(snippet: &str, channel: &str) -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let encoded = STANDARD.encode(snippet.as_bytes());
    // Per-channel path so log + monitor chunked writes never interleave
    // on the same remote BEAM.
    let path = format!("/tmp/ovcs_attach_{}.exs", channel);
    let mut out = String::with_capacity(encoded.len() + 256);
    out.push_str(&format!("File.write!(\"{}\", \"\")\n", path));
    for chunk in encoded.as_bytes().chunks(CHUNK_BYTES) {
        let chunk_str = std::str::from_utf8(chunk).expect("base64 alphabet is ASCII");
        out.push_str(&format!(
            "File.write!(\"{}\", Base.decode64!(\"{}\"), [:append])\n",
            path, chunk_str
        ));
    }
    // `Code.eval_file/1`, not `Code.require_file/1`: require_file
    // memoises by path for the BEAM's lifetime, so a second attach to
    // the same long-lived Nerves device would no-op the load and we'd
    // get no logs, no can, no bus.
    out.push_str(&format!("Code.eval_file(\"{}\")\n", path));
    out
}

fn attach_local(nodes: Vec<(String, String)>) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Msg>();
    let mut handles: Vec<NodeHandle> = Vec::new();
    let pid = std::process::id();
    let shutdown = Arc::new(AtomicBool::new(false));
    let mut sup_handles: Vec<thread::JoinHandle<()>> = Vec::new();

    for (idx, (label, full_node)) in nodes.iter().enumerate() {
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>();
        sub(&format!("supervisor for {} ({})", label, full_node));

        let tx_sup = tx.clone();
        let label_sup = label.clone();
        let full_node_sup = full_node.clone();
        let shutdown_sup = shutdown.clone();
        let h = thread::spawn(move || {
            run_local_node(
                label_sup,
                full_node_sup,
                pid,
                idx,
                stdin_rx,
                tx_sup,
                shutdown_sup,
            );
        });
        sup_handles.push(h);

        handles.push(NodeHandle {
            name: label.clone(),
            stdin: stdin_tx,
        });
    }

    step("attached — handing off to TUI. (Ctrl-C or q to quit)");

    let ui_result = run_ui::run(rx, handles);

    shutdown.store(true, Ordering::Relaxed);
    for h in sup_handles {
        let _ = h.join();
    }

    ui_result
}

/// Per-node supervisor. Owns one `Trio` of remsh children at a time, tied
/// to a single full node. On any of the three processes dying it kills
/// the survivors, reports `NodeDown`, then sleeps with exponential
/// backoff (capped at `BACKOFF_CAP`) before spawning a fresh trio. Exits
/// the loop when `shutdown` flips — callers set that flag after the TUI
/// returns so children don't outlive the CLI.
fn run_local_node(
    label: String,
    full_node: String,
    pid: u32,
    idx: usize,
    stdin_rx: Receiver<String>,
    tx: Sender<Msg>,
    shutdown: Arc<AtomicBool>,
) {
    let mut backoff = INITIAL_BACKOFF;
    let mut attempt: u64 = 0;

    while !shutdown.load(Ordering::Relaxed) {
        // Wait for the target BEAM to register with epmd before spawning
        // a trio: the first attempt after startup blocks here until
        // `./ovcs run` has finished booting; subsequent reconnects block
        // until the user restarts the BEAM. This is also the primary
        // death detector — `iex --remsh` doesn't exit when its remote
        // node dies (the pipes stay open), so polling epmd is how we
        // notice we need to tear down and retry.
        if !wait_until_registered(&full_node, &shutdown) {
            break;
        }

        match spawn_trio(&label, &full_node, pid, idx, attempt, &tx) {
            Ok(trio) => {
                // Fresh session: discard any input queued while down.
                while stdin_rx.try_recv().is_ok() {}

                let _ = tx.send(Msg::NodeUp(label.clone()));
                let session_elapsed = run_one_session(trio, &full_node, &stdin_rx, &shutdown);
                if session_elapsed > HEALTHY_SESSION {
                    backoff = INITIAL_BACKOFF;
                }
                let _ = tx.send(Msg::NodeDown(label.clone()));
            }
            Err(e) => {
                let _ = tx.send(Msg::Log {
                    node: label.clone(),
                    line: format!("[ovcs] spawn failed: {}", e),
                });
            }
        }

        if shutdown.load(Ordering::Relaxed) {
            break;
        }

        attempt += 1;
        let _ = tx.send(Msg::Log {
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

    // Forward stdin and watch for child death + node disappearance.
    // `recv_timeout` gives us a wake-up so we can poll without spinning.
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
/// Drops `shell_stdin` implicitly on kill so the BEAM's IEx sees EOF.
struct Trio {
    log_child: Child,
    shell_child: Child,
    mon_child: Child,
    shell_stdin: ChildStdin,
    // The log/monitor remsh sessions are non-interactive (we inject a
    // snippet then leave them streaming), but we must keep their stdin
    // *open* for the whole session: closing it sends EOF, and EOF makes
    // `iex --remsh` terminate the **remote** node's shell — which halts
    // the `./ovcs run` BEAM. Held here, never written; the fds close only
    // after the children are SIGKILLed in `kill_all`, by which point the
    // remote no longer cares.
    #[allow(dead_code)]
    log_stdin: ChildStdin,
    #[allow(dead_code)]
    mon_stdin: ChildStdin,
}

impl Trio {
    fn any_dead(&mut self) -> bool {
        [
            &mut self.log_child,
            &mut self.shell_child,
            &mut self.mon_child,
        ]
        .into_iter()
        .any(|c| matches!(c.try_wait(), Ok(Some(_))))
    }

    fn kill_all(&mut self) {
        for c in [
            &mut self.log_child,
            &mut self.shell_child,
            &mut self.mon_child,
        ] {
            // Kill the whole process group (stdbuf → iex → beam), not just
            // the direct child. Killing only the wrapper would orphan the
            // remsh BEAM, which then hits EOF on its closing stdin and
            // cleanly halts the *remote* node. A group SIGKILL drops the
            // distribution link abruptly instead — the remote survives.
            // The remsh is its own group leader (see `spawn_remsh`), so the
            // pid doubles as the pgid.
            unsafe { libc::kill(-(c.id() as libc::pid_t), libc::SIGKILL) };
            let _ = c.wait();
        }
    }
}

/// Build a fresh `Trio` for one node: three `iex --remsh` subprocesses,
/// six reader threads wired into the TUI channel. `attempt` is mixed into
/// each child's sname so reconnects don't collide with lingering epmd
/// entries from the previous incarnation.
fn spawn_trio(
    label: &str,
    full_node: &str,
    pid: u32,
    idx: usize,
    attempt: u64,
    tx: &Sender<Msg>,
) -> Result<Trio> {
    // Log-side remsh.
    let log_sname = format!("ovcs_attach_log_{}_{}_{}", pid, idx, attempt);
    let mut log_child =
        spawn_remsh(&log_sname, full_node).with_context(|| format!("log remsh for {}", label))?;
    let log_stdout = log_child.stdout.take().unwrap();
    let log_stderr = log_child.stderr.take().unwrap();
    let mut log_stdin = log_child.stdin.take().unwrap();
    let _ = log_stdin.write_all(wrap_snippet(LOG_INIT_SNIPPET, "log").as_bytes());
    let _ = log_stdin.flush();
    spawn_reader(log_stdout, label, tx, forward_log);
    spawn_reader(log_stderr, label, tx, forward_log);

    // Shell-side remsh.
    let shell_sname = format!("ovcs_attach_sh_{}_{}_{}", pid, idx, attempt);
    let mut shell_child = spawn_remsh(&shell_sname, full_node)
        .with_context(|| format!("shell remsh for {}", label))?;
    let shell_stdout = shell_child.stdout.take().unwrap();
    let shell_stderr = shell_child.stderr.take().unwrap();
    let shell_stdin = shell_child.stdin.take().unwrap();
    spawn_reader(shell_stdout, label, tx, forward_shell);
    spawn_reader(shell_stderr, label, tx, forward_shell);

    // Monitor-side remsh.
    let mon_sname = format!("ovcs_attach_mon_{}_{}_{}", pid, idx, attempt);
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
        log_stdin,
        mon_stdin,
    })
}

fn spawn_reader<R, F>(reader: R, label: &str, tx: &Sender<Msg>, forward: F)
where
    R: std::io::Read + Send + 'static,
    F: Fn(R, &str, &Sender<Msg>) + Send + 'static,
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

/// Returns true iff `full_node` (in the `sname@hostname` form returned by
/// `find_local_beams`) currently shows up in `epmd -names`.
///
/// epmd's output looks like:
/// ```text
/// epmd: up and running on port 4369 with data:
/// name ovcs1-vms at port 35123
/// ```
///
/// We parse each `name <sname> at` line and match on the sname only —
/// epmd is per-host so the hostname portion is implicit.
fn node_registered(full_node: &str) -> bool {
    let Some((sname, _)) = full_node.split_once('@') else {
        // Malformed full_node — assume up so we don't trigger an
        // incorrect reconnect storm.
        return true;
    };
    let Ok(out) = Command::new("epmd").arg("-names").output() else {
        // epmd unreachable (e.g., it stopped): treat as if everything is
        // up; the per-child pipe read errors will still tear us down
        // once a remsh actually fails.
        return true;
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    stdout.lines().any(|l| {
        l.trim()
            .strip_prefix("name ")
            .and_then(|s| s.split(" at").next())
            .map(|n| n == sname)
            .unwrap_or(false)
    })
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
    // `-hidden` makes the local observer a hidden node so it doesn't
    // become a full cluster member of the vehicle mesh. Without it,
    // `:global` panics with "overlapping partitions" every time a
    // remsh connects or disconnects (and we churn through six of them
    // per reconnect cycle with four vehicle BEAMs in flight).
    Command::new("stdbuf")
        .args([
            "-oL",
            "-eL",
            "iex",
            "--erl",
            "-hidden",
            "--sname",
            local_sname,
            "--cookie",
            "ovcs",
            "--remsh",
            full_node,
        ])
        // Own process group so `kill_all` can SIGKILL the whole
        // stdbuf → iex → beam chain at once (the pid is the pgid).
        .process_group(0)
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

    let ui_result = run_ui::run(rx, handles);

    // Unblock every supervisor task on any await point (connect, sleep,
    // select!) so they drop before the runtime thread joins.
    shutdown.store(true, Ordering::Relaxed);
    for h in aborts.lock().unwrap().drain(..) {
        h.abort();
    }
    let _ = rt_thread.join();

    ui_result
}

struct DeployedJob {
    label: String,
    host: String,
    stdin_rx: Receiver<String>,
}

fn run_ssh_runtime(
    jobs: Receiver<DeployedJob>,
    tx: Sender<Msg>,
    shutdown: Arc<AtomicBool>,
    aborts: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
) {
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
            let shutdown = shutdown.clone();
            let h = tokio::spawn(async move {
                run_device_supervisor(job.label, job.host, job.stdin_rx, tx, shutdown).await;
            });
            aborts.lock().unwrap().push(h.abort_handle());
            joins.push(h);
        }
        for j in joins {
            let _ = j.await;
        }
    });
}

/// Persistent per-device loop: connect, open the three channels, run the
/// session, and on any disconnect (including a clean remote EOF) wait with
/// exponential backoff and try again. Exits when `shutdown` flips; the
/// abort handle stashed by the caller ensures in-flight awaits (connect
/// or sleep) drop promptly instead of stranding the runtime thread.
async fn run_device_supervisor(
    label: String,
    host: String,
    stdin_rx: Receiver<String>,
    tx: Sender<Msg>,
    shutdown: Arc<AtomicBool>,
) {
    // Persistent sync→async bridge: the sync `stdin_rx` lives for the whole
    // node lifetime, but each session gets a fresh async channel swapped
    // through this Mutex. While the node is down the slot is `None`, which
    // silently discards any input the user typed after seeing
    // `[ovcs] disconnected`.
    let active: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedSender<String>>>> =
        Arc::new(Mutex::new(None));
    let active_bridge = active.clone();
    std::thread::spawn(move || {
        while let Ok(line) = stdin_rx.recv() {
            if let Some(s) = active_bridge.lock().unwrap().as_ref() {
                let _ = s.send(line);
            }
        }
    });

    let mut backoff = INITIAL_BACKOFF;

    while !shutdown.load(Ordering::Relaxed) {
        let (ain_tx, ain_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        *active.lock().unwrap() = Some(ain_tx);

        let started = tokio::time::Instant::now();
        let result = run_device_once(&label, &host, ain_rx, &tx).await;

        // Either the remote side hung up or we errored out — stop routing
        // stdin until a reconnect swaps in a fresh sender.
        *active.lock().unwrap() = None;

        if let Err(e) = result {
            let _ = tx.send(Msg::Log {
                node: label.clone(),
                line: format!("[ovcs] session: {}", e),
            });
        } else if started.elapsed() > HEALTHY_SESSION {
            // The session stayed up long enough to count as healthy;
            // reset the backoff so the next reconnect is quick.
            backoff = INITIAL_BACKOFF;
        }
        let _ = tx.send(Msg::NodeDown(label.clone()));

        if shutdown.load(Ordering::Relaxed) {
            break;
        }

        let _ = tx.send(Msg::Log {
            node: label.clone(),
            line: format!("[ovcs] reconnecting in {}s…", backoff.as_secs()),
        });
        interruptible_sleep_async(backoff, &shutdown).await;
        backoff = next_backoff(backoff);

        // On reconnect we don't want a success to route stale input into
        // the fresh session — re-establish the bridge only after the
        // next `run_device_once` has re-assigned `active`.
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

/// One round-trip SSH session for a device. Opens the three channels,
/// announces `NodeUp`, and pumps data until any channel EOFs or the
/// remote side dies. The supervisor above handles `NodeDown`, backoff,
/// and reconnection; this function just reports session-ending errors
/// via its `Result`.
async fn run_device_once(
    label: &str,
    host: &str,
    mut ain_rx: tokio::sync::mpsc::UnboundedReceiver<String>,
    tx: &Sender<Msg>,
) -> Result<()> {
    use russh::ChannelMsg;

    let mut handle = connect_ssh(host).await?;
    let (mut log_ch, mut shell_ch, mut mon_ch) = open_ssh_channels(&mut handle).await?;

    let _ = tx.send(Msg::NodeUp(label.to_string()));

    let label_owned = label.to_string();
    let tx_owned = tx.clone();
    // Same readiness gate as the local `forward_log` path — drop the
    // Nerves/IEx banner, the echoed `Code.eval_string` wrapper, and
    // IEx's prompt until the snippet finishes attaching RingLogger
    // and prints `OVCS_LOG_READY`. After that, `is_iex_noise` keeps
    // any stray prompts out.
    let mut log_ready = false;
    let forward_log_line = |line: String, ready: &mut bool, tx: &Sender<Msg>| {
        if !*ready {
            if strip_ansi(&line).contains(LOG_READY_MARKER) {
                *ready = true;
            }
            return;
        }
        if is_iex_noise(&line) {
            return;
        }
        let _ = tx.send(Msg::Log {
            node: label_owned.clone(),
            line,
        });
    };
    loop {
        tokio::select! {
            maybe = log_ch.wait() => {
                match maybe {
                    Some(ChannelMsg::Data { data }) => {
                        for line in split_lines(&data) {
                            forward_log_line(line, &mut log_ready, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in split_lines(&data) {
                            forward_log_line(line, &mut log_ready, &tx_owned);
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
            maybe = mon_ch.wait() => {
                match maybe {
                    Some(ChannelMsg::Data { data }) => {
                        for line in split_lines(&data) {
                            let _ = dispatch_monitor_line(&line, &label_owned, &tx_owned);
                        }
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for line in split_lines(&data) {
                            let _ = dispatch_monitor_line(&line, &label_owned, &tx_owned);
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

    let _ = log_ch.close().await;
    let _ = shell_ch.close().await;
    let _ = mon_ch.close().await;
    Ok(())
}

/// russh `client::Handler` that accepts any server host key. Private to
/// attach.rs — the TUI already requires the user to have cleared the host
/// verification via plain `ssh` once, and we can't prompt from inside a
/// Ratatui render loop.
struct SshAcceptAllKeys;

impl russh::client::Handler for SshAcceptAllKeys {
    type Error = russh::Error;
    async fn check_server_key(
        &mut self,
        _: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

/// Connect + authenticate an SSH session against `host` using the
/// user's ssh-agent identities. Returns the handle the caller can open
/// channels against. Returns a descriptive `anyhow::Error` on any
/// failure in the connect / auth chain.
async fn connect_ssh(host: &str) -> Result<russh::client::Handle<SshAcceptAllKeys>> {
    let config = Arc::new(russh::client::Config::default());
    let mut handle = tokio::time::timeout(
        CONNECT_TIMEOUT,
        russh::client::connect(config, (host, 22), SshAcceptAllKeys),
    )
    .await
    .with_context(|| format!("connect {} timed out after {:?}", host, CONNECT_TIMEOUT))?
    .with_context(|| format!("connect {} failed", host))?;

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
    // OTP 27's SSH daemon (nerves_ssh) rejects SHA-1 `ssh-rsa` signatures,
    // which is what russh signs with when `hash_alg` is `None`. For RSA keys
    // we must pick an `rsa-sha2-*` hash — mirroring what OpenSSH negotiates,
    // hence why plain `ssh` works while a `None` hash here does not. Query the
    // server's advertised algs and fall back to SHA-256 if it sent none.
    let rsa_hash = handle
        .best_supported_rsa_hash()
        .await
        .ok()
        .flatten()
        .unwrap_or(Some(russh::keys::ssh_key::HashAlg::Sha256));
    for key in identities {
        let hash_alg = match key.algorithm() {
            russh::keys::ssh_key::Algorithm::Rsa { .. } => rsa_hash,
            _ => None,
        };
        let auth = handle
            .authenticate_publickey_with(SSH_USER, key, hash_alg, &mut agent)
            .await?;
        if auth.success() {
            return Ok(handle);
        }
    }
    bail!("ssh auth failed for {}@{}", SSH_USER, host);
}

/// Connect to the ssh-agent that plain `ssh` would use for `host`. We
/// shell out to `ssh -G <host>` and honour its resolved `identityagent`
/// directive, falling back to `$SSH_AUTH_SOCK` when none is set. This
/// matches OpenSSH's per-host `IdentityAgent` precedence, so users with
/// e.g. `IdentityAgent ~/.1password/agent.sock` in `~/.ssh/config` get
/// the same agent here as in their terminal.
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
    let out = Command::new("ssh")
        .arg("-G")
        .arg(host)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let value = stdout.lines().find_map(|l| {
        let mut it = l.splitn(2, char::is_whitespace);
        match (it.next(), it.next()) {
            (Some(k), Some(v)) if k.eq_ignore_ascii_case("identityagent") => Some(v.trim()),
            _ => None,
        }
    })?;
    if value.is_empty() || value.eq_ignore_ascii_case("none") || value == "SSH_AUTH_SOCK" {
        return None;
    }
    let expanded = if let Some(rest) = value.strip_prefix("~/") {
        std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(rest))?
    } else {
        std::path::PathBuf::from(value)
    };
    Some(expanded)
}

/// Open the three session-shell channels used by `run_device_once`.
///
/// - logs: RingLogger.attach + sleep, stdout feeds log pane.
/// - shell: interactive IEx for user input.
/// - monitor: OvcsBus + Cantastic subscription; stdout is the stream of
///   tagged `OVCS_BUS` / `OVCS_CAN` lines consumed by the bus/can panes.
///
/// Returns them in `(log, shell, monitor)` order so destructuring matches
/// the order they are read in the caller's `tokio::select!` loop.
async fn open_ssh_channels(
    handle: &mut russh::client::Handle<SshAcceptAllKeys>,
) -> Result<(
    russh::Channel<russh::client::Msg>,
    russh::Channel<russh::client::Msg>,
    russh::Channel<russh::client::Msg>,
)> {
    let log_ch = handle.channel_open_session().await?;
    log_ch
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    log_ch.request_shell(false).await?;
    log_ch
        .data(wrap_snippet(LOG_INIT_SNIPPET, "log").as_bytes())
        .await?;

    let shell_ch = handle.channel_open_session().await?;
    shell_ch
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    shell_ch.request_shell(false).await?;

    let mon_ch = handle.channel_open_session().await?;
    mon_ch
        .request_pty(false, "xterm", 120, 40, 0, 0, &[])
        .await?;
    mon_ch.request_shell(false).await?;
    mon_ch
        .data(wrap_snippet(MONITOR_SNIPPET, "mon").as_bytes())
        .await?;

    Ok((log_ch, shell_ch, mon_ch))
}

fn split_lines(bytes: &[u8]) -> Vec<String> {
    let output = String::from_utf8_lossy(bytes);
    output
        .split('\n')
        .map(|l| l.trim_end_matches('\r').to_string())
        // Logger emits ANSI colour codes — a "blank" line may carry
        // just CSI resets, so check emptiness after stripping.
        .filter(|l| !strip_ansi(l).trim().is_empty())
        .collect()
}

// ---------- local stdio → Msg dispatch ----------

/// Read `reader` line by line, calling `handle_line(line, node, tx)` on
/// each. `handle_line` returns `false` to signal the reader should
/// stop (typically because the tx channel is gone). This is the one
/// pump shared by log / shell / monitor pipes — the three forms differ
/// only in their per-line decisions, which now live in dedicated
/// `dispatch_*_line` helpers.
fn forward_stream<Reader, Handle>(reader: Reader, node: &str, tx: &Sender<Msg>, handle_line: Handle)
where
    Reader: std::io::Read + Send + 'static,
    Handle: Fn(&str, &str, &Sender<Msg>) -> bool,
{
    let buffered = BufReader::new(reader);
    for line in buffered.lines().map_while(|result| result.ok()) {
        if !handle_line(&line, node, tx) {
            break;
        }
    }
}

fn forward_log<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Msg>) {
    // Suppress everything until the snippet prints LOG_READY_MARKER —
    // that covers the Nerves/IEx banner, the echoed `Code.eval_string`
    // input, and IEx's prompt repeat. After the marker, the normal
    // `is_iex_noise` filter is enough.
    let mut ready = false;
    let buffered = BufReader::new(reader);
    for line in buffered.lines().map_while(|r| r.ok()) {
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
/// stdout carries real log events but also IEx's own banner, continuation
/// prompts, and return values from the init snippet. Drop those so they
/// don't clutter the log pane.
///
/// Ideally we'd use `elixir -eval` against the target node instead of IEx
/// (no banner to filter), but `RingLogger.attach()` binds to the calling
/// process, so we need a long-lived remote process — exactly what an iex
/// remsh gives us. Prefix-matching is the pragmatic compromise; widen the
/// list if a new IEx version prints a banner line we haven't seen.
pub fn is_iex_noise(line: &str) -> bool {
    // Strip ANSI CSI sequences first — Logger emits colour codes around
    // level / source / timestamp on host dev, so the naive `line.trim()`
    // leaves an invisible but non-empty string and blank "[label] " rows
    // leak into the log pane.
    let stripped = strip_ansi(line);
    let trimmed = stripped.trim();
    const NOISE_PREFIXES: &[&str] = &[
        "iex(",               // interactive prompt
        "iex:",               // stacktrace frame (file:line) from iex eval
        "...(",               // continuation prompt
        "Erlang/OTP",         // erlang banner
        "Interactive Elixir", // iex banner
        ":ok",                // return value from our init snippet
        "Compiling ",         // mix recompile chatter under --remsh
        "** (",               // leading error header from IEx evaluation
        "Code.eval_string(",  // our remsh init wrapper, echoed by IEx
    ];
    // After the stripped.trim() above, raw stacktrace frames look like
    // `(ring_logger 0.11.5) RingLogger.attach()` — the leading `(` isn't
    // covered by any user log line we care about, so treating bare
    // library-name-in-parens frames as noise is safe.
    if trimmed.is_empty() || NOISE_PREFIXES.iter().any(|p| trimmed.starts_with(p)) {
        return true;
    }
    if let Some(inside) = trimmed.strip_prefix('(') {
        if let Some((lib, _)) = inside.split_once(')') {
            if is_library_tag(lib) {
                return true;
            }
        }
    }
    false
}

/// Heuristic for `(name 1.2.3)` / `(name)` stacktrace library tags — lib
/// names are lowercase identifiers with optional semver. A real log line
/// that happens to start with `(` is unlikely to match both conditions.
fn is_library_tag(s: &str) -> bool {
    let mut parts = s.split_whitespace();
    let name = match parts.next() {
        Some(n) => n,
        None => return false,
    };
    name.chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn forward_shell<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Msg>) {
    forward_stream(reader, node, tx, dispatch_shell_line);
}

fn dispatch_shell_line(line: &str, node: &str, tx: &Sender<Msg>) -> bool {
    tx.send(Msg::Shell {
        node: node.to_string(),
        line: line.to_string(),
    })
    .is_ok()
}

/// Reader thread for the monitor remsh's stdout.
///
/// The snippet we injected prints one tab-separated tagged line per event:
///   `OVCS_BUS\t<source>\t<name>\t<inspect(value)>`
///   `OVCS_CAN\t<network>\t<frame>\t<signals>\t<raw_hex>`
///
/// Anything else (iex banner, return values from the init snippet) is noise
/// from the remsh itself — drop it instead of polluting the log pane.
fn forward_monitor<R: std::io::Read + Send + 'static>(reader: R, node: &str, tx: &Sender<Msg>) {
    forward_stream(reader, node, tx, dispatch_monitor_line);
}

/// Parse one monitor line. Returns `false` if the channel is gone and the
/// caller should stop reading.
fn dispatch_monitor_line(raw: &str, node: &str, tx: &Sender<Msg>) -> bool {
    let stripped = strip_ansi(raw);
    let line = stripped.trim();
    if line.is_empty() {
        return true;
    }
    // splitn(5) covers the widest case (OVCS_CAN carries 4 body
    // fields); OVCS_BUS only has 3 body fields and its tail tokens
    // are left empty, which is fine.
    let mut parts = line.splitn(5, '\t');
    let tag = parts.next().unwrap_or("");
    match tag {
        "OVCS_BUS" => {
            let source = parts.next().unwrap_or("").to_string();
            let name = parts.next().unwrap_or("").to_string();
            let value = parts.next().unwrap_or("").to_string();
            tx.send(Msg::Bus {
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
            tx.send(Msg::CanFrame {
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
