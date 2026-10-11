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

#[cfg(test)]
mod tests {
    use super::{is_blank_after_ansi, strip_ansi};

    #[test]
    fn colour_codes_are_dropped() {
        assert_eq!(
            strip_ansi("\x1b[31m\x1b[1merror\x1b[0m: boom"),
            "error: boom"
        );
    }

    #[test]
    fn a_window_title_is_dropped_whichever_terminator_it_has() {
        assert_eq!(strip_ansi("\x1b]0;iex(vms@host)\x07iex> "), "iex> ");
        assert_eq!(strip_ansi("\x1b]0;iex(vms@host)\x1b\\iex> "), "iex> ");
    }

    #[test]
    fn a_bare_bell_is_dropped() {
        assert_eq!(strip_ansi("ding\x07 dong"), "ding dong");
    }

    #[test]
    fn an_escape_cut_off_at_the_end_of_the_line_is_dropped() {
        assert_eq!(strip_ansi("text\x1b"), "text");
        assert_eq!(strip_ansi("text\x1b[3"), "text");
        assert_eq!(strip_ansi("text\x1b]0;unterminated title"), "text");
    }

    #[test]
    fn plain_text_is_untouched() {
        let line = "VmsCore.Bus: speed=12.5 km/h — état ✓";
        assert_eq!(strip_ansi(line), line);
    }

    #[test]
    fn a_line_holding_only_escapes_and_spaces_is_blank() {
        assert!(is_blank_after_ansi(""));
        assert!(is_blank_after_ansi("\x1b[0m  \x1b[22m\t"));
        assert!(is_blank_after_ansi("\x1b]0;title\x07\x07 "));
        assert!(!is_blank_after_ansi("\x1b[0m x"));
        assert!(!is_blank_after_ansi("\x1b]0;title\x1b\\:ok"));
    }
}
