//! Images sent with a message: read from their files for the providers that take them as data.

use std::path::Path;

/// A message's parts in order: its words, and each image where its "[Image #n]" (n counting from 1) stands in them.
/// The token stays in the words, so the agent can call the image by its number; images never named come last.
pub enum Part<'a> { Text(String), Image(&'a str) }

pub fn parts<'a>(text: &str, images: &'a [String]) -> Vec<Part<'a>> {
    const TOKEN: &str = "[Image #";
    let mut parts = vec![];
    let mut placed = vec![false; images.len()];
    let mut words = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(TOKEN) {
        let after = &rest[start + TOKEN.len()..];
        let digits = after.len() - after.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        let number = after[..digits].parse::<usize>().ok().filter(|_| after[digits..].starts_with(']'));
        match number {
            Some(n) if (1..=images.len()).contains(&n) && !placed[n - 1] => {
                let end = start + TOKEN.len() + digits + 1;
                words.push_str(&rest[..end]);
                parts.push(Part::Text(std::mem::take(&mut words)));
                parts.push(Part::Image(&images[n - 1]));
                placed[n - 1] = true;
                rest = &rest[end..];
            }
            _ => {
                words.push_str(&rest[..start + TOKEN.len()]);
                rest = &rest[start + TOKEN.len()..];
            }
        }
    }
    words.push_str(rest);
    if !words.trim().is_empty() { parts.push(Part::Text(words)) }
    parts.extend(images.iter().zip(placed).filter(|(_, placed)| !placed).map(|(path, _)| Part::Image(path)));
    parts
}

/// The image's type and its bytes in base64, as Claude's and ACP's messages carry them; none when it can't be read.
pub fn data(path: &str) -> Option<(&'static str, String)> {
    let bytes = std::fs::read(path).ok()?;
    Some((mime(path), base64(&bytes)))
}

pub fn mime(path: &str) -> &'static str {
    match Path::new(path).extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

/// Standard base64, padded.
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() { out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char) } else { out.push('=') }
        }
    }
    out
}

/// Standard base64 back to bytes; none when it isn't base64.
pub fn unbase64(text: &str) -> Option<Vec<u8>> {
    let value = |c: u8| -> Option<u32> {
        Some(match c { b'A'..=b'Z' => c - b'A', b'a'..=b'z' => c - b'a' + 26, b'0'..=b'9' => c - b'0' + 52, b'+' | b'-' => 62, b'/' | b'_' => 63, _ => return None } as u32)
    };
    let digits: Vec<u8> = text.bytes().filter(|c| !c.is_ascii_whitespace() && *c != b'=').collect();
    let mut out = Vec::with_capacity(digits.len() * 3 / 4);
    for chunk in digits.chunks(4) {
        if chunk.len() == 1 { return None }
        let mut n = 0u32;
        for (i, c) in chunk.iter().enumerate() { n |= value(*c)? << (18 - 6 * i) }
        out.extend_from_slice(&n.to_be_bytes()[1..chunk.len()]);
    }
    Some(out)
}
