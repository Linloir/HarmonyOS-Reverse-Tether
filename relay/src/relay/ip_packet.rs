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

use super::ip_header::{IpHeader, IpHeaderData, IpHeaderMut};
use super::transport_header::{TransportHeader, TransportHeaderData, TransportHeaderMut};

pub const MAX_PACKET_LENGTH: usize = 65535;

pub struct IpPacket<'a> {
    raw: &'a mut [u8],
    ip_header_data: IpHeaderData,
    transport_header_data: Option<TransportHeaderData>,
}

impl<'a> IpPacket<'a> {
    pub fn parse(raw: &'a mut [u8]) -> Self {
        let ip_header_data = IpHeaderData::parse(raw);
        let transport_header_data = {
            let payload = &raw[ip_header_data.header_length() as usize..];
            TransportHeaderData::parse(ip_header_data.protocol(), payload)
        };
        Self {
            raw: &mut raw[..ip_header_data.total_length() as usize],
            ip_header_data,
            transport_header_data,
        }
    }

    pub fn new(
        raw: &'a mut [u8],
        ip_header_data: IpHeaderData,
        transport_header_data: TransportHeaderData,
    ) -> Self {
        Self {
            raw,
            ip_header_data,
            transport_header_data: Some(transport_header_data),
        }
    }

    #[inline]
    pub fn raw(&self) -> &[u8] {
        self.raw
    }

    #[inline]
    pub fn headers_data(&self) -> (&IpHeaderData, Option<&TransportHeaderData>) {
        (&self.ip_header_data, self.transport_header_data.as_ref())
    }

    pub fn headers(&self) -> (IpHeader<'_>, Option<TransportHeader<'_>>) {
        let transport_index = self.ip_header_data.header_length() as usize;
        if let Some(ref transport_header_data) = self.transport_header_data {
            let (ip_header_slice, transport_slice) = self.raw.split_at(transport_index);
            // payload_index is relative to transport
            let payload_index = transport_header_data.header_length() as usize;
            let transport_header_slice = &transport_slice[..payload_index];
            let ip_header = self.ip_header_data.bind(ip_header_slice);
            let transport_header = transport_header_data.bind(transport_header_slice);
            (ip_header, Some(transport_header))
        } else {
            let ip_header_slice = &self.raw[..transport_index];
            let ip_header = self.ip_header_data.bind(ip_header_slice);
            (ip_header, None)
        }
    }

    #[inline]
    #[cfg(test)]
    pub fn ip_header_data(&self) -> &IpHeaderData {
        &self.ip_header_data
    }

    #[inline]
    #[cfg(test)]
    pub fn ip_header(&self) -> IpHeader<'_> {
        let slice = &self.raw[..self.ip_header_data.header_length() as usize];
        self.ip_header_data.bind(slice)
    }

    #[inline]
    #[cfg(test)]
    pub fn transport_header_data(&self) -> Option<&TransportHeaderData> {
        self.transport_header_data.as_ref()
    }

    #[inline]
    pub fn transport_header(&self) -> Option<TransportHeader<'_>> {
        if let Some(ref transport_header_data) = self.transport_header_data {
            let start = self.ip_header_data.header_length() as usize;
            let end = start + transport_header_data.header_length() as usize;
            let slice = &self.raw[start..end];
            Some(transport_header_data.bind(slice))
        } else {
            None
        }
    }

    /// Divide the packet into mutable parts:
    ///  - the IP header
    ///  - the transport header (if any)
    ///  - the payload (if there is a transport at all)
    pub fn split_mut(&mut self) -> (IpHeaderMut<'_>, Option<(TransportHeaderMut<'_>, &mut [u8])>) {
        let transport_index = self.ip_header_data.header_length() as usize;
        if let Some(ref mut transport_header_data) = self.transport_header_data {
            // payload_index is relative to transport
            let payload_index = transport_header_data.header_length() as usize;
            let (ip_header_slice, transport_slice) = self.raw.split_at_mut(transport_index);
            let (transport_header_slice, payload_slice) =
                transport_slice.split_at_mut(payload_index);
            let ip_header = self.ip_header_data.bind_mut(ip_header_slice);
            let transport_header = transport_header_data.bind_mut(transport_header_slice);
            (ip_header, Some((transport_header, payload_slice)))
        } else {
            let ip_header_slice = &mut self.raw[..transport_index];
            let ip_header = self.ip_header_data.bind_mut(ip_header_slice);
            (ip_header, None)
        }
    }

    #[inline]
    pub fn is_valid(&self) -> bool {
        self.transport_header_data.is_some()
    }

    #[inline]
    pub fn length(&self) -> u16 {
        self.ip_header_data.total_length()
    }

    pub fn payload(&self) -> Option<&[u8]> {
        self.transport_header_data
            .as_ref()
            .map(|transport_header_data| {
                let range = self.ip_header_data.header_length() as usize
                    + transport_header_data.header_length() as usize..;
                &self.raw[range]
            })
    }

    pub fn compute_checksums(&mut self) {
        let (mut ip_header, transport) = self.split_mut();
        ip_header.update_checksum();
        if let Some((mut transport_header, payload)) = transport {
            transport_header.update_checksum(ip_header.data(), payload);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::ip_header::Protocol;
    use byteorder::{BigEndian, WriteBytesExt};

    fn create_packet() -> Vec<u8> {
        let mut raw = Vec::new();
        raw.reserve(32);

        raw.write_u8(4u8 << 4 | 5).unwrap(); // version_and_ihl
        raw.write_u8(0).unwrap(); //ToS
        raw.write_u16::<BigEndian>(32).unwrap(); // total length 20 + 8 + 4
        raw.write_u32::<BigEndian>(0).unwrap(); // id_flags_fragment_offset
        raw.write_u8(0).unwrap(); // TTL
        raw.write_u8(17).unwrap(); // protocol (UDP)
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum
        raw.write_u32::<BigEndian>(0x12345678).unwrap(); // source address
        raw.write_u32::<BigEndian>(0x42424242).unwrap(); // destination address

        raw.write_u16::<BigEndian>(1234).unwrap(); // source port
        raw.write_u16::<BigEndian>(5678).unwrap(); // destination port
        raw.write_u16::<BigEndian>(12).unwrap(); // UDP header plus payload
        raw.write_u16::<BigEndian>(0).unwrap(); // checksum

        raw.write_u32::<BigEndian>(0x11223344).unwrap(); // payload

        raw
    }

    #[test]
    fn parse_headers() {
        let raw = &mut create_packet()[..];
        let ip_packet = IpPacket::parse(raw);

        {
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

            if let Some(&TransportHeaderData::Udp(ref udp_header)) =
                ip_packet.transport_header_data()
            {
                assert_eq!(1234, udp_header.source_port());
                assert_eq!(5678, udp_header.destination_port());
            } else {
                panic!("No UDP transport header");
            }
        }
    }

    #[test]
    fn payload() {
        let raw = &mut create_packet()[..];
        let ip_packet = IpPacket::parse(raw);
        assert_eq!([0x11, 0x22, 0x33, 0x44], ip_packet.payload().unwrap());
    }
}
