use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use owo_colors::OwoColorize;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, List, ListItem, ListState, Padding, Paragraph};
use ratatui::Terminal;
use std::io::{self, IsTerminal, Stdout};

use crate::vehicles::Vehicle;

const ACCENT: Color = Color::Cyan;

/// Ratatui single-select picker for short plain-text lists (used by the
/// role picker, where each option is just a name). The richer
/// vehicle picker lives in `choose_vehicle`.
pub fn choose(label: &str, choices: &[String]) -> Result<String> {
    if choices.is_empty() {
        eprintln!("{}", "No options to choose from.".red());
        std::process::exit(1);
    }
    ensure_tty_or_exit(label);

    let (result, mut terminal) = with_terminal(|term| run_text_picker(term, label, choices))?;
    teardown(&mut terminal);

    match result? {
        Some(s) => Ok(s),
        None => aborted(),
    }
}

/// Vehicle picker — centered title, one row per vehicle (module atom +
/// snake_case dir). Deliberately metadata-free: it reads only what
/// `vehicles::list` already globbed, so it draws instantly. Probing each
/// vehicle's Nerves targets here would boot Mix several times per vehicle
/// (~2s each) before the picker could even appear; `./ovcs vehicles` is
/// the place for that detail.
pub fn choose_vehicle(vehicles: &[Vehicle]) -> Result<Vehicle> {
    if vehicles.is_empty() {
        eprintln!(
            "{}",
            "No vehicles found under vehicles/. Create one with `./ovcs new <name>`.".red()
        );
        std::process::exit(1);
    }
    ensure_tty_or_exit("vehicle");

    let (result, mut terminal) = with_terminal(|term| run_vehicle_picker(term, vehicles))?;
    teardown(&mut terminal);

    match result? {
        Some(idx) => Ok(vehicles[idx].clone()),
        None => aborted(),
    }
}

// ---------- shared plumbing ----------

fn ensure_tty_or_exit(label: &str) {
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
}

fn aborted() -> ! {
    eprintln!("{}", "Aborted.".yellow());
    std::process::exit(130);
}

fn with_terminal<T, F>(f: F) -> Result<(T, Terminal<CrosstermBackend<Stdout>>)>
where
    F: FnOnce(&mut Terminal<CrosstermBackend<Stdout>>) -> T,
{
    let mut stdout = io::stdout();
    enable_raw_mode()?;
    stdout.execute(EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;
    let result = f(&mut terminal);
    Ok((result, terminal))
}

fn teardown(terminal: &mut Terminal<CrosstermBackend<Stdout>>) {
    let _ = disable_raw_mode();
    let _ = terminal.backend_mut().execute(LeaveAlternateScreen);
    let _ = terminal.show_cursor();
}

// ---------- plain text picker ----------

fn run_text_picker(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    label: &str,
    choices: &[String],
) -> Result<Option<String>> {
    let mut state = ListState::default();
    state.select(Some(0));
    let title = format!("Select {}", label);

    loop {
        terminal.draw(|f| {
            let area = centered(f.area(), 60, choices.len() as u16 + 6);

            let outer = Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(ACCENT))
                .title(Line::from(vec![
                    Span::raw(" "),
                    Span::styled(title.clone(), Style::default().add_modifier(Modifier::BOLD)),
                    Span::raw(" "),
                ]))
                .padding(Padding::new(2, 2, 1, 1));
            let inner = outer.inner(area);
            f.render_widget(outer, area);

            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(1), Constraint::Length(1)])
                .split(inner);

            let items: Vec<ListItem> = choices
                .iter()
                .map(|c| ListItem::new(Line::from(Span::raw(c.clone()))))
                .collect();
            let list = List::new(items)
                .highlight_style(Style::default().fg(ACCENT).add_modifier(Modifier::BOLD))
                .highlight_symbol("▶ ");
            f.render_stateful_widget(list, rows[0], &mut state);

            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↑↓ navigate   ⏎ select   q / Esc cancel",
                    dim(),
                )))
                .alignment(Alignment::Center),
                rows[1],
            );
        })?;

        if let Some(evt) = read_nav()? {
            match evt {
                Nav::Up => {
                    let len = choices.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some(if i == 0 { len - 1 } else { i - 1 }));
                }
                Nav::Down => {
                    let len = choices.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some((i + 1) % len));
                }
                Nav::Home => state.select(Some(0)),
                Nav::End => state.select(Some(choices.len() - 1)),
                Nav::Enter => {
                    let i = state.selected().unwrap_or(0);
                    return Ok(Some(choices[i].clone()));
                }
                Nav::Cancel => return Ok(None),
            }
        }
    }
}

// ---------- vehicle picker ----------

fn run_vehicle_picker(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    vehicles: &[Vehicle],
) -> Result<Option<usize>> {
    let mut state = ListState::default();
    state.select(Some(0));

    loop {
        terminal.draw(|f| {
            let outer_area = f.area();

            // Pane up to 60 cols, shrunk to terminal width. One line per
            // vehicle + 2 border + 1 footer.
            let content_width = outer_area.width.saturating_sub(4).min(60);
            let total_height = vehicles.len() as u16 + 3;
            let area = centered(outer_area, content_width, total_height);

            // Title lives on the border itself, centered.
            let title = Line::from(vec![
                Span::raw(" "),
                Span::styled(
                    "OVCS",
                    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
                ),
                Span::raw("  ·  "),
                Span::styled(
                    "select a vehicle",
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw(" "),
            ]);

            let outer = Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(ACCENT))
                .title(title)
                .title_alignment(Alignment::Center)
                .padding(Padding::new(2, 2, 0, 0));
            let inner = outer.inner(area);
            f.render_widget(outer, area);

            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(1), Constraint::Length(1)])
                .split(inner);

            let list_items: Vec<ListItem> = vehicles
                .iter()
                .map(|v| {
                    ListItem::new(Line::from(vec![
                        Span::styled(
                            v.module.clone(),
                            Style::default().add_modifier(Modifier::BOLD),
                        ),
                        Span::raw("  "),
                        Span::styled(format!("({})", v.dir), dim()),
                    ]))
                })
                .collect();

            let list = List::new(list_items)
                .highlight_style(Style::default().add_modifier(Modifier::BOLD))
                .highlight_symbol(" ▌ ");
            f.render_stateful_widget(list, rows[0], &mut state);

            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↑↓ navigate   ⏎ select   q / Esc cancel",
                    dim(),
                )))
                .alignment(Alignment::Center),
                rows[1],
            );
        })?;

        if let Some(evt) = read_nav()? {
            match evt {
                Nav::Up => {
                    let len = vehicles.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some(if i == 0 { len - 1 } else { i - 1 }));
                }
                Nav::Down => {
                    let len = vehicles.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some((i + 1) % len));
                }
                Nav::Home => state.select(Some(0)),
                Nav::End => state.select(Some(vehicles.len() - 1)),
                Nav::Enter => return Ok(state.selected()),
                Nav::Cancel => return Ok(None),
            }
        }
    }
}

/// Terminal-default foreground with the `DIM` attribute — readable on
/// both light and dark terminals, unlike `Color::DarkGray` which
/// disappears on dark backgrounds.
fn dim() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

// ---------- shared input handling ----------

enum Nav {
    Up,
    Down,
    Home,
    End,
    Enter,
    Cancel,
}

fn read_nav() -> Result<Option<Nav>> {
    let Event::Key(key) = event::read()? else {
        return Ok(None);
    };
    if key.kind != KeyEventKind::Press {
        return Ok(None);
    }
    Ok(match key.code {
        KeyCode::Up | KeyCode::Char('k') => Some(Nav::Up),
        KeyCode::Down | KeyCode::Char('j') => Some(Nav::Down),
        KeyCode::Home | KeyCode::Char('g') => Some(Nav::Home),
        KeyCode::End | KeyCode::Char('G') => Some(Nav::End),
        KeyCode::Enter => Some(Nav::Enter),
        KeyCode::Char('q') | KeyCode::Esc => Some(Nav::Cancel),
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => Some(Nav::Cancel),
        _ => None,
    })
}

/// Centered sub-rect inside `outer`, clamped to the outer's extent.
fn centered(outer: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(outer.width);
    let h = height.min(outer.height);
    Rect {
        x: outer.x + (outer.width.saturating_sub(w)) / 2,
        y: outer.y + (outer.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}
