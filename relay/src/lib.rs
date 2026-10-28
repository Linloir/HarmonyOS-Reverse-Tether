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

pub mod dns;
pub mod policy;
mod relay;
pub use crate::relay::byte_buffer;

use crate::relay::Relay;
use std::io;

pub fn relay(port: u16) -> io::Result<()> {
    relay_with_policy(port, policy::Ipv6Policy::Inherit)
}

pub fn relay_with_policy(port: u16, ipv6: policy::Ipv6Policy) -> io::Result<()> {
    Relay::new(port, ipv6).run()
}
