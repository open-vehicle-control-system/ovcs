use anyhow::Result;
use ansi_to_tui::IntoText;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use crossterm::ExecutableCommand;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use regex::Regex;
use std::collections::VecDeque;
use std::io::{self, Stdout, Write};
use std::process::ChildStdin;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::time::Duration;

const LOG_CAP: usize = 4000;
const SHELL_CAP: usize = 2000;
const HISTORY_CAP: usize = 500;

pub enum Msg {
    LogLine(String),
    ShellLine(String),
    AppExited,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Focus {
    Log,
    Shell,
}

struct State {
    logs: VecDeque<Line<'static>>,
    shell_out: VecDeque<Line<'static>>,
    input: String,
    cursor: usize,
    history: Vec<String>,
    history_idx: Option<usize>,
    focus: Focus,
    log_scroll: u16,
    log_follow: bool,
    shell_scroll: u16,
    shell_follow: bool,
    app_exited: bool,
    quit: bool,
    node: String,
    prompt_re: Regex,
}

impl State {
    fn new(node: String) -> Self {
        Self {
            logs: VecDeque::with_capacity(LOG_CAP),
            shell_out: VecDeque::with_capacity(SHELL_CAP),
            input: String::new(),
            cursor: 0,
            history: Vec::new(),
            history_idx: None,
            focus: Focus::Shell,
            log_scroll: 0,
            log_follow: true,
            shell_scroll: 0,
            shell_follow: true,
            app_exited: false,
            quit: false,
            node,
            prompt_re: Regex::new(r"^(iex|\.{3})\(\d+\)>\s?").unwrap(),
        }
    }

    fn push_log(&mut self, raw: String) {
        if self.logs.len() == LOG_CAP {
            self.logs.pop_front();
        }
        self.logs.push_back(parse_ansi_line(&raw));
    }

    fn push_shell(&mut self, raw: String) {
        // Strip iex prompt prefixes (we echo our own "❯ " for typed input).
        let cleaned = self.prompt_re.replace(&raw, "").into_owned();
        if self.shell_out.len() == SHELL_CAP {
            self.shell_out.pop_front();
        }
        self.shell_out.push_back(parse_ansi_line(&cleaned));
    }

    fn push_shell_echo(&mut self, line: Line<'static>) {
        if self.shell_out.len() == SHELL_CAP {
            self.shell_out.pop_front();
        }
        self.shell_out.push_back(line);
    }
}

/// Parse a byte string containing ANSI escape sequences into a single styled
/// `Line`. Strips terminal escapes we don't understand, and carriage returns
/// which otherwise render as column-reset glitches inside Ratatui. Falls back
/// to a raw plain-text Line on parse failure.
fn parse_ansi_line(raw: &str) -> Line<'static> {
    // CR without LF (progress bars, spinners) would move the cursor to column 0
    // in a real terminal; Ratatui doesn't honor that, so we drop them to keep
    // the line width stable.
    let cleaned: String = raw.chars().filter(|&c| c != '\r').collect();
    match cleaned.into_text() {
        Ok(text) => text
            .lines
            .into_iter()
            .next()
            .unwrap_or_else(|| Line::raw(String::new())),
        Err(_) => Line::raw(cleaned),
    }
}

pub fn run(rx: Receiver<Msg>, mut shell_stdin: ChildStdin, node: &str) -> Result<()> {
    let mut stdout = io::stdout();
    enable_raw_mode()?;
    stdout.execute(EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;

    let result = event_loop(&mut terminal, rx, &mut shell_stdin, node.to_string());

    let _ = disable_raw_mode();
    let _ = terminal.backend_mut().execute(LeaveAlternateScreen);
    let _ = terminal.show_cursor();

    result
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    rx: Receiver<Msg>,
    shell_stdin: &mut ChildStdin,
    node: String,
) -> Result<()> {
    let mut state = State::new(node);

    loop {
        // Drain any pending messages (non-blocking).
        loop {
            match rx.try_recv() {
                Ok(Msg::LogLine(l)) => state.push_log(l),
                Ok(Msg::ShellLine(l)) => state.push_shell(l),
                Ok(Msg::AppExited) => {
                    state.app_exited = true;
                    state.push_log("[ovcs] BEAM exited".to_string());
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }

        terminal.draw(|f| render(f, &state))?;

        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    handle_key(&mut state, key.code, key.modifiers, shell_stdin)?;
                }
            }
        }

        if state.quit {
            break;
        }
    }

    Ok(())
}

fn render(f: &mut ratatui::Frame, state: &State) {
    let area = f.area();

    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(area);

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
        .split(outer[0]);

    render_logs(f, columns[0], state);
    render_shell(f, columns[1], state);
    render_status(f, outer[1], state);
}

fn render_logs(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let title = if state.app_exited {
        format!(" logs ({}) [EXITED] ", state.node)
    } else {
        format!(" logs ({}) ", state.node)
    };
    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Log));

    let inner_h = area.height.saturating_sub(2) as usize;
    let total = state.logs.len();
    let start = if state.log_follow {
        total.saturating_sub(inner_h)
    } else {
        state
            .log_scroll
            .min(total.saturating_sub(inner_h) as u16) as usize
    };

    let lines: Vec<Line> = state
        .logs
        .iter()
        .skip(start)
        .take(inner_h)
        .cloned()
        .collect();

    // No wrap: long lines truncate at the pane's right edge. Each stored
    // Line maps to exactly one visual row, so scroll math stays simple.
    let p = Paragraph::new(lines).block(block);
    f.render_widget(p, area);
}

fn render_shell(f: &mut ratatui::Frame, area: Rect, state: &State) {
    // One bordered box for the whole remsh pane. Output flows top-down;
    // the current input is pinned as the last interior row, so typing
    // feels like a live REPL prompt instead of a separate widget.
    let block = Block::default()
        .title(" iex --remsh ")
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Shell));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(inner);

    let out_area = rows[0];
    let input_area = rows[1];

    let inner_h = out_area.height as usize;
    let total = state.shell_out.len();
    let start = if state.shell_follow {
        total.saturating_sub(inner_h)
    } else {
        state
            .shell_scroll
            .min(total.saturating_sub(inner_h) as u16) as usize
    };

    let out_lines: Vec<Line> = state
        .shell_out
        .iter()
        .skip(start)
        .take(inner_h)
        .cloned()
        .collect();

    f.render_widget(Paragraph::new(out_lines), out_area);

    let input_line = Line::from(vec![
        Span::styled("❯ ", Style::default().fg(Color::Cyan)),
        Span::raw(state.input.clone()),
    ]);
    f.render_widget(Paragraph::new(input_line), input_area);

    if state.focus == Focus::Shell {
        let col = input_area.x + 2 + state.cursor as u16;
        let max_col = input_area.x + input_area.width.saturating_sub(1);
        f.set_cursor_position((col.min(max_col), input_area.y));
    }
}

fn render_status(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let focus_label = match state.focus {
        Focus::Log => "log",
        Focus::Shell => "shell",
    };
    let help = format!(
        " [{}] Tab=switch  ↑↓=scroll/history  Enter=eval  Esc=log focus  Ctrl-C/q=quit ",
        focus_label
    );
    let p = Paragraph::new(Line::from(Span::styled(
        help,
        Style::default().fg(Color::Black).bg(Color::Cyan),
    )));
    f.render_widget(p, area);
}

fn focus_style(state: &State, f: Focus) -> Style {
    if state.focus == f {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}

fn handle_key(
    state: &mut State,
    code: KeyCode,
    mods: KeyModifiers,
    shell_stdin: &mut ChildStdin,
) -> Result<()> {
    // Global: Ctrl-C quits from anywhere.
    if matches!(code, KeyCode::Char('c')) && mods.contains(KeyModifiers::CONTROL) {
        state.quit = true;
        return Ok(());
    }
    if code == KeyCode::Tab {
        state.focus = match state.focus {
            Focus::Log => Focus::Shell,
            Focus::Shell => Focus::Log,
        };
        return Ok(());
    }

    match state.focus {
        Focus::Log => handle_log(state, code),
        Focus::Shell => handle_shell(state, code, shell_stdin)?,
    }
    Ok(())
}

fn handle_log(state: &mut State, code: KeyCode) {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => state.quit = true,
        KeyCode::Up | KeyCode::Char('k') => {
            state.log_follow = false;
            state.log_scroll = state.log_scroll.saturating_sub(1);
        }
        KeyCode::Down | KeyCode::Char('j') => {
            state.log_scroll = state.log_scroll.saturating_add(1);
            if state.log_scroll as usize >= state.logs.len() {
                state.log_follow = true;
            }
        }
        KeyCode::PageUp => {
            state.log_follow = false;
            state.log_scroll = state.log_scroll.saturating_sub(10);
        }
        KeyCode::PageDown => {
            state.log_scroll = state.log_scroll.saturating_add(10);
            if state.log_scroll as usize >= state.logs.len() {
                state.log_follow = true;
            }
        }
        KeyCode::End | KeyCode::Char('G') => state.log_follow = true,
        KeyCode::Home | KeyCode::Char('g') => {
            state.log_follow = false;
            state.log_scroll = 0;
        }
        _ => {}
    }
}

fn handle_shell(state: &mut State, code: KeyCode, shell_stdin: &mut ChildStdin) -> Result<()> {
    match code {
        KeyCode::Esc => state.focus = Focus::Log,
        KeyCode::Enter => {
            let line = std::mem::take(&mut state.input);
            state.cursor = 0;
            state.history_idx = None;
            writeln!(shell_stdin, "{}", line)?;
            shell_stdin.flush()?;
            if !line.is_empty() {
                let echo = Line::from(vec![
                    Span::styled("❯ ", Style::default().fg(Color::Cyan)),
                    Span::raw(line.clone()),
                ]);
                state.push_shell_echo(echo);
                state.history.push(line);
                if state.history.len() > HISTORY_CAP {
                    state.history.remove(0);
                }
            }
            state.shell_follow = true;
        }
        KeyCode::Char(c) => {
            state.input.insert(state.cursor, c);
            state.cursor += c.len_utf8();
        }
        KeyCode::Backspace => {
            if state.cursor > 0 {
                // Step back one char boundary.
                let mut new = state.cursor;
                while new > 0 && !state.input.is_char_boundary(new - 1) {
                    new -= 1;
                }
                new = new.saturating_sub(1);
                state.input.drain(new..state.cursor);
                state.cursor = new;
            }
        }
        KeyCode::Left => state.cursor = prev_char_boundary(&state.input, state.cursor),
        KeyCode::Right => state.cursor = next_char_boundary(&state.input, state.cursor),
        KeyCode::Home => state.cursor = 0,
        KeyCode::End => state.cursor = state.input.len(),
        KeyCode::Up => {
            if !state.history.is_empty() {
                let new_idx = match state.history_idx {
                    None => state.history.len() - 1,
                    Some(0) => 0,
                    Some(i) => i - 1,
                };
                state.history_idx = Some(new_idx);
                state.input = state.history[new_idx].clone();
                state.cursor = state.input.len();
            }
        }
        KeyCode::Down => {
            if let Some(i) = state.history_idx {
                if i + 1 < state.history.len() {
                    state.history_idx = Some(i + 1);
                    state.input = state.history[i + 1].clone();
                } else {
                    state.history_idx = None;
                    state.input.clear();
                }
                state.cursor = state.input.len();
            }
        }
        _ => {}
    }
    Ok(())
}

fn prev_char_boundary(s: &str, i: usize) -> usize {
    if i == 0 {
        return 0;
    }
    let mut j = i - 1;
    while j > 0 && !s.is_char_boundary(j) {
        j -= 1;
    }
    j
}

fn next_char_boundary(s: &str, i: usize) -> usize {
    let mut j = i + 1;
    let len = s.len();
    while j < len && !s.is_char_boundary(j) {
        j += 1;
    }
    j.min(len)
}
