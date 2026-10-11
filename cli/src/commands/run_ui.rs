use ansi_to_tui::IntoText;
use anyhow::Result;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use crossterm::event::{
    self, Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::Terminal;
use regex::Regex;
use std::collections::{HashMap, VecDeque};
use std::io::{Stdout, Write as _};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::terminal;

const LOG_CAP: usize = 4000;
const SHELL_CAP: usize = 2000;
const BUS_CAP: usize = 4000;
const CAN_CAP: usize = 4000;
const HISTORY_CAP: usize = 500;

/// Weights of the per-key rate smoother shared by Bus and CAN: `_NEW` on
/// the newest 1/dt sample, `_PRIOR` on the smoothed value. Balances
/// reacting quickly against jittering on per-frame noise.
const EMA_WEIGHT_NEW: f32 = 0.3;
const EMA_WEIGHT_PRIOR: f32 = 0.7;

/// Hide the `@NHz` tag below this rate, where it reads as noise rather
/// than a cadence.
const MIN_HZ_DISPLAY: f32 = 0.5;

/// How long a footer toast (copy, selection) stays before the key hints return.
const TOAST_TTL: Duration = Duration::from_secs(3);

/// Clipboard payload cap: terminals silently drop larger OSC 52 payloads,
/// so the tail of a full buffer is copied.
const CLIPBOARD_CAP_BYTES: usize = 64 * 1024;

/// Blend the latest inter-arrival rate into the smoothed one. Returns
/// 0.0 when `last_ts` equals `now`, which callers read as "no rate yet".
fn smoothed_hz(now: Instant, last_ts: Instant, prev_ema: f32) -> f32 {
    let interval_seconds = now.saturating_duration_since(last_ts).as_secs_f32();
    let instantaneous = if interval_seconds > 0.0 {
        1.0 / interval_seconds
    } else {
        0.0
    };
    if prev_ema > 0.0 {
        prev_ema * EMA_WEIGHT_PRIOR + instantaneous * EMA_WEIGHT_NEW
    } else {
        instantaneous
    }
}

/// Messages pushed to the TUI from the transport backends (SSH task or
/// local remsh reader threads).
pub enum Message {
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
    /// One CAN frame observed on a node's monitor channel. Signals and
    /// raw hex are carried as separate fields so the CAN pane can
    /// toggle which half of the row is shown.
    CanFrame {
        node: String,
        network: String,
        frame: String,
        signals: String,
        raw: String,
    },
    /// Node finished setup and its shell/log channels are live.
    NodeUp(String),
    /// Node is gone (connection lost, ssh exited, etc.).
    NodeDown(String),
}

/// Per-node handle the TUI holds: the interactive shell's input sender.
/// It lives for the whole TUI, since supervisors reconnect behind it.
pub struct NodeHandle {
    pub name: String,
    pub stdin: Sender<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
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

/// `(source, name)`: the Bus pane's key for rate tracking, change
/// highlight and observer view. Only the VMS node subscribes to `OvcsBus`,
/// so the node is not part of it.
type BusKey = (String, String);

/// One OvcsBus message row, kept structured so the Bus pane can render
/// its modes (observer, filter, change highlight) without reparsing.
struct BusRow {
    node: String,
    source: String,
    name: String,
    value: String,
    /// EMA-smoothed rate in Hz at the time this row was pushed.
    /// `None` for the first observation of a `(source, name)`.
    ema_hz: Option<f32>,
    /// Whether this value differs from the previous observation of
    /// the same `(source, name)`. Drives the yellow-bold highlight.
    changed: bool,
    /// Lowercase (source, name, value) for the `/` substring filter.
    haystack_lc: String,
}

/// Per-`BusKey` tracking state. `latest_row` is shared with the
/// chronological feed and holds the previous value for change detection.
struct BusTrack {
    last_ts: Instant,
    ema_hz: f32,
    latest_row: Arc<BusRow>,
}

/// `(node, network, frame)` — the key everything in the CAN pane
/// deduplicates on: rate tracking, signal-diff, observer view.
type CanKey = (String, String, String);

/// One decoded CAN frame row, kept structured so the CAN pane can show
/// decoded signals, raw hex or both at render time. Shared between the
/// chronological feed and the observer map.
struct CanRow {
    node: String,
    network: String,
    frame: String,
    signals: String,
    raw: String,
    /// Signals split into (key, value) pairs by `parse_signal_pairs`.
    signal_pairs: Vec<(String, String)>,
    /// Keys whose value differs from the previous observation of this
    /// `(node, network, frame)`. Drives the bold-on-change highlight.
    /// Empty for the first observation of a tuple.
    changed_keys: Vec<String>,
    /// EMA-smoothed rate in Hz at the time this row was pushed.
    /// `None` for the first sample (no inter-arrival to measure).
    ema_hz: Option<f32>,
    /// Lowercase tab-joined fields for the `/` substring filter, built
    /// once per push rather than on every render.
    haystack_lc: String,
}

/// Per-`CanKey` tracking state: the previous observation's signals, its
/// time, the smoothed rate and the latest row.
struct CanTrack {
    last_ts: Instant,
    ema_hz: f32,
    prev_pairs: Vec<(String, String)>,
    latest_row: Arc<CanRow>,
}

/// Which half of each CAN row to render. Cycled with `i` in CAN focus.
#[derive(Clone, Copy, PartialEq, Eq)]
enum CanView {
    Both,
    Decoded,
    Raw,
}

impl CanView {
    fn next(self) -> Self {
        match self {
            CanView::Both => CanView::Decoded,
            CanView::Decoded => CanView::Raw,
            CanView::Raw => CanView::Both,
        }
    }

    fn label(self) -> &'static str {
        match self {
            CanView::Both => "both",
            CanView::Decoded => "decoded",
            CanView::Raw => "raw",
        }
    }
}

/// Active mouse drag selection, in absolute terminal rows: the anchor
/// is where the click started, the cursor the current end.
#[derive(Clone, Copy)]
struct Selection {
    focus: Focus,
    anchor_row: u16,
    cursor_row: u16,
}

impl Selection {
    fn row_range(&self) -> (u16, u16) {
        (
            self.anchor_row.min(self.cursor_row),
            self.anchor_row.max(self.cursor_row),
        )
    }
}

struct State {
    nodes: Vec<String>,
    by_node: HashMap<String, NodeState>,
    logs: VecDeque<Line<'static>>,
    bus: VecDeque<Arc<BusRow>>,
    can: VecDeque<Arc<CanRow>>,
    input: String,
    cursor: usize,
    history: Vec<String>,
    history_index: Option<usize>,
    focus: Focus,
    /// `Alt-Enter` gives the focused pane the whole main area.
    maximized: bool,
    log_scroll: u16,
    log_follow: bool,
    bus_scroll: u16,
    bus_follow: bool,
    /// Space-toggled freeze: incoming Bus messages are dropped. Separate
    /// from `bus_follow`, so scrolling doesn't drop data.
    bus_paused: bool,
    /// Widest capped column values so far, for `format_bus_row`'s padding.
    bus_source_w: u16,
    bus_name_w: u16,
    /// `o`-toggled latest-value view for the Bus pane — one row per
    /// `(source, name)` in first-seen order, updated in place.
    bus_observer: bool,
    /// Insertion order of `BusKey`s (for stable observer row order).
    bus_order: Vec<BusKey>,

    bus_tracks: HashMap<BusKey, BusTrack>,
    /// Substring filter applied at render time. Empty = no filter.
    bus_filter: String,
    /// True while the user types a filter in the footer prompt.
    bus_filter_editing: bool,
    can_scroll: u16,
    can_follow: bool,
    can_paused: bool,
    can_view: CanView,
    /// Widest capped column values so far, for `format_can_row`'s padding.
    can_node_w: u16,
    can_net_w: u16,
    can_frame_w: u16,
    /// `o`-toggled observer view: one row per `CanKey` in first-seen
    /// order, showing its latest value.
    can_observer: bool,
    /// First-seen key order (stable ordering for observer view).
    can_order: Vec<CanKey>,

    can_tracks: HashMap<CanKey, CanTrack>,
    /// Substring filter applied at render time. Empty = no filter.
    can_filter: String,
    /// True while the user types a filter in the footer prompt.
    can_filter_editing: bool,
    /// Footer message replacing the key hints for `TOAST_TTL`.
    toast: Option<(String, Instant)>,
    /// Pane rects (borders included) of the last tick, for mouse hit-testing.
    pane_rects: HashMap<Focus, Rect>,
    /// Active mouse drag, between MouseDown and MouseUp.
    selection: Option<Selection>,
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
        for (index, handle) in handles.into_iter().enumerate() {
            let color = PALETTE[index % PALETTE.len()];
            by_node.insert(
                handle.name.clone(),
                NodeState {
                    color,
                    up: false,
                    stdin: handle.stdin,
                    shell_out: VecDeque::with_capacity(SHELL_CAP),
                },
            );
            nodes.push(handle.name);
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
            history_index: None,
            focus: Focus::Shell,
            maximized: false,
            log_scroll: 0,
            log_follow: true,
            bus_scroll: 0,
            bus_follow: true,
            bus_paused: false,
            bus_source_w: 0,
            bus_name_w: 0,
            bus_observer: false,
            bus_order: Vec::new(),
            bus_tracks: HashMap::new(),
            bus_filter: String::new(),
            bus_filter_editing: false,
            can_scroll: 0,
            can_follow: true,
            can_paused: false,
            can_view: CanView::Both,
            can_node_w: 0,
            can_net_w: 0,
            can_frame_w: 0,
            can_observer: false,
            can_order: Vec::new(),
            can_tracks: HashMap::new(),
            can_filter: String::new(),
            can_filter_editing: false,
            toast: None,
            pane_rects: HashMap::new(),
            selection: None,
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
        if let Some(node_state) = self.by_node.get_mut(node) {
            if node_state.shell_out.len() == SHELL_CAP {
                node_state.shell_out.pop_front();
            }
            node_state.shell_out.push_back(parse_ansi_line(&cleaned));
        }
    }

    fn push_shell_echo(&mut self, line: Line<'static>) {
        if let Some(node_state) = self.by_node.get_mut(&self.current) {
            if node_state.shell_out.len() == SHELL_CAP {
                node_state.shell_out.pop_front();
            }
            node_state.shell_out.push_back(line);
        }
    }

    fn push_bus(&mut self, node: &str, source: &str, name: &str, value: &str) {
        if self.bus_paused {
            return;
        }
        const SOURCE_CAP: u16 = 28;
        const NAME_CAP: u16 = 28;
        let short_src_len = short_source(source).len() as u16;
        self.bus_source_w = self.bus_source_w.max(short_src_len.min(SOURCE_CAP));
        self.bus_name_w = self.bus_name_w.max((name.len() as u16).min(NAME_CAP));

        let now = Instant::now();
        let key: BusKey = (source.to_string(), name.to_string());

        let (changed, ema_hz) = match self.bus_tracks.get(&key) {
            Some(prev) => {
                let changed = prev.latest_row.value != value;
                let smoothed = smoothed_hz(now, prev.last_ts, prev.ema_hz);
                (changed, Some(smoothed))
            }
            None => {
                self.bus_order.push(key.clone());
                (false, None)
            }
        };

        let haystack_lc = {
            let mut haystack = String::with_capacity(source.len() + name.len() + value.len() + 2);
            haystack.push_str(&source.to_lowercase());
            haystack.push('\t');
            haystack.push_str(&name.to_lowercase());
            haystack.push('\t');
            haystack.push_str(&value.to_lowercase());
            haystack
        };

        let row = Arc::new(BusRow {
            node: node.to_string(),
            source: source.to_string(),
            name: name.to_string(),
            value: value.to_string(),
            ema_hz,
            changed,
            haystack_lc,
        });

        self.bus_tracks.insert(
            key,
            BusTrack {
                last_ts: now,
                ema_hz: ema_hz.unwrap_or(0.0),
                latest_row: Arc::clone(&row),
            },
        );

        if self.bus.len() == BUS_CAP {
            self.bus.pop_front();
        }
        self.bus.push_back(row);
    }

    fn push_can(&mut self, node: &str, network: &str, frame: &str, signals: &str, raw: &str) {
        if self.can_paused {
            return;
        }
        // Capped so one long name doesn't push the signals off-screen.
        const NODE_CAP: u16 = 24;
        const NET_CAP: u16 = 16;
        const FRAME_CAP: u16 = 32;
        self.can_node_w = self.can_node_w.max((node.len() as u16).min(NODE_CAP));
        self.can_net_w = self.can_net_w.max((network.len() as u16).min(NET_CAP));
        self.can_frame_w = self.can_frame_w.max((frame.len() as u16).min(FRAME_CAP));

        let now = Instant::now();
        let pairs = parse_signal_pairs(signals);
        let key: CanKey = (node.to_string(), network.to_string(), frame.to_string());

        let (changed_keys, ema_hz) = match self.can_tracks.get(&key) {
            Some(prev) => {
                let changed = diff_pairs(&prev.prev_pairs, &pairs);
                let smoothed = smoothed_hz(now, prev.last_ts, prev.ema_hz);
                (changed, Some(smoothed))
            }
            None => {
                self.can_order.push(key.clone());
                (Vec::new(), None)
            }
        };

        let haystack_lc = build_haystack(node, network, frame, signals, raw);

        let row = Arc::new(CanRow {
            node: node.to_string(),
            network: network.to_string(),
            frame: frame.to_string(),
            signals: signals.to_string(),
            raw: raw.to_string(),
            signal_pairs: pairs.clone(),
            changed_keys,
            ema_hz,
            haystack_lc,
        });

        let track = CanTrack {
            last_ts: now,
            ema_hz: ema_hz.unwrap_or(0.0),
            prev_pairs: pairs,
            latest_row: Arc::clone(&row),
        };
        self.can_tracks.insert(key, track);

        if self.can.len() == CAN_CAP {
            self.can.pop_front();
        }
        self.can.push_back(row);
    }

    fn cycle(&mut self, delta: isize) {
        if self.nodes.len() < 2 {
            return;
        }
        let index = self
            .nodes
            .iter()
            .position(|name| name == &self.current)
            .unwrap_or(0) as isize;
        let len = self.nodes.len() as isize;
        let next = ((index + delta).rem_euclid(len)) as usize;
        self.current = self.nodes[next].clone();
        self.shell_follow = true;
    }

    fn jump(&mut self, index: usize) {
        if let Some(name) = self.nodes.get(index) {
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

fn strip_osc(raw: &str) -> String {
    let mut stripped = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\x1b' && chars.peek() == Some(&']') {
            chars.next();
            while let Some(character) = chars.next() {
                if character == '\x07' {
                    break;
                }
                if character == '\x1b' && chars.peek() == Some(&'\\') {
                    chars.next();
                    break;
                }
            }
        } else {
            stripped.push(character);
        }
    }
    stripped
}

fn parse_ansi_line(raw: &str) -> Line<'static> {
    // OSC (IEx's window title) and BEL would beep the host terminal; CSI
    // stays for ansi_to_tui to render as colour.
    let without_osc = strip_osc(raw);
    let cleaned: String = without_osc
        .chars()
        .filter(|&c| c != '\r' && c != '\x07')
        .collect();
    match cleaned.into_text() {
        Ok(text) => text
            .lines
            .into_iter()
            .next()
            .unwrap_or_else(|| Line::raw(String::new())),
        Err(_) => Line::raw(cleaned),
    }
}

pub fn run(rx: Receiver<Message>, nodes: Vec<NodeHandle>) -> Result<()> {
    // Mouse capture keeps drag-selection inside the focused pane.
    let mut terminal = terminal::enter(true)?;
    let result = event_loop(&mut terminal, rx, nodes);
    terminal::restore();
    result
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    rx: Receiver<Message>,
    nodes: Vec<NodeHandle>,
) -> Result<()> {
    let mut state = State::new(nodes);

    loop {
        loop {
            match rx.try_recv() {
                Ok(Message::Log { node, line }) => state.push_log(&node, line),
                Ok(Message::Shell { node, line }) => state.push_shell(&node, line),
                Ok(Message::Bus {
                    node,
                    source,
                    name,
                    value,
                }) => state.push_bus(&node, &source, &name, &value),
                Ok(Message::CanFrame {
                    node,
                    network,
                    frame,
                    signals,
                    raw,
                }) => state.push_can(&node, &network, &frame, &signals, &raw),
                Ok(Message::NodeUp(node)) => {
                    if let Some(node_state) = state.by_node.get_mut(&node) {
                        node_state.up = true;
                    }
                    state.push_log(&node, "[ovcs] connected".to_string());
                }
                Ok(Message::NodeDown(node)) => {
                    if let Some(node_state) = state.by_node.get_mut(&node) {
                        node_state.up = false;
                    }
                    state.push_log(&node, "[ovcs] disconnected".to_string());
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }

        let size = terminal.size()?;
        compute_pane_rects(&mut state, Rect::new(0, 0, size.width, size.height));
        terminal.draw(|frame| render(frame, &state))?;

        if event::poll(Duration::from_millis(50))? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => {
                    handle_key(&mut state, key.code, key.modifiers)?;
                }
                Event::Mouse(mouse) => {
                    handle_mouse(&mut state, mouse);
                }
                _ => {}
            }
        }

        if state.quit {
            break;
        }
    }

    Ok(())
}

fn render(frame: &mut ratatui::Frame, state: &State) {
    let area = frame.area();

    if state.maximized {
        render_maximized(frame, area, state);
    } else {
        render_normal(frame, area, state);
    }

    if let Some(selection) = state.selection {
        if let Some(rect) = state.pane_rects.get(&selection.focus).copied() {
            paint_selection(frame, rect, selection);
        }
    }
}

/// Highlight the selected rows inside the pane's borders. Selection is by
/// whole rows, as rows map to messages.
fn paint_selection(frame: &mut ratatui::Frame, rect: Rect, selection: Selection) {
    if rect.width < 2 || rect.height < 2 {
        return;
    }
    let inner_x0 = rect.x + 1;
    let inner_x1 = rect.x + rect.width - 1;
    let inner_y0 = rect.y + 1;
    let inner_y1 = rect.y + rect.height - 1;
    let (first_row, last_row) = selection.row_range();
    let y_lo = first_row.max(inner_y0);
    let y_hi = last_row.min(inner_y1.saturating_sub(1));
    if y_lo > y_hi {
        return;
    }
    let buffer = frame.buffer_mut();
    for row in y_lo..=y_hi {
        for column in inner_x0..inner_x1 {
            if let Some(cell) = buffer.cell_mut((column, row)) {
                cell.set_bg(Color::Blue);
                cell.set_fg(Color::White);
            }
        }
    }
}

/// Recompute the pane rects `render_normal` / `render_maximized` draw,
/// for mouse hit-testing.
fn compute_pane_rects(state: &mut State, area: Rect) {
    state.pane_rects.clear();
    if state.maximized {
        let outer = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(1),
                Constraint::Length(1),
                Constraint::Length(1),
            ])
            .split(area);
        state.pane_rects.insert(state.focus, outer[0]);
    } else {
        let outer = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Percentage(70),
                Constraint::Length(1),
                Constraint::Percentage(30),
                Constraint::Length(1),
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
        state.pane_rects.insert(Focus::Log, upper[0]);
        state.pane_rects.insert(Focus::Bus, right[0]);
        state.pane_rects.insert(Focus::Can, right[1]);
        state.pane_rects.insert(Focus::Shell, outer[2]);
    }
}

/// Left drag inside a pane focuses it and selects rows; releasing copies
/// them to the clipboard, as `Ctrl-Y` does.
fn handle_mouse(state: &mut State, event: MouseEvent) {
    match event.kind {
        MouseEventKind::Down(MouseButton::Left) => {
            if let Some(focus) = pane_at(state, event.column, event.row) {
                state.focus = focus;
                state.selection = Some(Selection {
                    focus,
                    anchor_row: event.row,
                    cursor_row: event.row,
                });
            }
        }
        MouseEventKind::Drag(MouseButton::Left) => {
            if let Some(ref mut selection) = state.selection {
                if let Some(rect) = state.pane_rects.get(&selection.focus).copied() {
                    // Clamp to the pane's inner area (inside borders).
                    let inner_top = rect.y + 1;
                    let inner_bot = rect.y + rect.height.saturating_sub(2);
                    selection.cursor_row = event.row.clamp(inner_top, inner_bot);
                }
            }
        }
        MouseEventKind::Up(MouseButton::Left) => {
            if let Some(selection) = state.selection.take() {
                let text = selection_text(state, &selection);
                if !text.is_empty() {
                    let (method, _) = copy_to_clipboard(&text);
                    let lines = text.split('\n').count();
                    state.toast = Some((
                        format!(
                            "selected {} line(s) from {} → clipboard ({})",
                            lines,
                            focus_name(selection.focus),
                            method,
                        ),
                        Instant::now(),
                    ));
                }
            }
        }
        _ => {}
    }
}

/// Hit-test: which pane (if any) contains the cell at column/row?
fn pane_at(state: &State, column: u16, row: u16) -> Option<Focus> {
    state.pane_rects.iter().find_map(|(focus, rect)| {
        if column >= rect.x
            && column < rect.x + rect.width
            && row >= rect.y
            && row < rect.y + rect.height
        {
            Some(*focus)
        } else {
            None
        }
    })
}

fn focus_name(focus: Focus) -> &'static str {
    match focus {
        Focus::Log => "LOG",
        Focus::Bus => "BUS",
        Focus::Can => "CAN",
        Focus::Shell => "SHELL",
    }
}

/// The whole lines the selection covers, laid out as `render_*` lays them.
fn selection_text(state: &State, selection: &Selection) -> String {
    let rect = match state.pane_rects.get(&selection.focus) {
        Some(rect) => *rect,
        None => return String::new(),
    };
    if rect.height < 3 {
        return String::new();
    }
    let inner_h = rect.height.saturating_sub(2) as usize;
    let inner_w = rect.width.saturating_sub(2) as usize;
    let inner_y0 = rect.y + 1;
    let (first_row, last_row) = selection.row_range();
    let y_lo = first_row.max(inner_y0);
    let y_hi = last_row.min(rect.y + rect.height - 2);
    if y_lo > y_hi || inner_w == 0 {
        return String::new();
    }
    let rel_start = (y_lo - inner_y0) as usize;
    let rel_end = (y_hi - inner_y0) as usize;

    let lines = pane_visible_lines(state, selection.focus, inner_h, inner_w);

    // Accumulate each line's wrapped rows to find those in the range.
    let mut selected = Vec::new();
    let mut row_offset = 0usize;
    for line in &lines {
        let rendered_width = line.width().max(1);
        let taken = rendered_width.div_ceil(inner_w).max(1);
        let line_start = row_offset;
        let line_end = row_offset + taken - 1;
        if line_end >= rel_start && line_start <= rel_end {
            selected.push(line_to_plain(line));
        }
        row_offset += taken;
        if row_offset > rel_end {
            break;
        }
    }
    selected.join("\n")
}

/// The visible `Line`s of `focus`, in the order `render_*` draws them.
fn pane_visible_lines(
    state: &State,
    focus: Focus,
    inner_h: usize,
    inner_w: usize,
) -> Vec<Line<'static>> {
    match focus {
        Focus::Log => visible_lines(
            &state.logs,
            state.log_follow,
            state.log_scroll,
            inner_h,
            inner_w,
        ),
        Focus::Bus => {
            let filtered = candidate_bus_rows(state);
            let start = if state.bus_follow {
                visible_start_bus_refs(
                    &filtered,
                    inner_h,
                    inner_w,
                    state.bus_source_w,
                    state.bus_name_w,
                )
            } else {
                state
                    .bus_scroll
                    .min(filtered.len().saturating_sub(inner_h) as u16) as usize
            };
            filtered
                .iter()
                .skip(start)
                .map(|r| format_bus_row(r, state))
                .collect()
        }
        Focus::Can => {
            let filtered = candidate_can_rows(state);
            let start = if state.can_follow {
                visible_start_refs(
                    &filtered,
                    inner_h,
                    inner_w,
                    state.can_node_w,
                    state.can_net_w,
                    state.can_frame_w,
                    state.can_view,
                )
            } else {
                state
                    .can_scroll
                    .min(filtered.len().saturating_sub(inner_h) as u16) as usize
            };
            filtered
                .iter()
                .skip(start)
                .map(|r| format_can_row(r, state, state.can_view))
                .collect()
        }
        Focus::Shell => {
            if let Some(node_state) = state.by_node.get(&state.current) {
                visible_lines(
                    &node_state.shell_out,
                    state.shell_follow,
                    state.shell_scroll,
                    inner_h,
                    inner_w,
                )
            } else {
                Vec::new()
            }
        }
    }
}

/// The visible slice of a `VecDeque<Line>`-backed pane, as `render_*` draws it.
fn visible_lines(
    lines: &VecDeque<Line<'static>>,
    follow: bool,
    scroll: u16,
    inner_h: usize,
    inner_w: usize,
) -> Vec<Line<'static>> {
    let total = lines.len();
    let start = if follow {
        visible_start(lines, inner_h, inner_w)
    } else {
        scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };
    lines.iter().skip(start).cloned().collect()
}

fn render_normal(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    // The node tab strip sits above the shell, the only pane bound to one node.
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage(70), // upper: logs + bus + can
            Constraint::Length(1),      // node tab strip (drives shell)
            Constraint::Percentage(30), // shell
            Constraint::Length(2),      // footer
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

    render_logs(frame, upper[0], state);
    render_bus(frame, right[0], state);
    render_can(frame, right[1], state);
    render_tabs(frame, outer[1], state);
    render_shell(frame, outer[2], state);
    render_status(frame, outer[3], state);
}

/// Fullscreen mode: the focused pane gets the area above the tabs and footer.
fn render_maximized(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(1),    // focused pane
            Constraint::Length(1), // node tab strip
            Constraint::Length(2), // footer
        ])
        .split(area);

    match state.focus {
        Focus::Log => render_logs(frame, outer[0], state),
        Focus::Bus => render_bus(frame, outer[0], state),
        Focus::Can => render_can(frame, outer[0], state),
        Focus::Shell => render_shell(frame, outer[0], state),
    }
    render_tabs(frame, outer[1], state);
    render_status(frame, outer[2], state);
}

fn render_tabs(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    //   IEx ▸  ● F1 vms   ● F2 infotainment   ○ F3 bridge-radio_control
    let mut spans: Vec<Span<'static>> = vec![
        Span::styled(" IEx ", Style::default().add_modifier(Modifier::DIM)),
        Span::styled("▸ ", Style::default().add_modifier(Modifier::DIM)),
    ];

    for (index, name) in state.nodes.iter().enumerate() {
        let node = state.by_node.get(name);
        let color = node.map(|n| n.color).unwrap_or(Color::White);
        let up = node.map(|n| n.up).unwrap_or(false);
        let active = name == &state.current;

        let dot = if up { "●" } else { "○" };
        let fkey = format!("F{}", index + 1);

        let label_style = {
            let mut style = Style::default().fg(color);
            if active {
                style = style
                    .add_modifier(Modifier::BOLD)
                    .add_modifier(Modifier::UNDERLINED);
            }
            if !up {
                style = style.add_modifier(Modifier::DIM);
            }
            style
        };

        let dot_style = {
            let mut style = Style::default().fg(color);
            if !up {
                style = style.add_modifier(Modifier::DIM);
            }
            style
        };

        let fkey_style = {
            let mut style = Style::default().add_modifier(Modifier::DIM);
            if active {
                style = style.add_modifier(Modifier::BOLD);
            }
            style
        };

        if index > 0 {
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

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_logs(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let up = state.by_node.values().filter(|n| n.up).count();
    let total = state.nodes.len();
    let title = format!(
        " Logs  [{}/{} up]{} ",
        up,
        total,
        max_badge(state, Focus::Log)
    );
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

    let lines: Vec<Line> = state.logs.iter().skip(start).cloned().collect();

    let paragraph = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, area);
}

/// The Bus rows the pane shows: the observer view or the chronological
/// feed, filtered. `render_bus` has its own path for the unfiltered feed.
fn candidate_bus_rows(state: &State) -> Vec<&BusRow> {
    let rows: Vec<&BusRow> = if state.bus_observer {
        state
            .bus_order
            .iter()
            .filter_map(|k| state.bus_tracks.get(k).map(|t| t.latest_row.as_ref()))
            .collect()
    } else {
        state.bus.iter().map(|r| r.as_ref()).collect()
    };
    let filter = state.bus_filter.to_lowercase();
    if filter.is_empty() {
        rows
    } else {
        rows.into_iter()
            .filter(|r| r.haystack_lc.contains(&filter))
            .collect()
    }
}

/// The CAN rows the pane shows: the observer view or the chronological
/// feed, filtered.
fn candidate_can_rows(state: &State) -> Vec<&CanRow> {
    let rows: Vec<&CanRow> = if state.can_observer {
        state
            .can_order
            .iter()
            .filter_map(|k| state.can_tracks.get(k).map(|t| t.latest_row.as_ref()))
            .collect()
    } else {
        state.can.iter().map(|r| r.as_ref()).collect()
    };
    let filter = state.can_filter.to_lowercase();
    if filter.is_empty() {
        rows
    } else {
        rows.into_iter()
            .filter(|r| row_matches(r, &filter))
            .collect()
    }
}

fn render_bus(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;

    let filter_active = !state.bus_filter.is_empty();
    let filter_lc = if filter_active {
        state.bus_filter.to_lowercase()
    } else {
        String::new()
    };

    // Unfiltered, the feed is read in place rather than collected per render.
    let (lines, total): (Vec<Line>, usize) = if filter_active {
        let rows: Vec<&BusRow> = if state.bus_observer {
            state
                .bus_order
                .iter()
                .filter_map(|k| state.bus_tracks.get(k).map(|t| t.latest_row.as_ref()))
                .filter(|r| r.haystack_lc.contains(&filter_lc))
                .collect()
        } else {
            state
                .bus
                .iter()
                .map(|r| r.as_ref())
                .filter(|r| r.haystack_lc.contains(&filter_lc))
                .collect()
        };
        let total = rows.len();
        let start = if state.bus_follow {
            visible_start_bus_refs(
                &rows,
                inner_h,
                inner_w,
                state.bus_source_w,
                state.bus_name_w,
            )
        } else {
            state.bus_scroll.min(total.saturating_sub(inner_h) as u16) as usize
        };
        let lines: Vec<Line> = rows
            .iter()
            .skip(start)
            .map(|r| format_bus_row(r, state))
            .collect();
        (lines, total)
    } else if state.bus_observer {
        let total = state.bus_order.len();
        let start = if state.bus_follow {
            total.saturating_sub(inner_h)
        } else {
            state.bus_scroll.min(total.saturating_sub(inner_h) as u16) as usize
        };
        let lines: Vec<Line> = state
            .bus_order
            .iter()
            .skip(start)
            .filter_map(|k| state.bus_tracks.get(k).map(|t| t.latest_row.as_ref()))
            .map(|r| format_bus_row(r, state))
            .collect();
        (lines, total)
    } else {
        let total = state.bus.len();
        let start = if state.bus_follow {
            total.saturating_sub(inner_h)
        } else {
            state.bus_scroll.min(total.saturating_sub(inner_h) as u16) as usize
        };
        let lines: Vec<Line> = state
            .bus
            .iter()
            .skip(start)
            .map(|r| format_bus_row(r.as_ref(), state))
            .collect();
        (lines, total)
    };

    let pause = if state.bus_paused {
        " ❚❚ paused "
    } else {
        ""
    };
    let observer_badge = if state.bus_observer {
        " · observer "
    } else {
        ""
    };
    let filter_badge = if filter_active {
        format!(" · filter={:?}", state.bus_filter)
    } else {
        String::new()
    };
    let title = format!(
        " Bus  [{}]{}{}{}{} ",
        total,
        observer_badge,
        filter_badge,
        pause,
        max_badge(state, Focus::Bus),
    );
    let block = Block::default()
        .title(Span::styled(title, title_style(state, Focus::Bus)))
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Bus));

    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
}

/// The `Line` for one `BusRow`: padded source and name columns, the
/// `@N Hz` rate, and the value highlighted when it changed.
fn format_bus_row(row: &BusRow, state: &State) -> Line<'static> {
    let color = state
        .by_node
        .get(&row.node)
        .map(|n| n.color)
        .unwrap_or(Color::White);
    let source_col = truncate_pad(
        &short_source(&row.source),
        state.bus_source_w.max(1) as usize,
    );
    let name_col = truncate_pad(&row.name, state.bus_name_w.max(1) as usize);
    let rate_col = match row.ema_hz {
        Some(hz) if hz >= MIN_HZ_DISPLAY => {
            format!("{:>w$}", format!("@{}Hz", format_hz(hz)), w = RATE_W)
        }
        _ => format!("{:>w$}", "", w = RATE_W),
    };
    let value_style = if row.changed {
        Style::default()
            .fg(Color::Yellow)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
    };
    Line::from(vec![
        Span::styled(
            source_col,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(name_col, Style::default().add_modifier(Modifier::BOLD)),
        Span::raw("  "),
        Span::styled(rate_col, Style::default().add_modifier(Modifier::DIM)),
        Span::raw("  "),
        Span::styled(row.value.clone(), value_style),
    ])
}

/// Index of the first Bus row to draw so the newest rows fill the pane.
fn visible_start_bus_refs(
    rows: &[&BusRow],
    inner_h: usize,
    inner_w: usize,
    source_w: u16,
    name_w: u16,
) -> usize {
    if inner_h == 0 || inner_w == 0 || rows.is_empty() {
        return rows.len();
    }
    let prefix_len = source_w.max(1) as usize + 2 + name_w.max(1) as usize + 2 + RATE_W + 2;
    let mut used = 0usize;
    for (rev_i, row) in rows.iter().rev().enumerate() {
        let rendered_width = prefix_len + row.value.len();
        let taken = rendered_width.div_ceil(inner_w).max(1);
        if used + taken > inner_h {
            return rows.len() - rev_i;
        }
        used += taken;
    }
    0
}

fn render_can(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let rows = candidate_can_rows(state);

    let pause = if state.can_paused {
        " ❚❚ paused "
    } else {
        ""
    };
    let observer_badge = if state.can_observer {
        " · observer "
    } else {
        ""
    };
    let filter_badge = if !state.can_filter.is_empty() {
        format!(" · filter={:?}", state.can_filter)
    } else {
        String::new()
    };
    let title = format!(
        " CAN  [{}]  view={}{}{}{}{} ",
        rows.len(),
        state.can_view.label(),
        observer_badge,
        filter_badge,
        pause,
        max_badge(state, Focus::Can),
    );
    let block = Block::default()
        .title(Span::styled(title, title_style(state, Focus::Can)))
        .borders(Borders::ALL)
        .border_style(focus_style(state, Focus::Can));

    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;
    let total = rows.len();
    let start = if state.can_follow {
        visible_start_refs(
            &rows,
            inner_h,
            inner_w,
            state.can_node_w,
            state.can_net_w,
            state.can_frame_w,
            state.can_view,
        )
    } else {
        state.can_scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };

    let lines: Vec<Line> = rows
        .iter()
        .skip(start)
        .map(|row| format_can_row(row, state, state.can_view))
        .collect();
    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
}

/// Case-insensitive substring match against the row's `haystack_lc`.
fn row_matches(row: &CanRow, needle_lc: &str) -> bool {
    row.haystack_lc.contains(needle_lc)
}

/// The `Line` for one `CanRow`, its prefix padded so the signals line up;
/// `view` picks decoded signals, raw hex or both.
fn format_can_row(row: &CanRow, state: &State, view: CanView) -> Line<'static> {
    let color = state
        .by_node
        .get(&row.node)
        .map(|n| n.color)
        .unwrap_or(Color::White);

    let node_col = truncate_pad(&row.node, state.can_node_w.max(1) as usize);
    let net_col = truncate_pad(&row.network, state.can_net_w.max(1) as usize);
    let frame_col = truncate_pad(&row.frame, state.can_frame_w.max(1) as usize);
    let rate_col = match row.ema_hz {
        Some(hz) if hz >= MIN_HZ_DISPLAY => {
            format!("{:>w$}", format!("@{}Hz", format_hz(hz)), w = RATE_W)
        }
        _ => format!("{:>w$}", "", w = RATE_W),
    };

    let mut spans: Vec<Span<'static>> = vec![
        Span::styled(
            node_col,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(net_col, Style::default()),
        Span::raw("  "),
        Span::styled(frame_col, Style::default().add_modifier(Modifier::BOLD)),
        Span::raw("  "),
        Span::styled(rate_col, Style::default().add_modifier(Modifier::DIM)),
        Span::raw("  "),
    ];

    let show_signals = !matches!(view, CanView::Raw);
    let show_raw = !matches!(view, CanView::Decoded);

    if show_signals {
        if row.signal_pairs.is_empty() && view == CanView::Decoded {
            spans.push(Span::styled(
                format!("(no decode) raw={}", row.raw),
                Style::default().add_modifier(Modifier::DIM),
            ));
        } else {
            spans.extend(format_signal_pairs(&row.signal_pairs, &row.changed_keys));
        }
    }

    if show_raw {
        if show_signals && !row.signal_pairs.is_empty() {
            spans.push(Span::styled(
                "  | ",
                Style::default().add_modifier(Modifier::DIM),
            ));
        }
        spans.push(Span::styled(
            format!("raw={}", row.raw),
            Style::default().add_modifier(Modifier::DIM),
        ));
    }

    Line::from(spans)
}

/// Decoded `key=value` pairs, highlighting the keys in `changed_keys`.
fn format_signal_pairs(pairs: &[(String, String)], changed_keys: &[String]) -> Vec<Span<'static>> {
    let changed: std::collections::HashSet<&str> =
        changed_keys.iter().map(|s| s.as_str()).collect();
    let mut spans = Vec::with_capacity(pairs.len() * 2);
    for (index, (key, value)) in pairs.iter().enumerate() {
        if index > 0 {
            spans.push(Span::raw(" "));
        }
        let style = if changed.contains(key.as_str()) {
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().add_modifier(Modifier::DIM)
        };
        spans.push(Span::styled(format!("{}={}", key, value), style));
    }
    spans
}

/// Fixed, so the signals line up whether or not a rate is known.
const RATE_W: usize = 9;

/// `text` truncated with an ellipsis or padded to exactly `width`.
fn truncate_pad(text: &str, width: usize) -> String {
    if text.chars().count() > width {
        let mut truncated: String = text.chars().take(width.saturating_sub(1)).collect();
        truncated.push('…');
        truncated
    } else {
        format!("{:<width$}", text, width = width)
    }
}

/// Format a Hz reading for the `@N Hz` tag — integer when ≥ 10 Hz,
/// one decimal when between 1 and 10, otherwise two decimals.
fn format_hz(hz: f32) -> String {
    if hz >= 10.0 {
        format!("{:.0}", hz)
    } else if hz >= 1.0 {
        format!("{:.1}", hz)
    } else {
        format!("{:.2}", hz)
    }
}

/// Best-effort split of a signals string (`k1=v1 k2={:ok, 42}`) into
/// `(key, value)` pairs, on ` <ident>=` boundaries so values with spaces
/// survive intact.
fn parse_signal_pairs(signals: &str) -> Vec<(String, String)> {
    if signals.is_empty() {
        return Vec::new();
    }
    let bytes = signals.as_bytes();
    let mut starts: Vec<usize> = vec![0];
    let mut position = 0;
    while position < bytes.len() {
        if bytes[position] == b' ' {
            let mut identifier_end = position + 1;
            let ident_start = identifier_end;
            while identifier_end < bytes.len()
                && (bytes[identifier_end].is_ascii_alphanumeric() || bytes[identifier_end] == b'_')
            {
                identifier_end += 1;
            }
            if identifier_end > ident_start
                && identifier_end < bytes.len()
                && bytes[identifier_end] == b'='
            {
                starts.push(position + 1);
            }
        }
        position += 1;
    }
    starts.push(bytes.len() + 1);

    let mut pairs = Vec::with_capacity(starts.len().saturating_sub(1));
    for window in starts.windows(2) {
        let start_pos = window[0];
        let end_pos = window[1].saturating_sub(1).min(bytes.len());
        if start_pos >= end_pos {
            continue;
        }
        let token = &signals[start_pos..end_pos];
        let token = token.trim();
        if let Some(equals) = token.find('=') {
            pairs.push((token[..equals].to_string(), token[equals + 1..].to_string()));
        }
    }
    pairs
}

/// Keys whose value differs between two observations of one `CanKey`;
/// a new key counts as changed, a removed one is ignored.
fn diff_pairs(prev: &[(String, String)], new: &[(String, String)]) -> Vec<String> {
    let prev_map: HashMap<&str, &str> = prev
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    new.iter()
        .filter(|(key, value)| {
            prev_map
                .get(key.as_str())
                .map(|previous| *previous != value)
                .unwrap_or(true)
        })
        .map(|(key, _)| key.clone())
        .collect()
}

/// The lowercase text the `/` filter searches.
fn build_haystack(node: &str, network: &str, frame: &str, signals: &str, raw: &str) -> String {
    let mut haystack = String::with_capacity(
        node.len() + network.len() + frame.len() + signals.len() + raw.len() + 4,
    );
    haystack.push_str(&node.to_lowercase());
    haystack.push('\t');
    haystack.push_str(&network.to_lowercase());
    haystack.push('\t');
    haystack.push_str(&frame.to_lowercase());
    haystack.push('\t');
    haystack.push_str(&signals.to_lowercase());
    haystack.push('\t');
    haystack.push_str(&raw.to_lowercase());
    haystack
}

/// Index of the first CAN row to draw so the newest rows fill the pane,
/// for the chronological feed and the observer view alike.
fn visible_start_refs(
    rows: &[&CanRow],
    inner_h: usize,
    inner_w: usize,
    node_w: u16,
    net_w: u16,
    frame_w: u16,
    view: CanView,
) -> usize {
    if inner_h == 0 || inner_w == 0 || rows.is_empty() {
        return rows.len();
    }
    let prefix_len = node_w.max(1) as usize
        + 2
        + net_w.max(1) as usize
        + 2
        + frame_w.max(1) as usize
        + 2
        + RATE_W
        + 2;
    let mut used = 0usize;
    for (rev_i, row) in rows.iter().rev().enumerate() {
        let body_len = match view {
            CanView::Both => {
                if !row.signals.is_empty() && !row.raw.is_empty() {
                    row.signals.len() + row.raw.len() + " | raw=".len()
                } else {
                    row.signals.len().max(row.raw.len() + "raw=".len())
                }
            }
            CanView::Decoded => row
                .signals
                .len()
                .max("(no decode) raw=".len() + row.raw.len()),
            CanView::Raw => row.raw.len() + "raw=".len(),
        };
        let rendered_width = (prefix_len + body_len).max(1);
        let taken = rendered_width.div_ceil(inner_w).max(1);
        if used + taken > inner_h {
            return rows.len() - rev_i;
        }
        used += taken;
    }
    0
}

/// Index of the first line to draw so the newest lines, wrapped at
/// `inner_w`, fill the `inner_h` rows.
fn visible_start(lines: &VecDeque<Line<'static>>, inner_h: usize, inner_w: usize) -> usize {
    if inner_h == 0 || inner_w == 0 || lines.is_empty() {
        return lines.len();
    }
    let mut rows = 0usize;
    for (rev_i, line) in lines.iter().rev().enumerate() {
        let rendered_width = line.width().max(1);
        let taken = rendered_width.div_ceil(inner_w).max(1);
        if rows + taken > inner_h {
            return lines.len() - rev_i;
        }
        rows += taken;
    }
    0
}

fn render_shell(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let current_color = state
        .by_node
        .get(&state.current)
        .map(|n| n.color)
        .unwrap_or(Color::Cyan);
    let title = format!(
        " IEx · {}{} ",
        state.current,
        max_badge(state, Focus::Shell)
    );
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
    frame.render_widget(block, area);

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

    frame.render_widget(
        Paragraph::new(out_lines).wrap(Wrap { trim: false }),
        out_area,
    );

    let input_line = Line::from(vec![
        Span::styled("❯ ", Style::default().fg(current_color)),
        Span::raw(state.input.clone()),
    ]);
    frame.render_widget(Paragraph::new(input_line), input_area);

    if state.focus == Focus::Shell {
        let col = input_area.x + 2 + state.cursor as u16;
        let max_col = input_area.x + input_area.width.saturating_sub(1);
        frame.set_cursor_position((col.min(max_col), input_area.y));
    }
}

fn render_status(frame: &mut ratatui::Frame, area: Rect, state: &State) {
    let bar_style = Style::default().fg(Color::White).bg(Color::DarkGray);

    if let Some((ref message, at)) = state.toast {
        if at.elapsed() < TOAST_TTL {
            let toast_style = Style::default().fg(Color::Black).bg(Color::LightGreen);
            let paragraph =
                Paragraph::new(vec![Line::from(""), Line::from(format!(" {} ", message))])
                    .style(toast_style);
            frame.render_widget(paragraph, area);
            return;
        }
    }

    if state.can_filter_editing || state.bus_filter_editing {
        let text = if state.can_filter_editing {
            &state.can_filter
        } else {
            &state.bus_filter
        };
        let prompt_style = Style::default().fg(Color::Black).bg(Color::Yellow);
        let paragraph = Paragraph::new(vec![
            Line::from(""),
            Line::from(vec![
                Span::styled(" /", prompt_style),
                Span::styled(format!("{} ", text), prompt_style),
                Span::styled(" Enter=apply  Esc=cancel ", bar_style),
            ]),
        ])
        .style(bar_style);
        frame.render_widget(paragraph, area);
        return;
    }

    let focus_label = match state.focus {
        Focus::Log => "log",
        Focus::Bus => "bus",
        Focus::Can => "can",
        Focus::Shell => "shell",
    };
    let pane_keys = match state.focus {
        Focus::Bus => {
            let obs = if state.bus_observer { "on" } else { "off" };
            format!("Space=pause  ↑↓=scroll  o=observer({})  /=filter  ", obs,)
        }
        Focus::Can => {
            let obs = if state.can_observer { "on" } else { "off" };
            format!(
                "Space=pause  ↑↓=scroll  i=view({})  o=observer({})  /=filter  ",
                state.can_view.label(),
                obs,
            )
        }
        Focus::Log => "↑↓=scroll  ".to_string(),
        Focus::Shell => String::new(),
    };
    let fs = if state.maximized {
        "Alt-Enter=restore  "
    } else {
        "Alt-Enter=fullscreen  "
    };
    let copy_key = if matches!(state.focus, Focus::Shell) {
        "Ctrl-Y=copy"
    } else {
        "y/Ctrl-Y=copy"
    };
    let help = if state.nodes.len() > 1 {
        format!(
            " [{}] Tab=pane  {}{}{}  Ctrl-N/P=cycle node  Enter=eval  Ctrl-C/q=quit ",
            focus_label, pane_keys, fs, copy_key,
        )
    } else {
        format!(
            " [{}] Tab=pane  {}{}{}  Enter=eval  Ctrl-C/q=quit ",
            focus_label, pane_keys, fs, copy_key,
        )
    };
    let paragraph = Paragraph::new(vec![Line::from(""), Line::from(help)]).style(bar_style);
    frame.render_widget(paragraph, area);
}

fn focus_style(state: &State, pane: Focus) -> Style {
    if state.focus == pane {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        // The default foreground: DarkGray vanishes on light themes.
        Style::default()
    }
}

/// Title style: quiet when unfocused; focused, the block's `border_style` colours it.
fn title_style(state: &State, pane: Focus) -> Style {
    if state.focus == pane {
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().add_modifier(Modifier::BOLD)
    }
}

/// " ● MAX " badge for the title of the fullscreen pane, else empty.
fn max_badge(state: &State, pane: Focus) -> &'static str {
    if state.maximized && state.focus == pane {
        " ● MAX"
    } else {
        ""
    }
}

fn handle_key(state: &mut State, code: KeyCode, mods: KeyModifiers) -> Result<()> {
    if state.can_filter_editing || state.bus_filter_editing {
        handle_filter_edit_key(state, code, mods);
        return Ok(());
    }

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
    // Plain `y` / `c` copy only outside Shell, which takes them as input.
    let ctrl_y = matches!(code, KeyCode::Char('y') | KeyCode::Char('Y'))
        && mods.contains(KeyModifiers::CONTROL);
    let plain_copy = state.focus != Focus::Shell
        && !state.can_filter_editing
        && !state.bus_filter_editing
        && !mods.contains(KeyModifiers::CONTROL)
        && matches!(code, KeyCode::Char('y') | KeyCode::Char('c'));
    if ctrl_y || plain_copy {
        handle_copy(state);
        return Ok(());
    }
    if let KeyCode::F(number) = code {
        if (1..=9).contains(&number) {
            state.jump((number - 1) as usize);
            return Ok(());
        }
    }
    // Not F11, which many terminal emulators take for their own fullscreen.
    if code == KeyCode::Enter && mods.contains(KeyModifiers::ALT) {
        state.maximized = !state.maximized;
        return Ok(());
    }
    if handle_pane_specific_key(state, code) {
        return Ok(());
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
            state.bus.len(),
            &mut state.bus_scroll,
            &mut state.bus_follow,
            &mut state.bus_paused,
            &mut state.quit,
        ),
        Focus::Can => handle_pane_scroll(
            code,
            state.can.len(),
            &mut state.can_scroll,
            &mut state.can_follow,
            &mut state.can_paused,
            &mut state.quit,
        ),
        Focus::Shell => handle_shell(state, code)?,
    }
    Ok(())
}

/// Dispatch one keystroke while Bus or CAN filter edit mode is active.
/// Ctrl-C still quits; Esc clears + exits; Enter commits; Backspace + char
/// amend the filter string.
fn handle_filter_edit_key(state: &mut State, code: KeyCode, mods: KeyModifiers) {
    // Ctrl-C always quits, even during filter edit — check before
    // borrowing the pane-specific filter fields.
    if matches!(code, KeyCode::Char('c')) && mods.contains(KeyModifiers::CONTROL) {
        state.quit = true;
        return;
    }
    let (filter, editing) = if state.can_filter_editing {
        (&mut state.can_filter, &mut state.can_filter_editing)
    } else {
        (&mut state.bus_filter, &mut state.bus_filter_editing)
    };
    match code {
        KeyCode::Esc => {
            filter.clear();
            *editing = false;
        }
        KeyCode::Enter => {
            *editing = false;
        }
        KeyCode::Backspace => {
            filter.pop();
        }
        KeyCode::Char(character) => filter.push(character),
        _ => {}
    }
}

/// Bus / CAN focus-only bindings — chars would otherwise fight Shell input.
/// Observer toggle (`o`) and filter (`/`) behave the same way in both panes;
/// CAN adds `i` to cycle the view mode. Returns `true` when the key was
/// consumed so the caller can skip further dispatch.
fn handle_pane_specific_key(state: &mut State, code: KeyCode) -> bool {
    match state.focus {
        Focus::Bus => match code {
            KeyCode::Char('o') => {
                state.bus_observer = !state.bus_observer;
                state.bus_scroll = 0;
                state.bus_follow = true;
                true
            }
            KeyCode::Char('/') => {
                state.bus_filter_editing = true;
                state.bus_filter.clear();
                true
            }
            _ => false,
        },
        Focus::Can => match code {
            KeyCode::Char('i') => {
                state.can_view = state.can_view.next();
                true
            }
            KeyCode::Char('o') => {
                state.can_observer = !state.can_observer;
                // The observer view has its own row indices.
                state.can_scroll = 0;
                state.can_follow = true;
                true
            }
            KeyCode::Char('/') => {
                state.can_filter_editing = true;
                state.can_filter.clear();
                true
            }
            _ => false,
        },
        _ => false,
    }
}

fn handle_pane_scroll(
    code: KeyCode,
    row_count: usize,
    scroll: &mut u16,
    follow: &mut bool,
    paused: &mut bool,
    quit: &mut bool,
) {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => *quit = true,
        // Freeze: new messages are dropped and the view stops following.
        KeyCode::Char(' ') | KeyCode::Char('p') => {
            *paused = !*paused;
            if *paused {
                *follow = false;
                *scroll = row_count.saturating_sub(1) as u16;
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
            if *scroll as usize >= row_count {
                *follow = true;
            }
        }
        KeyCode::PageUp => {
            *follow = false;
            *scroll = scroll.saturating_sub(10);
        }
        KeyCode::PageDown => {
            *scroll = scroll.saturating_add(10);
            if *scroll as usize >= row_count {
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
            state.history_index = None;
            if let Some(node_state) = state.by_node.get(&state.current) {
                // Input typed while the node is down is dropped by its supervisor.
                let _ = node_state.stdin.send(format!("{}\n", line));
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
        KeyCode::Char(character) => {
            state.input.insert(state.cursor, character);
            state.cursor += character.len_utf8();
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
                let new_index = match state.history_index {
                    None => state.history.len() - 1,
                    Some(0) => 0,
                    Some(index) => index - 1,
                };
                state.history_index = Some(new_index);
                state.input = state.history[new_index].clone();
                state.cursor = state.input.len();
            }
        }
        KeyCode::Down => {
            if let Some(index) = state.history_index {
                if index + 1 < state.history.len() {
                    state.history_index = Some(index + 1);
                    state.input = state.history[index + 1].clone();
                } else {
                    state.history_index = None;
                    state.input.clear();
                }
                state.cursor = state.input.len();
            }
        }
        _ => {}
    }
    Ok(())
}

fn prev_char_boundary(text: &str, index: usize) -> usize {
    if index == 0 {
        return 0;
    }
    let mut boundary = index - 1;
    while boundary > 0 && !text.is_char_boundary(boundary) {
        boundary -= 1;
    }
    boundary
}

fn next_char_boundary(text: &str, index: usize) -> usize {
    let mut boundary = index + 1;
    let len = text.len();
    while boundary < len && !text.is_char_boundary(boundary) {
        boundary += 1;
    }
    boundary.min(len)
}

/// Flatten a `Line`'s span content into plain text, dropping styling.
fn line_to_plain(line: &Line) -> String {
    let mut text = String::new();
    for span in &line.spans {
        text.push_str(span.content.as_ref());
    }
    text
}

/// Gather the currently-visible content of the focused pane as plain
/// text (one logical row per line). Respects CAN view / filter /
/// observer so users copy exactly what the pane renders.
fn pane_snapshot(state: &State) -> (&'static str, String) {
    match state.focus {
        Focus::Log => (
            "log",
            state
                .logs
                .iter()
                .map(line_to_plain)
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        Focus::Bus => {
            let text = candidate_bus_rows(state)
                .iter()
                .map(|r| line_to_plain(&format_bus_row(r, state)))
                .collect::<Vec<_>>()
                .join("\n");
            ("bus", text)
        }
        Focus::Can => {
            let text = candidate_can_rows(state)
                .iter()
                .map(|r| line_to_plain(&format_can_row(r, state, state.can_view)))
                .collect::<Vec<_>>()
                .join("\n");
            ("can", text)
        }
        Focus::Shell => {
            let text = state
                .by_node
                .get(&state.current)
                .map(|node_state| {
                    node_state
                        .shell_out
                        .iter()
                        .map(line_to_plain)
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            ("shell", text)
        }
    }
}

/// Writes a pane copy, readable only by the user, under `$XDG_RUNTIME_DIR`
/// or else `~/.cache/ovcs`. Returns its path, or `None` if it could not be
/// written.
fn write_copy_file(label: &str, text: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(runtime_dir) => std::path::PathBuf::from(runtime_dir),
        None => std::path::PathBuf::from(std::env::var_os("HOME")?).join(".cache/ovcs"),
    };
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .ok()?;
    let path = dir.join(format!("ovcs_attach_copy_{}.txt", label));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .ok()?;
    file.write_all(text.as_bytes()).ok()?;
    Some(path)
}

/// Copy the focused pane's text to the system clipboard and, in full, to
/// `ovcs_attach_copy_<pane>.txt` in the user's private runtime directory.
/// Sets a footer toast so the user gets visible confirmation.
fn handle_copy(state: &mut State) {
    let focus_name = match state.focus {
        Focus::Log => "LOG",
        Focus::Bus => "BUS",
        Focus::Can => "CAN",
        Focus::Shell => "SHELL",
    };
    let (label, text) = pane_snapshot(state);
    let bytes = text.len();
    let lines = text.split('\n').count();

    // Best effort: a failed write only drops the file from the toast.
    let copy_file = write_copy_file(label, &text);

    let clip_slice = clip_to_boundary(&text, CLIPBOARD_CAP_BYTES);
    let clipped = clip_slice.len() < text.len();

    let (method, copy_ok) = copy_to_clipboard(clip_slice);

    let file_note = match &copy_file {
        Some(path) => format!(", full copy in {}", path.display()),
        None => String::new(),
    };
    let clip_note = match method {
        "osc52" => format!(
            " ⚠ clipboard via OSC 52 (install wl-clipboard or xclip for reliable copy){}",
            file_note,
        ),
        _ if !copy_ok => format!(" ⚠ clipboard copy via {} failed{}", method, file_note),
        _ if clipped => format!(
            " (clipboard got last {} KB via {}{})",
            clip_slice.len() / 1024,
            method,
            file_note,
        ),
        _ => format!(" → clipboard ({}){}", method, file_note),
    };
    state.toast = Some((
        format!(
            "copied {} pane ({} lines, {} bytes){}",
            focus_name, lines, bytes, clip_note,
        ),
        Instant::now(),
    ));
}

/// The newest `cap` bytes of `text`, cut at a UTF-8 character boundary.
fn clip_to_boundary(text: &str, cap: usize) -> &str {
    if text.len() <= cap {
        return text;
    }
    let mut start = text.len() - cap;
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// Push `text` onto the system clipboard with the first helper that works
/// (`wl-copy`, `xclip`, `xsel`, `pbcopy`), else OSC 52, which tmux,
/// gnome-terminal and konsole drop by default. Returns `(method, copied)`.
fn copy_to_clipboard(text: &str) -> (&'static str, bool) {
    use std::process::{Command, Stdio};

    let helpers: &[(&str, &str, &[&str])] = &[
        ("wl-copy", "wl-copy", &[]),
        ("xclip", "xclip", &["-selection", "clipboard"]),
        ("xsel", "xsel", &["--clipboard", "--input"]),
        ("pbcopy", "pbcopy", &[]),
    ];
    for (name, program, args) in helpers {
        let mut spawn = Command::new(program);
        spawn.args(*args);
        spawn.stdin(Stdio::piped());
        spawn.stdout(Stdio::null());
        spawn.stderr(Stdio::null());
        match spawn.spawn() {
            Ok(mut child) => {
                if let Some(mut stdin) = child.stdin.take() {
                    let wrote = stdin.write_all(text.as_bytes()).is_ok();
                    drop(stdin);
                    let waited = child.wait();
                    let copied = wrote && waited.map(|status| status.success()).unwrap_or(false);
                    if copied {
                        return (*name, true);
                    }
                }
            }
            Err(_) => continue,
        }
    }

    // `c` is the CLIPBOARD selection, not PRIMARY.
    let encoded = STANDARD.encode(text.as_bytes());
    let wrote = write!(std::io::stdout(), "\x1b]52;c;{}\x07", encoded).is_ok();
    let _ = std::io::stdout().flush();
    ("osc52", wrote)
}
