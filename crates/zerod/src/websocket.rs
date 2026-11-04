//! A WebSocket client for one peer on this Mac (Firefox's remote control on 127.0.0.1): text messages each way, pings
//! answered. No TLS, no extensions; a frame's size is whatever the peer sends.

use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

/// Connects to `ws://{address}{path}`: what's sent goes as text messages, and the text messages that come arrive on
/// the receiver, which ends when the connection does.
pub async fn connect(address: &str, path: &str) -> Result<(mpsc::UnboundedSender<String>, mpsc::UnboundedReceiver<String>), String> {
    let stream = TcpStream::connect(address).await.map_err(|e| format!("Can't reach {address}: {e}"))?;
    let (read, mut write) = stream.into_split();
    let mut read = BufReader::new(read);
    write.write_all(format!("GET {path} HTTP/1.1\r\nHost: {address}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                             Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").as_bytes()).await.map_err(|e| e.to_string())?;
    let mut status = String::new();
    read.read_line(&mut status).await.map_err(|e| e.to_string())?;
    if !status.contains(" 101 ") { return Err(format!("{address} refused the connection: {}", status.trim())) }
    loop {
        let mut header = String::new();
        if read.read_line(&mut header).await.map_err(|e| e.to_string())? == 0 { return Err("Closed while connecting".into()) }
        if header == "\r\n" { break }
    }
    let (send, mut outgoing) = mpsc::unbounded_channel::<String>();
    let (arrived, receive) = mpsc::unbounded_channel();
    let (pong, mut pongs) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        loop {
            let (opcode, data) = tokio::select! {
                text = outgoing.recv() => match text { Some(text) => (1, text.into_bytes()), None => (8, vec![]) },
                ping = pongs.recv() => match ping { Some(data) => (10, data), None => break },
            };
            if write.write_all(&frame(opcode, &data)).await.is_err() || opcode == 8 { break }
        }
    });
    tokio::spawn(async move {
        let mut message = Vec::new();
        while let Some((last, opcode, data)) = read_frame(&mut read).await {
            match opcode {
                0..=2 => {
                    message.extend(data);
                    if last {
                        if arrived.send(String::from_utf8_lossy(&message).into_owned()).is_err() { break }
                        message.clear();
                    }
                }
                8 => break,
                9 => { let _ = pong.send(data); }
                _ => {}
            }
        }
    });
    Ok((send, receive))
}

/// One frame from the client: final, masked (as a client's must be), its length as long as it needs.
pub fn frame(opcode: u8, data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x80 | opcode];
    match data.len() {
        n if n < 126 => out.push(0x80 | n as u8),
        n if n <= u16::MAX as usize => { out.push(0x80 | 126); out.extend((n as u16).to_be_bytes()) }
        n => { out.push(0x80 | 127); out.extend((n as u64).to_be_bytes()) }
    }
    // The mask hides nothing here (the peer is on this Mac); the protocol asks for one.
    let mask = [0x5a, 0x45, 0x52, 0x4f];
    out.extend(mask);
    out.extend(data.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out
}

/// One frame: whether it ends its message, its opcode, its data unmasked.
pub async fn read_frame<R: AsyncRead + Unpin>(read: &mut R) -> Option<(bool, u8, Vec<u8>)> {
    let mut head = [0u8; 2];
    read.read_exact(&mut head).await.ok()?;
    let length = match head[1] & 0x7f {
        126 => { let mut n = [0u8; 2]; read.read_exact(&mut n).await.ok()?; u16::from_be_bytes(n) as u64 }
        127 => { let mut n = [0u8; 8]; read.read_exact(&mut n).await.ok()?; u64::from_be_bytes(n) }
        n => n as u64,
    };
    if length > 256 << 20 { return None }
    let mut mask = [0u8; 4];
    if head[1] & 0x80 != 0 { read.read_exact(&mut mask).await.ok()?; }
    let mut data = vec![0u8; length as usize];
    read.read_exact(&mut data).await.ok()?;
    if head[1] & 0x80 != 0 { for (i, b) in data.iter_mut().enumerate() { *b ^= mask[i % 4] } }
    Some((head[0] & 0x80 != 0, head[0] & 0x0f, data))
}

/// What a server writes (unmasked), for tests that stand in for Firefox.
pub fn server_frame(opcode: u8, data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x80 | opcode];
    match data.len() {
        n if n < 126 => out.push(n as u8),
        n if n <= u16::MAX as usize => { out.push(126); out.extend((n as u16).to_be_bytes()) }
        n => { out.push(127); out.extend((n as u64).to_be_bytes()) }
    }
    out.extend(data);
    out
}
