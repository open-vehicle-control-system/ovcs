//! Strips the colour codes (CSI), window-title updates (OSC) and BEL bytes
//! that BEAM and IEx output carries, for the attach TUI and `run`'s output.
fn consume_escape<I: Iterator<Item = char>>(chars: &mut std::iter::Peekable<I>) {
    match chars.peek() {
        // CSI: ESC [ … <final byte in 0x40–0x7E>
        Some('[') => {
            chars.next();
            for character in chars.by_ref() {
                if matches!(character, '\x40'..='\x7e') {
                    break;
                }
            }
        }
        // OSC: ESC ] … terminated by BEL (\x07) or ST (ESC \)
        Some(']') => {
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
    while let Some(character) = chars.next() {
        if character == '\x1b' {
            consume_escape(&mut chars);
        } else if character != '\x07' {
            out.push(character);
        }
    }
    out
}

/// True when `line`, after stripping escape sequences, contains no
/// visible (non-whitespace) characters. Used to skip the "blank with
/// colour reset" lines Elixir's Logger emits around each message.
pub fn is_blank_after_ansi(line: &str) -> bool {
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\x1b' {
            consume_escape(&mut chars);
        } else if character != '\x07' && !character.is_whitespace() {
            return false;
        }
    }
    true
}
