use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use owo_colors::OwoColorize;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, List, ListItem, ListState, Padding, Paragraph};
use ratatui::Terminal;
use std::io::{self, IsTerminal, Stdout};

use crate::terminal;
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
        Some(choice) => Ok(choice),
        None => aborted(),
    }
}

/// Vehicle picker — centered title, one row per vehicle (module atom +
/// snake_case dir). It shows only what `vehicles::list` already globbed:
/// probing Nerves targets would boot Mix per vehicle before it could draw.
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
        Some(index) => Ok(vehicles[index].clone()),
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

fn with_terminal<T, F>(picker: F) -> Result<(T, Terminal<CrosstermBackend<Stdout>>)>
where
    F: FnOnce(&mut Terminal<CrosstermBackend<Stdout>>) -> T,
{
    let mut terminal = terminal::enter(false)?;
    let picked = picker(&mut terminal);
    Ok((picked, terminal))
}

fn teardown(_terminal: &mut Terminal<CrosstermBackend<Stdout>>) {
    terminal::restore();
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
        terminal.draw(|frame| {
            let area = centered(frame.area(), 60, choices.len() as u16 + 6);

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
            frame.render_widget(outer, area);

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
            frame.render_stateful_widget(list, rows[0], &mut state);

            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↑↓ navigate   ⏎ select   q / Esc cancel",
                    dim(),
                )))
                .alignment(Alignment::Center),
                rows[1],
            );
        })?;

        if let Some(navigation) = read_nav()? {
            match navigation {
                Nav::Up => {
                    let len = choices.len();
                    let selected = state.selected().unwrap_or(0);
                    state.select(Some(if selected == 0 { len - 1 } else { selected - 1 }));
                }
                Nav::Down => {
                    let len = choices.len();
                    let selected = state.selected().unwrap_or(0);
                    state.select(Some((selected + 1) % len));
                }
                Nav::Home => state.select(Some(0)),
                Nav::End => state.select(Some(choices.len() - 1)),
                Nav::Enter => {
                    let selected = state.selected().unwrap_or(0);
                    return Ok(Some(choices[selected].clone()));
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
        terminal.draw(|frame| {
            let outer_area = frame.area();

            // One line per vehicle, two borders and the footer.
            let content_width = outer_area.width.saturating_sub(4).min(60);
            let total_height = vehicles.len() as u16 + 3;
            let area = centered(outer_area, content_width, total_height);

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
            frame.render_widget(outer, area);

            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(1), Constraint::Length(1)])
                .split(inner);

            let list_items: Vec<ListItem> = vehicles
                .iter()
                .map(|vehicle| {
                    ListItem::new(Line::from(vec![
                        Span::styled(
                            vehicle.module.clone(),
                            Style::default().add_modifier(Modifier::BOLD),
                        ),
                        Span::raw("  "),
                        Span::styled(format!("({})", vehicle.dir), dim()),
                    ]))
                })
                .collect();

            let list = List::new(list_items)
                .highlight_style(Style::default().add_modifier(Modifier::BOLD))
                .highlight_symbol(" ▌ ");
            frame.render_stateful_widget(list, rows[0], &mut state);

            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↑↓ navigate   ⏎ select   q / Esc cancel",
                    dim(),
                )))
                .alignment(Alignment::Center),
                rows[1],
            );
        })?;

        if let Some(navigation) = read_nav()? {
            match navigation {
                Nav::Up => {
                    let len = vehicles.len();
                    let selected = state.selected().unwrap_or(0);
                    state.select(Some(if selected == 0 { len - 1 } else { selected - 1 }));
                }
                Nav::Down => {
                    let len = vehicles.len();
                    let selected = state.selected().unwrap_or(0);
                    state.select(Some((selected + 1) % len));
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
    let width = width.min(outer.width);
    let height = height.min(outer.height);
    Rect {
        x: outer.x + (outer.width.saturating_sub(width)) / 2,
        y: outer.y + (outer.height.saturating_sub(height)) / 2,
        width,
        height,
    }
}
