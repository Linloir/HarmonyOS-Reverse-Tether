// SPDX-License-Identifier: Apache-2.0
use super::ip_header::{frame_length, IpHeaderData, Protocol};
use super::ip_packet::IpPacket;
use super::ip_packet_buffer::IpPacketBuffer;
use super::packetizer::Packetizer;
use byteorder::{BigEndian, ByteOrder};
use std::io::Cursor;
use std::net::{IpAddr, Ipv6Addr};

fn packet(extension: Option<u8>) -> Vec<u8> {
    let offset = if extension.is_some() { 48 } else { 40 };
    let mut raw = vec![0; offset + 13];
    raw[0] = 0x60;
    BigEndian::write_u16(&mut raw[4..6], (offset - 40 + 13) as u16);
    raw[6] = extension.unwrap_or(17);
    raw[7] = 64;
    raw[8..24].copy_from_slice(&Ipv6Addr::new(0xfd00, 0x7265, 0x7674, 0, 0, 0, 0, 2).octets());
    raw[24..40].copy_from_slice(&Ipv6Addr::LOCALHOST.octets());
    if extension.is_some() {
        raw[40] = 17;
    }
    BigEndian::write_u16(&mut raw[offset..offset + 2], 40000);
    BigEndian::write_u16(&mut raw[offset + 2..offset + 4], 40001);
    BigEndian::write_u16(&mut raw[offset + 4..offset + 6], 13);
    BigEndian::write_u16(&mut raw[offset + 6..offset + 8], 0xffff);
    raw[offset + 8..].copy_from_slice(b"hello");
    IpPacket::parse(&mut raw).compute_checksums();
    raw
}

#[test]
fn ipv6_framing_waits_for_payload_length_bytes_and_bounds_total() {
    let raw = packet(None);
    for count in 0..6 {
        assert_eq!(frame_length(&raw[..count]).unwrap(), None);
    }
    assert_eq!(frame_length(&raw[..6]).unwrap(), Some(53));
    assert!(frame_length(&[0x60, 0, 0, 0, 0xff, 0xff]).is_err());
    assert!(frame_length(&[0x60, 0, 0, 0, 0, 0]).is_err());
    assert!(frame_length(&[0x70]).is_err());
}

#[test]
fn ipv6_truncated_reads_and_coalesced_frames_are_safe() {
    let raw = packet(None);
    let mut buffer = IpPacketBuffer::new();
    for byte in &raw[..raw.len() - 1] {
        buffer.read_from(&mut Cursor::new([*byte])).unwrap();
        buffer.validate_front().unwrap();
        assert!(buffer.as_ip_packet().is_none());
    }
    let mut tail = vec![raw[raw.len() - 1]];
    tail.extend_from_slice(&raw);
    buffer.read_from(&mut Cursor::new(tail)).unwrap();
    for _ in 0..2 {
        assert!(buffer.is_ipv6());
        assert_eq!(buffer.as_ip_packet().unwrap().payload().unwrap(), b"hello");
        buffer.next();
    }
    assert!(buffer.as_ip_packet().is_none());
}

#[test]
fn extension_headers_are_validated_and_not_reflected_to_reply() {
    for kind in [0, 60, 44] {
        let mut raw = packet(Some(kind));
        let packet = IpPacket::parse(&mut raw);
        let (header, transport) = packet.headers();
        assert_eq!(header.header_length(), 48);
        assert_eq!(header.data().protocol(), Protocol::Udp);
        let mut reply = Packetizer::new(&header, &transport.unwrap());
        let response = reply.packetize_empty_payload();
        assert_eq!(response.ip_header_data().header_length(), 40);
        assert_eq!(response.raw()[6], 17);
        assert_eq!(
            response.ip_header_data().source(),
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        );
        assert_eq!(BigEndian::read_u16(&response.raw()[4..6]), 8);
        assert_ne!(&response.raw()[46..48], &[0, 0]);
    }
    let mut malformed = packet(Some(60));
    malformed[41] = 255;
    assert!(IpHeaderData::validate(&malformed).is_err());
    let mut malformed_option = packet(Some(60));
    malformed_option[42] = 1;
    malformed_option[43] = 20;
    assert!(IpHeaderData::validate(&malformed_option).is_err());
}

#[test]
fn fragments_and_unknown_discard_options_do_not_desynchronize_stream() {
    let mut fragment = packet(Some(44));
    fragment[43] = 1; // More fragments: no reassembly is implemented.
    let mut unsafe_option = packet(Some(60));
    unsafe_option[42] = 0x80;
    unsafe_option[43] = 0;
    let good = packet(None);
    for mut dropped in [fragment, unsafe_option] {
        dropped.extend_from_slice(&good);
        let mut buffer = IpPacketBuffer::new();
        buffer.read_from(&mut Cursor::new(dropped)).unwrap();
        buffer.validate_front().unwrap();
        assert!(buffer.is_unsupported());
        buffer.next();
        buffer.validate_front().unwrap();
        assert!(!buffer.is_unsupported());
        assert_eq!(buffer.as_ip_packet().unwrap().payload().unwrap(), b"hello");
    }
}

#[test]
fn rejects_truncated_transport_and_ipv6_zero_udp_checksum() {
    let raw = packet(None);
    for count in 0..raw.len() {
        assert!(IpHeaderData::validate(&raw[..count]).is_err());
    }
    let mut no_checksum = raw.clone();
    no_checksum[46..48].fill(0);
    assert!(IpHeaderData::validate(&no_checksum).is_err());
    let mut bad_length = raw;
    bad_length[45] = 7;
    assert!(IpHeaderData::validate(&bad_length).is_err());
}
