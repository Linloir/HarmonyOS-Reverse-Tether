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

// SPDX-License-Identifier: Apache-2.0
use byteorder::{BigEndian, ByteOrder};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::{io, mem};

pub struct IpHeader<'a> {
    raw: &'a [u8],
    data: &'a IpHeaderData,
}
pub struct IpHeaderMut<'a> {
    raw: &'a mut [u8],
    data: &'a mut IpHeaderData,
}

#[derive(Clone, Debug)]
pub struct IpHeaderData {
    version: u8,
    header_length: u16,
    total_length: u16,
    protocol: Protocol,
    source: IpAddr,
    destination: IpAddr,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash)]
pub enum Protocol {
    Tcp,
    Udp,
    Other,
}

fn malformed() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Malformed IP/transport frame")
}

/// Native tunnel frames are bounded at 65535 bytes; no IPv6 jumbograms.
pub fn frame_length(raw: &[u8]) -> io::Result<Option<usize>> {
    if raw.is_empty() {
        return Ok(None);
    }
    match raw[0] >> 4 {
        4 => {
            if raw.len() < 4 {
                return Ok(None);
            }
            let header = usize::from(raw[0] & 15) * 4;
            let length = usize::from(BigEndian::read_u16(&raw[2..4]));
            if header < 20 || length < header {
                return Err(malformed());
            }
            Ok(Some(length))
        }
        6 => {
            if raw.len() < 6 {
                return Ok(None);
            }
            let payload = usize::from(BigEndian::read_u16(&raw[4..6]));
            if payload == 0 || payload + 40 > 65535 {
                return Err(malformed());
            }
            Ok(Some(40 + payload))
        }
        _ => Err(malformed()),
    }
}

impl IpHeaderData {
    /// The caller must have validated a complete packet first.
    pub fn parse(raw: &[u8]) -> Self {
        Self::validate(raw).expect("IP packet was validated before parsing")
    }
    pub fn validate(raw: &[u8]) -> io::Result<Self> {
        let length = frame_length(raw)?.ok_or_else(malformed)?;
        if raw.len() < length {
            return Err(malformed());
        }
        let version = raw[0] >> 4;
        let (source, destination, mut offset, mut next) = if version == 4 {
            let offset = usize::from(raw[0] & 15) * 4;
            let fragmented = raw[6] & 0x3f != 0 || raw[7] != 0;
            (
                IpAddr::V4(Ipv4Addr::from(BigEndian::read_u32(&raw[12..16]))),
                IpAddr::V4(Ipv4Addr::from(BigEndian::read_u32(&raw[16..20]))),
                offset,
                if fragmented { 255 } else { raw[9] },
            )
        } else {
            let mut src = [0; 16];
            src.copy_from_slice(&raw[8..24]);
            let mut dst = [0; 16];
            dst.copy_from_slice(&raw[24..40]);
            (
                IpAddr::V6(Ipv6Addr::from(src)),
                IpAddr::V6(Ipv6Addr::from(dst)),
                40,
                raw[6],
            )
        };
        if version == 6 {
            // Bound traversal. Routing/auth/encrypted headers and non-atomic
            // fragments remain unsupported packets, not stream failures.
            let mut extensions = 0;
            loop {
                if !matches!(next, 0 | 60 | 44) {
                    break;
                }
                extensions += 1;
                if extensions > 16 {
                    next = 255;
                    break;
                }
                if offset + 8 > length {
                    return Err(malformed());
                }
                let size = if next == 44 {
                    8
                } else {
                    (usize::from(raw[offset + 1]) + 1) * 8
                };
                if offset + size > length {
                    return Err(malformed());
                }
                if next == 44 {
                    if BigEndian::read_u16(&raw[offset + 2..offset + 4]) != 0 {
                        next = 255;
                        break;
                    }
                } else {
                    // Honor unknown-option discard bits and validate every TLV.
                    let mut option = offset + 2;
                    while option < offset + size {
                        let kind = raw[option];
                        if kind == 0 {
                            option += 1;
                            continue;
                        }
                        if option + 2 > offset + size {
                            return Err(malformed());
                        }
                        let option_size = usize::from(raw[option + 1]) + 2;
                        if option + option_size > offset + size {
                            return Err(malformed());
                        }
                        if kind & 0xc0 != 0 {
                            next = 255;
                            break;
                        }
                        option += option_size;
                    }
                    if next == 255 {
                        break;
                    }
                }
                next = raw[offset];
                offset += size;
            }
        }
        let protocol = match next {
            6 => Protocol::Tcp,
            17 => Protocol::Udp,
            _ => Protocol::Other,
        };
        let payload = length - offset;
        match protocol {
            Protocol::Tcp => {
                if payload < 20 {
                    return Err(malformed());
                }
                let header = usize::from(raw[offset + 12] >> 4) * 4;
                if header < 20 || header > payload {
                    return Err(malformed());
                }
            }
            Protocol::Udp => {
                if payload < 8
                    || usize::from(BigEndian::read_u16(&raw[offset + 4..offset + 6])) != payload
                {
                    return Err(malformed());
                }
                if version == 6 && raw[offset + 6..offset + 8] == [0, 0] {
                    return Err(malformed());
                }
            }
            Protocol::Other => (),
        }
        Ok(Self {
            version,
            header_length: offset as u16,
            total_length: length as u16,
            protocol,
            source,
            destination,
        })
    }
    pub fn bind<'c, 'a: 'c, 'b: 'c>(&'a self, raw: &'b [u8]) -> IpHeader<'c> {
        IpHeader::new(raw, self)
    }
    pub fn bind_mut<'c, 'a: 'c, 'b: 'c>(&'a mut self, raw: &'b mut [u8]) -> IpHeaderMut<'c> {
        IpHeaderMut::new(raw, self)
    }
    pub fn version(&self) -> u8 {
        self.version
    }
    pub fn header_length(&self) -> u16 {
        self.header_length
    }
    pub fn total_length(&self) -> u16 {
        self.total_length
    }
    pub fn protocol(&self) -> Protocol {
        self.protocol
    }
    pub fn source(&self) -> IpAddr {
        self.source
    }
    pub fn destination(&self) -> IpAddr {
        self.destination
    }

    /// Replies have a fresh IPv6 base header; never reflect request extensions.
    pub fn reply_header(&self, reference: &[u8]) -> (Self, Vec<u8>) {
        let mut data = self.clone();
        let mut raw = reference.to_vec();
        if self.version == 6 {
            raw.truncate(40);
            raw[6] = match self.protocol {
                Protocol::Tcp => 6,
                Protocol::Udp => 17,
                Protocol::Other => 59,
            };
            raw[7] = 64;
            data.header_length = 40;
        }
        data.bind_mut(&mut raw).swap_source_and_destination();
        (data, raw)
    }
    pub fn pseudo_header_sum(&self, protocol: u8, length: u16) -> u32 {
        fn address_sum(ip: IpAddr) -> u32 {
            match ip {
                IpAddr::V4(ip) => ip
                    .octets()
                    .chunks_exact(2)
                    .map(|p| u32::from(BigEndian::read_u16(p)))
                    .sum(),
                IpAddr::V6(ip) => ip.segments().iter().map(|&p| u32::from(p)).sum(),
            }
        }
        address_sum(self.source)
            + address_sum(self.destination)
            + u32::from(protocol)
            + u32::from(length)
    }
}

macro_rules! ip_header_common {
    ($name:ident, $raw_type:ty, $data_type:ty) => {
        #[allow(dead_code)]
        impl<'a> $name<'a> {
            pub fn new(raw: $raw_type, data: $data_type) -> Self {
                Self { raw, data }
            }
            pub fn raw(&self) -> &[u8] {
                self.raw
            }
            pub fn data(&self) -> &IpHeaderData {
                self.data
            }
            pub fn header_length(&self) -> u16 {
                self.data.header_length
            }
            pub fn total_length(&self) -> u16 {
                self.data.total_length
            }
            pub fn protocol(&self) -> Protocol {
                self.data.protocol
            }
            pub fn source(&self) -> IpAddr {
                self.data.source
            }
            pub fn destination(&self) -> IpAddr {
                self.data.destination
            }
        }
    };
}
ip_header_common!(IpHeader, &'a [u8], &'a IpHeaderData);
ip_header_common!(IpHeaderMut, &'a mut [u8], &'a mut IpHeaderData);

#[allow(dead_code)]
impl<'a> IpHeaderMut<'a> {
    pub fn raw_mut(&mut self) -> &mut [u8] {
        self.raw
    }
    pub fn data_mut(&mut self) -> &mut IpHeaderData {
        self.data
    }
    pub fn set_total_length(&mut self, length: u16) {
        self.data.total_length = length;
        if self.data.version == 6 {
            BigEndian::write_u16(&mut self.raw[4..6], length - 40);
        } else {
            BigEndian::write_u16(&mut self.raw[2..4], length);
        }
    }
    pub fn swap_source_and_destination(&mut self) {
        mem::swap(&mut self.data.source, &mut self.data.destination);
        let (offset, size) = if self.data.version == 6 {
            (8, 16)
        } else {
            (12, 4)
        };
        for i in offset..offset + size {
            self.raw.swap(i, i + size);
        }
    }
    pub fn update_checksum(&mut self) {
        if self.data.version == 6 {
            return;
        }
        let words = usize::from(self.data.header_length) / 2;
        let mut sum: u32 = (0..5)
            .chain(6..words)
            .map(|i| u32::from(BigEndian::read_u16(&self.raw[2 * i..2 * i + 2])))
            .sum();
        while sum > 0xffff {
            sum = (sum & 0xffff) + (sum >> 16);
        }
        BigEndian::write_u16(&mut self.raw[10..12], !(sum as u16));
    }
}
