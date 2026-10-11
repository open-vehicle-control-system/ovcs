use anyhow::{bail, Context, Result};
use owo_colors::OwoColorize;
use regex::Regex;
use std::path::Path;
use std::process::Command;

use crate::repo_root::repo_root;
use crate::ui::{step, sub};
use crate::vehicles::module_for;

pub fn run(
    name: String,
    vms_target: String,
    infotainment_target: String,
    no_infotainment: bool,
    no_bridges: bool,
    display_name: Option<String>,
) -> Result<()> {
    let name_pattern = Regex::new(r"^[a-z][a-z0-9_]*$").unwrap();
    let target_pattern = Regex::new(r"^[a-z][a-z0-9_]*$").unwrap();

    let vehicle_dir = name.trim().to_lowercase();
    if !name_pattern.is_match(&vehicle_dir) {
        eprintln!(
            "{}",
            format!(
                "Invalid vehicle name {:?}; use snake_case (e.g. my_vehicle).",
                vehicle_dir
            )
            .red()
        );
        std::process::exit(1);
    }
    let vms_target = validate_target(&target_pattern, &vms_target, "--vms-target");
    let infotainment = !no_infotainment;
    let infotainment_target = if infotainment {
        Some(validate_target(
            &target_pattern,
            &infotainment_target,
            "--infotainment-target",
        ))
    } else {
        None
    };

    let root = repo_root()?;
    let target_dir = root.join("vehicles").join(&vehicle_dir);
    let ovcs_vehicle_dir = root.join("libraries").join("ovcs_vehicle");
    if !ovcs_vehicle_dir.exists() {
        eprintln!(
            "{}",
            "libraries/ovcs_vehicle not found. Did you run `mise run libraries`?".red()
        );
        std::process::exit(1);
    }

    if target_dir.exists() {
        eprintln!(
            "{}",
            format!(
                "vehicles/{} already exists; pick another name.",
                vehicle_dir
            )
            .red()
        );
        std::process::exit(1);
    }

    let module = module_for(&vehicle_dir);
    let module_dir = directory_for_module(&module)?;
    if module_dir != vehicle_dir {
        eprintln!(
            "{}",
            format!(
                "Invalid vehicle name {:?}: its module {} maps back to the directory {:?}, \
                 which is where the firmware would look. Use {:?} instead.",
                vehicle_dir, module, module_dir, module_dir
            )
            .red()
        );
        std::process::exit(1);
    }
    let display_name = display_name
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| default_display_name(&vehicle_dir));
    if display_name.contains(['"', '\\']) || display_name.contains("#{") {
        eprintln!(
            "{}",
            format!(
                "Invalid display name {:?}: it goes into Elixir strings as is, so it may not \
                 contain `\"`, `\\` or `#{{`.",
                display_name
            )
            .red()
        );
        std::process::exit(1);
    }
    let bridges = !no_bridges;
    let infotainment_target_literal = match &infotainment_target {
        Some(target) => el_string(target),
        None => "nil".to_string(),
    };
    let assigns = format!(
        "module: {}, name: {}, display_name: {}, vms_target: {}, infotainment_target: {}, infotainment: {}, bridges: {}",
        el_string(&module),
        el_string(&vehicle_dir),
        el_string(&display_name),
        el_string(&vms_target),
        infotainment_target_literal,
        if infotainment { "true" } else { "false" },
        if bridges { "true" } else { "false" },
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

    let output = Command::new("mix")
        .args(["run", "--no-start", "--no-deps-check", "-e", &snippet])
        .current_dir(&ovcs_vehicle_dir)
        .env("MIX_ENV", "dev")
        .output()?;

    if !output.status.success() {
        let combined = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        if let Some(index) = combined.find("TEMPLATE_MISSING:") {
            let path = combined[index + "TEMPLATE_MISSING:".len()..].trim();
            eprintln!(
                "{}",
                format!("Template missing: {} (recompile ovcs_vehicle)", path).red()
            );
        } else {
            eprintln!("{}", combined.red());
        }
        std::process::exit(1);
    }

    let relative_dir = target_dir
        .strip_prefix(&root)
        .unwrap_or(&target_dir)
        .to_path_buf();
    println!();
    step(&format!("Scaffolded {}", relative_dir.display()));
    sub(&format!("vms          → {}", vms_target));
    sub(&format!(
        "infotainment → {}",
        infotainment_target.as_deref().unwrap_or("(skipped)")
    ));

    warn_missing_firmware(&root, "vms", &vms_target)?;
    if let Some(target) = &infotainment_target {
        warn_missing_firmware(&root, "infotainment", target)?;
    }

    println!();
    step("Next steps:");
    // `run` brings up the host vcan interfaces itself, so no `can setup` step.
    sub(&format!("./ovcs run {}", vehicle_dir));
    sub(&format!("./ovcs build {} vms", vehicle_dir));
    if infotainment_target.is_some() {
        sub(&format!("./ovcs build {} infotainment", vehicle_dir));
    }
    println!();
    println!(
        "Then review lib/{}.ex and composers; prune components and",
        vehicle_dir
    );
    println!(
        "CAN configs you don't need. See {}/README.md for details.",
        relative_dir.display()
    );
    Ok(())
}

fn validate_target(pattern: &Regex, value: &str, flag: &str) -> String {
    let target = value.trim().to_string();
    if !pattern.is_match(&target) {
        eprintln!(
            "{}",
            format!(
                "Invalid {} value {:?}; expected a Nerves target atom name like ovcs_base_can_system_rpi4.",
                flag, target
            )
            .red()
        );
        std::process::exit(1);
    }
    target
}

fn warn_missing_firmware(root: &Path, side: &str, target: &str) -> Result<()> {
    let snippet = format!(
        r##"IO.write(OvcsVehicle.Scaffold.firmware_defaults_dir({root}, :{side}, :{target}))"##,
        root = el_string(root.to_str().unwrap()),
        side = side,
        target = target,
    );
    let output = Command::new("mix")
        .args(["run", "--no-start", "--no-deps-check", "-e", &snippet])
        .current_dir(root.join("libraries").join("ovcs_vehicle"))
        .env("MIX_ENV", "dev")
        .stderr(std::process::Stdio::null())
        .output()?;
    if !output.status.success() {
        return Ok(());
    }
    let dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if dir.is_empty() || Path::new(&dir).exists() {
        return Ok(());
    }
    let relative_dir = Path::new(&dir)
        .strip_prefix(root)
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| dir.clone());
    println!();
    println!(
        "{}",
        format!(
            "Note: no firmware defaults for {side} target {target} at {relative_dir}.\n      priv/firmware/{side}/ was not populated. Add fwup.conf, config.txt,\n      cmdline-a.txt and cmdline-b.txt to that shared target dir (or put\n      all four in priv/firmware/{side}/) before building an image.",
            side = side,
            target = target,
            relative_dir = relative_dir
        )
        .yellow()
    );
    Ok(())
}

/// `text` as an Elixir string literal; `#` is escaped so `#{…}` is not
/// interpolated.
fn el_string(text: &str) -> String {
    format!(
        "\"{}\"",
        text.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('#', "\\#")
    )
}

/// The directory the firmware derives from a vehicle module with
/// `Macro.underscore/1`, asked of Elixir itself.
fn directory_for_module(module: &str) -> Result<String> {
    let output = Command::new("elixir")
        .args([
            "-e",
            &format!("IO.write(Macro.underscore({}))", el_string(module)),
        ])
        .output()
        .context("failed to spawn elixir")?;
    if !output.status.success() {
        bail!(
            "elixir could not underscore {}: {}",
            module,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn default_display_name(snake: &str) -> String {
    snake
        .split('_')
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::el_string;

    #[test]
    fn el_string_escapes_quotes_backslashes_and_interpolation() {
        assert_eq!(el_string("plain"), "\"plain\"");
        assert_eq!(el_string(r#"a "b" \ #{c}"#), r#""a \"b\" \\ \#{c}""#);
    }
}
