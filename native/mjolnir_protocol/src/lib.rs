//! Binary wire protocol for Mjolnir shell connections.
//!
//! Frame format:
//! ```text
//! [1 byte: message type] [4 bytes: payload length (big-endian)] [N bytes: payload]
//! ```
//!
//! Message types:
//! - `0x01` Data: raw terminal bytes
//! - `0x02` Resize: rows(u16 BE) + cols(u16 BE)
//! - `0x03` Exit: exit code(i32 BE)
//! - `0x04` Hello: rows(u16 BE) + cols(u16 BE) + protocol version(u16 BE)

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// ALPN protocol identifier for Mjolnir shell connections.
pub const SHELL_ALPN: &[u8] = b"mjolnir-shell/1";

/// ALPN protocol identifier for Mjolnir TCP port forwarding.
pub const TCP_FWD_ALPN: &[u8] = b"mjolnir-tcp-fwd/1";

/// ALPN protocol identifier for encrypted secrets injection via Iroh.
pub const SECRET_INJECT_ALPN: &[u8] = b"mjolnir-secret-inject/1";

/// Current protocol version.
pub const PROTOCOL_VERSION: u16 = 1;

/// Header size: 1 byte type + 4 bytes length.
const HEADER_SIZE: usize = 5;

/// Maximum payload size (16 MB) to prevent unbounded allocation.
const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;

/// Message type constants.
const TYPE_DATA: u8 = 0x01;
const TYPE_RESIZE: u8 = 0x02;
const TYPE_EXIT: u8 = 0x03;
const TYPE_HELLO: u8 = 0x04;

/// A decoded frame from the wire protocol.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    /// Raw terminal data (stdin/stdout bytes).
    Data(Vec<u8>),
    /// Terminal resize request.
    Resize { rows: u16, cols: u16 },
    /// Shell process exited with the given code.
    Exit { code: i32 },
    /// Client hello with initial terminal size and protocol version.
    Hello { rows: u16, cols: u16, version: u16 },
}

impl Frame {
    /// Encode this frame into wire format bytes.
    pub fn encode(&self) -> Vec<u8> {
        match self {
            Frame::Data(data) => {
                let len = data.len() as u32;
                let mut buf = Vec::with_capacity(HEADER_SIZE + data.len());
                buf.push(TYPE_DATA);
                buf.extend_from_slice(&len.to_be_bytes());
                buf.extend_from_slice(data);
                buf
            }
            Frame::Resize { rows, cols } => {
                let mut buf = Vec::with_capacity(HEADER_SIZE + 4);
                buf.push(TYPE_RESIZE);
                buf.extend_from_slice(&4u32.to_be_bytes());
                buf.extend_from_slice(&rows.to_be_bytes());
                buf.extend_from_slice(&cols.to_be_bytes());
                buf
            }
            Frame::Exit { code } => {
                let mut buf = Vec::with_capacity(HEADER_SIZE + 4);
                buf.push(TYPE_EXIT);
                buf.extend_from_slice(&4u32.to_be_bytes());
                buf.extend_from_slice(&code.to_be_bytes());
                buf
            }
            Frame::Hello { rows, cols, version } => {
                let mut buf = Vec::with_capacity(HEADER_SIZE + 6);
                buf.push(TYPE_HELLO);
                buf.extend_from_slice(&6u32.to_be_bytes());
                buf.extend_from_slice(&rows.to_be_bytes());
                buf.extend_from_slice(&cols.to_be_bytes());
                buf.extend_from_slice(&version.to_be_bytes());
                buf
            }
        }
    }
}

/// Read a single frame from an async reader.
///
/// Returns `Ok(None)` on clean EOF (stream closed).
/// Returns `Err` on malformed data or I/O errors.
pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Frame>> {
    // Read header
    let mut header = [0u8; HEADER_SIZE];
    match reader.read_exact(&mut header).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let msg_type = header[0];
    let payload_len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);

    if payload_len > MAX_PAYLOAD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("payload too large: {} bytes", payload_len),
        ));
    }

    // Read payload
    let mut payload = vec![0u8; payload_len as usize];
    if payload_len > 0 {
        reader.read_exact(&mut payload).await?;
    }

    // Decode
    match msg_type {
        TYPE_DATA => Ok(Some(Frame::Data(payload))),
        TYPE_RESIZE => {
            if payload.len() != 4 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Resize payload must be 4 bytes",
                ));
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            Ok(Some(Frame::Resize { rows, cols }))
        }
        TYPE_EXIT => {
            if payload.len() != 4 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Exit payload must be 4 bytes",
                ));
            }
            let code = i32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
            Ok(Some(Frame::Exit { code }))
        }
        TYPE_HELLO => {
            if payload.len() != 6 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Hello payload must be 6 bytes",
                ));
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            let version = u16::from_be_bytes([payload[4], payload[5]]);
            Ok(Some(Frame::Hello { rows, cols, version }))
        }
        _ => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("unknown message type: 0x{:02x}", msg_type),
        )),
    }
}

/// Write a single frame to an async writer.
pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    frame: &Frame,
) -> std::io::Result<()> {
    let encoded = frame.encode();
    writer.write_all(&encoded).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[tokio::test]
    async fn test_data_roundtrip() {
        let frame = Frame::Data(b"hello world".to_vec());
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_resize_roundtrip() {
        let frame = Frame::Resize { rows: 50, cols: 120 };
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_exit_roundtrip() {
        let frame = Frame::Exit { code: 42 };
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_hello_roundtrip() {
        let frame = Frame::Hello {
            rows: 24,
            cols: 80,
            version: PROTOCOL_VERSION,
        };
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_eof_returns_none() {
        let mut cursor = Cursor::new(Vec::<u8>::new());
        let result = read_frame(&mut cursor).await.unwrap();
        assert_eq!(result, None);
    }

    #[tokio::test]
    async fn test_multiple_frames() {
        let frames = vec![
            Frame::Hello {
                rows: 24,
                cols: 80,
                version: 1,
            },
            Frame::Data(b"ls\n".to_vec()),
            Frame::Resize { rows: 50, cols: 120 },
            Frame::Exit { code: 0 },
        ];

        let mut buf = Vec::new();
        for f in &frames {
            buf.extend_from_slice(&f.encode());
        }

        let mut cursor = Cursor::new(buf);
        for expected in &frames {
            let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
            assert_eq!(expected, &decoded);
        }

        // Next read should be EOF
        assert_eq!(read_frame(&mut cursor).await.unwrap(), None);
    }

    #[tokio::test]
    async fn test_empty_data_frame() {
        let frame = Frame::Data(Vec::new());
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_unknown_type_error() {
        let mut buf = vec![0xFF]; // unknown type
        buf.extend_from_slice(&0u32.to_be_bytes()); // 0 length
        let mut cursor = Cursor::new(buf);
        let result = read_frame(&mut cursor).await;
        assert!(result.is_err());
    }
}
