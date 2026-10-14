use anyhow::{Context, Result};

use crate::firmware;
use crate::resolve_args::resolve_vehicle_role;
use crate::shell;
use crate::vehicles;

pub fn run(
    vehicle: Option<String>,
    role: Option<String>,
    host: Option<String>,
    file: Option<String>,
    build: bool,
) -> Result<()> {
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

    let host = host.unwrap_or_else(|| vehicles::host_for(&args.vehicle.dir, &args.role));
    // `upload.sh` runs in the firmware directory, so a relative path must be
    // resolved against the directory the user ran the command from.
    let file = file
        .map(|path| std::path::absolute(&path))
        .transpose()
        .context("resolving --file")?
        .map(|path| path.to_string_lossy().into_owned());
    let mut argv: Vec<&str> = vec!["./upload.sh", &host];
    if let Some(ref file) = file {
        argv.push(file);
    }
    shell::run(&argv, &opts)
}
