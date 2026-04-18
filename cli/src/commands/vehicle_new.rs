use anyhow::Result;
use owo_colors::OwoColorize;
use regex::Regex;
use std::path::Path;
use std::process::Command;

use crate::repo_root::repo_root;
use crate::vehicles::module_for;

pub fn run(
    name: String,
    vms_target: String,
    infotainment_target: String,
    no_infotainment: bool,
) -> Result<()> {
    let name_pat = Regex::new(r"^[a-z][a-z0-9_]*$").unwrap();
    let target_pat = Regex::new(r"^[a-z][a-z0-9_]*$").unwrap();

    let raw = name.trim().to_lowercase();
    if !name_pat.is_match(&raw) {
        eprintln!(
            "{}",
            format!(
                "Invalid vehicle name {:?}; use snake_case (e.g. my_vehicle).",
                raw
            )
            .red()
        );
        std::process::exit(1);
    }
    let vms = validate_target(&target_pat, &vms_target, "--vms-target");
    let infotainment = !no_infotainment;
    let info = if infotainment {
        Some(validate_target(
            &target_pat,
            &infotainment_target,
            "--infotainment-target",
        ))
    } else {
        None
    };

    let root = repo_root()?;
    let target_dir = root.join("vehicles").join(&raw);
    let ovcs_vehicle_dir = root.join("libraries").join("ovcs_vehicle");
    if !ovcs_vehicle_dir.exists() {
        eprintln!(
            "{}",
            "libraries/ovcs_vehicle not found. Did you run `mise run libraries`?".red()
        );
        std::process::exit(1);
    }

    let module = module_for(&raw);
    let info_el = match &info {
        Some(t) => el_string(t),
        None => "nil".to_string(),
    };
    let assigns = format!(
        "module: {}, name: {}, upper: {}, vms_target: {}, infotainment_target: {}, infotainment: {}",
        el_string(&module),
        el_string(&raw),
        el_string(&raw.to_uppercase()),
        el_string(&vms),
        info_el,
        if infotainment { "true" } else { "false" },
    );

    let snippet = format!(
        r##"
case OvcsVehicle.Scaffold.generate({dir}, [{assigns}], repo_root: {root}) do
  :ok -> :ok
  {{:error, {{:template_missing, path}}}} ->
    IO.write(:stderr, "TEMPLATE_MISSING:" <> path)
    System.halt(2)
end
"##,
        dir = el_string(target_dir.to_str().unwrap()),
        assigns = assigns,
        root = el_string(root.to_str().unwrap()),
    );

    let out = Command::new("mix")
        .args(["run", "--no-start", "-e", &snippet])
        .current_dir(&ovcs_vehicle_dir)
        .env("MIX_ENV", "dev")
        .output()?;

    if !out.status.success() {
        let combined = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if let Some(idx) = combined.find("TEMPLATE_MISSING:") {
            let path = combined[idx + "TEMPLATE_MISSING:".len()..].trim();
            eprintln!(
                "{}",
                format!("Template missing: {} (recompile ovcs_vehicle)", path).red()
            );
        } else {
            eprintln!("{}", combined.red());
        }
        std::process::exit(1);
    }

    let rel = target_dir
        .strip_prefix(&root)
        .unwrap_or(&target_dir)
        .to_path_buf();
    println!("{}", format!("Scaffolded {}", rel.display()).green());
    println!();
    println!("Targets:");
    println!("  vms          → {}", vms);
    println!(
        "  infotainment → {}",
        info.as_deref().unwrap_or("(skipped)")
    );

    warn_missing_firmware(&root, "vms", &vms)?;
    if let Some(t) = &info {
        warn_missing_firmware(&root, "infotainment", t)?;
    }

    println!();
    println!("Next steps:");
    println!("  ./ovcs build {} vms         # build VMS firmware", raw);
    if info.is_some() {
        println!(
            "  ./ovcs build {} infotainment # build infotainment firmware",
            raw
        );
    }
    println!(
        "  ./ovcs can setup {}         # provision host vcan interfaces",
        raw
    );
    println!();
    println!(
        "Then review lib/{}.ex and composers; prune components and",
        raw
    );
    println!(
        "CAN configs you don't need. See {}/README.md for details.",
        rel.display()
    );
    Ok(())
}

fn validate_target(pat: &Regex, value: &str, flag: &str) -> String {
    let t = value.trim().to_string();
    if !pat.is_match(&t) {
        eprintln!(
            "{}",
            format!(
                "Invalid {} value {:?}; expected a Nerves target atom name like ovcs_base_can_system_rpi4.",
                flag, t
            )
            .red()
        );
        std::process::exit(1);
    }
    t
}

fn warn_missing_firmware(root: &Path, side: &str, target: &str) -> Result<()> {
    let snippet = format!(
        r##"IO.write(OvcsVehicle.Scaffold.firmware_defaults_dir({root}, :{side}, :{target}))"##,
        root = el_string(root.to_str().unwrap()),
        side = side,
        target = target,
    );
    let out = Command::new("mix")
        .args(["run", "--no-start", "--no-deps-check", "-e", &snippet])
        .current_dir(root.join("libraries").join("ovcs_vehicle"))
        .env("MIX_ENV", "dev")
        .stderr(std::process::Stdio::null())
        .output()?;
    if !out.status.success() {
        return Ok(());
    }
    let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if dir.is_empty() || Path::new(&dir).exists() {
        return Ok(());
    }
    let rel = Path::new(&dir)
        .strip_prefix(root)
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| dir.clone());
    println!();
    println!(
        "{}",
        format!(
            "Note: no firmware defaults for {side} target {target} at {rel}.\n      priv/firmware/{side}/ was not populated — seed one by dropping\n      fwup.conf + config.txt in there, or add them to the shared\n      target dir so future scaffolds pick them up.",
            side = side,
            target = target,
            rel = rel
        )
        .yellow()
    );
    Ok(())
}

fn el_string(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}
