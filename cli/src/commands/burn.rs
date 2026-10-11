use anyhow::Result;

use crate::firmware;
use crate::resolve_args::resolve_vehicle_role;
use crate::shell;

pub fn run(vehicle: Option<String>, role: Option<String>, build: bool) -> Result<()> {
    let args = resolve_vehicle_role(vehicle, role)?;
    let role_firmware = firmware::resolve(&args.vehicle, &args.role)?;
    let cwd = args.repo_root.join(&role_firmware.firmware_dir);
    let opts = shell::RunOpts {
        cwd: &cwd,
        env: &role_firmware.env,
    };

    if build {
        shell::run(&["./build.sh"], &opts)?;
    }
    shell::run(&["./burn.sh"], &opts)
}
