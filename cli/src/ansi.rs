//! ANSI escape handling shared by the attach TUI and the `run`
//! stdio streamer. Both see terminal output that carries colour
//! codes (CSI) and occasional window-title updates (OSC) from the
//! remote BEAM/IEx — this module collapses them out without pulling
//! in a full parser. Bare BEL bytes are also dropped so the host
//! terminal does not beep on every attach.
fn consume_escape<I: Iterator<Item = char>>(chars: &mut std::iter::Peekable<I>) {
    match chars.peek() {
        // CSI: ESC [ … <final byte in 0x40–0x7E>
        Some('[') => {
            chars.next();
            for c in chars.by_ref() {
                if matches!(c, '\x40'..='\x7e') {
                    break;
                }
            }
        }
        // OSC: ESC ] … terminated by BEL (\x07) or ST (ESC \)
        Some(']') => {
            chars.next();
            while let Some(c) = chars.next() {
                if c == '\x07' {
                    break;
                }
                if c == '\x1b' && chars.peek() == Some(&'\\') {
                    chars.next();
                    break;
                }
            }
        }
        // Two-byte sequences like ESC = or ESC > — drop the next char.
        Some(_) => {
            chars.next();
        }
        None => {}
    }
}

/// Drop ANSI escape sequences (CSI + OSC) and bare BEL bytes from
/// `line`, keeping every other character verbatim.
pub fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            consume_escape(&mut chars);
        } else if c == '\x07' {
            // BEL outside an OSC: would beep the host terminal.
        } else {
            out.push(c);
        }
    }
    out
}

/// True when `line`, after stripping escape sequences, contains no
/// visible (non-whitespace) characters. Used to skip the "blank with
/// colour reset" lines Elixir's Logger emits around each message.
pub fn is_blank_after_ansi(line: &str) -> bool {
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            consume_escape(&mut chars);
        } else if c == '\x07' {
            // ignore
        } else if !c.is_whitespace() {
            return false;
        }
    }
    true
}
