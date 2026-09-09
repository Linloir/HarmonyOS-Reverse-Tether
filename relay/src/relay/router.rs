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

use log::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::io;
use std::rc::{Rc, Weak};

use super::binary;
use super::client::{Client, ClientChannel};
use super::connection::{Connection, ConnectionId};
use super::ipv4_header::Protocol;
use super::ipv4_packet::Ipv4Packet;
use super::selector::Selector;
use super::tcp_connection::TcpConnection;
use super::udp_connection::UdpConnection;

const TAG: &str = "Router";

pub struct Router {
    client: Weak<RefCell<Client>>,
    // HashMap for O(1) lookup. Under load a single client can accumulate thousands of flows,
    // so the original "few connections per client" assumption (Vec + linear scan) becomes the
    // hot path for every packet.
    connections: HashMap<ConnectionId, Rc<RefCell<dyn Connection>>>,
}

impl Router {
    pub fn new() -> Self {
        Self {
            client: Weak::new(),
            connections: HashMap::new(),
        }
    }

    // expose client initialization after construction to break cyclic initialization dependencies
    pub fn set_client(&mut self, client: Weak<RefCell<Client>>) {
        self.client = client;
    }

    pub fn send_to_network(
        &mut self,
        selector: &mut Selector,
        client_channel: &mut ClientChannel,
        ipv4_packet: &Ipv4Packet,
    ) {
        if !ipv4_packet.is_valid() {
            warn!(target: TAG, "Dropping invalid packet");
            if log_enabled!(target: TAG, Level::Trace) {
                trace!(
                    target: TAG,
                    "{}",
                    binary::build_packet_string(ipv4_packet.raw())
                );
            }
            return;
        }

        let (ipv4_header_data, transport_header_data) = ipv4_packet.headers_data();
        let transport_header_data = transport_header_data.expect("No transport");
        let id = ConnectionId::from_headers(ipv4_header_data, transport_header_data);

        let connection_rc = match self.connections.get(&id) {
            Some(rc) => rc.clone(),
            None => match Self::create_connection(selector, id.clone(), self.client.clone(), ipv4_packet) {
                Ok(rc) => {
                    self.connections.insert(id.clone(), rc.clone());
                    rc
                }
                Err(err) => {
                    error!(
                        target: TAG,
                        "Cannot create route, dropping packet: {} (active connections: {})",
                        err,
                        self.connections.len()
                    );
                    return;
                }
            },
        };

        let closed = {
            let mut connection = connection_rc.borrow_mut();
            connection.send_to_network(selector, client_channel, ipv4_packet);
            connection.is_closed()
        };

        if closed {
            debug!(target: TAG, "Removing connection from router: {}", id);
            self.connections.remove(&id);
        }
    }

    fn create_connection(
        selector: &mut Selector,
        id: ConnectionId,
        client: Weak<RefCell<Client>>,
        ipv4_packet: &Ipv4Packet,
    ) -> io::Result<Rc<RefCell<dyn Connection>>> {
        let (ipv4_header, transport_header) = ipv4_packet.headers();
        let transport_header = transport_header.expect("No transport");
        match id.protocol() {
            Protocol::Tcp => Ok(TcpConnection::create(
                selector,
                id,
                client,
                ipv4_header,
                transport_header,
            )?),
            Protocol::Udp => Ok(UdpConnection::create(
                selector,
                id,
                client,
                ipv4_header,
                transport_header,
            )?),
            p => Err(io::Error::new(
                io::ErrorKind::Other,
                format!("Unsupported protocol: {:?}", p),
            )),
        }
    }

    pub fn remove(&mut self, connection: &dyn Connection) {
        let id = connection.id().clone();
        if self.connections.remove(&id).is_none() {
            warn!(target: TAG, "Removing an unknown connection: {}", id);
        } else {
            debug!(target: TAG, "Self-removing connection from router: {}", id);
        }
    }

    pub fn clear(&mut self, selector: &mut Selector) {
        for (_, connection) in self.connections.drain() {
            connection.borrow_mut().close(selector);
        }
    }

    pub fn clean_expired_connections(
        &mut self,
        selector: &mut Selector,
        client_channel: &mut ClientChannel,
    ) {
        let mut expired_ids = Vec::new();
        for (id, connection) in &self.connections {
            if connection.borrow().is_expired() {
                expired_ids.push(id.clone());
            }
        }
        for id in &expired_ids {
            if let Some(connection) = self.connections.remove(id) {
                debug!(target: TAG, "Removing expired connection from router: {}", id);
                connection.borrow_mut().expire(selector, client_channel);
            }
        }
        if !expired_ids.is_empty() {
            info!(
                target: TAG,
                "Expired connections cleaned: {} (active: {})",
                expired_ids.len(),
                self.connections.len()
            );
        }
    }

    pub fn active_count(&self) -> usize {
        self.connections.len()
    }

    pub fn protocol_counts(&self) -> (usize, usize, usize) {
        let mut tcp = 0;
        let mut udp = 0;
        let mut other = 0;
        for id in self.connections.keys() {
            match id.protocol() {
                Protocol::Tcp => tcp += 1,
                Protocol::Udp => udp += 1,
                Protocol::Other => other += 1,
            }
        }
        (tcp, udp, other)
    }
}
