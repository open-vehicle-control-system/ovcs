//! Shared status-line helpers for CLI commands.
//!
//! User-facing commands print progress through these helpers so the output
//! reads the same way across `run`, `attach`, `can`, `doctor`, etc.
//!
//! | helper      | symbol | meaning                                     |
//! |-------------|--------|---------------------------------------------|
//! | [`step`]    | `▸`    | top-level phase heading                     |
//! | [`sub`]     | `·`    | neutral sub-step detail                     |
//! | [`sub_ok`]  | `✓`    | sub-step that succeeded                     |
//! | [`sub_miss`]| `✗`    | sub-step that found nothing (not an error)  |
//! | [`sub_warn`]| `⚠`    | sub-step that produced a soft warning       |
//! | [`sub_fail`]| `✗`    | sub-step that hard-failed                   |

use owo_colors::OwoColorize;

/// Top-level phase heading.
pub fn step(message: &str) {
    println!("{} {}", "▸".cyan().bold(), message);
}

/// Neutral sub-step, for "doing X" info.
pub fn sub(message: &str) {
    println!("  {} {}", "·".dimmed(), message);
}

/// Sub-step that succeeded.
pub fn sub_ok(message: &str) {
    println!("  {} {}", "✓".green(), message);
}

/// Sub-step that didn't find what it was looking for, but that's not a
/// hard error (e.g. a probe that didn't respond, an optional component
/// a vehicle doesn't declare).
pub fn sub_miss(message: &str) {
    println!("  {} {}", "✗".yellow(), message);
}

/// Sub-step that produced a soft warning.
pub fn sub_warn(message: &str) {
    println!("  {} {}", "⚠".yellow(), message);
}

/// Sub-step that hard-failed.
pub fn sub_fail(message: &str) {
    println!("  {} {}", "✗".red(), message);
}
