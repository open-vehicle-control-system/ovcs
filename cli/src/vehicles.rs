use anyhow::{Context, Result};
use glob::glob;
use owo_colors::OwoColorize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::shell::run_capture;

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
    let snippet = format!(
        r#"
if function_exported?({module}, :nerves_target, 1) do
  try do
    IO.write(to_string({module}.nerves_target(:{side})))
  rescue
    FunctionClauseError -> :ok
  end
end
"#,
        module = vehicle.module,
        side = side,
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

fn run_snippet(path: &Path, snippet: &str) -> Result<Option<String>> {
    let env: HashMap<String, String> =
        std::iter::once(("MIX_ENV".to_string(), "dev".to_string())).collect();
    let (code, stdout) = run_capture(
        &[
            "mix",
            "run",
            "--no-start",
            "--no-deps-check",
            "-e",
            snippet,
        ],
        path,
        &env,
    )?;
    if code == 0 {
        let trimmed = stdout.trim();
        return Ok(if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        });
    }
    retry_with_deps(path, snippet)
}

fn retry_with_deps(path: &Path, snippet: &str) -> Result<Option<String>> {
    let rel = path
        .strip_prefix(std::env::current_dir()?)
        .unwrap_or(path);
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
        &[
            "mix",
            "run",
            "--no-start",
            "--no-deps-check",
            "-e",
            snippet,
        ],
        path,
        &env,
    )?;
    if code == 0 {
        let trimmed = stdout.trim();
        return Ok(if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        });
    }
    Ok(None)
}
