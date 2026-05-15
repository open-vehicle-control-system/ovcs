//! ANSI/CSI escape handling shared by the attach TUI and the `run`
//! stdio streamer. Both see terminal output that carries
//! `ESC[...letter` colour codes — this module collapses them out
//! without pulling in a full parser.

/// Drop CSI escape sequences (`ESC [ … letter`) from `line`, keeping
/// every other character verbatim.
pub fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for escape_char in chars.by_ref() {
                if escape_char.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// True when `line`, after stripping CSI escape sequences, contains
/// no visible (non-whitespace) characters. Used to skip the "blank
/// with colour reset" lines Elixir's Logger emits around each
/// message.
pub fn is_blank_after_ansi(line: &str) -> bool {
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for escape_char in chars.by_ref() {
                if escape_char.is_ascii_alphabetic() {
                    break;
                }
            }
        } else if !c.is_whitespace() {
            return false;
        }
    }
    true
}
