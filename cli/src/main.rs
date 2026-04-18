use anyhow::Result;
use clap::{Parser, Subcommand};

mod commands;
mod firmware;
mod prompt;
mod repo_root;
mod resolve_args;
mod shell;
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
    /// bridge) against a VMS-hosted localhost mosquitto, mirroring the
    /// deployed topology. Attach with `./ovcs attach` from another
    /// terminal for logs + IEx.
    Run { vehicle: Option<String> },
    /// Attach a split TUI (merged per-node logs + IEx shell) to a running
    /// vehicle — either the local dev BEAM or the N deployed Nerves devices.
    Attach { vehicle: Option<String> },
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
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Vehicles => commands::vehicles::run(),
        Commands::Doctor => commands::doctor::run(),
        Commands::Build { first, second } => commands::build::run(first, second),
        Commands::Burn { first, second } => commands::burn::run(first, second),
        Commands::Clean { first, second } => commands::clean::run(first, second),
        Commands::Upload {
            host,
            file,
            first,
            second,
        } => commands::upload::run(first, second, host, file),
        Commands::Can { action } => match action {
            CanAction::Setup { vehicle } => commands::can::setup(vehicle),
            CanAction::Status { vehicle } => commands::can::status(vehicle),
        },
        Commands::Vehicle { action } => match action {
            VehicleAction::New {
                name,
                vms_target,
                infotainment_target,
                no_infotainment,
            } => commands::vehicle_new::run(name, vms_target, infotainment_target, no_infotainment),
        },
        Commands::Run { vehicle } => commands::run::run(vehicle),
        Commands::Attach { vehicle } => commands::attach::run(vehicle),
    }
}
