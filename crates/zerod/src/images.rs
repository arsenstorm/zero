//! Images sent with a message: read from their files for the providers that take them as data.

use std::path::Path;

/// The image's type and its bytes in base64, as Claude's and ACP's messages carry them; none when it can't be read.
pub fn data(path: &str) -> Option<(&'static str, String)> {
    let bytes = std::fs::read(path).ok()?;
    Some((mime(path), base64(&bytes)))
}

fn mime(path: &str) -> &'static str {
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
