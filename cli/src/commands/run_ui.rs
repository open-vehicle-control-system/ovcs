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
const BUS_CAP: usize = 4000;
const CAN_CAP: usize = 4000;
const HISTORY_CAP: usize = 500;

/// Messages pushed to the TUI from the transport backends (SSH task or
/// local remsh reader threads).
pub enum Msg {
    /// One log line from a remote node's log channel.
    Log { node: String, line: String },
    /// One line of IEx output from a node's interactive shell channel.
    Shell { node: String, line: String },
    /// One OvcsBus message observed on a node's monitor channel.
    Bus {
        node: String,
        source: String,
        name: String,
        value: String,
    },
    /// One CAN frame observed on a node's monitor channel.
    CanFrame {
        node: String,
        network: String,
        frame: String,
        signals: String,
    },
    /// Node finished setup and its shell/log channels are live.
    NodeUp(String),
    /// Node is gone (connection lost, ssh exited, etc.).
    NodeDown(String),
}

/// Per-node handle the TUI holds onto — one sender per interactive shell,
/// keyed by node name. Lives for the whole app: supervisors on the other
/// end reconnect transparently across node death, so dropping on
/// `NodeDown` would break every reconnect after the first.
pub struct NodeHandle {
    pub name: String,
    pub stdin: Sender<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Focus {
    Log,
    Bus,
    Can,
    Shell,
}

struct NodeState {
    color: Color,
    up: bool,
    stdin: Sender<String>,
    shell_out: VecDeque<Line<'static>>,
}

struct State {
    nodes: Vec<String>,
    by_node: HashMap<String, NodeState>,
    logs: VecDeque<Line<'static>>,
    bus: VecDeque<Line<'static>>,
    can: VecDeque<Line<'static>>,
    input: String,
    cursor: usize,
    history: Vec<String>,
    history_idx: Option<usize>,
    focus: Focus,
    log_scroll: u16,
    log_follow: bool,
    bus_scroll: u16,
    bus_follow: bool,
    /// Space-toggled freeze: while true, incoming Bus messages are
    /// dropped so the pane contents stay exactly readable. Separate
    /// from `bus_follow` (which just controls auto-tail vs. fixed
    /// scroll position) so arrow-key scrolling doesn't silently drop
    /// data.
    bus_paused: bool,
    can_scroll: u16,
    can_follow: bool,
    can_paused: bool,
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
                    stdin: h.stdin,
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
            bus: VecDeque::with_capacity(BUS_CAP),
            can: VecDeque::with_capacity(CAN_CAP),
            input: String::new(),
            cursor: 0,
            history: Vec::new(),
            history_idx: None,
            focus: Focus::Shell,
            log_scroll: 0,
            log_follow: true,
            bus_scroll: 0,
            bus_follow: true,
            bus_paused: false,
            can_scroll: 0,
            can_follow: true,
            can_paused: false,
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

    fn push_bus(&mut self, node: &str, source: &str, name: &str, value: &str) {
        if self.bus_paused {
            return;
        }
        let color = self
            .by_node
            .get(node)
            .map(|n| n.color)
            .unwrap_or(Color::White);
        let spans = vec![
            Span::styled(
                format!("{:<28}", short_source(source)),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
            Span::styled(
                format!("{:<24}", name),
                Style::default().add_modifier(Modifier::BOLD),
            ),
            Span::raw(" = "),
            Span::raw(value.to_string()),
        ];
        if self.bus.len() == BUS_CAP {
            self.bus.pop_front();
        }
        self.bus.push_back(Line::from(spans));
    }

    fn push_can(&mut self, node: &str, network: &str, frame: &str, signals: &str) {
        if self.can_paused {
            return;
        }
        let color = self
            .by_node
            .get(node)
            .map(|n| n.color)
            .unwrap_or(Color::White);
        let line = Line::from(vec![
            Span::styled(
                format!("{:<18}", format!("[{}/{}]", network, frame)),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
            Span::styled(
                signals.to_string(),
                Style::default().add_modifier(Modifier::DIM),
            ),
        ]);
        if self.can.len() == CAN_CAP {
            self.can.pop_front();
        }
        self.can.push_back(line);
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

/// Shrink `VmsCore.Components.Volkswagen.Polo9N.ABS` → `Polo9N.ABS` so the
/// source column of the bus pane doesn't burn half the row on the
/// `VmsCore.Components.*` prefix every component shares.
fn short_source(source: &str) -> String {
    let trimmed = source.trim_matches('"');
    const COMPONENT_PREFIX: &str = "VmsCore.Components.";
    let dropped = trimmed.strip_prefix(COMPONENT_PREFIX).unwrap_or(trimmed);
    let parts: Vec<&str> = dropped.split('.').collect();
    if parts.len() > 2 {
        parts[parts.len() - 2..].join(".")
    } else {
        dropped.to_string()
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
                Ok(Msg::Bus {
                    node,
                    source,
                    name,
                    value,
                }) => state.push_bus(&node, &source, &name, &value),
                Ok(Msg::CanFrame {
                    node,
                    network,
                    frame,
                    signals,
                }) => state.push_can(&node, &network, &frame, &signals),
                Ok(Msg::NodeUp(node)) => {
                    if let Some(n) = state.by_node.get_mut(&node) {
                        n.up = true;
                    }
                    state.push_log(&node, "[ovcs] connected".to_string());
                }
                Ok(Msg::NodeDown(node)) => {
                    if let Some(n) = state.by_node.get_mut(&node) {
                        n.up = false;
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
    // Layout rationale: logs/bus/can show merged streams across every node,
    // but the IEx shell is bound to one node at a time. Put the node
    // selector (tab strip) directly above the shell so the scope of that
    // selection is obvious — F1/F2/… switch which node's IEx you're
    // driving, not what the panes above display.
    let area = f.area();
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage(70), // upper: logs + bus + can
            Constraint::Length(1),      // node tab strip (drives shell)
            Constraint::Percentage(30), // shell
            Constraint::Length(1),      // footer
        ])
        .split(area);

    let upper = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(outer[0]);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(upper[1]);

    render_logs(f, upper[0], state);
    render_bus(f, right[0], state);
    render_can(f, right[1], state);
    render_tabs(f, outer[1], state);
    render_shell(f, outer[2], state);
    render_status(f, outer[3], state);
}

fn render_tabs(f: &mut ratatui::Frame, area: Rect, state: &State) {
    // Node selector for the IEx pane below:
    //   IEx ▸  ● F1 vms   ● F2 infotainment   ○ F3 bridge-radio_control
    // Active: bold + underlined in the node's accent colour.
    // Disconnected: hollow `○` marker + DIM.
    let mut spans: Vec<Span<'static>> = vec![
        Span::styled(" IEx ", Style::default().add_modifier(Modifier::DIM)),
        Span::styled("▸ ", Style::default().add_modifier(Modifier::DIM)),
    ];

    for (i, name) in state.nodes.iter().enumerate() {
        let node = state.by_node.get(name);
        let color = node.map(|n| n.color).unwrap_or(Color::White);
        let up = node.map(|n| n.up).unwrap_or(false);
        let active = name == &state.current;

        let dot = if up { "●" } else { "○" };
        let fkey = format!("F{}", i + 1);

        let label_style = {
            let mut s = Style::default().fg(color);
            if active {
                s = s
                    .add_modifier(Modifier::BOLD)
                    .add_modifier(Modifier::UNDERLINED);
            }
            if !up {
                s = s.add_modifier(Modifier::DIM);
            }
            s
        };

        let dot_style = {
            let mut s = Style::default().fg(color);
            if !up {
                s = s.add_modifier(Modifier::DIM);
            }
            s
        };

        let fkey_style = {
            let mut s = Style::default().add_modifier(Modifier::DIM);
            if active {
                s = s.add_modifier(Modifier::BOLD);
            }
            s
        };

        if i > 0 {
            spans.push(Span::styled(
                "   ",
                Style::default().add_modifier(Modifier::DIM),
            ));
        }
        spans.push(Span::styled(dot.to_string(), dot_style));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(fkey, fkey_style));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(name.clone(), label_style));
    }

    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_logs(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let up = state.by_node.values().filter(|n| n.up).count();
    let total = state.nodes.len();
    let title = format!(" Logs  [{}/{} up] ", up, total);
    let block = Block::default()
        .title(Span::styled(title, title_style(state, Focus::Log)))
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

fn render_bus(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let pause = if state.bus_paused {
        " ❚❚ paused "
    } else {
        ""
    };
    let title = format!(" Bus  [{}]{} ", state.bus.len(), pause);
    let block = Block::default()
        .title(Span::styled(title, title_style(state, Focus::Bus)))
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Bus));

    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;
    let total = state.bus.len();
    let start = if state.bus_follow {
        visible_start(&state.bus, inner_h, inner_w)
    } else {
        state.bus_scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };

    let lines: Vec<Line> = state.bus.iter().skip(start).cloned().collect();
    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
}

fn render_can(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let pause = if state.can_paused {
        " ❚❚ paused "
    } else {
        ""
    };
    let title = format!(" CAN  [{}]{} ", state.can.len(), pause);
    let block = Block::default()
        .title(Span::styled(title, title_style(state, Focus::Can)))
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Can));

    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;
    let total = state.can.len();
    let start = if state.can_follow {
        visible_start(&state.can, inner_h, inner_w)
    } else {
        state.can_scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };

    let lines: Vec<Line> = state.can.iter().skip(start).cloned().collect();
    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
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
    // Shell pane keeps a short "IEx · <node>" title in the node's accent
    // colour; the tab strip directly above is the primary "which node am I
    // driving" selector.
    let title = format!(" IEx · {} ", state.current);
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
        Focus::Bus => "bus",
        Focus::Can => "can",
        Focus::Shell => "shell",
    };
    // The tab strip just above the shell advertises the F-key node map;
    // this footer stays focused on universal pane / editor / exit bindings
    // plus the pause hint users most often need on bus/can.
    let pane_keys = match state.focus {
        Focus::Bus | Focus::Can => "Space=pause  ↑↓=scroll  ",
        Focus::Log => "↑↓=scroll  ",
        Focus::Shell => "",
    };
    let help = if state.nodes.len() > 1 {
        format!(
            " [{}] Tab=pane  {}Ctrl-N/P=cycle node  Enter=eval  Ctrl-C/q=quit ",
            focus_label, pane_keys
        )
    } else {
        format!(
            " [{}] Tab=pane  {}Enter=eval  Ctrl-C/q=quit ",
            focus_label, pane_keys
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
        // Use the terminal's default foreground so the border is legible on
        // both light and dark themes — DarkGray is invisible on most light
        // schemes and the pane loses its frame entirely.
        Style::default()
    }
}

/// Title style for an unfocused pane — visible but quiet. When focused, we
/// let `border_style` on the block render the title in the focus colour.
fn title_style(state: &State, f: Focus) -> Style {
    if state.focus == f {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().add_modifier(Modifier::BOLD)
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
            Focus::Log => Focus::Bus,
            Focus::Bus => Focus::Can,
            Focus::Can => Focus::Shell,
            Focus::Shell => Focus::Log,
        };
        return Ok(());
    }

    match state.focus {
        Focus::Log => handle_log(state, code),
        Focus::Bus => handle_pane_scroll(
            code,
            &state.bus,
            &mut state.bus_scroll,
            &mut state.bus_follow,
            &mut state.bus_paused,
            &mut state.quit,
        ),
        Focus::Can => handle_pane_scroll(
            code,
            &state.can,
            &mut state.can_scroll,
            &mut state.can_follow,
            &mut state.can_paused,
            &mut state.quit,
        ),
        Focus::Shell => handle_shell(state, code)?,
    }
    Ok(())
}

fn handle_pane_scroll(
    code: KeyCode,
    lines: &VecDeque<Line<'static>>,
    scroll: &mut u16,
    follow: &mut bool,
    paused: &mut bool,
    quit: &mut bool,
) {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => *quit = true,
        // Space toggles a hard freeze: `paused` gates the push side so
        // messages stop entering the buffer, and `follow` goes off so the
        // view holds its current offset instead of auto-tailing. Unpause
        // resumes both.
        KeyCode::Char(' ') | KeyCode::Char('p') => {
            *paused = !*paused;
            if *paused {
                *follow = false;
                // Pin scroll to the tail so the pane freezes on the
                // messages the user was just looking at.
                *scroll = lines.len().saturating_sub(1) as u16;
            } else {
                *follow = true;
            }
        }
        KeyCode::Up | KeyCode::Char('k') => {
            *follow = false;
            *scroll = scroll.saturating_sub(1);
        }
        KeyCode::Down | KeyCode::Char('j') => {
            *scroll = scroll.saturating_add(1);
            if *scroll as usize >= lines.len() {
                *follow = true;
            }
        }
        KeyCode::PageUp => {
            *follow = false;
            *scroll = scroll.saturating_sub(10);
        }
        KeyCode::PageDown => {
            *scroll = scroll.saturating_add(10);
            if *scroll as usize >= lines.len() {
                *follow = true;
            }
        }
        KeyCode::End | KeyCode::Char('G') => {
            *follow = true;
            *paused = false;
        }
        KeyCode::Home | KeyCode::Char('g') => {
            *follow = false;
            *scroll = 0;
        }
        _ => {}
    }
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
                // Always queue to the supervisor's stdin channel — the
                // supervisor drains queued input on reconnect so stale
                // commands typed while the node was down don't hit the
                // fresh session. Sending while down is a no-op on the
                // far side.
                let _ = n.stdin.send(format!("{}\n", line));
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
