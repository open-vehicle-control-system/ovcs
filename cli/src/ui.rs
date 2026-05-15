//! Shared status-line helpers for CLI commands.
//!
//! All user-facing commands print progress using the same four symbols so
//! that the output reads the same way across `run`, `attach`, `can`,
//! `doctor`, etc. Stick to these helpers in new commands rather than
//! rolling your own formatting.
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

/// Top-level phase heading — cyan bold arrow prefix.
pub fn step(msg: &str) {
    println!("{} {}", "▸".cyan().bold(), msg);
}

/// Neutral sub-step — dimmed middle dot. Use for "doing X" info.
pub fn sub(msg: &str) {
    println!("  {} {}", "·".dimmed(), msg);
}

/// Sub-step that succeeded — green check.
pub fn sub_ok(msg: &str) {
    println!("  {} {}", "✓".green(), msg);
}

/// Sub-step that didn't find what it was looking for, but that's not a
/// hard error (e.g. a probe that didn't respond, an optional component
/// a vehicle doesn't declare).
pub fn sub_miss(msg: &str) {
    println!("  {} {}", "✗".yellow(), msg);
}

/// Sub-step that produced a soft warning — yellow triangle.
pub fn sub_warn(msg: &str) {
    println!("  {} {}", "⚠".yellow(), msg);
}

/// Sub-step that hard-failed — red cross.
pub fn sub_fail(msg: &str) {
    println!("  {} {}", "✗".red(), msg);
}
