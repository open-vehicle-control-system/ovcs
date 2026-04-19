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
/// application picker, where each option is just a name). The richer
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

/// Richer vehicle picker — centered title, per-vehicle row with module
/// atom, snake_case dir, and the nerves target for each side when we
/// know it.
pub fn choose_vehicle(vehicles: &[Vehicle]) -> Result<Vehicle> {
    if vehicles.is_empty() {
        eprintln!(
            "{}",
            "No vehicles found under vehicles/. Create one with `./ovcs vehicle new <name>`.".red()
        );
        std::process::exit(1);
    }
    ensure_tty_or_exit("vehicle");

    let items: Vec<VehicleItem> = vehicles
        .iter()
        .map(|v| VehicleItem {
            dir: v.dir.clone(),
            module: v.module.clone(),
            vms_target: crate::vehicles::nerves_target(v, "vms").ok().flatten(),
            info_target: crate::vehicles::nerves_target(v, "infotainment")
                .ok()
                .flatten(),
        })
        .collect();

    let (result, mut terminal) = with_terminal(|term| run_vehicle_picker(term, &items))?;
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
                    Style::default().fg(Color::DarkGray),
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

struct VehicleItem {
    dir: String,
    module: String,
    vms_target: Option<String>,
    info_target: Option<String>,
}

fn run_vehicle_picker(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    items: &[VehicleItem],
) -> Result<Option<usize>> {
    let mut state = ListState::default();
    state.select(Some(0));

    // Each vehicle row takes 4 lines (module, dir, vms target, info
    // target). ratatui's List renders one ListItem as one "logical" row
    // but the item itself can be multi-line — we construct it as such.
    const ROW_LINES: u16 = 4;
    const ROW_GAP: u16 = 1;

    loop {
        terminal.draw(|f| {
            let outer_area = f.area();

            // Centered content pane — ~80 wide or terminal width, whichever
            // is smaller. Height auto from item count + chrome.
            let content_width: u16 = 78;
            let items_height =
                (items.len() as u16) * ROW_LINES + (items.len() as u16).saturating_sub(1) * ROW_GAP;
            let chrome_height: u16 = 9; // title stack + footer + padding
            let total_height = items_height + chrome_height;
            let area = centered(outer_area, content_width, total_height);

            let outer = Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(ACCENT))
                .padding(Padding::new(2, 2, 1, 1));
            let inner = outer.inner(area);
            f.render_widget(outer, area);

            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(1),
                    Constraint::Length(1),
                    Constraint::Length(1),
                    Constraint::Min(1),
                    Constraint::Length(1),
                ])
                .split(inner);

            // Title: big OVCS wordmark + tagline
            f.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(
                        "OVCS",
                        Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
                    ),
                    Span::raw("  "),
                    Span::styled(
                        "select a vehicle",
                        Style::default()
                            .fg(Color::White)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]))
                .alignment(Alignment::Center),
                rows[0],
            );

            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!(
                        "{} vehicle{} discovered under vehicles/",
                        items.len(),
                        if items.len() == 1 { "" } else { "s" }
                    ),
                    Style::default().fg(Color::DarkGray),
                )))
                .alignment(Alignment::Center),
                rows[1],
            );

            // Blank spacer
            f.render_widget(Paragraph::new(""), rows[2]);

            // Items list
            let list_items: Vec<ListItem> = items
                .iter()
                .map(|v| {
                    let module_line = Line::from(vec![
                        Span::styled(
                            &v.module,
                            Style::default()
                                .fg(Color::White)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::raw("  "),
                        Span::styled(format!("({})", v.dir), Style::default().fg(Color::DarkGray)),
                    ]);
                    let vms_line = row_detail("vms", v.vms_target.as_deref());
                    let info_line = row_detail("infotainment", v.info_target.as_deref());
                    let gap = Line::from("");
                    ListItem::new(vec![module_line, vms_line, info_line, gap])
                })
                .collect();

            let list = List::new(list_items)
                .highlight_style(
                    Style::default()
                        .bg(Color::Rgb(30, 30, 30))
                        .add_modifier(Modifier::BOLD),
                )
                .highlight_symbol("▌ ");
            f.render_stateful_widget(list, rows[3], &mut state);

            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↑↓ navigate   ⏎ select   q / Esc cancel",
                    Style::default().fg(Color::DarkGray),
                )))
                .alignment(Alignment::Center),
                rows[4],
            );
        })?;

        if let Some(evt) = read_nav()? {
            match evt {
                Nav::Up => {
                    let len = items.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some(if i == 0 { len - 1 } else { i - 1 }));
                }
                Nav::Down => {
                    let len = items.len();
                    let i = state.selected().unwrap_or(0);
                    state.select(Some((i + 1) % len));
                }
                Nav::Home => state.select(Some(0)),
                Nav::End => state.select(Some(items.len() - 1)),
                Nav::Enter => return Ok(state.selected()),
                Nav::Cancel => return Ok(None),
            }
        }
    }
}

fn row_detail(label: &str, target: Option<&str>) -> Line<'static> {
    Line::from(vec![
        Span::raw("   "),
        Span::styled(
            format!("{:<13}", label),
            Style::default().fg(Color::DarkGray),
        ),
        Span::styled("→ ", Style::default().fg(Color::DarkGray)),
        match target {
            Some(t) => Span::styled(t.to_string(), Style::default().fg(ACCENT)),
            None => Span::styled("—", Style::default().fg(Color::DarkGray)),
        },
    ])
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
