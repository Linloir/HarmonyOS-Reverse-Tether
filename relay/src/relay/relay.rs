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

use chrono::Local;
use log::*;
use mio::Events;
use std::cell::RefCell;
use std::cmp::{max, min};
use std::io;
use std::rc::Rc;
use std::time::Duration;

use super::selector::Selector;
use super::tunnel_server::TunnelServer;

const TAG: &str = "Relay";
// Kept short so that SynSent / half-open reaps (see CONNECT_TIMEOUT_SECONDS in
// tcp_connection.rs) translate into a timely RST back to the Android client.
// Scan is O(n) in connection count and runs in microseconds for realistic n.
const CLEANING_INTERVAL_SECONDS: i64 = 5;
// Emit a periodic snapshot of per-client connection counts so that saturation
// (approaching the fd rlimit) is observable without enabling debug logs.
const STATS_INTERVAL_SECONDS: i64 = 5 * 60;

pub struct Relay {
    port: u16,
}

impl Relay {
    pub fn new(port: u16) -> Self {
        Self { port }
    }

    pub fn run(&self) -> io::Result<()> {
        let mut selector = Selector::create().unwrap();
        let tunnel_server = TunnelServer::create(self.port, &mut selector)?;
        info!(target: TAG, "Relay server started");
        self.poll_loop(&mut selector, &tunnel_server)
    }

    fn poll_loop(
        &self,
        selector: &mut Selector,
        tunnel_server: &Rc<RefCell<TunnelServer>>,
    ) -> io::Result<()> {
        let mut events = Events::with_capacity(1024);
        let start = Local::now().timestamp();
        let mut next_cleaning_deadline = start + CLEANING_INTERVAL_SECONDS;
        let mut next_stats_deadline = start + STATS_INTERVAL_SECONDS;
        loop {
            retry_on_intr!({
                // We want to wake at whichever deadline comes FIRST -- using
                // max() here would let cleaning be deferred all the way to
                // the next stats deadline (~5 min) during idle periods,
                // which lets dead-flow accumulation outpace reclamation.
                let next_deadline = min(next_cleaning_deadline, next_stats_deadline);
                let timeout_seconds = max(0, next_deadline - Local::now().timestamp());
                let timeout = Some(Duration::new(timeout_seconds as u64, 0));
                selector.poll(&mut events, timeout)
            })?;

            let now = Local::now().timestamp();
            if now >= next_cleaning_deadline {
                tunnel_server.borrow_mut().clean_up(selector);
                next_cleaning_deadline = now + CLEANING_INTERVAL_SECONDS;
            }
            if now >= next_stats_deadline {
                tunnel_server.borrow().log_stats();
                next_stats_deadline = now + STATS_INTERVAL_SECONDS;
            }
            if events.is_empty() && now < next_cleaning_deadline && now < next_stats_deadline {
                debug!(
                    target: TAG,
                    "Spurious wakeup: poll() returned without any event"
                );
                continue;
            }

            selector.run_handlers(&events);
        }
    }
}
