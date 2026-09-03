use anyhow::{Context, Result};
use glob::glob;
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::shell::run_capture;

#[derive(Clone)]
pub struct Vehicle {
    pub dir: String,
    pub module: String,
    pub path: PathBuf,
}

pub struct BridgeFirmware {
    pub target: String,
}

pub fn list(repo_root: &Path) -> Result<Vec<Vehicle>> {
    let pattern = repo_root.join("vehicles/*/mix.exs");
    let pattern_str = pattern.to_str().context("non-utf8 repo root")?;
    let mut vehicles = Vec::new();
    for entry in glob(pattern_str)? {
        let mix_path = entry?;
        let vehicle_path = mix_path.parent().unwrap().to_path_buf();
        let dir = vehicle_path
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .to_string();
        vehicles.push(Vehicle {
            module: module_for(&dir),
            dir,
            path: vehicle_path,
        });
    }
    vehicles.sort_by(|a, b| a.dir.cmp(&b.dir));
    Ok(vehicles)
}

pub fn module_for(dir: &str) -> String {
    dir.split('_')
        .filter(|s| !s.is_empty())
        .map(|s| {
            let mut chars = s.chars();
            chars.next().unwrap().to_uppercase().to_string() + chars.as_str()
        })
        .collect()
}

pub fn nerves_target(vehicle: &Vehicle, side: &str) -> Result<Option<String>> {
    let callback = match side {
        "vms" => "vms_target",
        "infotainment" => "infotainment_target",
        _ => return Ok(None),
    };
    let snippet = format!(
        r#"
if function_exported?({module}, :{callback}, 0) do
  IO.write(to_string({module}.{callback}()))
end
"#,
        module = vehicle.module,
        callback = callback,
    );
    run_snippet(&vehicle.path, &snippet)
}

pub fn host_can_interfaces(vehicle: &Vehicle) -> Result<Vec<String>> {
    let snippet = format!(
        r#"
m = {module}
sides =
  [m.vms()] ++
    if function_exported?(m, :infotainment, 0), do: [m.infotainment()], else: []
sides
|> Enum.map(& &1.default_can_mapping(:host))
|> Enum.join(",")
|> String.split(",", trim: true)
|> Enum.map(fn kv -> kv |> String.split(":", trim: true) |> List.last() end)
|> Enum.uniq()
|> Enum.join("\n")
|> IO.puts()
"#,
        module = vehicle.module,
    );
    match run_snippet(&vehicle.path, &snippet)? {
        None => Ok(Vec::new()),
        Some(output) => Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect()),
    }
}

pub fn host_for(vehicle_dir: &str, side: &str) -> String {
    // Both halves must use dashes — the device's `:mdns_lite` advertises
    // its hostname after replacing underscores in the vehicle dir AND in
    // the bridge id (see bridges/firmware/config/config.exs).
    format!(
        "{}-{}.local",
        vehicle_dir.replace('_', "-"),
        side.replace('_', "-")
    )
}

pub fn has_infotainment(vehicle: &Vehicle) -> Result<bool> {
    let snippet = format!(
        r#"
m = {module}
Code.ensure_loaded(m)
IO.write(if function_exported?(m, :infotainment, 0), do: "yes", else: "no")
"#,
        module = vehicle.module,
    );
    Ok(matches!(run_snippet(&vehicle.path, &snippet)?, Some(s) if s.trim() == "yes"))
}

pub fn bridge_firmwares(vehicle: &Vehicle) -> Result<HashMap<String, BridgeFirmware>> {
    let snippet = format!(
        r##"
m = {module}
Code.ensure_loaded(m)
if function_exported?(m, :bridge_firmwares, 0) do
  m.bridge_firmwares()
  |> Enum.map(fn {{id, entry}} -> "#{{id}}\t#{{entry[:target]}}" end)
  |> Enum.join("\n")
  |> IO.puts()
end
"##,
        module = vehicle.module,
    );
    let Some(output) = run_snippet(&vehicle.path, &snippet)? else {
        return Ok(HashMap::new());
    };
    let mut map = HashMap::new();
    for line in output.lines().filter(|l| !l.is_empty()) {
        if let Some((id, target)) = line.split_once('\t') {
            map.insert(
                id.to_string(),
                BridgeFirmware {
                    target: target.to_string(),
                },
            );
        }
    }
    Ok(map)
}

/// A dev-time companion process a firmware declares via `dev_addons/0`.
/// The CLI launches these alongside the BEAM on host runs; it stays
/// agnostic about what they are (a Vue dev server, a Flutter app, …).
pub struct DevAddon {
    /// Short name, unique within the firmware (e.g. "dashboard"). Combined
    /// with the firmware family for the log prefix.
    pub name: String,
    /// Directory to run in, relative to the firmware project dir.
    pub dir: String,
    /// Command (argv) that starts the long-running dev process.
    pub run: Vec<String>,
    /// Optional command (argv) to install deps on first run.
    pub install: Option<Vec<String>>,
    /// Optional path (relative to `dir`) whose presence means deps are
    /// already installed — when absent and `install` is set, the CLI runs
    /// `install` first.
    pub ready_marker: Option<String>,
    /// Optional one-line hint shown when the add-on starts (e.g. which URL
    /// to open). Keeps URL/port specifics in the app, not the CLI.
    pub note: Option<String>,
}

/// Ask a firmware project (by its directory) for the dev add-ons it
/// declares. The firmware's top-level module is named after its OTP app
/// (`Macro.camelize(app)`), so the same snippet works for every firmware
/// without the CLI hardcoding module names. Firmwares with no
/// `dev_addons/0` simply yield none.
pub fn dev_addons(firmware_dir: &Path) -> Result<Vec<DevAddon>> {
    let snippet = r##"
app = Mix.Project.config()[:app]
m = Module.concat([Macro.camelize(to_string(app))])
Code.ensure_loaded(m)
if function_exported?(m, :dev_addons, 0) do
  m.dev_addons()
  |> Enum.map(fn a ->
    run = a |> Map.get(:run, []) |> Enum.join(" ")
    install = a |> Map.get(:install, []) |> Enum.join(" ")
    [
      Map.fetch!(a, :name),
      Map.fetch!(a, :dir),
      run,
      install,
      Map.get(a, :ready_marker, ""),
      Map.get(a, :note, "")
    ]
    |> Enum.join("\t")
  end)
  |> Enum.join("\n")
  |> IO.puts()
end
"##;
    let Some(output) = run_snippet(firmware_dir, snippet)? else {
        return Ok(Vec::new());
    };
    let split = |s: &str| -> Vec<String> { s.split_whitespace().map(String::from).collect() };
    let mut addons = Vec::new();
    for line in output.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 6 {
            continue;
        }
        let run = split(f[2]);
        if run.is_empty() {
            continue;
        }
        let install = split(f[3]);
        addons.push(DevAddon {
            name: f[0].to_string(),
            dir: f[1].to_string(),
            run,
            install: if install.is_empty() {
                None
            } else {
                Some(install)
            },
            ready_marker: (!f[4].is_empty()).then(|| f[4].to_string()),
            note: (!f[5].is_empty()).then(|| f[5].to_string()),
        });
    }
    Ok(addons)
}

/// Printed by every probe before its payload, so compiler chatter can be
/// separated from the answer.
///
/// `mix run` compiles the project before evaluating `-e`, and that output
/// goes to stdout: "Compiling 10 files (.ex)", "Generated ovcs_mini app".
/// Returning raw stdout meant every caller parsed those lines as data.
/// `host_can_interfaces` took them for interface names and `ovcs can
/// setup` duly offered to `ip link add dev "Compiling 10 files (.ex)"`;
/// `has_infotainment` compares the whole output to "yes", so chatter made
/// it answer no. It only ever misbehaved on a cold build, which is why it
/// went unnoticed.
const PROBE_MARKER: &str = "__OVCS_PROBE__";

/// Everything the probe printed after the marker, or `None` if it printed
/// nothing. Splits on the *last* marker so a snippet that somehow emits it
/// twice still yields the final payload.
fn probe_payload(stdout: &str) -> Option<String> {
    let payload = match stdout.rsplit_once(PROBE_MARKER) {
        Some((_chatter, payload)) => payload,
        // No marker: an older/hand-built snippet, or mix failed before
        // evaluating. Fall back to the whole output rather than losing it.
        None => stdout,
    };
    let trimmed = payload.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub(crate) fn run_snippet(path: &Path, snippet: &str) -> Result<Option<String>> {
    let env: HashMap<String, String> =
        std::iter::once(("MIX_ENV".to_string(), "dev".to_string())).collect();
    let marked = format!("IO.write(\"{PROBE_MARKER}\")\n{snippet}");
    let (code, stdout) = run_capture(
        &["mix", "run", "--no-start", "--no-deps-check", "-e", &marked],
        path,
        &env,
    )?;
    if code == 0 {
        return Ok(probe_payload(&stdout));
    }
    // The retry gets the same marked snippet: it runs right after a
    // `deps.get` + `compile`, which is precisely when the chatter this
    // marker exists to skip is loudest.
    retry_with_deps(path, &marked)
}

fn retry_with_deps(path: &Path, marked: &str) -> Result<Option<String>> {
    let rel = path.strip_prefix(std::env::current_dir()?).unwrap_or(path);
    println!(
        "{}",
        format!("Preparing vehicle {} (first run)…", rel.display()).dimmed()
    );
    let env: HashMap<String, String> =
        std::iter::once(("MIX_ENV".to_string(), "dev".to_string())).collect();
    for args in [["deps.get"], ["compile"]] {
        let status = Command::new("mix")
            .args(args)
            .current_dir(path)
            .envs(&env)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()?;
        if !status.success() {
            return Ok(None);
        }
    }
    let (code, stdout) = run_capture(
        &["mix", "run", "--no-start", "--no-deps-check", "-e", marked],
        path,
        &env,
    )?;
    if code == 0 {
        return Ok(probe_payload(&stdout));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::{probe_payload, PROBE_MARKER};

    // The exact chatter that caused `ovcs can setup ovcs_mini` to offer
    // to create interfaces named "Compiling 10 files (.ex)".
    const CHATTER: &str = "Compiling 10 files (.ex)\nGenerated ovcs_mini app\n";

    #[test]
    fn compiler_chatter_before_the_marker_is_dropped() {
        let stdout = format!("{CHATTER}{PROBE_MARKER}vcan0\n");
        assert_eq!(probe_payload(&stdout).as_deref(), Some("vcan0"));
    }

    #[test]
    fn a_multi_line_payload_survives_intact() {
        let stdout = format!("{CHATTER}{PROBE_MARKER}vcan0\nvcan1\n");
        assert_eq!(probe_payload(&stdout).as_deref(), Some("vcan0\nvcan1"));
    }

    #[test]
    fn an_empty_payload_is_none_even_behind_chatter() {
        // Otherwise the chatter itself reads as the answer — which is how
        // has_infotainment came to answer "no" on a cold build.
        let stdout = format!("{CHATTER}{PROBE_MARKER}\n");
        assert_eq!(probe_payload(&stdout), None);
    }

    #[test]
    fn output_without_a_marker_is_passed_through() {
        // mix failing before it evaluates -e must not silently look like
        // an empty answer.
        assert_eq!(probe_payload("yes").as_deref(), Some("yes"));
    }

    #[test]
    fn the_last_marker_wins() {
        let stdout = format!("{PROBE_MARKER}stale{PROBE_MARKER}fresh");
        assert_eq!(probe_payload(&stdout).as_deref(), Some("fresh"));
    }
}
