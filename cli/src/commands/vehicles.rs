use anyhow::Result;
use owo_colors::OwoColorize;

use crate::repo_root::repo_root;
use crate::ui::step;
use crate::vehicles::{self, bridge_firmwares, nerves_target};

pub fn run() -> Result<()> {
    let root = repo_root()?;
    let list = vehicles::list(&root)?;
    step("Discovered vehicles:");
    println!();
    for vehicle in &list {
        println!("  {}  ({})", vehicle.dir.cyan(), vehicle.module);
        let vms_target = nerves_target(vehicle, "vms")?.unwrap_or_else(|| "—".to_string());
        let infotainment_target =
            nerves_target(vehicle, "infotainment")?.unwrap_or_else(|| "—".to_string());
        println!("    vms          → {}", vms_target);
        println!("    infotainment → {}", infotainment_target);
        if let Some(vision_target) = nerves_target(vehicle, "vision")? {
            println!("    vision       → {}", vision_target);
        }

        let bridges = bridge_firmwares(vehicle).unwrap_or_default();
        if !bridges.is_empty() {
            let mut entries: Vec<(String, String)> = bridges
                .into_iter()
                .map(|(id, bridge)| (id, bridge.target))
                .collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            println!("    bridges");
            for (id, target) in entries {
                println!("      {}  → {}", id.cyan(), target);
            }
        }

        println!();
    }
    Ok(())
}
