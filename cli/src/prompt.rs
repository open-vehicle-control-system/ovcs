use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use crossterm::ExecutableCommand;
use owo_colors::OwoColorize;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};
use std::io::{self, IsTerminal, Stdout};

/// Ratatui single-select picker. Exits the process with a clear error
/// when stdin is not a tty (piped/CI) so we never hang. Ctrl-C or `q`/Esc
/// exits with code 130 (aborted).
pub fn choose(label: &str, choices: &[String]) -> Result<String> {
    if choices.is_empty() {
        eprintln!("{}", "No options to choose from.".red());
        std::process::exit(1);
    }
    if !io::stdin().is_terminal() {
        eprintln!(
            "{}",
            format!(
                "{} not provided and stdin is not interactive. Pass it on the command line.",
                label
            )
            .red()
        );
        std::process::exit(2);
    }

    let mut stdout = io::stdout();
    enable_raw_mode()?;
    stdout.execute(EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;

    let result = run_picker(&mut terminal, label, choices);

    // Always clean up terminal state, even on error.
    let _ = disable_raw_mode();
    let _ = terminal.backend_mut().execute(LeaveAlternateScreen);
    let _ = terminal.show_cursor();

    match result? {
        Some(s) => Ok(s),
        None => {
            eprintln!("{}", "Aborted.".yellow());
            std::process::exit(130);
        }
    }
}

fn run_picker(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    label: &str,
    choices: &[String],
) -> Result<Option<String>> {
    let mut state = ListState::default();
    state.select(Some(0));
    let title = format!("Select {}:", label);

    loop {
        terminal.draw(|f| {
            let area = f.area();
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(1),
                    Constraint::Min(1),
                    Constraint::Length(1),
                ])
                .split(area);

            let header = Paragraph::new(Line::from(Span::styled(
                title.clone(),
                Style::default().add_modifier(Modifier::BOLD),
            )));
            f.render_widget(header, chunks[0]);

            let items: Vec<ListItem> = choices
                .iter()
                .map(|c| ListItem::new(Line::from(Span::raw(c.clone()))))
                .collect();
            let list = List::new(items)
                .block(Block::default().borders(Borders::NONE))
                .highlight_style(
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )
                .highlight_symbol("▶ ");
            f.render_stateful_widget(list, chunks[1], &mut state);

            let footer = Paragraph::new(Line::from(Span::styled(
                "↑↓ navigate  ⏎ select  q/Esc cancel",
                Style::default().fg(Color::DarkGray),
            )));
            f.render_widget(footer, chunks[2]);
        })?;

        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            let len = choices.len();
            match key.code {
                KeyCode::Up | KeyCode::Char('k') => {
                    let i = state.selected().unwrap_or(0);
                    state.select(Some(if i == 0 { len - 1 } else { i - 1 }));
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    let i = state.selected().unwrap_or(0);
                    state.select(Some((i + 1) % len));
                }
                KeyCode::Enter => {
                    let i = state.selected().unwrap_or(0);
                    return Ok(Some(choices[i].clone()));
                }
                KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    return Ok(None);
                }
                _ => {}
            }
        }
    }
}
