//! Taking over the terminal for a full-screen TUI, and giving it back.

use anyhow::Result;
use crossterm::cursor::Show;
use crossterm::event::{DisableMouseCapture, EnableMouseCapture};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io::{self, Stdout};
use std::sync::Once;

pub type Tui = Terminal<CrosstermBackend<Stdout>>;

/// Enters raw mode and the alternate screen, capturing the mouse if asked,
/// and installs a panic hook that restores the terminal: the release build
/// aborts on panic, so no destructor would run.
pub fn enter(mouse_capture: bool) -> Result<Tui> {
    install_restore_on_panic();
    let entered = (|| -> Result<Tui> {
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        stdout.execute(EnterAlternateScreen)?;
        if mouse_capture {
            stdout.execute(EnableMouseCapture)?;
        }
        Ok(Terminal::new(CrosstermBackend::new(stdout))?)
    })();
    if entered.is_err() {
        restore();
    }
    entered
}

/// Undoes everything `enter` may have set up; safe to call more than once.
pub fn restore() {
    let mut stdout = io::stdout();
    let _ = stdout.execute(DisableMouseCapture);
    let _ = disable_raw_mode();
    let _ = stdout.execute(LeaveAlternateScreen);
    let _ = stdout.execute(Show);
}

fn install_restore_on_panic() {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore();
            previous(info);
        }));
    });
}
