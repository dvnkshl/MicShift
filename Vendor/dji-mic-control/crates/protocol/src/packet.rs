//! DUML packet framing shared by the DJI microphone family.
//!
//! Every packet is `0x55`, a total-length byte, a body, and a two-byte
//! [`crc`](crate::crc). This module extracts whole frames from a byte stream,
//! classifies them, and builds outgoing command packets. A future device that
//! speaks a different protocol simply would not use these helpers.
//!
//! Byte 3 of every frame is a CRC-8 (poly `0x31`, init `0xEE`, reflected)
//! computed over `[SOF, length, version]`. Since SOF and version never vary,
//! it works out to a fixed value per packet length — e.g. `0x03` for the
//! 19-byte v1 command, `0xfc` for the 22-byte v2 one — which is why it can be
//! hardcoded below rather than computed. It is not a "routing" field; that
//! reading only held up because v1 firmware only ever emits two lengths
//! (19 and 14).

use crate::crc;

/// Start-of-frame marker.
pub const SOF: u8 = 0x55;

/// Length of a v1 setting command packet.
pub const V1_COMMAND_LEN: usize = 19;

/// Length of a v2 setting command packet.
pub const V2_COMMAND_LEN: usize = 22;

/// Which protocol version a connected device speaks. The v2 firmware update
/// replaced the plain command shape with a target-addressed one, and changed
/// the CRC-16 seed and the heartbeat marker; see `PROTOCOL.md`.
/// [`heartbeat_dialect`] detects which one a device is using from its
/// heartbeat stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    /// v1 firmware: 19-byte commands, CRC-16 seed `0x0000`.
    V1,
    /// v2 firmware: 22-byte target-addressed commands, CRC-16 seed `0x3692`.
    V2,
}

impl Dialect {
    /// The CRC-16 seed this version's outgoing packets are checksummed from.
    pub fn crc_init(self) -> u16 {
        match self {
            Dialect::V1 => crc::V1_INIT,
            Dialect::V2 => crc::V2_INIT,
        }
    }

    /// The residue a valid packet in this version checksums to.
    pub fn crc_residue(self) -> u16 {
        match self {
            Dialect::V1 => crc::V1_RESIDUE,
            Dialect::V2 => crc::V2_RESIDUE,
        }
    }
}

/// Detect a heartbeat frame's protocol version from its marker byte (offset
/// 11): `0x00` on v1 firmware, `0x03` on v2 firmware. Returns `None` for
/// anything that isn't a heartbeat (this byte only carries this meaning in
/// that position) — commands and acks don't need version detection since
/// only heartbeats are decoded without already knowing it.
pub fn heartbeat_dialect(frame: &[u8]) -> Option<Dialect> {
    if frame.len() < 12 || frame[8] != 0x00 || frame[9] != 0x5b || frame[10] != 0x03 {
        return None;
    }
    match frame[11] {
        0x00 => Some(Dialect::V1),
        0x03 => Some(Dialect::V2),
        _ => None,
    }
}

/// The role a frame plays, determined by its ACK-flag byte (offset 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// Host → device command (`0x40`).
    Command,
    /// Device → host acknowledgement (`0x80`).
    Ack,
    /// Device → host heartbeat / status (`0x00`).
    Heartbeat,
    /// Any other flag value.
    Other,
}

/// Classify a complete frame by its ACK-flag byte.
pub fn frame_kind(frame: &[u8]) -> FrameKind {
    match frame.get(8) {
        Some(0x40) => FrameKind::Command,
        Some(0x80) => FrameKind::Ack,
        Some(0x00) => FrameKind::Heartbeat,
        _ => FrameKind::Other,
    }
}

/// DUML protocol-version byte, present at offset 2 of every frame. Used to
/// reject a stray `0x55` occurring inside payload (e.g. the `U` in an ASCII
/// serial number) so framing cannot desync onto it.
const VERSION: u8 = 0x04;

/// Minimum plausible frame length (start, length, version, routing, CRC).
const MIN_FRAME: usize = 4;
/// Largest frame this family emits, with headroom, to reject absurd lengths
/// from a coincidental start marker. The v2 dialect's identity push listing
/// all three units (receiver + two transmitters) is 178 bytes, the largest
/// frame either version produces — this must stay comfortably above that.
const MAX_FRAME: usize = 256;

/// Drain and return the next complete frame from `buf`.
///
/// A frame starts with [`SOF`] and carries [`VERSION`] at offset 2; the length
/// byte gives the total size. This does not checksum incoming data — device→host
/// frames do not share the command CRC's residue — but the start marker plus
/// version byte reliably distinguish a real frame boundary from a `0x55` byte
/// inside payload, so length framing stays aligned even after a mid-frame read.
///
/// Bytes that cannot begin a valid frame are discarded to resync. Returns `None`
/// when no complete frame is available yet, leaving any partial frame buffered.
pub fn take_frame(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    loop {
        // Locate the next start marker whose version byte checks out.
        let mut start = None;
        let mut i = 0;
        while i < buf.len() {
            if buf[i] == SOF {
                if i + 2 >= buf.len() {
                    // Not enough bytes to validate yet — keep this candidate and
                    // whatever follows, and wait for more data.
                    buf.drain(..i);
                    return None;
                }
                if buf[i + 2] == VERSION {
                    start = Some(i);
                    break;
                }
            }
            i += 1;
        }

        let Some(i) = start else {
            // No validated start. Retain a lone trailing 0x55 in case its
            // version byte simply hasn't arrived yet; drop the rest.
            if buf.last() == Some(&SOF) {
                let last = buf.len() - 1;
                buf.drain(..last);
            } else {
                buf.clear();
            }
            return None;
        };

        buf.drain(..i);

        let len = buf[1] as usize;
        if !(MIN_FRAME..=MAX_FRAME).contains(&len) {
            // Implausible length for a validated start — skip it and resync.
            buf.remove(0);
            continue;
        }
        if buf.len() < len {
            return None;
        }
        return Some(buf.drain(..len).collect());
    }
}

/// Build a 19-byte v1 setting command packet.
///
/// `seq` is a per-session sequence counter echoed back in the device's ACK;
/// `command` is the 16-bit command id (sent big-endian); `value` is the single
/// payload byte.
pub fn build_v1_command(seq: u16, command: u16, value: u8) -> Vec<u8> {
    let body = vec![
        SOF,
        V1_COMMAND_LEN as u8,
        0x04,                // protocol version
        0x03,                // header CRC-8 for a 19-byte frame
        0x02,                // command set: audio subsystem
        0x5a,                // attribute flags
        (seq & 0xff) as u8,  // sequence, little-endian
        (seq >> 8) as u8,
        0x40,                // ACK requested
        0x5b,
        0x01,
        0x00,
        (command >> 8) as u8, // command id, big-endian
        (command & 0xff) as u8,
        0x00,
        0x01,                // payload length
        value,
    ];
    crc::append(body, Dialect::V1.crc_init(), Dialect::V1.crc_residue())
}

/// Build a 22-byte v2 setting command packet.
///
/// Unlike [`build_v1_command`], the v2 shape addresses a specific unit:
/// `target` is `0x0000` for the receiver itself or `0xffff` to broadcast to
/// every connected transmitter. `command` is sent little-endian here (the
/// opposite of the v1 shape's big-endian id).
pub fn build_v2_command(seq: u16, target: u16, command: u16, value: u8) -> Vec<u8> {
    let body = vec![
        SOF,
        V2_COMMAND_LEN as u8,
        0x04,                    // protocol version
        0xfc,                    // header CRC-8 for a 22-byte frame
        0x02,                    // command set: audio subsystem
        0x5a,                    // attribute flags
        (seq & 0xff) as u8,      // sequence, little-endian
        (seq >> 8) as u8,
        0x40,                    // ACK requested
        0x5b,
        0x01,
        0x02,                    // v2/target-addressed command sub-type
        (target & 0xff) as u8,   // target unit, little-endian
        (target >> 8) as u8,
        0x00,
        0x00,
        (command & 0xff) as u8, // command id, little-endian
        (command >> 8) as u8,
        0x01,                   // payload length
        value,
    ];
    crc::append(body, Dialect::V2.crc_init(), Dialect::V2.crc_residue())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_documented_nc_strong_command() {
        // seq = 1, NC (0x031d) -> Strong (0x01).
        let pkt = build_v1_command(1, 0x031d, 0x01);
        let expected: &[u8] = &[
            0x55, 0x13, 0x04, 0x03, 0x02, 0x5a, 0x01, 0x00, 0x40, 0x5b, 0x01,
            0x00, 0x03, 0x1d, 0x00, 0x01, 0x01, 0x91, 0xfb,
        ];
        assert_eq!(pkt, expected);
    }

    #[test]
    fn classifies_frames_by_flag() {
        let cmd = build_v1_command(1, 0x031d, 0x01);
        assert_eq!(frame_kind(&cmd), FrameKind::Command);
    }

    #[test]
    fn extracts_frame_and_resyncs_past_junk() {
        let cmd = build_v1_command(7, 0x0303, 0x01);
        let mut buf = vec![0xaa, 0xbb]; // leading junk
        buf.extend_from_slice(&cmd);
        buf.push(0x55); // start of an incomplete next frame
        let frame = take_frame(&mut buf).expect("frame");
        assert_eq!(frame, cmd);
        // The dangling partial frame is retained for next time.
        assert_eq!(buf, vec![0x55]);
        assert!(take_frame(&mut buf).is_none());
    }

    #[test]
    fn skips_start_marker_inside_payload() {
        // A stray 0x55 whose offset-2 byte is not the version byte (as happens
        // when the ASCII 'U' inside a serial is mistaken for a start) must be
        // skipped so framing locks onto the real frame that follows.
        let cmd = build_v1_command(3, 0x031d, 0x01);
        let mut buf = vec![0x55, 0x30, 0x31, 0x34, 0x51]; // "U014Q" — bogus start
        buf.extend_from_slice(&cmd);
        let frame = take_frame(&mut buf).expect("frame");
        assert_eq!(frame, cmd);
        assert!(buf.is_empty());
    }

    #[test]
    fn builds_v2_nc_basic_command() {
        // seq = 0xb640, NC (0x0037) -> Basic (0x00), broadcast to both TX.
        let pkt = build_v2_command(0xb640, 0xffff, 0x0037, 0x00);
        let expected: &[u8] = &[
            0x55, 0x16, 0x04, 0xfc, 0x02, 0x5a, 0x40, 0xb6, 0x40, 0x5b, 0x01,
            0x02, 0xff, 0xff, 0x00, 0x00, 0x37, 0x00, 0x01, 0x00, 0xdd, 0xe2,
        ];
        assert_eq!(pkt, expected);
    }

    #[test]
    fn detects_dialect_from_heartbeat_marker() {
        let v1: &[u8] = &[0x55, 0x38, 0x04, 0xe1, 0x5a, 0x02, 0, 0, 0, 0x5b, 0x03, 0x00];
        let v2: &[u8] = &[0x55, 0x36, 0x04, 0x3d, 0x5a, 0x02, 0, 0, 0, 0x5b, 0x03, 0x03];
        assert_eq!(heartbeat_dialect(v1), Some(Dialect::V1));
        assert_eq!(heartbeat_dialect(v2), Some(Dialect::V2));
        // A command frame (ack-flag 0x40) is never mistaken for a heartbeat.
        assert_eq!(heartbeat_dialect(&build_v1_command(1, 0x031d, 0x01)), None);
    }
}
