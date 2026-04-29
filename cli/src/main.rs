use anyhow::Result;
use clap::{Parser, Subcommand};

mod ansi;
mod commands;
mod firmware;
mod prompt;
mod repo_root;
mod resolve_args;
mod shell;
mod ui;
mod vehicles;

#[derive(Parser)]
#[command(
    name = "ovcs",
    version,
    about = "OVCS vehicle/firmware orchestrator",
    long_about = "Build, burn, upload, and inspect OVCS vehicle firmware."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List discovered vehicles and their Nerves targets
    Vehicles,
    /// Verify toolchain and vehicle packages
    Doctor,
    /// Build firmware for a vehicle/application
    Build {
        first: Option<String>,
        second: Option<String>,
    },
    /// Burn firmware to an SD card for a vehicle/application
    Burn {
        /// Build the firmware first, then burn (one-shot for fresh edits)
        #[arg(long)]
        build: bool,
        first: Option<String>,
        second: Option<String>,
    },
    /// Remove build artifacts for a vehicle/application
    Clean {
        first: Option<String>,
        second: Option<String>,
    },
    /// OTA-upload firmware to a running device
    Upload {
        /// Build the firmware first, then upload (one-shot for fresh edits)
        #[arg(long)]
        build: bool,
        /// Target host (default: <vehicle>-<application>.local)
        #[arg(long)]
        host: Option<String>,
        /// Custom .fw file to push
        #[arg(short = 'f', long)]
        file: Option<String>,
        first: Option<String>,
        second: Option<String>,
    },
    /// Host CAN helpers
    Can {
        #[command(subcommand)]
        action: CanAction,
    },
    /// Vehicle package helpers
    Vehicle {
        #[command(subcommand)]
        action: VehicleAction,
    },
    /// Provision vcan + boot one BEAM per role (vms, infotainment, each
    /// bridge), all joined by OvcsBus.Cluster (Erlang distribution),
    /// mirroring the deployed topology. Attach with `./ovcs attach`
    /// from another terminal for logs + IEx.
    Run { vehicle: Option<String> },
    /// Attach a split TUI (merged per-node logs + IEx shell) to a running
    /// vehicle — either the local dev BEAM or the N deployed Nerves devices.
    Attach { vehicle: Option<String> },
    /// Open an interactive IEx shell on a single deployed device over SSH.
    ///
    /// Targets the Nerves device's SSH-as-IEx login shell (requires the
    /// firmware to be flashed with `AUTHORIZED_SSH_KEYS`). For the
    /// multi-node split TUI with logs / bus / CAN panes, use `attach`.
    Connect {
        /// Override the target host (default: <vehicle>-<role>.local).
        /// Useful when mDNS isn't resolving and you know the device's IP.
        #[arg(long)]
        host: Option<String>,
        first: Option<String>,
        second: Option<String>,
    },
}

#[derive(Subcommand)]
enum CanAction {
    /// Create + bring up the vcan interfaces a vehicle needs
    Setup { vehicle: Option<String> },
    /// Report which vcan interfaces a vehicle needs and whether they're up
    Status { vehicle: Option<String> },
}

#[derive(Subcommand)]
enum VehicleAction {
    /// Generate persistent SSH host keys per firmware role so device
    /// identities stay stable across burns. Keys are gitignored under
    /// vehicles/<dir>/priv/host_keys/.
    HostKeys {
        /// Vehicle directory name (snake_case). Prompts if omitted.
        vehicle: Option<String>,
        /// Regenerate keys even if they already exist
        #[arg(long)]
        force: bool,
    },
    /// Scaffold a new vehicle package from the bundled template
    New {
        /// New vehicle directory name (snake_case)
        name: String,
        /// Nerves target system for the VMS firmware
        #[arg(long, default_value = "ovcs_base_can_system_rpi4")]
        vms_target: String,
        /// Nerves target system for the infotainment firmware
        #[arg(long, default_value = "ovcs_base_can_system_rpi5")]
        infotainment_target: String,
        /// Scaffold a VMS-only vehicle (skip the infotainment side)
        #[arg(long)]
        no_infotainment: bool,
        /// Skip the bridge_firmware dep (omit `bridge_firmwares/0`)
        #[arg(long)]
        no_bridges: bool,
        /// Human-readable display name (e.g. "OVCS Mini").
        /// Defaults to the snake_case name title-cased on `_`.
        #[arg(long)]
        display_name: Option<String>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Vehicles => commands::vehicles::run(),
        Commands::Doctor => commands::doctor::run(),
        Commands::Build { first, second } => commands::build::run(first, second),
        Commands::Burn {
            build,
            first,
            second,
        } => commands::burn::run(first, second, build),
        Commands::Clean { first, second } => commands::clean::run(first, second),
        Commands::Upload {
            build,
            host,
            file,
            first,
            second,
        } => commands::upload::run(first, second, host, file, build),
        Commands::Can { action } => match action {
            CanAction::Setup { vehicle } => commands::can::setup(vehicle),
            CanAction::Status { vehicle } => commands::can::status(vehicle),
        },
        Commands::Vehicle { action } => match action {
            VehicleAction::HostKeys { vehicle, force } => {
                commands::vehicle_host_keys::run(vehicle, force)
            }
            VehicleAction::New {
                name,
                vms_target,
                infotainment_target,
                no_infotainment,
                no_bridges,
                display_name,
            } => commands::vehicle_new::run(
                name,
                vms_target,
                infotainment_target,
                no_infotainment,
                no_bridges,
                display_name,
            ),
        },
        Commands::Run { vehicle } => commands::run::run(vehicle),
        Commands::Attach { vehicle } => commands::attach::run(vehicle),
        Commands::Connect {
            host,
            first,
            second,
        } => commands::connect::run(first, second, host),
    }
}
