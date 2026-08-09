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
//!   + optional UTF-8 tmux session name (all remaining bytes)

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// ALPN protocol identifier for Mjolnir shell connections.
pub const SHELL_ALPN: &[u8] = b"mjolnir-shell/1";

/// ALPN identifier for shell connections that may carry a tmux session name in Hello.
///
/// This is the version handshake. QUIC negotiates the ALPN before a single frame is
/// written, and a v1 agent rejects an unknown ALPN at the TLS layer — so a client that
/// connects with this string *knows* the far end can decode a long Hello before it
/// sends one. Without it, an extended Hello reaching a v1 agent would trip the strict
/// six-byte length check in `read_frame` and kill the connection instead of degrading.
pub const SHELL_ALPN_V2: &[u8] = b"mjolnir-shell/2";

/// ALPN protocol identifier for Mjolnir TCP port forwarding.
pub const TCP_FWD_ALPN: &[u8] = b"mjolnir-tcp-fwd/1";

/// ALPN protocol identifier for encrypted secrets injection via Iroh.
pub const SECRET_INJECT_ALPN: &[u8] = b"mjolnir-secret-inject/1";

/// Current protocol version.
pub const PROTOCOL_VERSION: u16 = 2;

/// Maximum length of a tmux session name on the wire.
///
/// The guest agent validates the name properly (`tmux::validate_session_name`, 64 chars);
/// this only stops a malformed peer from making us allocate a 16 MB "session name".
const MAX_SESSION_LEN: usize = 256;

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
    ///
    /// `session` asks the agent to attach this PTY to a named tmux session rather than
    /// spawn a private shell, which is how several clients converge on one terminal.
    /// It encodes to zero extra bytes when `None`, so a v1 Hello and a sessionless v2
    /// Hello are the same six bytes on the wire. Only ever send `Some` over
    /// [`SHELL_ALPN_V2`] — a v1 agent rejects the longer payload outright.
    Hello {
        rows: u16,
        cols: u16,
        version: u16,
        session: Option<String>,
    },
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
            Frame::Hello {
                rows,
                cols,
                version,
                session,
            } => {
                let session_bytes = session.as_deref().map(str::as_bytes).unwrap_or(&[]);
                let len = (6 + session_bytes.len()) as u32;
                let mut buf = Vec::with_capacity(HEADER_SIZE + len as usize);
                buf.push(TYPE_HELLO);
                buf.extend_from_slice(&len.to_be_bytes());
                buf.extend_from_slice(&rows.to_be_bytes());
                buf.extend_from_slice(&cols.to_be_bytes());
                buf.extend_from_slice(&version.to_be_bytes());
                buf.extend_from_slice(session_bytes);
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
            if payload.len() < 6 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Hello payload must be at least 6 bytes",
                ));
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            let version = u16::from_be_bytes([payload[4], payload[5]]);
            let session = if payload.len() == 6 {
                None
            } else {
                let raw = &payload[6..];
                if raw.len() > MAX_SESSION_LEN {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("Hello session name too long: {} bytes", raw.len()),
                    ));
                }
                Some(
                    std::str::from_utf8(raw)
                        .map_err(|_| {
                            std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                "Hello session name must be valid UTF-8",
                            )
                        })?
                        .to_string(),
                )
            };
            Ok(Some(Frame::Hello {
                rows,
                cols,
                version,
                session,
            }))
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
            session: None,
        };
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    #[tokio::test]
    async fn test_hello_with_session_roundtrip() {
        let frame = Frame::Hello {
            rows: 24,
            cols: 80,
            version: PROTOCOL_VERSION,
            session: Some("shared-term".to_string()),
        };
        let encoded = frame.encode();
        let mut cursor = Cursor::new(encoded);
        let decoded = read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame, decoded);
    }

    /// A sessionless Hello must stay byte-identical to the v1 encoding.
    ///
    /// This is the load-bearing compatibility claim: `mj connect` without `--session`
    /// still speaks SHELL_ALPN (v1) to agents in the field, so if this drifts, every
    /// deployed agent starts rejecting Hello on the strict six-byte check.
    #[tokio::test]
    async fn test_sessionless_hello_is_wire_identical_to_v1() {
        let encoded = Frame::Hello {
            rows: 24,
            cols: 80,
            version: 1,
            session: None,
        }
        .encode();

        let mut expected = vec![TYPE_HELLO];
        expected.extend_from_slice(&6u32.to_be_bytes());
        expected.extend_from_slice(&24u16.to_be_bytes());
        expected.extend_from_slice(&80u16.to_be_bytes());
        expected.extend_from_slice(&1u16.to_be_bytes());

        assert_eq!(encoded, expected);
    }

    #[tokio::test]
    async fn test_hello_short_payload_errors() {
        let mut buf = vec![TYPE_HELLO];
        buf.extend_from_slice(&4u32.to_be_bytes());
        buf.extend_from_slice(&24u16.to_be_bytes());
        buf.extend_from_slice(&80u16.to_be_bytes());
        let mut cursor = Cursor::new(buf);
        assert!(read_frame(&mut cursor).await.is_err());
    }

    #[tokio::test]
    async fn test_hello_session_too_long_errors() {
        let name = "a".repeat(MAX_SESSION_LEN + 1);
        let encoded = Frame::Hello {
            rows: 24,
            cols: 80,
            version: PROTOCOL_VERSION,
            session: Some(name),
        }
        .encode();
        let mut cursor = Cursor::new(encoded);
        assert!(read_frame(&mut cursor).await.is_err());
    }

    #[tokio::test]
    async fn test_hello_session_invalid_utf8_errors() {
        let mut buf = vec![TYPE_HELLO];
        buf.extend_from_slice(&8u32.to_be_bytes());
        buf.extend_from_slice(&24u16.to_be_bytes());
        buf.extend_from_slice(&80u16.to_be_bytes());
        buf.extend_from_slice(&2u16.to_be_bytes());
        buf.extend_from_slice(&[0xff, 0xfe]);
        let mut cursor = Cursor::new(buf);
        assert!(read_frame(&mut cursor).await.is_err());
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
                session: None,
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
