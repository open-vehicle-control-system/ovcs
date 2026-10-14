use anyhow::Result;

use crate::firmware;
use crate::resolve_args::resolve_vehicle_role;
use crate::shell;

pub fn run(vehicle: Option<String>, role: Option<String>) -> Result<()> {
    let args = resolve_vehicle_role(vehicle, role)?;
    let role_firmware = firmware::resolve(&args.vehicle, &args.role)?;
    let cwd = args.repo_root.join(&role_firmware.firmware_dir);
    shell::run(
        &["./clean.sh"],
        &shell::RunOpts {
            cwd: &cwd,
            env: &role_firmware.env,
        },
    )
}
