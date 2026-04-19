use ansi_to_tui::IntoText;
use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::Terminal;
use regex::Regex;
use std::collections::{HashMap, VecDeque};
use std::io::{self, Stdout};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::time::Duration;

const LOG_CAP: usize = 4000;
const SHELL_CAP: usize = 2000;
const HISTORY_CAP: usize = 500;

/// Messages pushed to the TUI from the transport backends (SSH task or
/// local remsh reader threads).
pub enum Msg {
    /// One log line from a remote node's log channel.
    Log { node: String, line: String },
    /// One line of IEx output from a node's interactive shell channel.
    Shell { node: String, line: String },
    /// Node finished setup and its shell/log channels are live.
    NodeUp(String),
    /// Node is gone (connection lost, ssh exited, etc.).
    NodeDown(String),
}

/// Per-node handle the TUI holds onto — one sender per interactive shell,
/// keyed by node name. Dropping the sender signals the worker to close the
/// channel.
pub struct NodeHandle {
    pub name: String,
    pub stdin: Sender<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Focus {
    Log,
    Shell,
}

struct NodeState {
    color: Color,
    up: bool,
    stdin: Option<Sender<String>>,
    shell_out: VecDeque<Line<'static>>,
}

struct State {
    nodes: Vec<String>,
    by_node: HashMap<String, NodeState>,
    logs: VecDeque<Line<'static>>,
    input: String,
    cursor: usize,
    history: Vec<String>,
    history_idx: Option<usize>,
    focus: Focus,
    log_scroll: u16,
    log_follow: bool,
    shell_scroll: u16,
    shell_follow: bool,
    current: String,
    quit: bool,
    prompt_re: Regex,
}

const PALETTE: &[Color] = &[
    Color::Cyan,
    Color::Yellow,
    Color::Green,
    Color::Magenta,
    Color::LightBlue,
    Color::LightRed,
    Color::LightGreen,
    Color::LightMagenta,
];

impl State {
    fn new(handles: Vec<NodeHandle>) -> Self {
        let mut nodes = Vec::new();
        let mut by_node = HashMap::new();
        for (i, h) in handles.into_iter().enumerate() {
            let color = PALETTE[i % PALETTE.len()];
            by_node.insert(
                h.name.clone(),
                NodeState {
                    color,
                    up: false,
                    stdin: Some(h.stdin),
                    shell_out: VecDeque::with_capacity(SHELL_CAP),
                },
            );
            nodes.push(h.name);
        }
        let current = nodes.first().cloned().unwrap_or_default();
        Self {
            nodes,
            by_node,
            logs: VecDeque::with_capacity(LOG_CAP),
            input: String::new(),
            cursor: 0,
            history: Vec::new(),
            history_idx: None,
            focus: Focus::Shell,
            log_scroll: 0,
            log_follow: true,
            shell_scroll: 0,
            shell_follow: true,
            current,
            quit: false,
            prompt_re: Regex::new(r"^(iex|\.{3})\(\d+\)>\s?").unwrap(),
        }
    }

    fn push_log(&mut self, node: &str, raw: String) {
        let color = self
            .by_node
            .get(node)
            .map(|n| n.color)
            .unwrap_or(Color::White);
        let tag = Span::styled(
            format!("[{}] ", node),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        );
        let body = parse_ansi_line(&raw);
        let mut spans = vec![tag];
        spans.extend(body.spans);
        if self.logs.len() == LOG_CAP {
            self.logs.pop_front();
        }
        self.logs.push_back(Line::from(spans));
    }

    fn push_shell(&mut self, node: &str, raw: String) {
        let cleaned = self.prompt_re.replace(&raw, "").into_owned();
        if let Some(n) = self.by_node.get_mut(node) {
            if n.shell_out.len() == SHELL_CAP {
                n.shell_out.pop_front();
            }
            n.shell_out.push_back(parse_ansi_line(&cleaned));
        }
    }

    fn push_shell_echo(&mut self, line: Line<'static>) {
        if let Some(n) = self.by_node.get_mut(&self.current) {
            if n.shell_out.len() == SHELL_CAP {
                n.shell_out.pop_front();
            }
            n.shell_out.push_back(line);
        }
    }

    fn cycle(&mut self, delta: isize) {
        if self.nodes.len() < 2 {
            return;
        }
        let idx = self
            .nodes
            .iter()
            .position(|n| n == &self.current)
            .unwrap_or(0) as isize;
        let len = self.nodes.len() as isize;
        let next = ((idx + delta).rem_euclid(len)) as usize;
        self.current = self.nodes[next].clone();
        self.shell_follow = true;
    }

    fn jump(&mut self, idx: usize) {
        if let Some(name) = self.nodes.get(idx) {
            self.current = name.clone();
            self.shell_follow = true;
        }
    }
}

fn parse_ansi_line(raw: &str) -> Line<'static> {
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

pub fn run(rx: Receiver<Msg>, nodes: Vec<NodeHandle>) -> Result<()> {
    let mut stdout = io::stdout();
    enable_raw_mode()?;
    stdout.execute(EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;

    let result = event_loop(&mut terminal, rx, nodes);

    let _ = disable_raw_mode();
    let _ = terminal.backend_mut().execute(LeaveAlternateScreen);
    let _ = terminal.show_cursor();

    result
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    rx: Receiver<Msg>,
    nodes: Vec<NodeHandle>,
) -> Result<()> {
    let mut state = State::new(nodes);

    loop {
        loop {
            match rx.try_recv() {
                Ok(Msg::Log { node, line }) => state.push_log(&node, line),
                Ok(Msg::Shell { node, line }) => state.push_shell(&node, line),
                Ok(Msg::NodeUp(node)) => {
                    if let Some(n) = state.by_node.get_mut(&node) {
                        n.up = true;
                    }
                    state.push_log(&node, "[ovcs] connected".to_string());
                }
                Ok(Msg::NodeDown(node)) => {
                    if let Some(n) = state.by_node.get_mut(&node) {
                        n.up = false;
                        n.stdin = None;
                    }
                    state.push_log(&node, "[ovcs] disconnected".to_string());
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }

        terminal.draw(|f| render(f, &state))?;

        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    handle_key(&mut state, key.code, key.modifiers)?;
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
    let up = state.by_node.values().filter(|n| n.up).count();
    let total = state.nodes.len();
    let title = format!(" logs  [{}/{} up] ", up, total);
    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Log));

    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;
    let total_lines = state.logs.len();
    let start = if state.log_follow {
        visible_start(&state.logs, inner_h, inner_w)
    } else {
        state
            .log_scroll
            .min(total_lines.saturating_sub(inner_h) as u16) as usize
    };

    // Pass the tail of entries from `start` onward — ratatui wraps them
    // top-down; any overflow past `inner_h` visual rows is clipped at the
    // bottom, which matches the stored order (newest last).
    let lines: Vec<Line> = state.logs.iter().skip(start).cloned().collect();

    let p = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false });
    f.render_widget(p, area);
}

/// Walk stored lines from newest to oldest, summing visual rows each would
/// occupy at width `inner_w` with wrap enabled. Stop when the next line
/// would overflow `inner_h`. Returns the index of the first stored line to
/// render so that the newest entries remain visible at the pane bottom.
fn visible_start(lines: &VecDeque<Line<'static>>, inner_h: usize, inner_w: usize) -> usize {
    if inner_h == 0 || inner_w == 0 || lines.is_empty() {
        return lines.len();
    }
    let mut rows = 0usize;
    for (rev_i, line) in lines.iter().rev().enumerate() {
        let w = line.width().max(1);
        let taken = w.div_ceil(inner_w).max(1);
        if rows + taken > inner_h {
            return lines.len() - rev_i;
        }
        rows += taken;
    }
    0
}

fn render_shell(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let current_color = state
        .by_node
        .get(&state.current)
        .map(|n| n.color)
        .unwrap_or(Color::Cyan);
    let up_badge = if state
        .by_node
        .get(&state.current)
        .map(|n| n.up)
        .unwrap_or(false)
    {
        ""
    } else {
        "  [disconnected]"
    };
    let title = format!(" iex — {}{} ", state.current, up_badge);
    let block = Block::default()
        .title(Span::styled(
            title,
            Style::default()
                .fg(current_color)
                .add_modifier(Modifier::BOLD),
        ))
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

    let empty = VecDeque::new();
    let shell_out = state
        .by_node
        .get(&state.current)
        .map(|n| &n.shell_out)
        .unwrap_or(&empty);

    let inner_h = out_area.height as usize;
    let inner_w = out_area.width as usize;
    let total = shell_out.len();
    let start = if state.shell_follow {
        visible_start(shell_out, inner_h, inner_w)
    } else {
        state.shell_scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };

    let out_lines: Vec<Line> = shell_out.iter().skip(start).cloned().collect();

    f.render_widget(
        Paragraph::new(out_lines).wrap(Wrap { trim: false }),
        out_area,
    );

    let input_line = Line::from(vec![
        Span::styled("❯ ", Style::default().fg(current_color)),
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
    let help = if state.nodes.len() > 1 {
        format!(
            " [{}] Tab=pane  Ctrl-N/P=shell node  F1..F9=jump  Enter=eval  Ctrl-C/q=quit ",
            focus_label
        )
    } else {
        format!(
            " [{}] Tab=pane  ↑↓=scroll/history  Enter=eval  Ctrl-C/q=quit ",
            focus_label
        )
    };
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

fn handle_key(state: &mut State, code: KeyCode, mods: KeyModifiers) -> Result<()> {
    if matches!(code, KeyCode::Char('c')) && mods.contains(KeyModifiers::CONTROL) {
        state.quit = true;
        return Ok(());
    }
    if matches!(code, KeyCode::Char('n')) && mods.contains(KeyModifiers::CONTROL) {
        state.cycle(1);
        return Ok(());
    }
    if matches!(code, KeyCode::Char('p')) && mods.contains(KeyModifiers::CONTROL) {
        state.cycle(-1);
        return Ok(());
    }
    if let KeyCode::F(n) = code {
        if (1..=9).contains(&n) {
            state.jump((n - 1) as usize);
            return Ok(());
        }
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
        Focus::Shell => handle_shell(state, code)?,
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

fn handle_shell(state: &mut State, code: KeyCode) -> Result<()> {
    match code {
        KeyCode::Esc => state.focus = Focus::Log,
        KeyCode::Enter => {
            let line = std::mem::take(&mut state.input);
            state.cursor = 0;
            state.history_idx = None;
            if let Some(n) = state.by_node.get(&state.current) {
                if let Some(tx) = &n.stdin {
                    let _ = tx.send(format!("{}\n", line));
                }
            }
            if !line.is_empty() {
                let color = state
                    .by_node
                    .get(&state.current)
                    .map(|n| n.color)
                    .unwrap_or(Color::Cyan);
                let echo = Line::from(vec![
                    Span::styled("❯ ", Style::default().fg(color)),
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
