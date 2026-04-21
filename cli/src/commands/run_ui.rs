use ansi_to_tui::IntoText;
use anyhow::Result;
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseButton, MouseEvent, MouseEventKind,
};
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
use std::io::{self, Stdout, Write as _};
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::time::{Duration, Instant};

const LOG_CAP: usize = 4000;
const SHELL_CAP: usize = 2000;
const BUS_CAP: usize = 4000;
const CAN_CAP: usize = 4000;
const HISTORY_CAP: usize = 500;

/// Exponential moving average weights for the per-key rate smoother
/// used by both Bus and CAN. `_NEW` is the weight on the newest
/// instantaneous 1/dt sample; `_PRIOR` is what's kept of the old
/// smoothed value. Tuned to react within a handful of samples
/// without jittering on per-frame noise.
const EMA_WEIGHT_NEW: f32 = 0.3;
const EMA_WEIGHT_PRIOR: f32 = 0.7;

/// Hide the `@NHz` tag on rows with rates below this — below 0.5 Hz
/// the number reads more like noise than a useful cadence.
const MIN_HZ_DISPLAY: f32 = 0.5;

/// How long a transient footer toast (copy, selection, etc) stays
/// visible before the normal key-hint line takes over again.
const TOAST_TTL: Duration = Duration::from_secs(3);

/// `OSC 52` clipboard payload cap. Most terminals silently drop
/// payloads past 64–100 KB; we keep to the tail 64 KB so the paste
/// still lands even for a full buffer.
const CLIPBOARD_CAP: usize = 64 * 1024;

/// EMA-smooth the per-key emit rate by blending the latest
/// inter-arrival delta into the previously smoothed value. Returns
/// 0.0 if `last_ts` is equal to `now` (defensive — callers treat
/// that as "no rate yet").
fn smoothed_hz(now: Instant, last_ts: Instant, prev_ema: f32) -> f32 {
    let dt = now.saturating_duration_since(last_ts).as_secs_f32();
    let instantaneous = if dt > 0.0 { 1.0 / dt } else { 0.0 };
    if prev_ema > 0.0 {
        prev_ema * EMA_WEIGHT_PRIOR + instantaneous * EMA_WEIGHT_NEW
    } else {
        instantaneous
    }
}

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

/// Per-node handle the TUI holds onto — one sender per interactive shell,
/// keyed by node name. Lives for the whole app: supervisors on the other
/// end reconnect transparently across node death, so dropping on
/// `NodeDown` would break every reconnect after the first.
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

/// `(source, name)` — the key the Bus pane deduplicates on for
/// rate tracking, change highlight, and observer view. Node isn't
/// part of the key because we only subscribe to `OvcsBus` on the
/// VMS node (cluster-wide fan-out), so every observation comes
/// from there.
type BusKey = (String, String);

/// One OvcsBus message row. Kept as structured data like `CanRow`
/// so the Bus pane can render different modes (observer, filter,
/// change highlight) without reparsing a pre-formatted line.
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
    /// Pre-built lowercase haystack (source, name, value) for the
    /// `/` substring filter — same trick as `CanRow.haystack_lc`.
    haystack_lc: String,
}

/// Per-`BusKey` tracking state: last observation time, smoothed
/// rate, and the latest row `Arc` shared with the chronological
/// `VecDeque`. Previous-value compare for change detection reads
/// `latest_row.value` via the Arc, so the tracker doesn't duplicate
/// a String on every push — a real saving at bus's ~1 kHz rate.
struct BusTrack {
    last_ts: Instant,
    ema_hz: f32,
    latest_row: Arc<BusRow>,
}

/// `(node, network, frame)` — the key everything in the CAN pane
/// deduplicates on: rate tracking, signal-diff, observer view.
type CanKey = (String, String, String);

/// One decoded CAN frame row. Kept as structured data (not a
/// pre-rendered `Line`) so the CAN pane can toggle between showing
/// decoded signals, raw hex, or both at render time without re-parsing
/// anything. Shared between the chronological VecDeque and the
/// observer map via `Arc` so each push only allocates one copy.
struct CanRow {
    node: String,
    network: String,
    frame: String,
    signals: String,
    raw: String,
    /// Signals pre-split into (key, value) pairs in emission order.
    /// Cheap best-effort parser: splits on ` <ident>=` boundaries, so
    /// `k1=v1 k2={:ok, 42}` still treats the whole `{:ok, 42}` as v2.
    signal_pairs: Vec<(String, String)>,
    /// Keys whose value differs from the previous observation of this
    /// `(node, network, frame)`. Drives the bold-on-change highlight.
    /// Empty for the first observation of a tuple.
    changed_keys: Vec<String>,
    /// EMA-smoothed rate in Hz at the time this row was pushed.
    /// `None` for the first sample (no inter-arrival to measure).
    ema_hz: Option<f32>,
    /// Pre-computed lowercase haystack (node, network, frame,
    /// signals, raw, tab-joined) used by the `/` substring filter.
    /// Computed once at push time so the hot render path doesn't
    /// reallocate five strings per row per tick.
    haystack_lc: String,
}

/// Per-`CanKey` tracking state: the previous observation's decoded
/// signals, when we last saw it, and the smoothed rate. The latest
/// row is shared with the chronological `VecDeque` via `Arc` so we
/// don't duplicate row data on every push.
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

/// Active mouse drag selection. Anchor is where the click started;
/// cursor is the current end. Both are absolute terminal coords so
/// the render overlay and the extractor can clip to the pane's rect
/// independently.
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
    history_idx: Option<usize>,
    focus: Focus,
    /// `Alt-Enter` fullscreens the focused pane: `render()` routes
    /// the whole main area to the focused pane's renderer instead of
    /// the usual 50/50 + 50/50 subdivision. Tabs + footer still render.
    maximized: bool,
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
    /// Max column widths observed so far (post-cap) for the Bus
    /// pane, driving `format_bus_row`'s column padding.
    bus_source_w: u16,
    bus_name_w: u16,
    /// `o`-toggled latest-value view for the Bus pane — one row per
    /// `(source, name)` in first-seen order, updated in place.
    bus_observer: bool,
    /// Insertion order of `BusKey`s (for stable observer row order).
    bus_order: Vec<BusKey>,
    /// Per-key tracking state — prev value (for change detection),
    /// last ts, rate, and the latest row Arc.
    bus_tracks: HashMap<BusKey, BusTrack>,
    /// Substring filter applied at render time. Empty = no filter.
    bus_filter: String,
    /// True while the user is typing a filter (mirrored in the
    /// footer prompt). Same UX as `can_filter_editing`.
    bus_filter_editing: bool,
    can_scroll: u16,
    can_follow: bool,
    can_paused: bool,
    can_view: CanView,
    /// Max column widths observed so far (post-cap). Updated on
    /// every `push_can`; capped to stop a pathological frame name
    /// from shoving the whole layout right. Drives
    /// `format_can_row`'s column padding so signals align across
    /// all rows.
    can_node_w: u16,
    can_net_w: u16,
    can_frame_w: u16,
    /// `o`-toggled observer view: render one row per `CanKey` in
    /// first-seen order showing the latest value, instead of the
    /// chronological feed. Same data, pure display flip.
    can_observer: bool,
    /// First-seen key order (stable ordering for observer view).
    can_order: Vec<CanKey>,
    /// Per-key tracking state — prev pairs (for diff), last ts, rate,
    /// and the latest row (for observer view).
    can_tracks: HashMap<CanKey, CanTrack>,
    /// Substring filter applied at render time (matches against the
    /// full rendered body). Empty = no filter.
    can_filter: String,
    /// While true, the footer replaces its hint row with a live edit
    /// prompt. Keystrokes mutate `can_filter` until Enter/Esc.
    can_filter_editing: bool,
    /// Transient status message shown in the footer (replaces key
    /// hints) for a couple of seconds after an action that wants
    /// visible feedback, e.g. "copied 42 lines to clipboard".
    toast: Option<(String, Instant)>,
    /// Last-known pane Rects (inclusive of border), refreshed once
    /// per tick just before `terminal.draw`. Mouse event handlers
    /// use these to hit-test which pane the cursor is in.
    pane_rects: HashMap<Focus, Rect>,
    /// Active mouse drag. `Some` between MouseDown and MouseUp, plus
    /// briefly on release so the render can show the highlight one
    /// last frame before clearing. `None` otherwise.
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
        const SOURCE_CAP: u16 = 28;
        const NAME_CAP: u16 = 28;
        let short_src_len = short_source(source).len() as u16;
        self.bus_source_w = self.bus_source_w.max(short_src_len.min(SOURCE_CAP));
        self.bus_name_w = self.bus_name_w.max((name.len() as u16).min(NAME_CAP));

        let now = Instant::now();
        let key: BusKey = (source.to_string(), name.to_string());

        // Compare against the previous latest_row to compute change
        // + EMA-smooth rate. Borrowing from the tracker's Arc avoids
        // storing `prev_value: String` separately.
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
            let mut s = String::with_capacity(source.len() + name.len() + value.len() + 2);
            s.push_str(&source.to_lowercase());
            s.push('\t');
            s.push_str(&name.to_lowercase());
            s.push('\t');
            s.push_str(&value.to_lowercase());
            s
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
        // Per-column width tracking: grow to fit the widest value
        // seen per column, but cap each column so a single
        // pathological name doesn't push signals off-screen.
        const NODE_CAP: u16 = 24;
        const NET_CAP: u16 = 16;
        const FRAME_CAP: u16 = 32;
        self.can_node_w = self.can_node_w.max((node.len() as u16).min(NODE_CAP));
        self.can_net_w = self.can_net_w.max((network.len() as u16).min(NET_CAP));
        self.can_frame_w = self.can_frame_w.max((frame.len() as u16).min(FRAME_CAP));

        let now = Instant::now();
        let pairs = parse_signal_pairs(signals);
        let key: CanKey = (node.to_string(), network.to_string(), frame.to_string());

        // Compare against the previous observation of this key to
        // compute the `changed_keys` list + EMA-smooth the rate.
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

        // Update the tracker for next time. The `latest_row` Arc shares
        // data with the VecDeque push below — no double allocation.
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
    // Capture mouse so drag-selection in the TUI can be constrained
    // to the focused pane instead of spilling across the whole
    // window. Disabled again on shutdown so the terminal's native
    // selection is restored.
    stdout.execute(EnableMouseCapture)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;

    let result = event_loop(&mut terminal, rx, nodes);

    let _ = terminal.backend_mut().execute(DisableMouseCapture);
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
                    raw,
                }) => state.push_can(&node, &network, &frame, &signals, &raw),
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

        let size = terminal.size()?;
        compute_pane_rects(&mut state, Rect::new(0, 0, size.width, size.height));
        terminal.draw(|f| render(f, &state))?;

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

fn render(f: &mut ratatui::Frame, state: &State) {
    let area = f.area();

    if state.maximized {
        render_maximized(f, area, state);
    } else {
        render_normal(f, area, state);
    }

    // Paint the drag-selection highlight after the panes so it
    // overlays the content. Clipped to the pane's inner area (inside
    // the border) so borders stay visible.
    if let Some(sel) = state.selection {
        if let Some(rect) = state.pane_rects.get(&sel.focus).copied() {
            paint_selection(f, rect, sel);
        }
    }
}

/// Invert bg/fg on cells inside the focused pane's inner area that
/// fall within the selection's row range. The selection is row-based
/// (whole terminal rows), not column-based — simpler for users and
/// matches how rows usually correspond to logical messages.
fn paint_selection(f: &mut ratatui::Frame, rect: Rect, sel: Selection) {
    if rect.width < 2 || rect.height < 2 {
        return;
    }
    let inner_x0 = rect.x + 1;
    let inner_x1 = rect.x + rect.width - 1;
    let inner_y0 = rect.y + 1;
    let inner_y1 = rect.y + rect.height - 1;
    let (r0, r1) = sel.row_range();
    let y_lo = r0.max(inner_y0);
    let y_hi = r1.min(inner_y1.saturating_sub(1));
    if y_lo > y_hi {
        return;
    }
    let buf = f.buffer_mut();
    for y in y_lo..=y_hi {
        for x in inner_x0..inner_x1 {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_bg(Color::Blue);
                cell.set_fg(Color::White);
            }
        }
    }
}

/// Recompute pane Rects matching whatever layout `render_normal` /
/// `render_maximized` would produce. Called once per tick so mouse
/// events can hit-test against the pane the user sees.
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

/// Mouse-event dispatcher. Left drag inside a pane selects rows (and
/// switches focus to that pane so other bindings still make sense).
/// Mouse up extracts the selected text and copies to the system
/// clipboard — same path as `Ctrl-Y`.
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
            if let Some(ref mut sel) = state.selection {
                if let Some(rect) = state.pane_rects.get(&sel.focus).copied() {
                    // Clamp to the pane's inner area (inside borders).
                    let inner_top = rect.y + 1;
                    let inner_bot = rect.y + rect.height.saturating_sub(2);
                    sel.cursor_row = event.row.clamp(inner_top, inner_bot);
                }
            }
        }
        MouseEventKind::Up(MouseButton::Left) => {
            if let Some(sel) = state.selection.take() {
                let text = selection_text(state, &sel);
                if !text.is_empty() {
                    let (method, _) = copy_to_clipboard(&text);
                    let lines = text.split('\n').count();
                    state.toast = Some((
                        format!(
                            "selected {} line(s) from {} → clipboard ({})",
                            lines,
                            focus_name(sel.focus),
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

/// Extract the text covered by the selection by mirroring the same
/// tail-fills-the-pane logic `render_*` use. Whole source rows are
/// returned, not column-bounded slices — we're row-selecting, not
/// rectangle-selecting.
fn selection_text(state: &State, sel: &Selection) -> String {
    let rect = match state.pane_rects.get(&sel.focus) {
        Some(r) => *r,
        None => return String::new(),
    };
    if rect.height < 3 {
        return String::new();
    }
    let inner_h = rect.height.saturating_sub(2) as usize;
    let inner_w = rect.width.saturating_sub(2) as usize;
    let inner_y0 = rect.y + 1;
    let (r0, r1) = sel.row_range();
    let y_lo = r0.max(inner_y0);
    let y_hi = r1.min(rect.y + rect.height - 2);
    if y_lo > y_hi || inner_w == 0 {
        return String::new();
    }
    let rel_start = (y_lo - inner_y0) as usize;
    let rel_end = (y_hi - inner_y0) as usize;

    // Build the visible slice of `Line`s in the same order render_*
    // passes them to the paragraph, then pick the ones overlapping
    // the row range.
    let lines = pane_visible_lines(state, sel.focus, inner_h, inner_w);

    // Walk the visible lines top-down, accumulating wrapped row span,
    // and collect lines whose span overlaps the selected row range.
    let mut out = Vec::new();
    let mut row_offset = 0usize;
    for line in &lines {
        let rendered_width = line.width().max(1);
        let taken = rendered_width.div_ceil(inner_w).max(1);
        let line_start = row_offset;
        let line_end = row_offset + taken - 1;
        if line_end >= rel_start && line_start <= rel_end {
            out.push(line_to_plain(line));
        }
        row_offset += taken;
        if row_offset > rel_end {
            break;
        }
    }
    out.join("\n")
}

/// Build the visible slice of `Line`s for `focus` in the same order `render_*`
/// passes them to the paragraph. Dedicated extraction so `selection_text` (and
/// any future whole-line copy path) reuse the exact display layout.
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
            if let Some(n) = state.by_node.get(&state.current) {
                visible_lines(
                    &n.shell_out,
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

/// Helper used by `selection_text` to compute the visible slice of a
/// `VecDeque<Line>`-backed pane (Log / Bus / Shell). Mirrors the
/// render_* logic so the extracted rows match the pane's display
/// exactly.
fn visible_lines(
    buf: &VecDeque<Line<'static>>,
    follow: bool,
    scroll: u16,
    inner_h: usize,
    inner_w: usize,
) -> Vec<Line<'static>> {
    let total = buf.len();
    let start = if follow {
        visible_start(buf, inner_h, inner_w)
    } else {
        scroll.min(total.saturating_sub(inner_h) as u16) as usize
    };
    buf.iter().skip(start).cloned().collect()
}

fn render_normal(f: &mut ratatui::Frame, area: Rect, state: &State) {
    // Layout rationale: logs/bus/can show merged streams across every node,
    // but the IEx shell is bound to one node at a time. Put the node
    // selector (tab strip) directly above the shell so the scope of that
    // selection is obvious — F1/F2/… switch which node's IEx you're
    // driving, not what the panes above display.
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

    render_logs(f, upper[0], state);
    render_bus(f, right[0], state);
    render_can(f, right[1], state);
    render_tabs(f, outer[1], state);
    render_shell(f, outer[2], state);
    render_status(f, outer[3], state);
}

/// Fullscreen mode: whichever pane has focus gets the entire area
/// between tabs and footer. Tabs + footer still render so node
/// selection and key hints remain visible.
fn render_maximized(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(1),    // focused pane
            Constraint::Length(1), // node tab strip
            Constraint::Length(2), // footer
        ])
        .split(area);

    match state.focus {
        Focus::Log => render_logs(f, outer[0], state),
        Focus::Bus => render_bus(f, outer[0], state),
        Focus::Can => render_can(f, outer[0], state),
        Focus::Shell => render_shell(f, outer[0], state),
    }
    render_tabs(f, outer[1], state);
    render_status(f, outer[2], state);
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

    // Pass the tail of entries from `start` onward — ratatui wraps them
    // top-down; any overflow past `inner_h` visual rows is clipped at the
    // bottom, which matches the stored order (newest last).
    let lines: Vec<Line> = state.logs.iter().skip(start).cloned().collect();

    let p = Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false });
    f.render_widget(p, area);
}

/// Collect the Bus rows that a pane should consider: observer view when
/// enabled (latest-per-key in insertion order), otherwise the chronological
/// feed. Applies the filter if any. Used by `selection_text` and
/// `pane_snapshot`; `render_bus` keeps its fast-path inline to avoid
/// materialising a Vec on the common no-filter / chronological case.
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

/// Collect the CAN rows that a pane should consider: observer view when
/// enabled, else chronological, filter applied. Used by `render_can`,
/// `selection_text`, and `pane_snapshot`.
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

fn render_bus(f: &mut ratatui::Frame, area: Rect, state: &State) {
    let inner_h = area.height.saturating_sub(2) as usize;
    let inner_w = area.width.saturating_sub(2) as usize;

    let filter_active = !state.bus_filter.is_empty();
    let filter_lc = if filter_active {
        state.bus_filter.to_lowercase()
    } else {
        String::new()
    };

    // Two paths: no-filter (cheap — iterate the underlying store
    // directly without materialising a 4000-entry Vec per render)
    // and filtered (must walk everything to compute total + scroll
    // range, so we build the Vec once).
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
        // Fast path: no filter, chronological. Start is the tail of
        // `state.bus` sized for the pane; iterate directly from the
        // VecDeque without building a Vec of references.
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

    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
}

/// Build a `Line` for one `BusRow` at render time. Source + name
/// columns are padded; the value is rendered bold-yellow when it
/// differs from the previous observation of the same `(source,
/// name)`. Optional `@N Hz` tag on the source column advertises the
/// broadcast rate.
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

/// Tail-aware visible-start for the Bus pane. Estimates rendered
/// width cheaply; used when `bus_follow` is on so the pane sticks to
/// the newest rows.
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

fn render_can(f: &mut ratatui::Frame, area: Rect, state: &State) {
    // Everything downstream (scroll clamp, follow tail, rendering)
    // operates on the observer-or-chronological-then-filtered slice.
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
    f.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        area,
    );
}

/// Case-insensitive substring match against the row's pre-computed
/// `haystack_lc`. Cheap enough to run against every row on every
/// render tick.
fn row_matches(row: &CanRow, needle_lc: &str) -> bool {
    row.haystack_lc.contains(needle_lc)
}

/// Build the `Line` for one `CanRow` at render time. Prefix is padded
/// to the widest observed prefix so the signals column lines up. The
/// `view` mode picks which half of the body (decoded signals, raw
/// hex, or both) is shown.
fn format_can_row(row: &CanRow, state: &State, view: CanView) -> Line<'static> {
    let color = state
        .by_node
        .get(&row.node)
        .map(|n| n.color)
        .unwrap_or(Color::White);

    let node_col = truncate_pad(&row.node, state.can_node_w.max(1) as usize);
    let net_col = truncate_pad(&row.network, state.can_net_w.max(1) as usize);
    let frame_col = truncate_pad(&row.frame, state.can_frame_w.max(1) as usize);
    // Rate column: right-aligned, fixed width so signals still line up
    // whether or not we have a sample yet.
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

/// Render decoded `key=value` pairs with yellow/bold highlight on keys in
/// `changed_keys` and dimmed styling otherwise. Keys are separated by a
/// single space so rows stay dense even when the pair list is long.
fn format_signal_pairs(pairs: &[(String, String)], changed_keys: &[String]) -> Vec<Span<'static>> {
    let changed: std::collections::HashSet<&str> =
        changed_keys.iter().map(|s| s.as_str()).collect();
    let mut spans = Vec::with_capacity(pairs.len() * 2);
    for (i, (k, v)) in pairs.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw(" "));
        }
        let style = if changed.contains(k.as_str()) {
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().add_modifier(Modifier::DIM)
        };
        spans.push(Span::styled(format!("{}={}", k, v), style));
    }
    spans
}

/// Fixed rate-column width so the signals column starts at the
/// same column on every row even when the rate isn't known yet.
const RATE_W: usize = 9;

/// Truncate `s` with an ellipsis if it would exceed `width`, else
/// pad with spaces to exactly `width`. Keeps the columns aligned
/// even when a single value is longer than our per-column cap.
fn truncate_pad(s: &str, width: usize) -> String {
    if s.chars().count() > width {
        let mut out: String = s.chars().take(width.saturating_sub(1)).collect();
        out.push('…');
        out
    } else {
        format!("{:<width$}", s, width = width)
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

/// Best-effort split of a rendered signals string (`k1=v1 k2=v2 …`)
/// into `(key, value)` pairs. Splits on ` <ident>=` boundaries so
/// values containing internal spaces (tuples, lists) survive intact.
/// Empty input → empty list.
fn parse_signal_pairs(signals: &str) -> Vec<(String, String)> {
    if signals.is_empty() {
        return Vec::new();
    }
    let bytes = signals.as_bytes();
    let mut starts: Vec<usize> = vec![0];
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b' ' {
            // Skip whitespace run.
            let mut j = i + 1;
            // Next token must be an identifier followed by `=`.
            let ident_start = j;
            while j < bytes.len() && (bytes[j].is_ascii_alphanumeric() || bytes[j] == b'_') {
                j += 1;
            }
            if j > ident_start && j < bytes.len() && bytes[j] == b'=' {
                starts.push(i + 1);
            }
        }
        i += 1;
    }
    starts.push(bytes.len() + 1);

    let mut pairs = Vec::with_capacity(starts.len().saturating_sub(1));
    for window in starts.windows(2) {
        let start_pos = window[0];
        let end_pos = window[1].saturating_sub(1).min(bytes.len());
        if start_pos >= end_pos {
            continue;
        }
        let tok = &signals[start_pos..end_pos];
        let tok = tok.trim();
        if let Some(eq) = tok.find('=') {
            pairs.push((tok[..eq].to_string(), tok[eq + 1..].to_string()));
        }
    }
    pairs
}

/// Keys whose value differs between two observations of the same
/// `(node, network, frame)`. New keys added in `new` count as
/// changed. Keys that disappeared are ignored — we render whatever
/// the latest observation carried.
fn diff_pairs(prev: &[(String, String)], new: &[(String, String)]) -> Vec<String> {
    let prev_map: HashMap<&str, &str> =
        prev.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    new.iter()
        .filter(|(k, v)| prev_map.get(k.as_str()).map(|p| *p != v).unwrap_or(true))
        .map(|(k, _)| k.clone())
        .collect()
}

/// Pre-build the lowercase haystack the `/` filter searches against.
/// One allocation per push instead of five per match during render.
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

/// Tail-aware start-of-view computation for the CAN pane. Takes a
/// slice of `&CanRow` so it works identically for the chronological
/// `VecDeque<CanRow>` and the observer view (lookup into
/// `can_tracks`).
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
        let rendered_width = line.width().max(1);
        let taken = rendered_width.div_ceil(inner_w).max(1);
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
    // Toast overrides the footer for ~3s after an action that wants
    // feedback (Ctrl-Y copy, etc). Falls back to the key-hint line
    // when expired.
    let bar_style = Style::default().fg(Color::White).bg(Color::DarkGray);

    if let Some((ref msg, at)) = state.toast {
        if at.elapsed() < TOAST_TTL {
            let toast_style = Style::default().fg(Color::Black).bg(Color::LightGreen);
            let p = Paragraph::new(vec![
                Line::from(""),
                Line::from(format!(" {} ", msg)),
            ])
            .style(toast_style);
            f.render_widget(p, area);
            return;
        }
    }

    // Edit-mode replaces the footer with a live prompt. Lets the user
    // see what they're typing without stealing screen space from the
    // Bus/CAN pane above.
    if state.can_filter_editing || state.bus_filter_editing {
        let text = if state.can_filter_editing {
            &state.can_filter
        } else {
            &state.bus_filter
        };
        let prompt_style = Style::default().fg(Color::Black).bg(Color::Yellow);
        let p = Paragraph::new(vec![
            Line::from(""),
            Line::from(vec![
                Span::styled(" /", prompt_style),
                Span::styled(format!("{} ", text), prompt_style),
                Span::styled(" Enter=apply  Esc=cancel ", bar_style),
            ]),
        ])
        .style(bar_style);
        f.render_widget(p, area);
        return;
    }

    let focus_label = match state.focus {
        Focus::Log => "log",
        Focus::Bus => "bus",
        Focus::Can => "can",
        Focus::Shell => "shell",
    };
    // The tab strip just above the shell advertises the F-key node map;
    // this footer stays focused on universal pane / editor / exit bindings
    // plus the pane-specific hints users most often need.
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
    let p = Paragraph::new(vec![Line::from(""), Line::from(help)]).style(bar_style);
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

/// " ● MAX " badge appended to a pane title when that pane is the
/// fullscreen focus. Empty string otherwise so the title collapses
/// back to normal seamlessly.
fn max_badge(state: &State, f: Focus) -> &'static str {
    if state.maximized && state.focus == f {
        " ● MAX"
    } else {
        ""
    }
}

fn handle_key(state: &mut State, code: KeyCode, mods: KeyModifiers) -> Result<()> {
    // Filter-editing mode: intercept every keystroke and feed it
    // into the active pane's filter string. Runs before the global
    // bindings so Ctrl-C still quits and Esc exits edit mode.
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
    // Ctrl-Y (universal, works in Shell) or plain `y` / `c` when the
    // focus is a read-only pane (Shell would swallow plain chars into
    // its input buffer). Both copy the focused pane to the system
    // clipboard via OSC 52 and a /tmp fallback.
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
    if let KeyCode::F(n) = code {
        if (1..=9).contains(&n) {
            state.jump((n - 1) as usize);
            return Ok(());
        }
    }
    // Alt-Enter toggles fullscreen for the focused pane. Enter alone
    // submits in Shell / is used by pane scrollers; the Alt modifier
    // keeps this unambiguous even when Shell has focus. Chosen over
    // F11 because many terminal emulators hijack F11 for their own
    // fullscreen.
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
        KeyCode::Char(c) => filter.push(c),
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
                // Observer view is a different index space than the
                // chronological VecDeque; reset scroll to avoid
                // clamping weirdness.
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

/// Flatten a `Line`'s span content into plain text, dropping styling.
fn line_to_plain(line: &Line) -> String {
    let mut out = String::new();
    for span in &line.spans {
        out.push_str(span.content.as_ref());
    }
    out
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
                .map(|n| {
                    n.shell_out
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

/// Copy the focused pane's visible text to the user's system
/// clipboard (OSC 52) and also write it to `/tmp/ovcs_attach_copy_
/// <pane>.txt` as a fallback. Sets a footer toast so the user gets
/// visible confirmation.
fn handle_copy(state: &mut State) {
    // OSC 52 payload limit comment and the CLIPBOARD_CAP constant
    // itself now live at module top with the rest of the tunables.

    let focus_name = match state.focus {
        Focus::Log => "LOG",
        Focus::Bus => "BUS",
        Focus::Can => "CAN",
        Focus::Shell => "SHELL",
    };
    let (label, text) = pane_snapshot(state);
    let bytes = text.len();
    let lines = text.split('\n').count();

    // Best-effort file dump — never fails the action, just skipped
    // if the write errors. Always full content.
    let path = format!("/tmp/ovcs_attach_copy_{}.txt", label);
    let file_ok = std::fs::write(&path, &text).is_ok();

    let clip_slice = clip_to_boundary(&text, CLIPBOARD_CAP);
    let clipped = clip_slice.len() < text.len();

    // Prefer a native clipboard helper (wl-copy / xclip / xsel /
    // pbcopy) so we work reliably on Linux desktops where tmux /
    // gnome-terminal / konsole silently drop OSC 52. Fall back to
    // OSC 52 when nothing is available (mostly ssh sessions into
    // headless hosts).
    let (method, copy_ok) = copy_to_clipboard(clip_slice);

    // Event log so the user can verify the binding actually fires,
    // and see which underlying paths succeeded.
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/ovcs_attach_events.log")
    {
        let _ = writeln!(
            f,
            "copy focus={} pane={} bytes={} clip_bytes={} lines={} clipped={} file_ok={} method={} copy_ok={} path={}",
            focus_name, label, bytes, clip_slice.len(), lines, clipped, file_ok, method, copy_ok, path,
        );
    }

    let clip_note = match method {
        "osc52" => format!(
            " ⚠ clipboard via OSC 52 (install wl-clipboard or xclip for reliable copy) · full copy in {}",
            path,
        ),
        _ if clipped => format!(
            " (clipboard got last {} KB via {}, full copy in {})",
            clip_slice.len() / 1024,
            method,
            path,
        ),
        _ => format!(" → clipboard ({}) + {}", method, path),
    };
    state.toast = Some((
        format!(
            "copied {} pane ({} lines, {} bytes){}",
            focus_name, lines, bytes, clip_note,
        ),
        Instant::now(),
    ));
}

/// Carve out the tail of `text` — newest content is what users typically
/// want when the buffer overflows. Slice at a UTF-8 char boundary so base64
/// encoding doesn't mangle multibyte chars (CAN rows can carry `·`, `❚❚`).
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

/// Push `text` onto the system clipboard using whichever mechanism the
/// host provides. Tries, in order:
/// 1. `wl-copy` (Wayland)
/// 2. `xclip -selection clipboard` (X11)
/// 3. `xsel --clipboard --input` (X11 alternative)
/// 4. `pbcopy` (macOS)
/// 5. OSC 52 via the terminal (SSH-friendly, but many terminals drop
///    it — that's exactly why this is last).
///
/// Returns `(method_name, ok)`.
fn copy_to_clipboard(text: &str) -> (&'static str, bool) {
    use std::process::{Command, Stdio};

    let helpers: &[(&str, &str, &[&str])] = &[
        ("wl-copy", "wl-copy", &[]),
        ("xclip", "xclip", &["-selection", "clipboard"]),
        ("xsel", "xsel", &["--clipboard", "--input"]),
        ("pbcopy", "pbcopy", &[]),
    ];
    for (name, cmd, args) in helpers {
        let mut spawn = Command::new(cmd);
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
                    let ok = wrote && waited.map(|s| s.success()).unwrap_or(false);
                    if ok {
                        return (*name, true);
                    }
                }
            }
            Err(_) => continue,
        }
    }

    // OSC 52 last-ditch. `c` = CLIPBOARD selection (not PRIMARY).
    let encoded = base64_encode(text.as_bytes());
    let wrote = write!(std::io::stdout(), "\x1b]52;c;{}\x07", encoded).is_ok();
    let _ = std::io::stdout().flush();
    ("osc52", wrote)
}

/// Minimal RFC 4648 base64 encoder (standard alphabet, `=` padding).
/// Hand-rolled to avoid pulling in a dependency just for OSC 52.
fn base64_encode(input: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    let chunks = input.chunks_exact(3);
    let rem = chunks.remainder();
    for c in chunks {
        let triple = ((c[0] as u32) << 16) | ((c[1] as u32) << 8) | c[2] as u32;
        out.push(ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((triple >> 6) & 0x3f) as usize] as char);
        out.push(ALPHABET[(triple & 0x3f) as usize] as char);
    }
    match rem.len() {
        1 => {
            let triple = (rem[0] as u32) << 16;
            out.push(ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
            out.push(ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
            out.push('=');
            out.push('=');
        }
        2 => {
            let triple = ((rem[0] as u32) << 16) | ((rem[1] as u32) << 8);
            out.push(ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
            out.push(ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
            out.push(ALPHABET[((triple >> 6) & 0x3f) as usize] as char);
            out.push('=');
        }
        _ => {}
    }
    out
}
