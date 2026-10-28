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

use std::io;

use super::datagram::{DatagramReceiver, ReadAdapter};
use super::ip_header::{IpHeader, IpHeaderData, IpHeaderMut};
use super::ip_packet::{IpPacket, MAX_PACKET_LENGTH};
use super::transport_header::{TransportHeader, TransportHeaderData, TransportHeaderMut};

/// Convert from level 5 to level 3 by appending correct IP and transport headers.
pub struct Packetizer {
    buffer: Box<[u8; MAX_PACKET_LENGTH]>,
    transport_index: usize,
    payload_index: usize,
    ip_header_data: IpHeaderData,
    transport_header_data: TransportHeaderData,
}

impl Packetizer {
    pub fn new(
        reference_ip_header: &IpHeader,
        reference_transport_header: &TransportHeader,
    ) -> Self {
        let mut buffer = Box::new([0; MAX_PACKET_LENGTH]);

        let (ip_header_data, ip_header_raw) = reference_ip_header
            .data()
            .reply_header(reference_ip_header.raw());
        let transport_index = usize::from(ip_header_data.header_length());
        let payload_index = transport_index + reference_transport_header.header_length() as usize;
        let mut transport_header_data = reference_transport_header.data_clone();
        buffer[..transport_index].copy_from_slice(&ip_header_raw);

        {
            let transport_header_raw = &mut buffer[transport_index..payload_index];
            transport_header_raw.copy_from_slice(reference_transport_header.raw());
            let mut transport_header = transport_header_data.bind_mut(transport_header_raw);
            transport_header.swap_source_and_destination();
        }

        Self {
            buffer,
            transport_index,
            payload_index,
            ip_header_data,
            transport_header_data,
        }
    }

    pub fn max_tcp_payload(&self) -> u16 {
        // Match the configured phone MTU, including the IPv6 base header.
        1500u16.saturating_sub(self.payload_index as u16)
    }

    pub fn packetize_empty_payload(&mut self) -> IpPacket<'_> {
        self.build(0)
    }

    pub fn packetize<R: DatagramReceiver>(&mut self, source: &mut R) -> io::Result<IpPacket<'_>> {
        let r = source.recv(&mut self.buffer[self.payload_index..])?;
        let ip_packet = self.build(r as u16);
        Ok(ip_packet)
    }

    /// Packetize from stream (`Read`) source.
    ///
    /// `Ok(Some(_))` when packet is available
    /// `Ok(None)` on EOF (read 0 byte)
    /// `Err(_)` on error
    pub fn packetize_read<R: io::Read>(
        &mut self,
        source: &mut R,
        max_chunk_size: Option<usize>,
    ) -> io::Result<Option<IpPacket<'_>>> {
        let mut adapter = ReadAdapter::new(source, max_chunk_size);
        let r = adapter.recv(&mut self.buffer[self.payload_index..])?;
        let option = if r > 0 {
            let ip_packet = self.build(r as u16);
            Some(ip_packet)
        } else {
            None
        };
        Ok(option)
    }

    pub fn ip_header_mut(&mut self) -> IpHeaderMut<'_> {
        let raw = &mut self.buffer[..self.transport_index];
        self.ip_header_data.bind_mut(raw)
    }

    pub fn transport_header_mut(&mut self) -> TransportHeaderMut<'_> {
        let raw = &mut self.buffer[self.transport_index..self.payload_index];
        self.transport_header_data.bind_mut(raw)
    }

    fn build(&mut self, payload_length: u16) -> IpPacket<'_> {
        let total_length = self.payload_index as u16 + payload_length;

        self.ip_header_mut().set_total_length(total_length);
        self.transport_header_mut()
            .set_payload_length(payload_length);

        let mut ip_packet = IpPacket::new(
            &mut self.buffer[..total_length as usize],
            self.ip_header_data.clone(),
            self.transport_header_data.clone(),
        );
        ip_packet.compute_checksums();
        ip_packet
    }

    pub fn inflate(&mut self, packet_length: u16) -> IpPacket<'_> {
        IpPacket::new(
            &mut self.buffer[..packet_length as usize],
            self.ip_header_data.clone(),
            self.transport_header_data.clone(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::datagram::tests::MockDatagramSocket;
    use byteorder::{BigEndian, WriteBytesExt};
    use std::io;

    fn create_packet() -> Vec<u8> {
        let mut raw = Vec::new();
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
        raw
    }

    #[test]
    fn merge_headers_and_payload() {
        let raw = &mut create_packet()[..];
        let reference_packet = IpPacket::parse(raw);

        let data = [0x11u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
        let mut mock = MockDatagramSocket::from_data(&data);

        let ip_header = reference_packet.ip_header();
        let transport_header = reference_packet.transport_header().unwrap();
        let mut packetizer = Packetizer::new(&ip_header, &transport_header);

        let packet = packetizer.packetize(&mut mock).unwrap();
        assert_eq!(36, packet.ip_header_data().total_length());
        assert_eq!(data, &packet.raw()[28..36]);
    }

    #[test]
    fn last_packet() {
        let raw = &mut create_packet()[..];
        let reference_packet = IpPacket::parse(raw);

        let data = [0x11u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
        let mut mock = MockDatagramSocket::from_data(&data);

        let ip_header = reference_packet.ip_header();
        let transport_header = reference_packet.transport_header().unwrap();
        let mut packetizer = Packetizer::new(&ip_header, &transport_header);

        let packet_length = packetizer.packetize(&mut mock).unwrap().length();
        let packet = packetizer.inflate(packet_length);
        assert_eq!(36, packet.ip_header_data().total_length());
        assert_eq!(data, &packet.raw()[28..36]);
    }

    #[test]
    fn packetize_chunks() {
        let raw = &mut create_packet()[..];
        let reference_packet = IpPacket::parse(raw);

        let data = [0x11u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
        let mut cursor = io::Cursor::new(&data);

        let ip_header = reference_packet.ip_header();
        let transport_header = reference_packet.transport_header().unwrap();
        let mut packetizer = Packetizer::new(&ip_header, &transport_header);

        {
            let packet = packetizer
                .packetize_read(&mut cursor, Some(2))
                .unwrap()
                .unwrap();
            assert_eq!(30, packet.ip_header_data().total_length());
            assert_eq!([0x11, 0x22], packet.payload().unwrap());
        }

        {
            let packet = packetizer
                .packetize_read(&mut cursor, Some(3))
                .unwrap()
                .unwrap();
            assert_eq!(31, packet.ip_header_data().total_length());
            assert_eq!([0x33, 0x44, 0x55], packet.payload().unwrap());
        }

        {
            let packet = packetizer
                .packetize_read(&mut cursor, Some(1024))
                .unwrap()
                .unwrap();
            assert_eq!(31, packet.ip_header_data().total_length());
            assert_eq!([0x66, 0x77, 0x88], packet.payload().unwrap());
        }
    }
}
