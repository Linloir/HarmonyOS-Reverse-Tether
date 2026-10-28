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

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use super::client::ClientChannel;
use super::ip_header::{IpHeaderData, Protocol};
use super::ip_packet::IpPacket;
use super::selector::Selector;
use super::transport_header::TransportHeaderData;

const LOCALHOST_FORWARD: u32 = 0x0A_00_02_02; // 10.0.2.2
const LOCALHOST: u32 = 0x7F_00_00_01; // 127.0.0.1

pub trait Connection {
    fn id(&self) -> &ConnectionId;
    fn send_to_network(
        &mut self,
        selector: &mut Selector,
        client_channel: &mut ClientChannel,
        ip_packet: &IpPacket,
    );
    fn close(&mut self, selector: &mut Selector);
    /// Called by the reaper when the flow has been idle for too long.
    /// Receives a ClientChannel so implementations can push a terminal
    /// packet (e.g. TCP RST) back to the client without having to
    /// re-borrow the Client -- which would panic, since the reaper is
    /// already holding it mutably.
    fn expire(&mut self, selector: &mut Selector, _client_channel: &mut ClientChannel) {
        self.close(selector);
    }
    fn is_expired(&self) -> bool;
    fn is_closed(&self) -> bool;
}

#[derive(Clone, Debug, Eq)]
pub struct ConnectionId {
    protocol: Protocol,
    source_ip: IpAddr,
    source_port: u16,
    destination_ip: IpAddr,
    destination_port: u16,
    id_string: String,
}

impl PartialEq for ConnectionId {
    fn eq(&self, other: &Self) -> bool {
        self.protocol == other.protocol
            && self.source_ip == other.source_ip
            && self.source_port == other.source_port
            && self.destination_ip == other.destination_ip
            && self.destination_port == other.destination_port
    }
}

impl std::hash::Hash for ConnectionId {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.protocol.hash(state);
        self.source_ip.hash(state);
        self.source_port.hash(state);
        self.destination_ip.hash(state);
        self.destination_port.hash(state);
    }
}

impl ConnectionId {
    pub fn from_headers(
        ip_header_data: &IpHeaderData,
        transport_header_data: &TransportHeaderData,
    ) -> Self {
        let source_ip = ip_header_data.source();
        let source_port = transport_header_data.source_port();
        let destination_ip = ip_header_data.destination();
        let destination_port = transport_header_data.destination_port();
        let id_string = format!(
            "{} -> {}",
            SocketAddr::new(source_ip, source_port),
            SocketAddr::new(destination_ip, destination_port)
        );
        Self {
            protocol: ip_header_data.protocol(),
            source_ip,
            source_port,
            destination_ip,
            destination_port,
            id_string,
        }
    }

    pub fn protocol(&self) -> Protocol {
        self.protocol
    }

    pub fn rewritten_destination(&self) -> SocketAddr {
        if crate::dns::is_virtual(self.destination_ip) && self.destination_port == 53 {
            return crate::dns::upstream();
        }
        let ip = if self.destination_ip == IpAddr::V4(Ipv4Addr::from(LOCALHOST_FORWARD)) {
            IpAddr::V4(Ipv4Addr::from(LOCALHOST))
        } else {
            self.destination_ip
        };
        SocketAddr::new(ip, self.destination_port)
    }
}

impl fmt::Display for ConnectionId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.id_string)
    }
}

// macros to log connection id along with the message

macro_rules! cx_format {
    ($id:tt, $str:tt, $($arg:tt)+) => {
        format!(concat!("{} ", $str), $id, $($arg)+)
    };
    ($id:tt, $str:tt) => {
        format!(concat!("{} ", $str), $id)
    };
}

macro_rules! cx_trace {
    (target: $target:expr, $id:expr, $($arg:tt)*) => {
        log::trace!(target: $target, "{}", cx_format!($id, $($arg)+))
    }
}

macro_rules! cx_debug {
    (target: $target:expr, $id:expr, $($arg:tt)*) => {
        log::debug!(target: $target, "{}", cx_format!($id, $($arg)+))
    }
}

macro_rules! cx_info {
    (target: $target:expr, $id:expr, $($arg:tt)*) => {
        log::info!(target: $target, "{}", cx_format!($id, $($arg)+))
    }
}

macro_rules! cx_warn {
    (target: $target:expr, $id:expr, $($arg:tt)*) => {
        log::warn!(target: $target, "{}", cx_format!($id, $($arg)+))
    }
}

macro_rules! cx_error {
    (target: $target:expr, $id:expr, $($arg:tt)*) => {
        log::error!(target: $target, "{}", cx_format!($id, $($arg)+))
    }
}
