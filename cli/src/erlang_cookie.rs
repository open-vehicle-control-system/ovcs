//! The Erlang cookie of the BEAMs the CLI starts on the host.

use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

const COOKIE_LENGTH: usize = 20;

/// Creates `~/.erlang.cookie` with a random cookie, readable only by its
/// owner, unless it exists. Every BEAM started without `--cookie` reads it,
/// so `run`'s nodes and `attach`'s remsh agree on a secret nobody else has.
/// Creating it here, once, keeps BEAMs that start together from each
/// writing a different one.
pub fn ensure() -> Result<()> {
    let path = cookie_path()?;
    let mut file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o400)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("creating {}", path.display())),
    };
    file.write_all(random_cookie()?.as_bytes())
        .with_context(|| format!("writing {}", path.display()))
}

fn cookie_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".erlang.cookie"))
}

/// Uppercase letters, as Erlang generates them.
fn random_cookie() -> Result<String> {
    let mut urandom = std::fs::File::open("/dev/urandom").context("opening /dev/urandom")?;
    let mut cookie = String::with_capacity(COOKIE_LENGTH);
    let mut byte = [0u8; 1];
    while cookie.len() < COOKIE_LENGTH {
        urandom.read_exact(&mut byte)?;
        // Rejecting bytes past the last multiple of 26 keeps letters uniform.
        if byte[0] < 234 {
            cookie.push(char::from(b'A' + byte[0] % 26));
        }
    }
    Ok(cookie)
}

#[cfg(test)]
mod tests {
    use super::random_cookie;

    #[test]
    fn a_cookie_is_twenty_uppercase_letters() {
        let cookie = random_cookie().unwrap();
        assert_eq!(cookie.len(), 20);
        assert!(cookie.chars().all(|c| c.is_ascii_uppercase()));
    }
}
