/*
 * Copyright (C) 2017 Genymobile
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use super::binary;
use super::byte_buffer::ByteBuffer;
use super::ip_header;
use super::ip_packet::{IpPacket, MAX_PACKET_LENGTH};

use log::*;
use std::io;

pub struct IpPacketBuffer {
    buf: ByteBuffer,
}

impl IpPacketBuffer {
    pub fn new() -> Self {
        Self {
            buf: ByteBuffer::new(MAX_PACKET_LENGTH),
        }
    }

    pub fn read_from<R: io::Read>(&mut self, source: &mut R) -> io::Result<bool> {
        self.buf.read_from(source)
    }

    // Framing and all transport bounds are checked before zero-copy parsing.
    pub fn validate_front(&self) -> io::Result<()> {
        let raw = self.buf.peek();
        if let Some(length) = ip_header::frame_length(raw)? {
            if raw.len() >= length {
                ip_header::IpHeaderData::validate(raw)?;
            }
        }
        Ok(())
    }

    pub fn is_unsupported(&self) -> bool {
        self.available_packet_length().is_some()
            && ip_header::IpHeaderData::validate(self.buf.peek())
                .map(|header| header.protocol() == ip_header::Protocol::Other)
                .unwrap_or(false)
    }

    pub fn is_ipv6(&self) -> bool {
        self.available_packet_length().is_some() && self.buf.peek()[0] >> 4 == 6
    }

    fn available_packet_length(&self) -> Option<u16> {
        let data = self.buf.peek();
        trace!("Parse packet: {}", binary::build_packet_string(data));
        let length = ip_header::frame_length(data).ok().flatten()?;
        if length <= data.len() {
            Some(length as u16)
        } else {
            None
        }
    }

    pub fn as_ip_packet(&mut self) -> Option<IpPacket<'_>> {
        if self.available_packet_length().is_some() && self.validate_front().is_ok() {
            Some(IpPacket::parse(self.buf.peek_mut()))
        } else {
            None
        }
    }

    pub fn next(&mut self) {
        // remove the packet in front of the buffer
        let length = self
            .available_packet_length()
            .expect("next() called while there was no packet") as usize;
        self.buf.consume(length);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::ip_header::Protocol;
    use crate::relay::transport_header::TransportHeaderData;
    use byteorder::{BigEndian, WriteBytesExt};
    use std::io;

    #[test]
    fn malformed_stream_cannot_reach_unchecked_parsers() {
        for raw in [
            vec![0x60, 0, 0, 20, 0, 0],
            vec![0x45, 0, 0, 0],
            vec![0x4f, 0, 0, 20],
        ] {
            let mut buffer = IpPacketBuffer::new();
            buffer.read_from(&mut io::Cursor::new(raw)).unwrap();
            assert!(buffer.validate_front().is_err());
        }
        let mut raw = create_packet();
        raw[24] = 0;
        raw[25] = 7;
        let mut buffer = IpPacketBuffer::new();
        buffer.read_from(&mut io::Cursor::new(raw)).unwrap();
        assert!(buffer.validate_front().is_err());
    }

    #[test]
    fn validates_next_coalesced_frame_and_identifies_fragments() {
        let mut raw = create_packet();
        raw[6] = 0x20;
        raw.extend_from_slice(&[0x45, 0, 0, 0]);
        let mut buffer = IpPacketBuffer::new();
        buffer.read_from(&mut io::Cursor::new(raw)).unwrap();
        assert!(buffer.validate_front().is_ok());
        assert!(buffer.is_unsupported());
        buffer.next();
        assert!(buffer.validate_front().is_err());
    }

    fn create_packet() -> Vec<u8> {
        let mut raw = Vec::new();
        write_packet_to(&mut raw);
        raw
    }

    fn write_packet_to(raw: &mut Vec<u8>) {
        raw.write_u8(4u8 << 4 | 5).unwrap();
        raw.write_u8(0).unwrap(); // ToS
        raw.write_u16::<BigEndian>(32).unwrap(); // total length 20 + 8 + 4
        raw.write_u32::<BigEndian>(0).unwrap(); // id_flags_fragment_offset
        raw.write_u8(0).unwrap(); // TTL
        raw.write_u8(17).unwrap(); // protocol (UDP)
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum
        raw.write_u32::<BigEndian>(0x12345678).unwrap(); // source address
        raw.write_u32::<BigEndian>(0x42424242).unwrap(); // destination address

        raw.write_u16::<BigEndian>(1234).unwrap(); // source port
        raw.write_u16::<BigEndian>(5678).unwrap(); // destination port
        raw.write_u16::<BigEndian>(12).unwrap(); // length
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum

        raw.write_u32::<BigEndian>(0x11223344).unwrap(); // payload
    }

    fn write_another_packet_to(raw: &mut Vec<u8>) {
        raw.write_u8(4u8 << 4 | 5).unwrap();
        raw.write_u8(0).unwrap(); // ToS
        raw.write_u16::<BigEndian>(29).unwrap(); // total length 20 + 8 + 1
        raw.write_u32::<BigEndian>(0).unwrap(); // id_flags_fragment_offset
        raw.write_u8(0).unwrap(); // TTL
        raw.write_u8(17).unwrap(); // protocol (UDP)
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum
        raw.write_u32::<BigEndian>(0x11111111).unwrap(); // source address
        raw.write_u32::<BigEndian>(0x22222222).unwrap(); // destination address

        raw.write_u16::<BigEndian>(1111).unwrap(); // source port
        raw.write_u16::<BigEndian>(2222).unwrap(); // destination port
        raw.write_u16::<BigEndian>(9).unwrap(); // length
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum

        raw.write_u8(0x99).unwrap(); // payload
    }

    fn check_packet_headers(ip_packet: &IpPacket) {
        let ip_header = ip_packet.ip_header();
        assert_eq!(20, ip_header.header_length());
        assert_eq!(32, ip_header.total_length());
        assert_eq!(Protocol::Udp, ip_header.protocol());
        assert_eq!(
            std::net::IpAddr::V4(std::net::Ipv4Addr::from(0x12345678u32)),
            ip_header.source()
        );
        assert_eq!(
            std::net::IpAddr::V4(std::net::Ipv4Addr::from(0x42424242u32)),
            ip_header.destination()
        );

        if let Some(&TransportHeaderData::Udp(ref udp_header)) = ip_packet.transport_header_data() {
            assert_eq!(1234, udp_header.source_port());
            assert_eq!(5678, udp_header.destination_port());
        } else {
            panic!("No UDP transport header");
        }
    }

    fn check_another_packet_headers(ip_packet: &IpPacket) {
        let ip_header = ip_packet.ip_header();
        assert_eq!(20, ip_header.header_length());
        assert_eq!(29, ip_header.total_length());
        assert_eq!(Protocol::Udp, ip_header.protocol());
        assert_eq!(
            std::net::IpAddr::V4(std::net::Ipv4Addr::from(0x11111111u32)),
            ip_header.source()
        );
        assert_eq!(
            std::net::IpAddr::V4(std::net::Ipv4Addr::from(0x22222222u32)),
            ip_header.destination()
        );

        if let Some(&TransportHeaderData::Udp(ref udp_header)) = ip_packet.transport_header_data() {
            assert_eq!(1111, udp_header.source_port());
            assert_eq!(2222, udp_header.destination_port());
        } else {
            panic!("No UDP transport header");
        }
    }

    #[test]
    fn parse_ip_packet_buffer() {
        let raw = create_packet();
        let mut packet_buffer = IpPacketBuffer::new();

        let mut cursor = io::Cursor::new(raw);
        packet_buffer.read_from(&mut cursor).unwrap();

        let packet = packet_buffer.as_ip_packet().unwrap();
        check_packet_headers(&packet);
    }

    #[test]
    fn parse_fragmented_ip_packet_buffer() {
        let raw = create_packet();
        let mut packet_buffer = IpPacketBuffer::new();

        let mut cursor = io::Cursor::new(&raw[..14]);
        packet_buffer.read_from(&mut cursor).unwrap();

        assert!(packet_buffer.as_ip_packet().is_none());

        let mut cursor = io::Cursor::new(&raw[14..]);
        packet_buffer.read_from(&mut cursor).unwrap();

        let packet = packet_buffer.as_ip_packet().unwrap();
        check_packet_headers(&packet);
    }

    fn create_multi_packets() -> Vec<u8> {
        let mut raw = Vec::new();
        write_packet_to(&mut raw);
        write_another_packet_to(&mut raw);
        write_packet_to(&mut raw);
        raw
    }

    #[test]
    fn parse_multi_packets() {
        let raw = create_multi_packets();
        let mut packet_buffer = IpPacketBuffer::new();

        let mut cursor = io::Cursor::new(raw);
        packet_buffer.read_from(&mut cursor).unwrap();

        check_packet_headers(&packet_buffer.as_ip_packet().unwrap());
        packet_buffer.next();
        check_another_packet_headers(&packet_buffer.as_ip_packet().unwrap());
        packet_buffer.next();
        check_packet_headers(&packet_buffer.as_ip_packet().unwrap());
        packet_buffer.next();

        assert!(packet_buffer.as_ip_packet().is_none());
    }
}
